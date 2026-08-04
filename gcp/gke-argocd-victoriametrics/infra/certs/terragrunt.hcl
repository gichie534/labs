# Google-managed HTTPS certificates (Certificate Manager, DNS-authorized) for the two public
# hostnames — argocd.$BASE_DOMAIN and grafana.$BASE_DOMAIN. Both are entries in a single certificate
# map named "obs"; the shared Gateway attaches the map via the `networking.gke.io/certmap: obs`
# annotation and picks the right leaf by SNI.
#
# DNS authorization is stable (independent of the LB IP), so the CNAMEs are published by the `dns`
# unit in Terraform. The A records, by contrast, are managed dynamically by external-dns.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id   = include.root.locals.project_id
  argocd_host  = include.root.locals.argocd_host
  grafana_host = include.root.locals.grafana_host
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/certificate-manager?ref=gcp-certificate-manager-v0.1.0"
}

inputs = {
  project_id = local.project_id
  name       = "obs"

  certificates = {
    argocd  = { domain = local.argocd_host }
    grafana = { domain = local.grafana_host }
  }
}
