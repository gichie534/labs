# Workload Identity Federation: lets GitHub Actions OIDC tokens from this lab's repository act
# directly as a federated identity with no exported key and no intermediary service account
# (Google's preferred direct-WIF pattern). Wires the (IdP-neutral)
# workload-identity-federation module to GitHub specifically and grants the repo its project roles
# directly.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id        = include.root.locals.project_id
  github_repository = include.root.locals.github_repository
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/workload-identity-federation?ref=gcp-workload-identity-federation-v0.2.1"
}

inputs = {
  project_id        = local.project_id
  pool_id           = "github-ci-gke-ingress"
  pool_display_name = "GitHub CI (gke-ingress)"

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
  # principalSet. No service account to impersonate.
  #   - artifactregistry.writer -> push images to the lab's repo
  #   - container.developer     -> get cluster credentials + apply workloads (helm)
  # DNS is published at stand-up time by the Taskfile (local), so CI needs no DNS role.
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
