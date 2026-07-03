# IAM identity for the NEITHER instance (matrix cell: identity=silent, bucket=silent).
#
# Its identity policy grants NO S3 permissions, and the demo bucket policy says nothing about this
# role either. With no Allow on either side and no explicit Deny, the request falls through to the
# default: an implicit deny. Expected result: the read FAILS with AccessDenied. This is the baseline
# cell — access must be granted somewhere; silence means no.
#
# The IAM role/profile itself is sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

inputs = {
  name = "s3-eval-neither"

  # Reach the instance via SSM Session Manager — no SSH key, no inbound rules. No S3 grant, and the
  # bucket policy is silent about this role too: the read is denied by default (implicit deny).
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  tags = {
    Environment = "lab"
  }
}
