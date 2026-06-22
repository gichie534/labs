# Public Cloud DNS zone for the app's hostname, delegated from the existing parent zone.
#
# Two-phase by necessity (Option A: classic GKE Ingress + ManagedCertificate). The external
# Application Load Balancer's IP is EPHEMERAL — it doesn't exist until the Ingress is deployed — so
# the apex A record cannot be created at `up` time. This unit therefore:
#
#   phase 1 (`task gke-ingress:up`):  create the child zone + write the NS delegation into the parent
#                                     zone (INGRESS_IP unset -> no A record yet).
#   phase 2 (`task gke-ingress:dns`): re-apply with INGRESS_IP set to the LB IP read from the
#                                     deployed Ingress -> the apex A record is added/updated.
#
# Keeping the A record in Terraform (rather than a raw gcloud write) preserves reproducibility: the
# record is state-managed and torn down cleanly with the zone.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id         = include.root.locals.project_id
  ingress_domain     = include.root.locals.ingress_domain
  parent_dns_zone    = include.root.locals.parent_dns_zone
  parent_dns_project = include.root.locals.parent_dns_project

  # The LB IP, supplied in phase 2. Empty in phase 1 (zone + delegation only).
  ingress_ip = get_env("INGRESS_IP", "")

  # Cloud DNS managed-zone resource name derived from the domain (dots -> hyphens), e.g.
  # "gke-ingress.gcp.richardbatyrov.com" -> "gke-ingress-gcp-richardbatyrov-com".
  zone_name = replace(local.ingress_domain, ".", "-")

  # Apex A record only once the IP is known (phase 2). Keyed by "" = zone apex.
  records = local.ingress_ip == "" ? {} : {
    "" = { type = "A", ttl = 60, rrdatas = [local.ingress_ip] }
  }
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/cloud-dns?ref=gcp-cloud-dns-v0.3.0"
}

inputs = {
  project_id = local.project_id
  name       = local.zone_name
  dns_name   = "${local.ingress_domain}."
  visibility = "public"

  records = local.records

  # Reproducible subdomain delegation: write this zone's NS record into the existing parent zone,
  # tracking the zone's current name servers across destroy/recreate. The parent zone lives in a
  # separate bootstrap project, so the delegation is written there via project_id.
  delegate_to_parent_zone = {
    zone_name  = local.parent_dns_zone
    project_id = local.parent_dns_project
  }
}
