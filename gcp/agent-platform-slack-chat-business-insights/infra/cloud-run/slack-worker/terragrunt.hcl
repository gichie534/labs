# PRIVATE Cloud Run service that does the slow part: receives a Slack event from Pub/Sub push, maps the Slack
# thread to an Agent Platform session, calls the agent (streamQuery) and replies in the thread.
#
# Only the Pub/Sub push identity may invoke it (IAM-enforced). Terraform owns its config; the image is deployed by
# `task deploy:bridge` / CI and ignored here. Secrets are read at runtime, not injected as env.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  r = include.root.locals
}

terraform {
  source = "${include.root.locals.catalog_local}/cloud-run-service"
}

dependency "worker_sa" {
  config_path = "../../sa/slack-worker"
  mock_outputs = {
    email = "mock-worker@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "push_sa" {
  config_path = "../../sa/slack-push"
  mock_outputs = {
    member = "serviceAccount:mock-push@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "agent" {
  config_path = "../../agent-runtime/business-insights"
  mock_outputs = {
    resource_name = "projects/mock-project/locations/us-central1/reasoningEngines/0000000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependencies {
  paths = ["../../secrets/slack-bot-token"]
}

inputs = {
  project_id            = local.r.project_id
  region                = local.r.region
  name                  = local.r.names.worker_service
  service_account_email = dependency.worker_sa.outputs.email

  ingress = "INGRESS_TRAFFIC_ALL"

  invoker_members = {
    pubsub_push = dependency.push_sa.outputs.member
  }

  env = {
    MODE                   = "worker"
    GOOGLE_CLOUD_PROJECT   = local.r.project_id
    AGENT_RESOURCE_NAME    = dependency.agent.outputs.resource_name
    AGENT_LOCATION         = local.r.region
    SLACK_BOT_TOKEN_SECRET = "projects/${local.r.project_id}/secrets/${local.r.names.slack_bot_token}/versions/latest"
  }

  # An agent turn with several tool calls can take a minute or more. Pub/Sub's ack deadline is set to match.
  timeout       = "600s"
  concurrency   = 10
  max_instances = 3
  memory        = "512Mi"

  deletion_protection = false
  labels              = local.r.labels
}
