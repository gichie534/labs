# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/shared-vpc-gke lab.
#
# The directory tree under root-folder/ mirrors a GCP org hierarchy (directory = node), the same
# style as the organization-layout-terragrunt lab. Every node/unit discovers this file via
# find_in_parent_folders("root.hcl") and never redefines state.
#
# Org-wide settings are read from the lab's .env via get_env (loaded by the Taskfile's dotenv).
# Copy .env.example to .env and fill it in (`task shared-vpc:init-env`); values already exported in
# your shell take precedence. A missing .env is harmless — the placeholders below keep cost-free
# commands parseable on a clean checkout.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  # GCP organization + billing the projects are created under.
  org_id          = get_env("GCP_ORG_ID", "REPLACE_WITH_ORG_ID")
  billing_account = get_env("GCP_BILLING_ACCOUNT", "REPLACE_WITH_BILLING_ACCOUNT")

  # Region for the host subnet, its Cloud NAT, and the regional Autopilot cluster.
  region = get_env("GCP_REGION", "us-central1")

  # The two projects the lab creates (globally unique IDs).
  host_project_id    = get_env("HOST_PROJECT_ID", "REPLACE_WITH_HOST_PROJECT_ID")
  service_project_id = get_env("SERVICE_PROJECT_ID", "REPLACE_WITH_SERVICE_PROJECT_ID")

  # GCS bucket that stores this lab's Terraform state (create it with `task shared-vpc:init-state`).
  state_bucket   = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
  state_project  = get_env("TF_STATE_PROJECT", "REPLACE_WITH_STATE_PROJECT")
  state_location = get_env("TF_STATE_LOCATION", "us-central1")

  # Path to the sibling infrastructure-catalog repo, used to source modules that are not yet
  # released as git tags: gcp/host-project, gcp/service-project, gcp/shared-vpc-iam.
  # TODO: cut gcp-host-project-v0.1.0 / gcp-service-project-v0.1.0 / gcp-shared-vpc-iam-v0.1.0 and
  # switch the _envcommon templates + the shared-vpc-access unit to pinned ?ref= git sources.
  catalog_modules = "${get_repo_root()}/../infrastructure-catalog/modules"
}

# Project-less provider: this lab spans two projects, and every module takes an explicit project_id,
# so the provider carries no default project (same approach as organization-layout-terragrunt).
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {}
  EOF
}

remote_state {
  backend = "gcs"
  config = {
    bucket   = local.state_bucket
    prefix   = "${path_relative_to_include()}/terraform.tfstate"
    project  = local.state_project
    location = local.state_location
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
