# Secret Manager container for the GitHub App private key (Argo CD's read credential for the private
# repo). Empty container only; the .pem is seeded out-of-band by `task seed-secrets`. Accessor IAM is
# wired by the iam/argocd-secret-sync unit.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/secret-manager?ref=gcp-secret-manager-v0.1.0"
}

inputs = {
  project_id = include.root.locals.project_id
  secret_id  = "github-app-private-key"
}
