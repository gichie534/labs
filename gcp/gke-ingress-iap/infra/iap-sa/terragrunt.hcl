# The service-account identity used for the automated POSITIVE IAP connectivity test.
#
# With the Google-managed OAuth client (the only option since the IAP OAuth Admin APIs were shut
# down in 2026), a human can't mint a programmatic IAP token — but a SERVICE ACCOUNT can, using a
# self-signed JWT whose audience is the resource URL. This unit creates that service account and lets
# the operator impersonate it (Token Creator) so they can sign the JWT without exporting a key.
#
# The matching "may pass through IAP" grant for this SA lives in the iap-access unit.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  iap_member = include.root.locals.iap_member
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/service-account?ref=gcp-service-account-v0.1.0"
}

inputs = {
  project_id   = local.project_id
  account_id   = "iap-tester"
  display_name = "IAP connectivity probe (gke-ingress-iap)"
  description  = "Programmatic identity for the lab's positive IAP connectivity test."

  # Let the operator impersonate this SA to mint a signed JWT for the test (no exported key).
  token_creators = {
    operator = local.iap_member
  }
}
