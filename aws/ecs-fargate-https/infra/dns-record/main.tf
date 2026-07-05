# Lab-local glue — NOT reusable infra: the alias A record that points the app's hostname at the ALB.
# It's a lab unit rather than a route53-module record because it's an ALIAS to a load balancer (needs
# the ALB's dns_name + zone_id), and it must be created AFTER the ALB while the parent zone is looked
# up BEFORE the cert — keeping it separate avoids a dependency cycle (zone -> cert -> alb -> record).

variable "app_domain" {
  description = "Hostname to publish (must be within the parent zone), e.g. ecs-https.aws.example.com."
  type        = string
}

variable "hosted_zone_id" {
  description = "ID of the parent hosted zone to create the record in."
  type        = string
}

variable "alb_dns_name" {
  description = "Public DNS name of the ALB to alias to."
  type        = string
}

variable "alb_zone_id" {
  description = "Route 53 hosted-zone ID of the ALB (for the alias target)."
  type        = string
}

resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

output "record_fqdn" {
  description = "FQDN of the published alias record."
  value       = aws_route53_record.app.fqdn
}
