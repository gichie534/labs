# Workload identity + access for the Grafana pod, which reads its OAuth client secret as a
# CSI-mounted file. GSA + Workload Identity binding for observability/grafana + secretAccessor on the
# Grafana secret container.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/workload-iam?ref=gcp-workload-iam-v0.1.0"
}

dependency "grafana_oauth" {
  config_path                             = "../../secrets/grafana-oauth"
  mock_outputs                            = { secret_id = "projects/mock/secrets/grafana-oauth-client-secret" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id                 = include.root.locals.project_id
  account_id                 = "grafana-oauth"
  display_name               = "Grafana OAuth secret reader"
  kubernetes_namespace       = "observability"
  kubernetes_service_account = "grafana"

  secret_ids = {
    oauth = dependency.grafana_oauth.outputs.secret_id
  }
}
