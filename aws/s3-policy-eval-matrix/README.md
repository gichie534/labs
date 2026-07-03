# aws/s3-policy-eval-matrix

A minimal reference for **how an IAM identity policy and an S3 bucket (resource) policy combine** to
decide access, in a single AWS account. Four EC2 instances each carry a different combination of the
two policy sides, so each lands in a different cell of the evaluation matrix — and the boot-time
probe on each instance shows whether the read is allowed or denied.

## The idea

For a request in the **same account**, S3 evaluates the caller's IAM identity policy and the
bucket's resource policy together:

1. An explicit `Deny` on **either** side always wins.
2. Otherwise, the request is allowed if **either** side has a matching `Allow`.
3. With no `Allow` anywhere, the default is an **implicit deny**.

The lab makes each rule concrete with one instance per cell:

| Instance (`infra/` unit) | Identity (IAM) policy | Bucket policy for its role | Expected | Why                               |
| ------------------------ | --------------------- | -------------------------- | -------- | --------------------------------- |
| `instance-identity-only` | Allow `s3:GetObject`  | silent                     | **OK**   | identity Allow alone is enough    |
| `instance-bucket-only`   | silent (no S3 grant)  | Allow `s3:GetObject`       | **OK**   | resource Allow alone is enough    |
| `instance-explicit-deny` | Allow `s3:GetObject`  | explicit `Deny`            | **Deny** | explicit Deny overrides Allow     |
| `instance-neither`       | silent                | silent                     | **Deny** | no Allow anywhere → implicit deny |

The two `OK` cells prove the **union** rule (either side allowing is enough); `explicit-deny` proves
**Deny beats Allow**; `neither` is the implicit-deny baseline.

## Architecture

```
infra/ (Terragrunt units)
  lookups ──(ami_id, subnet_id)──────────────▶ all four instance units      local: AL2023 AMI + default-VPC subnet

  iam-identity-only ─(profile)───────────────▶ instance-identity-only       identity Allow
  iam-bucket-only   ─(role_arn, profile)─┐
  iam-explicit-deny ─(role_arn, profile)─┼─▶ s3 (bucket + matrix policy: Allow bucket-only, Deny explicit-deny)
  iam-neither       ─(profile)───────────┘        │
                                                  └─▶ seed (probe.txt fixture object)  local
                                                          │
  each iam-* (profile) ───────────────────────────────────┴─▶ instance-*   EC2 + boot probe
```

| Unit                     | Source                         | Pinned tag                        |
| ------------------------ | ------------------------------ | --------------------------------- |
| `lookups`                | local (lab glue, no resources) | —                                 |
| `iam-identity-only`      | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `iam-bucket-only`        | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `iam-explicit-deny`      | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `iam-neither`            | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `s3`                     | `aws/s3-bucket`                | `aws-s3-bucket-v0.1.0`            |
| `seed`                   | local (test fixture object)    | —                                 |
| `instance-identity-only` | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |
| `instance-bucket-only`   | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |
| `instance-explicit-deny` | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |
| `instance-neither`       | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |

`lookups` and `seed` are lab-local units (not reusable modules): `lookups` only reads data sources
(AMI + subnet); `seed` creates the single `probe.txt` fixture the demo reads. Both are lab-specific
glue, so they're sourced from local paths rather than the modules repo.

## Same-account scope

The union rule ("either side allowing is enough") holds **within one account**. Cross-account access
requires an Allow on *both* sides — that's a different evaluation and gets its own lab. Everything
here lives in a single account. See `docs/adr/0001-s3-policy-eval-matrix.md`.

## Prerequisites

- An AWS account with a **default VPC** in your region, and an S3 bucket for Terraform state
  (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, and Task installed.
- `verify` / `show-proof` use SSM `send-command` (no Session Manager plugin needed).
- The module tags above published in `gichie534/infrastructure-catalog`.

```bash
task s3-eval:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env            # set AWS_REGION, a globally-unique TF_STATE_BUCKET, and a globally-unique DEMO_BUCKET
```

> Heads up: this creates real, costed resources (four t3.micro instances + an S3 bucket). Tear it
> down with `task s3-eval:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task s3-eval:state-bootstrap
```

Cost-free checks:

```bash
task s3-eval:validate
task s3-eval:plan
```

Provision, then prove the matrix:

```bash
task s3-eval:up        # four IAM roles/profiles + bucket + matrix policy + probe object + four instances
task s3-eval:verify    # runs the same S3 read on all four instances over SSM and asserts each cell's expected result
```

`verify` is the assertion. `show-proof` is the same idea read from each instance's boot-time log:

```bash
task s3-eval:show-proof   # cats /var/log/s3-eval-demo.log from all four instances via SSM
```

## Tear it down

```bash
task s3-eval:down
```

## Learned / decisions

See `docs/adr/0001-s3-policy-eval-matrix.md` for the evaluation rule this lab encodes, why the
matrix is four instances against one shared bucket, why the bucket-policy statements are scoped to
the lab role ARNs, and why scope is deliberately single-account.
