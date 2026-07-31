variable "project_id" {
  description = "Project that owns the SA, IAM bindings, and the Secret Manager secret."
  type        = string
  nullable    = false
}

variable "oauth_client_secret" {
  description = "The OAuth 2.0 Web client secret for Dex's Google connector (from the manually-created console client). Stored in Secret Manager; seeded from .env."
  type        = string
  nullable    = false
  sensitive   = true
}

# APIs Dex needs to read Workspace groups keylessly:
#  - admin.googleapis.com: the Admin SDK Directory API (group membership).
#  - iamcredentials.googleapis.com: lets the SA sign the delegation JWT WITHOUT a key (signJwt),
#    which is what makes domain-wide delegation work under Workload Identity.
resource "google_project_service" "apis" {
  for_each           = toset(["admin.googleapis.com", "iamcredentials.googleapis.com"])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# "Directory reader" service account Dex impersonates (via domain-wide delegation) to read a user's
# Workspace groups. NO KEY is created — Dex authenticates as this SA through GKE Workload Identity.
# DWD scope authorization remains a manual Workspace Admin console step keyed on this SA's client id.
resource "google_service_account" "dex_directory" {
  project      = var.project_id
  account_id   = "argocd-dex-directory"
  display_name = "Argo CD Dex directory reader"
  description  = "Workload-Identity-bound SA Dex uses to read Workspace group membership (keyless DWD). Managed by Terraform."
}

# Workload Identity: let the argocd-dex-server Kubernetes SA (namespace argocd) impersonate this GSA.
# GKE Autopilot always runs with Workload Identity enabled (pool <project>.svc.id.goog).
resource "google_service_account_iam_member" "dex_workload_identity" {
  service_account_id = google_service_account.dex_directory.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[argocd/argocd-dex-server]"
}

# Keyless domain-wide delegation mints the per-user assertion by calling IAM Credentials signJwt on
# this SA, so the SA must be allowed to create tokens for ITSELF.
resource "google_service_account_iam_member" "dex_self_token_creator" {
  service_account_id = google_service_account.dex_directory.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.dex_directory.email}"
}

# The OAuth 2.0 Web client secret (from the manual console client) lives in Secret Manager; the
# deploy task reads it from here to build the argocd-google-sso k8s secret.
resource "google_secret_manager_secret" "oauth_client_secret" {
  project   = var.project_id
  secret_id = "argocd-oauth-client-secret"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "oauth_client_secret" {
  secret      = google_secret_manager_secret.oauth_client_secret.id
  secret_data = var.oauth_client_secret
}

output "directory_sa_email" {
  description = "Email of the Dex directory-reader service account (also the value of the dex KSA's iam.gke.io/gcp-service-account annotation)."
  value       = google_service_account.dex_directory.email
}

output "directory_sa_client_id" {
  description = "The SA's client id (unique_id) — authorize THIS in the Workspace Admin console for domain-wide delegation (Directory read scopes)."
  value       = google_service_account.dex_directory.unique_id
}

output "oauth_client_secret_name" {
  description = "Secret Manager secret holding the OAuth 2.0 Web client secret."
  value       = google_secret_manager_secret.oauth_client_secret.secret_id
}
