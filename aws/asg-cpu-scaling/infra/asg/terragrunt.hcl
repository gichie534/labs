# The Auto Scaling group — the point of the lab.
#
# A fleet of Amazon Linux 2023 instances behind a launch template, with a single target-tracking
# policy on fleet-average CPU (target 30%). Push CPU load onto the running instances (via SSM) and
# the average climbs past 30% -> the group scales OUT toward max_size; release the load and the
# average falls -> the group scales IN back toward min_size.
#
# Each instance installs stress-ng at first boot (user_data) so the `load` task can trigger a burn
# without any extra setup. Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/autoscaling-group?ref=aws-autoscaling-group-v0.1.0"
}

dependency "lookups" {
  config_path = "../lookups"

  # Let plan/validate run before lookups is applied (cost-free checks).
  mock_outputs = {
    ami_id     = "ami-00000000000000000"
    vpc_id     = "vpc-mock"
    subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "iam" {
  config_path = "../iam"

  mock_outputs = {
    instance_profile_name = "mock-instance-profile"
  }
}

inputs = {
  name       = "asg-cpu-scaling-lab"
  ami_id     = dependency.lookups.outputs.ami_id
  subnet_ids = dependency.lookups.outputs.subnet_ids

  iam_instance_profile = dependency.iam.outputs.instance_profile_name

  # Fleet bounds: start at 1, allow up to 3 as CPU pressure builds.
  min_size         = 1
  max_size         = 3
  desired_capacity = 1

  # Low target so a stress load reliably trips scale-out and idle reliably trips scale-in.
  target_cpu_utilization = 30

  # Install stress-ng at boot so the `load` task can burn CPU on demand with no extra setup.
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf install -y stress-ng
  EOF

  tags = {
    Environment = "lab"
  }
}
