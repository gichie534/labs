# The Redshift Serverless warehouse both ingestion paths are loaded into.
#
# COST: this is the expensive unit. Redshift Serverless bills per RPU-second while a query runs, so
# base_capacity is pinned to the 8-RPU minimum and max_capacity to 8 as a hard ceiling — a runaway
# query cannot scale itself up and surprise you. Idle costs nothing, but `task down` is still the only
# way to stop paying for storage.
#
# No admin password is configured anywhere. The module leaves manage_admin_password on, so Redshift
# creates and rotates the credential secret in Secrets Manager, and the CLI authenticates to the Data
# API with IAM instead. Nothing sensitive passes through .env or Terraform state.
#
# The module's COPY role is granted read on the data bucket and set as the namespace default, which is
# what lets the load statements say `IAM_ROLE default`.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/redshift-serverless?ref=aws-redshift-serverless-v0.1.1"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    private_subnet_ids = [
      "subnet-00000000000000000",
      "subnet-11111111111111111",
      "subnet-22222222222222222",
    ]
  }
}

dependency "warehouse_sg" {
  config_path = "../warehouse-sg"

  mock_outputs = {
    id = "sg-00000000000000000"
  }
}

dependency "data_lake" {
  config_path = "../data-lake"

  mock_outputs = {
    arn = "arn:aws:s3:::mock-bucket"
  }
}

inputs = {
  name          = "events-warehouse"
  database_name = "labdb"

  # Three private subnets across three AZs — the minimum Redshift Serverless accepts.
  subnet_ids         = dependency.vpc.outputs.private_subnet_ids
  security_group_ids = [dependency.warehouse_sg.outputs.id]

  # Minimum capacity, with a matching ceiling as a cost guard.
  base_capacity = 8
  max_capacity  = 8

  # Lets the COPY role read both the batch/ and stream/ prefixes of the data bucket.
  s3_read_bucket_arns = [dependency.data_lake.outputs.arn]

  tags = {
    Environment = "lab"
  }
}
