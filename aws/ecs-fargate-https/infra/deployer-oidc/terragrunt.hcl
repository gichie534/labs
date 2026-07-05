# Keyless CI identity: an IAM OIDC provider for GitHub Actions plus a single deploy role the
# workflow assumes directly (no long-lived access keys). The role is scoped to this repo's `main`
# ref and granted only what shipping an image needs:
#   - ECR: auth + push/pull to THIS repository
#   - ECS: register a new task-def revision, describe it, and update/describe THIS service
#   - iam:PassRole on the service's execution + task roles (so a new revision can reference them)
#
# It deliberately gets nothing for DNS, ACM, or infra — those are stood up once by the operator via
# the Taskfile. See the ADR.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/oidc-federation?ref=aws-oidc-federation-v0.1.0"
}

dependency "registry" {
  config_path = "../registry"

  mock_outputs = {
    arn = "arn:aws:ecr:us-east-1:000000000000:repository/ecs-fargate-https"
  }
}

dependency "cluster" {
  config_path = "../ecs/cluster"

  mock_outputs = {
    cluster_arn = "arn:aws:ecs:us-east-1:000000000000:cluster/ecs-fargate-https"
  }
}

dependency "service" {
  config_path = "../ecs/service"

  mock_outputs = {
    service_id         = "arn:aws:ecs:us-east-1:000000000000:service/ecs-fargate-https/ecs-fargate-https"
    execution_role_arn = "arn:aws:iam::000000000000:role/ecs-fargate-https-execution"
    task_role_arn      = "arn:aws:iam::000000000000:role/ecs-fargate-https-task"
  }
}

locals {
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")
}

inputs = {
  provider_url = "https://token.actions.githubusercontent.com"
  name_prefix  = "ecs-fargate-https-"

  roles = {
    github_deployer = {
      # Scoped to this repo's main branch (covers push to main and workflow_dispatch on main).
      subjects = ["repo:${local.github_repository}:ref:refs/heads/main"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "EcrAuth"
            Effect   = "Allow"
            Action   = ["ecr:GetAuthorizationToken"]
            Resource = "*"
          },
          {
            Sid    = "EcrPushPull"
            Effect = "Allow"
            Action = [
              "ecr:BatchCheckLayerAvailability",
              "ecr:GetDownloadUrlForLayer",
              "ecr:BatchGetImage",
              "ecr:InitiateLayerUpload",
              "ecr:UploadLayerPart",
              "ecr:CompleteLayerUpload",
              "ecr:PutImage",
            ]
            Resource = dependency.registry.outputs.arn
          },
          {
            Sid    = "EcsRegisterAndDescribeTaskDef"
            Effect = "Allow"
            Action = [
              "ecs:RegisterTaskDefinition",
              "ecs:DescribeTaskDefinition",
            ]
            Resource = "*" # these actions do not support resource-level scoping
          },
          {
            Sid      = "EcsUpdateService"
            Effect   = "Allow"
            Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
            Resource = dependency.service.outputs.service_id
          },
          {
            Sid      = "PassTaskRoles"
            Effect   = "Allow"
            Action   = ["iam:PassRole"]
            Resource = [dependency.service.outputs.execution_role_arn, dependency.service.outputs.task_role_arn]
            Condition = {
              StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
            }
          },
        ]
      })
    }
  }

  tags = {
    Environment = "lab"
  }
}
