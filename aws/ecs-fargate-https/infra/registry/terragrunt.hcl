# ECR repository holding the app's container images. CI pushes here; the ECS service pulls from here.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ecr?ref=aws-ecr-v0.1.0"
}

inputs = {
  name                       = "ecs-fargate-https"
  force_delete               = true # throwaway lab: destroy cleanly without emptying first
  untagged_image_expiry_days = 7

  tags = {
    Environment = "lab"
  }
}
