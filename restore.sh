#!/usr/bin/env bash
# Restore a backup.sh dump over a database, from inside the container.
# Same interface as eeshugerman/postgres-backup-s3's restore.sh: no timestamp
# means the newest, a timestamp names one.
#
#   restore.sh --list [DB]           what backup.sh left, locally and in S3
#   restore.sh DB                    newest dump of DB (S3 if configured, else local)
#   restore.sh DB 2026-10-27T03:00:00  that one: $BACKUP_DIR first, then S3
#   restore.sh DB /path/to/x.dump    a file the container can read
#
# NOTHING LIVE IS TOUCHED UNTIL THE RESTORE HAS SUCCEEDED:
#   1. the dump goes into a NEW database, <db>__restore_<ts>, with
#      timescaledb_pre_restore()/post_restore() around it when it has
#      TimescaleDB — any pg_restore error fails the run and drops that database;
#   2. the two databases swap names in one transaction, with connections to
#      <db> blocked and terminated first (the app reconnects to the new one);
#   3. the old database — exact up to the swap, writes made during the restore
#      included — is dumped to pre-restore_<db>_<ts>.dump (and S3), then dropped.
#      Undo with `restore.sh DB /backups/pre-restore_<db>_<ts>.dump`.
#      KEEP_OLD=1 keeps it as <db>_pre_restore_<ts> instead.
#
# Restoring in place with pg_restore --clean (what this did before) destroyed
# data before knowing the restore worked: a crash mid-restore left the live
# database empty. The new database has no Spock: restart the container
# afterwards and init-node.sh attaches it again (mothership's db-restore does).
# A node with Spock PEERS is refused — restoring one side of an active-active
# pair is a cluster operation, not this script.
#
# PASSPHRASE decrypts a .dump.gpg object. Backup and restore share one lock, so
# a scheduled backup never runs against a half-swapped database.
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

backup_lock   # backup-s3.sh: waits for a running backup.sh / restore.sh

stamp=$(date -u +%Y%m%dT%H%M%S)
new="${db}__restore_${stamp}"
old="${db}_pre_restore_${stamp}"
tmp=$(mktemp -d /tmp/restore-XXXXXX)
swapped=""
blocked=""

sql() { psql -U "$DB_USER" -d "$1" -v ON_ERROR_STOP=1 -qtAc "$2"; }
db_exists() { [ "$(sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = 1 ]; }

cleanup() {
  rc=$?
  if [ -z "$swapped" ] && db_exists "$new" 2>/dev/null; then
    echo "Restore failed: dropping $new; $db was not touched." >&2
    sql postgres "DROP DATABASE \"$new\" WITH (FORCE)" || echo "could not drop $new: drop it by hand" >&2
  fi
  if [ -z "$swapped" ] && [ -n "$blocked" ]; then
    sql postgres "ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS true" || echo "$db REFUSES CONNECTIONS: run ALTER DATABASE $db WITH ALLOW_CONNECTIONS true" >&2
  fi
  rm -rf "$tmp"
  exit $rc
}
trap cleanup EXIT

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
# Listings are captured whole and filtered afterwards: a consumer that stops
# reading early (grep -q, head) SIGPIPEs the producer, and pipefail turns that
# into a false result — which once skipped timescaledb_pre_restore().
s3_keys() { local all; all=$(rclone lsf --include "$1.dump" --include "$1.dump.gpg" "$(s3_path)"); sort <<<"$all"; }

if [ -n "$want" ] && [ -f "$want" ]; then
  src="$want"
elif [ -n "$want" ] && [ -f "$BACKUP_DIR/${db}_${want}.dump" ]; then
  src="$BACKUP_DIR/${db}_${want}.dump"
elif [ -n "$want" ] && s3_enabled; then
  key=$(s3_keys "${db}_${want}"); key=${key%%$'\n'*}
  [ -n "$key" ] || { echo "no ${db}_${want} dump locally or in $(s3_path)" >&2; exit 2; }
  fetch "$key"
elif [ -n "$want" ]; then
  echo "no such dump: $want (not a file, not ${db}_${want}.dump in $BACKUP_DIR, S3 not configured)" >&2; exit 2
elif s3_enabled; then
  echo "Finding latest backup..."
  # Names carry a sortable UTC timestamp, so the last is the newest.
  key=$(s3_keys "${db}_*"); key=${key##*$'\n'}
  [ -n "$key" ] || { echo "no $db dump in $(s3_path)" >&2; exit 2; }
  fetch "$key"
else
  src=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${db}_*.dump" | sort | tail -1)
  [ -n "$src" ] || { echo "no $db dump in $BACKUP_DIR" >&2; exit 2; }
fi

toc=$(pg_restore --list "$src")

# Two queries: postgres resolves spock.subscription at parse time even inside a
# CASE, so one query errors on a database without Spock (e.g. just restored).
# If the count query itself fails, the comparison refuses — the safe side.
if db_exists "$db" && [ "$(sql "$db" "SELECT to_regclass('spock.subscription') IS NOT NULL")" = t ] \
   && [ "$(sql "$db" "SELECT count(*) FROM spock.subscription")" != 0 ]; then
  echo "$db has Spock subscriptions (an active-active peer): refusing. Restore the cluster, not one node." >&2
  exit 2
fi

# The dump excludes the spock schema but still lists `CREATE EXTENSION spock`
# and its comment; those are the only entries skipped. Everything else must
# restore, so pg_restore runs with --exit-on-error and its status counts.
grep -vE ' (EXTENSION|COMMENT) - (EXTENSION )?spock( |$)' <<<"$toc" > "$tmp/toc.list"

echo "Restoring $(basename "$src") into new database $new..."
sql postgres "CREATE DATABASE \"$new\""
timescale=""
if grep -qE ' EXTENSION - timescaledb( |$)' <<<"$toc"; then
  # A plain pg_restore of hypertable chunks segfaults the backend (seen on a
  # real voipappz dump). This is the documented sequence. Only $new is ever in
  # restoring mode, and a failure drops it.
  timescale=1
  sql "$new" "CREATE EXTENSION IF NOT EXISTS timescaledb" >/dev/null
  sql "$new" "SELECT timescaledb_pre_restore()" >/dev/null
fi
pg_restore -U "$DB_USER" -d "$new" -L "$tmp/toc.list" --exit-on-error "$src"
if [ -n "$timescale" ]; then
  sql "$new" "SELECT timescaledb_post_restore()" >/dev/null
  # post_restore sets the database default; a new session must see it off.
  [ "$(sql "$new" "SHOW timescaledb.restoring")" = off ] || { echo "$new still in timescaledb restoring mode" >&2; exit 1; }
fi
# Every table the dump defines must exist in the new database.
want_tables=$(awk '$4 == "TABLE" && $5 != "DATA" {print $5 "." $6}' "$tmp/toc.list" | sort -u)
have_tables=$(sql "$new" "SELECT schemaname || '.' || tablename FROM pg_tables" | sort -u)
missing=$(comm -23 <(echo "$want_tables") <(echo "$have_tables"))
[ -z "$missing" ] || { echo "tables missing after restore: $missing" >&2; exit 1; }
echo "Restored $(grep -c . <<<"$want_tables") tables into $new."

echo "Swapping $new in as $db..."
if db_exists "$db"; then
  blocked=1
  sql postgres "ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS false"
  for i in $(seq 1 20); do
    sql postgres "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" >/dev/null
    # Both renames in one transaction: either both happen or neither.
    if sql postgres "BEGIN; ALTER DATABASE \"$db\" RENAME TO \"$old\"; ALTER DATABASE \"$new\" RENAME TO \"$db\"; COMMIT;" 2>/dev/null; then
      swapped=1; break
    fi
    sleep 0.5
  done
  if [ -z "$swapped" ]; then
    echo "could not close every connection to $db: nothing swapped, $db untouched" >&2
    exit 1
  fi
  sql postgres "ALTER DATABASE \"$old\" WITH ALLOW_CONNECTIONS true"
else
  sql postgres "ALTER DATABASE \"$new\" RENAME TO \"$db\""
  swapped=1; old=""
fi
echo "Swapped: $db is the restored database."

if [ -n "$old" ]; then
  # Exact final state of what was replaced. A unique temp name: a concurrent
  # run can never write or delete this file under us.
  safety="$BACKUP_DIR/pre-restore_${db}_$(date -u +%Y-%m-%dT%H:%M:%S).dump"
  while [ -e "$safety" ]; do sleep 1; safety="$BACKUP_DIR/pre-restore_${db}_$(date -u +%Y-%m-%dT%H:%M:%S).dump"; done
  part=$(mktemp "$safety.XXXXXX.part")
  chmod 644 "$part"   # mktemp makes it 600; like backup.sh's dumps
  echo "Saving the replaced database to $safety..."
  if pg_dump -U "$DB_USER" -d "$old" -N spock --format=custom -f "$part" && pg_restore --list "$part" >/dev/null; then
    mv "$part" "$safety"
    if s3_enabled; then
      rclone copyto "$safety" "$(s3_path "$(basename "$safety")")"
      echo "uploaded: $(s3_path "$(basename "$safety")")"
    fi
    if [ -n "${KEEP_OLD:-}" ]; then
      echo "KEEP_OLD: the replaced database stays as $old"
    else
      sql postgres "DROP DATABASE \"$old\" WITH (FORCE)"
    fi
  else
    rm -f "$part"
    echo "SAFETY DUMP FAILED: the replaced database is kept as $old — dump or drop it by hand" >&2
    exit 1
  fi
fi

echo "Restore complete. Restart the container to re-attach Spock to $db."
