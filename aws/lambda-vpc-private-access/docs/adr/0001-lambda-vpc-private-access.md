# 0001 — Connecting Lambda to a VPC to reach a private resource

Status: accepted
Date: 2026-07-04

## Context

This lab demonstrates the one thing that makes a Lambda function able to reach private VPC resources
(RDS, ElastiCache, a private EC2 instance): attaching it to the VPC via `vpc_config`. To make the
proof concrete and cheap, the "private resource" is a single EC2 instance that serves its own
identity over HTTP, and the Lambda reads it. A few decisions aren't obvious and are worth recording.

## Decisions

### Two new catalog modules: `aws/lambda` and `aws/security-group`

The catalog had no Lambda module and no standalone security-group module. Rather than inline that
Terraform into the lab (which the labs steering forbids for reusable infra), both were added to
`infrastructure-catalog`, tested with Terratest, and pinned here by tag (`aws-lambda-v0.1.0`,
`aws-security-group-v0.1.0`). The `aws/ec2-instance` module already existed and takes
`vpc_security_group_ids` + `subnet_id`, so it composes directly.

- `aws/lambda` owns the function, its execution role, and a retention-managed log group. Its
  `vpc_config` input is the crux of this lab: when set, the module also attaches the
  `AWSLambdaVPCAccessExecutionRole` managed policy, which the function needs to create ENIs in the
  VPC. Without that policy the function can't attach and invocations fail.
- `aws/security-group` manages rules with the current best-practice
  `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` resources (one CIDR
  per rule) rather than legacy inline blocks, and supports pointing a rule at another security group.

### No NAT gateway

The traffic the lab cares about — Lambda → EC2 on `:8080` — is entirely internal to the VPC. Neither
side needs to reach the internet: the EC2 server uses only the Python stdlib already in the AMI, and
the Lambda only talks to the instance. So `enable_nat_gateway = false`. This removes the NAT
gateway's hourly + per-GB cost and gives the cleaner "truly private, no egress" story. The private
subnets get an isolated route table with no `0.0.0.0/0` route.

### Reach the EC2 with a security-group-to-security-group rule, not a CIDR

`sg/ec2` allows inbound `8080` only from `sg/lambda`, referenced by security-group id — not from the
VPC CIDR. This is tighter (nothing else in the VPC can reach the instance, even though they share the
network) and is the intended teaching point of the `aws/security-group` module's
`source_security_group_id` support. The Lambda SG itself has no inbound rules at all — it only needs
egress to reach the instance.

### The demo backend is a stdlib HTTP server on the instance

The instance runs Python's `http.server` (present on Amazon Linux 2023) as a systemd unit, returning
its instance id / private IP / AZ as JSON. Using the stdlib means **no package install**, which
matters because there's no NAT — the instance couldn't `yum install` anything anyway. Serving its own
identity makes the proof unambiguous: the JSON the Lambda returns could only have come from that
specific private instance.

### Go Lambda, built to `provided.al2023`

The handler is Go (per the lab choice), compiled to a static `bootstrap` and zipped. The
`provided.al2023` custom runtime is the current standard for Go on Lambda (the `go1.x` runtime is
retired). The build is a Task step (`build`) that also runs the Go unit tests; `validate`/`plan`
depend on it because the `aws/lambda` module hashes the zip at plan time.

### AMI and AZ discovery live in a separate local unit

`aws/vpc` takes `azs` as an input and `aws/ec2-instance` takes `ami_id`; both are data-source reads
(the latest AL2023 AMI via the SSM public parameter, and the region's available AZs) that Terragrunt
`inputs` can't perform at parse time. So a tiny lab-local `lookups` unit does the reads and exposes
outputs the other units consume — lab glue, not reusable infra, so it's sourced locally and creates
no resources.

## Consequences

- Real, costed resources exist for the lab's lifetime: a t3.micro EC2 instance and a Lambda function
  (no NAT gateway). Tear down with `task lambda-vpc:down`.
- The lab pins four module tags: `aws-vpc-v0.1.0`, `aws-security-group-v0.1.0`,
  `aws-ec2-instance-v0.1.0`, and `aws-lambda-v0.1.0`.
- Because the AMI is resolved dynamically, a new AL2023 release can change the AMI ID and cause a
  plan to want to replace the instance.
- The VPC-attached Lambda has a cold-start ENI setup cost on first invocation after deploy; fine for
  a lab, worth knowing for latency-sensitive production use.
