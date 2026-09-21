# The signal a budget structurally cannot produce.
#
# A budget compares spend to a number you picked. Anomaly detection compares it to a model of your own
# history, so it catches the shape of problem a limit misses entirely: one service quietly costing ten
# times what it did last week while the monthly total still sits comfortably under budget. It is free,
# which makes it the cheapest useful signal in FinOps.
#
# WHY THIS UNIT ADOPTS A MONITOR INSTEAD OF CREATING ONE
#
# AWS allows exactly ONE AWS-managed monitor for AWS services per account, and it creates that monitor for
# you when Cost Anomaly Detection is enabled. Creating a second fails outright:
#
#   ValidationException: Limit exceeded on dimensional spend monitor creation
#
# So the division of ownership is not a choice: the monitor is account infrastructure AWS owns, and what
# this lab owns is the alerting policy on top of it — who gets told, at what threshold, how often. The
# lookups unit finds that monitor's ARN; we attach subscriptions to it and leave it alone otherwise
# (`task down` therefore does not delete it, correctly).
#
# On a brand-new account that has never had Cost Anomaly Detection enabled there is no monitor to adopt,
# and the lookups unit returns an empty string. In that case this unit creates the monitor itself — the one
# situation where creating a DIMENSIONAL monitor succeeds.
#
# Two subscriptions, because AWS ties the delivery channel to the frequency:
#   immediate — SNS only. Machine-readable, arrives when the anomaly is detected.
#   daily     — email only. A digest for a human, at a higher bar.
#
# Thresholds are combined with OR on purpose. An absolute floor alone sleeps through a steady 30% overspend
# on a large bill; a percentage alone fires on a $2 service that tripled. Anomalies below the threshold are
# still recorded and visible in the console — the threshold controls notification, not detection.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/cost-anomaly-detection?ref=aws-cost-anomaly-detection-v0.2.0"
}

# Only env-derived values live here. Terragrunt evaluates `locals` BEFORE it resolves `dependency`
# blocks, so anything derived from dependency.lookups has to be computed inline in `inputs` below.
locals {
  alert_email        = get_env("FINOPS_ALERT_EMAIL", "")
  absolute_threshold = tonumber(get_env("FINOPS_ANOMALY_ABSOLUTE_USD", "10"))
  percentage         = tonumber(get_env("FINOPS_ANOMALY_PERCENTAGE", "50"))
}

dependency "lookups" {
  config_path = "../lookups"

  # Let plan/validate run before lookups is applied (cost-free checks). Empty means "no managed monitor
  # found", i.e. the branch that creates one — the safe assumption for a mock.
  mock_outputs = {
    aws_services_monitor_arn = ""
  }
}

dependency "alerts" {
  config_path = "../alerts"

  mock_outputs = {
    arn = "arn:aws:sns:us-east-1:000000000000:finops-baseline-alerts"
  }
}

inputs = {
  # Nothing to create in the normal case: AWS already owns the monitor. Only a fresh account that has
  # never enabled Cost Anomaly Detection (empty ARN from lookups) gets one created here.
  monitors = dependency.lookups.outputs.aws_services_monitor_arn != "" ? {} : {
    "finops-baseline-services" = {
      monitor_type      = "DIMENSIONAL"
      monitor_dimension = "SERVICE"
    }
  }

  # `compact()` handles both branches with one expression: an adopted ARN becomes a one-element list, and
  # an empty ARN becomes an empty list — which the module reads as "every monitor I manage", i.e. the one
  # created just above. No second conditional needed.
  subscriptions = merge(
    {
      "finops-baseline-immediate" = {
        frequency      = "IMMEDIATE"
        monitor_arns   = compact([dependency.lookups.outputs.aws_services_monitor_arn])
        sns_topic_arns = [dependency.alerts.outputs.arn]

        absolute_impact_threshold   = local.absolute_threshold
        percentage_impact_threshold = local.percentage
        threshold_combinator        = "OR"
      }
    },
    # A DAILY summary is email-only, so it can exist only once an address is configured. Skipping it keeps
    # cost-free checks working on a clean checkout instead of failing validation.
    local.alert_email == "" ? {} : {
      "finops-baseline-daily-summary" = {
        frequency         = "DAILY"
        monitor_arns      = compact([dependency.lookups.outputs.aws_services_monitor_arn])
        email_subscribers = [local.alert_email]

        # A higher bar than the immediate channel: a digest is for reading, not reacting.
        absolute_impact_threshold = local.absolute_threshold * 2
      }
    },
  )

  tags = {
    Environment = "lab"
  }
}
