# aws/lambda-alb-https

Runs a Go "hello world" workload as an **AWS Lambda** function invoked directly by an internet-facing
**Application Load Balancer** that terminates TLS with an **ACM certificate**, so the app is reachable
on a **public HTTPS endpoint** (`https://$APP_DOMAIN`, e.g. `lambda-https.aws.richardbatyrov.com`)
with an HTTP→HTTPS redirect. Deploys run from **GitHub Actions**, which builds the zip and ships it
with `aws lambda update-function-code` — authenticating to AWS **keylessly** via GitHub OIDC.

This is the Lambda sibling of `aws/ecs-fargate-https`: the same ALB + ACM + Route 53 building blocks,
with Lambda instead of ECS Fargate. See `docs/adr/0001-lambda-alb-https.md` for the design decisions.

## Architecture

```
                 client
                   │ https://lambda-https.aws.example.com
                   ▼
   Route 53 (existing zone) ── alias A ──▶ Application Load Balancer
                                            (:443 HTTPS, ACM cert; :80 → 301 HTTPS)
                                            │ target group (type lambda)
                                            ▼
                                       AWS Lambda (Go, provided.al2023)
                                            ▲
   GitHub Actions ─ build zip ─▶ update-function-code
   (keyless, GitHub OIDC → IAM role)
```

The ALB invokes the function through the Lambda service, so the function is **not** attached to the
VPC (the VPC exists only because an ALB needs subnets in two AZs).

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag (two units are lab-local glue):

| Unit            | Source                                 | Pinned tag / kind            |
| --------------- | -------------------------------------- | ---------------------------- |
| `network`       | `aws/vpc`                              | `aws-vpc-v0.1.0`             |
| `zone-lookup`   | local (data lookup of the parent zone) | lab-local glue               |
| `cert`          | `aws/acm-certificate`                  | `aws-acm-certificate-v0.1.0` |
| `function`      | `aws/lambda`                           | `aws-lambda-v0.2.0`          |
| `alb`           | `aws/alb`                              | `aws-alb-v0.3.0`             |
| `deployer-oidc` | `aws/oidc-federation`                  | `aws-oidc-federation-v0.1.0` |
| `dns-record`    | local (ALB alias A record)             | lab-local glue               |

Dependencies: `cert` needs `zone-lookup`; `alb` needs `network` + `cert` + `function`;
`deployer-oidc` needs `function`; `dns-record` needs `zone-lookup` + `alb`.

> **Before you can run it:** two **new** module tags were created in the modules repo
> (`infrastructure-catalog`) for this lab — `aws-alb-v0.3.0` (Lambda target support) and
> `aws-lambda-v0.2.0` (`ignore_code_changes`). They must be **committed and pushed to the catalog
> remote** (`git push origin <tag>`) before `terragrunt` can fetch them via `?ref=<tag>`.

## Prerequisites

- An AWS account and an S3 bucket for Terraform state (create it with `task lambda-https:state-bootstrap`).
- An **existing public Route 53 hosted zone** you own (here `aws.richardbatyrov.com`) whose
  delegation already works. The app record and ACM validation records are created directly in it.
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, `go`, `zip`, `jq`, and Task installed.

Set the lab's inputs in a local **`.env`** (loaded automatically via Task's dotenv; `.env` is
gitignored):

```bash
task lambda-https:init-env   # copies .env.example -> .env (no-op if it exists)
$EDITOR .env                 # fill in region, state bucket, parent zone, app domain, GitHub repo
```

The variables the lab reads:

```bash
AWS_REGION=us-east-1
TF_STATE_BUCKET=my-tf-state-bucket
PARENT_ZONE_NAME=aws.richardbatyrov.com             # existing public zone you own
APP_DOMAIN=lambda-https.aws.richardbatyrov.com      # hostname served over HTTPS (within the zone)
GITHUB_REPOSITORY=owner/repo                         # repo allowed to assume the CI deploy role
```

## Stand it up (local)

```bash
task lambda-https:state-bootstrap   # one-time: create the S3 state bucket
task lambda-https:validate          # cost-free (builds the zip, then validates)
task lambda-https:plan              # cost-free
task lambda-https:up                # VPC, ACM cert, Lambda, ALB (HTTPS, lambda target), CI role, DNS

task lambda-https:verify            # GET https://$APP_DOMAIN/
task lambda-https:endpoint          # prints https://$APP_DOMAIN and the ALB DNS name
```

Unlike the ECS lab (whose service can point at an image tag that doesn't exist yet), a Lambda needs a
real artifact at create time — so `up` builds the initial `bootstrap` zip and the endpoint works right
after `up`. Steady-state code changes are shipped by `deploy`/CI:

```bash
task lambda-https:all               # = deploy -> verify  (build zip, update-function-code, GET)
```

## Wire GitHub Actions (one-time)

```bash
task lambda-https:ci-config
# AWS_ROLE_ARN=arn:aws:iam::<account>:role/lambda-alb-https-github_deployer
```

Set these repository **Variables**: `AWS_REGION`, `AWS_ROLE_ARN`, and `APP_DOMAIN`. The lab-fixed
function name (`lambda-alb-https`) is hardcoded as a constant in the workflow, so only the account-
and domain-specific values are variables. On push to `main` (or manual dispatch) the workflow builds
the zip, ships it with `update-function-code`, and **GETs the public HTTPS endpoint** — keyless via
OIDC.

> The Action is the steady-state **app loop**; it assumes infra, the certificate, the ALB, and the
> DNS record were stood up once by the Taskfile. It holds minimal permissions
> (`lambda:UpdateFunctionCode` + `Get*` on this function only) — no ECR, no `PassRole`, no DNS or
> infra access. See the ADR.
>
> The workflow file lives inside the lab (`.github/workflows/deploy.yml`). GitHub runs the copy at
> the repository root: `.github/workflows/deploy-lambda-alb-https.yml`.

## Tear it down

```bash
task lambda-https:down   # destroys all infra (DNS/cert records included)
```

## Security caveats

- The function runs **outside the VPC** — the ALB reaches it through the Lambda service, not the
  network — so there is no task SG or NAT to reason about. A function needing private resources would
  set `vpc_config`; this one doesn't.
- The account may hold only **one GitHub OIDC provider**; if one already exists (e.g. from the ECS
  lab), the `deployer-oidc` unit will collide — import it or reuse it. See the ADR.

## Learned / decisions

See `docs/adr/0001-lambda-alb-https.md` for why ALB + Lambda target (not API Gateway or a Function
URL), why a zip (not a container image), why the native ALB handler (not the Lambda Web Adapter), why
the function stays out of the VPC, and the Terraform-owns-infra / CI-owns-code split
(`ignore_code_changes`, the Lambda analogue of `ignore_task_definition_changes`).
