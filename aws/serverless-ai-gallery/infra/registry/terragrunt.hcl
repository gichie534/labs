# ECR repository holding the gallery container's images. CI pushes here; the ECS service pulls.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ecr?ref=aws-ecr-v0.1.0"
}

inputs = {
  name                       = "serverless-ai-gallery"
  force_delete               = true # throwaway lab: destroy cleanly without emptying first
  untagged_image_expiry_days = 7

  tags = {
    Environment = "lab"
  }
}
