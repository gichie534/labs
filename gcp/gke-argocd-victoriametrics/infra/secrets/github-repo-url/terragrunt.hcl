# Secret Manager container for the private infra repo URL. It's the match key of the Argo CD
# repository Secret, so SecretSync sources it here (must equal the Applications' repoURL). Empty
# container; value seeded by `task seed-secrets`.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/secret-manager?ref=gcp-secret-manager-v0.1.0"
}

inputs = {
  project_id = include.root.locals.project_id
  secret_id  = "github-repo-url"
}
