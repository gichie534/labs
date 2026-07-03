# The BUCKET-ONLY demo instance (identity=silent, bucket=Allow). Attaches the bucket-only profile
# (whose identity policy grants no S3 at all) and, at boot, reads the probe object. The bucket policy
# explicitly allows this role, and same-account access is granted if EITHER side allows it, so the
# read SUCCEEDS purely on the resource-side grant. Result is logged to /var/log/s3-eval-demo.log.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ec2-instance?ref=aws-ec2-instance-v0.1.0"
}

locals {
  bucket = get_env("DEMO_BUCKET", "s3-policy-eval-matrix-lab")
}

dependency "lookups" {
  config_path = "../lookups"

  mock_outputs = {
    ami_id    = "ami-00000000000000000"
    vpc_id    = "vpc-mock"
    subnet_id = "subnet-mock"
  }
}

dependency "iam" {
  config_path = "../iam-bucket-only"

  mock_outputs = {
    instance_profile_name = "mock-instance-profile"
  }
}

# Force the bucket, its policy, AND the probe.txt fixture to exist before this instance runs its
# boot-time probe. (seed depends on s3, so this covers both.)
dependency "seed" {
  config_path = "../seed"

  mock_outputs = {
    key = "probe.txt"
  }
}

inputs = {
  name      = "s3-eval-bucket-only"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Boot-time probe: identical command to every other instance. Expected: SUCCESS (identity policy
  # silent, but bucket policy allows).
  user_data = <<-EOF
    #!/bin/bash
    set -uo pipefail
    LOG=/var/log/s3-eval-demo.log
    BUCKET="${local.bucket}"
    echo "=== s3-policy-eval-matrix (BUCKET-ONLY, expect SUCCESS): $(date -u) ===" >>"$LOG"
    echo "caller identity (from IMDS role creds):" >>"$LOG"
    aws sts get-caller-identity >>"$LOG" 2>&1 || true
    echo "aws s3 cp s3://$BUCKET/probe.txt - :" >>"$LOG"
    aws s3 cp "s3://$BUCKET/probe.txt" - >>"$LOG" 2>&1
    echo "exit_code=$?" >>"$LOG"
    echo "=== done ===" >>"$LOG"
  EOF

  tags = {
    Environment = "lab"
  }
}
