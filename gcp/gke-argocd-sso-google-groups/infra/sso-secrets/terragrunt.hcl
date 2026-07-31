# SSO identity + secret material for Argo CD's Dex Google connector, kept inline because it needs
# things the catalog's pure modules deliberately don't do: cross-resource IAM (Workload Identity)
# and a Secret Manager VERSION.
#
# Keyless: Dex authenticates as the directory-reader SA through GKE Workload Identity (no SA key).
#
# It creates:
#   - the Admin SDK + IAM Credentials API enablement (group reads + keyless DWD JWT signing),
#   - a "directory reader" service account (no key),
#   - the Workload Identity binding for the argocd-dex-server KSA + self token-creator for DWD,
#   - a Secret Manager secret holding the OAuth 2.0 Web client secret (seeded from .env).
#
# TWO MANUAL Google steps this unit cannot automate (documented in the README):
#   1. Create the OAuth 2.0 Web client in the console (Google exposes no Terraform resource for it);
#      put its id/secret in .env. Its authorized redirect URI is https://$ARGOCD_DOMAIN/api/dex/callback.
#   2. After `up`, authorize this SA's client id (output `directory_sa_client_id`) for the Directory
#      read scopes in the Workspace Admin console (domain-wide delegation).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
}

inputs = {
  project_id          = local.project_id
  oauth_client_secret = include.root.locals.oauth_client_secret
}
