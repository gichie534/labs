# 0001 — Keyless GKE → AWS access via OIDC web identity federation

Status: accepted
Date: 2026-06-24

## Context

This lab connects two clouds: a workload on **GKE** (GCP) must read and write an **SQS** queue
(AWS). The interesting problem is authentication — how does a pod on Google prove its identity to
Amazon without a long-lived AWS access key copied into the cluster?

It is also the first lab needing **both** AWS and GCP, so it establishes the `aws-gcp/` provider
group at the repo root for cross-cloud labs.

## Decisions

### Keyless OIDC web identity federation, not static AWS keys

A GKE cluster is itself an **OIDC identity provider**: it publishes a discovery document and a public
JWKS at a stable issuer URL, and the kubelet can mint short-lived, signed tokens for a pod's service
account. AWS already knows how to trust an external OIDC provider and exchange its tokens for
temporary credentials via `sts:AssumeRoleWithWebIdentity`.

So we register the GKE issuer as an **IAM OIDC provider** in AWS and gate IAM roles on the token's
claims. A pod mounts a **projected service-account token** (audience `sts.amazonaws.com`); the AWS
SDK reads it (`AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`) and assumes the role itself. No static
secret ever exists. This is the exact mirror of the `gcp/gke-workload-identity` lab — there a GCP
workload proved its identity to GCP; here a GCP workload proves its identity to AWS.

The rejected alternative — an IAM user with an access key stored as a Kubernetes Secret — means a
long-lived credential to rotate, leak, and audit. Federation removes it entirely.

### Reuse the IdP-neutral `aws/oidc-federation` module

The catalog's `aws/oidc-federation` module already owns the mechanism (one IAM OIDC provider + roles
whose trust policy gates on `aud`/`sub`), and is deliberately IdP-neutral — it's used for
GitHub→AWS CI. Pointing its `provider_url` at the GKE issuer instead of GitHub's is all that's
needed; no new module. The GKE token's `sub` is `system:serviceaccount:<namespace>:<ksa>`, which the
trust policy matches with `StringEquals`.

### Construct the issuer URL from the cluster's `cluster_id`

AWS matches the OIDC provider URL against the token's `iss` claim **exactly**, so the value must be
right. The GKE issuer is
`https://container.googleapis.com/v1/projects/<PROJECT_ID>/locations/<REGION>/clusters/<NAME>`. The
`gcp/gke` module's `cluster_id` output is precisely that path
(`projects/<project-id>/locations/<region>/clusters/<name>`), so the federation unit builds the
issuer as `https://container.googleapis.com/v1/${cluster_id}` from a real value in Terraform state.
This uses the **project ID** (what GKE actually puts in `iss`), and avoids hand-assembling the URL
from a project number we'd have to guess.

### Two KSAs → two least-privilege roles (send-only / receive-only)

Rather than one shared role with both permissions, each workload gets its own KSA and its own IAM
role: the writer role may only `sqs:SendMessage`; the reader role may only `sqs:ReceiveMessage`,
`DeleteMessage`, `GetQueueAttributes`. Both pods authenticate identically, but the auth boundary is
real — the writer physically cannot read and the reader cannot write. This makes the lab a
demonstration of *scoped* federation, not just connectivity. The trust policies bind each role to
exactly one KSA subject, so a pod can only assume its own role.

### A new minimal `aws/sqs` catalog module

No SQS module existed. Per the rule against inlining reusable infra into a lab, a minimal
`aws/sqs` module was added (single queue, standard by default, SSE-SQS on, IAM-free). It owns only
the queue; the send/receive IAM split lives in the lab's `federation` unit, which consumes the
queue's `arn`. The lab pins it at `aws-sqs-v0.1.0`.

> TODO(release): tag `aws-sqs-v0.1.0` in the catalog before this lab is "done"; until then the
> `queue` unit's `?ref=` will not resolve.

### Long-running Deployments, not one-shot Jobs

The task is "one pod writes, the other reads, both log continuously," so each side is a long-running
**Deployment** (writer sends every few seconds; reader long-polls and deletes). Long polling
(`receive_wait_time_seconds = 20` on the queue + `WaitTimeSeconds` in the SDK call) keeps the reader
from busy-spinning. The assertion reads recent logs from both Deployments.

### Standard queue, not FIFO

Ordering and exactly-once aren't part of the objective, and standard queues are simpler with higher
throughput. The reader deletes each message it processes; no DLQ is configured (out of scope).

### master_authorized_networks = 0.0.0.0/0 (lab-only tradeoff)

The cluster control-plane endpoint is opened so a runner/laptop can reach it for kubectl/helm. Nodes
stay private (egress via Cloud NAT, which is also how they reach AWS STS/SQS). Lab-only; tear down
when finished.

## Consequences

- The lab pins these module tags: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`,
  `gcp-artifact-registry-v0.2.0`, `aws-oidc-federation-v0.1.0`, and the new `aws-sqs-v0.1.0`.
- `root.hcl` generates **two** provider blocks (google + aws). GCP credentials come from gcloud ADC;
  AWS credentials (to run `terragrunt apply`) come from your normal AWS CLI environment.
- "Which pod can do what to the queue" is answered entirely by the two IAM role policies — there is
  no AWS key to find, because there isn't one.
