# The DENIED demo instance. Attaches the `iam-denied` profile (NO project tag) and, at boot, runs the
# exact same probe against the demo bucket. Its RBAC identity policy allows the read, but the bucket
# policy's ABAC condition denies it because the role carries no project=abac-lab tag — so the read
# FAILS with AccessDenied. The result is written to /var/log/abac-demo.log for reading over SSM.

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
  config_path = "../iam-denied"

  mock_outputs = {
    instance_profile_name = "mock-instance-profile"
  }
}

# Force the bucket, its ABAC policy, AND the probe.txt fixture to exist before this instance runs its
# boot-time probe. (seed depends on s3, so this covers both.)
dependency "seed" {
  config_path = "../seed"

  mock_outputs = {
    key = "probe.txt"
  }
}

inputs = {
  name      = "ec2-abac-s3-denied"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Boot-time ABAC probe: identical command to the allowed instance. Expected: AccessDenied, because
  # the bucket policy's aws:PrincipalTag/project condition isn't satisfied by this untagged role.
  user_data = <<-EOF
    #!/bin/bash
    set -uo pipefail
    LOG=/var/log/abac-demo.log
    BUCKET="${local.bucket}"
    echo "=== ABAC demo (DENIED, expect AccessDenied): $(date -u) ===" >>"$LOG"
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
