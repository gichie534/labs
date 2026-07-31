# Public Cloud DNS zone for the Argo CD hostname, delegated from the existing parent zone.
#
# Single-phase (unlike the classic-Ingress sibling lab): because the Gateway attaches a reserved
# GLOBAL static IP (the address unit) rather than an ephemeral LB IP, the apex A record is known at
# `up` time and created here directly. Certificate Manager validates via a DNS-authorization CNAME
# (independent of the IP), which this unit also publishes from the certs unit's output.
#
# Records created:
#   - apex "" A            -> the reserved Gateway IP (address unit)
#   - cert DNS-auth CNAME  -> from the certs unit (validation_records; keys are stable at plan time)
# Plus the NS delegation written into the existing parent zone so the subdomain is reproducible.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id         = include.root.locals.project_id
  argocd_domain      = include.root.locals.argocd_domain
  parent_dns_zone    = include.root.locals.parent_dns_zone
  parent_dns_project = include.root.locals.parent_dns_project

  # Cloud DNS managed-zone resource name derived from the domain (dots -> hyphens), e.g.
  # "argocd.gcp.example.com" -> "argocd-gcp-example-com".
  zone_name = replace(local.argocd_domain, ".", "-")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/cloud-dns?ref=gcp-cloud-dns-v0.3.0"
}

dependency "address" {
  config_path = "../address"

  mock_outputs = {
    address = "203.0.113.10"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "certs" {
  config_path = "../certs"

  mock_outputs = {
    dns_authorization_records = {
      server = { name = "_acme.example.com.", type = "CNAME", data = "abc.authorize.certificatemanager.goog." }
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id = local.project_id
  name       = local.zone_name
  dns_name   = "${local.argocd_domain}."
  visibility = "public"

  # Apex A record -> the reserved global Gateway IP. Keyed by "" = zone apex.
  records = {
    "" = { type = "A", ttl = 60, rrdatas = [dependency.address.outputs.address] }
  }

  # Certificate Manager DNS-authorization CNAME(s). The cert module emits { name, type, data };
  # adapt `data` to cloud-dns's `rrdatas`. Keyed by the stable cert label so for_each keys are
  # known at plan time.
  validation_records = {
    for label, rec in dependency.certs.outputs.dns_authorization_records :
    label => {
      name    = rec.name
      type    = rec.type
      rrdatas = [rec.data]
    }
  }

  # Reproducible subdomain delegation: write this zone's NS record into the existing parent zone,
  # tracking the zone's current name servers across destroy/recreate. The parent zone may live in a
  # separate bootstrap project.
  delegate_to_parent_zone = {
    zone_name  = local.parent_dns_zone
    project_id = local.parent_dns_project
  }
}
