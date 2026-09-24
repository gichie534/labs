# The TARGET GKE Autopilot cluster: it runs its OWN VictoriaMetrics/VictoriaLogs stack, collecting
# its own metrics and logs from the moment it exists. The migration therefore has to MERGE the
# source's history into a live database rather than replace its storage — which is precisely why this
# lab migrates over the APIs instead of copying data directories. See
# docs/adr/0002-api-migration-not-filesystem-copy.md.
#
# The migration Job runs here, reaching the source's private addresses over the VPN.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so your kubectl reaches the control plane from
# anywhere. Only the CONTROL PLANE is public; the observability data path is private-only.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.3.0"
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link  = "projects/mock/global/networks/mock"
    subnets_self_links = { nodes = "projects/mock/regions/mock/subnetworks/nodes" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name       = "${include.root.locals.lab}-target"
  project_id = local.project_id
  region     = local.region

  network             = dependency.network.outputs.network_self_link
  subnetwork          = dependency.network.outputs.subnets_self_links["nodes"]
  pods_range_name     = "pods"
  services_range_name = "services"

  enable_private_endpoint = false
  master_authorized_networks = [
    { display_name = "operators-and-world", cidr_block = "0.0.0.0/0" },
  ]

  # Must not overlap the VPC ranges or anything advertised over the VPN.
  master_ipv4_cidr_block = "172.16.0.0/28"

  # Give the nodes their own identity, holding exactly roles/container.defaultNodeServiceAccount.
  #
  # Not cosmetic. Left unset, GKE runs nodes as the project's Compute Engine default service account,
  # which on a project created after Google stopped auto-granting roles/editor holds NO roles at all.
  # Nodes then boot, fail to register, and get deleted again, so the cluster reports RUNNING with a
  # blank node count while every pod — kube-dns and metrics-server included — sits Pending with
  # "no nodes available to schedule pods". This lab hit exactly that; see docs/adr/0003.
  create_node_service_account = true

  deletion_protection = false

  resource_labels = {
    lab  = "victoriametrics-eks-to-gke"
    role = "migration-target"
  }
}
