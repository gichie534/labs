# gcp/gke-ingress-iap-playwright

Provisions a regional **GKE Autopilot** cluster from the shared modules repo and serves a Go
"hello world" HTTP server on it behind a **public HTTPS endpoint** protected by **Identity-Aware
Proxy (IAP)** — then verifies that gate with **Playwright** end-to-end tests that run from GitHub
Actions and authenticate **through IAP**. The endpoint is a classic **GKE Ingress** (external
Application Load Balancer) with a **Google-managed TLS certificate** (ManagedCertificate CRD) and an
HTTP→HTTPS redirect; a **BackendConfig** (`iap.enabled: true`, Google-managed OAuth client) puts IAP
in front. The hostname is the apex of a **delegated Cloud DNS zone** (e.g.
`gke-iap-pw.gcp.example.com`) the lab creates and delegates from your existing parent zone. Deploys
run from GitHub Actions with Helm, authenticating to GCP **keylessly** via Workload Identity
Federation.

This builds directly on `gcp/gke-ingress-iap`; the only new concern is **testing IAP with a browser
tool (Playwright) from CI**, including the authenticated path. See
`docs/adr/0001-playwright-iap-auth.md`.

## Architecture

```
                          client / Playwright
                            │ https://gke-iap-pw.gcp.example.com
                            │ (positive test adds: Authorization: Bearer <SA-signed JWT>)
                            ▼
   Cloud DNS (child zone, delegated from parent) ── A ──▶ ephemeral global LB IP
                            │                                   │
                            │                          external Application LB
                            │                          (TLS via Google-managed cert,
                            │                           HTTP→HTTPS via FrontendConfig,
                            │                           IAP via BackendConfig) ── gate ──┐
                            ▼                                   │ NEG → Pod IPs           │
                  GKE Autopilot cluster  ◀── ClusterIP Service ─┘            roles/iap.httpsResourceAccessor
                            ▲                                                 (operator + playwright-iap-tester SA)
   GitHub Actions ─ build & push ─▶ Artifact Registry ─ nodes pull ─▶ (Deployment)
   (keyless, direct WIF) ─ impersonate playwright-iap-tester ─ sign JWT ─▶ Playwright
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
**child** zone and writes its `NS` delegation into your existing parent zone automatically.

## What's different from `gcp/gke-ingress-iap`

Only the **testing** changes; the infra topology is the same. The additions:

1. **A Playwright test project** under `tests/e2e/` (TypeScript, `@playwright/test`) with two specs:
   a **negative** test (unauthenticated request must be blocked) and a **positive** test
   (authenticated request reaches the app).
2. **The test SA is renamed** from `iap-tester` to **`playwright-iap-tester`**, and the **CI WIF
   principal is granted Token Creator on it** (`infra/iap-sa`) so CI — not just the operator — can
   mint the IAP JWT. This is the deliberate tradeoff (the reference lab kept CI to the negative test
   only); see the ADR.
3. **The GitHub Actions workflow runs Playwright** (negative + positive) instead of a curl check.

## How Playwright authenticates through IAP

IAP with the Google-managed OAuth client accepts programmatic access only via a **service-account
self-signed JWT** whose audience is the resource URL. You **cannot** get such a token from Workload
Identity Federation alone (a federated principal has no signing keys IAP trusts), and a browser can't
realistically drive Google's interactive sign-in. So:

- The Taskfile (locally) or the workflow (in CI) **impersonates `playwright-iap-tester`** and signs
  a JWT as it with `gcloud iam service-accounts sign-jwt` — no exported key.
- The JWT is passed to Playwright as `IAP_JWT`, which injects it as an `Authorization: Bearer` header
  on every request (`tests/e2e/playwright.config.ts`).
- **Negative** spec sends no header and asserts a 302→`accounts.google.com` or 401/403.
- **Positive** spec navigates with the header and asserts a 200 plus the app's greeting.

## Prerequisites

- A GCP project **inside a Google organization** and a GCS bucket for Terraform state (create it with
  `task gke-iap-pw:init-state`).
- The **IAP API** enabled on the project (`gcloud services enable iap.googleapis.com`).
- An **existing public parent zone** in Cloud DNS whose delegation already works.
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl`, `helm`, `go`, **Node.js 20+ /
  npm** (for Playwright), and Task installed.

Set these before running. The lab loads them from a local **`.env`** file automatically:

```bash
task gke-iap-pw:init-env   # copies .env.example to .env (no-op if .env exists)
$EDITOR .env               # fill in project, region, domain, parent zone, IAP_MEMBER, etc.
```

`.env` is gitignored. The variables the lab reads:

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012     # for the GKE node SA and the CI WIF principalSet
GITHUB_REPOSITORY=owner/repo        # repo allowed to federate into the WIF pool
TF_STATE_BUCKET=my-tf-state-bucket
INGRESS_DOMAIN=gke-iap-pw.gcp.example.com
PARENT_DNS_ZONE=gcp-example-com     # Cloud DNS managed-zone NAME of the parent zone
PARENT_DNS_PROJECT=my-bootstrap-project   # project owning the parent zone (omit if same as GCP_PROJECT)
IAP_MEMBER=user:you@example.com     # Google identity allowed through IAP / impersonates the test SA
```

> `IAP_MEMBER` must be a Google identity in your organization (`user:` or `group:`). It is granted
> browser access through IAP and Token Creator on the test service account.

## Stand it up (full flow, local)

```bash
task gke-iap-pw:init-env     # one-time: create .env from the template, then fill it in
task gke-iap-pw:init-state   # one-time: create the GCS bucket for Terraform state
task gke-iap-pw:validate     # cost-free
task gke-iap-pw:plan         # cost-free
task gke-iap-pw:up           # VPC, Autopilot cluster, registry, CI identity, delegated DNS zone, IAP access, test SA

task gke-iap-pw:push         # build the Go image and push it to Artifact Registry (mirrors CI)
task gke-iap-pw:creds        # fetch kube-context for the cluster
task gke-iap-pw:all          # deploy -> dns -> verify (verify = wait for cert, then Playwright)
```

`task gke-iap-pw:verify` waits for the managed cert to go Active, then runs the Playwright IAP tests
(negative + positive) via `task gke-iap-pw:test-e2e`. First managed-cert issuance can take 10–20
minutes.

## Wire GitHub Actions (one-time)

```bash
task gke-iap-pw:ci-config
# WIF_PROVIDER=projects/<num>/locations/global/workloadIdentityPools/github-ci-gke-iap-pw/providers/github
```

Set repository **Variables**: `GCP_PROJECT`, `GCP_REGION`, `GKE_CLUSTER=gke-ingress-iap-pw`,
`ARTIFACT_REPO=gke-ingress-iap-pw`, `INGRESS_DOMAIN`, and `WIF_PROVIDER`. The workflow in
`.github/workflows/deploy.yml` builds, pushes, `helm upgrade --install`s, then mints the IAP JWT and
runs the **negative + positive** Playwright tests on push to `main` (or manual dispatch). The
workflow file lives inside the lab; to have GitHub run it, move or symlink it to the repository's
top-level `.github/workflows/`.

## Tear it down

```bash
task gke-iap-pw:down   # uninstalls the Helm release (removes the LB/Ingress), then destroys infra
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can reach
  it. Deliberate lab-only tradeoff, inherited from the reference lab.
- CI can mint IAP tokens as `playwright-iap-tester`. Deliberate — it's what lets CI run the
  authenticated browser test. See the ADR.

## Learned / decisions

See `docs/adr/0001-playwright-iap-auth.md` for why Playwright authenticates via a service-account
JWT injected as a Bearer header (and why WIF alone can't), why the CI principal is granted Token
Creator on the test SA, and the negative + positive Playwright test strategy.
