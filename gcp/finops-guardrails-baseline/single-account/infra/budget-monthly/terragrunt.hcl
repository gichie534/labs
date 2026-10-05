# The limit you chose.
#
# Alerts at 50% and 80% of current spend (early warning), 100% (you are over), and 100% of Google's FORECAST
# for the month — the only forward-looking signal a budget offers. Current-spend thresholds can only ever
# report money already spent, because billing data trails usage by hours.
#
# Scoped to THIS project by project number. A GCP budget lives on the billing account, so without the filter
# it would silently measure every project the account pays for — usually the right budget for an org, rarely
# the right one for a lab.
#
# Credits: see docs/adr/0003. Discounts and free-tier usage are subtracted because they are genuinely free;
# promotional credits (the $300 Free Trial, event credits) are NOT, so the budget tracks what this project
# would cost you once the credits run out.
#
# A separate unit from the zero-spend guard for the same reason as in the AWS lab: this one changes whenever
# your intended spend changes, the other one never changes at all.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/billing-budget?ref=gcp-billing-budget-v0.1.0"
}

locals {
  monthly_limit  = tonumber(get_env("FINOPS_MONTHLY_BUDGET", "50"))
  project_number = get_env("GCP_PROJECT_NUMBER", "000000000000")
}

dependencies {
  paths = ["../apis"]
}

dependency "alert_channels" {
  config_path = "../alert-channels"

  # Let plan/validate run before alert-channels is applied (cost-free checks).
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
  display_name    = "finops-baseline-monthly"

  # In the billing account's own currency. Leaving currency_code unset avoids the one way to make this fail:
  # naming a currency the account is not billed in.
  amount          = local.monthly_limit
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
    { threshold_percent = 0.5 },
    { threshold_percent = 0.8 },
    { threshold_percent = 1.0 },
    { threshold_percent = 1.0, spend_basis = "FORECASTED_SPEND" },
  ]

  notification_channel_ids = dependency.alert_channels.outputs.ids
  pubsub_topic             = dependency.budget_topic.outputs.id

  # Keep the billing admins (on a personal account: you) as a second recipient.
  disable_default_iam_recipients = false
}
