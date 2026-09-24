# GCP VPC hosting the TARGET GKE Autopilot cluster.
#
# The secondary ranges are what make this a VPC-native cluster: Pods draw from `pods`, Services from
# `services`. The Pod range matters to the VPN as well — it is NOT a subnet, so the Cloud Router never
# advertises it automatically, and GKE does not masquerade Pod traffic to RFC 1918 destinations. The
# gcp/vpn-tunnels unit therefore advertises it explicitly; see that unit and docs/adr/0001.
#
# Cloud NAT is still needed even with the VPN: Autopilot nodes have no external addresses and must
# reach the internet to pull the VictoriaMetrics/Grafana images. No static NAT address is reserved —
# nothing on the AWS side allowlists an egress IP any more, because the migration crosses privately.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/vpc?ref=gcp-vpc-v0.2.0"
}

locals {
  lab        = include.root.locals.lab
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

inputs = {
  name       = local.lab
  project_id = local.project_id

  subnets = [
    {
      name                = "nodes"
      region              = local.region
      ip_cidr_range       = include.root.locals.gcp_nodes_cidr
      pods_cidr_range     = include.root.locals.gcp_pods_cidr
      services_cidr_range = include.root.locals.gcp_svcs_cidr
      pods_range_name     = "pods"
      services_range_name = "services"
    },
  ]

  # Autopilot nodes have no public IPs; they egress through Cloud NAT for image pulls.
  create_nat = true
}
