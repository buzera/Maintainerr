# Overlay scope test images: staging, pilot and rollback

Fork-only material for running the overlay scope feature before it is merged
upstream. Nothing here is meant for the upstream pull request.

| Image                                                             | Built from                                                                                                       | Use                                                      |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `ghcr.io/buzera/maintainerr-overlay-scope:3.30.2-test.<n>`        | branch `ci/overlay-scope-image-3.30.2`: the official v3.30.2 release plus the overlay scope commit, nothing else | **Production pilot**                                     |
| `ghcr.io/buzera/maintainerr-overlay-scope:overlay-scope-test.<n>` | branch `ci/overlay-scope-image`: upstream `development` plus the same commit                                     | Preview of the upstream pull request; not for production |

| File                                                   | Purpose                                                                                  |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `../../.github/workflows/fork-overlay-scope-image.yml` | Builds and smoke-tests both images natively on `linux/amd64`; publishes only on your tag |
| `docker-compose.stage.yml`                             | Staging instance `maintainerr-stage` on `127.0.0.1:6247`                                 |
| `test-db-copy-migration.sh`                            | Migrates a disposable copy of the production database with no network                    |
| `verify-restored-artwork.py`                           | Read-only check that restored artwork matches the preserved originals                    |
| `PULL_REQUEST.md`                                      | Proposed upstream pull request title and description                                     |
| `DOCS.md`                                              | Proposed Overlay scope section for the documentation site                                |

Nothing here runs against production until section 4, and section 4 is to be
run by you, step by step.

---

## 1. Build and publish

A push to either `ci/*` branch builds and smoke-tests its image and
publishes nothing. Publishing is your approval: tag the commit and push the
tag. A tag that already exists in the registry is refused, so use a new
number for every build.

```bash
git fetch origin
# Production candidate (v3.30.2-based):
git tag 3.30.2-test.1 origin/ci/overlay-scope-image-3.30.2
git push origin 3.30.2-test.1
# Upstream preview (development-based):
git tag overlay-scope-test.1 origin/ci/overlay-scope-image
git push origin overlay-scope-test.1
```

The workflow refuses a `3.30.2-test.*` tag unless the app code is exactly
v3.30.2 plus one commit, and an `overlay-scope-test.*` tag on that commit, so
the two images cannot be swapped. The run summary prints the digest.

A newly published GHCR package is private. Either make it public under
GitHub > Your profile > Packages > maintainerr-overlay-scope > Package
settings, or log in on the server with a token that has `read:packages`:

```bash
echo "$GHCR_READ_TOKEN" | docker login ghcr.io -u buzera --password-stdin
IMAGE=ghcr.io/buzera/maintainerr-overlay-scope:3.30.2-test.1
docker pull "$IMAGE"
docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}'                                      # linux/amd64
docker image inspect "$IMAGE" --format '{{index .Config.Labels "io.github.buzera.overlay-scope.base"}}'  # v3.30.2
docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}'                                        # pin this
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

Every container the check starts has `--network none`, so the copy, which
holds the production URLs and keys, can reach nothing:

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

## 4. Production pilot with the v3.30.2-based image (prepared, not executed)

### How the pilot avoids redrawing child overlays

An overlay is redrawn only when the number of days it shows changes, and
every countdown changes at midnight (server time zone), because collection
items are stored with a midnight add date. So:

- On the day of a completed old-version overlay run, the new version redraws
  nothing: every saved count is still today's.
- A narrowed collection is restored straight from the saved originals. The
  first run after the switch uploads each excluded season and episode once,
  as its original, and never draws an overlay on it first.
- Saving a rule writes no artwork, and with the overlay feature switched off
  a run does nothing at all, reverts included.

Therefore: run the old version's overlay pass, deploy, switch the scopes and
run the new version's first pass **on the same calendar day**, and never let
an overlay run happen on a new day while a show collection you mean to narrow
is still on Show + seasons + episodes. If the work spills over midnight, keep
the overlay feature off until every remaining show collection is switched.

### 4.1 Variables and preconditions

```bash
export MAINTAINERR=maintainerr                       # container name
export MAINTAINERR_URL=http://127.0.0.1:6246         # API as reachable from the server
export COMPOSE_FILE=/path/to/docker-compose.yml       # the file that defines it
export NEW_IMAGE=ghcr.io/buzera/maintainerr-overlay-scope@sha256:<digest of 3.30.2-test.n>
export OFFICIAL_3_30_2=ghcr.io/maintainerr/maintainerr:3.30.2@sha256:816779316fc9a2d8e45946dc7a0e676784bc1453eaaff701900132ab67d5abba
export BACKUP=/root/maintainerr-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP" && chmod 700 "$BACKUP"     # it will hold API keys and tokens
```

Sections 2 and 3 have passed with this same digest.

### 4.2 Record the current state (old version running)

```bash
docker inspect "$MAINTAINERR" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | tee "$BACKUP/mounts.txt"
docker inspect "$MAINTAINERR" --format '{{.Config.Image}} {{.Image}}' | tee "$BACKUP/previous-image.txt"
docker tag "$(docker inspect "$MAINTAINERR" --format '{{.Image}}')" maintainerr-rollback:pre-overlay-scope
curl -fsS "$MAINTAINERR_URL/api/settings" > "$BACKUP/settings.json"
curl -fsS "$MAINTAINERR_URL/api/overlays/settings" > "$BACKUP/overlay-settings.json"
```

`mounts.txt` must show `/services/maintainerr -> /opt/data` and where
`/mnt/plexoverlays` is mounted. Overlay originals live at
`<data dir>/overlays/originals` inside the container, so with
`/mnt/plexoverlays -> /opt/data/overlays` they are in
`/mnt/plexoverlays/originals`:

```bash
export ORIGINALS=/mnt/plexoverlays/originals         # confirm against mounts.txt
```

Row counts and the overlay inventory, read-only through the running app's
own SQLite driver:

```bash
cat > "$BACKUP/counts.js" <<'JS'
// Resolved from the app folder: a script outside it cannot see its modules.
const Database = require(require.resolve("better-sqlite3", { paths: ["/opt/app/apps/server"] }));
const db = new Database("/opt/data/maintainerr.sqlite", { readonly: true });
const tables = ["collection", "collection_media", "rule_group", "rules", "exclusion", "overlay_item_state"];
const out = Object.fromEntries(tables.map((t) => [t, db.prepare(`SELECT COUNT(*) AS c FROM "${t}"`).get().c]));
out.lastMigration = db.prepare("SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1").get().name;
const hasScope = db.prepare("SELECT name FROM pragma_table_info(?)").all("collection").some((r) => r.name === "overlayScope");
// Per overlay collection: states, and how many of them are inherited (a
// season or episode drawn because its show is a member). For a show
// collection switched to Show only, "inherited" is what the first run restores.
out.overlayCollections = db.prepare(`
  SELECT c.id, c.title, c.type, ${hasScope ? "c.overlayScope" : "'(none)'"} AS scope,
         COUNT(s.id) AS states,
         SUM(CASE WHEN m.id IS NULL THEN 1 ELSE 0 END) AS inherited
  FROM collection c
  JOIN overlay_item_state s ON s.collectionId = c.id
  LEFT JOIN collection_media m ON m.collectionId = c.id AND m.mediaServerId = s.mediaServerId
  GROUP BY c.id ORDER BY c.id`).all();
out.integrity = db.pragma("integrity_check", { simple: true });
console.log(JSON.stringify(out, null, 1));
JS
docker cp "$BACKUP/counts.js" "$MAINTAINERR:/tmp/counts.js"
docker exec "$MAINTAINERR" node /tmp/counts.js | tee "$BACKUP/counts-before.json"
```

`lastMigration` must be `MoveExclusionTagToServers1790456691255` (v3.30.2).
If it is older, production is not on v3.30.2: stop and rerun section 3
first, since the upgrade would also apply the releases in between.

### 4.3 Today's old-version overlay run

Let the scheduled overlay run finish, or press Run under Settings > Overlays.
Check that it finished today with `0 errors`
(`docker logs --since 6h "$MAINTAINERR" | grep "Overlay run complete"`).
From here until 4.10, everything happens before midnight.

### 4.4 Pause deletion and overlay runs

```bash
curl -fsS -X PATCH "$MAINTAINERR_URL/api/settings" -H 'Content-Type: application/json' \
  -d '{"collection_handler_job_cron":"0 4 1 1 *","rules_handler_job_cron":"0 4 1 1 *"}'
curl -fsS -X PUT "$MAINTAINERR_URL/api/overlays/settings" -H 'Content-Type: application/json' \
  -d '{"enabled":false}'
```

Both handlers now wait until 1 January; with the overlay feature off, no
overlay run does anything. The same settings are under Settings > Jobs and
Settings > Overlays. Confirm no handler is running before going on.

### 4.5 Stop, back up, and preserve every original

```bash
docker compose -f "$COMPOSE_FILE" stop "$MAINTAINERR"   # or: docker stop "$MAINTAINERR"
tar --numeric-owner -cpf "$BACKUP/services-maintainerr.tar" -C / services/maintainerr
tar --numeric-owner -cpf "$BACKUP/plexoverlays.tar" -C / mnt/plexoverlays
# A browsable copy of every original, which no Maintainerr run ever touches.
rsync -a "$ORIGINALS/" "$BACKUP/originals-preserved/"
(cd "$BACKUP/originals-preserved" && find . -name '*.jpg' -type f | sort | xargs sha256sum > ../originals-preserved.sha256)
find "$BACKUP/originals-preserved" -name '*.jpg' | wc -l | tee "$BACKUP/originals-before.count"
(cd "$BACKUP" && sha256sum *.tar > SHA256SUMS)
```

Keep `$BACKUP` until the new version has run for a week.

### 4.6 Change only the image

In `$COMPOSE_FILE`, change the `image:` line of the Maintainerr service to
`$NEW_IMAGE`; leave `volumes:`, `user:`, `environment:` and `ports:` as they
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
docker inspect -f '{{.State.Health.Status}}' "$MAINTAINERR"     # healthy
docker cp "$BACKUP/counts.js" "$MAINTAINERR:/tmp/counts.js"
docker exec "$MAINTAINERR" node /tmp/counts.js | tee "$BACKUP/counts-after.json"
```

Expected: `lastMigration` is `AddCollectionOverlayScope1792538934144`, every
collection shows `scope: all`, `integrity` is `ok`, and every count, and every
`states`/`inherited` figure, matches `counts-before.json`. Rules, collections
and settings in the UI look as before. If anything differs, stop and roll back
(section 5).

### 4.7 Pilot: one show collection

Pick a small show collection and note its `inherited` figure from
`counts-after.json`. Edit its rule, set **Overlay scope** to **Show only** and
save. Nothing is written yet: the overlay feature is still off.

Switch overlays back on with no schedule, so the only run is the one you
start, then start it:

```bash
curl -fsS -X PUT "$MAINTAINERR_URL/api/overlays/settings" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"cronSchedule":null}'
curl -fsS -X POST "$MAINTAINERR_URL/api/overlays/process" -H 'Content-Type: application/json' -d '{}'
docker logs -f "$MAINTAINERR" | grep --line-buffered -E "Overlay run complete|Failed to restore|reverting"
```

Expected summary: `0 applied, <inherited> reverted, ... 0 errors`. Any
`applied` count means a countdown changed since 4.3 (a run on a new day, or a
member added since); it is harmless, but check the date before going on.

### 4.8 Verify the pilot

```bash
docker logs --since 2h "$MAINTAINERR" > "$BACKUP/pilot.log" 2>&1
grep -c "Restored original poster for item" "$BACKUP/pilot.log"     # = inherited
grep -c "Failed to restore" "$BACKUP/pilot.log"                     # = 0
PLEX_URL=http://<plex>:32400 PLEX_TOKEN=<token> \
  python3 verify-restored-artwork.py "$BACKUP/originals-preserved" "$BACKUP/pilot.log"
find "$ORIGINALS" -maxdepth 1 -name '*.jpg' | wc -l                 # = before - inherited
docker exec "$MAINTAINERR" node /tmp/counts.js                       # its states = its members
```

`verify-restored-artwork.py` only sends GET requests to Plex. It reads each
restored item's artwork the way Maintainerr does and compares it with the
preserved original; it ends with `match=<n>` for every item. Open a few of
those seasons and episodes in Plex as well. A `Failed to restore` line keeps
that item's backup and state, and the next run retries it.

### 4.9 The remaining show collections, the same day

Set Overlay scope on each remaining show rule you want narrowed, then run
once more (the `POST /api/overlays/process` above) and verify as in 4.8. A
large library takes a while: each restore is several Plex requests. If it
cannot finish before midnight, leave the overlay feature off overnight
(`{"enabled":false}`) and only switch it back on after the last collection
is narrowed.

### 4.10 Resume normal operation

Restore the overlay schedule and the handler schedules you saved:

```bash
curl -fsS -X PUT "$MAINTAINERR_URL/api/overlays/settings" -H 'Content-Type: application/json' \
  -d '{"enabled":true,"cronSchedule":"<cronSchedule from overlay-settings.json>"}'
curl -fsS -X PATCH "$MAINTAINERR_URL/api/settings" -H 'Content-Type: application/json' \
  -d '{"collection_handler_job_cron":"<saved value>","rules_handler_job_cron":"<saved value>"}'
```

From the next day on, each overlay run uploads only the show posters of the
narrowed collections.

---

## 5. Rollback to the official v3.30.2

The previous image is kept as `maintainerr-rollback:pre-overlay-scope`, and
the database backup from 4.5 matches it.

```bash
docker compose -f "$COMPOSE_FILE" stop "$MAINTAINERR"
mv /services/maintainerr "/services/maintainerr.overlay-scope-$(date +%Y%m%d-%H%M%S)"
tar --numeric-owner -xpf "$BACKUP/services-maintainerr.tar" -C /
# Overlay originals: merge, never replace. A backup taken after the
# deployment belongs to artwork that may still carry an overlay, so it must
# survive; --ignore-existing keeps it and brings back every original the new
# version deleted after restoring it.
rsync -a --ignore-existing "$BACKUP/originals-preserved/" "$ORIGINALS/"
```

Set the `image:` line back to `maintainerr-rollback:pre-overlay-scope` (or
`$OFFICIAL_3_30_2`), then:

```bash
docker compose -f "$COMPOSE_FILE" up -d "$MAINTAINERR"
docker cp "$BACKUP/counts.js" "$MAINTAINERR:/tmp/counts.js"
docker exec "$MAINTAINERR" node /tmp/counts.js
```

The counts and `lastMigration` must match `counts-before.json` exactly. The
database backup was taken after the pause in 4.4, so put the schedules from
`settings.json` and `overlay-settings.json` back as in 4.10. Artwork the new
version restored stays original until the old version's next overlay run,
which draws on seasons and episodes again as it did before, from the merged
originals.
