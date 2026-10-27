#!/usr/bin/env bash
# Back up this node's databases from INSIDE the container: pg_dump over the
# local socket into $BACKUP_DIR, then (when S3_BUCKET is set) copy each dump to
# S3/MinIO. Retention prunes both copies after $BACKUP_KEEP_DAYS.
#
# Scheduled by whoever runs the container — on a mothership node, an Ofelia
# job-exec label on the postgres service; here, `make backup`. Nothing else is
# needed: pg_dump and rclone ship in this image.
#
#   BACKUP_DIR            /backups            mount a volume or bind dir here
#   BACKUP_DATABASES      $DATABASES          space-separated
#   BACKUP_KEEP_DAYS      14
#   S3_BUCKET             (unset = local only)
#   S3_ENDPOINT           e.g. http://minio:9000 (unset = AWS)
#   S3_PREFIX             postgres            objects: <prefix>/<db>/<db>-<stamp>.dump
#   S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY / S3_REGION (us-east-1)
#
# Dumps exclude spock (-N spock): its metadata is rebuilt, never restored.
# Each dump is written as .part, validated with pg_restore --list, then renamed,
# so a half-written file never looks like the newest good backup.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_DATABASES="${BACKUP_DATABASES:-${DATABASES:-voipappz}}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
S3_PREFIX="${S3_PREFIX:-postgres}"
DB_USER="${DB_USER:-postgres}"

[[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || { echo "BACKUP_KEEP_DAYS must be a whole number of days" >&2; exit 2; }

. "$(dirname "$0")/backup-s3.sh"

mkdir -p "$BACKUP_DIR"
rm -f "$BACKUP_DIR"/*.dump.part

stamp=$(date -u +%Y%m%d-%H%M%S)
for db in $BACKUP_DATABASES; do
  part="$BACKUP_DIR/$db-$stamp.dump.part"
  final="${part%.part}"
  pg_dump -U "$DB_USER" -d "$db" -N spock -Fc -f "$part"
  pg_restore --list "$part" >/dev/null
  mv "$part" "$final"
  echo "backup ready: $final ($(du -h "$final" | cut -f1))"
  if s3_enabled; then
    rclone copyto "$final" "$(s3_path "$db/$(basename "$final")")"
    echo "uploaded: $(s3_path "$db/$(basename "$final")")"
  fi
done

find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -mtime "+$BACKUP_KEEP_DAYS" -print -delete \
  | sed 's/^/pruned: /'
if s3_enabled; then
  rclone delete --min-age "${BACKUP_KEEP_DAYS}d" --include '*.dump' -v "$(s3_path)" 2>&1 \
    | sed -n 's/.*INFO  : \(.*\): Deleted$/pruned from s3: \1/p'
fi
