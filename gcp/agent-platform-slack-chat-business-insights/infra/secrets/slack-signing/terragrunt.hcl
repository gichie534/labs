# Slack app signing secret (verifies that requests to the public ingress really come from Slack). Empty
# container; `task slack:secrets` adds the value from SLACK_SIGNING_SECRET in .env.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/secret-manager?ref=gcp-secret-manager-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id = include.root.locals.project_id
  secret_id  = include.root.locals.names.slack_signing
  labels     = include.root.locals.labels
}
