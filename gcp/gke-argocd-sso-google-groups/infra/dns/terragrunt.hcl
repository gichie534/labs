# Public Cloud DNS zone for the Argo CD hostname, delegated from the existing parent zone. Publishes
# the apex A record (-> reserved Gateway IP) and the cert DNS-authorization CNAME. Same as the base
# lab (single-phase, thanks to the reserved IP).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id         = include.root.locals.project_id
  argocd_domain      = include.root.locals.argocd_domain
  parent_dns_zone    = include.root.locals.parent_dns_zone
  parent_dns_project = include.root.locals.parent_dns_project

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

  records = {
    "" = { type = "A", ttl = 60, rrdatas = [dependency.address.outputs.address] }
  }

  validation_records = {
    for label, rec in dependency.certs.outputs.dns_authorization_records :
    label => {
      name    = rec.name
      type    = rec.type
      rrdatas = [rec.data]
    }
  }

  delegate_to_parent_zone = {
    zone_name  = local.parent_dns_zone
    project_id = local.parent_dns_project
  }
}
