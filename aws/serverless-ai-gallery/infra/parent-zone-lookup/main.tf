# Lab-local lookup — NOT reusable infra, just the glue this lab needs: resolve the existing public
# Route 53 parent hosted zone (e.g. aws.richardbatyrov.com) by name so the child zone this lab creates
# can be delegated from it (NS records written into the parent). A data-source read, which Terragrunt
# `inputs` can't do at parse time, so it lives in its own tiny unit whose zone_id the zone unit
# consumes via a dependency block.

variable "zone_name" {
  description = "Domain name of the existing public parent hosted zone (without a trailing dot)."
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
