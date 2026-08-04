# Workload identity + access for the SecretSync controller that materializes the two Argo CD secrets.
# The catalog workload-iam module creates a GSA, binds the argocd/argocd-secret-sync Kubernetes SA to
# it via Workload Identity, and grants secretAccessor on the two secret containers. The KSA carries
# the matching iam.gke.io/gcp-service-account annotation (see the private-repo template).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/workload-iam?ref=gcp-workload-iam-v0.1.0"
}

dependency "argocd_oidc" {
  config_path                             = "../../secrets/argocd-oidc"
  mock_outputs                            = { secret_id = "projects/mock/secrets/argocd-oidc-client-secret" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "github_app" {
  config_path                             = "../../secrets/github-app"
  mock_outputs                            = { secret_id = "projects/mock/secrets/github-app-private-key" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "github_app_id" {
  config_path                             = "../../secrets/github-app-id"
  mock_outputs                            = { secret_id = "projects/mock/secrets/github-app-id" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "github_app_installation_id" {
  config_path                             = "../../secrets/github-app-installation-id"
  mock_outputs                            = { secret_id = "projects/mock/secrets/github-app-installation-id" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "github_repo_url" {
  config_path                             = "../../secrets/github-repo-url"
  mock_outputs                            = { secret_id = "projects/mock/secrets/github-repo-url" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id                 = include.root.locals.project_id
  account_id                 = "argocd-secret-sync"
  display_name               = "Argo CD SecretSync reader"
  kubernetes_namespace       = "argocd"
  kubernetes_service_account = "argocd-secret-sync"

  # Everything SecretSync materializes for Argo CD: the OIDC client secret and the four fields of the
  # repository Secret (url + App id + installation id + private key).
  secret_ids = {
    oidc                = dependency.argocd_oidc.outputs.secret_id
    github_key          = dependency.github_app.outputs.secret_id
    github_app_id       = dependency.github_app_id.outputs.secret_id
    github_installation = dependency.github_app_installation_id.outputs.secret_id
    github_repo_url     = dependency.github_repo_url.outputs.secret_id
  }
}
