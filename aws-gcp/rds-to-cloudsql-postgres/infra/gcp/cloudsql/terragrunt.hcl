# The target Cloud SQL for PostgreSQL instance. PRIVATE IP only — the migration runs from the
# migration host inside this VPC, so no public endpoint is needed (the production shape, and what the
# follow-up IAM-auth lab keeps). The built-in `postgres` user gets a password (admin_password)
# because this lab migrates PASSWORD-auth -> PASSWORD-auth; the follow-up lab converts the app roles
# to IAM database authentication.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/cloud-sql-postgres?ref=gcp-cloud-sql-postgres-vX.Y.Z"

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/gcp/cloud-sql-postgres"
}

locals {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")
}

dependency "gcp_network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link = "projects/mock/global/networks/rds2cloudsql"
  }
  # apply/destroy included so run --all can parse inputs when the dependency's outputs aren't ready
  # yet or are already gone (teardown re-run); mocks are transient and never affect real resources.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name          = "rds2cloudsql-tgt"
  project_id    = local.project_id
  region        = local.region
  network       = dependency.gcp_network.outputs.network_self_link
  database_name = "app"

  # Password auth for the admin user (this lab's scope). Private IP only (default) — reached from the
  # migration host inside the VPC, so no public endpoint or authorized networks are needed.
  admin_password = get_env("CLOUDSQL_ADMIN_PASSWORD", "REPLACE_WITH_CLOUDSQL_ADMIN_PASSWORD")

  deletion_protection = false
}
