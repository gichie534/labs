# Direct Workload Identity Federation for the demo workload.
#
# Grants roles/secretmanager.secretAccessor straight to the KSA's federated principal
# (principal://.../workloadIdentityPools/<project>.svc.id.goog/subject/ns/<ns>/sa/<ksa>) on each
# of the two secrets — no Google service account, no key, no impersonation. The CSI driver and
# the SecretSync controller authenticate to Secret Manager as this KSA.
#
# The namespace/KSA name MUST match the deploy/ manifests.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id     = include.root.locals.project_id
  project_number = include.root.locals.project_number
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke-workload-identity?ref=gcp-gke-workload-identity-v0.2.0"
}

dependency "secret_volume" {
  config_path = "../secrets/volume"

  mock_outputs = {
    secret_id = "projects/mock/secrets/mock-vol"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "secret_env" {
  config_path = "../secrets/env"

  mock_outputs = {
    secret_id = "projects/mock/secrets/mock-env"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id     = local.project_id
  project_number = local.project_number

  # Must match deploy/manifests namespace + serviceAccount.
  kubernetes_namespace       = "csi-demo"
  kubernetes_service_account = "secret-reader"

  secret_iam = {
    volume = {
      secret_id = dependency.secret_volume.outputs.secret_id
      role      = "roles/secretmanager.secretAccessor"
    }
    env = {
      secret_id = dependency.secret_env.outputs.secret_id
      role      = "roles/secretmanager.secretAccessor"
    }
  }
}
