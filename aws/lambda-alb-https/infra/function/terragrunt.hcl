# The Go "hello world" Lambda — the workload. It's a zip-packaged function on the provided.al2023
# runtime (a compiled `bootstrap` binary), invoked directly by the ALB (no VPC attachment: the ALB
# reaches the function through the Lambda service, not over the network).
#
# ignore_code_changes = true: Terraform creates the function from the initial build and then stops
# managing the code, so the GitHub Actions pipeline (and `task deploy`) can ship new versions with
# `aws lambda update-function-code` without Terraform reverting them — the Lambda analogue of the
# ECS lab's ignore_task_definition_changes. See the ADR.
#
# filename must be an ABSOLUTE path because Terraform hashes it from the terragrunt cache dir, not
# the lab dir; get_terragrunt_dir() resolves it. Build the zip first (`task package`, wired as a dep
# of validate/plan/up), or plan/apply will fail to find it.
#
# Sourced from the modules repo by pinned tag (lambda v0.2.0 adds ignore_code_changes).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/lambda?ref=aws-lambda-v0.2.0"
}

inputs = {
  name     = "lambda-alb-https"
  filename = "${get_terragrunt_dir()}/../../app/go/build/function.zip"

  # Go on the Amazon Linux 2023 custom runtime: the zip contains a `bootstrap` executable.
  handler      = "bootstrap"
  runtime      = "provided.al2023"
  architecture = "x86_64"

  memory_size = 128
  timeout     = 10

  # CI owns rolling code deployments; Terraform only creates the function and manages its config.
  ignore_code_changes = true

  tags = {
    Environment = "lab"
  }
}
