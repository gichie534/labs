# The agent's long-lived "shell" on Agent Runtime: Agent Identity, Memory Bank and who may call it. NO code and no
# deployment_spec — `task deploy:agent` (and CI) ship code, scaling and env as revisions of this engine, so the
# agent's identity, and every IAM grant made to it, survive releases. See docs/adr/0002.
#
# Scaling (min/max instances, CPU/memory, concurrency) lives in app/python/lifecycle/release.py, and the Agent
# Gateway binding in `task gateway:bind`: the API refuses a deployment_spec on an engine that has no code yet.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  r = include.root.locals
}

terraform {
  source = "${include.root.locals.catalog_local}/agent-runtime"
}

dependencies {
  paths = ["../../project/apis"]
}

dependency "worker_sa" {
  config_path = "../../sa/slack-worker"
  mock_outputs = {
    member = "serviceAccount:mock-worker@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id   = local.r.project_id
  region       = local.r.region
  display_name = local.r.names.agent_display
  description  = "Answers business questions about TheLook customers, orders and web activity, from Slack."
  labels       = local.r.labels

  memory_bank = {
    default_ttl    = "7776000s" # 90 days
    managed_topics = ["USER_PREFERENCES", "EXPLICIT_INSTRUCTIONS"]
    custom_topics = {
      reporting_preferences = "How this person likes answers: currency and rounding, preferred comparison period, level of detail, charts vs tables."
      focus_areas           = "Product categories, brands, regions or customer segments this person regularly asks about."
    }
  }

  # Only the Slack worker may call the agent — on this engine, not project-wide.
  invoker_members = {
    slack_worker = dependency.worker_sa.outputs.member
  }

  force_destroy = true
}
