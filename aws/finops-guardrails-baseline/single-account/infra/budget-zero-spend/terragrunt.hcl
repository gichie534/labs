# The "I thought this account was empty" guard.
#
# An absolute threshold of one cent. Its job is not to measure anything — it is to catch spend appearing in
# an account you believed was idle: a forgotten NAT gateway, a leftover load balancer, an EBS volume nobody
# detached, a resource left behind by a lab that failed halfway through `task down`.
#
# Deliberately its own unit rather than a second entry alongside the monthly limit. The two have nothing in
# common operationally: the monthly limit gets edited whenever your intended spend changes, while this one
# is set once and never touched. Keeping them separate means changing one cannot produce a diff on the
# other.
#
# The limit_amount below is nominal. AWS requires one, but with an ABSOLUTE_VALUE threshold of 0.01 it is
# the threshold that decides when this fires, not the limit.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/budget?ref=aws-budget-v0.1.0"
}

dependency "alerts" {
  config_path = "../alerts"

  mock_outputs = {
    arn = "arn:aws:sns:us-east-1:000000000000:finops-baseline-alerts"
  }
}

inputs = {
  name         = "finops-baseline-zero-spend"
  limit_amount = "1"
  time_unit    = "MONTHLY"

  subscriber_sns_topic_arns = [dependency.alerts.outputs.arn]

  notifications = [
    { threshold = 0.01, threshold_type = "ABSOLUTE_VALUE", notification_type = "ACTUAL" },
  ]

  tags = {
    Environment = "lab"
  }
}
