# gcp/gke-workload-identity

Demonstrates **Workload Identity Federation for GKE service accounts** — how a pod authenticates to
Google Cloud APIs as its Kubernetes service account (KSA) with **no exported key and no Google
service account**, using the Google-recommended **direct** pattern where the KSA *is* the IAM
principal.

A regional **GKE Autopilot** cluster runs a one-shot Go **Job** that reads one object from each of
two GCS buckets using the Cloud Storage SDK and prints a per-bucket report:

- **allowed** bucket — the KSA is granted `roles/storage.objectViewer`, so the read succeeds and the
  Job prints the object's contents;
- **denied** bucket — the KSA is granted nothing, so the read fails and the Job prints the error in
  human-readable form (permission denied, 403).

`task gke-wi:test` asserts `allowed=OK` and `denied=DENIED`, proving the authorization gate is real.

## Architecture

```
   GitHub Actions ─ build & push ─▶ Artifact Registry ─ nodes pull ─▶ reader Job (Pod)
   (keyless, GitHub→GCP WIF)                                              │
                                                                          │ runs as KSA wifdemo/reader
                                                                          │ (direct WIF: KSA = IAM principal,
                                                                          │  no GSA, no key)
                                                  ┌───────────────────────┤
                            roles/storage.objectViewer            (no grant)
                                                  ▼                       ▼
                                        gs://<proj>-wif-allowed   gs://<proj>-wif-denied
                                          read OK (prints data)    read DENIED (403)
```

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag:

| Unit                | Module                             | Pinned tag                                |
| ------------------- | ---------------------------------- | ----------------------------------------- |
| `network`           | `gcp/vpc`                          | `gcp-vpc-v0.1.0`                          |
| `cluster`           | `gcp/gke`                          | `gcp-gke-v0.1.0`                          |
| `bucket-allowed`    | `gcp/gcs`                          | `gcp-gcs-v0.1.0`                          |
| `bucket-denied`     | `gcp/gcs`                          | `gcp-gcs-v0.1.0`                          |
| `workload-identity` | `gcp/gke-workload-identity`        | `gcp-gke-workload-identity-v0.1.0`        |
| `registry`          | `gcp/artifact-registry`            | `gcp-artifact-registry-v0.2.0`            |
| `deployer-wif`      | `gcp/workload-identity-federation` | `gcp-workload-identity-federation-v0.2.1` |

`cluster` depends on `network`; `workload-identity` depends on `bucket-allowed` (it grants the KSA
read on that bucket). The denied bucket is denied simply by **not being referenced** in any grant.

## Two kinds of "workload identity federation" here

Keep them distinct:

- **The lab's subject** — *in-cluster* GKE **KSA → IAM** federation (`workload-identity` unit). This
  is what the Job exercises.
- **Pipeline auth** — *external* **GitHub → GCP** federation (`deployer-wif` unit) so CI can build,
  push, and deploy keylessly. Supporting cast, not the point.

See `docs/adr/0001-direct-workload-identity.md` for why direct (not GSA impersonation), why a new
standalone catalog module, and why a one-shot Job.

## Prerequisites

- A GCP project and a GCS bucket for Terraform state (create it with `task gke-wi:init-state`).
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl`, `helm`, `go`, `docker`, and Task
  installed.

Copy the env template and fill it in (`.env` is gitignored; shell exports take precedence):

```bash
cp .env.example .env
$EDITOR .env
```

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012   # gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
GITHUB_REPOSITORY=owner/repo      # repo allowed to federate into the GitHub WIF pool (CI)
TF_STATE_BUCKET=my-tf-state-bucket
```

The two data buckets are derived automatically as `<project>-wif-allowed` / `<project>-wif-denied`.

## Stand it up (full flow, local)

```bash
task gke-wi:init-state   # one-time: create the GCS bucket for Terraform state
task gke-wi:validate     # cost-free
task gke-wi:plan         # cost-free
task gke-wi:up           # VPC, Autopilot cluster, registry, both data buckets, the KSA grant, CI WIF

task gke-wi:seed         # write message.txt into each data bucket

# build + push the image (mirrors CI), then fetch creds and deploy + assert
task gke-wi:push
task gke-wi:creds
task gke-wi:all
```

`task gke-wi:all` runs `seed → deploy → test-assert`. On success it prints the Job's report and
confirms `allowed=OK` / `denied=DENIED`. Inspect the raw report any time with:

```bash
kubectl -n wifdemo logs job/reader-reader
```

## Wire GitHub Actions (one-time)

```bash
task gke-wi:ci-config
# WIF_PROVIDER=projects/<num>/locations/global/workloadIdentityPools/github-ci-gke-wi/providers/github
```

Set repository **Variables**: `GCP_PROJECT`, `GCP_REGION`, `GKE_CLUSTER=gke-workload-identity`,
`ARTIFACT_REPO=gke-workload-identity`, and `WIF_PROVIDER`. The workflow in
`.github/workflows/deploy.yml` builds, pushes, `helm upgrade --install`s the Job, and asserts its
report on push to `main` (or manual dispatch). A repo-root copy is provided as
`deploy-gke-workload-identity.yml` for GitHub to pick up.

## Tear it down

```bash
task gke-wi:down   # uninstall the Helm release, then destroy infra (buckets force_destroy seeded data)
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can reach
  it. Deliberate lab-only tradeoff. See the ADR.

## Learned / decisions

See `docs/adr/0001-direct-workload-identity.md`.
