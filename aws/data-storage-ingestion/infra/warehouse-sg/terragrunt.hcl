# Security group for the Redshift Serverless workgroup.
#
# NO ingress rules at all, on purpose. Queries reach the warehouse through the Redshift Data API — an
# IAM-authenticated regional AWS endpoint — so nothing ever connects to the workgroup over the
# network. There is no bastion, no psql, and no reason to open port 5439 to anything. Egress-only is
# the whole group.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/security-group?ref=aws-security-group-v0.1.0"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }
}

inputs = {
  name        = "streaming-vs-batch-warehouse"
  description = "Egress-only group for the Redshift Serverless workgroup; queries arrive via the Data API, never over the network"
  vpc_id      = dependency.vpc.outputs.vpc_id

  # Explicitly empty — see the note above.
  ingress_rules = []

  tags = {
    Environment = "lab"
  }
}
