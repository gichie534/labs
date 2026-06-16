# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the aws/eks-vpc-cni-ip-allocation lab.
#
# Owns the two things every unit shares: the generated aws provider and the S3 + DynamoDB
# remote-state backend. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl")
# and never redefines state.
#
# PLACEHOLDERS — fill these in before running anything (see README). They are intentionally left as
# obvious sentinels (or sensible defaults) so the lab is reproducible from a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # Region everything is created in.
  region = get_env("AWS_REGION", "us-east-1")

  # S3 bucket that stores Terraform state for this lab. Must be globally unique. Terragrunt
  # auto-creates it on first run if it doesn't exist.
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
          Lab       = "eks-vpc-cni-ip-allocation"
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
