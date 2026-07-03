# Lab-local lookups — NOT a reusable module, just the glue this lab needs to stay self-contained:
# resolve the latest Amazon Linux 2023 AMI and read the account's default VPC + its subnets. These
# are data-source reads, which Terragrunt `inputs` can't do at parse time, so they live in their own
# tiny unit whose outputs the downstream units consume via dependency blocks.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC (default-VPC subnets auto-assign public IPs, so instances reach the
# SSM endpoints over the internet gateway with no NAT). The ALB needs subnets in >=2 AZs; the default
# VPC provides one per AZ.
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

output "vpc_cidr_block" {
  description = "Primary CIDR of the default VPC — used to scope the app security group to in-VPC (ALB) traffic only."
  value       = data.aws_vpc.default.cidr_block
}

output "subnet_ids" {
  description = "Subnets in the default VPC (for the ALB and the instances)."
  value       = data.aws_subnets.default.ids
}
