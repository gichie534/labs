# The limit you chose.
#
# Alerts at 50% and 80% of actual spend (early warning), 100% of actual (you are over), and 100% of AWS's
# FORECAST for the month. The forecast is the only forward-looking signal budgets offer; the actual
# thresholds can only ever tell you about money already spent, because AWS refreshes billing data at most a
# few times a day.
#
# A separate unit from the zero-spend guard next door, because they are separate decisions: this one
# changes whenever your intended spend changes, the other one never changes at all.
#
# Notifies the SNS topic rather than an email address directly, so there is one channel to change and one
# place where fan-out (email now, chat later) is configured.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/budget?ref=aws-budget-v0.1.0"
}

locals {
  monthly_limit = get_env("FINOPS_MONTHLY_BUDGET_USD", "50")
}

dependency "alerts" {
  config_path = "../alerts"

  # Let plan/validate run before alerts is applied (cost-free checks).
  mock_outputs = {
    arn = "arn:aws:sns:us-east-1:000000000000:finops-baseline-alerts"
  }
}

inputs = {
  name         = "finops-baseline-monthly"
  limit_amount = local.monthly_limit
  time_unit    = "MONTHLY"

  subscriber_sns_topic_arns = [dependency.alerts.outputs.arn]

  notifications = [
    { threshold = 50, notification_type = "ACTUAL" },
    { threshold = 80, notification_type = "ACTUAL" },
    { threshold = 100, notification_type = "ACTUAL" },
    { threshold = 100, notification_type = "FORECASTED" },
  ]

  tags = {
    Environment = "lab"
  }
}
