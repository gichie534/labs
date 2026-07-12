# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws/slack-event-debug lab.
#
# Owns the two things every unit shares: the generated aws provider and the S3 remote-state backend
# (S3-native locking, no DynamoDB). The single infra/ unit discovers this file via
# find_in_parent_folders("root.hcl") and never redefines state.
#
# PLACEHOLDERS — fill these in before running anything (see README). Set them via the lab's .env.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Region everything is created in.
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
          Lab       = "slack-event-debug"
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
