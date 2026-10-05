# The human channel — where a crossed threshold actually lands.
#
# A Cloud Monitoring email channel, which budgets reference by resource name. This is the GCP stand-in for the
# AWS lab's SNS email subscription, with one important difference: there is no confirmation link. The channel
# is live as soon as it exists. That removes the AWS lab's most common silent failure, and replaces it with a
# quieter one — nothing checks the address is right. `task verify` prints it back so you can.
#
# Budgets ALSO email the billing account's admins by default (default IAM recipients stay on in this lab), so
# on a personal account you may get two copies. That is intentional redundancy, not a bug.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/notification-channels?ref=gcp-notification-channels-v0.1.0"
}

dependencies {
  paths = ["../apis"]
}

inputs = {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  # A sentinel rather than an empty list keeps cost-free checks working on a clean checkout; `task up` refuses
  # to run while any REPLACE_WITH value is still in place.
  email_addresses = [get_env("FINOPS_ALERT_EMAIL", "REPLACE_WITH_YOUR_EMAIL@example.com")]

  display_name_prefix = "FinOps baseline"
  description         = "Budget threshold alerts from the finops-guardrails-baseline lab."
}
