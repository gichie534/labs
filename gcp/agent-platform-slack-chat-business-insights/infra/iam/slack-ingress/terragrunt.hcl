# The ingress service's resource-scoped grants: read the Slack signing secret. (Publishing to the topic is granted
# on the topic in the pubsub/slack-events unit.)
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_local}/principal-iam"
}

dependency "ingress_sa" {
  config_path = "../../sa/slack-ingress"
  mock_outputs = {
    member = "serviceAccount:mock-ingress@mock-project.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

dependencies {
  paths = ["../../secrets/slack-signing"]
}

inputs = {
  project_id = include.root.locals.project_id
  member     = dependency.ingress_sa.outputs.member

  secret_roles = {
    signing_secret = { secret_id = include.root.locals.names.slack_signing }
  }
}
