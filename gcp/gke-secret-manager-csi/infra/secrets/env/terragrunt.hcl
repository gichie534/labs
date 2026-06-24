# The "env" secret. Same shape as secret-volume — created by the catalog's secret-manager module
# and seeded inline — but consumed differently downstream: a SecretSync resource materializes its
# value as a Kubernetes Secret which the Deployment references via valueFrom.secretKeyRef.

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
  secret_id  = "csi-env-secret"
  labels = {
    lab     = "gke-secret-manager-csi"
    consume = "env"
  }
}

generate "version" {
  path      = "version.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    resource "google_secret_manager_secret_version" "seed" {
      secret      = google_secret_manager_secret.this.id
      secret_data = "hello-from-env"
    }

    output "secret_version" {
      description = "Resource name of the seeded secret version (projects/<project>/secrets/<name>/versions/<n>). Wire this into the SecretProviderClass."
      value       = google_secret_manager_secret_version.seed.name
    }
  EOF
}
