# aws-gcp/rds-to-cloudsql-postgres

Migrates a **production-shaped PostgreSQL database from Amazon RDS to Cloud SQL for PostgreSQL** —
carrying schemas, roles, ownership, grants, sequences, extensions, partitions, views, materialized
views, functions, triggers, and data — then **verifies parity** by diffing a structure+content
snapshot of source vs target. It migrates **password-auth → password-auth** (converting the app to
Cloud SQL IAM database auth is a separate follow-up lab).

This lab doubles as a **reference/runbook for a real production migration**: the migration is a set
of small, re-runnable scripts driven by `SOURCE_URL` / `TARGET_URL`, and the role/ownership/password
steps are **generated from the source catalog** (no hardcoded object lists), so the same scripts run
against a live database.

## Architecture

```
 AWS (source)                            GCP (target)
 ┌────────────────────────────┐          ┌──────────────────────────────────────────┐
 │ aws/network (aws/vpc)       │          │ gcp/network (gcp/vpc + PSA + IAP fw + NAT) │
 │ aws/rds (aws/rds-postgres)  │  RDS     │ gcp/migration-host (compute-engine)        │
 │   PostgreSQL 16, public,    │  public  │   ├─ no public IP; egress via Cloud NAT    │
 │   SSL-forced, seeded        │◀── TLS ──┤   ├─ pg_dump/pg_restore/psql               │
 │   SG allows the NAT IP      │  via NAT │   └─ reaches Cloud SQL over PRIVATE IP ──┐ │
 └────────────────────────────┘   static │ gcp/cloudsql (cloud-sql-postgres)        │ │
                                     IP   │   PostgreSQL 16, PRIVATE IP only  ◀──────┘ │
                                          └──────────────────────────────────────────┘
   operator ── gcloud compute ssh --tunnel-through-iap ──▶ migration host runs the migration
```

The migration runs **on a Compute Engine host inside the GCP VPC** (a jump host — the
production-faithful shape), not from your laptop. The host has **no public IP** (org policies
commonly forbid them): it reaches the target Cloud SQL over its **private IP**, and reaches the
source RDS over RDS's public endpoint via the VPC's **Cloud NAT**, whose reserved **static IP** the
RDS security group allowlists. You drive it over **IAP SSH** (no public SSH exposure);
`seed`/`migrate`/`verify` sync `db/` to the host and run there.

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo:

| Unit                       | Cloud | Module                   | Release tag (see note)          |
| -------------------------- | ----- | ------------------------ | ------------------------------- |
| `infra/aws/network`        | AWS   | `aws/vpc`                | `aws-vpc-vX.Y.Z`                |
| `infra/aws/rds`            | AWS   | `aws/rds-postgres`       | `aws-rds-postgres-v0.1.0`       |
| `infra/gcp/network`        | GCP   | `gcp/vpc`                | `gcp-vpc-v0.2.0`                |
| `infra/gcp/migration-host` | GCP   | `gcp/compute-engine`     | `gcp-compute-engine-v0.2.0`     |
| `infra/gcp/cloudsql`       | GCP   | `gcp/cloud-sql-postgres` | `gcp-cloud-sql-postgres-v0.2.0` |

Dependencies: `aws/rds` → `aws/network` **and** `gcp/network` (for the static NAT egress IP to
allowlist); `gcp/migration-host` → `gcp/network`; `gcp/cloudsql` → `gcp/network`.

> **Module source note.** The new `aws/rds-postgres` module and the additive `gcp/cloud-sql-postgres`
> (`admin_password`, …), `gcp/compute-engine` (subnetwork/tags/startup-script/public-IP/service-account),
> and `gcp/vpc` (`iap_ssh_enabled`) changes were built for this lab.
> Until those tags are released in the catalog, every unit's `source` points at a **local relative
> path** to `infrastructure-catalog/` (allowed by the tech steering while iterating). Each unit has a
> `TODO(release)` comment with the pinned `git::…?ref=` line to switch to before the lab is "done".

## Prerequisites

- A GCP project and a GCS bucket for Terraform state (create it with `task init-state`).
- AWS credentials in your environment (profile / SSO / env vars) able to create VPC + RDS.
- `terraform`, `terragrunt` (pinned via tenv), `aws`, `gcloud`, and Task installed. **The PostgreSQL
  client tools run on the migration host, not locally** — you don't need `psql`/`pg_dump` on your
  machine. Your gcloud identity needs IAP SSH access (a project Owner has it; otherwise
  `roles/iap.tunnelResourceAccessor` + `roles/compute.instanceAdmin.v1` or OS Login).

Copy the env template and fill it in (`.env` is gitignored; shell exports take precedence):

```bash
task init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env
```

Set at least: `GCP_PROJECT`, `GCP_REGION`, `AWS_REGION`, `TF_STATE_BUCKET`, `RDS_MASTER_PASSWORD`,
`CLOUDSQL_ADMIN_PASSWORD`, `APP_DB_PASSWORD`. No operator IP is needed (the migration runs on the
host over IAP). Keep passwords free of spaces/quotes (they go into a libpq connection string).

## Stand it up

```bash
task init-state   # one-time: create the GCS bucket for Terraform state
task validate     # cost-free
task plan         # cost-free
task up           # RDS + VPC (AWS); Cloud SQL (private) + VPC/PSA + migration host (GCP)
```

## Migrate

`seed`, `migrate`, and `verify` sync `db/` to the migration host and run there over IAP (the first
run waits for the host's startup script to finish installing the PostgreSQL 16 client):

```bash
task seed         # populate RDS: schemas, roles, grants, sequences, partitions, views, ~5.5k rows
task migrate      # dump RDS -> create roles -> restore -> reassign owners -> set passwords (Cloud SQL)
task verify       # strict parity diff (structure + content); non-zero exit on any mismatch

task all          # seed -> migrate -> verify in one go
task ssh          # open an interactive shell on the migration host (IAP)
```

What `migrate` does (each step is an independently re-runnable script under `db/migrate/`, run on
the host, so a real cutover can run them one at a time — see `docs/runbook-cutover.md`):

1. `10_dump.sh` — generate application roles from the source catalog + `pg_dump -Fc` the database.
2. `20_load_roles.sh` — create those roles on the target, then grant them to the restore admin.
3. `30_restore.sh` — restore `pre-data` / `data` (`--disable-triggers`, parallel) / `post-data`,
   `--no-owner` but **with** ACLs.
4. `40_reassign_owners.sh` — reassign ownership on the target from the source catalog.
5. `50_finalize.sh` — set passwords + `LOGIN` on the app roles, refresh materialized views.

## Tear it down

```bash
task down   # destroy all infra (AWS + GCP)
```

## Available tasks

`task <name>` — `init-env`, `init-state`, `fmt`, `validate`, `lint`, `plan`, `up`, `seed`,
`migrate`, `verify`, `all`, `ssh`, `down`.

## Security caveats

- The **target Cloud SQL has no public endpoint** — reached only over its private IP from the
  migration host. The **migration host has no public IP** either (egress via Cloud NAT, SSH via IAP).
  The **source RDS** has a public endpoint (there's no VPN between the clouds in this lab), but its
  security group is scoped to the VPC's reserved **static Cloud NAT IP** `/32` with TLS enforced. See
  `docs/adr/0002-connectivity.md` for the production private-path upgrade.
- SSH to the host is **IAP-only** (no public SSH). `.env` holds database passwords and is gitignored;
  the connection env written to the host is `chmod 600` under `/tmp` on an ephemeral instance.

## Learned / decisions

- `docs/adr/0001-migration-method.md` — why section-based dump/restore with generic, catalog-driven
  globals handling (and how DMS / pglogical fit as low-downtime alternatives).
- `docs/adr/0002-connectivity.md` — the public-endpoint-with-allowlist tradeoff and the production
  private-path upgrade.
- `docs/runbook-cutover.md` — turning `task migrate` into a real production cutover, with rollback.
