# The service-account identity Playwright uses for the automated POSITIVE IAP test.
#
# With the Google-managed OAuth client (the only option since the IAP OAuth Admin APIs were shut
# down in 2026), neither a human nor a bare WIF federated principal can mint a programmatic IAP
# token — but a SERVICE ACCOUNT can, using a self-signed JWT whose audience is the resource URL.
# Playwright injects that JWT as an `Authorization: Bearer` header on every request, so IAP admits
# the browser traffic. This unit creates that service account and grants Token Creator to the two
# callers that need to sign a JWT as it, WITHOUT exporting a key:
#
#   - the operator (IAP_MEMBER): signs the JWT locally for `task gke-iap-pw:test-e2e`.
#   - the CI WIF principalSet:   signs the JWT in GitHub Actions for the Playwright job.
#
# This CI grant is the deliberate departure from the reference gcp/gke-ingress-iap lab (where CI ran
# only the credential-free negative test). Letting CI run the POSITIVE test is the whole point of
# this lab, and it widens CI's blast radius to mint IAP tokens as this SA. See docs/adr/0001.
#
# The matching "may pass through IAP" grant for this SA lives in the iap-access unit.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id        = include.root.locals.project_id
  project_number    = include.root.locals.project_number
  github_repository = include.root.locals.github_repository
  wif_pool_id       = include.root.locals.wif_pool_id
  iap_member        = include.root.locals.iap_member

  # The GitHub Actions federated identity for this repo (direct WIF principalSet). Must match the
  # pool created by the deployer-wif unit; the pool id is shared via root.hcl so they cannot drift.
  ci_principal = "principalSet://iam.googleapis.com/projects/${local.project_number}/locations/global/workloadIdentityPools/${local.wif_pool_id}/attribute.repository/${local.github_repository}"
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/service-account?ref=gcp-service-account-v0.1.0"
}

inputs = {
  project_id   = local.project_id
  account_id   = "playwright-iap-tester"
  display_name = "Playwright IAP probe (gke-ingress-iap-playwright)"
  description  = "Programmatic identity Playwright signs an IAP JWT as, for the positive IAP test."

  # Let the operator AND the CI federated principal impersonate this SA to mint a signed IAP JWT
  # (no exported key).
  token_creators = {
    operator = local.iap_member
    ci       = local.ci_principal
  }
}
