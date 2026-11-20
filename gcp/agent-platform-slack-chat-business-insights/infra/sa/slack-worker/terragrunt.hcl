# Runtime identity of the PRIVATE Slack worker service: the only principal allowed to call the agent (granted on
# the reasoning engine itself in the agent-runtime/business-insights unit) and to read the Slack bot token.
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
  account_id   = include.root.locals.names.worker_sa
  display_name = "Slack bridge - worker (private)"
  description  = "Calls the business-insights agent and replies in Slack."

  project_roles = [
    "roles/logging.logWriter",
  ]
}
