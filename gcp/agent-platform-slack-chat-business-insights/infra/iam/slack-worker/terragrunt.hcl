# The worker's resource-scoped grants: read the Slack bot token. (Calling the agent is granted on the reasoning
# engine itself, in the agent-runtime/business-insights unit.)
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_local}/principal-iam"
}

dependency "worker_sa" {
  config_path = "../../sa/slack-worker"
  mock_outputs = {
    member = "serviceAccount:mock-worker@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependencies {
  paths = ["../../secrets/slack-bot-token"]
}

inputs = {
  project_id = include.root.locals.project_id
  member     = dependency.worker_sa.outputs.member

  secret_roles = {
    bot_token = { secret_id = include.root.locals.names.slack_bot_token }
  }
}
