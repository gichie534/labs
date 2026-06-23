# The heart of the lab: direct Workload Identity Federation for the GKE workload.
#
# Grants IAM roles straight to the Kubernetes service account's federated principal
# (principal://.../workloadIdentityPools/<project>.svc.id.goog/subject/ns/<ns>/sa/<ksa>) — the
# Google-recommended pattern, with NO Google service account created or impersonated.
#
# It grants the KSA roles/storage.objectViewer on the ALLOWED bucket and nothing on the DENIED
# bucket. The deployed Job runs under exactly this namespace/KSA, so its reads of the allowed bucket
# succeed and its reads of the denied bucket fail with 403 — demonstrating the authorization gate.
#
# The namespace and KSA name here MUST match the Helm chart's values (serviceAccount.* / namespace).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id     = include.root.locals.project_id
  project_number = include.root.locals.project_number
  bucket_allowed = include.root.locals.bucket_allowed
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke-workload-identity?ref=gcp-gke-workload-identity-v0.1.0"
}

# Depend on the allowed bucket so the grant is created against a real bucket name, and ordered after
# it. The denied bucket is intentionally NOT referenced here — that's what makes it denied.
dependency "bucket_allowed" {
  config_path = "../bucket-allowed"

  mock_outputs = {
    name = "mock-allowed-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id     = local.project_id
  project_number = local.project_number

  # Must match deploy/helm/reader/values.yaml (namespace + serviceAccount.name).
  kubernetes_namespace       = "wifdemo"
  kubernetes_service_account = "reader"

  bucket_iam = {
    allowed = {
      bucket = dependency.bucket_allowed.outputs.name
      role   = "roles/storage.objectViewer"
    }
  }
}
