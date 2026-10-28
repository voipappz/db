#!/usr/bin/env bash
# Back up this node's databases from INSIDE the container, modelled on
# eeshugerman/postgres-backup-s3 (the tool mothership used to run beside it):
# a dated pg_dump per database, uploaded to S3/MinIO, optionally GPG-encrypted,
# old copies pruned. Unlike it, this runs where postgres runs (socket, no
# password), keeps a local copy in $BACKUP_DIR, and works in a fresh file per run.
#
# Scheduled by whoever runs the container — on a mothership node, an Ofelia
# job-exec label on the postgres service; here, `make backup`.
#
#   BACKUP_DIR            /backups            mount a volume or bind dir here
#   BACKUP_DATABASES      $DATABASES          space-separated
#   BACKUP_KEEP_DAYS      14                  both copies; empty = keep forever
#   S3_BUCKET             (unset = local only)
#   S3_ENDPOINT           e.g. http://minio:9000 (unset = AWS)
#   S3_PREFIX             postgres
#   S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY / S3_REGION (us-east-1)
#   PASSPHRASE            set = the S3 copy is gpg --symmetric (.dump.gpg)
#
# Names: <db>_<UTC YYYY-MM-DDTHH:MM:SS>.dump, locally and at s3://<bucket>/<prefix>/
# — upstream's scheme, so `restore.sh <db> <timestamp>` finds either copy and
# objects upstream already wrote stay restorable.
#
# Dumps exclude spock (-N spock): its metadata is rebuilt, never restored.
# Each dump is written to a unique .part, validated with pg_restore --list, then renamed,
# so a half-written file never looks like the newest good backup.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_DATABASES="${BACKUP_DATABASES:-${DATABASES:-voipappz}}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS-14}"
DB_USER="${DB_USER:-postgres}"

[[ -z "$BACKUP_KEEP_DAYS" || "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] \
  || { echo "BACKUP_KEEP_DAYS must be a whole number of days" >&2; exit 2; }

. "$(dirname "$0")/backup-s3.sh"

backup_lock   # backup-s3.sh: one backup/restore at a time
mkdir -p "$BACKUP_DIR"
# Only a crashed run's leftovers: a fresh .part may be another run's work.
find "$BACKUP_DIR" -maxdepth 1 -name '*.part' -mmin +1440 -delete

timestamp=$(date -u +%Y-%m-%dT%H:%M:%S)
# Names are per-second; never reuse one a previous run in this second took.
while ls "$BACKUP_DIR"/*_"$timestamp".dump >/dev/null 2>&1; do
  sleep 1; timestamp=$(date -u +%Y-%m-%dT%H:%M:%S)
done
for db in $BACKUP_DATABASES; do
  echo "Creating backup of $db database..."
  final="$BACKUP_DIR/${db}_${timestamp}.dump"
  part=$(mktemp "$final.XXXXXX.part")
  chmod 644 "$part"   # mktemp makes it 600; dumps stay readable as before
  pg_dump -U "$DB_USER" -d "$db" -N spock --format=custom -f "$part"
  pg_restore --list "$part" >/dev/null
  mv "$part" "$final"
  echo "backup ready: $final ($(du -h "$final" | cut -f1))"

  if s3_enabled; then
    src="$final" key="$(basename "$final")"
    if [ -n "${PASSPHRASE:-}" ]; then
      src=$(mktemp /tmp/backup-XXXXXX.dump.gpg)
      gpg --symmetric --batch --yes --passphrase "$PASSPHRASE" -o "$src" "$final"
      key="$key.gpg"
    fi
    rclone copyto "$src" "$(s3_path "$key")"
    [ "$src" = "$final" ] || rm -f "$src"
    echo "uploaded: $(s3_path "$key")"
  fi
done
echo "Backup complete."

if [ -n "$BACKUP_KEEP_DAYS" ]; then
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -mtime "+$BACKUP_KEEP_DAYS" -print -delete \
    | sed 's/^/pruned: /'
  if s3_enabled; then
    rclone delete --min-age "${BACKUP_KEEP_DAYS}d" --include '*.dump' --include '*.dump.gpg' -v "$(s3_path)" 2>&1 \
      | sed -n 's/.*INFO  : \(.*\): Deleted$/pruned from s3: \1/p'
  fi
fi
