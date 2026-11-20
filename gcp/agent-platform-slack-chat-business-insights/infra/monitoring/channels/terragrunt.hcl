# Email notification channel for the observability alerts (ALERT_EMAIL in .env).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/notification-channels?ref=gcp-notification-channels-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id          = include.root.locals.project_id
  email_addresses     = [include.root.locals.alert_email]
  display_name_prefix = "business-insights"
  labels              = include.root.locals.labels
}
