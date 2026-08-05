# 0001 — Migration method: section-based logical dump/restore + generic post-processing

## Status

Accepted.

## Context

We need to migrate a PostgreSQL database from Amazon RDS to Cloud SQL for PostgreSQL, carrying
**everything**: schemas, roles, ownership, grants, sequences, extensions, partitions, views,
materialized views, functions, triggers, and data. The lab must double as a **reference for a real
production migration** (the author intends to run the same steps against a live database).

Both managed engines forbid a real `SUPERUSER`. On RDS the admin is a member of `rds_superuser`; on
Cloud SQL the admin (`postgres`) is a member of `cloudsqlsuperuser`. Neither can be assumed on the
other side, and roles like `rds_superuser` simply do not exist on Cloud SQL. Any migration must
therefore treat cluster **globals** (roles, ownership, grants) as a first-class, hand-managed
concern — no tool does all of it for you.

### Options considered

1. **Logical dump/restore (`pg_dump`/`pg_restore`) + generic globals handling** — section-based
   restore (`pre-data` / `data` / `post-data`), `--no-owner --no-acl`-style control, roles and
   ownership reconstructed explicitly. Downtime = the dump/restore window.
2. **GCP Database Migration Service (DMS)** — managed CDC; DMS *creates and owns* the destination
   Cloud SQL instance and replicates continuously, promote at cutover. Near-zero downtime.
3. **Native logical replication (pglogical / built-in)** — self-managed CDC.

## Decision

Build **Option 1**. It is the most reproducible, reuses the existing `gcp/cloud-sql-postgres`
module (DMS would bypass it by creating its own instance), and — critically — forces us through the
exact globals work (roles, ownership, grants, sequences, extensions) that DMS and pglogical do
**not** do for you. That makes it the best *reference*.

We keep the author's proven production flow (section-based restore with `--disable-triggers` on the
data section, verification by diffing a query snapshot of source vs target) but make the fragile
parts **generic and catalog-driven** rather than hand-maintained lists:

- **Roles** are generated from the source catalog (`gen_roles.sql`) — never emitting the
  managed-service roles (`rds*`, `cloudsql*`), the bootstrap `postgres`/master role, or the
  attributes a managed target rejects (`SUPERUSER`, `REPLICATION`, `BYPASSRLS`). This replaces
  `pg_dumpall --globals-only` + hand-sanitizing.
- **Ownership** is generated from the source catalog (`gen_owners.sql`) covering schemas, tables,
  standalone sequences, views, materialized views, and functions — replacing hand-written
  `ALTER ... OWNER` lists.
- **Grants** ride along in the dump's ACLs (we do **not** pass `--no-acl`) because every grantee
  role is created on the target *before* the restore.
- **Passwords** are set at cutover from the source's login-role list (`gen_passwords.sql`); secrets
  never travel in a dump.

Ordering: create roles → grant them to the restore admin (so it can set ownership) → restore
(pre/data/post) → reassign ownership → set passwords + refresh matviews → parity check.

### Why password auth (not IAM) here

This lab migrates **password-auth RDS → password-auth Cloud SQL** deliberately: it mirrors the
author's current production (password auth) so the reference is faithful. Converting the application
roles to Cloud SQL **IAM database authentication** is a separate, follow-up lab.

## Consequences

- Downtime equals the dump+restore window. For large or low-downtime migrations, add CDC — see the
  alternatives below; the globals work in this lab is a prerequisite for those too.
- The flow is engine-version tolerant and database-agnostic (no hardcoded object names), so the same
  scripts run against a real production database by pointing `SOURCE_URL`/`TARGET_URL` at it.

## Alternatives for low-downtime cutover (documented, not built)

- **DMS**: create a connection profile to the RDS source, let DMS build the Cloud SQL destination
  and replicate; run this lab's `gen_roles`/`gen_owners`/`gen_passwords` steps around the promote to
  cover what DMS omits.
- **pglogical / built-in logical replication**: enable `rds.logical_replication` (a
  `pending-reboot` parameter the `aws/rds-postgres` module supports), create a publication on the
  source and a subscription on the target after the schema+roles are in place.
