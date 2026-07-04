# Security group for the private EC2 instance. It permits inbound on the app port (8080) ONLY from
# the Lambda security group — a security-group-to-security-group rule, the reason the
# aws/security-group module exists. No CIDR-based ingress, so nothing else in the VPC can reach it;
# the only thing that can is the Lambda function. Egress defaults to allow-all.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/security-group?ref=aws-security-group-v0.1.0"
}

dependency "vpc" {
  config_path = "../../vpc"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
}

dependency "sg_lambda" {
  config_path = "../lambda"

  mock_outputs = {
    id = "sg-mocklambda"
  }
}

inputs = {
  name        = "lambda-vpc-private-access-ec2"
  vpc_id      = dependency.vpc.outputs.vpc_id
  description = "Private app server: inbound 8080 from the Lambda SG only."

  ingress_rules = [{
    description              = "App port from the Lambda function only"
    from_port                = 8080
    to_port                  = 8080
    protocol                 = "tcp"
    source_security_group_id = dependency.sg_lambda.outputs.id
  }]

  # egress_rules defaults to allow-all.

  tags = {
    Environment = "lab"
  }
}
