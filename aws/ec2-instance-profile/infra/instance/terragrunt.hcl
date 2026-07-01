# The demo EC2 instance. It attaches the instance profile from the `iam` unit and runs a tiny
# user_data script at first boot that proves the profile works: `aws s3 ls` succeeds with NO
# credentials on the box — the CLI transparently pulls temporary creds from IMDS (the instance role).
#
# The script writes its result to /var/log/s3-ls-demo.log so you can read the proof over SSM without
# re-running anything. Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/ec2-instance?ref=aws-ec2-instance-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  # Let plan/validate run before lookups is applied (cost-free checks).
  mock_outputs = {
    ami_id    = "ami-00000000000000000"
    vpc_id    = "vpc-mock"
    subnet_id = "subnet-mock"
  }
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    instance_profile_name = "mock-instance-profile"
  }
}

inputs = {
  name      = "ec2-instance-profile-lab"
  ami_id    = dependency.lookups.outputs.ami_id
  subnet_id = dependency.lookups.outputs.subnet_id

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Proof-of-instance-profile at boot: list buckets using only the role's IMDS-vended credentials.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    LOG=/var/log/s3-ls-demo.log
    echo "=== instance profile demo: $(date -u) ===" >>"$LOG"
    echo "caller identity (from IMDS role creds):" >>"$LOG"
    aws sts get-caller-identity >>"$LOG" 2>&1 || true
    echo "aws s3 ls output:" >>"$LOG"
    aws s3 ls >>"$LOG" 2>&1 || true
    echo "=== done ===" >>"$LOG"
  EOF

  tags = {
    Environment = "lab"
  }
}
