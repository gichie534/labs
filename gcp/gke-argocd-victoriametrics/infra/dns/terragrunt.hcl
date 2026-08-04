# Public Cloud DNS zone for $BASE_DOMAIN, delegated from the existing parent zone. Terraform
# publishes ONLY the stable records: the two Certificate Manager DNS-authorization CNAMEs. The
# hostname A records (argocd.$BASE_DOMAIN, grafana.$BASE_DOMAIN) are created dynamically by
# external-dns from the Gateway/HTTPRoutes — that is the whole point of running external-dns, so
# they are deliberately absent here. See docs/adr/0001.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id         = include.root.locals.project_id
  base_domain        = include.root.locals.base_domain
  parent_dns_zone    = include.root.locals.parent_dns_zone
  parent_dns_project = include.root.locals.parent_dns_project

  zone_name = replace(local.base_domain, ".", "-")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/cloud-dns?ref=gcp-cloud-dns-v0.3.0"
}

dependency "certs" {
  config_path = "../certs"

  mock_outputs = {
    dns_authorization_records = {
      argocd  = { name = "_acme.argocd.example.com.", type = "CNAME", data = "a.authorize.certificatemanager.goog." }
      grafana = { name = "_acme.grafana.example.com.", type = "CNAME", data = "b.authorize.certificatemanager.goog." }
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_id = local.project_id
  name       = local.zone_name
  dns_name   = "${local.base_domain}."
  visibility = "public"

  # No A records here: external-dns owns argocd.* and grafana.* dynamically.
  records = {}

  # Certificate Manager DNS-authorization CNAMEs (stable, one per managed cert).
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
