# Lab-local lookups — NOT a reusable module, just the glue this lab needs to stay self-contained:
# resolve the latest Amazon Linux 2023 AMI and pick a subnet from the account's default VPC. These
# are data-source reads, which Terragrunt `inputs` can't do at parse time, so they live in their own
# tiny unit whose outputs the `instance` units consume via a dependency block.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# Public subnets in the default VPC (default-VPC subnets auto-assign public IPs), so the instances
# can reach the SSM endpoints over the internet gateway with no NAT.
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

output "subnet_id" {
  description = "A subnet in the default VPC to launch the instances in."
  value       = data.aws_subnets.default.ids[0]
}
