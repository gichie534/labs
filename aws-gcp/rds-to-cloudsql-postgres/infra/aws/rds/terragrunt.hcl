# The source PostgreSQL RDS instance. Seeded (task seed) with a production-shaped database — multiple
# schemas owned by per-service roles, a role hierarchy, sequences, a partitioned table, a view, a
# materialized view, triggers, and extensions — then dumped and migrated to Cloud SQL (task migrate).
#
# publicly_accessible + a narrow allowed_cidr_blocks (your OPERATOR_CIDR) + rds.force_ssl make the
# instance reachable from your machine over TLS only. See docs/adr/0002-connectivity.md.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/rds-postgres?ref=aws-rds-postgres-vX.Y.Z"

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/aws/rds-postgres"
}

dependency "aws_network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
  # Include apply + destroy so run --all can parse this unit's inputs even when the dependency's
  # outputs aren't available yet (first apply) or are already gone (teardown re-run). Terragrunt
  # re-reads real outputs before actually applying; destroy works from state, so mocks never affect
  # real resources.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

# The source is reached from the GCP migration host, which has no public IP and egresses through the
# VPC's Cloud NAT. Cross-cloud wiring: the AWS instance's ingress is scoped to that reserved static
# NAT IP (the GCP network's egress address).
dependency "gcp_network" {
  config_path = "../../gcp/network"

  mock_outputs = {
    nat_ip_addresses = ["203.0.113.10"]
  }
  # apply: so `run --all apply` can resolve inputs on the first pass when gcp/network's state predates
  # the nat_ip_addresses output (Terragrunt re-reads the REAL output before applying, so the mock
  # never reaches the RDS security group). destroy: so a teardown re-run can parse this unit after
  # gcp/network has already been destroyed.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name       = "rds2cloudsql-src"
  vpc_id     = dependency.aws_network.outputs.vpc_id
  subnet_ids = dependency.aws_network.outputs.public_subnet_ids

  engine_version  = "16"
  instance_class  = "db.t4g.micro"
  db_name         = "app"
  master_username = get_env("RDS_MASTER_USERNAME", "postgres")
  master_password = get_env("RDS_MASTER_PASSWORD", "REPLACE_WITH_RDS_PASSWORD")

  publicly_accessible = true
  allowed_cidr_blocks = ["${dependency.gcp_network.outputs.nat_ip_addresses[0]}/32"]

  # Require TLS on every connection.
  parameters = [
    { name = "rds.force_ssl", value = "1" },
  ]

  # Ephemeral lab: no backups, no deletion protection, no final snapshot.
  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true

  tags = {
    Lab       = "rds-to-cloudsql-postgres"
    ManagedBy = "terragrunt"
  }
}
