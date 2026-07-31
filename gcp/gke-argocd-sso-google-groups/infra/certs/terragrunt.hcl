# Google-managed HTTPS certificate for the Argo CD hostname (Certificate Manager, DNS-authorized).
# The Gateway attaches it via the `networking.gke.io/certmap: argocd` annotation. Same as the base
# lab.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id    = include.root.locals.project_id
  argocd_domain = include.root.locals.argocd_domain
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/certificate-manager?ref=gcp-certificate-manager-v0.1.0"
}

inputs = {
  project_id = local.project_id
  name       = "argocd"

  certificates = {
    server = { domain = local.argocd_domain }
  }
}
