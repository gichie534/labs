# The image metadata table. One row per uploaded image, keyed by the upload key (uploads/<id>): the
# push Lambda writes a placeholder description on upload, and the ai Lambda overwrites it with the
# Bedrock-generated description. The fetch Lambda reads it to render the gallery.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/dynamodb?ref=aws-dynamodb-v0.1.0"
}

inputs = {
  name          = "ai-gallery-image-metadata"
  hash_key      = "ImageKey"
  hash_key_type = "S"

  tags = {
    Environment = "lab"
  }
}
