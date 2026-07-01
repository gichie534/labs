# 0001 — Minimal IAM for EC2: SSM access, an inline S3 grant, and a two-module split

Status: accepted
Date: 2026-07-01

## Context

This lab is a reference for the minimal IAM wiring that gives an EC2 instance an identity, so a
workload on the box calls AWS with no static credentials. A few design points aren't obvious and are
worth recording.

## Decisions

### Reach the instance via SSM Session Manager, not SSH

The instance is reached with **SSM Session Manager**, granted by attaching the AWS-managed
`AmazonSSMManagedInstanceCore` policy to the role. This needs no SSH key, no inbound security-group
rule, and no bastion — the SSM agent (preinstalled on Amazon Linux 2023) dials **out** to the SSM
endpoints. For a lab about *minimal* configuration, "no inbound access at all" is the cleaner story
than managing a key pair and opening port 22. The only network requirement is egress to the SSM
endpoints, satisfied by the default VPC's public subnet + public IP over the internet gateway (no
NAT).

So there are no separate "Session Manager resources" to create — SSM access is purely an IAM grant
plus the agent that already ships in the AMI.

### The S3 permission is an inline policy, minimal to `s3:ListAllMyBuckets`

The demo runs `aws s3 ls`, which calls exactly one action: `s3:ListAllMyBuckets`. The lab grants
only that, as an **inline** policy on the role rather than an AWS-managed policy like
`AmazonS3ReadOnlyAccess`. Inline keeps the least-privilege grant visible right next to the role and
avoids handing the instance far broader S3 read access than the demo needs. This contrast — a
managed policy for the generic SSM capability, an inline policy for the narrow workload grant — is
the teaching point of the `iam-instance-profile` module's two inputs.

### AMI and default-VPC discovery live in a separate local unit

The `aws/ec2-instance` module takes `ami_id` and `subnet_id` as inputs (it stays region- and
account-agnostic and does no lookups). But those values come from **data sources** — the latest
Amazon Linux 2023 AMI via the SSM public parameter, and a subnet of the default VPC — and Terragrunt
`inputs` are evaluated at parse time and can't consume Terraform data-source results. So a tiny
lab-local `lookups` unit performs the reads and exposes them as outputs, which the `instance` unit
consumes via a `dependency` block. It's lab glue, not reusable infra, so it's sourced from a local
path rather than the modules repo — and it creates no resources.

### Two modules, not one

The identity (`aws/iam-instance-profile`) and the compute (`aws/ec2-instance`) are separate modules
rather than one "instance-with-a-role" module. They're independent concerns with independent reuse:
a role/profile can be shared by many instances or an autoscaling group, and an instance module is
useful without this particular role. Keeping them split follows the catalog's single-purpose rule
and lets each be tested and versioned on its own.

### AMI resolved dynamically, not pinned

The AMI is resolved from the `al2023-ami-kernel-default-x86_64` SSM public parameter so the lab is
region-portable and always launches a current, patched image. A production stack that values
bit-for-bit reproducibility might pin an AMI ID instead; for a teaching lab, portability wins.

## Consequences

- A real, costed EC2 instance (t3.micro) exists for the lab's lifetime — tear down with
  `task ec2-profile:down`.
- The lab pins two module tags: `aws-iam-instance-profile-v0.1.0` and `aws-ec2-instance-v0.1.0`.
- Requires a default VPC in the target region (the `lookups` unit assumes one exists).
- Because the AMI is resolved dynamically, a new AL2023 release can change the AMI ID and cause a
  plan to want to replace the instance.
