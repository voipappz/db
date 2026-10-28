#!/usr/bin/env bash
# backup.sh / restore.sh end to end, inside the image, against a real MinIO:
#   - a row written before the backup comes back from S3 (newest), from S3 by
#     timestamp, from the local copy, and from a GPG-encrypted S3 copy;
#   - names are <db>_<YYYY-MM-DDTHH:MM:SS>.dump, the dump is a valid archive
#     without spock, and no .part is left;
#   - retention prunes a stale local dump AND a stale S3 object;
#   - every restore first keeps the existing database as pre-restore_<db>_<ts>.dump;
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
probe() {
  [ "$(q voipappz "SELECT count(*) FROM backup_probe WHERE note='round-trip';")" = 1 ] || fail "row not back after $1"
  [ "$(q voipappz "SELECT count(*) FROM ts_probe;")" = 40 ] || fail "hypertable rows not back after $1"
  [ "$(q voipappz "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='ts_probe';")" = 1 ] || fail "ts_probe is no longer a hypertable after $1"
  # post_restore ran: the database is out of restoring mode.
  [ "$(q voipappz "SHOW timescaledb.restoring;")" = off ] || fail "voipappz left in timescaledb restoring mode after $1"
  docker logs "$PG" 2>&1 | grep -q 'Segmentation fault' && fail "postgres segfaulted during $1"
  return 0
}

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
# A hypertable with chunks: restoring one without timescaledb_pre_restore()
# segfaulted a real node's postgres. probe() checks these rows come back too.
q voipappz "CREATE EXTENSION IF NOT EXISTS timescaledb;
            CREATE TABLE ts_probe (at timestamptz NOT NULL, v int);
            SELECT create_hypertable('ts_probe', 'at', chunk_time_interval => interval '1 day');
            INSERT INTO ts_probe SELECT now() - i * interval '6 hours', i FROM generate_series(1, 40) i;" >/dev/null
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
# The state just before that restore (no backup_probe) was kept, locally and in S3.
safety=$(docker exec "$PG" sh -c 'ls /backups' | grep '^pre-restore_voipappz_' | sort | tail -1)
[ -n "$safety" ] || fail "restore did not keep a pre-restore dump of the existing database"
docker exec "$PG" pg_restore --list "/backups/$safety" | grep -q backup_probe && fail "$safety is not the pre-restore state"
s3 "rclone lsf s3:backup/postgres" | grep -qx "$safety" || fail "$safety not uploaded"

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

echo ">> the Makefile: make backup / backup-list / backup-restore drive the same scripts"
# Every S3 value on the command line, so a local .env (which the Makefile
# -includes) cannot point this at a real bucket.
mk() { make -s -C "$(dirname "$0")/.." "$@" NODE="$PG" DATABASES=voipappz BACKUP_KEEP_DAYS=1 \
  S3_BUCKET=backup S3_ENDPOINT="http://$MI:9000" S3_PREFIX=postgres S3_REGION=us-east-1 \
  S3_ACCESS_KEY_ID=backuptest S3_SECRET_ACCESS_KEY=backuptest-secret-2026; }
before=$(s3 "rclone lsf --include 'voipappz_*.dump' s3:backup/postgres" | sort | tail -1)
sleep 1   # names are per-second; the make run must produce a new one
mk backup | sed 's/^/   /'
made=$(s3 "rclone lsf --include 'voipappz_*.dump' s3:backup/postgres" | sort | tail -1)
[ -n "$made" ] && [ "$made" != "$before" ] || fail "make backup uploaded nothing new (newest: $made)"
listed=$(mk backup-list DB=voipappz)   # not piped into grep -q: SIGPIPE + pipefail
echo "$listed" | grep -q "$made" || fail "make backup-list does not show $made"
mk backup-restore DB=voipappz 2>/dev/null && fail "make backup-restore ran without FORCE=1"
q voipappz "DROP TABLE backup_probe;" >/dev/null
# A TS in the environment must not choose the dump (WSL exports NAME this way).
TS=bogus mk backup-restore FORCE=1 DB=voipappz 2>&1 | sed 's/^/   /'
probe "make backup-restore (newest, TS only in env)"
mts=${made#voipappz_}; mts=${mts%.dump}
q voipappz "DROP TABLE backup_probe;" >/dev/null
mk backup-restore FORCE=1 DB=voipappz TS="$mts" 2>&1 | sed 's/^/   /'
probe "make backup-restore TS=<timestamp>"
# Three restores ran within seconds above; each must have its own safety copy.
n_safe=$(docker exec "$PG" sh -c 'ls /backups' | grep -c '^pre-restore_voipappz_')
[ "$n_safe" -ge 6 ] || fail "only $n_safe pre-restore dumps for 6 restores: one overwrote another"

echo "PASS: dated dumps locally and in MinIO (plain and gpg), both pruned; restore by newest, timestamp, local; make targets"
