# Google-managed HTTPS certificate for the Argo CD hostname, issued and auto-renewed by Certificate
# Manager and validated by DNS authorization. The GKE Gateway attaches it by referencing this
# module's certificate MAP through the `networking.gke.io/certmap` annotation (the annotation value
# is the map name, which equals this unit's `name` input, "argocd").
#
# The module only outputs the DNS-authorization CNAME(s); the dns unit publishes them (see below).
# The cert stays PENDING until that CNAME resolves — exactly like an ACM cert waiting on its
# Route53 validation record.

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

  # Base name; also the certificate MAP name and therefore the value of the Gateway's
  # `networking.gke.io/certmap` annotation. Kept generic (no domain) on purpose.
  name = "argocd"

  certificates = {
    server = { domain = local.argocd_domain }
  }
}
