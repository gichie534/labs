# The VPC-attached Lambda — the star of the lab. It is placed in the same private subnets as the EC2
# instance and given the Lambda security group, then pointed at the instance's private IP via the
# TARGET_URL env var. On invocation it GETs http://<ec2-private-ip>:8080 and returns the instance's
# JSON identity, proving a VPC-attached function can reach a private VPC resource.
#
# The deployment zip is built by `task lambda-vpc:build` (compiles app/go -> bootstrap, zips it to
# build/function.zip). Run build before up/plan; the module hashes the zip so rebuilds redeploy.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/lambda?ref=aws-lambda-v0.1.0"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
  }
}

dependency "sg_lambda" {
  config_path = "../sg/lambda"

  mock_outputs = {
    id = "sg-mocklambda"
  }
}

dependency "ec2" {
  config_path = "../ec2"

  mock_outputs = {
    private_ip = "10.0.128.10"
  }
}

inputs = {
  name = "lambda-vpc-private-access"

  # Built by `task lambda-vpc:build` into the lab-root build/ dir.
  filename = "${get_terragrunt_dir()}/../../build/function.zip"
  handler  = "bootstrap"
  runtime  = "provided.al2023"

  # Attach to the VPC's private subnets with the Lambda SG — this is what grants network reachability
  # to the private EC2 instance.
  vpc_config = {
    subnet_ids         = dependency.vpc.outputs.private_subnet_ids
    security_group_ids = [dependency.sg_lambda.outputs.id]
  }

  environment_variables = {
    TARGET_URL = "http://${dependency.ec2.outputs.private_ip}:8080"
  }

  tags = {
    Environment = "lab"
  }
}
