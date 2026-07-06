# aws/serverless-ai-gallery

An **AI image gallery**: users upload an image, it's processed and catalogued, and **Amazon Bedrock**
(Claude Haiku) generates a description for it. The gallery page is a small Go container on **ECS
Fargate** behind an internet-facing **HTTPS ALB** (reachable at `https://$APP_DOMAIN`), and the
upload → process → describe pipeline is four **Python Lambda microservices** wired to **S3** and
**DynamoDB**. Deploys run from **GitHub Actions**, keyless via GitHub OIDC.

This is the capstone build from `lab-instructions.md`, re-expressed in this repo's patterns:
everything is Terraform modules composed by Terragrunt units (no click-ops), buckets stay private
(presigned URLs, not public S3), and the app ships through a keyless CI pipeline. See
`docs/adr/0001-serverless-ai-gallery.md` for the design decisions.

## Architecture

```
                          client
                            │ https://ai-gallery.aws.example.com
                            ▼
   Route 53 (delegated child zone) ── alias A ──▶ Application Load Balancer
                                                    (:443 HTTPS, ACM cert; :80 → 301)
                                                    │ target group (type ip)
                                                    ▼
                                          ECS Fargate — gallery (Go static server)
                                                    │  serves index.html/index.js;
                                                    │  injects the Function URLs below
        ┌───────────────────────────────┬──────────┴───────────────┐
        ▼ (GET, browser)                 ▼ (GET, browser)            ▼ ("Upload New Image" link)
   fetch Lambda (Function URL)      ai Lambda (Function URL)    upload Lambda (Function URL)
        │ presigned GET urls             │ Bedrock (Claude Haiku)     │ serves upload.html/js,
        │ + DynamoDB descriptions        │ + DynamoDB write           │ mints presigned PUT url
        ▼                                ▼                            ▼
   website-assets bucket            website-assets bucket        upload bucket (uploads/)
   (images/uploads/, private)       DynamoDB: ImageMetadata           │ ObjectCreated
                                                                      ▼
                                                            push Lambda (Pillow layer)
                                                            resize → images/ + DynamoDB row

   GitHub Actions ─ build image + package zips ─▶ roll Fargate service + update-function-code x4
   (keyless, GitHub OIDC → IAM role)
```

The pipeline Lambdas run **outside the VPC** (invoked by the Lambda service / Function URLs, not over
the network). The VPC exists only for the Fargate gallery + ALB.

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag (units marked *local* are lab glue):

| Unit                  | Source                    | Pinned tag / kind                |
| --------------------- | ------------------------- | -------------------------------- |
| `network`             | `aws/vpc`                 | `aws-vpc-v0.1.0`                 |
| `registry`            | `aws/ecr`                 | `aws-ecr-v0.1.0`                 |
| `dynamodb`            | `aws/dynamodb`            | `aws-dynamodb-v0.1.0` **(new)**  |
| `s3-buckets/uploads`  | `aws/s3-bucket`           | `aws-s3-bucket-v0.2.0` **(new)** |
| `s3-buckets/assets`   | `aws/s3-bucket`           | `aws-s3-bucket-v0.2.0` **(new)** |
| `lambdas/upload-page` | `aws/lambda`              | `aws-lambda-v0.3.0` **(new)**    |
| `lambdas/push`        | `aws/lambda`              | `aws-lambda-v0.3.0` **(new)**    |
| `lambdas/fetch`       | `aws/lambda`              | `aws-lambda-v0.3.0` **(new)**    |
| `lambdas/ai`          | `aws/lambda`              | `aws-lambda-v0.3.0` **(new)**    |
| `upload-events`       | local (S3 → push notify)  | lab-local glue                   |
| `parent-zone-lookup`  | local (parent zone data)  | lab-local glue                   |
| `zone`                | `aws/route53`             | `aws-route53-v0.1.0`             |
| `cert`                | `aws/acm-certificate`     | `aws-acm-certificate-v0.1.0`     |
| `alb`                 | `aws/alb`                 | `aws-alb-v0.3.0`                 |
| `ecs/cluster`         | `aws/ecs-cluster`         | `aws-ecs-cluster-v0.1.0`         |
| `ecs/service`         | `aws/ecs-fargate-service` | `aws-ecs-fargate-service-v0.1.0` |
| `dns-record`          | local (ALB alias A)       | lab-local glue                   |
| `deployer-oidc`       | `aws/oidc-federation`     | `aws-oidc-federation-v0.1.0`     |

## Prerequisites

- An AWS account and an S3 bucket for Terraform state (`task ai-gallery:state-bootstrap`).
- An **existing public Route 53 hosted zone** you own (here `aws.richardbatyrov.com`). This lab
  creates a **new child zone** for `$APP_DOMAIN` and delegates it from the parent.
- **Bedrock model access**: enable the Claude Haiku model in the Bedrock console (Model access) in
  your region **before** generating descriptions. `BEDROCK_MODEL_ID` defaults to the Claude Haiku 4.5
  US cross-region inference profile (`us.anthropic.claude-haiku-4-5-20251001-v1:0`) — newer Claude
  models must be invoked through an inference profile, not the bare model id. This step is manual
  (there is no Terraform resource for model access).
- `terraform`, `terragrunt` (pinned via tenv), `aws`, `go`, `docker`, `zip`, `jq`, and Task installed.

Set the lab's inputs in a local **`.env`** (loaded automatically via Task's dotenv; `.env` is
gitignored):

```bash
task ai-gallery:init-env    # copies .env.example -> .env (no-op if it exists)
$EDITOR .env                # region, account id, state bucket, parent zone, app domain, GitHub repo, model, layer
```

## Stand it up (local)

```bash
task ai-gallery:state-bootstrap   # one-time: create the S3 state bucket
task ai-gallery:validate          # cost-free (packages the Lambda zips, then validates)
task ai-gallery:plan              # cost-free
task ai-gallery:up                # provision everything

task ai-gallery:all               # = deploy -> verify (push image + roll service, ship Lambdas, GET)
task ai-gallery:endpoint          # prints the gallery URL, ALB DNS, and the Lambda Function URLs
```

Unlike a single container, the Fargate service is created pointing at a `:bootstrap` image tag that
doesn't exist yet, so the gallery only becomes healthy after the first `deploy`. The Lambdas, by
contrast, are created from real zips during `up` and work immediately.

## Wire GitHub Actions (one-time)

```bash
task ai-gallery:ci-config
# AWS_ROLE_ARN=arn:aws:iam::<account>:role/serverless-ai-gallery-github_deployer
```

Set these repository **Variables**: `AWS_REGION`, `AWS_ROLE_ARN`, `APP_DOMAIN`. On push to `main`
(or manual dispatch) the workflow builds+pushes the gallery image, rolls the service, ships new code
to the four Lambdas, and GETs the public HTTPS endpoint — keyless via OIDC. The workflow lives at
`.github/workflows/deploy.yml` in the lab; GitHub runs the copy at the repo root
(`.github/workflows/deploy-serverless-ai-gallery.yml`).

## Tear it down

```bash
task ai-gallery:down   # destroys all infra (buckets are force_destroy; zone/cert/DNS included)
```

## Security caveats

- The three browser-facing Function URLs (`upload`, `fetch`, `ai`) use **`authorization_type = NONE`
  (public)** — the app has no user auth, matching the capstone's intent. Anyone with a URL can list
  images, request presigned URLs, and trigger Bedrock calls. For anything real, put auth in front
  (Cognito / a signed API) or switch the URLs to `AWS_IAM`.
- The upload bucket's CORS allows PUT from any origin (`*`); the **presigned URL** — not CORS — is the
  actual authorization, and presigned PUTs carry no credentials.
- The `ai` Lambda's `bedrock:InvokeModel` is scoped to `*` (inference profiles route across regions).
  Scope it to the profile + model ARNs in production.
- The account may hold only **one GitHub OIDC provider**; if one already exists (e.g. from another
  lab) the `deployer-oidc` unit will collide — import or reuse it.

## Learned / decisions

See `docs/adr/0001-serverless-ai-gallery.md` for why presigned URLs (not a public bucket or
CloudFront), why the Function URLs are injected at runtime rather than baked into the image, why the
pipeline Lambdas stay out of the VPC, the delegated-child-zone choice, the Bedrock inference-profile
requirement, and the Terraform-owns-infra / CI-owns-code split.
