# gcp/gke-ingress-iap

Provisions a regional **GKE Autopilot** cluster from the shared modules repo and serves a Go
"hello world" HTTP server on it behind a **public HTTPS endpoint** protected by **Identity-Aware
Proxy (IAP)**. The endpoint is a classic **GKE Ingress** (external Application Load Balancer) with a
**Google-managed TLS certificate** (ManagedCertificate CRD) and an HTTP→HTTPS redirect; a
**BackendConfig** (`iap.enabled: true`, Google-managed OAuth client) puts IAP in front so only Google
identities in the organization that hold `roles/iap.httpsResourceAccessor` can reach the app. The
hostname is the apex of a **delegated Cloud DNS zone** (e.g. `gke-iap.gcp.example.com`) the lab
creates and delegates from your existing parent zone. Deploys run from GitHub Actions with Helm,
authenticating to GCP **keylessly** via Workload Identity Federation.

This builds directly on `gcp/gke-ingress-managed-cert`; the only new concern is **private access via
IAP** and **how to test it**. See `docs/adr/0001-iap-on-gke-ingress.md`.

## Architecture

```
                          client
                            │ https://gke-iap.gcp.example.com
                            ▼
   Cloud DNS (child zone, delegated from parent) ── A ──▶ ephemeral global LB IP
                            │                                   │
                            │                          external Application LB
                            │                          (TLS via Google-managed cert,
                            │                           HTTP→HTTPS via FrontendConfig,
                            │                           IAP via BackendConfig) ── gate ──┐
                            ▼                                   │ NEG → Pod IPs           │
                  GKE Autopilot cluster  ◀── ClusterIP Service ─┘            roles/iap.httpsResourceAccessor
                            ▲                                                 (operator + test SA)
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
| `iap-sa`       | `gcp/service-account`              | `gcp-service-account-v0.1.0`              |
| `iap-access`   | `gcp/iap-access`                   | `gcp-iap-access-v0.1.0`                   |

`cluster` depends on `network`; `iap-access` depends on `iap-sa`. The `dns` unit creates the public
**child** zone and writes its `NS` delegation into your existing parent zone automatically, so the
subdomain is delegated reproducibly across teardown/recreate.

## How IAP fits in (the lab's point)

IAP has two halves and you need both:

1. **Enable the gate** — the Helm chart ships a `BackendConfig` with `iap.enabled: true`
   (`deploy/helm/hello/templates/backendconfig.yaml`), attached to the Service via the
   `cloud.google.com/backend-config` annotation. It uses the **Google-managed OAuth client** (no
   brand, no client, no secret — the IAP OAuth Admin APIs were shut down in 2026, so self-managed
   OAuth via Terraform is no longer possible).
2. **Say who passes** — the `iap-access` unit grants `roles/iap.httpsResourceAccessor` to the
   operator (`IAP_MEMBER`) and to a dedicated test service account.

## Testing access (two tests)

- **Negative (automated, no credentials):** an unauthenticated `GET` is bounced to Google sign-in
  (302 to `accounts.google.com`) or refused (401/403). A 200 would mean IAP isn't enforcing — a hard
  failure. Run by `task gke-iap:verify` (and the GitHub Action).
- **Positive (service-account JWT):** with the Google-managed client, programmatic access uses a
  **self-signed service-account JWT** whose audience is the resource URL. The lab creates a test SA,
  grants it IAP access, lets you impersonate it (Token Creator), signs a JWT with
  `gcloud iam service-accounts sign-jwt`, and `GET`s with `Authorization: Bearer <jwt>` expecting
  200. Run by `task gke-iap:verify-positive`.
- **Browser (manual):** open `https://$INGRESS_DOMAIN` and sign in as `IAP_MEMBER` to see the app;
  a disallowed identity is blocked.

## Prerequisites

- A GCP project **inside a Google organization** (Google-managed OAuth authenticates org-internal
  identities) and a GCS bucket for Terraform state (create it with `task gke-iap:init-state`).
- The **IAP API** enabled on the project (`gcloud services enable iap.googleapis.com`).
- An **existing public parent zone** in Cloud DNS whose delegation already works.
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl`, `helm`, `go`, and Task installed.

Set these before running. The lab loads them from a local **`.env`** file automatically:

```bash
task gke-iap:init-env   # copies .env.example to .env (no-op if .env exists)
$EDITOR .env            # fill in project, region, domain, parent zone, IAP_MEMBER, etc.
```

`.env` is gitignored. The variables the lab reads:

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012     # for the GKE node SA that pulls images
GITHUB_REPOSITORY=owner/repo        # repo allowed to federate into the WIF pool
TF_STATE_BUCKET=my-tf-state-bucket
INGRESS_DOMAIN=gke-iap.gcp.example.com
PARENT_DNS_ZONE=gcp-example-com     # Cloud DNS managed-zone NAME of the parent zone
PARENT_DNS_PROJECT=my-bootstrap-project   # project owning the parent zone (omit if same as GCP_PROJECT)
IAP_MEMBER=user:you@example.com     # Google identity allowed through IAP / impersonates the test SA
```

> `IAP_MEMBER` must be a Google identity in your organization (`user:` or `group:`). It is granted
> browser access through IAP and Token Creator on the test service account for the positive test.

## Stand it up (full flow, local)

```bash
task gke-iap:init-env     # one-time: create .env from the template, then fill it in
task gke-iap:init-state   # one-time: create the GCS bucket for Terraform state
task gke-iap:validate     # cost-free
task gke-iap:plan         # cost-free
task gke-iap:up           # VPC, Autopilot cluster, registry, CI identity, delegated DNS zone, IAP access

task gke-iap:push         # build the Go image and push it to Artifact Registry (mirrors CI)
task gke-iap:creds        # fetch kube-context for the cluster
task gke-iap:all          # deploy -> dns -> verify
```

`task gke-iap:all` runs `deploy → dns → verify`. `verify` waits for the cert + DNS, then runs the IAP
negative and positive tests. First managed-cert issuance can take 10–20 minutes.

## Wire GitHub Actions (one-time)

```bash
task gke-iap:ci-config
# WIF_PROVIDER=projects/<num>/locations/global/workloadIdentityPools/github-ci-gke-iap/providers/github
```

Set repository **Variables**: `GCP_PROJECT`, `GCP_REGION`, `GKE_CLUSTER=gke-ingress-iap`,
`ARTIFACT_REPO=gke-ingress-iap`, `INGRESS_DOMAIN`, and `WIF_PROVIDER`. The workflow in
`.github/workflows/deploy.yml` builds, pushes, `helm upgrade --install`s, and runs the **negative**
IAP test on push to `main` (or manual dispatch). CI does not run the positive test — it would require
impersonating the test SA, which CI is deliberately not granted. The workflow file lives inside the
lab; to have GitHub run it, move or symlink it to the repository's top-level `.github/workflows/`.

## Tear it down

```bash
task gke-iap:down   # uninstalls the Helm release (removes the LB/Ingress), then destroys infra
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can reach
  it. Deliberate lab-only tradeoff, inherited from the reference lab. See the ADR.

## Learned / decisions

See `docs/adr/0001-iap-on-gke-ingress.md` for why the Google-managed OAuth client (self-managed is
gone), why IAP access control is a separate reusable module, the negative + service-account-JWT test
strategy, and why CI runs only the negative test.
