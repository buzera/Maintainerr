# Overlay scope test image: staging, deployment and rollback

Fork-only material for running the `feat/configurable-overlay-scope` build
before it is merged upstream. Nothing here is meant for the upstream pull
request.

| File                                                   | Purpose                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------- |
| `../../.github/workflows/fork-overlay-scope-image.yml` | Builds and smoke-tests a native `linux/amd64` image; publishes only on your tag |
| `docker-compose.stage.yml`                             | Staging instance `maintainerr-stage` on `127.0.0.1:6247`                        |
| `test-db-copy-migration.sh`                            | Migrates a disposable copy of the production database with no network           |
| `PULL_REQUEST.md`                                      | Proposed upstream pull request title and description                            |
| `DOCS.md`                                              | Proposed Overlay scope section for the documentation site                       |

Nothing in this procedure runs against production until you reach section 4,
and section 4 is to be run by you, step by step.

---

## 1. Build and publish the amd64 image

A push to `ci/overlay-scope-image` builds and smoke-tests the image on an
x86_64 Ubuntu runner and publishes nothing. To publish (your approval), tag
the commit you want and push the tag:

```bash
git fetch origin
git tag overlay-scope-test.1 origin/ci/overlay-scope-image
git push origin overlay-scope-test.1
```

The run publishes `ghcr.io/buzera/maintainerr-overlay-scope:overlay-scope-test.1`
and prints its digest in the run summary. Use a new number for every later
build; the workflow never writes `latest`.

A newly published GHCR package is private. Either make it public under
GitHub > Your profile > Packages > maintainerr-overlay-scope > Package
settings, or log in on the server with a token that has `read:packages`:

```bash
echo "$GHCR_READ_TOKEN" | docker login ghcr.io -u buzera --password-stdin
```

Pull and check the platform:

```bash
IMAGE=ghcr.io/buzera/maintainerr-overlay-scope:overlay-scope-test.1
docker pull "$IMAGE"
docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}'   # linux/amd64
docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}'    # pin this
```

## 2. Staging

```bash
cd deploy/overlay-scope
export IMAGE=ghcr.io/buzera/maintainerr-overlay-scope@sha256:<digest>
docker compose -f docker-compose.stage.yml up -d
docker inspect -f '{{.State.Health.Status}}' maintainerr-stage   # healthy after ~40 s
curl -fsS http://127.0.0.1:6247/api/health/ready
```

Open it through an SSH tunnel (`ssh -L 6247:127.0.0.1:6247 <server>`). It
has its own empty database: connect only test fixtures to it, never the
production Plex, Radarr, Sonarr, Tautulli or Ombi. Remove it with
`docker compose -f docker-compose.stage.yml down -v`.

## 3. Migration test on a copy of the production database

Make the copy without stopping production, with SQLite's online backup (it
only reads the live file):

```bash
mkdir -p /root/maintainerr-dbcopy
sqlite3 /services/maintainerr/maintainerr.sqlite ".backup /root/maintainerr-dbcopy/maintainerr.sqlite"
```

If `sqlite3` is not installed, stop the production container for a moment,
`cp -a` the `maintainerr.sqlite*` files to `/root/maintainerr-dbcopy/`, and
start it again.

Then run the check. Every container it starts has `--network none`, so the
copy, which holds the production URLs and keys, can reach nothing:

```bash
IMAGE=ghcr.io/buzera/maintainerr-overlay-scope@sha256:<digest> \
DB_COPY=/root/maintainerr-dbcopy/maintainerr.sqlite \
  ./test-db-copy-migration.sh
```

It reports `MIGRATION CHECK PASSED` when the overlay scope migration is the
newest applied, integrity and foreign keys are clean, every collection reads
as `all`, and collections, members, rule groups, rules, exclusions, overlay
state, templates and settings kept their row counts. Delete
`/root/maintainerr-dbcopy` afterwards: it contains production credentials.

---

## 4. Production deployment (prepared, not executed)

Run these one at a time and check each result. Adjust the variables first.

```bash
export MAINTAINERR=maintainerr                       # container name
export MAINTAINERR_URL=http://127.0.0.1:6246         # API as reachable from the server
export COMPOSE_FILE=/path/to/docker-compose.yml       # the file that defines it
export NEW_IMAGE=ghcr.io/buzera/maintainerr-overlay-scope@sha256:<digest>
export BACKUP=/root/maintainerr-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP"
```

### 4.1 Record the current state

```bash
docker inspect "$MAINTAINERR" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | tee "$BACKUP/mounts.txt"
docker inspect "$MAINTAINERR" --format '{{.Config.Image}} {{.Image}}' | tee "$BACKUP/previous-image.txt"
docker tag "$(docker inspect "$MAINTAINERR" --format '{{.Image}}')" maintainerr-rollback:pre-overlay-scope
curl -fsS "$MAINTAINERR_URL/api/settings" > "$BACKUP/settings.json"
curl -fsS "$MAINTAINERR_URL/api/overlays/settings" > "$BACKUP/overlay-settings.json"
chmod -R go-rwx "$BACKUP"    # settings.json and the backups hold API keys and tokens
```

`mounts.txt` must show `/services/maintainerr -> /opt/data` and where
`/mnt/plexoverlays` is mounted. Overlay originals live at
`<data dir>/overlays/originals` inside the container, so with
`/mnt/plexoverlays -> /opt/data/overlays` they are in
`/mnt/plexoverlays/originals`. Set it:

```bash
export ORIGINALS=/mnt/plexoverlays/originals         # confirm against mounts.txt
find "$ORIGINALS" -maxdepth 1 -name '*.jpg' | wc -l | tee "$BACKUP/originals-before.count"
```

Row counts, read through the running app's own driver, read-only:

```bash
cat > "$BACKUP/counts.js" <<'JS'
// Resolved from the app folder: a script outside it cannot see its modules.
const Database = require(require.resolve("better-sqlite3", { paths: ["/opt/app/apps/server"] }));
const db = new Database("/opt/data/maintainerr.sqlite", { readonly: true });
const tables = ["collection", "collection_media", "rule_group", "rules", "exclusion", "overlay_item_state"];
const out = Object.fromEntries(tables.map((t) => [t, db.prepare(`SELECT COUNT(*) AS c FROM "${t}"`).get().c]));
out.lastMigration = db.prepare("SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1").get().name;
const cols = db.prepare("SELECT name FROM pragma_table_info(?)").all("collection").map((r) => r.name);
if (cols.includes("overlayScope")) out.scopes = db.prepare("SELECT overlayScope, COUNT(*) AS c FROM collection GROUP BY overlayScope").all();
out.integrity = db.pragma("integrity_check", { simple: true });
console.log(JSON.stringify(out, null, 1));
JS
docker cp "$BACKUP/counts.js" "$MAINTAINERR:/tmp/counts.js"
docker exec -w /opt/app/apps/server "$MAINTAINERR" node /tmp/counts.js | tee "$BACKUP/counts-before.json"
```

### 4.2 Pause deletion and overlay runs

Note the current schedules in `settings.json`
(`collection_handler_job_cron`, `rules_handler_job_cron`) and in
`overlay-settings.json` (`enabled`, `cronSchedule`). Then move both handlers
to a date outside the deployment window and switch the overlay feature off.
With the feature off a run skips entirely; it does not revert anything.

```bash
curl -fsS -X PATCH "$MAINTAINERR_URL/api/settings" -H 'Content-Type: application/json' \
  -d '{"collection_handler_job_cron":"0 4 1 1 *","rules_handler_job_cron":"0 4 1 1 *"}'
curl -fsS -X PUT "$MAINTAINERR_URL/api/overlays/settings" -H 'Content-Type: application/json' \
  -d '{"enabled":false}'
```

The same settings are under Settings > Jobs and Settings > Overlays in the UI.
Confirm in Settings > Jobs that no handler is running before going on.

### 4.3 Stop and back up

```bash
docker compose -f "$COMPOSE_FILE" stop "$MAINTAINERR"   # or: docker stop "$MAINTAINERR"
tar --numeric-owner -cpf "$BACKUP/services-maintainerr.tar" -C / services/maintainerr
tar --numeric-owner -cpf "$BACKUP/plexoverlays.tar" -C / mnt/plexoverlays
(cd "$BACKUP" && sha256sum *.tar > SHA256SUMS && tar -tf services-maintainerr.tar | grep -c maintainerr.sqlite)
```

Keep the backup until the new version has run for a few days.

### 4.4 Change only the image

In `$COMPOSE_FILE`, change the `image:` line of the Maintainerr service to
`$NEW_IMAGE`, leave `volumes:`, `user:`, `environment:` and `ports:` as they
are, and keep Watchtower away from it:

```yaml
image: ghcr.io/buzera/maintainerr-overlay-scope@sha256:<digest>
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

```bash
docker compose -f "$COMPOSE_FILE" pull "$MAINTAINERR"
docker compose -f "$COMPOSE_FILE" up -d "$MAINTAINERR"
docker logs -f "$MAINTAINERR"        # Ctrl-C once "Nest application successfully started"
```

### 4.5 Verify the migration

```bash
docker inspect -f '{{.State.Health.Status}}' "$MAINTAINERR"     # healthy
docker cp "$BACKUP/counts.js" "$MAINTAINERR:/tmp/counts.js"
docker exec -w /opt/app/apps/server "$MAINTAINERR" node /tmp/counts.js | tee "$BACKUP/counts-after.json"
```

Expected: `lastMigration` is `AddCollectionOverlayScope1792538934144`, every
collection is in `scopes` as `all`, `integrity` is `ok`, and every count
matches `counts-before.json`. Rules, collections and settings in the UI look
as before. If anything differs, stop here and roll back (section 5).

### 4.6 Confirm nothing changed yet, then restore child artwork

1. Switch overlays back on with the old settings (Settings > Overlays, or
   `PUT /api/overlays/settings` with the `enabled` and `cronSchedule` from
   `overlay-settings.json`) and press Run on the Overlay Handler. Every
   collection is still `all`, so the summary line must show `0 reverted` and
   `0 errors`; only the usual day-count updates are applied.
2. Pilot: edit one small show rule, set Overlay scope to Show only, save, and
   run the Overlay Handler. The log lists `Restored original poster for item
...` for each season and episode of that collection, and the summary shows
   that many `reverted` and `0 errors`. Check a few of those seasons and
   episodes in Plex, and that the originals count dropped by the same number:
   `find "$ORIGINALS" -maxdepth 1 -name '*.jpg' | wc -l`.
3. Any `Failed to restore original poster ...; keeping backup for retry` line
   leaves that item's backup and state in place; the next run retries it.
   A large collection takes a while: each restore is several Plex requests.
4. Change the remaining show collections one at a time the same way.
5. Put back the original handler schedules from `settings.json`:

```bash
curl -fsS -X PATCH "$MAINTAINERR_URL/api/settings" -H 'Content-Type: application/json' \
  -d '{"collection_handler_job_cron":"<saved value>","rules_handler_job_cron":"<saved value>"}'
```

---

## 5. Rollback

The previous image is kept as `maintainerr-rollback:pre-overlay-scope`, and
the database backup from 4.3 matches it.

```bash
docker compose -f "$COMPOSE_FILE" stop "$MAINTAINERR"
mv /services/maintainerr "/services/maintainerr.overlay-scope-$(date +%Y%m%d-%H%M%S)"
tar --numeric-owner -xpf "$BACKUP/services-maintainerr.tar" -C /
# Overlay originals: merge, never replace. Backups the new version took after
# the deployment belong to artwork that may still carry an overlay, so they
# must survive; --ignore-existing keeps them and brings back every original the
# new version deleted after restoring it.
mkdir -p "$BACKUP/plexoverlays-restore"
tar --numeric-owner -xpf "$BACKUP/plexoverlays.tar" -C "$BACKUP/plexoverlays-restore"
rsync -a --ignore-existing "$BACKUP/plexoverlays-restore/mnt/plexoverlays/" /mnt/plexoverlays/
```

Set the `image:` line back to `maintainerr-rollback:pre-overlay-scope` (or
the reference in `previous-image.txt`), then:

```bash
docker compose -f "$COMPOSE_FILE" up -d "$MAINTAINERR"
docker exec -w /opt/app/apps/server "$MAINTAINERR" node /tmp/counts.js   # copy counts.js in again first
```

`counts.js` must match `counts-before.json` exactly, `lastMigration`
included (for v3.30.2 that is `MoveExclusionTagToServers1790456691255`). Artwork the new version
restored stays original in Plex until the previous version's next overlay
run, which draws on seasons and episodes again as it did before.
