# The APIs every other unit calls. Everything else depends on this unit, so it applies first.
#
#   billingbudgets  — budgets (called with this project as the quota project, see root.hcl)
#   cloudbilling    — reading the project's billing link (`task verify`)
#   monitoring      — the email notification channel budgets deliver through
#   pubsub          — the budget status feed
#   bigquery        — the billing export dataset
#
# The module never disables an API on destroy, so `task down` leaves them on. That is deliberate: other
# things in the project may rely on them, and an enabled API costs nothing.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/project-services?ref=gcp-project-services-v0.1.0"
}

inputs = {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")

  activate_apis = [
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
  ]
}
