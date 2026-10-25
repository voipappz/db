#!/bin/bash
set -e

# pgEdge node initialization script (Debian/Ubuntu pg_ctlcluster style)
# Configures Spock logical replication for multi-master.
#
# Required env vars:
#   NODE_NAME       - This node's name (n1 or n2)
#   PEER_NAME       - The other node's name (n2 or n1)
#   PEER_HOST       - The other node's hostname
#   PEER_PORT       - The other node's port (default: 5432)
#   DB_USER         - Database superuser (default: postgres)
#   DATABASES       - Space-separated list of databases to create (default: voipappz)
#   SPOCK_DATABASES - Databases replicated active-active (default: voipappz)
#
# Optional PostgreSQL tuning (see .env.example for full list):
#   PG_MAX_CONNECTIONS, PG_SHARED_BUFFERS, PG_EFFECTIVE_CACHE_SIZE, ...

DB_USER="${DB_USER:-postgres}"
PEER_PORT="${PEER_PORT:-5432}"
PG_VERSION="${PG_VERSION:-17}"
PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
DATABASES="${DATABASES:-voipappz}"

# PostgreSQL tuning (env-overridable)
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-250}"
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-1GB}"
PG_EFFECTIVE_CACHE_SIZE="${PG_EFFECTIVE_CACHE_SIZE:-12GB}"
PG_WORK_MEM="${PG_WORK_MEM:-20971kB}"
PG_MAINTENANCE_WORK_MEM="${PG_MAINTENANCE_WORK_MEM:-512MB}"
PG_EFFECTIVE_IO_CONCURRENCY="${PG_EFFECTIVE_IO_CONCURRENCY:-200}"
PG_RANDOM_PAGE_COST="${PG_RANDOM_PAGE_COST:-1.1}"
PG_WAL_BUFFERS="${PG_WAL_BUFFERS:-16MB}"

# CIS PostgreSQL Benchmark knobs (env-overridable).
#
# log_destination/logging_collector default to the CONTAINER-NATIVE path:
# postgres logs to stderr, and docker's syslog log driver ships that to the
# telegraf collector. CIS assumes a host install and asks for the collector
# writing files under log_directory; inside a container those files are
# invisible to that pipeline, so the collector is OPT-IN. Set
# PG_LOGGING_COLLECTOR=on (optionally PG_LOG_DESTINATION=csvlog) on a host
# deployment to get the file-based behaviour CIS describes -- every
# supporting knob (directory, filename, mode, rotation) is already set below
# so flipping the one variable is enough.
PG_LOG_DESTINATION="${PG_LOG_DESTINATION:-stderr}"
PG_LOGGING_COLLECTOR="${PG_LOGGING_COLLECTOR:-off}"
PG_LOG_STATEMENT="${PG_LOG_STATEMENT:-ddl}"
PG_LOG_MIN_MESSAGES="${PG_LOG_MIN_MESSAGES:-warning}"
PG_LOG_MIN_ERROR_STATEMENT="${PG_LOG_MIN_ERROR_STATEMENT:-error}"
PG_LOG_ERROR_VERBOSITY="${PG_LOG_ERROR_VERBOSITY:-default}"
PG_SYSLOG_FACILITY="${PG_SYSLOG_FACILITY:-LOCAL0}"
PG_SYSLOG_IDENT="${PG_SYSLOG_IDENT:-postgres}"
# pgaudit.so ships inside pgedge-enterprise-postgres -- no extra package.
# 'write' is deliberately NOT in the default class list: this database carries
# CDR/event-store insert volume and auditing every write would dwarf the real
# log. Add it via PG_PGAUDIT_LOG='ddl,role,write' where compliance requires it.
PG_PGAUDIT_LOG="${PG_PGAUDIT_LOG:-ddl,role}"
# TLS is off by default because the app plane reaches postgres over the docker
# bridge only (loopback-published on the host). Set PG_TLS=on to enable; a
# self-signed cert is generated when none is mounted at PG_TLS_CERT/PG_TLS_KEY.
PG_TLS="${PG_TLS:-off}"
PG_TLS_CERT="${PG_TLS_CERT:-/etc/postgresql/${PG_VERSION}/main/server.crt}"
PG_TLS_KEY="${PG_TLS_KEY:-/etc/postgresql/${PG_VERSION}/main/server.key}"
# Dedicated streaming-replication role (CIS: replication must not use a
# superuser). Created when PG_REPLICATION_PASSWORD is supplied.
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicator}"
PG_REPLICATION_PASSWORD="${PG_REPLICATION_PASSWORD:-}"

# ── Remaining CIS knobs: every benchmark item is env-tunable ──
# Logging details (CIS section 3). Defaults are the values this image has
# always shipped; the vars exist so a deployment can tighten or relax them
# without a rebuild.
PG_TIMEZONE="${PG_TIMEZONE:-UTC}"
PG_LOG_TIMEZONE="${PG_LOG_TIMEZONE:-UTC}"
PG_LOG_LINE_PREFIX="${PG_LOG_LINE_PREFIX:-%m [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h }"
PG_LOG_MIN_DURATION_STATEMENT="${PG_LOG_MIN_DURATION_STATEMENT:-1000}"
PG_LOG_CONNECTIONS="${PG_LOG_CONNECTIONS:-on}"
PG_LOG_DISCONNECTIONS="${PG_LOG_DISCONNECTIONS:-on}"
# log_hostname default off: costs a reverse-DNS lookup per connection and %h in
# log_line_prefix already records the client address.
PG_LOG_HOSTNAME="${PG_LOG_HOSTNAME:-off}"
PG_LOG_REPLICATION_COMMANDS="${PG_LOG_REPLICATION_COMMANDS:-on}"
# pgAudit detail knobs
PG_PGAUDIT_LOG_CATALOG="${PG_PGAUDIT_LOG_CATALOG:-off}"
PG_PGAUDIT_LOG_PARAMETER="${PG_PGAUDIT_LOG_PARAMETER:-on}"
PG_PGAUDIT_LOG_RELATION="${PG_PGAUDIT_LOG_RELATION:-on}"
PG_PGAUDIT_LOG_STATEMENT_ONCE="${PG_PGAUDIT_LOG_STATEMENT_ONCE:-off}"
# Password complexity: passwordcheck in shared_preload_libraries.
PG_PASSWORDCHECK="${PG_PASSWORDCHECK:-on}"
# set_user extension (CIS: audited privilege escalation instead of raw SET
# ROLE). Preloaded + created in every database when on; skipped with a warning
# if the .so is not present in the image.
PG_SET_USER="${PG_SET_USER:-off}"
# pgcrypto in every database (CIS: column-level crypto available to apps).
PG_PGCRYPTO="${PG_PGCRYPTO:-off}"
# Privilege hardening. REVOKE_PUBLIC_CREATE undoes the historical
# GRANT ALL ON SCHEMA public TO PUBLIC in the sql/ init files (runs after
# them, every boot). REVOKE_FUNCTION_PRIVS removes existing EXECUTE-to-PUBLIC
# grants and strips that default from routines DB_USER creates from then on.
PG_REVOKE_PUBLIC_CREATE="${PG_REVOKE_PUBLIC_CREATE:-off}"
PG_REVOKE_FUNCTION_PRIVS="${PG_REVOKE_FUNCTION_PRIVS:-off}"
# Server-side RLS switch. 'on' is the PG default and means policies are
# enforced; per-table policies stay app-owned (this image creates none).
PG_ROW_SECURITY="${PG_ROW_SECURITY:-on}"
# Predefined roles (CIS: use pg_monitor & co instead of superuser). A
# non-superuser monitoring login granted pg_monitor, created when the
# password is supplied.
PG_MONITOR_USER="${PG_MONITOR_USER:-monitor}"
PG_MONITOR_PASSWORD="${PG_MONITOR_PASSWORD:-}"
# Streaming replication / worker capacity.
PG_MAX_WORKER_PROCESSES="${PG_MAX_WORKER_PROCESSES:-10}"
PG_MAX_WAL_SENDERS="${PG_MAX_WAL_SENDERS:-10}"
PG_MAX_REPLICATION_SLOTS="${PG_MAX_REPLICATION_SLOTS:-10}"
# WAL archiving for physical base backups (pg_basebackup + PITR). Off by
# default: this image ships logical dump/restore via the Makefile. Set
# PG_ARCHIVE_MODE=on AND a real PG_ARCHIVE_COMMAND to enable.
PG_ARCHIVE_MODE="${PG_ARCHIVE_MODE:-off}"
PG_ARCHIVE_COMMAND="${PG_ARCHIVE_COMMAND:-}"
PG_TLS_MIN_PROTOCOL="${PG_TLS_MIN_PROTOCOL:-TLSv1.2}"

# The postgres role password. POSTGRES_PASSWORD is the only source.
# Warn loudly if unset: the ALTER ROLE below is then skipped and the
# container reports healthy while every client fails to authenticate.
export PGPASSWORD="${POSTGRES_PASSWORD:-}"
if [ -z "$PGPASSWORD" ]; then
  echo "[$NODE_NAME] WARNING: POSTGRES_PASSWORD is not set — clients will" >&2
  echo "[$NODE_NAME]          fail to authenticate." >&2
fi

# ============================================================
# Initialize and start PostgreSQL (Debian-style)
# ============================================================

# Create cluster if it doesn't exist
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[$NODE_NAME] Creating PostgreSQL ${PG_VERSION} cluster..."
  pg_createcluster "$PG_VERSION" main -- \
    --auth-local=trust --auth-host=scram-sha-256
fi

# Configure pg_hba.conf for replication and local trust. PostgreSQL's `host`
# record accepts both encrypted and unencrypted connections; use `hostssl`
# whenever TLS is enabled so encryption is mandatory, not merely available.
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
HBA_HOST_TYPE="host"
if [ "$PG_TLS" = "on" ]; then
  HBA_HOST_TYPE="hostssl"
  # Upgrade the managed rules on an existing data volume. Enabling TLS is a
  # one-way hardening action; deliberately do not downgrade hostssl on a later
  # boot just because PG_TLS was accidentally omitted.
  sed -i -E \
    '/(10\.0\.0\.0\/8|172\.16\.0\.0\/12|192\.168\.0\.0\/16)/ s/^([[:space:]]*)host([[:space:]])/\1hostssl\2/' \
    "$PG_HBA"
fi
if ! grep -q "spock replication" "$PG_HBA" 2>/dev/null; then
  cat >> "$PG_HBA" <<EOF
# spock replication (Docker network only)
${HBA_HOST_TYPE}    all             all             10.0.0.0/8              scram-sha-256
${HBA_HOST_TYPE}    all             all             172.16.0.0/12           scram-sha-256
${HBA_HOST_TYPE}    all             all             192.168.0.0/16          scram-sha-256
${HBA_HOST_TYPE}    replication     all             10.0.0.0/8              scram-sha-256
${HBA_HOST_TYPE}    replication     all             172.16.0.0/12           scram-sha-256
${HBA_HOST_TYPE}    replication     all             192.168.0.0/16          scram-sha-256
local   all             all                                     trust
EOF
fi

# Build shared_preload_libraries from the enabled features. pgaudit must be
# preloaded to audit anything; passwordcheck enforces password complexity at
# CREATE/ALTER ROLE time; set_user needs preload for its logging hooks.
# Feature .so files are checked before preloading: a missing library in
# shared_preload_libraries prevents postgres from starting at all.
PGLIBDIR="$(pg_config --pkglibdir 2>/dev/null || echo /usr/lib/postgresql/${PG_VERSION}/lib)"
PRELOAD_LIBS="spock,pg_stat_statements,pgaudit,timescaledb"
if [ "$PG_PASSWORDCHECK" = "on" ]; then
  PRELOAD_LIBS="${PRELOAD_LIBS},passwordcheck"
fi
if [ "$PG_SET_USER" = "on" ]; then
  if [ -f "${PGLIBDIR}/set_user.so" ]; then
    PRELOAD_LIBS="${PRELOAD_LIBS},set_user"
  else
    echo "[$NODE_NAME] WARN: PG_SET_USER=on but ${PGLIBDIR}/set_user.so not found; disabling set_user"
    PG_SET_USER="off"
  fi
fi
if [ "$PG_ARCHIVE_MODE" = "on" ] && [ -z "$PG_ARCHIVE_COMMAND" ]; then
  echo "[$NODE_NAME] WARN: PG_ARCHIVE_MODE=on with empty PG_ARCHIVE_COMMAND -- WAL will"
  echo "[$NODE_NAME]       accumulate unarchived until a command is set."
fi

# Configure postgresql.conf for replication (idempotent)
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
if ! grep -q "pgEdge Spock replication settings" "$PG_CONF" 2>/dev/null; then
cat >> "$PG_CONF" <<EOF
# pgEdge Spock replication settings
wal_level = logical
# Spock's walsender opens its slot with the spock_output plugin. This build of
# PostgreSQL gates that behind an allowlist -- without the library named here,
# CREATE_REPLICATION_SLOT over the replication protocol is refused with
#   library "spock_output" may not be used as an output plugin
# and the apply worker exits, so subscriptions form and nothing ever replicates.
#
# The failure is three steps from its cause: the only thing a test sees is that
# a replicated table never arrived. Note the restriction applies to the
# REPLICATION path only -- calling pg_create_logical_replication_slot() as a
# superuser still succeeds, which makes the plugin look fine when probed by hand.
output_plugin_libraries = 'spock_output'
max_worker_processes = ${PG_MAX_WORKER_PROCESSES}
max_replication_slots = ${PG_MAX_REPLICATION_SLOTS}
max_wal_senders = ${PG_MAX_WAL_SENDERS}
shared_preload_libraries = '${PRELOAD_LIBS}'
track_commit_timestamp = on
listen_addresses = '*'

# DDL replication. Spock 5 drives this with GUCs -- there is no
# spock.autoddl_set_enabled() function (an older call by that name errored
# every boot behind a 2>/dev/null, printing "autoddl already enabled").
#
# This is what makes the node active-active-correct in practice: the API
# creates its tables via rake db:migrate LONG AFTER this script's
# repset_add_all_tables runs against a still-empty database. Without
# include_ddl_repset those tables exist on both nodes but belong to no
# replication set, so nothing about them replicates.
#   enable_ddl_replication - ship DDL to peers
#   include_ddl_repset     - auto-add newly created tables to their repset
#   allow_ddl_from_functions - migrations run DDL inside DO/pl-pgsql blocks
spock.enable_ddl_replication = on
spock.include_ddl_repset = on
spock.allow_ddl_from_functions = on

# VoIP-optimized settings (env-overridable)
max_connections = ${PG_MAX_CONNECTIONS}
shared_buffers = ${PG_SHARED_BUFFERS}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}
work_mem = ${PG_WORK_MEM}
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM}
effective_io_concurrency = ${PG_EFFECTIVE_IO_CONCURRENCY}
random_page_cost = ${PG_RANDOM_PAGE_COST}
default_statistics_target = 100
checkpoint_completion_target = 0.9
wal_buffers = ${PG_WAL_BUFFERS}
password_encryption = scram-sha-256

# ── Logging (CIS PostgreSQL Benchmark section 3) ─────────────
timezone = '${PG_TIMEZONE}'
log_timezone = '${PG_LOG_TIMEZONE}'

# Destination + collector. See the PG_LOGGING_COLLECTOR note at the top of this
# script for why the container default is stderr with the collector off.
log_destination = '${PG_LOG_DESTINATION}'
logging_collector = ${PG_LOGGING_COLLECTOR}

# Collector file handling. Inert while logging_collector=off, but set so that
# flipping it on yields the CIS-described behaviour with no other change.
# %a is the abbreviated weekday: combined with truncate-on-rotation and a 1-day
# rotation age this self-prunes to a rolling 7 days with no external logrotate.
# log_rotation_size stays 0 so size never rotates a file mid-day -- that would
# reuse a weekday name and truncate the day's earlier entries.
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_file_mode = 0600
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 0

# syslog specifics (apply when log_destination includes 'syslog').
# sequence_numbers + split_messages keep syslog from silently collapsing
# repeated lines or dropping the tail of a statement over the 1KB-ish limit.
syslog_facility = '${PG_SYSLOG_FACILITY}'
syslog_ident = '${PG_SYSLOG_IDENT}'
syslog_sequence_numbers = on
syslog_split_messages = on

# What gets logged.
log_min_messages = ${PG_LOG_MIN_MESSAGES}
log_min_error_statement = ${PG_LOG_MIN_ERROR_STATEMENT}
log_error_verbosity = ${PG_LOG_ERROR_VERBOSITY}
log_statement = '${PG_LOG_STATEMENT}'
log_min_duration_statement = ${PG_LOG_MIN_DURATION_STATEMENT}
log_connections = ${PG_LOG_CONNECTIONS}
log_disconnections = ${PG_LOG_DISCONNECTIONS}
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_replication_commands = ${PG_LOG_REPLICATION_COMMANDS}
log_hostname = ${PG_LOG_HOSTNAME}
log_line_prefix = '${PG_LOG_LINE_PREFIX}'

# Debug dumps: parse/rewrite/plan trees are developer aids that leak query
# internals into the log, so they stay off. pretty_print only affects the
# formatting IF one of them is ever turned on.
debug_print_parse = off
debug_print_rewritten = off
debug_print_plan = off
debug_pretty_print = on

# ── Audit (pgAudit) ──────────────────────────────────────────
pgaudit.log = '${PG_PGAUDIT_LOG}'
pgaudit.log_catalog = ${PG_PGAUDIT_LOG_CATALOG}
pgaudit.log_parameter = ${PG_PGAUDIT_LOG_PARAMETER}
pgaudit.log_relation = ${PG_PGAUDIT_LOG_RELATION}
pgaudit.log_statement_once = ${PG_PGAUDIT_LOG_STATEMENT_ONCE}

# ── RLS enforcement + WAL archiving (CIS sections 4/8) ───────
row_security = ${PG_ROW_SECURITY}
archive_mode = ${PG_ARCHIVE_MODE}
archive_command = '${PG_ARCHIVE_COMMAND}'

# Extensions tracking
pg_stat_statements.track = all
EOF
fi

# TLS (opt-in). Generated self-signed only when no cert is mounted; a real cert
# should be bind-mounted at PG_TLS_CERT/PG_TLS_KEY.
if [ "$PG_TLS" = "on" ]; then
  if [ ! -f "$PG_TLS_CERT" ]; then
    echo "[$NODE_NAME] PG_TLS=on and no cert at ${PG_TLS_CERT} -- generating self-signed"
    openssl req -new -x509 -days 825 -nodes -text \
      -out "$PG_TLS_CERT" -keyout "$PG_TLS_KEY" \
      -subj "/CN=${NODE_NAME:-postgres}" >/dev/null 2>&1
  fi
  # Postgres refuses to start if the key is group/world readable.
  chmod 0600 "$PG_TLS_KEY"
  if ! grep -q "VoIPAppz TLS" "$PG_CONF" 2>/dev/null; then
    cat >> "$PG_CONF" <<EOF

# VoIPAppz TLS
ssl = on
ssl_cert_file = '${PG_TLS_CERT}'
ssl_key_file = '${PG_TLS_KEY}'
ssl_min_protocol_version = '${PG_TLS_MIN_PROTOCOL}'
EOF
  fi
fi

# Start PostgreSQL
echo "[$NODE_NAME] Starting PostgreSQL ${PG_VERSION}..."
pg_ctlcluster "$PG_VERSION" main start

# Wait for PostgreSQL to be ready
echo "[$NODE_NAME] Waiting for PostgreSQL..."
for i in $(seq 1 60); do
  if pg_isready -U "$DB_USER" -q 2>/dev/null; then
    echo "[$NODE_NAME] PostgreSQL ready after ${i}s"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[$NODE_NAME] ERROR: PostgreSQL failed to start within 60s"
    exit 1
  fi
  sleep 1
done

# Ensure the configured DB_USER exists as superuser
# (cluster is created by the pgedge OS user; create additional roles as needed)
CLUSTER_USER=$(psql -U pgedge -d postgres -t -A -c "SELECT current_user;" 2>/dev/null || echo "pgedge")
if [ "$DB_USER" != "$CLUSTER_USER" ]; then
  psql -U "$CLUSTER_USER" -d postgres -c \
    "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN CREATE ROLE ${DB_USER} SUPERUSER LOGIN; END IF; END \$\$;"
  echo "[$NODE_NAME] Created superuser role: ${DB_USER}"
fi

# Set password if provided
if [ -n "$PGPASSWORD" ]; then
  SPOCK_PASSWORD="$PGPASSWORD"
  # Set role password (local trust auth, no password needed for this connection)
  psql -U "$DB_USER" -d postgres -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${PGPASSWORD}';"
  # Verify password was stored
  HAS_PASS=$(psql -U "$DB_USER" -d postgres -t -A -c \
    "SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname='${DB_USER}';")
  echo "[$NODE_NAME] Password set for ${DB_USER} (stored=${HAS_PASS})"
  # Clear password from environment (password is embedded in Spock DSNs below)
  unset PGPASSWORD
fi

# ============================================================
# Database initialization (per-database SQL files)
# ============================================================

SQL_DIR="/home/pgedge/scripts/sql"

for dbname in $DATABASES; do
  # Create database if needed
  psql -U "$DB_USER" -d postgres -c "CREATE DATABASE ${dbname};" 2>/dev/null || true

  # Run matching SQL init file
  if [ -f "${SQL_DIR}/${dbname}.sql" ]; then
    echo "[$NODE_NAME] Running ${dbname}.sql..."
    psql -U "$DB_USER" -d "$dbname" -f "${SQL_DIR}/${dbname}.sql"
  fi

  # pgAudit is preloaded cluster-wide but the extension is per-database, and
  # without it pgaudit.log is silently inert.
  psql -U "$DB_USER" -d "$dbname" -c "CREATE EXTENSION IF NOT EXISTS pgaudit;" >/dev/null 2>&1 \
    || echo "[$NODE_NAME] WARN: could not create pgaudit extension in ${dbname}"

  # Optional CIS extensions/hardening (see the PG_* knobs at the top)
  if [ "$PG_PGCRYPTO" = "on" ]; then
    psql -U "$DB_USER" -d "$dbname" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 \
      || echo "[$NODE_NAME] WARN: could not create pgcrypto extension in ${dbname}"
  fi
  if [ "$PG_SET_USER" = "on" ]; then
    psql -U "$DB_USER" -d "$dbname" -c "CREATE EXTENSION IF NOT EXISTS set_user;" >/dev/null 2>&1 \
      || echo "[$NODE_NAME] WARN: could not create set_user extension in ${dbname}"
  fi
  # Runs after the sql/ init file, so it wins over the GRANT ALL ... TO PUBLIC
  # those files carry.
  if [ "$PG_REVOKE_PUBLIC_CREATE" = "on" ]; then
    psql -U "$DB_USER" -d "$dbname" -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" >/dev/null
  fi
  if [ "$PG_REVOKE_FUNCTION_PRIVS" = "on" ]; then
    psql -U "$DB_USER" -d "$dbname" -v ON_ERROR_STOP=1 -c \
      "REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA public FROM PUBLIC;
       ALTER DEFAULT PRIVILEGES FOR ROLE ${DB_USER} REVOKE EXECUTE ON ROUTINES FROM PUBLIC;" >/dev/null
  fi
done

# Dedicated streaming-replication role. CIS: replication must not run as a
# superuser. REPLICATION+LOGIN only -- no data access, no DDL.
if [ -n "$PG_REPLICATION_PASSWORD" ]; then
  psql -U "$DB_USER" -d postgres -c \
    "DO \$\$ BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${PG_REPLICATION_USER}') THEN
         CREATE ROLE ${PG_REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${PG_REPLICATION_PASSWORD}';
       ELSE
         ALTER ROLE ${PG_REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${PG_REPLICATION_PASSWORD}';
       END IF;
     END \$\$;" >/dev/null
  echo "[$NODE_NAME] Replication role ready: ${PG_REPLICATION_USER}"
fi

# Monitoring role via the pg_monitor predefined role (CIS: use predefined
# roles instead of superuser). Created when PG_MONITOR_PASSWORD is supplied.
if [ -n "$PG_MONITOR_PASSWORD" ]; then
  psql -U "$DB_USER" -d postgres -c \
    "DO \$\$ BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${PG_MONITOR_USER}') THEN
         CREATE ROLE ${PG_MONITOR_USER} WITH LOGIN PASSWORD '${PG_MONITOR_PASSWORD}';
       ELSE
         ALTER ROLE ${PG_MONITOR_USER} WITH LOGIN PASSWORD '${PG_MONITOR_PASSWORD}';
       END IF;
       GRANT pg_monitor TO ${PG_MONITOR_USER};
     END \$\$;" >/dev/null
  echo "[$NODE_NAME] Monitoring role ready: ${PG_MONITOR_USER} (pg_monitor)"
fi

# PostgREST removed 2026-08-03. It was an unused second listener on :3000 that
# authenticated as a LOGIN role holding SELECT over every table in voipappz,
# with a hardcoded, well-known password. The API plane reaches postgres
# directly; nothing consumed this. One process, one port, one attack surface
# fewer.

# ============================================================
# Configure Spock replication
# ============================================================

# Databases that replicate between nodes. Each gets the full setup
# (extension, node, repsets, subscription) — GUCs alone are not enough.
SPOCK_DATABASES="${SPOCK_DATABASES:-voipappz}"

echo "[$NODE_NAME] Configuring Spock replication for: ${SPOCK_DATABASES}"

# Use actual container hostname (pgedge-n1/pgedge-n2) for DSN, not NODE_NAME (n1/n2)
NODE_HOST="$(hostname)"
SPOCK_SSL_DSN=""
if [ "$PG_TLS" = "on" ]; then
  SPOCK_SSL_DSN=" sslmode=require"
fi

# CIS 7.1: the WAL sender must not run as a superuser. When a dedicated
# replication role exists, subscriptions connect as that role instead of
# DB_USER, so every wal sender on the peer belongs to a REPLICATION-only,
# non-superuser account. The node's own advertised DSN stays on DB_USER --
# it is not the streaming connection, and Spock uses it for local admin.
SPOCK_DSN_USER="$DB_USER"
SPOCK_DSN_PASSWORD="$SPOCK_PASSWORD"
if [ -n "$PG_REPLICATION_PASSWORD" ]; then
  SPOCK_DSN_USER="$PG_REPLICATION_USER"
  SPOCK_DSN_PASSWORD="$PG_REPLICATION_PASSWORD"
fi

for spockdb in $SPOCK_DATABASES; do
  # Ensure spock extension is available
  psql -U "$DB_USER" -d "$spockdb" -c "CREATE EXTENSION IF NOT EXISTS spock;"

  # Provider-side grants for the replication role. Spock's walsender reads its
  # own catalogs and calls spock.node_info() during sub_create, and
  # synchronize_data COPYs the tables -- none of which a bare REPLICATION role
  # may do. Must run after CREATE EXTENSION, since it grants on schema spock.
  if [ -n "$PG_REPLICATION_PASSWORD" ]; then
    psql -U "$DB_USER" -d "$spockdb" -v ON_ERROR_STOP=1 -c "
      GRANT CONNECT ON DATABASE ${spockdb} TO ${PG_REPLICATION_USER};
      GRANT USAGE ON SCHEMA public, spock TO ${PG_REPLICATION_USER};
      GRANT SELECT ON ALL TABLES IN SCHEMA public, spock TO ${PG_REPLICATION_USER};
      GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA spock TO ${PG_REPLICATION_USER};
      -- voipappz has no tables at boot: every one arrives later from the API's
      -- migrations, so the default privilege is the grant that actually matters.
      --
      -- FOR ROLE covers only tables created BY that role, so both creators need
      -- an entry. DB_USER is the API's migrations; postgres is the superuser
      -- that psql -U postgres uses -- which is how CI creates its probe table,
      -- and how an operator creates anything by hand. With only DB_USER listed,
      -- such a table replicates its DDL and then cannot be read by the wal
      -- sender, which presents as \"the table never reached the peer\".
      ALTER DEFAULT PRIVILEGES FOR ROLE ${DB_USER} IN SCHEMA public
        GRANT SELECT ON TABLES TO ${PG_REPLICATION_USER};
      ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
        GRANT SELECT ON TABLES TO ${PG_REPLICATION_USER};
      -- Spock applies replicated DDL on the subscriber through this role, so it
      -- must be able to create objects in the target schema. USAGE alone lets it
      -- read what exists and nothing more.
      GRANT CREATE ON SCHEMA public TO ${PG_REPLICATION_USER};" >/dev/null
    echo "[$NODE_NAME] ${spockdb}: replication role ${PG_REPLICATION_USER} granted provider read access"
  fi

  # ---- Create Spock node ----
  NODE_DSN="host=${NODE_HOST} port=5432 dbname=${spockdb} user=${DB_USER}${SPOCK_SSL_DSN}"
  if [ -n "$SPOCK_PASSWORD" ]; then
    NODE_DSN="${NODE_DSN} password=${SPOCK_PASSWORD}"
  fi
  psql -U "$DB_USER" -d "$spockdb" -c \
    "SELECT spock.node_create(
      node_name := '${NODE_NAME}',
      dsn := '${NODE_DSN}'
    );" 2>/dev/null || echo "[$NODE_NAME] ${spockdb}: node already exists, skipping."

  # ---- Add all tables + sequences to default repset ----
  psql -U "$DB_USER" -d "$spockdb" -c \
    "SELECT spock.repset_add_all_tables('default', ARRAY['public']);" \
    2>/dev/null || echo "[$NODE_NAME] ${spockdb}: tables already in repset."
  psql -U "$DB_USER" -d "$spockdb" -c \
    "SELECT spock.repset_add_all_sequences('default', ARRAY['public']);" \
    2>/dev/null || echo "[$NODE_NAME] ${spockdb}: sequences already in repset."
done

# ---- Verify DDL replication is actually on ----
# Set via postgresql.conf GUCs above. Checked (not assumed) because a silent
# failure here is invisible until a peer is missing data.
DDL_CHECK_DB="${SPOCK_DATABASES%% *}"
DDL_REPL=$(psql -U "$DB_USER" -d "$DDL_CHECK_DB" -t -A -c "SHOW spock.enable_ddl_replication;" 2>/dev/null || echo "unknown")
DDL_REPSET=$(psql -U "$DB_USER" -d "$DDL_CHECK_DB" -t -A -c "SHOW spock.include_ddl_repset;" 2>/dev/null || echo "unknown")
echo "[$NODE_NAME] DDL replication=${DDL_REPL} include_ddl_repset=${DDL_REPSET}"
if [ "$DDL_REPL" != "on" ] || [ "$DDL_REPSET" != "on" ]; then
  echo "[$NODE_NAME] WARN: DDL replication is not fully enabled -- tables created"
  echo "[$NODE_NAME]       after this point may not replicate to peers."
fi

# ---- Create subscriptions to peer (if peer is configured) ----
if [ -z "$PEER_NAME" ] || [ "$PEER_NAME" = "none" ] || [ -z "$PEER_HOST" ]; then
  echo "[$NODE_NAME] No peer configured (PEER_NAME=${PEER_NAME:-<empty>}). Skipping subscription."
else
  echo "[$NODE_NAME] Checking peer availability: ${PEER_HOST}:${PEER_PORT}..."

  # Wait for peer TCP connectivity (up to 120s, peer may still be starting)
  PEER_READY=false
  for i in $(seq 1 120); do
    if pg_isready -h "$PEER_HOST" -p "$PEER_PORT" -q 2>/dev/null; then
      PEER_READY=true
      echo "[$NODE_NAME] Peer ${PEER_NAME} TCP ready after ${i}s"
      break
    fi
    sleep 1
  done

  for spockdb in $SPOCK_DATABASES; do
    # Build peer DSN (include password if set for scram-sha-256 auth). This is
    # the connection that becomes a wal sender on the peer, so it carries the
    # replication role when one is configured (CIS 7.1).
    PEER_DSN="host=${PEER_HOST} port=${PEER_PORT} dbname=${spockdb} user=${SPOCK_DSN_USER}${SPOCK_SSL_DSN}"
    if [ -n "$SPOCK_DSN_PASSWORD" ]; then
      PEER_DSN="${PEER_DSN} password=${SPOCK_DSN_PASSWORD}"
    fi

    if [ "$PEER_READY" = true ]; then
      # Retry subscription creation — peer's Spock node may still be initializing
      SUB_CREATED=false
      for attempt in $(seq 1 30); do
        SUB_OUTPUT=$(psql -U "$DB_USER" -d "$spockdb" -v ON_ERROR_STOP=1 -c \
          "SELECT spock.sub_create(
            subscription_name := 'sub_${NODE_NAME}_${PEER_NAME}',
            provider_dsn := '${PEER_DSN}',
            -- 'ddl_sql' is REQUIRED for active-active. Spock queues replicated
            -- DDL into the ddl_sql replication set, not 'default'. Subscribing to
            -- 'default' alone gives working row replication for tables that
            -- already exist, while every CREATE/ALTER silently stops at this node
            -- -- so the API's migrations would land on one node only.
            -- default_insert_only covers tables with no replica identity.
            replication_sets := ARRAY['default','default_insert_only','ddl_sql'],
            synchronize_data := true
          );" 2>&1) && SUB_CREATED=true
        echo "[$NODE_NAME] ${spockdb} sub_create attempt ${attempt}: ${SUB_OUTPUT}"
        if [ "$SUB_CREATED" = true ]; then
          echo "[$NODE_NAME] ${spockdb}: subscription to ${PEER_NAME} created."
          break
        fi
        sleep 2
      done
      # Verify subscription state
      SUB_COUNT=$(psql -U "$DB_USER" -d "$spockdb" -t -A -c \
        "SELECT count(*) FROM spock.subscription;" 2>/dev/null || echo "0")
      echo "[$NODE_NAME] ${spockdb}: spock subscription count: ${SUB_COUNT}"
      if [ "$SUB_CREATED" = false ]; then
        echo "[$NODE_NAME] WARNING: ${spockdb}: could not create subscription to ${PEER_NAME} after 30 attempts."
      fi
    else
      echo "[$NODE_NAME] WARNING: Peer ${PEER_NAME} not reachable after 120s. Subscription skipped."
      echo "[$NODE_NAME] Run manually once peer is up (in ${spockdb}):"
      echo "  SELECT spock.sub_create("
      echo "    subscription_name := 'sub_${NODE_NAME}_${PEER_NAME}',"
      echo "    provider_dsn := 'host=${PEER_HOST} port=${PEER_PORT} dbname=${spockdb} user=${SPOCK_DSN_USER}${SPOCK_SSL_DSN}',"
      echo "    replication_sets := ARRAY['default','default_insert_only','ddl_sql'],"
      echo "    synchronize_data := true"
      echo "  );"
    fi
  done
fi

echo "[$NODE_NAME] Spock initialization complete."

# Signal that initialization is complete (used by CI/health checks)
touch /tmp/init-complete

# Keep PostgreSQL + PostgREST running in foreground
echo "[$NODE_NAME] PostgreSQL + PostgREST running. Tailing logs..."
exec tail -f /var/log/postgresql/postgresql-${PG_VERSION}-main.log
