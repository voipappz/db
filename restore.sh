#!/usr/bin/env bash
# Restore a backup.sh dump INTO a live database, from inside the container.
#
#   restore.sh --list [DB]           what backup.sh left, locally and in S3
#   restore.sh DB                    the newest dump of DB (S3 if configured, else local)
#   restore.sh DB NAME               DB-<stamp>.dump: from $BACKUP_DIR if there, else S3
#   restore.sh DB /path/to/x.dump    a file the container can read
#
# pg_restore --clean --if-exists overwrites DB's objects. It exits non-zero on
# spock extension stubs and on --clean of objects already gone, so the exit
# code is not the check — the caller verifies the data (see CLAUDE.md).
#
# An S3 dump is fetched into its own mktemp file, so a scheduled backup.sh
# running at the same moment can never touch the archive being restored.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
S3_PREFIX="${S3_PREFIX:-postgres}"
DB_USER="${DB_USER:-postgres}"

. "$(dirname "$0")/backup-s3.sh"

if [ "${1:-}" = "--list" ]; then
  db="${2:-}"
  echo "== $BACKUP_DIR/"
  ls -lh "$BACKUP_DIR"/${db:+$db-}*.dump 2>/dev/null || echo "   none"
  if s3_enabled; then
    echo "== $(s3_path "$db")/"
    rclone lsl --include '*.dump' "$(s3_path "$db")" | sort -k2,3
  fi
  exit 0
fi

db="${1:?usage: restore.sh DB [NAME|FILE] | --list [DB]}"
want="${2:-}"
[[ "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "invalid DB name: $db" >&2; exit 2; }

tmp=""
trap '[ -n "$tmp" ] && rm -f "$tmp"' EXIT
fetch() { tmp=$(mktemp /tmp/restore-XXXXXX.dump); rclone copyto "$(s3_path "$db/$1")" "$tmp"; src="$tmp"; }

if [ -n "$want" ] && [ -f "$want" ]; then
  src="$want"
elif [ -n "$want" ] && [ -f "$BACKUP_DIR/$want" ]; then
  src="$BACKUP_DIR/$want"
elif [ -n "$want" ] && s3_enabled; then
  fetch "$want"
elif [ -n "$want" ]; then
  echo "no such dump: $want (not a file, not in $BACKUP_DIR, S3 not configured)" >&2; exit 2
elif s3_enabled; then
  # Names carry a sortable UTC stamp, so the last is the newest.
  name=$(rclone lsf --include "$db-*.dump" "$(s3_path "$db")" | sort | tail -1)
  [ -n "$name" ] || { echo "no $db dump in $(s3_path "$db")" >&2; exit 2; }
  fetch "$name"
else
  src=$(ls "$BACKUP_DIR"/"$db"-*.dump 2>/dev/null | sort | tail -1 || true)
  [ -n "$src" ] || { echo "no $db dump in $BACKUP_DIR" >&2; exit 2; }
fi

pg_restore --list "$src" >/dev/null
echo "restoring ${name:-${want:-$src}} -> $db"
pg_restore -U "$DB_USER" -d "$db" --clean --if-exists "$src" || true
