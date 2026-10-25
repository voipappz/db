# Customer CIS PostgreSQL 17 audit

This procedure lets a customer independently audit the running VoIPAppz
PostgreSQL nodes against the 44 controls they requested from the CIS PostgreSQL
17 Benchmark v1.0.0. It generates technical evidence; it does not claim CIS
certification.

## What the audit does

The audit uses read-only PostgreSQL catalog queries and read-only container file
inspection. It does not run `ALTER`, `CREATE`, `DROP`, `GRANT`, `REVOKE`, or
write to PostgreSQL. It does not collect password values, password hashes,
private keys, or sensitive connection strings.

Each control receives one status:

- `PASS` — the automated expectation was satisfied.
- `FAIL` — a mandatory automated expectation was not satisfied.
- `REVIEW` — CIS or deployment context requires a named human decision.
- `N/A` — the feature is not active, such as syslog when logs use CSV/stderr.

An approval is valid only for the Git commit, clean-worktree state, audit-script
hash, container image ID, PostgreSQL version, node, database, and generation
time recorded in the report. A report showing a dirty worktree is draft
evidence and must not be approved as a release artifact.

## Customer procedure

Prerequisites: Docker, Bash, `sha256sum`, and a running cluster created from the
release being evaluated.

Run the audit independently against both nodes:

```bash
make customer-audit \
  NODE=pgedge-n1 \
  CUSTOMER_NAME="Example Customer" \
  AUDIT_ENVIRONMENT="Production" \
  AUDITOR_NAME="Example Security Team" \
  REPORT_DIR=./reports/customer/n1

make customer-audit \
  NODE=pgedge-n2 \
  CUSTOMER_NAME="Example Customer" \
  AUDIT_ENVIRONMENT="Production" \
  AUDITOR_NAME="Example Security Team" \
  REPORT_DIR=./reports/customer/n2
```

If the deployment uses different container names, replace `NODE`. To audit a
different database or role, also set `DB` or `DB_USER`.

Verify that no evidence file changed after collection:

```bash
(cd reports/customer/n1 && sha256sum -c SHA256SUMS)
(cd reports/customer/n2 && sha256sum -c SHA256SUMS)
```

The strict form is suitable for an automated release gate. It still writes the
complete evidence, then exits non-zero when any control is `FAIL` or the
worktree is dirty:

```bash
make customer-audit-check \
  NODE=pgedge-n1 \
  REPORT_DIR=./reports/customer/n1
```

## Evidence delivered

Give the customer each complete report directory, including:

- `report.html` — styled customer document with summary, control table, and
  sign-off fields; it is print-ready for PDF export from a browser.
- `report.md` — readable control table with Evidence and Comment columns.
- `report.csv` — the same 44 controls for Excel or Google Sheets.
- `settings.csv` — effective security-relevant settings.
- `extensions.csv` — installed extension versions.
- `roles.csv` — role capabilities and memberships without credentials.
- `privileges.csv` — non-system table and routine grants.
- `rls.csv` — table-by-table RLS and policy inventory.
- `runtime-parameters.csv` — redacted settings grouped by runtime context.
- `hba-rules.csv` — PostgreSQL authentication and transport rules.
- `replication.csv` — active WAL sender identities and state.
- `log-files.txt` — actual log filenames, sizes, owners, and permissions.
- `tls.txt` — public certificate subject, issuer, validity, and fingerprint.
- `SHA256SUMS` — integrity hashes for the complete evidence set.

## Manual evidence and sign-off

Run the audit after application migrations and while both replication nodes are
active. RLS and DML privileges cannot be approved correctly against an empty
schema. Replication-role usage cannot be proven on an isolated node.

Control 7.3 requires evidence of a successful physical base backup and restore,
not merely a `pg_dump`. Supply that operator artifact when generating the
report:

```bash
CIS_BASE_BACKUP_EVIDENCE=/path/to/restore-test.txt \
  make customer-audit NODE=pgedge-n1 REPORT_DIR=./reports/customer/n1
```

For every `REVIEW` or `N/A` row, record the reviewer, decision, rationale,
ticket/reference, and review date. The release can be approved only when:

1. Both nodes have zero `FAIL` rows.
2. Every `REVIEW` and `N/A` row has documented customer/security acceptance.
3. Both `SHA256SUMS` manifests verify successfully.
4. The reviewed image IDs match the images deployed to production.
