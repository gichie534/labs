# Queue between the public ingress and the private worker. Slack wants an HTTP 200 within 3 seconds; an agent
# turn takes much longer. The ingress publishes and returns; Pub/Sub pushes to the worker with an OIDC token for
# the push identity, retrying on failure.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  r = include.root.locals
}

terraform {
  # Local path while the module change (push_subscriptions) is unreleased.
  source = "${include.root.locals.catalog_local}/pubsub-topic"
}

dependency "ingress_sa" {
  config_path = "../../sa/slack-ingress"
  mock_outputs = {
    member = "serviceAccount:mock-ingress@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "push_sa" {
  config_path = "../../sa/slack-push"
  mock_outputs = {
    email = "mock-push@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependency "worker" {
  config_path = "../../cloud-run/slack-worker"
  mock_outputs = {
    uri = "https://mock-worker-abc123-uc.a.run.app"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  project_id = local.r.project_id
  name       = local.r.names.slack_topic
  labels     = local.r.labels

  publisher_members = [dependency.ingress_sa.outputs.member]

  push_subscriptions = {
    (local.r.names.slack_subscription) = {
      push_endpoint              = "${dependency.worker.outputs.uri}/pubsub/push"
      oidc_service_account_email = dependency.push_sa.outputs.email
      audience                   = dependency.worker.outputs.uri
      # Matches the worker's request timeout: a slow agent turn must not trigger a duplicate delivery.
      ack_deadline_seconds  = 600
      retry_minimum_backoff = "30s"
      retry_maximum_backoff = "600s"
      # Slack events are only useful for a few minutes.
      message_retention_duration = "1800s"
    }
  }
}
