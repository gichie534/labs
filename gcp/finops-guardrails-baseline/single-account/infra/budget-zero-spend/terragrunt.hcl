# The "I thought this project was empty" guard.
#
# A $1 budget with a 1% threshold — one cent. Its job is not to measure anything, it is to catch spend
# appearing in a project you believed was idle: a static IP nobody released, a persistent disk left behind
# by a deleted VM, a GKE cluster from a lab whose `task down` failed halfway.
#
# The credit treatment matters more here than anywhere else in the lab (docs/adr/0003). With the GCP default,
# INCLUDE_ALL_CREDITS, an account still on Free Trial credit reports $0 net spend for everything and this
# guard never fires — exactly when you most want it to. With EXCLUDE_ALL_CREDITS it fires on genuinely free
# usage too, because free-tier usage is billed as a cost with an offsetting FREE_TIER credit. Subtracting
# only free tier and discounts is the setting that means "you are consuming something that is not free".
#
# Its own unit rather than a second threshold on the monthly budget: set once, never edited, and changing
# the monthly limit can never produce a diff here.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/billing-budget?ref=gcp-billing-budget-v0.1.0"
}

locals {
  project_number = get_env("GCP_PROJECT_NUMBER", "000000000000")
}

dependencies {
  paths = ["../apis"]
}

dependency "alert_channels" {
  config_path = "../alert-channels"

  mock_outputs = {
    ids = ["projects/mock-project/notificationChannels/0"]
  }
}

dependency "budget_topic" {
  config_path = "../budget-topic"

  mock_outputs = {
    id = "projects/mock-project/topics/finops-budget-updates"
  }
}

inputs = {
  billing_account = get_env("GCP_BILLING_ACCOUNT", "000000-000000-000000")
  display_name    = "finops-baseline-zero-spend"

  # 1% of 1 unit of the account's currency. The amount is nominal; the threshold is what decides.
  amount          = 1
  calendar_period = "MONTH"

  projects = ["projects/${local.project_number}"]

  credit_types_treatment = "INCLUDE_SPECIFIED_CREDITS"
  credit_types = [
    "DISCOUNT",
    "FREE_TIER",
    "SUSTAINED_USAGE_DISCOUNT",
    "COMMITTED_USAGE_DISCOUNT",
    "COMMITTED_USAGE_DISCOUNT_DOLLAR_BASE",
    "SUBSCRIPTION_BENEFIT",
  ]

  threshold_rules = [
    { threshold_percent = 0.01 },
  ]

  notification_channel_ids = dependency.alert_channels.outputs.ids
  pubsub_topic             = dependency.budget_topic.outputs.id

  disable_default_iam_recipients = false
}
