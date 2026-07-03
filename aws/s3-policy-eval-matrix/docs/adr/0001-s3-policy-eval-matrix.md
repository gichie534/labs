# 0001 — Demonstrating S3 access as IAM identity policy + bucket policy combined

Status: accepted
Date: 2026-07-03

## Context

This lab shows how AWS decides S3 access when an **IAM identity policy** (attached to the caller's
role) and an **S3 bucket policy** (attached to the resource) both have a say. The behaviour is
frequently misremembered as "both must allow", when in a single account the rule is a union with an
explicit-deny override. Rather than describe it, the lab runs the real evaluation on four EC2
instances, one per combination.

## Decisions

### Four instances, one shared bucket — the 2x2 evaluation matrix

The two variables are: does the **identity** policy allow the read, and what does the **bucket**
policy say (Allow / explicit Deny / silent). The four instances cover the meaningful cells:

- `identity-only` — identity Allow, bucket silent → **OK** (union: either side allowing suffices).
- `bucket-only` — identity silent, bucket Allow → **OK** (resource-side Allow alone is enough).
- `explicit-deny` — identity Allow, bucket explicit Deny → **AccessDenied** (Deny always wins).
- `neither` — identity silent, bucket silent → **AccessDenied** (implicit deny; access must be
  granted *somewhere*).

Using one shared bucket keeps the resource constant so the only thing that varies is the policy
combination — the teaching point stays unambiguous.

### The evaluation rule this encodes (same account)

1. An explicit `Deny` on **either** the identity or the resource policy always wins.
2. Otherwise the request is allowed if **either** side has a matching `Allow`.
3. With no `Allow` anywhere, the default is an implicit deny.

`bucket-only` is the cell people find surprising: an empty identity policy still reads the object
because the bucket policy's resource-side `Allow` is sufficient on its own.

### Scope is deliberately single-account

The union rule holds only **within one account**. Cross-account access requires an `Allow` on
*both* sides (the trusting account's resource policy *and* the calling account's identity policy),
which is a materially different evaluation. Mixing it in here would muddy the union demonstration, so
cross-account is left to a separate lab and everything here lives in one account.

### Bucket-policy statements are scoped to the lab role ARNs

Both the `Allow` (for `bucket-only`) and the explicit `Deny` (for `explicit-deny`) set `Principal`
to the specific lab role ARN. A broad `Principal: "*"` Deny keyed on something coarse is a common way
to fence the bucket owner/admin out of their own bucket; scoping to the exact role ARNs keeps the
blast radius to the lab and leaves the owner's access intact.

### AMI/subnet discovery and the probe object are separate local units

As in the sibling `aws/ec2-abac-s3` lab, AMI + default-VPC discovery is a local `lookups` unit
because Terragrunt `inputs` can't consume data-source results at parse time. The demonstration reads
a fixture object (`probe.txt`); creating an object isn't the S3 module's job and the object is
lab-specific, so a tiny local `seed` unit creates it, ordered after `s3` (bucket exists) and before
the instances (which read it at boot). Both are lab glue, sourced from local paths, and `lookups`
creates no resources.

### Proof over SSM, not SSH

All four instances are reached via SSM Session Manager (managed policy
`AmazonSSMManagedInstanceCore`), so there's no SSH key or inbound rule. `task s3-eval:verify` runs
the same `aws s3 cp` on every instance via `ssm send-command` and asserts each cell's expected
result (allow/deny). Each instance also records the same probe at boot to
`/var/log/s3-eval-demo.log` (readable with `show-proof`).

### A denial can surface as `403 Forbidden`, not just `AccessDenied`

`aws s3 cp` issues a `HeadObject` before the `GetObject`. `HeadObject` has no response body, so when
a bucket-policy `Deny` blocks it, S3 returns a bare `403 Forbidden` instead of the XML `AccessDenied`
error code — that's what the `explicit-deny` cell shows. The `neither` cell, denied at a different
point, surfaces `AccessDenied`. Because both are genuine denials, `verify` treats the two cells the
same: it asserts the read did **not** succeed (`exit_code != 0`) **and** the failure was a
permissions error (`AccessDenied`, `Forbidden`, or `403`), rather than string-matching `AccessDenied`
alone.

## Consequences

- Real, costed resources exist for the lab's lifetime: four t3.micro instances and an S3 bucket.
  Tear down with `task s3-eval:down` (`force_destroy = true` lets the non-empty bucket be destroyed).
- The lab pins three module tags: `aws-iam-instance-profile-v0.1.0`, `aws-s3-bucket-v0.1.0`, and
  `aws-ec2-instance-v0.1.0`.
- Requires a default VPC in the target region (the `lookups` unit assumes one exists).
- The demo bucket name (`DEMO_BUCKET`) must be globally unique, like the state bucket.
- Because the AMI is resolved dynamically, a new AL2023 release can change the AMI ID and cause a
  plan to want to replace the instances.
