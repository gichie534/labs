# The IDENTITY-ONLY demo instance (identity=Allow, bucket=silent). Attaches the identity-only
# profile and, at boot, reads the probe object using only the role's IMDS credentials. Its identity
# policy allows the read and nothing denies it, so the read SUCCEEDS. The result is written to
# /var/log/s3-eval-demo.log so the proof is readable over SSM without re-running anything.

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
  config_path = "../iam-identity-only"

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
  name      = "s3-eval-identity-only"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Boot-time probe: read the demo object using only the role's IMDS creds. Expected: SUCCESS
  # (identity policy allows; bucket policy silent).
  user_data = <<-EOF
    #!/bin/bash
    set -uo pipefail
    LOG=/var/log/s3-eval-demo.log
    BUCKET="${local.bucket}"
    echo "=== s3-policy-eval-matrix (IDENTITY-ONLY, expect SUCCESS): $(date -u) ===" >>"$LOG"
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
