# 0001 — Serverless AI image gallery

- Status: accepted
- Date: 2026-07-06

## Context

The capstone (`lab-instructions.md`) builds an AI image gallery entirely with the AWS CLI: DynamoDB,
two S3 buckets, four Python Lambdas (with public Function URLs and an S3 trigger), an ECS Fargate web
app behind an HTTPS ALB, a custom domain, a CI/CD pipeline, and Amazon Bedrock for descriptions. This
lab re-expresses that as reusable Terraform modules composed by Terragrunt units, consistent with the
rest of the repo. The interesting decisions are where the CLI recipe and our patterns diverge.

## Decisions

### Private buckets + presigned URLs (not public S3, not CloudFront)

Our `s3-bucket` module refuses to serve public objects (public access fully blocked, ACLs disabled).
Rather than fork it or add a CDN, both buckets stay private and the Lambdas mint short-lived
presigned URLs: `upload` hands the browser a presigned **PUT** to the upload bucket, and `fetch`
returns presigned **GET** URLs for the gallery. This keeps the hardened baseline, needs no public
bucket policy, and adds no CloudFront distribution. CORS on the upload bucket allows the browser PUT;
the presigned URL (not CORS) is the authorization, so `allowed_origins = ["*"]` is acceptable.

### Function URLs injected at runtime, not baked into the image

`index.js` needs the `fetch` and `ai` Function URLs, and the gallery links to the `upload` Function
URL — all unknown until the Lambdas exist. Instead of templating them into the image at build time
(which would couple the image to a deploy and force rebuilds when a URL changes), the gallery is a
tiny Go server that receives the three URLs as **task-definition environment variables** (wired from
the Lambda outputs) and substitutes them into `index.html`/`index.js` at request time. The image
stays generic.

The `upload` Lambda serves its own page (`upload.html`/`upload.js`, packaged in the zip) and its
script posts back **same-origin**, so no URL needs injecting there; only the "Back to Gallery" link
is templated from `APP_DOMAIN`. This removed a whole "seed HTML into a bucket" step the CLI recipe
had.

### Pipeline Lambdas run outside the VPC

`push`, `fetch`, `ai`, and `upload` reach S3, DynamoDB, and Bedrock over the AWS APIs and are invoked
by the Lambda service (S3 event / Function URLs), not over the network. They need no VPC attachment.
The VPC exists only because the ALB + Fargate gallery need subnets in two AZs. The Fargate tasks run
in public subnets with public IPs and no NAT (cost), locked to the ALB's security group.

### Delegated child hosted zone (not records in the parent)

The lab creates a **new public hosted zone** for `$APP_DOMAIN` and delegates it from the existing
parent zone (NS records written into the parent by the `route53` module). This keeps the lab's DNS
self-contained and removable — `down` deletes the child zone and its delegation — rather than
scattering records into a shared parent zone. The ACM validation records and the ALB alias A record
are written into this child zone.

### Bedrock: Claude Haiku via a cross-region inference profile

Claude Haiku 3 (in the original instructions) is deprecated. Newer Claude models on Bedrock cannot be
invoked by their bare foundation-model id for on-demand throughput — they require a **cross-region
inference profile**. `BEDROCK_MODEL_ID` therefore defaults to `us.anthropic.claude-haiku-4-5-...`
(the `us.` profile) and is an input so it can be changed per region/account. Model access is enabled
manually in the console (no Terraform resource). `ai.py` was updated to parse the Messages-API
response into plain text and to sniff the image's media type rather than assume JPEG.

### Terraform owns infra; CI owns code

Every Lambda uses `ignore_code_changes = true` and the Fargate service uses
`ignore_task_definition_changes = true`. Terraform creates them from an initial artifact and then
stops managing the code, so the GitHub Actions pipeline (`update-function-code` for the four Lambdas,
plus register-task-def + roll for the container) owns steady-state rollouts and Terraform never
reverts a deploy. The CI role is keyless (GitHub OIDC) and scoped to exactly ECR push/pull, ECS
register/update on this service, `iam:PassRole` on its roles, and `lambda:UpdateFunctionCode`/`Get`
on the four functions — nothing for DNS, ACM, S3, or DynamoDB.

### Public Function URLs (no auth)

The three browser-facing Function URLs use `authorization_type = NONE`, matching the capstone (the
app has no user auth). This is a deliberate lab simplification, called out in the README's security
caveats; a real deployment would add authentication or use `AWS_IAM`.

## Consequences

- Three module changes ship with this lab and must be tagged/pushed before it can run:
  `aws-dynamodb-v0.1.0` (new), `aws-lambda-v0.3.0` (Function URLs + layers), `aws-s3-bucket-v0.2.0`
  (CORS).
- The gallery is only healthy after the first `deploy` (bootstrap image tag); the Lambdas work right
  after `up`.
- Public, unauthenticated endpoints exist by design — acceptable for a throwaway lab, not for
  production.
