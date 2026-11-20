# Every API the lab touches, enabled once up front. All other units depend on this one so a fresh project
# doesn't fail half-way with "API not enabled".
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/project-services?ref=gcp-project-services-v0.1.0"
}

inputs = {
  project_id = include.root.locals.project_id

  activate_apis = [
    # Agent Platform: Agent Runtime, Sessions, Memory Bank, Gemini, Evaluation.
    "aiplatform.googleapis.com",
    # Agent Registry (lists the deployed agent and, with the gateway, its approved destinations).
    "agentregistry.googleapis.com",
    # Data sources. Enabling BigQuery and Cloud SQL Admin also enables their remote MCP servers.
    "bigquery.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    # Guardrails.
    "modelarmor.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    # Observability (agent traces go to the Telemetry API, then Cloud Trace).
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "telemetry.googleapis.com",
    # Slack bridge.
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "artifactregistry.googleapis.com",
    # Agent Gateway (preview) and its IAP authorization.
    "networkservices.googleapis.com",
    "networksecurity.googleapis.com",
    "iap.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}
