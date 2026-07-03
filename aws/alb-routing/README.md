# aws/alb-routing

A minimal reference for **Application Load Balancer routing**: how one ALB, with a single HTTP
listener, sends requests to different backends based on the **URL path** or the **Host header**.

The lab stands up two EC2 instances — `app-a` and `app-b`, each running a tiny web server that
reports its own identity — behind one internet-facing ALB, then routes traffic to them by path and
by host.

## The idea

```
                              ┌── /a, /a/*  ───────────────▶ target group A ──▶ app-a
client ─▶ ALB (HTTP :80) ─────┤── /b, /b/*  ───────────────▶ target group B ──▶ app-b
          listener + rules    ├── Host: a.alb.lab ─────────▶ target group A ──▶ app-a
                              ├── Host: b.alb.lab ─────────▶ target group B ──▶ app-b
                              └── (no rule matches) ───────▶ fixed 404
```

- **Path-based:** `/a` and `/a/*` go to A, `/b` and `/b/*` go to B.
- **Host-based:** the exact same URL routes differently depending on the `Host` header —
  `a.alb.lab` to A, `b.alb.lab` to B. This is demonstrated with `curl -H "Host: ..."`, so the lab
  needs **no real DNS or registered domain**.
- **No match:** the listener returns a fixed `404` so unmatched requests fail cheaply instead of
  hitting an arbitrary backend.

Each instance answers *every* path with its identity, because the ALB does **not** strip the matched
path prefix — a request to `/a/foo` arrives at app-a as `/a/foo`.

## Architecture

```
infra/ (Terragrunt units)
  lookups   ──(ami_id, vpc_id, vpc_cidr, subnet_ids)──▶ …   local glue: AL2023 AMI + default-VPC reads
  security  ──(app_security_group_id)────────────────▶ app-a/app-b   local glue: app SG (port 80 from VPC CIDR)
  app-a     ──(id)───────────────────────────────────▶ alb   EC2 instance, "hello from app-a"
  app-b     ──(id)───────────────────────────────────▶ alb   EC2 instance, "hello from app-b"
  alb                                                        ALB + listener + 2 target groups + 4 rules
```

| Unit       | Source                         | Pinned tag                |
| ---------- | ------------------------------ | ------------------------- |
| `lookups`  | local (lab glue, no resources) | —                         |
| `security` | local (lab glue)               | —                         |
| `app-a`    | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0` |
| `app-b`    | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0` |
| `alb`      | `aws/alb`                      | `aws-alb-v0.1.0`          |

`lookups` and `security` are lab-local units (not reusable modules): `lookups` only reads data
sources (the latest AL2023 AMI via an SSM public parameter, and the default VPC + its subnets) and
`security` creates the one app security group. The app instances allow HTTP only from the VPC CIDR,
so clients must reach them through the ALB — and scoping to the CIDR (rather than the ALB's SG) keeps
`security` independent of `alb`, avoiding a dependency cycle.

## Prerequisites

- An AWS account with a **default VPC** (with subnets in ≥2 AZs) in your region, and an S3 bucket for
  Terraform state (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, `curl`, and Task installed.
- The module tags above published in `gichie534/infrastructure-catalog`.

```bash
task alb:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env        # set AWS_REGION and a globally-unique TF_STATE_BUCKET
```

> Heads up: this creates real, costed resources (two t3.micro instances + an ALB). Tear it down with
> `task alb:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task alb:state-bootstrap
```

Cost-free checks:

```bash
task alb:validate
task alb:plan
```

Provision, then prove the routing:

```bash
task alb:up      # two instances + the ALB and its rules
task alb:demo    # curls the ALB for both routing styles (+ the 404 fallback)
```

`demo` may show the 404 fallback for a minute or two right after `up` while the targets pass their
first health checks; re-run it once they're healthy. You can also grab the DNS name directly:

```bash
task alb:dns
curl "http://$(task -s alb:dns)/a/"
curl -H "Host: b.alb.lab" "http://$(task -s alb:dns)/"
```

## Tear it down

```bash
task alb:down
```

## Learned / decisions

See `docs/adr/0001-alb-routing.md` for why routing is demonstrated with Host headers instead of real
DNS, why the app security group is scoped to the VPC CIDR (to avoid a dependency cycle), why two
single instances rather than ASGs, and which module versions the lab pins.
