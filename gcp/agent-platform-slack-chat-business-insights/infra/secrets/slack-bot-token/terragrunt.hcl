# Slack bot token (xoxb-...) the worker uses to post replies. Empty container; `task slack:secrets` adds the
# value from SLACK_BOT_TOKEN in .env.
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
  secret_id  = include.root.locals.names.slack_bot_token
  labels     = include.root.locals.labels
}
