# Lab-local lookups unit. Sourced from a local path (not the modules repo) because it's lab-specific
# glue — discovering the account's existing AWS-managed anomaly monitor — not reusable infrastructure.
# It creates NO resources; it only reads data sources and exposes their results as outputs for the
# anomaly-detection unit.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}
