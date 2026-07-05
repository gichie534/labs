# Lab-local lookup — NOT reusable infra, just the glue this lab needs: resolve the existing public
# Route 53 hosted zone (e.g. aws.richardbatyrov.com) by name so the cert and the app's DNS record can
# write into it. A data-source read, which Terragrunt `inputs` can't do at parse time, so it lives in
# its own tiny unit whose zone_id output the cert and dns-record units consume via dependency blocks.

variable "zone_name" {
  description = "Domain name of the existing public hosted zone (without a trailing dot)."
  type        = string
}

data "aws_route53_zone" "parent" {
  name         = var.zone_name
  private_zone = false
}

output "zone_id" {
  description = "ID of the parent hosted zone."
  value       = data.aws_route53_zone.parent.zone_id
}

output "zone_name" {
  description = "Name of the parent hosted zone."
  value       = data.aws_route53_zone.parent.name
}
