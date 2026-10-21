#!/usr/bin/env bash
# Migrate a disposable copy of a Maintainerr database with the overlay scope
# test image, and report what changed.
#
# Safety:
# - It works on a second copy of DB_COPY in a fresh temporary directory, so
#   neither the production database nor DB_COPY itself is ever opened for
#   writing.
# - Every container runs with --network none: the copy holds the production
#   Plex, Radarr, Sonarr, Tautulli and Ombi URLs and keys, and this way it can
#   reach none of them, so it cannot delete media or touch artwork.
# - Nothing is published on a port, and no media or overlay originals are
#   mounted.
#
# Usage:
#   IMAGE=ghcr.io/buzera/maintainerr-overlay-scope:overlay-scope-test.1 \
#   DB_COPY=/root/maintainerr-dbcopy/maintainerr.sqlite \
#     ./test-db-copy-migration.sh
#
# Set KEEP=1 to keep the migrated copy for inspection.
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE to the overlay scope test image}"
DB_COPY="${DB_COPY:?set DB_COPY to a copy of maintainerr.sqlite (never the live file)}"

case "$(readlink -f "$DB_COPY")" in
  /services/maintainerr/*)
    echo "DB_COPY points into the production data directory. Copy it elsewhere first." >&2
    exit 1
    ;;
esac
[ -f "$DB_COPY" ] || { echo "No such file: $DB_COPY" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/maintainerr-dbcopy.XXXXXX")"
NAME="maintainerr-dbcopy-$$"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if [ "${KEEP:-0}" = "1" ]; then
    echo "Kept the migrated copy in $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

for suffix in "" "-wal" "-shm"; do
  if [ -f "${DB_COPY}${suffix}" ]; then
    cp "${DB_COPY}${suffix}" "$WORK/maintainerr.sqlite${suffix}"
  fi
done
chmod -R u+rwX "$WORK"
RUN_AS="$(id -u):$(id -g)"

# Table row counts, integrity, foreign keys and the overlay scope values,
# read with the image's own SQLite driver.
# shellcheck disable=SC2016 # JavaScript, expanded by node rather than the shell
STATS_JS='
const db = require("better-sqlite3")("/opt/data/maintainerr.sqlite");
db.pragma("wal_checkpoint(TRUNCATE)");
const tables = db
  .prepare("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ? ORDER BY name")
  .all("table", "sqlite_%")
  .map((row) => row.name);
const counts = {};
for (const table of tables) {
  counts[table] = db.prepare(`SELECT COUNT(*) AS c FROM "${table}"`).get().c;
}
const columns = db.prepare("SELECT name FROM pragma_table_info(?)").all("collection").map((row) => row.name);
console.log(JSON.stringify({
  counts,
  integrity: db.pragma("integrity_check", { simple: true }),
  foreignKeyViolations: db.pragma("foreign_key_check").length,
  lastMigration: db.prepare("SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1").get()?.name,
  overlayScopes: columns.includes("overlayScope")
    ? db.prepare("SELECT overlayScope AS scope, COUNT(*) AS c FROM collection GROUP BY overlayScope").all()
    : null,
}));
'
stats() {
  docker run --rm --network none --user "$RUN_AS" -v "$WORK:/opt/data" \
    -w /opt/app/apps/server --entrypoint node "$IMAGE" -e "$STATS_JS"
}

echo "== Before: $(basename "$DB_COPY") as it is now"
BEFORE="$(stats)"
echo "$BEFORE"

echo "== Booting $IMAGE on the copy, with no network"
docker run -d --name "$NAME" --network none --user "$RUN_AS" \
  -e TZ="${TZ:-UTC}" -v "$WORK:/opt/data" "$IMAGE" >/dev/null
status=starting
for _ in $(seq 1 120); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo gone)"
  [ "$status" = "healthy" ] || [ "$status" = "gone" ] && break
  sleep 5
done
docker logs "$NAME" > "$WORK/boot.log" 2>&1 || true
docker rm -f "$NAME" >/dev/null
echo "Health after boot: $status (log: boot.log in the work directory)"
grep -iE "migration|error" "$WORK/boot.log" | grep -viE "ENOTFOUND|EAI_AGAIN|ENETUNREACH|getaddrinfo" | tail -n 20 || true

echo "== After"
AFTER="$(stats)"
echo "$AFTER"

echo "== Verdict"
# shellcheck disable=SC2016 # JavaScript, expanded by node rather than the shell
docker run --rm --network none -e BEFORE="$BEFORE" -e AFTER="$AFTER" -e STATUS="$status" \
  --entrypoint node "$IMAGE" -e '
const before = JSON.parse(process.env.BEFORE);
const after = JSON.parse(process.env.AFTER);
let failed = 0;
const check = (label, ok, detail = "") => {
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  (" + detail + ")" : ""}`);
};
check("container became healthy", process.env.STATUS === "healthy", process.env.STATUS);
check("overlay scope migration is the newest applied", /^AddCollectionOverlayScope/.test(after.lastMigration ?? ""), after.lastMigration);
check("integrity_check ok", after.integrity === "ok", after.integrity);
check("no foreign key violations", after.foreignKeyViolations === 0, String(after.foreignKeyViolations));
const collections = after.counts.collection ?? 0;
const allScope = (after.overlayScopes ?? []).find((row) => row.scope === "all")?.c ?? 0;
check("every existing collection reads as all", allScope === collections, `${allScope}/${collections}`);
// What the migration must carry across untouched.
for (const table of ["collection", "collection_media", "rule_group", "rules", "exclusion", "overlay_item_state", "overlay_templates", "settings"]) {
  if (!(table in before.counts)) continue;
  check(`${table}: ${before.counts[table]} rows kept`, before.counts[table] === after.counts[table], `after: ${after.counts[table]}`);
}
const changed = Object.keys(after.counts).filter((t) => before.counts[t] !== after.counts[t]);
console.log(`Other tables whose row count changed during boot: ${changed.join(", ") || "none"}`);
console.log(failed === 0 ? "\nMIGRATION CHECK PASSED" : `\n${failed} CHECK(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
'
