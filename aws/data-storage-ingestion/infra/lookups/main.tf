# Lab-local lookups — NOT a reusable module, just the glue this lab needs to stay self-contained:
# pick the availability zones the VPC spreads its subnets across. This is a data-source read, which
# Terragrunt `inputs` can't do at parse time, so it lives in its own tiny unit whose outputs the other
# units consume via dependency blocks. It creates NO resources.

# Availability zones usable in this region. THREE are taken rather than the usual two because Redshift
# Serverless refuses to create a workgroup with fewer than three subnets across three AZs.
data "aws_availability_zones" "available" {
  state = "available"

  # Exclude opt-in (Local/Wavelength) zones, which cannot host a Redshift Serverless workgroup.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

output "azs" {
  description = "First three available AZs for the VPC subnets — the minimum Redshift Serverless accepts."
  value       = slice(data.aws_availability_zones.available.names, 0, 3)
}
