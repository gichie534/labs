# The identity the agent BORROWS for Cloud SQL. Cloud SQL IAM database authentication accepts users and service
# accounts but not Agent Identity principals, so the agent mints short-lived tokens for this account (it holds
# roles/iam.serviceAccountTokenCreator here, granted in iam/agent) and calls the Cloud SQL MCP server with
# them. Cloud SQL then logs in as this account's IAM database user — no password anywhere.
#
# What the account can do is deliberately tiny, because its tokens are plain bearer tokens (not bound to the
# agent runtime's mTLS certificate like the agent's own):
#   - project: run SQL through the Data API and log in (cloudsql.instanceUser), call MCP tools, use project quota;
#   - database: SELECT on two tables (data/crm/grants.sql.tmpl, applied by `task seed`);
#   - deny policy: no read-write MCP tools (iam-deny/agent-guardrails).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  # Optional: your own identity (e.g. user:you@example.com), so `task dev` / `task eval` can borrow the account
  # locally the same way the agent does on Agent Runtime. Owner alone does not include getAccessToken.
  developer = get_env("DEVELOPER_MEMBER", "")
}

terraform {
  source = "${include.root.locals.catalog_git}/service-account?ref=gcp-service-account-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id   = include.root.locals.project_id
  account_id   = include.root.locals.names.crm_reader_sa
  display_name = "Business insights - CRM reader (borrowed by the agent)"
  description  = "Cloud SQL IAM database user for the business-insights agent. Read-only on crm.users and crm.orders."

  project_roles = [
    "roles/cloudsql.instanceUser",
    "roles/mcp.toolUser",
    "roles/serviceusage.serviceUsageConsumer",
  ]

  token_creators = local.developer == "" ? {} : { developer = local.developer }
}
