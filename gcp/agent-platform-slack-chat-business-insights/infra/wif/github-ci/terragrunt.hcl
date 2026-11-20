# GitHub Actions -> GCP Workload Identity Federation for this lab's CI (keyless). The pipeline evaluates and ships
# agent revisions, shifts traffic, and deploys the Slack bridge image.
#
# Roles are project-level because the catalog module grants at project scope; a production setup would scope
# aiplatform to the reasoning engine and actAs to the two bridge service accounts.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  repo = include.root.locals.github_repository
}

terraform {
  source = "${include.root.locals.catalog_git}/workload-identity-federation?ref=gcp-workload-identity-federation-v0.2.1"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id        = include.root.locals.project_id
  pool_id           = include.root.locals.names.wif_pool
  pool_display_name = "GitHub CI (business insights)"

  oidc_providers = {
    github = {
      issuer_uri = "https://token.actions.githubusercontent.com"
      attribute_mapping = {
        "google.subject"       = "assertion.sub"
        "attribute.repository" = "assertion.repository"
        "attribute.ref"        = "assertion.ref"
      }
      # Security gate: only tokens minted for this repository are accepted.
      attribute_condition = "assertion.repository == \"${local.repo}\""
      display_name        = "GitHub Actions"
    }
  }

  project_iam_bindings = {
    deployer = {
      principal_set = "attribute.repository/${local.repo}"
      roles = [
        # Push revisions, read them, query a specific revision for the eval gate, change traffic, run evals.
        "roles/aiplatform.user",
        # Eval ground truth: query bi_crm_snapshot / bi_analytics.
        "roles/bigquery.jobUser",
        "roles/bigquery.dataViewer",
        # Slack bridge image: push it, then roll it out to the two Cloud Run services (actAs their SAs).
        "roles/artifactregistry.writer",
        "roles/run.developer",
        "roles/iam.serviceAccountUser",
      ]
    }
  }
}
