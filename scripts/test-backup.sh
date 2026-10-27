#!/usr/bin/env bash
# backup.sh / restore.sh end to end, inside the image, against a real MinIO:
#   - a row written before the backup comes back from S3 (newest), from S3 by
#     timestamp, from the local copy, and from a GPG-encrypted S3 copy;
#   - names are <db>_<YYYY-MM-DDTHH:MM:SS>.dump, the dump is a valid archive
#     without spock, and no .part is left;
#   - retention prunes a stale local dump AND a stale S3 object;
#   - restore.sh --list shows both copies.
#
#   scripts/test-backup.sh                       # image ghcr.io/voipappz/db:pgedge
#   IMAGE=ghcr.io/voipappz/db:x scripts/test-backup.sh
#   KEEP=1 scripts/test-backup.sh                # leave it up to look at
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/voipappz/db:pgedge}"
MINIO_IMAGE="${MINIO_IMAGE:-cgr.dev/chainguard/minio:latest}"
NET=db-backup-test
PG=db-backup-test-pg
MI=db-backup-test-minio
S3_ENV=(-e S3_BUCKET=backup -e S3_ENDPOINT=http://$MI:9000 -e S3_PREFIX=postgres
        -e S3_ACCESS_KEY_ID=backuptest -e S3_SECRET_ACCESS_KEY=backuptest-secret-2026)
SCRIPTS=/home/pgedge/scripts
STALE=voipappz_2000-01-01T00:00:00.dump

fail() { echo "FAIL: $*"; exit 1; }
q() { docker exec "$PG" psql -U postgres -d "$1" -tAc "$2"; }
run() { docker exec -u root "${S3_ENV[@]}" -e BACKUP_KEEP_DAYS=1 "$PG" "$@"; }
# rclone with the remote the scripts configure (backup-s3.sh), not its own.
s3() { run bash -c ". $SCRIPTS/backup-s3.sh && $*"; }
probe() { [ "$(q voipappz "SELECT count(*) FROM backup_probe WHERE note='round-trip';")" = 1 ] || fail "row not back after $1"; }

cleanup() {
  rc=$?
  [ $rc -ne 0 ] && { echo "── $PG"; docker logs --tail 40 "$PG" 2>&1 || true; }
  [ -n "${KEEP:-}" ] && { echo "KEEP=1: $PG and $MI left up"; return; }
  docker rm -f "$PG" "$MI" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$PG" "$MI" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true

echo ">> minio + one node of $IMAGE"
docker network create "$NET" >/dev/null
docker run -d --name "$MI" --network "$NET" \
  -e MINIO_ROOT_USER=backuptest -e MINIO_ROOT_PASSWORD=backuptest-secret-2026 \
  "$MINIO_IMAGE" server /data >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e NODE_NAME=test -e PEER_NAME=none -e DB_USER=postgres \
  -e POSTGRES_PASSWORD=BackupTest-Pg2026 -e DATABASES="voipappz" -e DB_NAME=voipappz \
  "$IMAGE" >/dev/null
for i in $(seq 1 120); do
  docker exec "$PG" test -f /tmp/init-complete 2>/dev/null && { echo "   ready after ${i}s"; break; }
  [ "$i" -eq 120 ] && fail "node not ready after 120s"
  sleep 1
done
# The bucket is the store owner's job (mothership: createbuckets), not backup.sh's.
for i in $(seq 1 30); do
  s3 "rclone mkdir --s3-no-check-bucket=false s3:backup" 2>/dev/null && break
  [ "$i" -eq 30 ] && { s3 "rclone mkdir --s3-no-check-bucket=false s3:backup" || true; fail "minio never accepted the bucket"; }
  sleep 1
done

echo ">> a row the dump must carry, and stale dumps the sweep must remove"
q voipappz "CREATE TABLE backup_probe (id int PRIMARY KEY, note text); INSERT INTO backup_probe VALUES (1, 'round-trip');" >/dev/null
run bash -c "touch -d '3 days ago' /backups/$STALE"
# rclone keeps the file's mtime as object metadata, which --min-age reads.
s3 "touch -d '3 days ago' /tmp/old.dump && rclone copyto /tmp/old.dump s3:backup/postgres/$STALE"

echo ">> backup.sh"
run "$SCRIPTS/backup.sh" | sed 's/^/   /'
name=$(docker exec "$PG" sh -c 'ls /backups' | grep -E '^voipappz_[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.dump$' | grep -v 2000-01-01 | sort | tail -1)
[ -n "$name" ] || fail "no voipappz_<timestamp>.dump written"
ts=${name#voipappz_}; ts=${ts%.dump}
docker exec "$PG" sh -c 'ls /backups/*.part' 2>/dev/null && fail ".part left behind"
docker exec "$PG" test -e "/backups/$STALE" && fail "stale local dump not pruned"
objs=$(s3 "rclone lsf s3:backup/postgres")
echo "$objs" | grep -qx "$name" || fail "$name not uploaded (have: $objs)"
echo "$objs" | grep -q 2000-01-01 && fail "stale S3 object not pruned"
toc=$(docker exec "$PG" pg_restore --list "/backups/$name")
echo "$toc" | grep -q backup_probe || fail "dump has no backup_probe"
echo "$toc" | grep -qi 'SCHEMA - spock\|spock\.' && fail "dump carries spock objects"

echo ">> restore.sh --list"
list=$(run "$SCRIPTS/restore.sh" --list voipappz)
echo "$list" | sed 's/^/   /'
[ "$(echo "$list" | grep -c "$name")" = 2 ] || fail "--list does not show $name in both copies"

echo ">> restore.sh voipappz (newest, from S3)"
q voipappz "DROP TABLE backup_probe;" >/dev/null
run "$SCRIPTS/restore.sh" voipappz 2>&1 | sed 's/^/   /'
probe "S3 newest restore"

echo ">> restore.sh voipappz $ts (from S3 by timestamp: local copy removed)"
run rm "/backups/$name"
q voipappz "DROP TABLE backup_probe;" >/dev/null
run "$SCRIPTS/restore.sh" voipappz "$ts" 2>&1 | sed 's/^/   /'
probe "S3 timestamp restore"

echo ">> PASSPHRASE: the S3 copy is .dump.gpg and restores with the passphrase"
run rm -f /backups/*.dump
docker exec -u root "${S3_ENV[@]}" -e PASSPHRASE=ci-gpg-passphrase "$PG" "$SCRIPTS/backup.sh" | sed 's/^/   /'
gpg_obj=$(s3 "rclone lsf --include 'voipappz_*.dump.gpg' s3:backup/postgres" | sort | tail -1)
[ -n "$gpg_obj" ] || fail "no .dump.gpg object with PASSPHRASE set"
s3 "rclone cat s3:backup/postgres/$gpg_obj" | head -c 5 | grep -q PGDMP && fail "$gpg_obj is not encrypted"
run rm -f /backups/*.dump   # force the S3 path
q voipappz "DROP TABLE backup_probe;" >/dev/null
docker exec -u root "${S3_ENV[@]}" -e PASSPHRASE=ci-gpg-passphrase "$PG" "$SCRIPTS/restore.sh" voipappz 2>&1 | sed 's/^/   /'
probe "encrypted S3 restore"

echo ">> restore.sh voipappz <ts> (local copy, S3 off)"
docker exec -u root "$PG" "$SCRIPTS/backup.sh" | sed 's/^/   /'
local_name=$(docker exec "$PG" sh -c 'ls /backups' | grep '^voipappz_' | sort | tail -1)
lts=${local_name#voipappz_}; lts=${lts%.dump}
q voipappz "DROP TABLE backup_probe;" >/dev/null
docker exec -u root "$PG" "$SCRIPTS/restore.sh" voipappz "$lts" 2>&1 | sed 's/^/   /'
probe "local restore"

echo "PASS: dated dumps locally and in MinIO (plain and gpg), both pruned; restore by newest, timestamp, local"
