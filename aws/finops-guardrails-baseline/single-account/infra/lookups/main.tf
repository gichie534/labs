# Lab-local lookups unit. Creates NO resources; it only reads existing account state and exposes it as
# outputs for the anomaly-detection unit.
#
# It exists because of a quota that shapes the whole design: AWS allows exactly ONE AWS-managed monitor
# for AWS services per account, and it creates that monitor for you when Cost Anomaly Detection is
# enabled. So the lab cannot create its own — a second one fails with:
#
#   ValidationException: Limit exceeded on dimensional spend monitor creation
#
# The right move is to adopt the monitor AWS already made and attach our own subscriptions to it: the
# monitor is account infrastructure AWS owns, the alerting policy is ours. That needs the monitor's ARN,
# and the AWS provider has no data source for anomaly monitors — hence the shell-out below.
#
# This is lab-specific glue, not reusable infrastructure, so it is sourced from a local path.

data "aws_caller_identity" "current" {}

# Find the account's AWS-managed "AWS services" monitor, if it has one. Emits an empty string rather than
# failing when there is none, so a brand-new account (Cost Anomaly Detection never enabled) still plans —
# the anomaly-detection unit then creates the monitor itself.
data "external" "aws_services_monitor" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    arn="$(aws ce get-anomaly-monitors --region us-east-1 \
      --query "AnomalyMonitors[?MonitorType=='DIMENSIONAL' && MonitorDimension=='SERVICE'].MonitorArn | [0]" \
      --output text 2>/dev/null || true)"
    if [ "$arn" = "None" ] || [ -z "$arn" ]; then
      arn=""
    fi
    printf '{"arn":"%s"}' "$arn"
  EOT
  ]
}

output "account_id" {
  description = "The account this lab is running against."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_services_monitor_arn" {
  description = "ARN of the account's existing AWS-managed 'AWS services' anomaly monitor, or an empty string if it has none."
  value       = data.external.aws_services_monitor.result.arn
}
