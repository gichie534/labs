# Runtime identity of the PUBLIC Slack ingress service. It may only read the Slack signing secret and publish to
# the events topic (granted on those resources) — it can't call the agent and never sees the bot token.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/service-account?ref=gcp-service-account-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id   = include.root.locals.project_id
  account_id   = include.root.locals.names.ingress_sa
  display_name = "Slack bridge - ingress (public)"
  description  = "Verifies Slack signatures and queues events. No access to the agent or the bot token."

  project_roles = [
    "roles/logging.logWriter",
  ]
}
