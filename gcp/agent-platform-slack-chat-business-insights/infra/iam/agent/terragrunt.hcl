# Everything THIS agent may touch, granted to its own Agent Identity principal (not a service account):
#
#   BigQuery   — run query jobs in the project + read ONE dataset (bi_analytics). bi_crm_snapshot stays denied.
#   MCP        — mcp.tools.call, required for any Google remote MCP server on top of the service permissions.
#   GCS        — read the business docs bucket. The seed bucket stays denied.
#   Cloud SQL  — NOTHING directly. The agent may impersonate bi-crm-reader (token creator on that one account),
#                and that account is the Cloud SQL IAM database user. Impersonation widens the agent's reach to
#                what bi-crm-reader can do, which is why it is listed here with the rest.
#
# Default Agent Identity roles (agentDefaultAccess, agentContextEditor) already cover model calls, sessions and
# memories. Baseline project roles are in iam/all-agents.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  r = include.root.locals
}

terraform {
  source = "${include.root.locals.catalog_local}/principal-iam"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    principal = "principal://agents.global.org-000000000000.system.id.goog/resources/aiplatform/projects/000000000000/locations/us-central1/reasoningEngines/0000000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "crm_reader_sa" {
  config_path = "../../sa/crm-reader"
  mock_outputs = {
    name = "projects/mock-project/serviceAccounts/bi-crm-reader@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependencies {
  paths = ["../../bigquery/analytics", "../../buckets/docs"]
}

inputs = {
  project_id = local.r.project_id
  member     = dependency.agent.outputs.principal

  project_roles = [
    "roles/bigquery.jobUser",
    "roles/mcp.toolUser",
  ]

  bigquery_dataset_roles = {
    analytics = { dataset_id = local.r.names.analytics_dataset, role = "roles/bigquery.dataViewer" }
  }

  bucket_roles = {
    docs = { bucket = local.r.names.docs_bucket, role = "roles/storage.objectViewer" }
  }

  service_account_roles = {
    crm_reader = { service_account = dependency.crm_reader_sa.outputs.name }
  }
}
