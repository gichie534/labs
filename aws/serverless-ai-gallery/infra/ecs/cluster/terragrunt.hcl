# The Fargate ECS cluster the gallery service runs in.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ecs-cluster?ref=aws-ecs-cluster-v0.1.0"
}

inputs = {
  name = "serverless-ai-gallery"

  tags = {
    Environment = "lab"
  }
}
