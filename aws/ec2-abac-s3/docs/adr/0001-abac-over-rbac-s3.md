# 0001 — Demonstrating ABAC over RBAC for S3 with two EC2 instances

Status: accepted
Date: 2026-07-01

## Context

This lab shows why attribute-based access control (ABAC) adds security beyond role-based access
control (RBAC). Two EC2 instances get the same S3 identity policy, but only one is allowed to read
the bucket — the difference is a single principal attribute enforced by the bucket policy. Several
design points aren't obvious and are worth recording.

## Decisions

### Both roles get identical RBAC; the tag is the only difference

Each instance role carries a byte-for-byte identical inline policy granting `s3:ListBucket` +
`s3:GetObject` on the demo bucket. If the lab differentiated the two at the RBAC layer (e.g. only one
role gets the grant), it would be demonstrating RBAC, not ABAC. Keeping RBAC identical and moving the
distinction entirely into an attribute (`project=abac-lab`) makes the teaching point unambiguous:
RBAC alone permits both; the ABAC gate is what stops one.

### The attribute is an IAM role tag, surfaced as `aws:PrincipalTag`

EC2 instance-profile credentials are an assumed-role session that passes **no STS session tags**.
AWS includes an assumed-role session's **role tags** in the request context as `aws:PrincipalTag/*`
(if a session tag of the same key were passed, it would take precedence — but instance profiles pass
none). So tagging the *role* `project=abac-lab` is precisely what a resource policy evaluates, with
no session-tag plumbing. This is the mechanism that makes ABAC work for EC2 workloads.

### The gate lives in the bucket policy as a scoped explicit Deny

The ABAC condition is enforced on the **resource** side (the bucket policy), not the identity side,
because that's where ABAC guards a too-broad RBAC grant: even if an identity policy allows the read,
the resource says no unless the attribute matches. It's written as an explicit `Deny` with
`StringNotEquals` on `aws:PrincipalTag/project`, so a missing tag (the denied role) fails the
condition and is blocked. The Deny is **scoped by `Principal` to the two lab role ARNs** so it can't
accidentally lock the bucket owner/admin out of their own bucket — a broad `Principal: "*"` Deny on a
tag condition is a common way to fence yourself out.

### AMI/subnet discovery and the probe object are separate local units

As in `aws/ec2-instance-profile`, AMI + default-VPC discovery is a local `lookups` unit because
Terragrunt `inputs` can't consume data-source results at parse time. Additionally, the demonstration
reads a fixture object (`probe.txt`); creating an object isn't the S3 module's job and the object is
lab-specific, so a tiny local `seed` unit creates it, ordered after `s3` (bucket exists) and before
the instances (which read it at boot). Both are lab glue, sourced from local paths, and `lookups`
creates no resources.

### A new `aws/s3-bucket` module, kept single-purpose

The bucket needs a reusable module (the catalog had none), so `aws/s3-bucket` was added to
`gichie534/infrastructure-catalog` and pinned at `aws-s3-bucket-v0.1.0`. It owns only the bucket and
its security defaults (block public access, default SSE, `BucketOwnerEnforced`) plus an **optional
`bucket_policy`** input — mirroring how `iam-instance-profile` takes `inline_policies`. The
ABAC policy document itself is lab-specific composition and stays in the lab's `s3` unit; the module
stays environment-agnostic and reusable.

### Proof over SSM, not SSH

Both instances are reached via SSM Session Manager (managed policy `AmazonSSMManagedInstanceCore`),
so there's no SSH key or inbound rule. `task ec2-abac:verify` runs the same `aws s3 cp` on both
instances via `ssm send-command` and asserts the allowed instance succeeds while the denied instance
returns `AccessDenied`. Each instance also records the same probe at boot to `/var/log/abac-demo.log`
(readable with `show-proof`).

## Consequences

- Real, costed resources exist for the lab's lifetime: two t3.micro instances and an S3 bucket. Tear
  down with `task ec2-abac:down` (`force_destroy = true` lets the non-empty bucket be destroyed).
- The lab pins three module tags: `aws-iam-instance-profile-v0.1.0`, `aws-s3-bucket-v0.1.0`, and
  `aws-ec2-instance-v0.1.0`.
- Requires a default VPC in the target region (the `lookups` unit assumes one exists).
- The demo bucket name (`ABAC_BUCKET`) must be globally unique, like the state bucket.
- Because the AMI is resolved dynamically, a new AL2023 release can change the AMI ID and cause a
  plan to want to replace the instances.
```
