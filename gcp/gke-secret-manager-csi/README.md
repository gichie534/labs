# gcp/gke-secret-manager-csi

Demonstrates the **GKE-managed Secret Manager add-on** (Google's build of the Secrets Store CSI
Driver + GCP provider) and its **SecretSync** feature, mounting two Secret Manager secrets into a
single Deployment through **both** consumption patterns at once:

- **Volume mount** — the CSI driver materializes `csi-volume-secret` as a tmpfs file at
  `/mnt/secrets/vol-secret`.
- **Environment variable** — `SecretSync` materializes `csi-env-secret` as a Kubernetes Secret in
  the workload's namespace, which the Deployment consumes via `valueFrom.secretKeyRef` as
  `$ENV_SECRET`.

A minimal `alpine:3.20` Deployment loops every 30s and prints both values so `kubectl logs` shows
the pattern at work.

## Architecture

```
   GCP Secret Manager                        GKE Autopilot (Secret Manager add-on + SecretSync)
   ─────────────────                         ─────────────────────────────────────────────────────
   csi-volume-secret  ──[CSI volume]──▶  /mnt/secrets/vol-secret  ┐
                                                                  ├──▶  alpine Deployment (KSA secret-reader,
   csi-env-secret     ──[SecretSync]──▶  K8s Secret csi-env-secret┘     direct WIF, prints both values)
                                                  │
                                                  └─▶ valueFrom.secretKeyRef -> $ENV_SECRET
```

Infra is composed as small Terragrunt units under `infra/`:

| Unit                | Module                      | Source                                                                          |
| ------------------- | --------------------------- | ------------------------------------------------------------------------------- |
| `network`           | `gcp/vpc`                   | `?ref=gcp-vpc-v0.1.0`                                                           |
| `cluster`           | `gcp/gke`                   | `?ref=gcp-gke-v0.2.0` (adds `enable_secret_manager_addon`/`enable_secret_sync`) |
| `secrets/volume`    | `gcp/secret-manager`        | `?ref=gcp-secret-manager-v0.1.0` + inline `secret_version` to seed test data    |
| `secrets/env`       | `gcp/secret-manager`        | `?ref=gcp-secret-manager-v0.1.0` + inline `secret_version` to seed test data    |
| `workload-identity` | `gcp/gke-workload-identity` | `?ref=gcp-gke-workload-identity-v0.2.0` (adds `secret_iam` map)                 |

Every unit sources its module from the catalog by a pinned tag.
See `docs/adr/0001-gke-secret-manager-addon.md`.

## Two independent cluster features, both used here

- **Secret Manager add-on** (`secret_manager_config.enabled`) installs the GKE-managed Secrets
  Store CSI Driver + GCP provider. This is what makes the **volume** mount work.
- **SecretSync** (`secret_sync_config.enabled`) installs the `SecretSync` controller, which
  materializes a Secret Manager secret as a Kubernetes Secret consumable via standard
  `valueFrom.secretKeyRef` / `envFrom`. This is what makes the **env** path work — the CSI driver
  has no env-var mode of its own.

The two are independent cluster features; neither requires the other. Documented as alternatives
on Google's side (use either, or both, depending on what your workload needs). This lab uses both
to demonstrate both consumption patterns in the same Deployment.

Workload Identity Federation for GKE is on by default in Autopilot. The CSI driver and the
`SecretSync` controller authenticate to Secret Manager as the workload's KSA; the
`workload-identity` unit grants `roles/secretmanager.secretAccessor` directly to that KSA's
federated principal on each secret (no Google service account, no key, no impersonation).

## Prerequisites

- A GCP project, plus a GCS bucket for Terraform state (create it with `task csi:init-state`).
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl`, and Task installed.
- A GKE control plane on a version that supports `secret_sync_config` (1.33+ at the time of
  writing). The default `release_channel = REGULAR` rolls forward into this range.

Copy the env template and fill it in (`.env` is gitignored; shell exports take precedence):

```bash
task csi:init-env   # cp .env.example .env (won't clobber an existing .env)
$EDITOR .env
```

```dotenv
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012   # gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
TF_STATE_BUCKET=my-tf-state-bucket
```

## Stand it up

```bash
task csi:init-state   # one-time: create the GCS bucket for Terraform state
task csi:validate     # cost-free
task csi:plan         # cost-free
task csi:up           # VPC, Autopilot cluster, two seeded secrets, KSA IAM grants

task csi:creds        # kube-context
task csi:deploy       # namespace, KSA, two SPCs, SecretSync, Deployment

task csi:logs         # tail the printer; expect lines like:
                      #   2026-... volume=hello-from-volume env=hello-from-env
```

## Tear it down

```bash
task csi:down   # delete the workload, then destroy infra
```

## Security caveats

- The cluster's control-plane endpoint is open to `0.0.0.0/0` for convenience. Lab-only.
- Test secret values are hardcoded in the `infra/secret-*` units (`hello-from-volume`,
  `hello-from-env`). Don't reuse this pattern for real secrets — Terraform state would carry the
  value.

## Learned / decisions

See `docs/adr/0001-gke-secret-manager-addon.md`.
