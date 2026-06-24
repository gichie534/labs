# The "volume" secret. Created by the catalog's secret-manager module (an empty container) and
# seeded with a hardcoded test value via a generated google_secret_manager_secret_version resource
# alongside the module's source — keeping the catalog module untouched (it deliberately does not
# own values) while letting `task csi:up` produce a fully-working state with no separate seed step.
#
# This unit is a pure producer: it owns the secret + version and exports the ID. The KSA accessor
# IAM is granted in the workload-identity unit, so policy lives with the workload that consumes it.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/secret-manager?ref=gcp-secret-manager-v0.1.0"
}

inputs = {
  project_id = local.project_id
  secret_id  = "csi-volume-secret"
  labels = {
    lab     = "gke-secret-manager-csi"
    consume = "volume"
  }
}

# Seed a hardcoded test value via Terraform. The generated file lives next to the module's source
# in Terragrunt's working dir, so it can reference google_secret_manager_secret.this directly. The
# value is intentionally a hardcoded test string — no real secret is being committed.
generate "version" {
  path      = "version.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    resource "google_secret_manager_secret_version" "seed" {
      secret      = google_secret_manager_secret.this.id
      secret_data = "hello-from-volume"
    }

    output "secret_version" {
      description = "Resource name of the seeded secret version (projects/<project>/secrets/<name>/versions/<n>). Wire this into the SecretProviderClass."
      value       = google_secret_manager_secret_version.seed.name
    }
  EOF
}
