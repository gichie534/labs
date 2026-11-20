# PREVIEW. Agent Gateway (Agent-to-Anywhere) for the project's agents, plus the Agent Registry entries it allows.
# Excluded unless ENABLE_AGENT_GATEWAY=true; the agent only routes through it after `task gateway:bind`, which sets
# the binding on the agent with the deploy tooling (the engine's deployment_spec isn't Terraform's). See docs/adr/0006.
#
# The gateway is default-deny and matches hostnames exactly, so every host the agent's SDKs resolve to is
# registered: Agent Platform (regional + global model endpoint), the platform's own logging/tracing/metrics, GCS
# for the glossary, IAM Credentials (the agent mints bi-crm-reader tokens for Cloud SQL), and the two MCP servers —
# each in its standard and mTLS form (Agent Identity uses mTLS).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

exclude {
  if      = !include.root.locals.enable_agent_gateway
  actions = ["all"]
  no_run  = true
}

locals {
  r = include.root.locals

  google_hosts = {
    "agent-platform-regional" = "${include.root.locals.region}-aiplatform"
    "agent-platform-global"   = "aiplatform"
    "logging"                 = "logging"
    "telemetry"               = "telemetry"
    "cloudtrace"              = "cloudtrace"
    "monitoring"              = "monitoring"
    "secretmanager"           = "secretmanager"
    "resourcemanager"         = "cloudresourcemanager"
    "iamcredentials"          = "iamcredentials"
    "storage"                 = "storage"
  }

  endpoints = merge(
    {
      for k, h in local.google_hosts : "bi-${k}" => { url = "https://${h}.googleapis.com" }
    },
    {
      for k, h in local.google_hosts : "bi-${k}-mtls" => { url = "https://${h}.mtls.googleapis.com" }
    },
    {
      "bi-agent-registry" = { url = "https://agentregistry.googleapis.com" }
    },
  )
}

terraform {
  source = "${include.root.locals.catalog_local}/agent-gateway"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    project_principal_set = "principalSet://agents.global.org-000000000000.system.id.goog/attribute.platformContainer/aiplatform/projects/000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id = local.r.project_id
  region     = local.r.region
  name       = local.r.names.gateway
  labels     = local.r.labels

  egress_principals = [dependency.agent.outputs.project_principal_set]

  endpoints = local.endpoints

  mcp_servers = {
    "bi-bigquery-mcp"         = { url = "https://bigquery.googleapis.com/mcp" }
    "bi-bigquery-mcp-mtls"    = { url = "https://bigquery.mtls.googleapis.com/mcp" }
    "bi-cloudsql-mcp-ro"      = { url = "https://sqladmin.googleapis.com/mcp/readonly" }
    "bi-cloudsql-mcp-ro-mtls" = { url = "https://sqladmin.mtls.googleapis.com/mcp/readonly" }
  }

  # Audit-only until the logs show no unexpected denials; then set AGENT_GATEWAY_ENFORCE=true.
  dry_run = get_env("AGENT_GATEWAY_ENFORCE", "false") != "true"
}
