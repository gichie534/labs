# The machine channel — a Pub/Sub topic both budgets publish their status to.
#
# Read this as a FEED, not an alert. Cloud Billing publishes the current spend for each budget several times a
# day whether or not anything crossed a threshold. Nothing in this lab consumes it automatically; it is here
# because it is the only programmatic hook GCP gives you — chat notifications, or the classic "detach billing
# when the cap is hit" function, both start from this topic — and because `task show-spend` reads the latest
# message from it, which is the cheapest way to see what Google thinks the project has spent this month.
#
# Billing publishes as billing-budget-alert@system.gserviceaccount.com. The publisher grant below is the GCP
# twin of the SNS topic policy in the AWS lab: miss it and publishes are refused with nothing to tell you.
# (On an organization enforcing iam.allowedPolicyMemberDomains this grant is rejected; the project needs an
# exemption.)

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/pubsub-topic?ref=gcp-pubsub-topic-v0.1.0"
}

dependencies {
  paths = ["../apis"]
}

inputs = {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  name       = "finops-budget-updates"

  publisher_members = [
    "serviceAccount:billing-budget-alert@system.gserviceaccount.com",
  ]

  # Without a subscription the topic discards every message. Seven days of retention (the maximum) so
  # `task show-spend` always has something to read; never expires, so a quiet month does not delete it.
  pull_subscriptions = {
    "finops-budget-updates-pull" = {}
  }
}
