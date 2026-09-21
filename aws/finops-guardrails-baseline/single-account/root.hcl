# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws/finops-guardrails-baseline/single-account lab.
#
# Owns the two things every unit shares: the generated aws provider and the S3 remote-state backend
# (S3-native locking, no DynamoDB). Each infra/ unit discovers this file via
# find_in_parent_folders("root.hcl") and never redefines state.
#
# WHY THE REGION IS NOT AN INPUT: every service this lab touches is global. Cost Explorer (cost
# categories, anomaly detection) and the Data Exports control plane are reachable only through their
# us-east-1 endpoints, and AWS Budgets is regionless. Exposing a region knob here would offer a
# setting whose only effect is to break the lab, so the whole thing is pinned to us-east-1 — including
# the state bucket and the export bucket. See docs/adr/0002.
#
# PLACEHOLDERS — fill these in before running anything (see README). Set them via the lab's .env.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Billing and cost management APIs live here. Not parameterised on purpose (see above).
  region = "us-east-1"

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
          Lab       = "finops-guardrails-baseline-single-account"
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
