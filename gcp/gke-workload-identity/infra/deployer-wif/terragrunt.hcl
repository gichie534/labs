# GitHub -> GCP Workload Identity Federation for CI. Lets GitHub Actions OIDC tokens from this lab's
# repository act directly as a federated identity (no exported key, no intermediary GSA) to build,
# push, and deploy.
#
# NOTE: this is a DIFFERENT federation than the lab's subject. This unit federates an *external*
# IdP (GitHub) into GCP so the pipeline can run. The lab itself demonstrates *in-cluster* GKE
# KSA -> IAM federation (the workload-identity unit). Both are "workload identity federation"; keep
# them distinct.

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
  pool_id           = "github-ci-gke-wi"
  pool_display_name = "GitHub CI"

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

  # Direct WIF for CI: grant the repo's federated identities the roles the pipeline needs.
  #   - artifactregistry.writer -> push images to the lab's repo
  #   - container.developer     -> get cluster credentials + apply workloads (helm/kubectl)
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
