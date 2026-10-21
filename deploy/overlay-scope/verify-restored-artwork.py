#!/usr/bin/env python3
"""Check that artwork Maintainerr reports as restored matches the saved original.

Read-only: it sends GET requests to Plex and reads files, nothing else. For
every item a log names in "Restored original poster for item <id>", it reads
the item's current artwork the same way Maintainerr does (the item's `thumb`,
with X-Plex-Token) and compares its SHA-256 with <preserved dir>/<id>.jpg, the
copy of the originals folder taken before the run.

Usage:
  PLEX_URL=http://127.0.0.1:32400 PLEX_TOKEN=... \\
    python3 verify-restored-artwork.py <preserved originals dir> <maintainerr log> [--sample N]

Exit status 0 when every checked item matches, 1 otherwise.
"""

import hashlib
import json
import os
import random
import sys
import urllib.request

MARKER = "Restored original poster for item "


def restored_ids(log_path):
    ids = []
    with open(log_path, encoding="utf-8", errors="replace") as log:
        for line in log:
            at = line.find(MARKER)
            if at == -1:
                continue
            item_id = line[at + len(MARKER):].strip().split()[0]
            if item_id and item_id not in ids:
                ids.append(item_id)
    return ids


def get(url, token, accept):
    request = urllib.request.Request(
        url, headers={"X-Plex-Token": token, "Accept": accept}, method="GET"
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def current_artwork(base, token, item_id):
    meta = json.loads(get(f"{base}/library/metadata/{item_id}", token, "application/json"))
    items = meta.get("MediaContainer", {}).get("Metadata") or []
    thumb = next((item.get("thumb") for item in items if item.get("thumb")), None)
    if not thumb:
        raise RuntimeError("no artwork")
    return get(thumb if thumb.startswith("http") else f"{base}{thumb}", token, "*/*")


def main():
    args = sys.argv[1:]
    sample = None
    if "--sample" in args:
        at = args.index("--sample")
        sample = int(args[at + 1])
        del args[at : at + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    preserved, log_path = args
    base = os.environ.get("PLEX_URL", "").rstrip("/")
    token = os.environ.get("PLEX_TOKEN", "")
    if not base or not token:
        print("Set PLEX_URL and PLEX_TOKEN")
        return 2

    ids = restored_ids(log_path)
    if sample is not None and sample < len(ids):
        ids = random.sample(ids, sample)
    print(f"Checking {len(ids)} restored item(s)")

    counts = {"match": 0, "differs": 0, "no-backup": 0, "error": 0}
    for item_id in ids:
        backup = os.path.join(preserved, f"{item_id}.jpg")
        if not os.path.isfile(backup):
            counts["no-backup"] += 1
            print(f"NO BACKUP  {item_id}")
            continue
        try:
            current = current_artwork(base, token, item_id)
        except Exception as error:  # report and carry on
            counts["error"] += 1
            print(f"ERROR      {item_id}: {error}")
            continue
        with open(backup, "rb") as original:
            expected = hashlib.sha256(original.read()).hexdigest()
        actual = hashlib.sha256(current).hexdigest()
        if actual == expected:
            counts["match"] += 1
        else:
            counts["differs"] += 1
            print(f"DIFFERS    {item_id}: open it in Plex and compare by eye")

    print(" ".join(f"{name}={count}" for name, count in counts.items()))
    return 0 if counts["match"] == len(ids) else 1


if __name__ == "__main__":
    sys.exit(main())
