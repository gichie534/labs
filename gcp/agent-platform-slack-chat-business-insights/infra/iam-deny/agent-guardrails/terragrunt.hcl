# IAM deny policy on the project, aimed at AI agents (every Agent Identity in the organization's trust domain)
# and at the service account the agent borrows for Cloud SQL. Deny is evaluated before allow, so these hold even
# if someone later grants either of them a broad role:
#   1. Agents may not create, change or delete agents (an agent re-deploying itself, or another one).
#   2. Agents, and bi-crm-reader, may only call READ-ONLY Google MCP tools. Defence in depth: the toolsets are
#      already the read-only ones and the database user can only SELECT — and bi-crm-reader's tokens are plain
#      bearer tokens, so this also bounds what a leaked one could do.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_local}/iam-deny-policy"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    trust_domain = "agents.global.org-000000000000.system.id.goog"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
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
  attachment_point = "cloudresourcemanager.googleapis.com/projects/${include.root.locals.project_id}"
  name             = include.root.locals.names.deny_policy
  display_name     = "Business insights - agent guardrails"

  rules = [
    {
      description       = "Agents never manage agents."
      denied_principals = ["principalSet://${dependency.agent.outputs.trust_domain}/*"]
      denied_permissions = [
        "aiplatform.googleapis.com/reasoningEngines.create",
        "aiplatform.googleapis.com/reasoningEngines.update",
        "aiplatform.googleapis.com/reasoningEngines.delete",
      ]
    },
    {
      description = "Agents and the CRM reader may only call read-only Google MCP tools."
      denied_principals = [
        "principalSet://${dependency.agent.outputs.trust_domain}/*",
        "principal://iam.googleapis.com/projects/-/serviceAccounts/${dependency.crm_reader_sa.outputs.email}",
      ]
      denied_permissions = ["mcp.googleapis.com/tools.call"]
      denial_condition = {
        title      = "Deny read-write MCP tools"
        expression = "api.getAttribute('mcp.googleapis.com/tool.isReadOnly', false) == false"
      }
    },
  ]
}
