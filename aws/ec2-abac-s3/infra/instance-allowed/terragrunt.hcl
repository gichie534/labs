# The ALLOWED demo instance. Attaches the `iam-allowed` profile (tagged project=abac-lab) and, at
# boot, probes the demo bucket with only the role's IMDS-vended credentials. Because its principal
# tag satisfies the bucket policy, the read SUCCEEDS. The result is written to /var/log/abac-demo.log
# so the proof is readable over SSM without re-running anything.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ec2-instance?ref=aws-ec2-instance-v0.1.0"
}

locals {
  bucket = get_env("ABAC_BUCKET", "ec2-abac-s3-lab")
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
  config_path = "../iam-allowed"

  mock_outputs = {
    instance_profile_name = "mock-instance-profile"
  }
}

# Not consumed as an input, but forces the bucket, its ABAC policy, AND the probe.txt fixture to
# exist before this instance runs its boot-time probe. (seed depends on s3, so this covers both.)
dependency "seed" {
  config_path = "../seed"

  mock_outputs = {
    key = "probe.txt"
  }
}

inputs = {
  name      = "ec2-abac-s3-allowed"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Boot-time ABAC probe: read the demo object using only the role's IMDS creds. Expected: SUCCESS.
  user_data = <<-EOF
    #!/bin/bash
    set -uo pipefail
    LOG=/var/log/abac-demo.log
    BUCKET="${local.bucket}"
    echo "=== ABAC demo (ALLOWED, expect SUCCESS): $(date -u) ===" >>"$LOG"
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
