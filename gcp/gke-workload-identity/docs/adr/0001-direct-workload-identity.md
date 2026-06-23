# 0001 — Demonstrate direct Workload Identity Federation for GKE service accounts

Status: accepted
Date: 2026-06-23

## Context

This lab showcases **Workload Identity Federation for GKE**: how a pod authenticates to Google Cloud
APIs as its Kubernetes service account (KSA), with no exported service-account key. To make the
authorization boundary visible, a one-shot Go Job reads one object from each of two GCS buckets — an
"allowed" bucket the KSA is granted read on, and a "denied" bucket it is granted nothing on — and
reports OK (printing the data) or DENIED (printing a human-readable error) per bucket. The assertion
is that allowed=OK and denied=DENIED.

Several choices had real alternatives.

## Decisions

### Direct WIF (KSA as IAM principal), not GSA impersonation

GKE Workload Identity supports two patterns:

- **GSA impersonation (older):** create a Google service account, bind a KSA to it with
  `roles/iam.workloadIdentityUser`, annotate the KSA with `iam.gke.io/gcp-service-account`, and grant
  resource access to the GSA. The catalog's [`gcp/workload-iam`](../../../../infrastructure-catalog/modules/gcp/workload-iam)
  module implements this.
- **Direct (recommended):** the KSA *is* an IAM principal. Grant roles straight to its federated
  principal string and skip the GSA entirely.

The principal is:

```
principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/<NAMESPACE>/sa/<KSA>
```

This lab deliberately uses the **direct** pattern, per Google's current recommendation
([Authenticate to Google Cloud APIs from GKE workloads](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#authn-to-gcp)).
It removes a whole identity (the GSA), its key-rotation/impersonation surface, and the KSA
annotation — fewer moving parts and a clearer "this KSA may do X" mental model.

Consequence: the existing `gcp/workload-iam` module doesn't fit (it builds the GSA path). A new
standalone catalog module, [`gcp/gke-workload-identity`](../../../../infrastructure-catalog/modules/gcp/gke-workload-identity),
was added (tag `gcp-gke-workload-identity-v0.1.0`) that grants IAM roles directly to the KSA
principal.

### A new standalone module, not a submodule of `gcp/gke`

The federated principal is a **project-level** identity (the fixed `<project>.svc.id.goog` pool); it
exists independently of any one cluster resource and binding to it needs only the project, namespace,
and KSA name. Co-locating it inside the `gke` module would wrongly couple "grant a KSA access" to
"create a cluster," force consumers to pull the whole cluster module, and chain its release cadence
to the cluster module's (this catalog tags per top-level module; nested modules can't be sourced or
tagged on their own). So it ships as a sibling of `gke` — mirroring how the existing `workload-iam`
is already a standalone IAM unit while producer modules stay pure.

### Module is minimal but extensible

The lab needs only a bucket grant and (room for) project roles, so the module ships `bucket_iam` +
`project_roles` and nothing else. GCP has no single generic resource-IAM resource — each service has
its own (`google_storage_bucket_iam_member`, `google_secret_manager_secret_iam_member`,
`google_dns_managed_zone_iam_member`, …) — so "universal" means typed inputs per resource kind. The
module is structured so each new kind is a one-input/one-resource addition (the principal string is
computed once and reused), keeping it minimal now without painting us into a corner.

### Two buckets to prove the gate, denied by omission

The negative case is what proves authorization is actually enforced (vs. reads happening to work).
The "denied" bucket is denied simply by **not being referenced** in any IAM grant — the
workload-identity unit depends only on the allowed bucket. This keeps the demonstration honest and
needs no explicit deny rule.

### One-shot Job, not a long-running server

The workload only needs to read once and report, so it's a Kubernetes **Job** (printing to stdout),
not an HTTP server. Assertions read the Job's logs — no port-forward or Service needed. The chart
models the Job as a Helm `post-install,post-upgrade` hook with `before-hook-creation` delete policy
so every `helm upgrade` reruns it (a Job pod template is otherwise immutable) while the latest Job's
logs persist for the assertion. The Go program exits 0 even when the denied read fails, because a
403 there is the *expected* result; the pass/fail decision lives in the assertion that checks both
RESULT lines.

### Buckets named by derivation, seeded out-of-band

Bucket names are derived from the project ID (`<project>-wif-allowed` / `-wif-denied`) so they're
globally unique with zero extra config; the Taskfile, IAM unit, and chart all derive the same names.
The `gcs` module only creates buckets (it grants nothing and writes no objects), so a `seed` task
uploads `message.txt` with `gcloud storage cp` rather than inlining `google_storage_bucket_object`.

### CI uses a separate GitHub->GCP federation

The pipeline authenticates to GCP keylessly via **GitHub** Workload Identity Federation
(`gcp/workload-identity-federation`), with minimal roles (`artifactregistry.writer`,
`container.developer`). This is a *different* federation from the lab's subject (the in-cluster
KSA->IAM federation) — both are "WIF," kept distinct in the units and docs to avoid conflation. CI is
the steady-state app loop (build -> push -> rerun Job -> re-assert); the operator stands up infra and
seeds buckets once via the Taskfile.

### master_authorized_networks = 0.0.0.0/0 (inherited lab-only tradeoff)

The control-plane endpoint is opened so GitHub-hosted runners can reach it to run kubectl/helm.
Lab-only; tear down when finished.

## Consequences

- The lab pins these module tags: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`, `gcp-gcs-v0.1.0`,
  `gcp-artifact-registry-v0.2.0`, `gcp-workload-identity-federation-v0.2.1`, and the new
  `gcp-gke-workload-identity-v0.1.0`.
- The `gcs-bucket` catalog module was renamed to `gcs` (and tagged `gcp-gcs-v0.1.0`) as part of this
  work; references in `workload-iam` and the new module were updated.
- Direct WIF means there is no GSA to inspect; "who can this pod act as" is answered entirely by the
  IAM bindings on the KSA principal.
