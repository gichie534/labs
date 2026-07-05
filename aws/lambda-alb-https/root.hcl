# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws/lambda-alb-https lab.
#
# Owns the two things every unit shares: the generated aws provider and the S3 remote-state backend
# (S3-native locking, no DynamoDB). Each infra/ unit discovers this file via
# find_in_parent_folders("root.hcl") and never redefines state.
#
# Lab inputs (region, state bucket, domain, parent zone, GitHub repo) come from the lab's .env via
# Task's dotenv, and units read them with get_env(...). See .env.example / README.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Region everything is created in. The ACM certificate is issued here too (it fronts an ALB, which
  # requires the cert in the ALB's own region — this is NOT CloudFront, so us-east-1 is not special).
  region = get_env("AWS_REGION", "us-east-1")

  # S3 bucket that stores Terraform state for this lab. Must be globally unique.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"

      default_tags {
        tags = {
          Lab       = "lambda-alb-https"
          ManagedBy = "terragrunt"
        }
      }
    }
  EOF
}

remote_state {
  backend = "s3"
  config = {
    bucket  = local.state_bucket
    key     = "${path_relative_to_include()}/terraform.tfstate"
    region  = local.region
    encrypt = true

    # S3 native state locking (Terraform >= 1.10) — no DynamoDB lock table needed.
    use_lockfile = true
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
