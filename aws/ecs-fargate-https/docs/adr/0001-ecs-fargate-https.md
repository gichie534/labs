# 0001 — Public HTTPS for an ECS Fargate workload via ALB + ACM, deployed by GitHub Actions

Status: accepted
Date: 2026-07-05

## Context

This lab is the AWS analogue of `gcp/gke-ingress-managed-cert`: run a Go "hello world" HTTP server
as a managed container workload and expose it on a **public HTTPS endpoint**
(`https://$APP_DOMAIN`), with a GitHub Actions pipeline that builds the image and rolls it out.
Where the GKE lab uses Autopilot + Ingress + a Google-managed cert, here we use **ECS Fargate + an
Application Load Balancer + an ACM certificate**. Several choices had real alternatives.

## Decisions

### ECS Fargate (not EC2-backed ECS, not EKS)

Fargate is the minimal managed-container path on AWS: no nodes, autoscaling groups, or AMIs to own —
just a task definition and a service. EKS would reintroduce the Kubernetes machinery the reference
lab already covers; plain EC2-backed ECS would add capacity management with no upside for a "run one
container" objective.

### Public HTTPS via ALB + ACM DNS-validated cert + a Route 53 alias (not CloudFront)

An **Application Load Balancer** with an **HTTPS listener** is the direct way to terminate TLS in
front of an ECS service. The certificate is a **DNS-validated public ACM certificate** in the ALB's
region (ACM certs for an ALB must be regional; only CloudFront needs `us-east-1`). Validation is
automatic because the records are written straight into a Route 53 zone we control. The app hostname
is a Route 53 **alias A record** to the ALB. The HTTP :80 listener is a permanent **301 redirect** to
HTTPS.

CloudFront in front of the ALB would also give HTTPS but adds a CDN, a second cert story, and origin
config for no benefit to this objective — out of scope.

Because ACM DNS validation and the ALB are ordinary Terraform resources with a stable ALB DNS name,
there is **no two-phase stand-up** here (the GKE lab needed one only because its LB IP was ephemeral
and the managed cert validated by load-balancer authorization). One `up` brings everything up.

### DNS records go directly into the existing parent zone (no delegated child zone)

The reference GKE lab **delegated a child zone** and had to manage reproducible NS delegation. Here
the parent zone (`aws.richardbatyrov.com`) already exists in Route 53, so the lab simply writes the
app's A record and the ACM validation records **directly into it**. Those records are Terraform-owned
and torn down with the lab. This is the minimal, fully-reproducible choice — there is no delegation
to go stale — and DNS delegation is not this lab's learning objective. (Reproducible subdomain
delegation is available in the `aws/route53` module via `delegate_to_parent_zone` if a future lab
wants an isolated child zone.)

### Tasks in public subnets with public IPs; NAT disabled

Fargate tasks need outbound reachability to pull the image from ECR and reach AWS APIs. The two
options are **private subnets + a NAT gateway (or a set of VPC interface endpoints)** or **public
subnets + `assign_public_ip`**. NAT gateways and interface endpoints both bill hourly; for a
throwaway lab we run tasks in **public subnets with public IPs** and disable NAT entirely. Security is
preserved by the **task security group allowing inbound only from the ALB's security group** on
:8080 — the tasks are not reachable directly from the internet even though they have public IPs.

A production setup would place tasks in private subnets behind NAT/endpoints; that is a deliberate
cost-for-simplicity tradeoff here, documented so it isn't copied blindly.

### Terraform owns infra; CI owns the rollout (`ignore_task_definition_changes`)

The clean split mirrors the GKE lab's "Terraform makes the cluster, Helm ships the app". The
`ecs-fargate-service` module creates the service with a **bootstrap image** and then sets
`lifecycle.ignore_changes = [task_definition, desired_count]`, so Terraform stops managing which
revision runs. The **GitHub Actions pipeline** (and `task ecs-https:deploy` locally) registers new
task-definition revisions with real image tags and updates the service; Terraform never reverts them
on the next `apply`. The bootstrap image tag doesn't need to exist at `up` time — the service simply
has no healthy tasks until the first deploy pushes and rolls a real image.

(Because a `lifecycle` block can't be driven by a variable, the module implements this as two
count-gated `aws_ecs_service` resources selected by the `ignore_task_definition_changes` flag.)

### Keyless CI via GitHub OIDC, minimal-privilege role

CI authenticates by **direct GitHub OIDC federation** (assume-role with a short-lived token, no
access keys), via the `aws/oidc-federation` module. The deploy role is scoped to this repo's `main`
ref and granted only: ECR auth + push/pull to **this** repository, `ecs:RegisterTaskDefinition` /
`DescribeTaskDefinition` (which don't support resource scoping), `ecs:UpdateService` /
`DescribeServices` on **this** service, and `iam:PassRole` on the service's execution + task roles
(conditioned to `ecs-tasks.amazonaws.com`). It gets **nothing** for DNS, ACM, or infra — those are
stood up once by the operator, exactly as CI stays minimal in the reference lab.

> **OIDC provider caveat:** an AWS account may hold only one IAM OIDC provider per issuer URL, and
> the module is create-only. If a GitHub OIDC provider already exists in the account (e.g. from
> another lab), `up` will collide on the `deployer-oidc` unit — import the existing provider or have
> a single owner create it.

### New catalog modules (rather than inlining infra in the lab)

The catalog had no ECS/ECR/ACM modules and the `alb` module only did plain HTTP. Per the two-repo
discipline, reusable infra is not inlined in a lab, so this lab drove four new modules and one
enhancement, each released by pinned tag:

| Unit            | Module                    | Pinned tag                             |
| --------------- | ------------------------- | -------------------------------------- |
| `network`       | `aws/vpc`                 | `aws-vpc-v0.1.0`                       |
| `registry`      | `aws/ecr`                 | `aws-ecr-v0.1.0` (new)                 |
| `ecs/cluster`   | `aws/ecs-cluster`         | `aws-ecs-cluster-v0.1.0` (new)         |
| `cert`          | `aws/acm-certificate`     | `aws-acm-certificate-v0.1.0` (new)     |
| `alb`           | `aws/alb`                 | `aws-alb-v0.2.0` (HTTPS added)         |
| `ecs/service`   | `aws/ecs-fargate-service` | `aws-ecs-fargate-service-v0.1.0` (new) |
| `deployer-oidc` | `aws/oidc-federation`     | `aws-oidc-federation-v0.1.0`           |

Two units are **lab-local glue** (not reusable), sourced from a local path: `zone-lookup` (resolve
the existing parent zone id — a data read Terragrunt `inputs` can't do) and `dns-record` (the ALB
alias A record). `dns-record` is kept separate from `zone-lookup` deliberately: the zone id must be
known *before* the cert, but the alias record can only be created *after* the ALB, so folding them
into one unit would create a `zone → cert → alb → record` cycle.

## Consequences

- HTTPS is live after a single `up` + first `deploy`. ACM DNS validation typically completes in a
  few minutes on first issuance.
- The lab depends on the module tags listed above. The four new tags and `aws-alb-v0.2.0` must be
  **pushed to the catalog remote** before `terragrunt` can fetch them (they are consumed by
  `git::https://…?ref=<tag>`).
- Tasks carry public IPs (lab tradeoff); tear the lab down when finished.
