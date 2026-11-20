# The identity Pub/Sub signs push requests as. It has exactly one permission: roles/run.invoker on the worker
# service (granted in the cloud-run/slack-worker unit). That is what keeps the worker private.
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
  account_id   = include.root.locals.names.push_sa
  display_name = "Slack bridge - Pub/Sub push invoker"
  description  = "Identity in the OIDC token Pub/Sub attaches when pushing Slack events to the worker."
}
