# aws-gcp/victoriametrics-eks-to-gke

Imitates **migrating an observability stack from one cloud to another**. VictoriaMetrics and
VictoriaLogs run on **EKS** (the source) and are filled with metrics and logs; an identical stack runs on
**GKE Autopilot** (the target), already collecting its own data. A Job in the target then pulls the
source's history across a **private, BGP-routed IPsec VPN** — no public data path at any point — and the
result is checked by an **exact, sample-for-sample diff** whose verdict you read off a Grafana dashboard.

The thing the lab is built to show: after the migration, the target holds data **timestamped before the
target cluster existed**.

## Architecture

```
AWS  10.20.0.0/16                                 GCP  nodes 10.30.0.0/20, pods 10.31.0.0/16
┌────────────────────────────────┐                ┌──────────────────────────────────────────┐
│ EKS  vmmig-source              │                │ GKE Autopilot  vmmig-target              │
│                                │                │                                          │
│  VMSingle  ─ vmsingle-endpoint │◀───┐      ┌───▶│  VMSingle   (dedup 1ms → idempotent)     │
│  VictoriaLogs ─ vl-private-lb  │◀─┐ │      │    │  VictoriaLogs                            │
│  vmagent  cluster=vmmig-source │  │ │      │    │  vmagent  cluster=vmmig-target           │
│  log collector                 │  │ │      │    │  log collector                           │
│  avalanche + flog (live data)  │  │ │      │    │  Grafana + 4 datasources + dashboard     │
│  seed Job (backdated dataset)  │  │ │      │    │                                          │
│                                │  │ │      │    │  migrate-metrics Job   (vmctl vm-native) │
│  INTERNAL load balancers only  │  │ │      │    │  migrate-logs Job      (logsql→jsonline) │
│  (no public listener)          │  │ │      │    │  verify Job            (exact diff)      │
└────────────────────────────────┘  │ │      │    └──────────────────────────────────────────┘
                                    │ └──────┼───── HA VPN ⇄ Site-to-Site VPN, BGP ──────────
                                    └────────┘      2 tunnels, private addressing only
```

Terragrunt units, each pinned to the modules repo by tag:

| Unit              | Module                 | Pinned tag                    |
| ----------------- | ---------------------- | ----------------------------- |
| `aws/network`     | `aws/vpc`              | `aws-vpc-v0.1.0`              |
| `aws/cluster`     | `aws/eks`              | `aws-eks-v0.2.0`              |
| `gcp/network`     | `gcp/vpc`              | `gcp-vpc-v0.2.0`              |
| `gcp/cluster`     | `gcp/gke`              | `gcp-gke-v0.3.0`              |
| `gcp/vpn-gateway` | `gcp/ha-vpn-gateway`   | `gcp-ha-vpn-gateway-v0.1.0`   |
| `aws/vpn`         | `aws/site-to-site-vpn` | `aws-site-to-site-vpn-v0.1.0` |
| `gcp/vpn-tunnels` | `gcp/ha-vpn-tunnels`   | `gcp-ha-vpn-tunnels-v0.1.0`   |

The three VPN modules were written for this lab and released alongside it; the other four already
existed. Charts pinned to `victoria-metrics-k8s-stack` 0.93.0, `victoria-logs-single` 0.13.9,
`victoria-logs-collector` 0.3.7; `vmctl` to `v1.152.0`.

## How the migration works

**Metrics** — `vmctl vm-native`, which is purpose-built for moving data between VictoriaMetrics
installations. It pulls from the source and writes to the target, chunked a day at a time, excluding
VictoriaMetrics' own `vm_*` series (both clusters produce those natively).

**Logs** — code, because no tool does this yet. `vmctl` has no VictoriaLogs mode, `vlogscli` can only
read, and VictoriaMetrics' own roadmap still lists log migration tooling and backup/restore as unshipped.
It
streams `/select/logsql/query` into `/insert/jsonline`, reconstructing log streams from stream field
names discovered on the source at runtime, gzipping the import, and **bisecting each window on time until
it holds few enough lines to transfer intact** — then checking what arrived against what the source said
it held. Those last two exist because a real migration lost data without them; see
[`docs/adr/0002`](docs/adr/0002-api-migration-not-filesystem-copy.md).

**The code that fills the gaps** lives in `deploy/migrator/` — one Go binary with three subcommands
(`seed`, `migrate-logs`, `verify`). It is mounted into a stock `golang` image from a ConfigMap and run
with `go run`, which is what keeps this lab free of a container registry: two clouds would otherwise mean
two registries, their IAM, and a build-and-push step, for three pieces of logic. The tradeoff is a few
seconds of compilation at the start of each Job.

Because it is compiled, its correctness is checkable without a cluster:

```bash
task build     # gofmt + type check
task test      # 25 unit tests, no cloud resources
```

Those tests are mostly about making verification **fail** when it should — a dropped sample, a
re-stamped timestamp, an altered value, a duplicated log line, an empty source reported as success, a
truncated window, a burst too dense to split. A comparison that cannot catch those would report success on
a broken migration, which is worse than no check at all.

**Why not just copy the data directories?** Because the target is already live, and restoring a snapshot
is a whole-directory *replace* — it would destroy the data the target had been collecting. Full reasoning,
including the hybrid that gets both properties, in
[`docs/adr/0002`](docs/adr/0002-api-migration-not-filesystem-copy.md).

## How verification works, and why you can trust it

The gate is an **exact diff of a deterministic dataset over its entire history** — every series, every
timestamp, every value for metrics; every line for logs. Not counts, not sampling, no tolerance.

That is possible because `task seed` writes a dataset generated from a pure function of (series, sample):
~24k metric samples across 12 series and ~10k log lines, all **backdated** over `SEED_DAYS` (default 7).
Backdating gives a week of history in seconds instead of a week, and — more importantly — the seed is
written once and **never appended to**, so it is immutable. A full-history comparison of immutable data
returns the same answer whenever you run it, which is what makes "verify the whole time range" sound
rather than a race against the clock.

Alongside it, `avalanche` and `flog` plus the real vmagent and log collector keep writing genuinely
unpredictable data to the source, so the migration has to cope with a database still being written to.
That **live** half is reported separately and **never fails the gate**: samples can be written to the
source just before the cutoff yet only become visible after the migration read that window, so demanding
exact equality there would fail for reasons of physics rather than correctness. Live data is
distinguishable at all because each cluster's vmagent stamps its scrapes with
`cluster=vmmig-source` / `cluster=vmmig-target`.

`migrator verify` then **pushes its findings into the target as `migration_verify_*` metrics**, so the dashboard
displays plain PromQL instead of reimplementing the comparison in dashboard queries — and every run is
kept, giving the verdict a history.

## Prerequisites

- An AWS account, a GCP project, and a GCS bucket for Terraform state (`task init-state` creates it).
- `terraform` + `terragrunt` via tenv, plus `aws`, `gcloud`, `kubectl`, `helm` and Task.
- `go` (1.24+) — only for `task build` and `task test`. The cluster compiles the migrator itself, so a
  local toolchain is not needed to *run* the lab, just to check it before you do.
- The module tags in the table above published in `gichie534/infrastructure-catalog`.

> **Cost.** An EKS control plane, a NAT gateway, 2 EC2 nodes, a GKE Autopilot cluster, Cloud NAT, two
> internal load balancers, two AWS VPN connections and two Cloud VPN tunnels — roughly **$0.85/hour**
> while up. VPN connections and tunnels bill from creation whether or not traffic flows. `task down`
> matters more here than in most labs.

## Run it

```bash
task init-env          # writes .env from .env.example — then edit it
task init-state        # one-time: the GCS state bucket

task validate          # cost-free
task build             # cost-free: compile the migrator
task test              # cost-free: the migrator's unit tests
task plan              # cost-free

task up                # both VPCs, both clusters, the three-phase VPN
task vpn-status        # repeat until both tunnels are ESTABLISHED and BGP has learned 10.20.0.0/16
task kubeconfig        # contexts: vmmig-source (EKS) and vmmig-target (GKE)

task deploy            # VM + VL + collectors on both; Grafana + dashboard on the target

task seed              # backdated deterministic dataset -> the SOURCE
task migrate           # Jobs in GKE pull metrics + logs across the VPN
task verify            # exact full-history diff; fails on any mismatch

task grafana           # port-forward Grafana, prints the admin password
```

`task all` chains seed → migrate → verify once `up` and `deploy` are done.

**Do not skip `task vpn-status`.** It checks BGP peer state and learned routes, not just tunnel status —
an ASN mismatch leaves tunnels `ESTABLISHED` while nothing routes, and the resulting migration failure
looks like a broken script.

## What to look at

Open Grafana (`task grafana`, user `admin`) and find **"VictoriaMetrics/VictoriaLogs migration: EKS ->
GKE"**:

- **Migration verified** — green `VERIFIED` only when the seed dataset matches exactly on both sides.
- **Sample diff / log diff** — both must be `0`.
- **SOURCE vs TARGET timeseries** — the same query against the two databases. Look at the **left-hand
  edge**: the target's line extends back roughly a week, well before the GKE cluster was created. Had the
  migration re-stamped the data with "now", the target panel would show one narrow spike instead of a
  week of history.
- **Oldest seed sample held by each side** — the same claim as a timestamp.
- **Migration progress** — `vmctl` pushes its own progress metrics while it runs.
- **Seed logs, both sides** — the log equivalent, read live from both clusters.

`task verify` prints the same findings as text, including the first few differing samples when it fails.

### Poking at either side from a terminal

For ad-hoc exploration, `vlogscli` is VictoriaMetrics' interactive LogsQL client — `psql` for
VictoriaLogs. It only reads, so it cannot affect a migration, and it is often quicker than the dashboard
for answering "what is actually in there":

```bash
# port-forward whichever side you want, then:
docker run --rm -it --network host victoriametrics/vlogscli:v1.52.0 \
  -datasource.url=http://localhost:9428/select/logsql/query

;> dataset:seed | stats count();
;> \tail *                      # live tail
```

Two things it does well here. It pipes results through `less`, and VictoriaLogs *pauses* query execution
while `less` is not reading — so a query matching billions of lines costs nothing until you scroll. And
`\c` / `\logfmt` / `\s` switch output formats, which makes eyeballing migrated versus native lines easy.

For scripted use the VictoriaLogs docs recommend `curl` + `jq` instead, which is effectively what the
migrator does.

## Re-running things

`task migrate` is safe to repeat **for metrics**: both stores run `-dedup.minScrapeInterval=1ms`, so
re-importing an identical sample collapses to one. It is **not** safe for logs — VictoriaLogs
deduplicates nothing and cannot delete by query — so the log migration refuses to run when the target
already holds the dataset, unless `MIGRATE_FORCE=1`. `task seed` guards its log half the same way. The
reasoning is in [`docs/adr/0002`](docs/adr/0002-api-migration-not-filesystem-copy.md).

## Tear down

```bash
task down     # runs clean-k8s first, then destroys all infra
```

`down` removes the in-cluster pieces before touching Terraform, and that order is **required**: the
source's two internal load balancers are created by Kubernetes, so Terraform does not know they exist.
Left behind, their ENIs and security groups keep the VPC alive and `terragrunt destroy` fails partway
through with a dependency violation.

## Running the log migration without the VPN

The lab's own path is a Job inside the target cluster reaching the source over the private VPN. Real
clusters often have no such path, so the same migrator also runs **from a workstation over
`kubectl port-forward`**, which needs no connectivity between the two clouds at all:

```bash
# in one terminal, held open — the source side
kubectl --context <source-ctx> -n <ns> port-forward svc/<vl-service> 19428:9428

# then
MIGRATE_QUERY='{kubernetes.pod_namespace="default"}' ./scripts/prod-migrate-logs.sh inspect
MIGRATE_START=... MIGRATE_END=... ./scripts/prod-migrate-logs.sh migrate
```

`inspect` is **read-only**: it lists the source's field names and values and dry-runs your filter, on both
sides. `migrate` writes, and requires an explicit window plus a typed confirmation. They are separate
subcommands so that nothing can write to a target by accident.

**Run `inspect` first, always.** The likeliest way to get a real migration wrong is the filter: collectors
disagree about field names, so a namespace may be `kubernetes.pod_namespace`, `kubernetes_namespace`,
`namespace`, or something a custom pipeline invented. A filter naming a field that does not exist matches
nothing, and the migration then reports success having moved no data. `migrator fields` turns that silent
failure into a number you can check.

This path has moved ~123M lines between two production clusters. What that exercise taught — silent
truncation through the tunnel, per-window verification, content-sized windows, and gzip — is recorded in
[`docs/adr/0002`](docs/adr/0002-api-migration-not-filesystem-copy.md) and is now in the migrator for both
paths.

## Spinning the connectivity slice out into its own lab

The private EKS ⇄ GKE path was built here because this lab needed it, but it stands on its own.
`scripts/scaffold-vpn-lab.sh` generates `aws-gcp/eks-gke-private-vpn` from it: it **copies** the seven
Terragrunt units verbatim (they are the configuration this lab exercised end to end), rewrites the prose
that talks about observability, and writes a fresh Taskfile, README, ADR and a connectivity test with no
VictoriaMetrics in it at all — an echo server on EKS behind an internal load balancer, called by a Job in
GKE.

```bash
./scripts/scaffold-vpn-lab.sh
```

The generated lab is self-contained and has no dependency on this one. The script fails loudly if a
passage it expects to rewrite has been reworded here, so the two cannot drift into describing each other.

## Learned / decisions

- [`0001` — private cross-cloud connectivity](docs/adr/0001-private-cross-cloud-connectivity.md): why a
  VPN instead of an allowlisted public endpoint, why two AWS connections rather than one, why the peering
  needs three Terragrunt units, and the two details that cost the most time — GKE Pod ranges not being
  advertised by subnet advertisement, and VGW route propagation being a separate step.
- [`0002` — API migration, not filesystem copy](docs/adr/0002-api-migration-not-filesystem-copy.md): why a
  live target rules out snapshot restore, why VictoriaLogs needs bespoke code, the idempotency asymmetry
  between the two halves, and the retention trap that silently discards backdated data.
- [`0003` — explicit GKE node service account](docs/adr/0003-explicit-gke-node-service-account.md): the
  cluster came up `RUNNING` with zero nodes and every pod `Pending`, including `kube-dns`. Not quota, not
  CIDRs, not Autopilot resource ratios — the Compute Engine default service account held no roles, so
  nodes booted, failed to register, and were deleted on a loop. Why the fix belongs in the module, why
  Autopilot needs `cluster_autoscaling` rather than `node_config`, and why the binding must be additive.
  **Also records an unresolved thread** — the grant fixed a real defect but did not revive the cluster,
  and the "Open" section lists what was ruled out so the dead ends are not re-run.

## Notes / caveats

- The **second tunnel of each AWS VPN connection stays `DOWN`**. That is expected: an HA VPN interface
  pairs with one connection, so only tunnel 1 of each is used.
- Both Kubernetes **control planes** are public (`0.0.0.0/0`) so `kubectl` works from anywhere. Only the
  control planes — the observability data path has no public listener. Narrow both for anything
  longer-lived.
- `SEED_DAYS` must stay below the 30d retention configured in the values files. the seeder refuses
  otherwise, because backdated data older than retention is discarded at ingest and the seed would appear
  to succeed while storing nothing.
- Grafana, the datasources and the dashboard arrive via sidecar-discovered ConfigMaps, so allow ~a minute
  after `task deploy` before they appear.
- The two **log panels** use the VictoriaLogs Grafana datasource with a bare LogsQL expression. If your
  plugin version wants a different query shape, adjust them in the UI — every number that verification
  depends on comes from the pushed `migration_verify_*` metrics, not from those panels.
