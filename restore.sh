#!/usr/bin/env bash
# Restore a backup.sh dump INTO a live database, from inside the container.
# Same interface as eeshugerman/postgres-backup-s3's restore.sh: no timestamp
# means the newest, a timestamp names one.
#
#   restore.sh --list [DB]           what backup.sh left, locally and in S3
#   restore.sh DB                    newest dump of DB (S3 if configured, else local)
#   restore.sh DB 2026-10-27T03:00:00  that one: $BACKUP_DIR first, then S3
#   restore.sh DB /path/to/x.dump    a file the container can read
#
# Before overwriting, the live DB is dumped to pre-restore_<db>_<ts>.dump (and
# to S3) — undo a restore with `restore.sh DB /backups/pre-restore_<db>_<ts>.dump`.
#
# PASSPHRASE decrypts a .dump.gpg object. pg_restore --clean --if-exists
# overwrites DB's objects; it exits non-zero on spock extension stubs and on
# --clean of objects already gone, so the exit code is not the check — the
# caller verifies the data (see CLAUDE.md).
#
# Upstream fetches into ./db.dump, shared with backup.sh — a scheduled backup
# landing mid-restore corrupted the archive. Here every fetch is its own mktemp.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
DB_USER="${DB_USER:-postgres}"

. "$(dirname "$0")/backup-s3.sh"

if [ "${1:-}" = "--list" ]; then
  db="${2:-}"
  echo "== $BACKUP_DIR/"
  # One find, not ls of two globs: ls exits 2 when either glob is empty, which
  # printed "none" under a non-empty listing.
  found=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "${db:-*}_*.dump" -o -name "pre-restore_${db:-*}_*.dump" \) | sort)
  if [ -n "$found" ]; then echo "$found" | xargs ls -lh; else echo "   none"; fi
  if s3_enabled; then
    echo "== $(s3_path)/"
    rclone lsl --include "${db:-*}_*.dump" --include "${db:-*}_*.dump.gpg" --include "pre-restore_${db:-*}_*.dump" "$(s3_path)" | sort -k4
  fi
  exit 0
fi

db="${1:?usage: restore.sh DB [TIMESTAMP|FILE] | --list [DB]}"
want="${2:-}"
[[ "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "invalid DB name: $db" >&2; exit 2; }

tmp=$(mktemp -d /tmp/restore-XXXXXX)
trap 'rm -rf "$tmp"' EXIT

fetch() {  # $1 = object key under the prefix
  echo "Fetching $(s3_path "$1")..."
  rclone copyto "$(s3_path "$1")" "$tmp/$1"
  src="$tmp/$1"
  if [[ "$src" == *.gpg ]]; then
    [ -n "${PASSPHRASE:-}" ] || { echo "$1 is encrypted: set PASSPHRASE" >&2; exit 2; }
    echo "Decrypting backup..."
    gpg --decrypt --batch --passphrase "$PASSPHRASE" -o "${src%.gpg}" "$src"
    src="${src%.gpg}"
  fi
}
newest_s3() {
  rclone lsf --include "${db}_*.dump" --include "${db}_*.dump.gpg" "$(s3_path)" | sort | tail -1
}

if [ -n "$want" ] && [ -f "$want" ]; then
  src="$want"
elif [ -n "$want" ] && [ -f "$BACKUP_DIR/${db}_${want}.dump" ]; then
  src="$BACKUP_DIR/${db}_${want}.dump"
elif [ -n "$want" ] && s3_enabled; then
  key=$(rclone lsf --include "${db}_${want}.dump" --include "${db}_${want}.dump.gpg" "$(s3_path)" | head -1)
  [ -n "$key" ] || { echo "no ${db}_${want} dump locally or in $(s3_path)" >&2; exit 2; }
  fetch "$key"
elif [ -n "$want" ]; then
  echo "no such dump: $want (not a file, not ${db}_${want}.dump in $BACKUP_DIR, S3 not configured)" >&2; exit 2
elif s3_enabled; then
  echo "Finding latest backup..."
  # Names carry a sortable UTC timestamp, so the last is the newest.
  key=$(newest_s3)
  [ -n "$key" ] || { echo "no $db dump in $(s3_path)" >&2; exit 2; }
  fetch "$key"
else
  src=$(ls "$BACKUP_DIR"/"${db}"_*.dump 2>/dev/null | sort | tail -1 || true)
  [ -n "$src" ] || { echo "no $db dump in $BACKUP_DIR" >&2; exit 2; }
fi

pg_restore --list "$src" >/dev/null

# Keep what is about to be overwritten. Named pre-restore_<db>_<ts> so "newest
# <db>_*" never picks it; pruned on the same BACKUP_KEEP_DAYS as backup.sh's.
# A failed safety dump aborts the restore (set -e).
# Names are per-second: two restores in one second must not share (and so
# overwrite) one safety copy.
safety="$BACKUP_DIR/pre-restore_${db}_$(date -u +%Y-%m-%dT%H:%M:%S).dump"
while [ -e "$safety" ]; do
  sleep 1
  safety="$BACKUP_DIR/pre-restore_${db}_$(date -u +%Y-%m-%dT%H:%M:%S).dump"
done
echo "Saving current $db to $safety..."
mkdir -p "$BACKUP_DIR"
pg_dump -U "$DB_USER" -d "$db" -N spock --format=custom -f "$safety.part"
pg_restore --list "$safety.part" >/dev/null
mv "$safety.part" "$safety"
if s3_enabled; then
  rclone copyto "$safety" "$(s3_path "$(basename "$safety")")"
  echo "uploaded: $(s3_path "$(basename "$safety")")"
fi

# TimescaleDB: a plain pg_restore of hypertable chunks segfaults the backend
# and takes the whole server through crash recovery (seen on a real voipappz
# dump: COPY _timescaledb_internal._hyper_1_1_chunk). The documented sequence
# is timescaledb_pre_restore() before and timescaledb_post_restore() after;
# post_restore runs from the trap too, so a failed restore never leaves the
# database in restoring mode with its background workers stopped.
psql_db() { psql -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 -qtAc "$1"; }
timescale=""
if pg_restore --list "$src" | grep -qE ' EXTENSION - timescaledb( |$)'; then
  timescale=1
  psql_db "CREATE EXTENSION IF NOT EXISTS timescaledb" >/dev/null
  psql_db "SELECT timescaledb_pre_restore()" >/dev/null
  trap 'psql_db "SELECT timescaledb_post_restore()" >/dev/null || echo "timescaledb_post_restore() FAILED on $db: run it by hand" >&2; rm -rf "$tmp"' EXIT
  echo "TimescaleDB: pre_restore done; post_restore runs when this exits"
fi

echo "Restoring $(basename "$src") into $db..."
pg_restore -U "$DB_USER" -d "$db" --clean --if-exists "$src" || true
echo "Restore complete."
