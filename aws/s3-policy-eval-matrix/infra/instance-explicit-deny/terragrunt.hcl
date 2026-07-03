# The EXPLICIT-DENY demo instance (identity=Allow, bucket=explicit Deny). Attaches the explicit-deny
# profile (whose identity policy DOES allow the read) and, at boot, runs the same probe. The bucket
# policy's explicit Deny on this role overrides the identity Allow — an explicit Deny always wins —
# so the read FAILS with AccessDenied. Result is logged to /var/log/s3-eval-demo.log.

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
  config_path = "../iam-explicit-deny"

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
  name      = "s3-eval-explicit-deny"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Boot-time probe: identical command to every other instance. Expected: AccessDenied (identity
  # policy allows, but the bucket policy's explicit Deny overrides it).
  user_data = <<-EOF
    #!/bin/bash
    set -uo pipefail
    LOG=/var/log/s3-eval-demo.log
    BUCKET="${local.bucket}"
    echo "=== s3-policy-eval-matrix (EXPLICIT-DENY, expect AccessDenied): $(date -u) ===" >>"$LOG"
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
