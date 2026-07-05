# 0001 — Public HTTPS for a Lambda workload via ALB + ACM, deployed by GitHub Actions

Status: accepted
Date: 2026-07-05

## Context

This lab is the Lambda sibling of `aws/ecs-fargate-https`: run a Go "hello world" HTTP workload and
expose it on a **public HTTPS endpoint** (`https://$APP_DOMAIN`), with a GitHub Actions pipeline that
builds the code and ships it. It deliberately keeps the same building blocks as the ECS lab —
**ALB + ACM + a Route 53 alias** — and swaps the compute from ECS Fargate to **AWS Lambda**. Several
choices had real alternatives.

## Decisions

### Compute: AWS Lambda, zip-packaged Go on `provided.al2023` (not a container image)

The objective is "run one small handler", which is Lambda's sweet spot. The function is a compiled
Go binary named `bootstrap` on the **`provided.al2023`** custom runtime, shipped as a **zip** — the
shape the catalog `aws/lambda` module already takes. A **container-image Lambda** would add an ECR
repository and an image build/push path for no benefit at this size, so it's out of scope.

### HTTPS/routing fabric: ALB with a Lambda target (not API Gateway, not Function URL + CloudFront)

An **Application Load Balancer** with an **HTTPS listener** fronting a **Lambda target** is the
closest analogue to the ECS lab and reuses the same `alb` + `acm-certificate` + Route 53 alias
pattern verbatim. The certificate is a **DNS-validated public ACM certificate** in the ALB's region
(ACM for an ALB is regional; only CloudFront needs `us-east-1`), validated automatically because the
records are written straight into a Route 53 zone we control. The app hostname is a Route 53
**alias A record** to the ALB. The HTTP :80 listener is a permanent **301 redirect** to HTTPS.

The real alternatives were deliberately not taken:

- **API Gateway HTTP API + custom domain** — more "serverless-native" and cheaper (no ALB/VPC), but
  a different fabric (different cert story via ACM + a custom domain name, different event shape). It
  would stop this being "the same lab with Lambda instead of Fargate."
- **Lambda Function URL + CloudFront** — moves TLS to CloudFront and the cert to `us-east-1` + a CDN,
  again a different shape for no gain here.

### The Lambda is NOT attached to the VPC

The ALB invokes a Lambda target **through the Lambda service**, not over a network path, so the
function does not need to live in the VPC. The VPC exists only because an ALB requires subnets in
two AZs. This is simpler and cheaper than the ECS lab: **no NAT, no task ENIs, no task security
group**, and no cold-start ENI penalty. (VPC attachment would only be needed to reach private
resources, which this hello-world doesn't.)

### The app is a native ALB-target handler (not API Gateway proxy, not the Lambda Web Adapter)

The Go app is an `events.ALBTargetGroupRequest` → `events.ALBTargetGroupResponse` handler started
with `lambda.Start`. Two alternatives were considered:

- An **API Gateway proxy event** handler — wrong event shape for an ALB target.
- The **Lambda Web Adapter**, which would let the ECS lab's `net/http` server run **unchanged** under
  Lambda. That is attractive for "lift a normal HTTP server", but it adds an extension layer and
  readiness wiring.

We chose the **native ALB handler** for minimalism and one dependency (`aws-lambda-go`). The
tradeoff, recorded so it isn't a surprise: the app is a Lambda handler, **not** a byte-identical copy
of the ECS lab's `net/http` server. Routing behaviour is the same (`/` greets, `/healthz` is a probe,
everything else 404s).

### Terraform owns infra; CI owns code (`ignore_code_changes`)

Mirroring the ECS lab's "Terraform makes the infra, CI ships the app": the `aws/lambda` module
creates the function and then, with **`ignore_code_changes = true`**, stops managing the deployment
package. The **GitHub Actions pipeline** (and `task lambda-https:deploy` locally) ships new code with
**`aws lambda update-function-code`**; Terraform never reverts it on the next apply.

One honest difference from the ECS lab: ECS could create a service pointing at a `:bootstrap` image
tag that **doesn't exist yet**, deferring all real code to the first deploy. Lambda **cannot** —
`aws_lambda_function` needs a real artifact at create time. So `task up` **builds the initial zip**
and the function is functional immediately after `up`; steady-state rollouts are still CI-owned, and
Terraform ignores subsequent code changes. (The flag is implemented as two count-gated
`aws_lambda_function` resources because `lifecycle.ignore_changes` can't be driven by a variable —
the same idiom the `ecs-fargate-service` module uses.)

### Keyless CI via GitHub OIDC, minimal-privilege role

CI authenticates by **direct GitHub OIDC federation** (assume-role with a short-lived token, no
access keys), via the `aws/oidc-federation` module. The deploy role is scoped to this repo's `main`
ref and granted only **`lambda:UpdateFunctionCode`** plus `lambda:GetFunction` /
`GetFunctionConfiguration` on **this** function. It's even smaller than the ECS role: no ECR, and no
`iam:PassRole` (updating code doesn't pass the execution role). It gets nothing for DNS, ACM, the
ALB, or infra — those are stood up once by the operator.

> **OIDC provider caveat:** an AWS account may hold only one IAM OIDC provider per issuer URL, and
> the module is create-only. If a GitHub OIDC provider already exists in the account (e.g. from the
> ECS lab), `up` will collide on the `deployer-oidc` unit — import the existing provider or have a
> single owner create it.

### Catalog module changes (rather than inlining infra in the lab)

Per the two-repo discipline, reusable infra is not inlined in a lab. Two catalog modules were
extended, each released by a pinned tag:

| Unit            | Module                | Pinned tag                        |
| --------------- | --------------------- | --------------------------------- |
| `network`       | `aws/vpc`             | `aws-vpc-v0.1.0`                  |
| `cert`          | `aws/acm-certificate` | `aws-acm-certificate-v0.1.0`      |
| `function`      | `aws/lambda`          | `aws-lambda-v0.2.0` (new flag)    |
| `alb`           | `aws/alb`             | `aws-alb-v0.3.0` (lambda targets) |
| `deployer-oidc` | `aws/oidc-federation` | `aws-oidc-federation-v0.1.0`      |

- **`aws-alb-v0.3.0`** adds real Lambda-target support: for `target_type = "lambda"` the target group
  is created without `port`/`protocol`/`vpc_id` and without an HTTP health check, the module grants
  Elastic Load Balancing permission to invoke the function, and registers it. (Before this, the
  module accepted the `target_type` string but would fail to apply for Lambda.)
- **`aws-lambda-v0.2.0`** adds the `ignore_code_changes` flag described above.

Two units are **lab-local glue** (not reusable), sourced from a local path: `zone-lookup` (resolve
the existing parent zone id — a data read Terragrunt `inputs` can't do) and `dns-record` (the ALB
alias A record). `dns-record` is kept separate from `zone-lookup` deliberately: the zone id must be
known *before* the cert, but the alias record can only be created *after* the ALB, so folding them
into one unit would create a `zone → cert → alb → record` cycle.

## Consequences

- HTTPS is live after a single `up` (which builds and deploys the initial function code) — no first
  deploy is strictly required to get a working endpoint, though `deploy`/CI is how new code ships.
  ACM DNS validation typically completes in a few minutes on first issuance.
- The lab depends on the module tags above. The two **new** tags (`aws-alb-v0.3.0`,
  `aws-lambda-v0.2.0`) must be **pushed to the catalog remote** before `terragrunt` can fetch them
  via `?ref=<tag>`.
- The function runs outside the VPC (cheaper, no NAT). Tear the lab down when finished.
