# Secret Manager container for Argo CD's OIDC client secret. The catalog module creates an EMPTY
# container only — the value is seeded out-of-band by `task seed-secrets` (from .env), so no secret
# material ever lands in Terraform state. Accessor IAM is wired by the iam/argocd-secret-sync unit.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/secret-manager?ref=gcp-secret-manager-v0.1.0"
}

inputs = {
  project_id = include.root.locals.project_id
  secret_id  = "argocd-oidc-client-secret"
}
