# The IAM identity attached to every instance the Auto Scaling group launches.
#
# One deliberately minimal grant: AmazonSSMManagedInstanceCore (managed), which lets you reach each
# instance via SSM Session Manager and run commands on it — so the lab can push a synthetic CPU load
# onto the fleet (to trip scale-out) and release it (to trip scale-in) with no SSH key and no inbound
# port 22. That command-driven load is how the whole scaling demo is exercised.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/iam-instance-profile?ref=aws-iam-instance-profile-v0.1.0"
}

inputs = {
  name = "asg-cpu-scaling-lab"

  # Reach the instances via SSM Session Manager / send-command — no SSH key, no inbound rules.
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  tags = {
    Environment = "lab"
  }
}
