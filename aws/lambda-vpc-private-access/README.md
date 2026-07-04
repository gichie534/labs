# aws/lambda-vpc-private-access

A minimal reference for **connecting a Lambda function to a VPC** so it can reach **private**
resources. The lab stands up a private EC2 instance with no public IP and no inbound access except
from the function, then invokes a VPC-attached Lambda that reads the instance over the VPC's internal
network — proving the function has access to private VPC resources.

## The idea

By default a Lambda function runs outside your VPC and can't see anything private in it. Give it a
`vpc_config` (private subnets + a security group) and Lambda creates ENIs in those subnets, so it
now sits *inside* the VPC and can talk to private resources over their private IPs.

```
                     VPC 10.0.0.0/16  (no NAT — nothing needs the internet)
   ┌───────────────────────────────────────────────────────────────────┐
   │  private subnets (10.0.128.0/20, 10.0.144.0/20)                     │
   │                                                                     │
   │   ┌───────────────┐   GET :8080    ┌──────────────────────────┐    │
   │   │ Lambda (ENIs) │ ─────────────▶ │ EC2 (no public IP)        │    │
   │   │ sg/lambda      │               │ http.server -> identity   │    │
   │   └───────────────┘               │ sg/ec2: 8080 from sg/lambda│    │
   │        │                          └──────────────────────────┘    │
   │        └── returns the instance's JSON identity to the caller      │
   └───────────────────────────────────────────────────────────────────┘
```

The EC2 instance runs a tiny HTTP server on `:8080` (Python stdlib, already on Amazon Linux 2023 —
no package install, no internet needed) that returns its own instance id, private IP, hostname, and
AZ as JSON. The Lambda GETs that endpoint and hands the JSON back. If the function weren't attached
to the VPC — or the security-group path were wrong — the GET would time out. A successful response
is the whole demonstration.

Network posture worth noting:

- **No NAT gateway.** Lambda↔EC2 traffic never leaves the VPC, so there's no need for (and no cost
  of) NAT. The private subnets have an isolated route table with no default route.
- **Least-privilege reachability.** `sg/ec2` allows inbound `8080` **only** from `sg/lambda` (a
  security-group-to-security-group rule) — not from a CIDR — so nothing else can reach the instance.
- **IMDSv2 + encrypted root volume** come from the `aws/ec2-instance` module.

## Architecture

```
infra/ (Terragrunt units)
  lookups    ──(ami_id, azs)──────────▶ vpc, ec2      local unit: AL2023 AMI + AZ discovery (no resources)
  vpc        ──(subnets, vpc_id)──────▶ sgs, ec2, lambda   dedicated VPC, NAT disabled
  sg/lambda  ──(id)───────────────────▶ sg/ec2, lambda     egress-only SG for the function
  sg/ec2     ──(id)───────────────────▶ ec2                inbound 8080 from sg/lambda only
  ec2        ──(private_ip)────────────▶ lambda            private HTTP server on :8080
  lambda                                                   VPC-attached; GETs the EC2 and returns it
```

| Unit        | Source                         | Pinned tag                  |
| ----------- | ------------------------------ | --------------------------- |
| `lookups`   | local (lab glue, no resources) | —                           |
| `vpc`       | `aws/vpc`                      | `aws-vpc-v0.1.0`            |
| `sg/lambda` | `aws/security-group`           | `aws-security-group-v0.1.0` |
| `sg/ec2`    | `aws/security-group`           | `aws-security-group-v0.1.0` |
| `ec2`       | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`   |
| `lambda`    | `aws/lambda`                   | `aws-lambda-v0.1.0`         |

The Lambda handler is a small Go program under `app/go/` (stdlib + `aws-lambda-go` only). `task
lambda-vpc:build` compiles it to a `bootstrap` binary and zips it to `build/function.zip`, which the
`lambda` unit deploys.

## Prerequisites

- An AWS account and an S3 bucket for Terraform state (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `go`, `zip`, and the `aws` CLI installed.
- The module tags above published in `gichie534/infrastructure-catalog`.

```bash
task lambda-vpc:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env               # set AWS_REGION and a globally-unique TF_STATE_BUCKET
```

> Heads up: this creates real, costed resources (a t3.micro EC2 instance and a Lambda function).
> There is **no** NAT gateway, so the ongoing cost is just the instance. Tear it down with
> `task lambda-vpc:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task lambda-vpc:state-bootstrap
```

Cost-free checks (these build the zip first):

```bash
task lambda-vpc:validate
task lambda-vpc:plan
```

Provision, then see the proof:

```bash
task lambda-vpc:up        # VPC, SGs, private EC2, VPC-attached Lambda
task lambda-vpc:invoke    # invokes the Lambda; prints the EC2's JSON identity it read
```

A successful `invoke` prints something like:

```json
{
  "ok": true,
  "target_url": "http://10.0.128.x:8080",
  "status": 200,
  "backend": {
    "message": "hello from a private EC2 instance",
    "instance_id": "i-0…",
    "private_ip": "10.0.128.x",
    "availability_zone": "us-east-1a"
  }
}
```

## Tear it down

```bash
task lambda-vpc:down
```

## Learned / decisions

See `docs/adr/0001-lambda-vpc-private-access.md` for why there's no NAT, why the EC2 is reached with
a security-group-to-security-group rule, why the demo backend is a stdlib HTTP server, and why the
Lambda and security-group modules were added to the catalog.
