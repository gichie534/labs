# IAM identity for the BUCKET-ONLY instance (matrix cell: identity=silent, bucket=Allow).
#
# Its identity policy grants NO S3 permissions at all — only AmazonSSMManagedInstanceCore so we can
# drive the probe over SSM. The demo bucket policy, however, explicitly Allows s3:GetObject to THIS
# role's ARN. Because same-account access is granted if EITHER side allows it, the resource-side
# Allow is enough on its own. Expected result: the read SUCCEEDS despite an empty identity grant.
#
# The IAM role/profile itself is sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

inputs = {
  name = "s3-eval-bucket-only"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules. Deliberately NO S3
  # grant here: the bucket policy is the only thing that permits this instance's read.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  tags = {
    Environment = "lab"
  }
}
