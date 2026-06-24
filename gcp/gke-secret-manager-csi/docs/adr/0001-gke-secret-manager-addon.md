# 0001 — Use the GKE-managed Secret Manager add-on (with SecretSync) instead of the OSS CSI driver

Status: Accepted
Date: 2026-06-24

## Context

The lab demonstrates mounting Secret Manager secrets into a GKE pod two ways: as a CSI-mounted
file and as an environment variable. There are two real ways to do this on GKE:

1. **GKE-managed add-on** — `secret_manager_config { enabled = true }` on
   `google_container_cluster` installs Google's build of the [Secrets Store CSI Driver][csi] +
   [GCP provider][gcp-prov]. Optionally, `secret_sync_config { enabled = true }` installs the
   `SecretSync` controller, which materializes a Secret Manager secret as a Kubernetes Secret so
   it can be consumed via `valueFrom.secretKeyRef`.
2. **OSS install** — install the CSI driver + GCP provider via Helm (or kustomize) into a
   self-managed namespace. Same end result; you own the lifecycle.

[csi]: https://github.com/kubernetes-sigs/secrets-store-csi-driver
[gcp-prov]: https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp

## Decision

Use the **add-on** plus **SecretSync** — two independent cluster features on
`google_container_cluster`, both turned on so a single workload can demonstrate both consumption
patterns.

- The lab's wording specifically calls for "enabling the Secrets Store CSI driver addon" — the
  managed add-on is the literal answer, and avoids two extra Helm releases the lab would otherwise
  have to own.
- The CSI driver has no env-var mode. The GCP-recommended way to expose a Secret Manager secret as
  `$ENV_VAR` (without writing custom shell to read a CSI-mounted file) is the
  [SecretSync feature][sync], which materializes a Kubernetes Secret consumed via standard
  `valueFrom.secretKeyRef` / `envFrom`. Google documents the two as independent alternatives
  (either, or both, depending on the workload's needs).
- Because the add-on registers the driver under the namespaced provider name
  `secrets-store-gke.csi.k8s.io` (not the OSS `secrets-store.csi.k8s.io`), all manifests reference
  the GKE driver name explicitly.

[sync]: https://docs.cloud.google.com/secret-manager/docs/sync-k8-secrets

## Consequences

- **Catalog changes (small):** the `gcp/gke` module gains two flags
  (`enable_secret_manager_addon`, `enable_secret_sync`) and the `gcp/gke-workload-identity` module
  gains a `secret_iam` map mirroring the existing `bucket_iam` map. Both are additive and default
  off, so existing consumers are unaffected.
- **Module sources:** all units are pinned to catalog tags — `gcp/vpc` at `gcp-vpc-v0.1.0`,
  `gcp/gke` at `gcp-gke-v0.2.0`, `gcp/secret-manager` at `gcp-secret-manager-v0.1.0`, and
  `gcp/gke-workload-identity` at `gcp-gke-workload-identity-v0.2.0` (the latter two carrying the
  new inputs this lab needs).
- **GKE version floor:** `secret_sync_config` requires a 1.33+ control plane. Default
  `release_channel = REGULAR` rolls forward into this range, but if a project pins an older
  channel, `up` will fail with a backend validation error. Documented in the README prereqs.
- **Secret values in state:** the two secret versions are seeded inline in the `secrets/volume` and
  `secrets/env` units with hardcoded test strings. The Terraform state therefore stores the
  values. This is fine for a lab demo with synthetic data; not a pattern for real secrets.
- **Direct WIF reused:** the lab keeps the same direct-Workload-Identity pattern as
  `gcp/gke-workload-identity` — IAM grants go straight to the KSA's federated principal, no GSA
  is created or impersonated. The new `secret_iam` map preserves that, scoped per-secret.
