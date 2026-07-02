# Lab-local lookups — NOT a reusable module, just the glue this lab needs to stay self-contained:
# resolve the latest Amazon Linux 2023 AMI and list the subnets of the account's default VPC. These
# are data-source reads, which Terragrunt `inputs` can't do at parse time, so they live in their own
# tiny unit whose outputs the `asg` unit consumes via a dependency block.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC (default-VPC subnets auto-assign public IPs), so instances can reach
# the SSM endpoints over the internet gateway with no NAT. Spreading the ASG across them gives it
# multiple AZs to launch into as it scales out.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

output "ami_id" {
  description = "Latest Amazon Linux 2023 AMI ID for this region."
  value       = data.aws_ssm_parameter.al2023.value
  sensitive   = true
}

output "vpc_id" {
  description = "Default VPC ID."
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "Subnets in the default VPC for the ASG to launch instances into."
  value       = data.aws_subnets.default.ids
}
