# GCP VPC for the target Cloud SQL instance. Private Service Access is enabled so Cloud SQL can get a
# private IP on this network (the production access path, used by the follow-up role-based-auth lab).
# No Cloud NAT — nothing here needs outbound internet.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/vpc?ref=gcp-vpc-vX.Y.Z"

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/gcp/vpc"
}

locals {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")
}

inputs = {
  name       = "rds2cloudsql"
  project_id = local.project_id

  subnets = [
    {
      name          = "db"
      region        = local.region
      ip_cidr_range = "10.70.0.0/20"
    },
  ]

  private_service_access = true

  # The migration host has no external IP (org policy commonly forbids them), so it egresses to the
  # RDS public endpoint via Cloud NAT. A reserved static NAT IP gives a stable address the RDS
  # security group can allowlist.
  create_nat            = true
  nat_reserve_static_ip = true

  # Let the operator reach the migration host over IAP SSH (no public SSH exposure).
  iap_ssh_enabled     = true
  iap_ssh_target_tags = ["migration-host"]
}
