# Reserved GLOBAL external static IP for the Argo CD Gateway (see the base lab's ADR for why a
# reserved IP gives single-phase DNS). Single lab-specific glue resource, kept inline.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
}

inputs = {
  project_id = local.project_id
  name       = "argocd-gateway"
}
