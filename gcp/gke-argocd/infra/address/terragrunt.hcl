# Reserved GLOBAL external static IP for the Argo CD Gateway.
#
# Why an inline unit (not a modules-repo module): this is a single lab-specific glue resource
# (one google_compute_global_address), not reusable infrastructure — so it lives here rather than
# being promoted to the catalog. Reserving the IP up front (instead of letting the load balancer
# allocate an ephemeral one) means the DNS A record can be published at `up` time and survives
# teardown/recreate, which is the more production-like, single-phase path. The Gateway attaches it
# by name via `spec.addresses[].type: NamedAddress`.

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
