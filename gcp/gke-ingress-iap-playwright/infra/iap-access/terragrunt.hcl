# Grants "may pass through IAP" (roles/iap.httpsResourceAccessor) to the two principals the lab
# tests with, at the project-wide IAP web scope (GKE Ingress names its backend service dynamically,
# so project scope is the pragmatic choice):
#
#   - the operator (IAP_MEMBER): interactive browser sign-in / manual check.
#   - the Playwright test service account (from iap-sa): the identity the signed JWT authenticates
#     as, so the positive Playwright test is admitted through IAP.
#
# Enabling IAP on the backend itself is done in the Helm chart (BackendConfig iap.enabled: true).
# This unit only says WHO gets through. (WHO may SIGN a JWT as the test SA — the operator and CI —
# is a separate Token Creator grant in the iap-sa unit.)

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  iap_member = include.root.locals.iap_member
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/iap-access?ref=gcp-iap-access-v0.1.0"
}

dependency "iap_sa" {
  config_path = "../iap-sa"

  mock_outputs = {
    member = "serviceAccount:playwright-iap-tester@mock.iam.gserviceaccount.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id = local.project_id

  members = {
    operator = local.iap_member
    probe_sa = dependency.iap_sa.outputs.member
  }
}
