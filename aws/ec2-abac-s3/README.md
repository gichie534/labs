# aws/ec2-abac-s3

A minimal reference for **ABAC layered on top of RBAC** for S3: two EC2 instances are given the
**identical** IAM identity policy (RBAC) that permits reading a demo bucket, yet only **one** can
actually read it — because the bucket policy adds an **attribute-based** gate keyed on a principal
tag. It makes concrete *why* ABAC buys you security that RBAC alone doesn't.

## The idea

Both instances carry the same role-level grant:

```
role (allowed)  ─ inline policy: s3:ListBucket + s3:GetObject on the bucket   ← RBAC
role (denied)   ─ inline policy: s3:ListBucket + s3:GetObject on the bucket   ← identical RBAC
```

On RBAC alone, **both** would read the bucket. The difference is one attribute:

```
role (allowed)  ─ tag: project = abac-lab
role (denied)   ─ (no project tag)
```

AWS surfaces an IAM role's tags as `aws:PrincipalTag/*` on the instance's assumed-role session. The
demo **bucket policy** denies the read actions to the two lab roles whenever
`aws:PrincipalTag/project` is not `abac-lab`:

```
                         ┌─ allowed role: PrincipalTag/project=abac-lab ─▶ condition false ─▶ not denied ─▶ RBAC allows ─▶ READ OK
bucket policy Deny  ─────┤
  (StringNotEquals)      └─ denied role:  no project tag                 ─▶ condition true  ─▶ DENY        ─────────────────▶ AccessDenied
```

So the denied instance is blocked *even though its RBAC identity policy allows the read*. That
contrast — RBAC says yes, ABAC says no — is the whole demonstration. In the real world ABAC lets one
policy scale across many principals/resources by attribute instead of enumerating ARNs, and adds a
guardrail that a too-broad RBAC grant can't bypass.

## Architecture

```
infra/ (Terragrunt units)
  lookups ──(ami_id, subnet_id)──────────────▶ instance-allowed / instance-denied   local: AL2023 AMI + default-VPC subnet
  iam-allowed ─(role_arn, profile)─┐
  iam-denied  ─(role_arn, profile)─┼─▶ s3 (bucket + ABAC bucket policy scoped to both role ARNs)
                                   │        │
                                   │        └─▶ seed (probe.txt fixture object)  local
                                   │                 │
  iam-allowed (profile) ───────────┴────────────────┴─▶ instance-allowed   EC2 + boot probe (expect SUCCESS)
  iam-denied  (profile) ────────────────────────────┴─▶ instance-denied    EC2 + boot probe (expect AccessDenied)
```

| Unit               | Source                         | Pinned tag                        |
| ------------------ | ------------------------------ | --------------------------------- |
| `lookups`          | local (lab glue, no resources) | —                                 |
| `iam-allowed`      | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `iam-denied`       | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `s3`               | `aws/s3-bucket`                | `aws-s3-bucket-v0.1.0`            |
| `seed`             | local (test fixture object)    | —                                 |
| `instance-allowed` | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |
| `instance-denied`  | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |

`lookups` and `seed` are lab-local units (not reusable modules): `lookups` only reads data sources
(AMI + subnet); `seed` creates the single `probe.txt` fixture the demo reads. Both are lab-specific
glue, so they're sourced from local paths rather than the modules repo.

## Why the tag lives on the role (not passed as a session tag)

EC2 instance-profile credentials don't pass STS session tags. AWS includes an assumed-role session's
**role tags** in the request context as `aws:PrincipalTag/*` (a session tag would only override a
role tag of the same key). So tagging the *role* `project=abac-lab` is exactly what the bucket policy
sees — no session-tag plumbing needed. See `docs/adr/0001-abac-over-rbac-s3.md`.

## Prerequisites

- An AWS account with a **default VPC** in your region, and an S3 bucket for Terraform state
  (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, and Task installed.
- For `task ec2-abac:verify` / `show-proof`: nothing extra (they use SSM `send-command`, not the
  Session Manager plugin).
- The module tags above published in `gichie534/infrastructure-catalog` — including
  **`aws-s3-bucket-v0.1.0`** (new for this lab).

```bash
task ec2-abac:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env             # set AWS_REGION, a globally-unique TF_STATE_BUCKET, and a globally-unique ABAC_BUCKET
```

> Heads up: this creates real, costed resources (two t3.micro instances + an S3 bucket). Tear it
> down with `task ec2-abac:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task ec2-abac:state-bootstrap
```

Cost-free checks:

```bash
task ec2-abac:validate
task ec2-abac:plan
```

Provision, then prove ABAC:

```bash
task ec2-abac:up        # IAM roles/profiles + bucket + ABAC policy + probe object + both instances
task ec2-abac:verify    # runs the same S3 read on both instances over SSM and asserts allowed=OK, denied=AccessDenied
```

`verify` is the assertion. `show-proof` is the same idea read from each instance's boot-time log:

```bash
task ec2-abac:show-proof   # cats /var/log/abac-demo.log from both instances via SSM
```

## Tear it down

```bash
task ec2-abac:down
```

## Learned / decisions

See `docs/adr/0001-abac-over-rbac-s3.md` for why the tag is on the role (not a session tag), why the
bucket-policy Deny is scoped to the two role ARNs, why both roles get identical RBAC, and the new
`aws/s3-bucket` module split.
