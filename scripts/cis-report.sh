#!/usr/bin/env bash

# Generate customer-verifiable evidence for the requested subset of the
# CIS PostgreSQL 17 Benchmark v1.0.0. The audit is read-only: it inspects a
# running PostgreSQL container and never changes PostgreSQL or its files.

set -euo pipefail

NODE="${NODE:-pgedge-n1}"
DB="${DB:-voipappz}"
DB_USER="${DB_USER:-postgres}"
REPORT_DIR="${REPORT_DIR:-./reports/cis-postgresql-17}"
CIS_ENFORCE="${CIS_ENFORCE:-0}"
CUSTOMER_NAME="${CUSTOMER_NAME:-Customer}"
AUDIT_ENVIRONMENT="${AUDIT_ENVIRONMENT:-Not specified}"
AUDITOR_NAME="${AUDITOR_NAME:-Automated customer audit}"
REPORT_VERSION="${REPORT_VERSION:-1.0}"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is required" >&2
  exit 2
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "ERROR: sha256sum is required" >&2
  exit 2
}

docker inspect "$NODE" >/dev/null 2>&1 || {
  echo "ERROR: container '$NODE' does not exist; start the cluster first" >&2
  exit 2
}

docker exec "$NODE" pg_isready -U "$DB_USER" -d "$DB" >/dev/null 2>&1 || {
  echo "ERROR: PostgreSQL in '$NODE' is not ready" >&2
  exit 2
}

mkdir -p "$REPORT_DIR"

psql_scalar() {
  docker exec "$NODE" psql -U "$DB_USER" -d "$DB" -X -qAt \
    -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null | sed '/^[[:space:]]*$/d' | paste -sd ';' -
}

psql_csv() {
  local output="$1"
  local sql="$2"
  docker exec "$NODE" psql -U "$DB_USER" -d "$DB" -X --csv \
    -v ON_ERROR_STOP=1 -c "$sql" > "$REPORT_DIR/$output"
}

setting() {
  psql_scalar "SELECT setting FROM pg_settings WHERE name = '$1';"
}

safe_text() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/; }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

csv_text() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/; }"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

html_text() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/<br>}"
  printf '%s' "$value"
}

declare -a CONTROL_IDS=()
declare -a CONTROL_TITLES=()
declare -a CONTROL_STATUSES=()
declare -a CONTROL_EVIDENCE=()
declare -a CONTROL_COMMENTS=()

add_control() {
  CONTROL_IDS+=("$1")
  CONTROL_TITLES+=("$2")
  CONTROL_STATUSES+=("$3")
  CONTROL_EVIDENCE+=("$4")
  CONTROL_COMMENTS+=("$5")
}

expect_equal() {
  local id="$1" title="$2" actual="$3" expected="$4" comment="$5"
  if [ "$actual" = "$expected" ]; then
    add_control "$id" "$title" "PASS" "$id: value=$actual; expected=$expected" "$comment"
  else
    add_control "$id" "$title" "FAIL" "$id: value=${actual:-<empty>}; expected=$expected" "$comment"
  fi
}

# Supporting evidence files. Sensitive pg_settings values are redacted.
psql_csv "settings.csv" "
  SELECT name,
         CASE WHEN name ~ '(password|passphrase|conninfo|command)' THEN '<redacted>' ELSE setting END AS setting,
         unit, context, source
  FROM pg_settings
  WHERE name IN (
    'server_version','log_destination','logging_collector','log_directory',
    'log_filename','log_file_mode','log_truncate_on_rotation',
    'log_rotation_age','log_rotation_size','syslog_facility','syslog_ident',
    'syslog_sequence_numbers','syslog_split_messages','log_min_messages',
    'log_min_error_statement','debug_print_parse','debug_print_rewritten',
    'debug_print_plan','debug_pretty_print','log_connections',
    'log_disconnections','log_error_verbosity','log_hostname',
    'log_line_prefix','log_statement','log_timezone','shared_preload_libraries',
    'row_security','ssl','ssl_min_protocol_version','ssl_cert_file','ssl_key_file',
    'password_encryption','log_replication_commands','archive_mode',
    'archive_command','wal_level','max_wal_senders','max_replication_slots',
    'max_worker_processes','hot_standby','primary_conninfo'
  )
  ORDER BY name;"

psql_csv "extensions.csv" "
  SELECT extname, extversion, n.nspname AS schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  ORDER BY extname;"

psql_csv "roles.csv" "
  SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
         rolcanlogin, rolreplication, rolbypassrls,
         ARRAY(
           SELECT parent.rolname
           FROM pg_auth_members m
           JOIN pg_roles parent ON parent.oid = m.roleid
           WHERE m.member = r.oid
           ORDER BY parent.rolname
         ) AS member_of
  FROM pg_roles r
  ORDER BY rolname;"

psql_csv "privileges.csv" "
  SELECT 'table' AS object_type, table_schema AS object_schema,
         table_name AS object_name, grantee, privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema NOT IN ('pg_catalog','information_schema','spock')
  UNION ALL
  SELECT 'routine', routine_schema, routine_name, grantee, privilege_type
  FROM information_schema.role_routine_grants
  WHERE routine_schema NOT IN ('pg_catalog','information_schema','spock')
  ORDER BY object_type, object_schema, object_name, grantee, privilege_type;"

psql_csv "rls.csv" "
  SELECT n.nspname AS schema, c.relname AS table_name,
         c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced,
         count(p.policyname) AS policy_count,
         coalesce(string_agg(p.policyname, ', ' ORDER BY p.policyname), '') AS policies
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_policies p ON p.schemaname = n.nspname AND p.tablename = c.relname
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog','information_schema','spock')
  GROUP BY n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
  ORDER BY n.nspname, c.relname;"

psql_csv "runtime-parameters.csv" "
  SELECT name,
         CASE WHEN name ~ '(password|passphrase|conninfo|command)' THEN '<redacted>' ELSE setting END AS setting,
         unit, context, source, pending_restart
  FROM pg_settings
  WHERE context IN ('backend','postmaster','sighup','superuser','superuser-backend','user')
  ORDER BY context, name;"

psql_csv "hba-rules.csv" "
  SELECT rule_number, type, database, user_name, address, netmask, auth_method, error
  FROM pg_hba_file_rules
  ORDER BY rule_number;"

psql_csv "replication.csv" "
  SELECT application_name, usename, client_addr, state, sync_state
  FROM pg_stat_replication
  ORDER BY application_name, usename;"

SERVER_VERSION="$(setting server_version)"
IMAGE_ID="$(docker inspect -f '{{.Image}}' "$NODE" 2>/dev/null || echo unknown)"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if git diff --quiet -- 2>/dev/null \
  && git diff --cached --quiet -- 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  GIT_STATE="clean"
else
  GIT_STATE="dirty"
fi
SCRIPT_SHA256="$(sha256sum "$0" | awk '{print $1}')"
GENERATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

LOG_DESTINATION="$(setting log_destination)"
LOGGING_COLLECTOR="$(setting logging_collector)"
LOG_DIRECTORY="$(setting log_directory)"
LOG_FILENAME="$(setting log_filename)"
LOG_FILE_MODE="$(setting log_file_mode)"
LOG_TRUNCATE="$(setting log_truncate_on_rotation)"
LOG_AGE="$(setting log_rotation_age)"
LOG_SIZE="$(setting log_rotation_size)"
SYSLOG_FACILITY="$(setting syslog_facility)"
SYSLOG_SEQUENCE="$(setting syslog_sequence_numbers)"
SYSLOG_SPLIT="$(setting syslog_split_messages)"
SYSLOG_IDENT="$(setting syslog_ident)"
LOG_MIN_MESSAGES="$(setting log_min_messages)"
LOG_MIN_ERROR="$(setting log_min_error_statement)"
LOG_CONNECTIONS="$(setting log_connections)"
LOG_DISCONNECTIONS="$(setting log_disconnections)"
LOG_ERROR_VERBOSITY="$(setting log_error_verbosity)"
LOG_HOSTNAME="$(setting log_hostname)"
LOG_LINE_PREFIX="$(setting log_line_prefix)"
LOG_STATEMENT="$(setting log_statement)"
LOG_TIMEZONE="$(setting log_timezone)"
PRELOAD_LIBS="$(setting shared_preload_libraries)"
SSL="$(setting ssl)"
SSL_MIN_PROTOCOL="$(setting ssl_min_protocol_version)"
WAL_LEVEL="$(setting wal_level)"
MAX_WAL_SENDERS="$(setting max_wal_senders)"
MAX_REPLICATION_SLOTS="$(setting max_replication_slots)"
HOT_STANDBY="$(setting hot_standby)"

DATA_DIRECTORY="$(setting data_directory)"
case "$LOG_DIRECTORY" in
  /*) LOG_PATH="$LOG_DIRECTORY" ;;
  *) LOG_PATH="$DATA_DIRECTORY/$LOG_DIRECTORY" ;;
esac

docker exec "$NODE" sh -c '
  path="$1"
  if [ ! -d "$path" ]; then
    echo "directory-missing: $path"
    exit 0
  fi
  find "$path" -maxdepth 1 -type f -printf "%m|%u:%g|%s|%f\n" | sort
' sh "$LOG_PATH" > "$REPORT_DIR/log-files.txt" 2>/dev/null || true

if [ "$SSL" = "on" ]; then
  SSL_CERT_FILE="$(setting ssl_cert_file)"
  docker exec "$NODE" sh -c '
    cert="$1"
    if [ -f "$cert" ]; then
      openssl x509 -in "$cert" -noout -subject -issuer -dates -fingerprint -sha256
    else
      echo "certificate-missing: $cert"
    fi
  ' sh "$SSL_CERT_FILE" > "$REPORT_DIR/tls.txt" 2>&1 || true
else
  printf 'TLS is disabled\n' > "$REPORT_DIR/tls.txt"
fi

# 3 Logging and Auditing
if [ -n "$LOG_DESTINATION" ]; then
  add_control "3.1.2" "Ensure the log destinations are set correctly" "PASS" \
    "log_destination=$LOG_DESTINATION; settings.csv" \
    "Destination is explicitly configured. Customer policy must approve the selected destinations."
else
  add_control "3.1.2" "Ensure the log destinations are set correctly" "FAIL" \
    "log_destination is empty" "No active log destination was found."
fi

expect_equal "3.1.3" "Ensure the logging collector is enabled" \
  "$LOGGING_COLLECTOR" "on" "Required by the customer checklist for PostgreSQL-managed log files."

if [ -n "$LOG_DIRECTORY" ] && ! grep -q '^directory-missing:' "$REPORT_DIR/log-files.txt" 2>/dev/null; then
  add_control "3.1.4" "Ensure the log file destination directory is set correctly" "PASS" \
    "log_directory=$LOG_DIRECTORY; resolved_path=$LOG_PATH; log-files.txt" \
    "The configured directory exists. Retention and off-host collection remain operational policy decisions."
else
  add_control "3.1.4" "Ensure the log file destination directory is set correctly" "FAIL" \
    "log_directory=${LOG_DIRECTORY:-<empty>}; resolved_path=$LOG_PATH; log-files.txt" \
    "The configured log directory is empty or does not exist."
fi

if [ -n "$LOG_FILENAME" ] && [[ "$LOG_FILENAME" == *%* ]]; then
  add_control "3.1.5" "Ensure the filename pattern for log files is set correctly" "PASS" \
    "log_filename=$LOG_FILENAME" "A rotating filename pattern is configured."
else
  add_control "3.1.5" "Ensure the filename pattern for log files is set correctly" "FAIL" \
    "log_filename=${LOG_FILENAME:-<empty>}" "A time-based filename pattern is expected."
fi

expect_equal "3.1.6" "Ensure the log file permissions are set correctly" \
  "$LOG_FILE_MODE" "0600" "Actual files and ownership are recorded in log-files.txt."
expect_equal "3.1.7" "Ensure 'log_truncate_on_rotation' is enabled" \
  "$LOG_TRUNCATE" "on" "Recurring filenames are safely truncated at time-based rotation."

if [[ "$LOG_AGE" =~ ^[0-9]+$ ]] && [ "$LOG_AGE" -gt 0 ] && [ "$LOG_AGE" -le 1440 ]; then
  add_control "3.1.8" "Ensure the maximum log file lifetime is set correctly" "PASS" \
    "log_rotation_age=${LOG_AGE} minutes" "Files rotate at least daily; customer retention policy must also cover removal and off-host retention."
else
  add_control "3.1.8" "Ensure the maximum log file lifetime is set correctly" "FAIL" \
    "log_rotation_age=${LOG_AGE:-<empty>} minutes" "Expected a non-zero rotation age no greater than one day."
fi

if [ "$LOG_SIZE" = "0" ] && [[ "$LOG_AGE" =~ ^[0-9]+$ ]] && [ "$LOG_AGE" -gt 0 ]; then
  add_control "3.1.9" "Ensure the maximum log file size is set correctly" "REVIEW" \
    "log_rotation_size=0 kB; log_rotation_age=${LOG_AGE} minutes" \
    "Size-based rotation is disabled; daily age-based rotation is active. Customer logging policy must accept this exception or set a non-zero limit."
elif [[ "$LOG_SIZE" =~ ^[0-9]+$ ]] && [ "$LOG_SIZE" -gt 0 ]; then
  add_control "3.1.9" "Ensure the maximum log file size is set correctly" "PASS" \
    "log_rotation_size=${LOG_SIZE} kB" "A non-zero maximum file size is configured."
else
  add_control "3.1.9" "Ensure the maximum log file size is set correctly" "FAIL" \
    "log_rotation_size=${LOG_SIZE:-<empty>} kB" "No valid size or age-based rotation policy was detected."
fi

if [[ ",$LOG_DESTINATION," == *,syslog,* ]]; then
  add_control "3.1.10" "Ensure the correct syslog facility is selected" "REVIEW" \
    "syslog_facility=$SYSLOG_FACILITY" "Manual confirmation against the customer's syslog routing policy is required."
  expect_equal "3.1.11" "Ensure syslog messages are not suppressed" \
    "$SYSLOG_SEQUENCE" "on" "Sequence numbers prevent repeated messages from being silently collapsed."
  expect_equal "3.1.12" "Ensure syslog messages are not lost due to size" \
    "$SYSLOG_SPLIT" "on" "Long messages are split for syslog transport."
  if [ -n "$SYSLOG_IDENT" ]; then
    add_control "3.1.13" "Ensure the program name for PostgreSQL syslog messages is correct" "PASS" \
      "syslog_ident=$SYSLOG_IDENT" "The program identifier is explicit."
  else
    add_control "3.1.13" "Ensure the program name for PostgreSQL syslog messages is correct" "FAIL" \
      "syslog_ident is empty" "Set a unique PostgreSQL syslog identifier."
  fi
else
  add_control "3.1.10" "Ensure the correct syslog facility is selected" "N/A" \
    "log_destination=$LOG_DESTINATION; syslog_facility=$SYSLOG_FACILITY" "Syslog is not an active PostgreSQL destination."
  add_control "3.1.11" "Ensure syslog messages are not suppressed" "N/A" \
    "log_destination=$LOG_DESTINATION; syslog_sequence_numbers=$SYSLOG_SEQUENCE" "Syslog is not an active PostgreSQL destination."
  add_control "3.1.12" "Ensure syslog messages are not lost due to size" "N/A" \
    "log_destination=$LOG_DESTINATION; syslog_split_messages=$SYSLOG_SPLIT" "Syslog is not an active PostgreSQL destination."
  add_control "3.1.13" "Ensure the program name for PostgreSQL syslog messages is correct" "N/A" \
    "log_destination=$LOG_DESTINATION; syslog_ident=$SYSLOG_IDENT" "Syslog is not an active PostgreSQL destination."
fi

expect_equal "3.1.14" "Ensure the correct messages are written to the server log" \
  "$LOG_MIN_MESSAGES" "warning" "WARNING and more severe server messages are logged."
expect_equal "3.1.15" "Ensure the correct SQL statements generating errors are recorded" \
  "$LOG_MIN_ERROR" "error" "SQL statements producing ERROR or more severe messages are logged."
expect_equal "3.1.16" "Ensure 'debug_print_parse' is disabled" "$(setting debug_print_parse)" "off" "Parse trees can expose sensitive query details."
expect_equal "3.1.17" "Ensure 'debug_print_rewritten' is disabled" "$(setting debug_print_rewritten)" "off" "Rewritten parse trees can expose sensitive query details."
expect_equal "3.1.18" "Ensure 'debug_print_plan' is disabled" "$(setting debug_print_plan)" "off" "Execution plans are not emitted for every query."
expect_equal "3.1.19" "Ensure 'debug_pretty_print' is enabled" "$(setting debug_pretty_print)" "on" "Debug output remains readable if explicitly enabled."
expect_equal "3.1.20" "Ensure 'log_connections' is enabled" "$LOG_CONNECTIONS" "on" "Connection attempts and authentication completion are logged."
expect_equal "3.1.21" "Ensure 'log_disconnections' is enabled" "$LOG_DISCONNECTIONS" "on" "Session termination is logged."

if [ "$LOG_ERROR_VERBOSITY" = "default" ] || [ "$LOG_ERROR_VERBOSITY" = "verbose" ]; then
  add_control "3.1.22" "Ensure 'log_error_verbosity' is set correctly" "PASS" \
    "log_error_verbosity=$LOG_ERROR_VERBOSITY" "TERSE is rejected; DEFAULT or VERBOSE preserves diagnostic context."
else
  add_control "3.1.22" "Ensure 'log_error_verbosity' is set correctly" "FAIL" \
    "log_error_verbosity=${LOG_ERROR_VERBOSITY:-<empty>}" "Expected DEFAULT or VERBOSE."
fi

expect_equal "3.1.23" "Ensure 'log_hostname' is set correctly" "$LOG_HOSTNAME" "off" "Client addresses remain available through %h without reverse-DNS latency."

PREFIX_MISSING=""
for token in '%m' '%p' '%u' '%d' '%h'; do
  [[ "$LOG_LINE_PREFIX" == *"$token"* ]] || PREFIX_MISSING="$PREFIX_MISSING $token"
done
if [ -z "$PREFIX_MISSING" ]; then
  add_control "3.1.24" "Ensure 'log_line_prefix' is set correctly" "PASS" \
    "log_line_prefix=$LOG_LINE_PREFIX" "Timestamp, process, database, user, and client address are present."
else
  add_control "3.1.24" "Ensure 'log_line_prefix' is set correctly" "FAIL" \
    "log_line_prefix=$LOG_LINE_PREFIX; missing=$PREFIX_MISSING" "Required forensic context fields are missing."
fi

if [ "$LOG_STATEMENT" = "ddl" ] || [ "$LOG_STATEMENT" = "mod" ] || [ "$LOG_STATEMENT" = "all" ]; then
  add_control "3.1.25" "Ensure 'log_statement' is set correctly" "PASS" \
    "log_statement=$LOG_STATEMENT" "DDL is logged. pgAudit provides additional configured audit classes."
else
  add_control "3.1.25" "Ensure 'log_statement' is set correctly" "FAIL" \
    "log_statement=${LOG_STATEMENT:-<empty>}" "Expected ddl, mod, or all."
fi

expect_equal "3.1.26" "Ensure 'log_timezone' is set correctly" "$LOG_TIMEZONE" "UTC" "UTC provides consistent cross-system incident timelines."

PGAUDIT_EXTENSION="$(psql_scalar "SELECT count(*) FROM pg_extension WHERE extname='pgaudit';")"
PGAUDIT_LOG="$(psql_scalar "SELECT current_setting('pgaudit.log', true);")"
if [[ ",$PRELOAD_LIBS," == *,pgaudit,* ]] && [ "$PGAUDIT_EXTENSION" = "1" ] && [ -n "$PGAUDIT_LOG" ] && [ "$PGAUDIT_LOG" != "none" ]; then
  add_control "3.2" "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled" "PASS" \
    "preloaded=yes; extension=yes; pgaudit.log=$PGAUDIT_LOG; extensions.csv" "pgAudit is loaded and active in the audited database."
else
  add_control "3.2" "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled" "FAIL" \
    "shared_preload_libraries=$PRELOAD_LIBS; extension_count=$PGAUDIT_EXTENSION; pgaudit.log=${PGAUDIT_LOG:-<empty>}" "Preload, extension creation, and a non-none audit class are all required."
fi

# 4 User Access and Authorization
SUPERUSERS="$(psql_scalar "SELECT coalesce(string_agg(rolname, ',' ORDER BY rolname), 'none') FROM pg_roles WHERE rolsuper;")"
CREATEROLES="$(psql_scalar "SELECT coalesce(string_agg(rolname, ',' ORDER BY rolname), 'none') FROM pg_roles WHERE rolcreaterole;")"
add_control "4.3" "Ensure excessive administrative privileges are revoked" "REVIEW" \
  "superusers=$SUPERUSERS; createrole_roles=$CREATEROLES; roles.csv" \
  "Manual owner approval is required. Application traffic must not use a superuser or CREATEROLE role."

PUBLIC_FUNCTION_GRANTS="$(psql_scalar "
  SELECT count(*) FROM information_schema.role_routine_grants
  WHERE grantee='PUBLIC' AND routine_schema NOT IN ('pg_catalog','information_schema','spock');")"
if [ "$PUBLIC_FUNCTION_GRANTS" = "0" ]; then
  add_control "4.5" "Ensure excessive function privileges are revoked" "PASS" \
    "PUBLIC non-system routine grants=0; privileges.csv" "No non-system routine EXECUTE grants to PUBLIC were found."
else
  add_control "4.5" "Ensure excessive function privileges are revoked" "FAIL" \
    "PUBLIC non-system routine grants=$PUBLIC_FUNCTION_GRANTS; privileges.csv" "Review and revoke unnecessary PUBLIC EXECUTE privileges, including existing functions."
fi

PUBLIC_DML_GRANTS="$(psql_scalar "
  SELECT count(*) FROM information_schema.role_table_grants
  WHERE grantee='PUBLIC'
    AND table_schema NOT IN ('pg_catalog','information_schema','spock')
    AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE');")"
if [ "$PUBLIC_DML_GRANTS" = "0" ]; then
  add_control "4.6" "Ensure excessive DML privileges are revoked" "REVIEW" \
    "PUBLIC DML grants=0; privileges.csv" "No PUBLIC DML grants were found; named application-role grants still require data-owner review."
else
  add_control "4.6" "Ensure excessive DML privileges are revoked" "FAIL" \
    "PUBLIC DML grants=$PUBLIC_DML_GRANTS; privileges.csv" "PUBLIC must not receive blanket DML privileges."
fi

USER_TABLES="$(psql_scalar "
  SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema','spock');")"
RLS_TABLES="$(psql_scalar "
  SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p') AND c.relrowsecurity
    AND n.nspname NOT IN ('pg_catalog','information_schema','spock');")"
RLS_POLICIES="$(psql_scalar "SELECT count(*) FROM pg_policies WHERE schemaname NOT IN ('pg_catalog','information_schema','spock');")"
add_control "4.7" "Ensure Row Level Security (RLS) is configured correctly" "REVIEW" \
  "user_tables=$USER_TABLES; rls_enabled_tables=$RLS_TABLES; policies=$RLS_POLICIES; rls.csv" \
  "RLS is data-model-specific. Run after application migrations and obtain the data owner's table-by-table approval."

SET_USER_EXTENSION="$(psql_scalar "SELECT count(*) FROM pg_extension WHERE extname='set_user';")"
if [[ ",$PRELOAD_LIBS," == *,set_user,* ]] && [ "$SET_USER_EXTENSION" = "1" ]; then
  add_control "4.8" "Ensure the set_user extension is installed" "PASS" \
    "preloaded=yes; extension=yes; extensions.csv" "set_user is preloaded and installed in the audited database."
else
  add_control "4.8" "Ensure the set_user extension is installed" "FAIL" \
    "shared_preload_libraries=$PRELOAD_LIBS; extension_count=$SET_USER_EXTENSION" "Enable PG_SET_USER and recreate or correctly reconfigure the cluster."
fi

PREDEFINED_MEMBERS="$(psql_scalar "
  SELECT coalesce(string_agg(member.rolname || '->' || parent.rolname, ',' ORDER BY member.rolname,parent.rolname), 'none')
  FROM pg_auth_members m
  JOIN pg_roles parent ON parent.oid=m.roleid
  JOIN pg_roles member ON member.oid=m.member
  WHERE parent.rolname LIKE 'pg_%';")"
if [ "$PREDEFINED_MEMBERS" != "none" ]; then
  add_control "4.9" "Make use of predefined roles" "PASS" \
    "memberships=$PREDEFINED_MEMBERS; roles.csv" "At least one purpose-specific role uses a PostgreSQL predefined role."
else
  add_control "4.9" "Make use of predefined roles" "REVIEW" \
    "predefined role memberships=none; roles.csv" "Use pg_monitor, pg_read_all_stats, or narrower predefined roles instead of superuser access where appropriate."
fi

# 5.6 Password complexity
if [[ ",$PRELOAD_LIBS," == *,passwordcheck,* ]]; then
  add_control "5.6" "Ensure Password Complexity is configured" "PASS" \
    "passwordcheck is in shared_preload_libraries" "Static evidence confirms enforcement is loaded; CI should retain a negative weak-password test."
else
  add_control "5.6" "Ensure Password Complexity is configured" "FAIL" \
    "shared_preload_libraries=$PRELOAD_LIBS" "passwordcheck is not preloaded."
fi

# 6 PostgreSQL Settings. These controls require inventory plus owner review;
# the report provides the complete redacted inventory as supporting evidence.
ROLE_SETTING_OVERRIDES="$(psql_scalar "SELECT count(*) FROM pg_db_role_setting;")"
BACKEND_NONDEFAULT="$(psql_scalar "SELECT count(*) FROM pg_settings WHERE context='backend' AND source NOT IN ('default','override');")"
if [ "$ROLE_SETTING_OVERRIDES" = "0" ] && [ "$BACKEND_NONDEFAULT" = "0" ]; then
  add_control "6.2" "Ensure 'backend' runtime parameters are configured correctly" "PASS" \
    "backend non-default settings=0; role/database overrides=0; runtime-parameters.csv" "No unexpected backend-context overrides were found."
else
  add_control "6.2" "Ensure 'backend' runtime parameters are configured correctly" "REVIEW" \
    "backend non-default settings=$BACKEND_NONDEFAULT; role/database overrides=$ROLE_SETTING_OVERRIDES; runtime-parameters.csv" "Review all connection-start and role/database overrides."
fi

for runtime_spec in \
  "6.3|Postmaster|postmaster" \
  "6.4|SIGHUP|sighup" \
  "6.5|Superuser|superuser" \
  "6.6|User|user"; do
  IFS='|' read -r control_id label context <<< "$runtime_spec"
  PARAM_COUNT="$(psql_scalar "SELECT count(*) FROM pg_settings WHERE context='$context';")"
  NONDEFAULT_COUNT="$(psql_scalar "SELECT count(*) FROM pg_settings WHERE context='$context' AND source NOT IN ('default','override');")"
  add_control "$control_id" "Ensure '$label' Runtime Parameters are Configured" "REVIEW" \
    "context=$context; parameters=$PARAM_COUNT; non-default=$NONDEFAULT_COUNT; runtime-parameters.csv" \
    "CIS requires manual review against the approved configuration baseline; no universal value is valid for every deployment."
done

NON_SSL_HOST_RULES="$(psql_scalar "
  SELECT count(*) FROM pg_hba_file_rules
  WHERE type='host' AND error IS NULL
    AND coalesce(address,'') NOT IN ('127.0.0.1','::1');")"
if [ "$SSL" != "on" ]; then
  add_control "6.8" "Ensure TLS is enabled and configured correctly" "FAIL" \
    "ssl=$SSL; ssl_min_protocol_version=$SSL_MIN_PROTOCOL; tls.txt; hba-rules.csv" "TLS is disabled."
elif [ "$NON_SSL_HOST_RULES" != "0" ]; then
  add_control "6.8" "Ensure TLS is enabled and configured correctly" "FAIL" \
    "ssl=on; min_protocol=$SSL_MIN_PROTOCOL; non-loopback host rules permitting non-TLS=$NON_SSL_HOST_RULES; tls.txt; hba-rules.csv" \
    "The server supports TLS, but pg_hba.conf does not enforce hostssl for network clients. Certificate trust also requires customer review."
elif [ "$SSL_MIN_PROTOCOL" = "TLSv1.2" ] || [ "$SSL_MIN_PROTOCOL" = "TLSv1.3" ]; then
  add_control "6.8" "Ensure TLS is enabled and configured correctly" "REVIEW" \
    "ssl=on; min_protocol=$SSL_MIN_PROTOCOL; non-loopback non-TLS host rules=0; tls.txt; hba-rules.csv" \
    "Transport enforcement is present; verify certificate chain, hostname, expiry, and approved ciphers."
else
  add_control "6.8" "Ensure TLS is enabled and configured correctly" "FAIL" \
    "ssl=on; min_protocol=${SSL_MIN_PROTOCOL:-<empty>}; tls.txt; hba-rules.csv" "TLS minimum protocol is below the approved baseline."
fi

PGCRYPTO_EXTENSION="$(psql_scalar "SELECT count(*) FROM pg_extension WHERE extname='pgcrypto';")"
if [ "$PGCRYPTO_EXTENSION" = "1" ]; then
  add_control "6.11" "Ensure the pgcrypto extension is installed and configured correctly" "PASS" \
    "pgcrypto extension installed; extensions.csv" "Applications must still use appropriate cryptographic functions and key management."
else
  add_control "6.11" "Ensure the pgcrypto extension is installed and configured correctly" "FAIL" \
    "pgcrypto extension count=$PGCRYPTO_EXTENSION; extensions.csv" "Enable PG_PGCRYPTO and install the extension in every application database."
fi

# 7 Replication
REPLICATION_ROLES="$(psql_scalar "
  SELECT coalesce(string_agg(rolname, ',' ORDER BY rolname), 'none')
  FROM pg_roles WHERE rolreplication AND NOT rolsuper;")"
REPLICATION_SESSIONS="$(psql_scalar "SELECT count(*) FROM pg_stat_replication;")"
BAD_REPLICATION_SESSIONS="$(psql_scalar "
  SELECT count(*) FROM pg_stat_replication s
  LEFT JOIN pg_roles r ON r.rolname=s.usename
  WHERE coalesce(r.rolsuper,true) OR NOT coalesce(r.rolreplication,false);")"
REPLICATION_USERS="$(psql_scalar "SELECT coalesce(string_agg(DISTINCT usename, ','), 'none') FROM pg_stat_replication;")"
if [ "$REPLICATION_ROLES" = "none" ]; then
  add_control "7.1" "Ensure a replication-only user is created and used for streaming replication" "FAIL" \
    "non-superuser replication roles=none; active replication users=$REPLICATION_USERS; roles.csv; replication.csv" "No dedicated replication-only role exists."
elif [ "$REPLICATION_SESSIONS" = "0" ]; then
  add_control "7.1" "Ensure a replication-only user is created and used for streaming replication" "REVIEW" \
    "replication roles=$REPLICATION_ROLES; active sessions=0; roles.csv; replication.csv" "The role exists, but no active session proves it is used. Run against the complete cluster."
elif [ "$BAD_REPLICATION_SESSIONS" = "0" ]; then
  add_control "7.1" "Ensure a replication-only user is created and used for streaming replication" "PASS" \
    "replication roles=$REPLICATION_ROLES; active users=$REPLICATION_USERS; replication.csv" "Every active WAL sender uses a non-superuser replication role."
else
  add_control "7.1" "Ensure a replication-only user is created and used for streaming replication" "FAIL" \
    "replication roles=$REPLICATION_ROLES; active users=$REPLICATION_USERS; noncompliant sessions=$BAD_REPLICATION_SESSIONS; replication.csv" "At least one active WAL sender uses a superuser or non-dedicated role."
fi

expect_equal "7.2" "Ensure logging of replication commands is configured" \
  "$(setting log_replication_commands)" "on" "Replication commands are recorded in the server log."

ARCHIVE_MODE="$(setting archive_mode)"
ARCHIVE_COMMAND_SET="$(psql_scalar "SELECT CASE WHEN setting <> '' AND setting <> '(disabled)' THEN 'yes' ELSE 'no' END FROM pg_settings WHERE name='archive_command';")"
LAST_ARCHIVED_WAL="$(psql_scalar "SELECT coalesce(last_archived_wal, 'none') FROM pg_stat_archiver;")"
if [ -n "${CIS_BASE_BACKUP_EVIDENCE:-}" ] && [ -s "${CIS_BASE_BACKUP_EVIDENCE:-}" ]; then
  add_control "7.3" "Ensure base backups are configured and functional" "PASS" \
    "operator evidence=$CIS_BASE_BACKUP_EVIDENCE; archive_mode=$ARCHIVE_MODE; last_archived_wal=$LAST_ARCHIVED_WAL" \
    "The supplied artifact must document a successful restore, not only backup creation."
else
  add_control "7.3" "Ensure base backups are configured and functional" "REVIEW" \
    "archive_mode=$ARCHIVE_MODE; archive_command_set=$ARCHIVE_COMMAND_SET; last_archived_wal=$LAST_ARCHIVED_WAL" \
    "No independent physical base-backup and restore artifact was supplied. Logical pg_dump evidence does not satisfy this control."
fi

WAL_RECEIVERS="$(psql_scalar "SELECT count(*) FROM pg_stat_wal_receiver;")"
SPOCK_EXTENSION="$(psql_scalar "SELECT count(*) FROM pg_extension WHERE extname='spock';")"
if [ "$WAL_RECEIVERS" != "0" ] && [ "$MAX_WAL_SENDERS" -gt 0 ] && [ "$MAX_REPLICATION_SLOTS" -gt 0 ]; then
  add_control "7.5" "Ensure streaming replication parameters are configured correctly" "PASS" \
    "wal_level=$WAL_LEVEL; max_wal_senders=$MAX_WAL_SENDERS; max_replication_slots=$MAX_REPLICATION_SLOTS; hot_standby=$HOT_STANDBY; wal_receivers=$WAL_RECEIVERS" \
    "An active physical WAL receiver and non-zero sender/slot capacity were detected."
elif [ "$SPOCK_EXTENSION" = "1" ]; then
  add_control "7.5" "Ensure streaming replication parameters are configured correctly" "REVIEW" \
    "wal_level=$WAL_LEVEL; max_wal_senders=$MAX_WAL_SENDERS; max_replication_slots=$MAX_REPLICATION_SLOTS; hot_standby=$HOT_STANDBY; physical_wal_receivers=$WAL_RECEIVERS; spock=yes" \
    "This deployment uses Spock logical active-active replication rather than physical streaming replication. Customer approval of an architectural exception is required."
else
  add_control "7.5" "Ensure streaming replication parameters are configured correctly" "FAIL" \
    "wal_level=$WAL_LEVEL; max_wal_senders=$MAX_WAL_SENDERS; max_replication_slots=$MAX_REPLICATION_SLOTS; hot_standby=$HOT_STANDBY; physical_wal_receivers=$WAL_RECEIVERS" \
    "No active physical streaming receiver or documented logical-replication architecture was detected."
fi

PASS_COUNT=0
FAIL_COUNT=0
REVIEW_COUNT=0
NA_COUNT=0
for status in "${CONTROL_STATUSES[@]}"; do
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    REVIEW) REVIEW_COUNT=$((REVIEW_COUNT + 1)) ;;
    N/A) NA_COUNT=$((NA_COUNT + 1)) ;;
  esac
done

if [ "$FAIL_COUNT" -gt 0 ]; then
  OVERALL="FAIL"
elif [ "$REVIEW_COUNT" -gt 0 ]; then
  OVERALL="REVIEW REQUIRED"
else
  OVERALL="PASS"
fi

REPORT_MD="$REPORT_DIR/report.md"
REPORT_CSV="$REPORT_DIR/report.csv"
REPORT_HTML="$REPORT_DIR/report.html"

{
  printf '# CIS PostgreSQL 17 Customer Evidence Report\n\n'
  printf 'This report covers the customer-requested subset of the CIS PostgreSQL 17 Benchmark v1.0.0. '
  printf 'It is technical evidence, not a CIS certification. Controls marked REVIEW require named owner approval.\n\n'
  printf -- '- Generated (UTC): `%s`\n' "$GENERATED_AT"
  printf -- '- Customer: `%s`\n' "$(safe_text "$CUSTOMER_NAME")"
  printf -- '- Environment: `%s`\n' "$(safe_text "$AUDIT_ENVIRONMENT")"
  printf -- '- Auditor: `%s`\n' "$(safe_text "$AUDITOR_NAME")"
  printf -- '- Report version: `%s`\n' "$(safe_text "$REPORT_VERSION")"
  printf -- '- PostgreSQL: `%s`\n' "$(safe_text "$SERVER_VERSION")"
  printf -- '- Container: `%s`\n' "$(safe_text "$NODE")"
  printf -- '- Database: `%s`\n' "$(safe_text "$DB")"
  printf -- '- Image ID: `%s`\n' "$(safe_text "$IMAGE_ID")"
  printf -- '- Git commit: `%s`\n' "$(safe_text "$COMMIT")"
  printf -- '- Git worktree: `%s`\n' "$(safe_text "$GIT_STATE")"
  printf -- '- Audit script SHA-256: `%s`\n' "$(safe_text "$SCRIPT_SHA256")"
  printf -- '- Overall: **%s**\n' "$OVERALL"
  printf -- '- Summary: **%d PASS**, **%d FAIL**, **%d REVIEW**, **%d N/A**\n\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$REVIEW_COUNT" "$NA_COUNT"
  printf '| CIS | Security Detail | Status | Evidence | Comment |\n'
  printf '|---|---|---:|---|---|\n'
  for i in "${!CONTROL_IDS[@]}"; do
    printf '| %s | %s | **%s** | %s | %s |\n' \
      "$(safe_text "${CONTROL_IDS[$i]}")" \
      "$(safe_text "${CONTROL_TITLES[$i]}")" \
      "$(safe_text "${CONTROL_STATUSES[$i]}")" \
      "$(safe_text "${CONTROL_EVIDENCE[$i]}")" \
      "$(safe_text "${CONTROL_COMMENTS[$i]}")"
  done
  printf '\n## Supporting evidence\n\n'
  printf -- '- `settings.csv`: effective security-relevant PostgreSQL settings\n'
  printf -- '- `extensions.csv`: installed extensions and versions\n'
  printf -- '- `roles.csv`: role capabilities and memberships, without password hashes\n'
  printf -- '- `privileges.csv`: table and routine grants\n'
  printf -- '- `rls.csv`: per-table RLS state and policy counts\n'
  printf -- '- `runtime-parameters.csv`: redacted inventory grouped by runtime context\n'
  printf -- '- `hba-rules.csv`: parsed client-authentication rules\n'
  printf -- '- `replication.csv`: active WAL sender users and state\n'
  printf -- '- `log-files.txt`: actual log-file modes, owners, sizes, and names\n'
  printf -- '- `tls.txt`: public certificate metadata only; no private key material\n'
  printf -- '- `SHA256SUMS`: integrity manifest for every evidence file\n'
} > "$REPORT_MD"

{
  printf 'CIS,Security Detail,Status,Evidence,Comment\n'
  for i in "${!CONTROL_IDS[@]}"; do
    csv_text "${CONTROL_IDS[$i]}"; printf ','
    csv_text "${CONTROL_TITLES[$i]}"; printf ','
    csv_text "${CONTROL_STATUSES[$i]}"; printf ','
    csv_text "${CONTROL_EVIDENCE[$i]}"; printf ','
    csv_text "${CONTROL_COMMENTS[$i]}"; printf '\n'
  done
} > "$REPORT_CSV"

{
  printf '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
  printf '<title>%s — CIS PostgreSQL 17 Customer Evidence Report</title>\n' "$(html_text "$CUSTOMER_NAME")"
  printf '<style>\n'
  printf '%s\n' ':root{--ink:#172033;--muted:#5c667a;--line:#d9deea;--paper:#fff;--bg:#f3f5f9;--pass:#16794b;--fail:#b42318;--review:#9a6700;--na:#52606d}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 Arial,Helvetica,sans-serif}.page{max-width:1320px;margin:28px auto;background:var(--paper);padding:44px;box-shadow:0 8px 30px #17203318}h1{font-size:28px;margin:0 0 6px}h2{margin:34px 0 12px;font-size:19px}.subtitle{color:var(--muted);margin-bottom:24px}.meta{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px 28px;padding:18px;background:#f8f9fc;border:1px solid var(--line);border-radius:8px}.meta div{display:grid;grid-template-columns:150px 1fr;gap:8px}.meta b{color:var(--muted)}.summary{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}.card{min-width:120px;padding:14px 18px;border:1px solid var(--line);border-radius:8px}.card strong{display:block;font-size:24px}.overall{border-width:2px}.PASS{color:var(--pass)}.FAIL{color:var(--fail)}.REVIEW{color:var(--review)}.NA{color:var(--na)}table{width:100%;border-collapse:collapse;margin:12px 0 24px}th,td{border:1px solid var(--line);padding:9px 10px;text-align:left;vertical-align:top}th{background:#eef1f6;font-size:12px;text-transform:uppercase;letter-spacing:.04em}td:first-child{white-space:nowrap;font-weight:700}.status{font-weight:700;white-space:nowrap}.notice{border-left:4px solid var(--review);background:#fff8e6;padding:12px 16px;margin:18px 0}.failnotice{border-left-color:var(--fail);background:#fff1f0}.files{columns:2}.files li{margin:5px 0}.sign td{height:58px}.footer{margin-top:34px;padding-top:14px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}@media(max-width:800px){.page{margin:0;padding:20px}.meta{grid-template-columns:1fr}.files{columns:1}table{font-size:12px}}@media print{body{background:#fff}.page{max-width:none;margin:0;padding:18mm;box-shadow:none}thead{display:table-header-group}tr{break-inside:avoid}.no-print{display:none}@page{size:A4 landscape;margin:10mm}}'
  printf '</style></head><body><main class="page">\n'
  printf '<h1>CIS PostgreSQL 17 Customer Evidence Report</h1>\n'
  printf '<div class="subtitle">%s · Customer-requested 44-control security assessment · Report v%s</div>\n' "$(html_text "$CUSTOMER_NAME")" "$(html_text "$REPORT_VERSION")"
  if [ "$GIT_STATE" != "clean" ]; then
    printf '<div class="notice failnotice"><strong>DRAFT — NOT APPROVABLE:</strong> the repository worktree was dirty when this evidence was generated.</div>\n'
  fi
  printf '<section class="meta">\n'
  printf '<div><b>Customer</b><span>%s</span></div>\n' "$(html_text "$CUSTOMER_NAME")"
  printf '<div><b>Environment</b><span>%s</span></div>\n' "$(html_text "$AUDIT_ENVIRONMENT")"
  printf '<div><b>Auditor</b><span>%s</span></div>\n' "$(html_text "$AUDITOR_NAME")"
  printf '<div><b>Generated UTC</b><span>%s</span></div>\n' "$(html_text "$GENERATED_AT")"
  printf '<div><b>PostgreSQL</b><span>%s</span></div>\n' "$(html_text "$SERVER_VERSION")"
  printf '<div><b>Container / DB</b><span>%s / %s</span></div>\n' "$(html_text "$NODE")" "$(html_text "$DB")"
  printf '<div><b>Image ID</b><span>%s</span></div>\n' "$(html_text "$IMAGE_ID")"
  printf '<div><b>Git commit</b><span>%s (%s)</span></div>\n' "$(html_text "$COMMIT")" "$(html_text "$GIT_STATE")"
  printf '<div><b>Audit script SHA-256</b><span>%s</span></div>\n' "$(html_text "$SCRIPT_SHA256")"
  printf '</section>\n'
  printf '<h2>Scope and methodology</h2><p>This document assesses the 44 PostgreSQL security controls supplied by the customer from the CIS PostgreSQL 17 Benchmark v1.0.0. Evidence is collected from effective <code>pg_settings</code>, PostgreSQL catalogs, parsed HBA rules, extension and role inventories, active replication state, TLS certificate metadata, and actual log-file attributes. Manual controls remain REVIEW until signed by an authorized owner. This report is technical assessment evidence and is not a CIS certification.</p>\n'
  OVERALL_CLASS="${OVERALL%% *}"
  printf '<section class="summary"><div class="card overall %s"><span>Overall</span><strong>%s</strong></div>' "$(html_text "$OVERALL_CLASS")" "$(html_text "$OVERALL")"
  printf '<div class="card PASS"><span>Pass</span><strong>%d</strong></div>' "$PASS_COUNT"
  printf '<div class="card FAIL"><span>Fail</span><strong>%d</strong></div>' "$FAIL_COUNT"
  printf '<div class="card REVIEW"><span>Review</span><strong>%d</strong></div>' "$REVIEW_COUNT"
  printf '<div class="card NA"><span>N/A</span><strong>%d</strong></div></section>\n' "$NA_COUNT"
  printf '<div class="notice"><strong>Approval rule:</strong> both nodes must have zero FAIL rows; every REVIEW and N/A row requires documented owner acceptance; SHA256SUMS and production image IDs must match.</div>\n'
  printf '<h2>Control assessment</h2>\n<table><thead><tr><th>CIS</th><th>Security Detail</th><th>Status</th><th>Evidence</th><th>Comment</th></tr></thead><tbody>\n'
  for i in "${!CONTROL_IDS[@]}"; do
    status_class="${CONTROL_STATUSES[$i]//\//}"
    status_class="${status_class// /}"
    printf '<tr><td>%s</td><td>%s</td><td class="status %s">%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$(html_text "${CONTROL_IDS[$i]}")" \
      "$(html_text "${CONTROL_TITLES[$i]}")" \
      "$(html_text "$status_class")" \
      "$(html_text "${CONTROL_STATUSES[$i]}")" \
      "$(html_text "${CONTROL_EVIDENCE[$i]}")" \
      "$(html_text "${CONTROL_COMMENTS[$i]}")"
  done
  printf '</tbody></table>\n'
  printf '<h2>Supporting evidence</h2><ul class="files">\n'
  for evidence_file in settings.csv extensions.csv roles.csv privileges.csv rls.csv runtime-parameters.csv hba-rules.csv replication.csv log-files.txt tls.txt report.md report.csv; do
    printf '<li><a href="%s">%s</a></li>\n' "$(html_text "$evidence_file")" "$(html_text "$evidence_file")"
  done
  printf '</ul>\n'
  printf '<h2>Review and sign-off</h2><table class="sign"><tr><th>Role</th><th>Name</th><th>Decision / Exceptions</th><th>Date</th><th>Signature</th></tr><tr><td>Database owner</td><td></td><td></td><td></td><td></td></tr><tr><td>Security reviewer</td><td></td><td></td><td></td><td></td></tr><tr><td>Customer approver</td><td></td><td></td><td></td><td></td></tr></table>\n'
  printf '<p class="no-print"><strong>PDF:</strong> open this file in a browser and choose Print → Save as PDF. Keep the complete evidence directory with the PDF.</p>\n'
  printf '<div class="footer">Generated by the repository customer audit script. Verify all accompanying files with <code>sha256sum -c SHA256SUMS</code>.</div>\n'
  printf '</main></body></html>\n'
} > "$REPORT_HTML"

(
  cd "$REPORT_DIR" || exit 2
  sha256sum \
    settings.csv extensions.csv roles.csv privileges.csv rls.csv \
    runtime-parameters.csv hba-rules.csv replication.csv log-files.txt \
    tls.txt report.md report.csv report.html > SHA256SUMS
)

printf 'CIS PostgreSQL 17 report: %s\n' "$OVERALL"
printf '  PASS=%d FAIL=%d REVIEW=%d N/A=%d\n' "$PASS_COUNT" "$FAIL_COUNT" "$REVIEW_COUNT" "$NA_COUNT"
printf '  Markdown: %s\n' "$REPORT_MD"
printf '  CSV:      %s\n' "$REPORT_CSV"
printf '  Document: %s\n' "$REPORT_HTML"
printf '  Verify:   (cd %s && sha256sum -c SHA256SUMS)\n' "$REPORT_DIR"

if [ "$CIS_ENFORCE" = "1" ]; then
  ENFORCE_FAILED=0
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '  GATE: rejected because %d automated control(s) failed.\n' "$FAIL_COUNT" >&2
    ENFORCE_FAILED=1
  fi
  if [ "$GIT_STATE" != "clean" ]; then
    printf '  GATE: rejected because git worktree state is %s; commit the audited release first.\n' "$GIT_STATE" >&2
    ENFORCE_FAILED=1
  fi
  if [ "$ENFORCE_FAILED" -eq 1 ]; then
    exit 1
  fi
fi
