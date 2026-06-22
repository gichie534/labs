# gcp/gke-ingress-managed-cert

Provisions a regional **GKE Autopilot** cluster from the shared modules repo and serves a Go
"hello world" HTTP server on it behind a **public HTTPS endpoint** — a classic **GKE Ingress**
(external Application Load Balancer) with a **Google-managed TLS certificate** (ManagedCertificate
CRD) and an HTTP→HTTPS redirect. The app's hostname is the apex of a **delegated Cloud DNS zone**
(e.g. `gke-ingress.gcp.example.com`) that the lab creates and delegates from your existing
parent zone. Deploys run from GitHub Actions with Helm, authenticating to GCP **keylessly** via
Workload Identity Federation.

This is the **Option A** variant (classic Ingress + ManagedCertificate). A planned v2 implements the
**Gateway API + Certificate Manager** path. See `docs/adr/0001-https-ingress-and-dns.md`.

## Architecture

```
                          client
                            │ https://gke-ingress.gcp.example.com
                            ▼
   Cloud DNS (child zone, delegated from parent) ── A ──▶ ephemeral global LB IP
                            │                                   │
                            │                          external Application LB
                            │                          (TLS via Google-managed cert,
                            │                           HTTP→HTTPS via FrontendConfig)
                            ▼                                   │ NEG → Pod IPs
                  GKE Autopilot cluster  ◀── ClusterIP Service ─┘
                            ▲
   GitHub Actions ─ build & push ─▶ Artifact Registry ─ nodes pull ─▶ (Deployment)
   (keyless, direct WIF)
```

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag:

| Unit           | Module                             | Pinned tag                                |
| -------------- | ---------------------------------- | ----------------------------------------- |
| `network`      | `gcp/vpc`                          | `gcp-vpc-v0.1.0`                          |
| `cluster`      | `gcp/gke`                          | `gcp-gke-v0.1.0`                          |
| `registry`     | `gcp/artifact-registry`            | `gcp-artifact-registry-v0.2.0`            |
| `deployer-wif` | `gcp/workload-identity-federation` | `gcp-workload-identity-federation-v0.2.1` |
| `dns`          | `gcp/cloud-dns`                    | `gcp-cloud-dns-v0.3.0`                    |

`cluster` depends on `network`. The `dns` unit creates the public **child** zone and writes its `NS`
delegation into your existing parent zone automatically (cloud-dns `delegate_to_parent_zone`, new in
v0.3.0), so the subdomain is delegated reproducibly across teardown/recreate.

## Why two phases (HTTPS specifics)

The load-balancer IP is **ephemeral** (no static IP reserved) and the managed certificate validates
by **load-balancer authorization** — it only goes Active *after* the domain resolves to the LB IP.
So HTTPS comes up in two phases:

1. **`up`** — infra + the delegated public zone (no A record yet; the IP doesn't exist).
2. **`deploy`** — app + Ingress + ManagedCertificate; the LB allocates its ephemeral IP.
3. **`dns`** — read the Ingress IP and publish the apex **A record** (re-applies the `dns` unit with
   `INGRESS_IP`; the record stays in Terraform state).
4. **`verify`** — wait for the cert to go Active + DNS to resolve, then `GET https://<domain>`.

First managed-cert issuance can take 10–20 minutes.

## Prerequisites

- A GCP project and a GCS bucket for Terraform state (create it with `task gke-ingress:init-state`).
- An **existing public parent zone** in Cloud DNS (here `gcp.example.com`) whose delegation
  already works (your registrar / Cloudflare NS records point at it).
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl`, `helm`, `go`, and Task installed.

Set these before running. The lab loads them from a local **`.env`** file automatically (Task's
built-in dotenv), so the simplest path is to copy the template and fill it in:

```bash
cp .env.example .env
$EDITOR .env          # fill in project, region, domain, parent zone, etc.
```

`.env` is gitignored. Anything you also `export` in your shell takes precedence over `.env`, and a
missing `.env` is harmless (cost-free tasks still run). The variables the lab reads:

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012     # for the GKE node SA that pulls images
GITHUB_REPOSITORY=owner/repo        # repo allowed to federate into the WIF pool
TF_STATE_BUCKET=my-tf-state-bucket
INGRESS_DOMAIN=gke-ingress.gcp.example.com
PARENT_DNS_ZONE=gcp-example-com     # Cloud DNS managed-zone NAME of the parent zone
PARENT_DNS_PROJECT=my-bootstrap-project   # project owning the parent zone (omit if same as GCP_PROJECT)
```

> `PARENT_DNS_ZONE` is the parent zone's Cloud DNS **resource name**, not its domain. Find it with:
> `gcloud dns managed-zones list --project "$PARENT_DNS_PROJECT" --format='table(name,dnsName)'`
>
> `PARENT_DNS_PROJECT` is the project that owns the existing parent zone (often a separate bootstrap
> project). Leave it unset if the parent zone lives in `GCP_PROJECT`. The deployer needs
> `roles/dns.admin` (or equivalent) on that project to write the NS delegation record.
>
> `GCP_PROJECT_NUMBER` is the project *number*, not the ID:
> `gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'`

## Stand it up (full flow, local)

```bash
task gke-ingress:init-state   # one-time: create the GCS bucket for Terraform state
task gke-ingress:validate     # cost-free
task gke-ingress:plan         # cost-free
task gke-ingress:up           # VPC, Autopilot cluster, registry, CI identity, delegated DNS zone

# build + push an image (mirrors CI), fetch creds, then deploy -> dns -> verify
task gke-ingress:build
gcloud auth configure-docker "$GCP_REGION-docker.pkg.dev" --quiet
docker tag hello:dev "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/gke-ingress-managed-cert/hello:dev"
docker push "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/gke-ingress-managed-cert/hello:dev"
task gke-ingress:creds
REGISTRY="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/gke-ingress-managed-cert" TAG=dev task gke-ingress:all
```

`task gke-ingress:all` runs `deploy → dns → verify`. On success it prints the greeting fetched over
HTTPS from `https://$INGRESS_DOMAIN/`.

## Wire GitHub Actions (one-time)

```bash
task gke-ingress:ci-config
# WIF_PROVIDER=projects/<num>/locations/global/workloadIdentityPools/github-ci/providers/github
```

Set repository **Variables**: `GCP_PROJECT`, `GCP_REGION`, `GKE_CLUSTER=gke-ingress-managed-cert`,
`ARTIFACT_REPO=gke-ingress-managed-cert`, `INGRESS_DOMAIN`, and `WIF_PROVIDER`. The workflow in
`.github/workflows/deploy.yml` builds, pushes, `helm upgrade --install`s, and then **GETs the public
HTTPS endpoint** on push to `main` (or manual dispatch), authenticating with direct WIF.

> The Action is the steady-state **app loop**; it assumes infra and the A record were stood up once
> by the Taskfile. CI keeps minimal roles (`artifactregistry.writer`, `container.developer`) — it
> does not manage DNS or infra. See the ADR for why.
>
> The workflow file lives inside the lab. To have GitHub run it, move or symlink it to the
> repository's top-level `.github/workflows/` (a copy is provided there as
> `deploy-gke-ingress-managed-cert.yml`).

## Tear it down

```bash
task gke-ingress:down   # uninstalls the Helm release (removes the LB/Ingress), then destroys infra
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can reach
  it. Deliberate lab-only tradeoff, inherited from `gke-autopilot-helm`. See the ADR.

## Learned / decisions

See `docs/adr/0001-https-ingress-and-dns.md` for why classic Ingress + ManagedCertificate (not
Gateway + Certificate Manager), why the IP is ephemeral and DNS is two-phase, why the cloud-dns
module gained reproducible subdomain delegation, and why CI stays minimal-privilege.
