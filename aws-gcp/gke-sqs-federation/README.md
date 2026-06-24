# aws-gcp/gke-sqs-federation

Demonstrates **keyless cross-cloud authentication**: pods on a **GKE** cluster (GCP) read and write
an **SQS** queue (AWS) with **no long-lived AWS access key**. The GKE cluster is itself an OIDC
identity provider; AWS trusts it and hands pods short-lived credentials via
`sts:AssumeRoleWithWebIdentity`.

A **writer** Deployment sends a timestamped message every few seconds and logs each send. A
**reader** Deployment long-polls the queue, logs each message body, and deletes it. Each runs under
its own Kubernetes service account mapped to its own least-privilege IAM role:

- **writer** → may only `sqs:SendMessage`
- **reader** → may only `sqs:ReceiveMessage` / `DeleteMessage` / `GetQueueAttributes`

Both authenticate identically, but the boundary is real — the writer can't read and the reader
can't write.

This is the first lab needing both AWS and GCP, so it lives under the `aws-gcp/` provider group.

## How the auth works

```
   pod (KSA writer|reader)
     │  mounts a projected SA token  (audience = sts.amazonaws.com,
     │                                 sub = system:serviceaccount:sqsdemo:<ksa>)
     ▼
   AWS SDK reads AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE
     │  calls sts:AssumeRoleWithWebIdentity
     ▼
   AWS STS
     │  validates the JWT against the GKE OIDC provider (fetches its public JWKS),
     │  checks aud + the role trust policy (sub == this KSA),
     │  returns short-lived credentials for the scoped role
     ▼
   SQS  ── writer: SendMessage ──▶  ◀── reader: ReceiveMessage/DeleteMessage ──
```

The GKE issuer URL AWS trusts is
`https://container.googleapis.com/v1/<cluster_id>`, where `cluster_id` is
`projects/<project-id>/locations/<region>/clusters/<name>` — built in Terraform from the `gcp/gke`
module's `cluster_id` output, so it matches the token's `iss` claim exactly.

## Architecture

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag:

| Unit         | Cloud | Module                  | Pinned tag                     |
| ------------ | ----- | ----------------------- | ------------------------------ |
| `network`    | GCP   | `gcp/vpc`               | `gcp-vpc-v0.1.0`               |
| `cluster`    | GCP   | `gcp/gke`               | `gcp-gke-v0.1.0`               |
| `registry`   | GCP   | `gcp/artifact-registry` | `gcp-artifact-registry-v0.2.0` |
| `queue`      | AWS   | `aws/sqs`               | `aws-sqs-v0.1.0`               |
| `federation` | AWS   | `aws/oidc-federation`   | `aws-oidc-federation-v0.1.0`   |

Dependencies: `cluster` → `network`; `federation` → `cluster` (for the issuer URL) and `queue` (for
the queue ARN the role policies scope to).

> **Note:** the `aws/sqs` module must be released as `aws-sqs-v0.1.0` in the catalog before
> `task gke-sqs:up` will resolve the `queue` unit. While iterating you can point the `queue` unit's
> `source` at the local module path (see the comment in `infra/queue/terragrunt.hcl`).

## Prerequisites

- A GCP project and a GCS bucket for Terraform state (create it with `task gke-sqs:init-state`).
- AWS credentials in your environment (profile / SSO / env vars) able to create IAM + SQS.
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `aws`, `kubectl`, `helm`, `go`, `docker`,
  `jq`, and Task installed.

Copy the env template and fill it in (`.env` is gitignored; shell exports take precedence):

```bash
task gke-sqs:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env
```

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
GCP_PROJECT_NUMBER=123456789012   # gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
AWS_REGION=us-east-1
TF_STATE_BUCKET=my-tf-state-bucket
```

The namespace (`sqsdemo`) and service-account names (`writer`, `reader`) are fixed in `root.hcl` and
matched by the Helm chart — nothing to set.

## Stand it up

```bash
task gke-sqs:init-state   # one-time: create the GCS bucket for Terraform state
task gke-sqs:validate     # cost-free
task gke-sqs:plan         # cost-free
task gke-sqs:up           # VPC, Autopilot cluster, registry (GCP) + SQS queue, OIDC provider + 2 roles (AWS)

task gke-sqs:push         # build + push the writer/reader image
task gke-sqs:all          # creds -> deploy (both Deployments) -> assert writer SENT & reader RECEIVED
```

Inspect the live exchange any time:

```bash
kubectl -n sqsdemo logs deploy/writer --tail=20   # SENT body="message #N ..."
kubectl -n sqsdemo logs deploy/reader --tail=20   # RECEIVED body="..." / DELETED messageId=...
```

## Tear it down

```bash
task gke-sqs:down   # uninstall the Helm release, then destroy all infra (GCP + AWS)
```

## Available tasks

`task gke-sqs:<name>` — `init-env`, `init-state`, `fmt`, `validate`, `lint`, `plan`, `up`, `build`,
`push`, `creds`, `deploy`, `test`, `all`, `down`.

## Security caveats

- The cluster control-plane endpoint is opened to `0.0.0.0/0` so a runner/laptop can reach it for
  kubectl/helm. Deliberate lab-only tradeoff; nodes stay private. See the ADR.

## Learned / decisions

See `docs/adr/0001-gke-to-aws-oidc-federation.md`.
