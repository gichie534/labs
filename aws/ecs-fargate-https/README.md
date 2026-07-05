# aws/ecs-fargate-https

Runs a Go "hello world" HTTP server as an **ECS Fargate** service behind an internet-facing
**Application Load Balancer** that terminates TLS with an **ACM certificate**, so the app is reachable
on a **public HTTPS endpoint** (`https://$APP_DOMAIN`, e.g. `ecs-https.aws.richardbatyrov.com`) with
an HTTP→HTTPS redirect. Deploys run from **GitHub Actions**, which builds the image, pushes it to
ECR, registers a new task-definition revision, and rolls the service — authenticating to AWS
**keylessly** via GitHub OIDC.

This is the AWS analogue of `gcp/gke-ingress-managed-cert` (GKE Ingress + Google-managed cert). See
`docs/adr/0001-ecs-fargate-https.md` for the design decisions.

## Architecture

```
                 client
                   │ https://ecs-https.aws.example.com
                   ▼
   Route 53 (existing zone) ── alias A ──▶ Application Load Balancer
                                            (:443 HTTPS, ACM cert; :80 → 301 HTTPS)
                                            │ target group (type ip), health /healthz
                                            ▼
                              ECS Fargate service ── tasks (public subnet, SG: ALB only)
                                            ▲
   GitHub Actions ─ build ─▶ ECR ─ pull ─▶ (new task-def revision → rolling update)
   (keyless, GitHub OIDC → IAM role)
```

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag (two units are lab-local glue):

| Unit            | Source                                 | Pinned tag / kind                |
| --------------- | -------------------------------------- | -------------------------------- |
| `network`       | `aws/vpc`                              | `aws-vpc-v0.1.0`                 |
| `zone-lookup`   | local (data lookup of the parent zone) | lab-local glue                   |
| `registry`      | `aws/ecr`                              | `aws-ecr-v0.1.0`                 |
| `ecs/cluster`   | `aws/ecs-cluster`                      | `aws-ecs-cluster-v0.1.0`         |
| `cert`          | `aws/acm-certificate`                  | `aws-acm-certificate-v0.1.0`     |
| `alb`           | `aws/alb`                              | `aws-alb-v0.2.0`                 |
| `ecs/service`   | `aws/ecs-fargate-service`              | `aws-ecs-fargate-service-v0.1.0` |
| `deployer-oidc` | `aws/oidc-federation`                  | `aws-oidc-federation-v0.1.0`     |
| `dns-record`    | local (ALB alias A record)             | lab-local glue                   |

The two ECS units are grouped under `infra/ecs/` (`ecs/cluster`, `ecs/service`).

Dependencies: `cert` needs `zone-lookup`; `alb` needs `network` + `cert`; `ecs/service` needs
`network` + `ecs/cluster` + `alb` + `registry`; `deployer-oidc` needs `registry` + `ecs/cluster` +
`ecs/service`; `dns-record` needs `zone-lookup` + `alb`.

> **Before you can run it:** the four new module tags and `aws-alb-v0.2.0` were created in the modules
> repo (`infrastructure-catalog`) for this lab. They must be **pushed to the catalog remote**
> (`git push origin <tag>`) before `terragrunt` can fetch them via `?ref=<tag>`.

## Prerequisites

- An AWS account and an S3 bucket for Terraform state (create it with `task ecs-https:state-bootstrap`).
- An **existing public Route 53 hosted zone** you own (here `aws.richardbatyrov.com`) whose
  delegation already works. The app record and ACM validation records are created directly in it.
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, `docker`, `jq`, `go`, and Task installed.

Set the lab's inputs in a local **`.env`** (loaded automatically via Task's dotenv; `.env` is
gitignored):

```bash
task ecs-https:init-env   # copies .env.example -> .env (no-op if it exists)
$EDITOR .env              # fill in region, state bucket, parent zone, app domain, GitHub repo
```

The variables the lab reads:

```bash
AWS_REGION=us-east-1
TF_STATE_BUCKET=my-tf-state-bucket
PARENT_ZONE_NAME=aws.richardbatyrov.com          # existing public zone you own
APP_DOMAIN=ecs-https.aws.richardbatyrov.com      # hostname served over HTTPS (within the zone)
GITHUB_REPOSITORY=owner/repo                      # repo allowed to assume the CI deploy role
```

## Stand it up (local)

```bash
task ecs-https:state-bootstrap   # one-time: create the S3 state bucket
task ecs-https:validate          # cost-free
task ecs-https:plan              # cost-free
task ecs-https:up                # VPC, ECR, cluster, ACM cert, ALB (HTTPS), Fargate service, CI role, DNS

# build + push the image, register a task-def revision, roll the service, then GET the HTTPS endpoint
task ecs-https:all               # = deploy -> verify
task ecs-https:endpoint          # prints https://$APP_DOMAIN and the ALB DNS name
```

The service is created with a `:bootstrap` image that doesn't exist yet, so it has no healthy tasks
until the first `deploy` pushes and rolls a real image. `task ecs-https:all` prints the greeting
fetched over HTTPS on success.

## Wire GitHub Actions (one-time)

```bash
task ecs-https:ci-config
# AWS_ROLE_ARN=arn:aws:iam::<account>:role/ecs-fargate-https-github_deployer
```

Set these repository **Variables**: `AWS_REGION`, `AWS_ROLE_ARN`, and `APP_DOMAIN`. The lab-fixed
names (ECR repository, ECS cluster/service, task family, container) are hardcoded as constants in the
workflow — they are always `ecs-fargate-https` / `app`, so only the account- and domain-specific
values are variables. On push to `main` (or manual dispatch) the workflow builds, pushes to ECR,
registers a new task-def revision, rolls the service, and **GETs the public HTTPS endpoint** —
keyless via OIDC.

> The Action is the steady-state **app loop**; it assumes infra, the certificate, and the DNS record
> were stood up once by the Taskfile. It holds minimal permissions (ECR push/pull + ECS
> register/update on this service + `iam:PassRole` on the task roles) — no DNS or infra access. See
> the ADR.
>
> The workflow file lives inside the lab (`.github/workflows/deploy.yml`). GitHub runs the copy at
> the repository root: `.github/workflows/deploy-ecs-fargate-https.yml`.

## Tear it down

```bash
task ecs-https:down   # destroys all infra (ECR force_delete and DNS/cert records included)
```

## Security caveats

- Fargate tasks run in **public subnets with public IPs** (no NAT gateway, to keep the lab cheap).
  They are not reachable directly — the task security group allows inbound only from the ALB. A
  production setup would use private subnets + NAT/VPC endpoints. See the ADR.
- The account may hold only **one GitHub OIDC provider**; if one already exists, the `deployer-oidc`
  unit will collide — import it or reuse it. See the ADR.

## Learned / decisions

See `docs/adr/0001-ecs-fargate-https.md` for why Fargate, why ALB + ACM (not CloudFront), why records
go straight into the existing zone (no delegated child zone, unlike the GKE reference), the
public-subnet-vs-NAT tradeoff, and the Terraform-owns-infra / CI-owns-rollout split.
