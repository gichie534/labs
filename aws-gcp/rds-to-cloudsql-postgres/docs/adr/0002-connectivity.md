# 0002 — Where the migration runs, and cross-cloud connectivity

## Status

Accepted.

## Context

The migration (`pg_dump` from RDS, `pg_restore`/`psql` into Cloud SQL) must reach **both** databases.
Cloud SQL's production access path is a **private IP** on a VPC with Private Service Access —
unreachable from a laptop without a VPN, a jump host, or Private Service Connect. There is no VPN
between AWS and GCP in this lab, so the RDS source is reached over its public endpoint.

We want the migration to run **from inside GCP** (the author's explicit requirement, and the
production-faithful pattern), which also lets the target Cloud SQL stay **private**.

### Where to run it

1. **Compute Engine jump host** *(chosen)* — a small VM in the target VPC runs the migration. Reaches
   Cloud SQL over private IP; reaches RDS over its own external IP; driven over IAP SSH.
2. **Cloud Run job (serverless)** — a container with the client + scripts, attached to the VPC via
   Direct VPC egress / a connector. Avoids managing a VM, but adds: building and pushing an image,
   a VPC egress/connector, a Cloud NAT with a **static** IP to allowlist in RDS, Secret Manager for
   the passwords, and job IAM. More moving parts for the same job.

### How the host reaches each database

- **Cloud SQL (target):** private IP on the shared VPC (PSA peering) — no public endpoint.
- **The host has no public IP.** Org policies commonly forbid external IPs on VMs
  (`constraints/compute.vmExternalIpAccess`), and it's better practice anyway. Egress goes through
  the VPC's **Cloud NAT**, configured with a **reserved static IP** (`nat_reserve_static_ip`).
- **RDS (source):** public endpoint, TLS forced, its security group scoped to that **static NAT
  IP** `/32`. The `aws/rds` unit reads it via a cross-cloud Terragrunt `dependency` on `gcp/network`
  and allowlists it. (The AWS instance's ingress is wired from a GCP output — an elegant cross-cloud
  dependency.)
- **Operator → host:** **IAP SSH** only. The `gcp/network` unit opens `tcp/22` from Google's IAP
  range (`35.235.240.0/20`) to the host's network tag; the host has no public SSH.

## Decision

Use the **Compute Engine jump host over IAP** (option 1). It is the most widely understood DB-migration
topology, keeps the target Cloud SQL private, needs no image build or Secret Manager, and lets the
migration scripts run unchanged (they just execute on the host instead of the laptop). The
`seed`/`migrate`/`verify` tasks `scp` `db/` to the host, write a `chmod 600` connection env there,
and run the scripts over IAP.

## Consequences

- The **source RDS is publicly reachable** (locked to the static NAT `/32`, TLS enforced) because
  there is no cross-cloud private link in this lab. The **target and the host are fully private**.
- The Cloud NAT egress IP is **reserved (static)**, so the RDS allowlist stays valid across host
  stop/start — no drift, unlike an ephemeral instance IP.
- The host's connection env holds passwords in a `chmod 600` file under `/tmp` on an ephemeral VM,
  destroyed with the lab. A hardened setup would pull secrets from Secret Manager at run time.

### Production upgrade

- Replace the RDS public endpoint with a **private cross-cloud link** — HA VPN (GCP) ↔ Site-to-Site
  VPN (AWS), or reach RDS privately via peering — and drop `publicly_accessible`.
- Harden the client to `sslmode=verify-full` with the RDS CA bundle and the Cloud SQL server cert.
- Source the migration credentials from **Secret Manager** rather than an on-host env file.
- The serverless (Cloud Run job) variant becomes attractive when you want no long-lived VM; the
  trade is the extra image/connector/NAT/secret plumbing noted above.
