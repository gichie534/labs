# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION for the gcp/agent-platform-slack-chat-business-insights lab.
#
# Owns what every unit shares: the generated google provider, the GCS remote-state backend, the lab's naming
# convention and the module sources. Each infra/ unit discovers this file via find_in_parent_folders("root.hcl")
# and never redefines state.
#
# Values come from the lab's .env (loaded by Task) or the shell. Sentinels make a missing value obvious.
# ---------------------------------------------------------------------------------------------------------------------
locals {
  project_id     = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  project_number = get_env("GCP_PROJECT_NUMBER", "REPLACE_WITH_PROJECT_NUMBER")

  # Agent Runtime, Cloud SQL, Cloud Run and the Agent Gateway all live here.
  region = get_env("GCP_REGION", "us-central1")
  # The seed data is copied from bigquery-public-data.thelook_ecommerce, which lives in the US multi-region.
  # A CREATE TABLE AS SELECT can't cross locations, so the lab's datasets must be there too.
  bq_location = "US"

  state_bucket      = get_env("TF_STATE_BUCKET", "REPLACE_WITH_STATE_BUCKET")
  github_repository = get_env("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPO")
  alert_email       = get_env("ALERT_EMAIL", "")

  # Agent Gateway is a preview feature. ENABLE_AGENT_GATEWAY=true includes the agent-gateway/egress unit
  # (task gateway:up); binding the agent to it is a deploy-time step (task gateway:bind), not Terraform.
  enable_agent_gateway = get_env("ENABLE_AGENT_GATEWAY", "false") == "true"

  # --- Naming convention. Scripts (scripts/*.sh), the deploy pipeline (app/python/deploy) and CI derive the same
  # names from GCP_PROJECT / GCP_REGION, so they never need Terraform outputs except the reasoning engine ID.
  names = {
    agent_display      = "business-insights"
    docs_bucket        = "${local.project_id}-bi-docs"
    seed_bucket        = "${local.project_id}-bi-seed"
    analytics_dataset  = "bi_analytics"
    crm_snapshot       = "bi_crm_snapshot"
    crm_instance       = "bi-crm"
    crm_database       = "crm"
    crm_reader_sa      = "bi-crm-reader"
    slack_signing      = "bi-slack-signing-secret"
    slack_bot_token    = "bi-slack-bot-token"
    slack_topic        = "bi-slack-events"
    slack_subscription = "bi-slack-events-worker"
    ingress_service    = "bi-slack-ingress"
    worker_service     = "bi-slack-worker"
    ingress_sa         = "bi-slack-ingress"
    worker_sa          = "bi-slack-worker"
    push_sa            = "bi-slack-push"
    bridge_repo        = "bi-slack-bridge"
    gateway            = "bi-agents-egress"
    deny_policy        = "bi-agent-guardrails"
    wif_pool           = "github-ci-bi"
  }

  labels = {
    lab        = "agent-platform-slack-chat-business-insights"
    managed-by = "terragrunt"
  }

  # --- Module sources. Tagged modules are pinned by ?ref=. Modules that are new or changed for this lab are read
  # from a sibling checkout of the catalog while they are being iterated on; switch each to a pinned tag once it is
  # released (see README "Module versions").
  catalog_git   = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp"
  catalog_local = "${get_repo_root()}/../infrastructure-catalog/modules/gcp"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {
      project = "${local.project_id}"
      region  = "${local.region}"
    }
  EOF
}

remote_state {
  backend = "gcs"
  config = {
    bucket   = local.state_bucket
    prefix   = "${path_relative_to_include()}/terraform.tfstate"
    project  = local.project_id
    location = local.region
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
