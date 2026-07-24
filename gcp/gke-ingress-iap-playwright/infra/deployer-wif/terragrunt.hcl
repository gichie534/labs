# Workload Identity Federation: lets GitHub Actions OIDC tokens from this lab's repository act
# directly as a federated identity with no exported key and no intermediary service account
# (Google's preferred direct-WIF pattern). Wires the (IdP-neutral)
# workload-identity-federation module to GitHub specifically and grants the repo its project roles
# directly.
#
# NOTE (this lab's addition): CI also needs to MINT an IAP bearer token for the Playwright positive
# test. IAP won't accept a bare federated token (a federated principal has no signing keys IAP
# trusts), so CI impersonates the Playwright test SA and signs a JWT as it. That impersonation grant
# (roles/iam.serviceAccountTokenCreator on the test SA) lives in the iap-sa unit, granted to this
# pool's repo principalSet — not here.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id        = include.root.locals.project_id
  github_repository = include.root.locals.github_repository
  wif_pool_id       = include.root.locals.wif_pool_id
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/workload-identity-federation?ref=gcp-workload-identity-federation-v0.2.1"
}

inputs = {
  project_id        = local.project_id
  pool_id           = local.wif_pool_id
  pool_display_name = "GitHub CI (gke-iap-pw)"

  oidc_providers = {
    github = {
      issuer_uri = "https://token.actions.githubusercontent.com"
      attribute_mapping = {
        "google.subject"       = "assertion.sub"
        "attribute.repository" = "assertion.repository"
        "attribute.ref"        = "assertion.ref"
      }
      # Security gate: only tokens minted for this repository are accepted.
      attribute_condition = "assertion.repository == \"${local.github_repository}\""
      display_name        = "GitHub Actions"
    }
  }

  # Direct WIF: grant the repo's federated identities the roles CI needs, straight to the
  # principalSet. No service account to impersonate for the deploy itself.
  #   - artifactregistry.writer -> push images to the lab's repo
  #   - container.developer     -> get cluster credentials + apply workloads (helm)
  # DNS and IAP access are managed at stand-up time by the Taskfile (local), so CI needs neither a
  # DNS role nor IAP-admin rights. The one extra CI capability this lab adds (Token Creator on the
  # test SA, to mint the IAP JWT) is granted in the iap-sa unit.
  project_iam_bindings = {
    deployer = {
      principal_set = "attribute.repository/${local.github_repository}"
      roles = [
        "roles/artifactregistry.writer",
        "roles/container.developer",
      ]
    }
  }
}
