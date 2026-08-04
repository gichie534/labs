# Workload identity + access for external-dns. No secrets — just a GSA bound to the
# external-dns/external-dns Kubernetes SA via Workload Identity, granted project-level roles/dns.admin
# so it can manage records in the lab's Cloud DNS zone.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/workload-iam?ref=gcp-workload-iam-v0.1.0"
}

inputs = {
  project_id                 = include.root.locals.project_id
  account_id                 = "external-dns"
  display_name               = "external-dns Cloud DNS writer"
  kubernetes_namespace       = "external-dns"
  kubernetes_service_account = "external-dns"

  project_roles = ["roles/dns.admin"]
}
