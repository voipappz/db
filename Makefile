IMAGE_NAME := ghcr.io/voipappz/db
IMAGE_TAG  := pgedge
COMPOSE    := docker compose
NODE       ?= pgedge-n1
DB_USER    ?= postgres
DUMP_DIR   ?= ./backups
DUMP_FMT   ?= custom
# Databases the loop targets operate on. voipappz is the only one this image
# provisions.
DATABASES  ?= voipappz

# S3 backup. Our fork of eeshugerman/postgres-backup-s3 -- upstream publishes
# no :17 tag (it stops at 16, and a PG16 pg_dump refuses a PG17 server).
# Source: https://github.com/nirlevi/postgres-backup-s3
S3_BACKUP_IMAGE := nirlevi/postgres-backup-s3:17
-include .env

.DEFAULT_GOAL := help

.PHONY: help build verify test customer-audit customer-audit-check cis-report cis-check up down logs clean ps \
        setup psql shell status \
        dump dump-db dump-schema dump-data dump-db-schema dump-db-data \
        restore restore-db \
        export export-db export-remote import import-db import-remote sync sync-db \
        backup-now backup-ls backup backup-list backup-restore \
        dump-s3 dump-db-s3 restore-s3 restore-db-s3

# ── Help ─────────────────────────────────────────────────────

help:
	@echo "va-voipbox-postgres — common commands"
	@echo ""
	@echo "Build & test:"
	@echo "  make build                       Build the Docker image"
	@echo "  make verify                      Verify image contents"
	@echo "  make test                        Single-node smoke test"
	@echo "  make customer-audit              Generate customer CIS evidence (running cluster)"
	@echo "  make customer-audit-check        Same report; fail when controls fail"
	@echo ""
	@echo "Cluster (local two-node dev):"
	@echo "  make setup                       Create .env + POSTGRES_PASSWORD, then 'make up'"
	@echo "  make up / down / logs / ps       Start, stop, tail, list"
	@echo "  make status                      PG health + Spock subscriptions"
	@echo "  make psql DB=voipappz            psql shell (NODE=pgedge-n2 for node 2)"
	@echo ""
	@echo "Export / import (DATABASES='$(DATABASES)', NODE=$(NODE)):"
	@echo "  make export                      Dump all DATABASES → $(DUMP_DIR)/"
	@echo "  make export-db DB=voipappz       Dump one database"
	@echo "  make import                      Restore all from $(DUMP_DIR)/"
	@echo "  make import-db DB=voipappz FILE=./backups/voipappz.dump"
	@echo ""
	@echo "Remote (live-safe: pg_dump takes an MVCC snapshot):"
	@echo "  make export-remote DB=voipappz REMOTE_HOST=203.0.113.7 REMOTE_PASSWORD=secret"
	@echo "  make import-remote DB=voipappz REMOTE_HOST=203.0.113.7 REMOTE_PASSWORD=secret"
	@echo "    Optional: REMOTE_PORT=5432 REMOTE_USER=postgres REMOTE_DB=<name-on-remote>"
	@echo "    Production container: add NODE=postgres"
	@echo ""
	@echo "Sync between nodes (no intermediate file):"
	@echo "  make sync                        All DATABASES, $(SRC) → $(DST)"
	@echo "  make sync-db DB=voipappz SRC=pgedge-n2 DST=pgedge-n1"
	@echo ""
	@echo "Scheduled backups are managed by mothership."
	@echo "  make backup-now / backup-ls      Manual local backups"
	@echo "  make backup / backup-list        backup.sh inside NODE (+ S3 when S3_BUCKET is set)"
	@echo "  make backup-restore FORCE=1 DB=voipappz [NAME=voipappz-<stamp>.dump]"
	@echo ""
	@echo "S3 backup (needs S3_* vars in .env):"
	@echo "  make dump-s3 / restore-s3        All databases"
	@echo "  make dump-db-s3 DB=voipappz      Single database"
	@echo ""
	@echo "More variants (schema/data-only, formats): see comments in this Makefile."

# ── Build & Test ─────────────────────────────────────────────

# Build the Docker image
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

# Verify the image: check PG, extensions, and SQL files
verify: build
	@echo "=== Verifying image contents ==="
	@docker run --rm --entrypoint bash $(IMAGE_NAME):$(IMAGE_TAG) -c '\
		echo "--- PostgreSQL version ---" && \
		pg_config --version && \
		echo "" && \
		echo "--- Installed extensions ---" && \
		ls /usr/share/postgresql/*/extension/ | grep -E "prefix|spock" && \
		echo "" && \
		echo "--- SQL init files ---" && \
		ls -la /home/pgedge/scripts/sql/ && \
		echo "" && \
		echo "--- init-node.sh ---" && \
		test -x /home/pgedge/scripts/init-node.sh && echo "init-node.sh: OK (executable)" && \
		echo "" && \
		echo "=== All checks passed ==="'

# Run a single-node smoke test
test: build
	@echo "=== Running smoke test ==="
	@docker rm -f pgedge-test 2>/dev/null || true
	@docker run -d --name pgedge-test \
		-e NODE_NAME=test \
		-e PEER_NAME=none \
		-e PEER_HOST=localhost \
		-e DB_USER=postgres \
		-e POSTGRES_PASSWORD=smoketest123 \
		$(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Waiting for init to complete..."
	@for i in $$(seq 1 90); do \
		if docker exec pgedge-test test -f /tmp/init-complete 2>/dev/null; then \
			echo "Ready after $${i}s"; \
			break; \
		fi; \
		if [ "$$i" -eq 90 ]; then \
			echo "FAIL: not ready after 90s"; \
			docker logs pgedge-test; \
			docker rm -f pgedge-test; \
			exit 1; \
		fi; \
		sleep 1; \
	done
	@echo ""
	@echo "--- Checking databases ---"
	@docker exec pgedge-test psql -U postgres -d postgres -t -A -c \
		"SELECT datname FROM pg_database WHERE datname = 'voipappz';"
	@echo ""
	@docker rm -f pgedge-test
	@echo "=== Smoke test passed ==="

# Customer-verifiable evidence for the requested CIS PostgreSQL 17 controls.
# The report is read-only and contains no password hashes or private keys.
cis-report:
	@NODE=$(NODE) DB=$(or $(DB),voipappz) DB_USER=$(DB_USER) \
		CUSTOMER_NAME="$(or $(CUSTOMER_NAME),Customer)" \
		AUDIT_ENVIRONMENT="$(or $(AUDIT_ENVIRONMENT),Not specified)" \
		AUDITOR_NAME="$(or $(AUDITOR_NAME),Automated customer audit)" \
		REPORT_VERSION="$(or $(REPORT_VERSION),1.0)" \
		REPORT_DIR=$(or $(REPORT_DIR),./reports/cis-postgresql-17) \
		./scripts/cis-report.sh

# Mandatory CI form: still writes the complete report, then exits non-zero if
# any automated control failed or the evidence came from a dirty worktree.
# REVIEW controls require human sign-off.
cis-check:
	@NODE=$(NODE) DB=$(or $(DB),voipappz) DB_USER=$(DB_USER) CIS_ENFORCE=1 \
		CUSTOMER_NAME="$(or $(CUSTOMER_NAME),Customer)" \
		AUDIT_ENVIRONMENT="$(or $(AUDIT_ENVIRONMENT),Not specified)" \
		AUDITOR_NAME="$(or $(AUDITOR_NAME),Automated customer audit)" \
		REPORT_VERSION="$(or $(REPORT_VERSION),1.0)" \
		REPORT_DIR=$(or $(REPORT_DIR),./reports/cis-postgresql-17) \
		./scripts/cis-report.sh

# Customer-facing aliases. The cis-* names remain available for concise CI use.
customer-audit: cis-report
customer-audit-check: cis-check

# ── Cluster Lifecycle ────────────────────────────────────────

# Initial setup: create .env with a generated password, then start the cluster
setup:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env from .env.example — edit as needed"; \
	else \
		echo ".env already exists"; \
	fi
	@if grep -qE '^POSTGRES_PASSWORD=.+' .env; then \
		echo "POSTGRES_PASSWORD already set in .env"; \
	else \
		sed -i '/^POSTGRES_PASSWORD=/d' .env; \
		printf 'POSTGRES_PASSWORD=%s\n' "$$(openssl rand -base64 24 | tr -d '/+=')" >> .env; \
		echo "Generated POSTGRES_PASSWORD in .env"; \
	fi
	@mkdir -p backups
	@if grep -qE '^BACKUP_DIR=.+' .env; then \
		echo "BACKUP_DIR already set in .env"; \
	else \
		sed -i '/^BACKUP_DIR=/d' .env; \
		printf 'BACKUP_DIR=%s\n' "$(CURDIR)/backups" >> .env; \
		echo "Set BACKUP_DIR to $(CURDIR)/backups in .env"; \
	fi
	@echo "Run 'make up' to start the cluster"

# Start both nodes (local testing)
up:
	$(COMPOSE) up -d --build

# Stop both nodes
down:
	$(COMPOSE) down

# Tail logs
logs:
	$(COMPOSE) logs -f

# Show container status
ps:
	$(COMPOSE) ps

# Remove containers, volumes, and image
clean:
	$(COMPOSE) down -v
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

# ── Database Operations ──────────────────────────────────────

# Open psql shell on a node (default: pgedge-n1)
#   make psql                       # voipappz on n1
#   make psql NODE=pgedge-n2        # voipappz on n2
psql:
	docker exec -it $(NODE) psql -U $(DB_USER) -d $(or $(DB),voipappz)

# Open bash shell on a node
shell:
	docker exec -it $(NODE) bash

# Show cluster status: services, connections, replication, backups
status:
	@echo "=== Services ==="
	@for svc in pgedge-n1 pgedge-n2 pgedge-pgcat; do \
		STATE=$$(docker inspect -f '{{.State.Status}}' $$svc 2>/dev/null || echo "missing"); \
		HEALTH=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' $$svc 2>/dev/null || echo "-"); \
		RESTARTS=$$(docker inspect -f '{{.RestartCount}}' $$svc 2>/dev/null || echo "-"); \
		printf '  %-16s %-10s %-14s restarts=%s\n' "$$svc" "$$STATE" "$$HEALTH" "$$RESTARTS"; \
	done
	@echo ""
	@echo "=== Cluster ==="
	@for node in pgedge-n1 pgedge-n2; do \
		echo ""; \
		echo "--- $$node ---"; \
		docker exec $$node pg_isready -U $(DB_USER) >/dev/null 2>&1 && echo "  PostgreSQL: UP" || echo "  PostgreSQL: DOWN"; \
		CONN=$$(docker exec $$node psql -U $(DB_USER) -t -A -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null || echo "?"); \
		echo "  Connections: $$CONN"; \
		SUB=$$(docker exec $$node psql -U $(DB_USER) -d voipappz -t -A -c \
			"SELECT subscription_name || '=' || status FROM spock.sub_show_status();" 2>/dev/null || echo "?"); \
		echo "  Subscriptions: $${SUB:-none}"; \
		echo "$$SUB" | grep -qv "=replicating" && [ -n "$$SUB" ] && echo "  WARNING: a subscription is not replicating"; \
		LAG=$$(docker exec $$node psql -U $(DB_USER) -d voipappz -t -A -c \
			"SELECT coalesce(max(replication_lag)::text, 'none') FROM spock.lag_tracker;" 2>/dev/null || echo "?"); \
		echo "  Replication lag: $$LAG"; \
	done
	@echo ""
# ── Dump helpers ──
# DUMP_FMT controls output format:
#   custom  → .dump  (pg_dump -Fc, default — fastest restore, compressed)
#   tar     → .tar.gz (pg_dump -Ft piped through gzip)
#   sql     → .sql.gz (pg_dump plain SQL piped through gzip)
#
# Common options:
#   NODE=pgedge-n2   dump from node 2
#   DUMP_DIR=./bak   change output directory
#   DUMP_FMT=tar     use tar+gzip format

# Internal: resolve extension and pg_dump flags from DUMP_FMT
_dump_ext = $(if $(filter tar,$(DUMP_FMT)),.tar.gz,$(if $(filter sql,$(DUMP_FMT)),.sql.gz,.dump))
_dump_cmd = $(if $(filter tar,$(DUMP_FMT)),pg_dump -U $(DB_USER) -N spock -Ft,$(if $(filter sql,$(DUMP_FMT)),pg_dump -U $(DB_USER) -N spock,pg_dump -U $(DB_USER) -N spock -Fc))
_needs_gzip = $(filter tar sql,$(DUMP_FMT))

# Dump all databases (full: schema + data)
#   make dump
#   make dump DUMP_FMT=tar
#   make dump DUMP_FMT=sql NODE=pgedge-n2
dump:
	@mkdir -p $(DUMP_DIR)
	@for db in $(DATABASES); do \
		echo "Dumping $$db from $(NODE) [fmt=$(DUMP_FMT)]..."; \
		$(if $(_needs_gzip),\
			docker exec $(NODE) $(_dump_cmd) $$db | gzip > $(DUMP_DIR)/$$db$(_dump_ext);,\
			docker exec $(NODE) $(_dump_cmd) $$db > $(DUMP_DIR)/$$db$(_dump_ext);) \
		echo "  → $(DUMP_DIR)/$$db$(_dump_ext) ($$(du -h $(DUMP_DIR)/$$db$(_dump_ext) | cut -f1))"; \
	done
	@echo "All dumps saved to $(DUMP_DIR)/"

# Dump all databases — schema only (no data)
#   make dump-schema
#   make dump-schema DUMP_FMT=sql
dump-schema:
	@mkdir -p $(DUMP_DIR)
	@for db in $(DATABASES); do \
		echo "Dumping $$db schema from $(NODE) [fmt=$(DUMP_FMT)]..."; \
		$(if $(_needs_gzip),\
			docker exec $(NODE) $(_dump_cmd) --schema-only $$db | gzip > $(DUMP_DIR)/$${db}_schema$(_dump_ext);,\
			docker exec $(NODE) $(_dump_cmd) --schema-only $$db > $(DUMP_DIR)/$${db}_schema$(_dump_ext);) \
		echo "  → $(DUMP_DIR)/$${db}_schema$(_dump_ext) ($$(du -h $(DUMP_DIR)/$${db}_schema$(_dump_ext) | cut -f1))"; \
	done
	@echo "All schema dumps saved to $(DUMP_DIR)/"

# Dump all databases — data only (no schema)
#   make dump-data
#   make dump-data DUMP_FMT=tar
dump-data:
	@mkdir -p $(DUMP_DIR)
	@for db in $(DATABASES); do \
		echo "Dumping $$db data from $(NODE) [fmt=$(DUMP_FMT)]..."; \
		$(if $(_needs_gzip),\
			docker exec $(NODE) $(_dump_cmd) --data-only $$db | gzip > $(DUMP_DIR)/$${db}_data$(_dump_ext);,\
			docker exec $(NODE) $(_dump_cmd) --data-only $$db > $(DUMP_DIR)/$${db}_data$(_dump_ext);) \
		echo "  → $(DUMP_DIR)/$${db}_data$(_dump_ext) ($$(du -h $(DUMP_DIR)/$${db}_data$(_dump_ext) | cut -f1))"; \
	done
	@echo "All data dumps saved to $(DUMP_DIR)/"

# Dump a single database (full)
#   make dump-db DB=voipappz
#   make dump-db DB=voipappz DUMP_FMT=tar
dump-db:
	@mkdir -p $(DUMP_DIR)
	@echo "Dumping $(DB) from $(NODE) [fmt=$(DUMP_FMT)]..."
	$(if $(_needs_gzip),\
		@docker exec $(NODE) $(_dump_cmd) $(DB) | gzip > $(DUMP_DIR)/$(DB)$(_dump_ext),\
		@docker exec $(NODE) $(_dump_cmd) $(DB) > $(DUMP_DIR)/$(DB)$(_dump_ext))
	@echo "  → $(DUMP_DIR)/$(DB)$(_dump_ext) ($$(du -h $(DUMP_DIR)/$(DB)$(_dump_ext) | cut -f1))"

# Dump a single database — schema only
#   make dump-db-schema DB=voipappz
dump-db-schema:
	@mkdir -p $(DUMP_DIR)
	@echo "Dumping $(DB) schema from $(NODE) [fmt=$(DUMP_FMT)]..."
	$(if $(_needs_gzip),\
		@docker exec $(NODE) $(_dump_cmd) --schema-only $(DB) | gzip > $(DUMP_DIR)/$(DB)_schema$(_dump_ext),\
		@docker exec $(NODE) $(_dump_cmd) --schema-only $(DB) > $(DUMP_DIR)/$(DB)_schema$(_dump_ext))
	@echo "  → $(DUMP_DIR)/$(DB)_schema$(_dump_ext) ($$(du -h $(DUMP_DIR)/$(DB)_schema$(_dump_ext) | cut -f1))"

# Dump a single database — data only
#   make dump-db-data DB=voipappz
dump-db-data:
	@mkdir -p $(DUMP_DIR)
	@echo "Dumping $(DB) data from $(NODE) [fmt=$(DUMP_FMT)]..."
	$(if $(_needs_gzip),\
		@docker exec $(NODE) $(_dump_cmd) --data-only $(DB) | gzip > $(DUMP_DIR)/$(DB)_data$(_dump_ext),\
		@docker exec $(NODE) $(_dump_cmd) --data-only $(DB) > $(DUMP_DIR)/$(DB)_data$(_dump_ext))
	@echo "  → $(DUMP_DIR)/$(DB)_data$(_dump_ext) ($$(du -h $(DUMP_DIR)/$(DB)_data$(_dump_ext) | cut -f1))"

# Restore all databases from DUMP_DIR
# Detects format by file extension (.dump, .tar.gz, .sql.gz)
#   make restore
#   make restore NODE=pgedge-n2
restore:
	@for db in $(DATABASES); do \
		if [ -f $(DUMP_DIR)/$$db.dump ]; then \
			echo "Restoring $$db to $(NODE) from $$db.dump..."; \
			docker exec -i $(NODE) pg_restore -U $(DB_USER) -d $$db --clean --if-exists < $(DUMP_DIR)/$$db.dump || true; \
			echo "  $$db: done"; \
		elif [ -f $(DUMP_DIR)/$$db.tar.gz ]; then \
			echo "Restoring $$db to $(NODE) from $$db.tar.gz..."; \
			gunzip -c $(DUMP_DIR)/$$db.tar.gz | docker exec -i $(NODE) pg_restore -U $(DB_USER) -d $$db --clean --if-exists || true; \
			echo "  $$db: done"; \
		elif [ -f $(DUMP_DIR)/$$db.sql.gz ]; then \
			echo "Restoring $$db to $(NODE) from $$db.sql.gz..."; \
			gunzip -c $(DUMP_DIR)/$$db.sql.gz | docker exec -i $(NODE) psql -U $(DB_USER) -d $$db || true; \
			echo "  $$db: done"; \
		else \
			echo "  SKIP: no dump found for $$db in $(DUMP_DIR)/"; \
		fi; \
	done

# Restore a single database from a file (auto-detects format)
#   make restore-db DB=voipappz FILE=./backups/voipappz.dump
#   make restore-db DB=voipappz FILE=./backups/voipappz.tar.gz
#   make restore-db DB=voipappz FILE=./backups/voipappz.sql.gz
restore-db:
	@echo "Restoring $(DB) to $(NODE) from $(FILE)..."
	@case "$(FILE)" in \
		*.sql.gz) gunzip -c $(FILE) | docker exec -i $(NODE) psql -U $(DB_USER) -d $(DB) || true ;; \
		*.tar.gz) gunzip -c $(FILE) | docker exec -i $(NODE) pg_restore -U $(DB_USER) -d $(DB) --clean --if-exists || true ;; \
		*)        docker exec -i $(NODE) pg_restore -U $(DB_USER) -d $(DB) --clean --if-exists < $(FILE) || true ;; \
	esac
	@echo "  $(DB): done"

# ── Import / Export / Sync ──
# export/import are aliases for dump/restore (same options apply).
#   make export                       # all databases → DUMP_DIR
#   make export-db DB=voipappz
#   make import                       # DUMP_DIR → all databases
#   make import-db DB=voipappz FILE=./backups/voipappz.dump
export: dump
export-db: dump-db
import: restore
import-db: restore-db

# Sync databases between nodes: pg_dump on SRC piped straight into pg_restore
# on DST, no intermediate file. Spock schema excluded; || true because residual
# spock extension stubs error harmlessly (see CLAUDE.md).
#   make sync                         # n1 → n2, all databases
#   make sync SRC=pgedge-n2 DST=pgedge-n1
#   make sync-db DB=voipappz          # single database
SRC ?= pgedge-n1
DST ?= pgedge-n2
sync:
	@for db in $(DATABASES); do \
		echo "Syncing $$db: $(SRC) → $(DST)..."; \
		docker exec $(SRC) pg_dump -U $(DB_USER) -N spock -Fc $$db \
			| docker exec -i $(DST) pg_restore -U $(DB_USER) -d $$db --clean --if-exists || true; \
		echo "  $$db: done"; \
	done

sync-db:
	@echo "Syncing $(DB): $(SRC) → $(DST)..."
	@docker exec $(SRC) pg_dump -U $(DB_USER) -N spock -Fc $(DB) \
		| docker exec -i $(DST) pg_restore -U $(DB_USER) -d $(DB) --clean --if-exists || true
	@echo "  $(DB): done"

# Import a database from a REMOTE PostgreSQL host into NODE. pg_dump runs
# inside the container against the remote over TCP, piped straight into
# pg_restore — no intermediate file.
#   make import-remote DB=voipappz REMOTE_HOST=203.0.113.7 REMOTE_PASSWORD=secret
#   Optional: REMOTE_PORT=5432 REMOTE_USER=$(DB_USER) REMOTE_DB=$(DB) NODE=postgres
REMOTE_PORT ?= 5432
REMOTE_USER ?= $(DB_USER)

# Dump a database FROM a remote LIVE PostgreSQL host to DUMP_DIR. Safe against
# production: pg_dump takes an MVCC snapshot and never blocks writers.
#   make export-remote DB=voipappz REMOTE_HOST=203.0.113.7 REMOTE_PASSWORD=secret
export-remote:
	@mkdir -p $(DUMP_DIR)
	@echo "Dumping $(or $(REMOTE_DB),$(DB)) from $(REMOTE_HOST):$(REMOTE_PORT)..."
	@docker exec -e PGPASSWORD=$(REMOTE_PASSWORD) $(NODE) \
		pg_dump -h $(REMOTE_HOST) -p $(REMOTE_PORT) -U $(REMOTE_USER) -N spock -Fc $(or $(REMOTE_DB),$(DB)) \
		> $(DUMP_DIR)/$(DB).dump
	@echo "  → $(DUMP_DIR)/$(DB).dump ($$(du -h $(DUMP_DIR)/$(DB).dump | cut -f1))"

import-remote:
	@echo "Importing $(or $(REMOTE_DB),$(DB)) from $(REMOTE_HOST):$(REMOTE_PORT) into $(NODE)/$(DB)..."
	@docker exec -e PGPASSWORD=$(REMOTE_PASSWORD) $(NODE) bash -c \
		"pg_dump -h $(REMOTE_HOST) -p $(REMOTE_PORT) -U $(REMOTE_USER) -N spock -Fc $(or $(REMOTE_DB),$(DB)) \
		 | pg_restore -U $(DB_USER) -d $(DB) --clean --if-exists" || true
	@echo "  $(DB): done"

# Manual local backups. Scheduled backups are owned by mothership.
backup-now:
	@mkdir -p $(BACKUP_DIR)
	docker run --rm --network pgedge-net \
		-e PGPASSWORD=$(POSTGRES_PASSWORD) \
		-v $(BACKUP_DIR):/backups \
		postgres:17-alpine sh -c 'set -e; \
			rm -f /backups/*.dump.part; \
			TS=$$(date +%Y%m%d-%H%M%S); \
			for db in $(DATABASES); do \
				pg_dump -h $(NODE) -U $(DB_USER) -Fc -N spock $$db > /backups/$$db-$$TS.dump.part; \
				mv /backups/$$db-$$TS.dump.part /backups/$$db-$$TS.dump; \
				echo "backed up $$db to $$db-$$TS.dump"; \
			done; \
			find /backups -name "*.dump" -mtime +$(BACKUP_KEEP_DAYS) -delete'

backup-ls:
	@ls -lh $(BACKUP_DIR)/*.dump 2>/dev/null || echo "No dumps in $(BACKUP_DIR)"

# ── In-container backup (backup.sh / restore.sh, baked into the image) ──
# The same scripts mothership's Ofelia job runs: pg_dump into the node's
# /backups, then to S3/MinIO when S3_BUCKET is set, pruned on BACKUP_KEEP_DAYS.
# Root, because /backups is usually a bind dir Docker created root-owned.
#
#   make backup                              # dump DATABASES now (+ S3 if set)
#   make backup-list [DB=voipappz]           # local and S3 dumps
#   make backup-restore FORCE=1 DB=voipappz [NAME=voipappz-<stamp>.dump]
_backup_exec = docker exec -u root \
	-e BACKUP_DATABASES="$(DATABASES)" -e BACKUP_KEEP_DAYS=$(BACKUP_KEEP_DAYS) \
	-e S3_BUCKET=$(S3_BUCKET) -e S3_ENDPOINT=$(S3_ENDPOINT) -e S3_PREFIX=$(S3_PREFIX) -e S3_REGION=$(S3_REGION) \
	-e S3_ACCESS_KEY_ID=$(S3_ACCESS_KEY_ID) -e S3_SECRET_ACCESS_KEY=$(S3_SECRET_ACCESS_KEY) \
	$(NODE) /home/pgedge/scripts

backup:
	@$(_backup_exec)/backup.sh

backup-list:
	@$(_backup_exec)/restore.sh --list $(DB)

backup-restore:
	@[ "$(FORCE)" = "1" ] || { echo "this overwrites $(DB) in $(NODE). FORCE=1 to do it." >&2; exit 2; }
	@$(_backup_exec)/restore.sh $(DB) $(NAME)

# ── S3 Backup (one-shot via nirlevi/postgres-backup-s3:17) ───
# Requires S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY in .env
# Optional: S3_REGION, S3_PREFIX, S3_ENDPOINT, BACKUP_PASSPHRASE, BACKUP_KEEP_DAYS
#
# Schedule externally, e.g.: 0 2 * * * cd /path/to/project && make dump-s3
#
#   make dump-s3                       # backup all databases to S3
#   make dump-db-s3 DB=voipappz       # backup a single database
#   make restore-s3                    # restore latest from S3 (all databases)
#   make restore-db-s3 DB=voipappz    # restore latest from S3 (single database)

# Internal: common docker-run flags for the S3 backup container
_s3run = docker run --rm --network pgedge-net \
	-e S3_REGION=$(S3_REGION) \
	-e S3_BUCKET=$(S3_BUCKET) \
	-e S3_ACCESS_KEY_ID=$(S3_ACCESS_KEY_ID) \
	-e S3_SECRET_ACCESS_KEY=$(S3_SECRET_ACCESS_KEY) \
	-e S3_ENDPOINT=$(S3_ENDPOINT) \
	-e BACKUP_KEEP_DAYS=$(BACKUP_KEEP_DAYS) \
	-e PASSPHRASE=$(BACKUP_PASSPHRASE) \
	-e PGDUMP_EXTRA_OPTS="-N spock" \
	-e POSTGRES_HOST=pgedge-n1 \
	-e POSTGRES_PORT=5432 \
	-e POSTGRES_USER=$(DB_USER) \
	-e POSTGRES_PASSWORD=$(POSTGRES_PASSWORD)

# Backup all databases to S3
dump-s3:
	@for db in $(DATABASES); do \
		echo "Backing up $$db to s3://$(S3_BUCKET)/$(S3_PREFIX)/$$db ..."; \
		$(_s3run) \
			-e POSTGRES_DATABASE=$$db \
			-e S3_PREFIX=$(S3_PREFIX)/$$db \
			$(S3_BACKUP_IMAGE) /backup.sh; \
		echo "  $$db: done"; \
	done

# Backup a single database to S3
#   make dump-db-s3 DB=voipappz
dump-db-s3:
	@echo "Backing up $(DB) to s3://$(S3_BUCKET)/$(S3_PREFIX)/$(DB) ..."
	@$(_s3run) \
		-e POSTGRES_DATABASE=$(DB) \
		-e S3_PREFIX=$(S3_PREFIX)/$(DB) \
		$(S3_BACKUP_IMAGE) /backup.sh

# Restore all databases from S3 (latest backup)
restore-s3:
	@for db in $(DATABASES); do \
		echo "Restoring $$db from s3://$(S3_BUCKET)/$(S3_PREFIX)/$$db ..."; \
		$(_s3run) \
			-e POSTGRES_DATABASE=$$db \
			-e S3_PREFIX=$(S3_PREFIX)/$$db \
			$(S3_BACKUP_IMAGE) /restore.sh; \
		echo "  $$db: done"; \
	done

# Restore a single database from S3 (latest backup)
#   make restore-db-s3 DB=voipappz
restore-db-s3:
	@echo "Restoring $(DB) from s3://$(S3_BUCKET)/$(S3_PREFIX)/$(DB) ..."
	@$(_s3run) \
		-e POSTGRES_DATABASE=$(DB) \
		-e S3_PREFIX=$(S3_PREFIX)/$(DB) \
		$(S3_BACKUP_IMAGE) /restore.sh
