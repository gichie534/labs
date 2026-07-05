# Keyless CI identity: an IAM OIDC provider for GitHub Actions plus a single deploy role the
# workflow assumes directly (no long-lived access keys). The role is scoped to this repo's `main`
# ref and granted only what shipping new function code needs:
#   - lambda:UpdateFunctionCode on THIS function (push a new zip)
#   - lambda:GetFunction / GetFunctionConfiguration on THIS function (wait for the update to settle)
#
# It deliberately gets nothing for DNS, ACM, the ALB, or infra — those are stood up once by the
# operator via the Taskfile. See the ADR.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/oidc-federation?ref=aws-oidc-federation-v0.1.0"
}

dependency "function" {
  config_path = "../function"

  mock_outputs = {
    function_arn = "arn:aws:lambda:us-east-1:000000000000:function:lambda-alb-https"
  }
}

locals {
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")
}

inputs = {
  provider_url = "https://token.actions.githubusercontent.com"
  name_prefix  = "lambda-alb-https-"

  roles = {
    github_deployer = {
      # Scoped to this repo's main branch (covers push to main and workflow_dispatch on main).
      subjects = ["repo:${local.github_repository}:ref:refs/heads/main"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "UpdateThisFunctionCode"
            Effect = "Allow"
            Action = [
              "lambda:UpdateFunctionCode",
              "lambda:GetFunction",
              "lambda:GetFunctionConfiguration",
            ]
            Resource = dependency.function.outputs.function_arn
          },
        ]
      })
    }
  }

  tags = {
    Environment = "lab"
  }
}
