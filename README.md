# va-voipbox-postgres

pgEdge multi-master PostgreSQL 17 cluster for VoIP infrastructure. Provides Spock-based bidirectional replication for the VoIPAppz database.

**Docker image:** `ghcr.io/voipappz/db:pgedge`

## Backup ownership

Mothership owns Ofelia and scheduled database backups. The database image contains no scheduler. Ofelia runs only in the `ci`
Compose profile for backup testing. Manual dump and restore commands remain available for
local development. PgCat and the second database node are optional (`ci` profile).

## Architecture

```
┌─────────────────────┐       Spock        ┌─────────────────────┐
│     pgedge-n1       │◄────replication────►│     pgedge-n2       │
│  PostgreSQL 17      │                    │  PostgreSQL 17      │
│  Spock + pgAudit    │                    │  Spock + pgAudit    │
│  prefix, pgcrypto   │                    │  prefix, pgcrypto   │
└─────────────────────┘                    └─────────────────────┘
```

- **Spock replication** — logical multi-master, both nodes writable
- **pgAudit** — session/object audit logging (`ddl,role` by default; see `PG_PGAUDIT_LOG`)
- **prefix** — telephone number prefix range type for LCR routing
- **SCRAM-SHA-256** — password encryption for all connections

## Databases

| Database    | Purpose                                    | Schema managed by |
|-------------|--------------------------------------------|-------------------|
| `voipappz`  | VoIP application                           | App migrations (`rake db:migrate`) |

`voipappz` is the only database this image provisions, and it ships extensions only (hstore, uuid-ossp, prefix, spock) — every table comes from the app's migrations. It is replicated active-active between both nodes.

Post-boot tables must use uuid keys: a `serial` PK generates the same ids on both masters and collides.

## Docker Image

The image is built from Ubuntu 24.04 and includes:

- **pgEdge Enterprise PostgreSQL 17** with logical replication
- **Spock** — multi-master replication extension (shared_preload_libraries)
- **prefix** — built from source (telephone prefix ranges for LCR)
- **pg_stat_statements** — query performance tracking
- Runs as `pgedge` user (non-root)
- Exposes port 5432 (PostgreSQL)

```bash
# Pull from GHCR
docker pull ghcr.io/voipappz/db:pgedge

# Or build locally
make build
```

## Quick Start

```bash
# 1. Initial setup (generates password, creates .env)
make setup

# 2. Start two-node cluster
make up

# 3. Check status
make status

# 4. Open psql
make psql                    # voipappz on n1
make psql NODE=pgedge-n2     # voipappz on n2
```

## Configuration

Create the environment file (generates `POSTGRES_PASSWORD`):

```bash
make setup
```

Key settings in `.env`:

| Variable                 | Default       | Description                       |
|--------------------------|---------------|-----------------------------------|
| `POSTGRES_PASSWORD`      | _(none)_      | postgres role password — **required** |
| `DB_USER`                | `postgres`    | Database superuser                |
| `DATABASES`              | `voipappz`    | Databases to create               |
| `SPOCK_DATABASES`        | `voipappz`    | Databases replicated active-active |
| `N1_PEER_HOST`           | `pgedge-n2`   | Peer hostname for node 1          |
| `N2_PEER_HOST`           | `pgedge-n1`   | Peer hostname for node 2          |
| `PG_MAX_CONNECTIONS`     | `250`         | Max PostgreSQL connections        |
| `PG_SHARED_BUFFERS`      | `1GB`         | Shared buffer memory              |
| `PG_EFFECTIVE_CACHE_SIZE`| `12GB`        | Planner cache size estimate       |
| `PG_WORK_MEM`            | `20971kB`     | Per-operation work memory         |
| `PG_MAINTENANCE_WORK_MEM`| `512MB`       | Maintenance operation memory      |

See `.env.example` for the full list including PostgreSQL tuning and S3 backup settings.

## Makefile Commands

### Cluster Lifecycle

```bash
make build          # Build Docker image
make verify         # Verify image contents (PG, extensions, init scripts)
make test           # Single-node smoke test
make setup          # Create .env with a generated POSTGRES_PASSWORD
make up             # Start both nodes
make down           # Stop both nodes
make logs           # Tail logs
make ps             # Show container status
make clean          # Remove containers, volumes, and image
```

### Database Operations

```bash
make psql                         # Interactive psql (voipappz on n1)
make psql NODE=pgedge-n2          # Connect to node 2
make shell                        # Bash shell on a node
make status                       # Cluster health: PG, Spock
```

### Backup & Restore

Dumps automatically exclude the `spock` replication schema (`-N spock`) so restores don't carry stale replication metadata. Spock is configured fresh by `init-node.sh` on each node.

```bash
# Dump all databases (default: custom format .dump)
make dump
make dump DUMP_FMT=tar            # .tar.gz format
make dump DUMP_FMT=sql            # .sql.gz format
make dump NODE=pgedge-n2          # Dump from node 2
make dump DUMP_DIR=./my-backups   # Custom output directory

# Dump a single database
make dump-db DB=voipappz
make dump-db DB=voipappz DUMP_FMT=tar

# Schema-only / data-only
make dump-schema
make dump-data
make dump-db-schema DB=voipappz
make dump-db-data DB=voipappz

# Restore all databases (auto-detects format by extension)
make restore                       # from ./backups/
make restore NODE=pgedge-n2
make restore DUMP_DIR=./my-backups

# Restore a single database
make restore-db DB=voipappz FILE=./backups/voipappz.dump
make restore-db DB=voipappz FILE=./backups/voipappz.tar.gz
make restore-db DB=voipappz FILE=./backups/voipappz.sql.gz
```

### S3 Backup

Requires `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` in `.env`.

Uses [nirlevi/postgres-backup-s3](https://github.com/nirlevi/postgres-backup-s3) — our fork of [eeshugerman/postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3), which exists because upstream publishes no `:17` tag (it stops at 16, and a PG16 `pg_dump` refuses a PG17 server). Dumps pass `-N spock` via `PGDUMP_EXTRA_OPTS`.

```bash
# Manual commands
make dump-s3                      # Backup all databases to S3
make dump-db-s3 DB=voipappz       # Backup single database
make restore-s3                   # Restore all from S3 (latest)
make restore-db-s3 DB=voipappz    # Restore single from S3
```

Optional `.env` settings for S3:

| Variable              | Default          | Description                     |
|-----------------------|------------------|---------------------------------|
| `S3_REGION`           | `eu-central-1`   | AWS region                      |
| `S3_BUCKET`           |                  | S3 bucket name (required)       |
| `S3_PREFIX`           | `pgedge-backups` | Key prefix in bucket            |
| `S3_ENDPOINT`         |                  | Custom endpoint (MinIO, etc.)   |
| `BACKUP_KEEP_DAYS`    | `7`              | Retention period                |
| `BACKUP_PASSPHRASE`   |                  | GPG encryption passphrase       |

## Production Deployment

For production, run one node per host with real hostnames:

```bash
# Host 1
N1_PEER_HOST=db2.example.com docker compose up pgedge-n1

# Host 2
N2_PEER_HOST=db1.example.com docker compose up pgedge-n2
```

### Security

- **Passwords**: From the `POSTGRES_PASSWORD` environment variable only — never baked into the image, and no secret file on disk
- **Encryption**: SCRAM-SHA-256 for all password authentication
- **Network**: `pg_hba.conf` allows only private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) — no 0.0.0.0/0
- **PostgREST**: removed 2026-08-03. It was an unused listener on :3000 whose `postgrest_auth` LOGIN role held SELECT over every table with a hardcoded password.
- **Audit**: pgAudit enabled cluster-wide; `passwordcheck` preloaded so weak passwords are rejected at `CREATE`/`ALTER ROLE`
- **Replication role**: set `PG_REPLICATION_PASSWORD` to get a non-superuser `replicator` role (CIS requires replication not run as superuser)
- **TLS**: opt-in via `PG_TLS=on` (self-signed generated when no cert is mounted at `PG_TLS_CERT`/`PG_TLS_KEY`)
- **Container**: Runs as non-root `pgedge` user

#### Customer CIS evidence

The repository can generate the customer-requested Evidence and Comment table
for the CIS PostgreSQL 17 Benchmark v1.0.0. Start the exact cluster being
assessed, then run:

```bash
make customer-audit                     # report only
make customer-audit-check               # report + non-zero exit on FAIL
make customer-audit NODE=pgedge-n2      # assess the other node
```

The output is written to `reports/cis-postgresql-17/` as a customer-ready HTML
document, Markdown, CSV, and supporting redacted evidence files. Open
`report.html` in a browser to deliver it directly or print it to PDF. The audit
is read-only and does not include
password hashes, password values, TLS private keys, or sensitive connection
strings. `REVIEW` controls are intentionally not auto-approved: privileges,
RLS policy coverage, runtime-parameter exceptions, certificate trust, and
backup/restore evidence require a named human owner.

See `docs/customer-cis-audit.md` for the independent customer procedure,
status definitions, integrity verification, and sign-off process.

For a physical base-backup control, provide an independent restore-test
artifact when generating the report:

```bash
CIS_BASE_BACKUP_EVIDENCE=/path/to/restore-test.txt make customer-audit
```

### Tuning

PostgreSQL is pre-configured for VoIP workloads. Override via environment variables:

```bash
PG_MAX_CONNECTIONS=500
PG_SHARED_BUFFERS=4GB
PG_EFFECTIVE_CACHE_SIZE=24GB
PG_WORK_MEM=64MB
```

Additional fixed settings (in `init-node.sh`):
- `wal_level = logical` (required for Spock)
- `max_worker_processes = 10`
- `max_replication_slots = 10`
- `max_wal_senders = 10`
- `track_commit_timestamp = on`
- `log_min_duration_statement = 1000` (log slow queries > 1s)

## CI Pipeline

GitHub Actions runs checks on pull requests and main pushes; main publishes only after all checks pass:

1. **build** — Build image, verify PostgreSQL 17, extensions (spock, prefix, pgaudit), init scripts
2. **test** — Single-node verification:
   - `voipappz` created with zero tables; freeswitch/kamailio/kong absent
   - Extensions (hstore, uuid-ossp, prefix, spock)
   - CIS logging/audit settings; event_store_events is NOT seeded
   - Dump/restore round-trip (custom, tar, SQL, schema-only, data-only)
3. **test-multi-node** — Two-node verification:
   - Spock bidirectional replication (n1 -> n2, n2 -> n1)
   - Security (SCRAM-SHA-256, pg_hba restrictions, no secrets in image)
   - PostgreSQL tuning parameters
   - DDL created on n1 replicates to n2 and joins a replication set
4. **push** — Publish to GHCR (`ghcr.io/voipappz/db:pgedge` + `:latest`)

## Project Structure

```
.
├── .github/workflows/image.yml # GitHub Actions checks and GHCR publishing
├── Dockerfile              # Image: Ubuntu 24.04 + pgEdge PG 17 + prefix
├── docker-compose.yml      # Two-node cluster + pgcat, with health checks
├── init-node.sh            # Entrypoint: PG cluster, DB init, CIS config, Spock replication
├── Makefile                # CLI: build, test, dump, restore, status, S3 backup
├── .env.example            # Configuration template (all defaults documented)
├── cluster.yaml            # Cluster topology definition (nodes, replication)
├── db.json                 # Cluster topology (JSON format)
└── sql/
    └── voipappz.sql        # Extensions only (ALL tables are managed by app migrations)
```

GHCR publishing uses the repository GITHUB_TOKEN.

GitHub Actions builds and runs the existing single-node and replication checks before
publishing `ghcr.io/voipappz/db:pgedge`, `:latest`, and `:sha-<commit>` on main.
It authenticates with the repository GITHUB_TOKEN; no Docker Hub credentials are needed.

TimescaleDB 2.31.0 is built and preloaded alongside Spock. Enable it explicitly
in the time-series database with CREATE EXTENSION timescaledb. Existing application
tables and Event Store schemas are not converted. Production backups remain in mothership.
