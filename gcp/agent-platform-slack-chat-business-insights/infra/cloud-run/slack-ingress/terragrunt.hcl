# PUBLIC Cloud Run service Slack's Events API calls. Slack can't present a Google identity token, so the Cloud Run
# IAM check is off (invoker_iam_disabled) and the app authenticates every request by verifying Slack's HMAC
# signature with the signing secret. It acknowledges within Slack's 3-second budget and publishes the event to
# Pub/Sub; it holds no other permission.
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

dependency "ingress_sa" {
  config_path = "../../sa/slack-ingress"
  mock_outputs = {
    email = "mock-ingress@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "topic" {
  config_path = "../../pubsub/slack-events"
  mock_outputs = {
    id = "projects/mock-project/topics/mock-topic"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependencies {
  paths = ["../../secrets/slack-signing"]
}

inputs = {
  project_id            = local.r.project_id
  region                = local.r.region
  name                  = local.r.names.ingress_service
  service_account_email = dependency.ingress_sa.outputs.email

  ingress               = "INGRESS_TRAFFIC_ALL"
  allow_unauthenticated = true

  env = {
    MODE                        = "ingress"
    GOOGLE_CLOUD_PROJECT        = local.r.project_id
    PUBSUB_TOPIC                = dependency.topic.outputs.id
    SLACK_SIGNING_SECRET_SECRET = "projects/${local.r.project_id}/secrets/${local.r.names.slack_signing}/versions/latest"
    # Comma-separated Slack channel IDs the bot answers in. Empty = every channel it is invited to.
    SLACK_ALLOWED_CHANNELS = get_env("SLACK_ALLOWED_CHANNELS", "")
  }

  timeout       = "10s"
  concurrency   = 80
  max_instances = 3
  memory        = "256Mi"

  deletion_protection = false
  labels              = local.r.labels
}
