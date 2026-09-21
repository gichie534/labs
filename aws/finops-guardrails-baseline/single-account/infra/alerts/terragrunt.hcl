# The notification backbone — everything else in this lab plugs into it.
#
# One SNS topic that AWS Budgets and Cost Anomaly Detection are both allowed to publish to, with the
# lab's email address subscribed. This unit comes first for a reason: a guardrail nobody hears about is
# not a guardrail, and the resource-policy grant below is the single most common reason a budget or
# anomaly alert silently never arrives. Both services publish as their own service principal, so an IAM
# policy on your side cannot substitute for it.
#
# The email subscription applies immediately but sits at PendingConfirmation until you click the link
# AWS sends. `task verify` checks that explicitly rather than assuming a successful apply means
# delivery works.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/sns-topic?ref=aws-sns-topic-v0.1.0"
}

locals {
  alert_email = get_env("FINOPS_ALERT_EMAIL", "")
}

inputs = {
  name         = "finops-baseline-alerts"
  display_name = "FinOps alerts"

  allowed_service_principals = [
    "budgets.amazonaws.com",
    "costalerts.amazonaws.com",
  ]

  # Empty until FINOPS_ALERT_EMAIL is set, which keeps cost-free checks working on a clean checkout.
  email_subscribers = local.alert_email == "" ? [] : [local.alert_email]

  tags = {
    Environment = "lab"
  }
}
