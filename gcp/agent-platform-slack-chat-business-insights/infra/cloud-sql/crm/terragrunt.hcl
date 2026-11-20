# The operational CRM database (users, orders) on Cloud SQL for PostgreSQL, reached by the agent ONLY through the
# Cloud SQL remote MCP server's read-only toolset and the Data API — no connector, no network path from the agent.
#
#   - No public IP (the organization enforces constraints/sql.restrictPublicIp) and no VPC: the instance is
#     Private Service Connect-enabled but no PSC endpoint exists, so nothing can open a direct connection.
#   - data_api_access = ALLOW_DATA_API: SQL can run over Google's API (instances.executeSql), authorized by IAM
#     (cloudsql.instances.executeSql) AND by the database user's own grants.
#   - IAM database authentication: the bi-crm-reader service account is registered as an IAM database user.
#     The agent borrows that account (sa/crm-reader unit), so the Data API logs in as it — passwordless.
#     `task seed` grants it SELECT on users and orders; IAM database users start with no privileges at all.
#
# Smallest shared-core tier: the CRM is ~100k users / ~125k orders.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  # Local path while the module change (data_api_access, PSC, service account output) is unreleased.
  source = "${include.root.locals.catalog_local}/cloud-sql-postgres"
}

dependencies {
  paths = ["../../project/apis"]
}

dependency "crm_reader_sa" {
  config_path = "../../sa/crm-reader"
  mock_outputs = {
    email = "bi-crm-reader@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  name          = include.root.locals.names.crm_instance
  project_id    = include.root.locals.project_id
  region        = include.root.locals.region
  database_name = include.root.locals.names.crm_database

  tier             = "db-f1-micro"
  edition          = "ENTERPRISE"
  database_version = "POSTGRES_16"

  # Private Service Connect with no endpoint, and no public IP. A Cloud SQL instance needs some IP
  # configuration; PSC satisfies that without a VPC, peering or reserved range. The Data API and
  # `gcloud sql import` run on Google's side, so they need no endpoint. To psql in, create a PSC endpoint
  # against the psc_service_attachment_link output.
  psc_enabled      = true
  enable_public_ip = false
  ssl_mode         = "ENCRYPTED_ONLY"
  data_api_access  = "ALLOW_DATA_API"

  # Registered as CLOUD_IAM_SERVICE_ACCOUNT; its database login is the email without ".gserviceaccount.com".
  iam_service_account_emails = [dependency.crm_reader_sa.outputs.email]

  deletion_protection = false
  user_labels         = include.root.locals.labels
}
