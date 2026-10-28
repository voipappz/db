#!/usr/bin/env bash
# backup.sh / restore.sh end to end, inside the image, against a real MinIO:
#   - a row written before the backup comes back from S3 (newest), from S3 by
#     timestamp, from the local copy, and from a GPG-encrypted S3 copy;
#   - names are <db>_<YYYY-MM-DDTHH:MM:SS>.dump, the dump is a valid archive
#     without spock, and no .part is left;
#   - retention prunes a stale local dump AND a stale S3 object;
#   - restore goes into a new database and swaps it in: the replaced database
#     is kept as pre-restore_<db>_<ts>.dump, no temp database is left behind;
#   - a TimescaleDB hypertable shaped like the real one comes back exactly
#     (content checksum), changed after the backup so stale data cannot pass;
#   - a corrupt dump fails the restore and leaves the live database untouched;
#   - a restore with a client writing during it succeeds;
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
ident_sum() { q voipappz "SELECT md5(string_agg(t::text, '|' ORDER BY event_id, at)) FROM identities t;"; }
probe() {
  [ "$(q voipappz "SELECT count(*) FROM backup_probe WHERE note='round-trip';")" = 1 ] || fail "row not back after $1"
  [ "$(ident_sum)" = "$IDENT_SUM" ] || fail "identities content differs from the dump after $1"
  [ "$(q voipappz "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='identities';")" = 1 ] || fail "identities is no longer a hypertable after $1"
  [ "$(q voipappz "SELECT count(*) FROM timescaledb_information.jobs WHERE hypertable_name='identities' AND proc_name='policy_retention';")" = 1 ] || fail "identities lost its retention policy after $1"
  # post_restore ran: the database is out of restoring mode.
  [ "$(q voipappz "SHOW timescaledb.restoring;")" = off ] || fail "voipappz left in timescaledb restoring mode after $1"
  local logs; logs=$(docker logs "$PG" 2>&1)   # captured: grep -q on a pipe can SIGPIPE docker logs
  grep -q 'Segmentation fault' <<<"$logs" && fail "postgres segfaulted during $1"
  [ "$(q postgres "SELECT count(*) FROM pg_database WHERE datname LIKE 'voipappz\_\_restore\_%' OR datname LIKE 'voipappz\_pre\_restore\_%'")" = 0 ] \
    || fail "a temporary restore database was left behind after $1"
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
# The shape of mothership's real hypertable, public.identities (columns,
# indexes, 1-day chunks, 90-day retention policy), with made-up rows. Restoring
# that in place segfaulted a real node's postgres; the toy table this replaced
# did not, so CI passed while the real restore crashed.
q voipappz "CREATE EXTENSION IF NOT EXISTS timescaledb;
  CREATE TABLE public.identities (
    at timestamp with time zone NOT NULL, scope text NOT NULL, id text NOT NULL,
    environment_uuid uuid, event text NOT NULL, data jsonb, incr jsonb, event_id text NOT NULL);
  CREATE INDEX identities_at_idx ON public.identities USING btree (at DESC);
  CREATE INDEX identities_environment_at_idx ON public.identities USING btree (environment_uuid, at DESC);
  CREATE UNIQUE INDEX identities_event_id_at_idx ON public.identities USING btree (event_id, at);
  CREATE INDEX identities_scope_id_at_idx ON public.identities USING btree (scope, id, at DESC);
  SELECT create_hypertable('public.identities', 'at', chunk_time_interval => interval '1 day');
  SELECT add_retention_policy('public.identities', drop_after => interval '90 days');
  INSERT INTO public.identities
    SELECT now() - (i % 20) * interval '1 day' - i * interval '1 minute', 'account', 'id-' || (i % 50),
           gen_random_uuid(), 'event.' || (i % 7), jsonb_build_object('n', i, 'tag', md5(i::text)),
           jsonb_build_object('seen', i % 3), 'evt-' || i
    FROM generate_series(1, 2000) i;" >/dev/null
IDENT_SUM=$(ident_sum)
# A real voipappz dump lists thousands of TOC entries; the test's few dozen fit
# in a pipe buffer. restore.sh once piped the listing into grep -q: on a real
# dump pg_restore died of SIGPIPE, the timescaledb check came out false, and
# the restore segfaulted the server. Filler tables give the dump a real-sized TOC.
q voipappz "CREATE SCHEMA toc_filler;
  DO \$\$ BEGIN FOR i IN 1..1000 LOOP
    EXECUTE format('CREATE TABLE toc_filler.t%s (id int)', i);
  END LOOP; END \$\$;" >/dev/null
[ "$(docker exec "$PG" sh -c 'pg_dump -U postgres -d voipappz -N spock -Fc | pg_restore --list | wc -c')" -gt 100000 ] \
  || fail "dump TOC too small to exercise the SIGPIPE case"
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
grep -qx "$name" <<<"$objs" || fail "$name not uploaded (have: $objs)"
grep -q 2000-01-01 <<<"$objs" && fail "stale S3 object not pruned"
toc=$(docker exec "$PG" pg_restore --list "/backups/$name")
grep -q backup_probe <<<"$toc" || fail "dump has no backup_probe"
grep -qi 'SCHEMA - spock\|spock\.' <<<"$toc" && fail "dump carries spock objects"

echo ">> restore.sh --list"
list=$(run "$SCRIPTS/restore.sh" --list voipappz)
echo "$list" | sed 's/^/   /'
[ "$(echo "$list" | grep -c "$name")" = 2 ] || fail "--list does not show $name in both copies"

echo ">> restore.sh voipappz (newest, from S3)"
q voipappz "DROP TABLE backup_probe;" >/dev/null
# Change the hypertable after the backup: only a real restore brings it back.
q voipappz "DELETE FROM identities WHERE event_id LIKE 'evt-1%'; UPDATE identities SET data = '{}' WHERE event_id LIKE 'evt-2%';" >/dev/null
[ "$(ident_sum)" != "$IDENT_SUM" ] || fail "mutating identities did not change its checksum"
run "$SCRIPTS/restore.sh" voipappz 2>&1 | sed 's/^/   /'
probe "S3 newest restore"
# The state just before that restore (no backup_probe) was kept, locally and in S3.
safety=$(docker exec "$PG" sh -c 'ls /backups' | grep '^pre-restore_voipappz_' | sort | tail -1)
[ -n "$safety" ] || fail "restore did not keep a pre-restore dump of the existing database"
safety_toc=$(docker exec "$PG" pg_restore --list "/backups/$safety")
grep -q 'TABLE public backup_probe' <<<"$safety_toc" && fail "$safety is not the pre-restore state"
objs=$(s3 "rclone lsf s3:backup/postgres")
grep -qx "$safety" <<<"$objs" || fail "$safety not uploaded"

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
magic=$(s3 "rclone cat s3:backup/postgres/$gpg_obj | head -c 5")
[ "$magic" = PGDMP ] && fail "$gpg_obj is not encrypted"
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
grep -q "$made" <<<"$listed" || fail "make backup-list does not show $made"
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

echo ">> a corrupt dump fails the restore and leaves voipappz untouched"
good=$(docker exec "$PG" sh -c 'ls /backups' | grep -E '^voipappz_2.*\.dump$' | sort | tail -1)
run bash -c "head -c \$((\$(stat -c %s /backups/$good) * 2 / 3)) /backups/$good > /backups/voipappz_2001-01-01T00:00:00.dump"
before_rows=$(q voipappz "SELECT count(*) FROM backup_probe")
if docker exec -u root "$PG" "$SCRIPTS/restore.sh" voipappz 2001-01-01T00:00:00 > /tmp/claude-corrupt.$$ 2>&1; then
  cat /tmp/claude-corrupt.$$; rm -f /tmp/claude-corrupt.$$; fail "restore of a truncated dump reported success"
fi
sed 's/^/   /' /tmp/claude-corrupt.$$ | tail -3; rm -f /tmp/claude-corrupt.$$
run rm -f /backups/voipappz_2001-01-01T00:00:00.dump
[ "$(q voipappz "SELECT count(*) FROM backup_probe")" = "$before_rows" ] || fail "failed restore changed voipappz"
[ "$(q voipappz "SELECT datallowconn FROM pg_database WHERE datname = 'voipappz'")" = t ] || fail "failed restore left voipappz refusing connections"
probe "the failed restore (live must be unchanged)"

echo ">> a restore while a client keeps writing"
docker exec "$PG" rm -f /tmp/writer-done
docker exec -d "$PG" bash -c 'for i in $(seq 1 200); do psql -U postgres -d voipappz -qc "INSERT INTO identities VALUES (now(), '"'"'w'"'"', '"'"'w'"'"', NULL, '"'"'e'"'"', NULL, NULL, '"'"'live-'"'"' || $i)" >/dev/null 2>&1; sleep 0.05; done; touch /tmp/writer-done'
sleep 1
docker exec -u root "$PG" "$SCRIPTS/restore.sh" voipappz "$lts" 2>&1 | sed 's/^/   /' | tail -4
# Let the writer finish, then put the table back to the dump state.
for i in $(seq 1 120); do docker exec "$PG" test -e /tmp/writer-done && break; [ "$i" -eq 120 ] && fail "writer never finished"; sleep 1; done
q voipappz "DELETE FROM identities WHERE event_id LIKE 'live-%'" >/dev/null
probe "a restore with a client writing"

echo "PASS: dated dumps locally and in MinIO (plain and gpg), both pruned; restore by newest, timestamp, local; new-db swap; corrupt dump refused; make targets"
