# gcp/gke-autopilot-helm

Provisions a regional **GKE Autopilot** cluster from the shared modules repo and deploys a Go
"hello world" HTTP server onto it from **GitHub Actions using Helm**, authenticating to GCP
**keylessly** via Workload Identity Federation.

## Architecture

```
GitHub Actions (OIDC token)
        │  keyless, direct Workload Identity Federation (acts as the federated principal itself)
        │  principalSet granted: artifactregistry.writer, container.developer
        ▼
  WIF pool/provider
        │
        │ build & push                         helm upgrade --install
        ▼                                      ▼
  Artifact Registry  ───image───▶  GKE Autopilot cluster  ◀── nodes egress via Cloud NAT
        ▲                                      │
        └──────────── VPC (subnet + Pods/Services secondary ranges) ──────────┘
```

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag:

| Unit           | Module                             | Pinned tag                                |
| -------------- | ---------------------------------- | ----------------------------------------- |
| `network`      | `gcp/vpc`                          | `gcp-vpc-v0.1.0`                          |
| `cluster`      | `gcp/gke`                          | `gcp-gke-v0.1.0`                          |
| `registry`     | `gcp/artifact-registry`            | `gcp-artifact-registry-v0.2.0`            |
| `deployer-wif` | `gcp/workload-identity-federation` | `gcp-workload-identity-federation-v0.1.0` |

`cluster` depends on `network`. `deployer-wif` uses **direct** Workload Identity Federation — CI
acts as the federated identity itself and is granted its project roles directly, with no service
account to impersonate and no JSON key.

Two distinct identities touch the registry: the **CI deployer** principalSet gets
`artifactregistry.writer` (push, in `deployer-wif`), while the **GKE node** service account gets
`artifactregistry.reader` (pull, in `registry`). Image pulls authenticate as the node SA, not the
deployer or the pod — granting only the deployer leaves pods stuck in `ImagePullBackOff`.

## Prerequisites

- A GCP project and a GCS bucket for Terraform state.
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `helm`, `go`, and Task installed.
- The four module tags above published in `gichie534/infrastructure-catalog`.

Set these before running (the lab reads them via env, with placeholders otherwise):

```bash
export GCP_PROJECT=my-project
export GCP_REGION=us-central1
export GCP_PROJECT_NUMBER=123456789012     # for the GKE node SA that pulls images
export GITHUB_REPOSITORY=owner/repo        # repo allowed to federate into the WIF pool
export TF_STATE_BUCKET=my-tf-state-bucket
```

> `GCP_PROJECT_NUMBER` is the project *number*, not the ID. Get it with:
> `gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'`

## Stand it up

```bash
task gke-helm:validate      # cost-free
task gke-helm:plan          # cost-free
task gke-helm:up            # creates the VPC, Autopilot cluster, registry, and CI identity
```

Then wire GitHub Actions (one-time) — print the provider name and set it as a repository
**Variable**:

```bash
task gke-helm:ci-config
# WIF_PROVIDER=projects/<num>/locations/global/workloadIdentityPools/github-ci/providers/github
```

Also set repo variables `GCP_PROJECT`, `GCP_REGION`, `GKE_CLUSTER=gke-autopilot-helm`, and
`ARTIFACT_REPO=gke-autopilot-helm`. The workflow in `.github/workflows/deploy.yml` then builds,
pushes, and `helm upgrade --install`s on push to `main` (or via manual dispatch). CI authenticates
with **direct WIF**.

> The workflow file lives inside the lab. To have GitHub run it, move or symlink it to the
> repository's top-level `.github/workflows/`.

## Local deploy (optional)

```bash
task gke-helm:build
gcloud container clusters get-credentials gke-autopilot-helm --region "$GCP_REGION"
REGISTRY="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/gke-autopilot-helm" TAG=dev task gke-helm:deploy
kubectl -n hello get svc hello   # grab the LoadBalancer external IP, then curl it
```

## Tear it down

```bash
task gke-helm:down
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can reach
  it. This is a deliberate lab-only tradeoff; a v2 will switch to GKE Connect Gateway. See
  `docs/adr/0001-topology-and-cicd.md`.

## Learned / decisions

See `docs/adr/0001-topology-and-cicd.md` for why Autopilot, why the WIF module is IdP-neutral, why
CI uses direct WIF rather than impersonation, and why the deploy is push-based Helm rather than
GitOps.
