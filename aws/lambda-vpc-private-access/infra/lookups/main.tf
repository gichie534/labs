# Lab-local lookups — NOT a reusable module, just the glue this lab needs to stay self-contained:
# resolve the latest Amazon Linux 2023 AMI and pick two availability zones for the VPC. These are
# data-source reads, which Terragrunt `inputs` can't do at parse time, so they live in their own tiny
# unit whose outputs the other units consume via dependency blocks. It creates NO resources.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Availability zones available in this region; the VPC spreads its subnets across the first two.
data "aws_availability_zones" "available" {
  state = "available"
}

output "ami_id" {
  description = "Latest Amazon Linux 2023 AMI ID for this region."
  value       = data.aws_ssm_parameter.al2023.value
  sensitive   = true
}

output "azs" {
  description = "First two available AZs for the VPC subnets."
  value       = slice(data.aws_availability_zones.available.names, 0, 2)
}
