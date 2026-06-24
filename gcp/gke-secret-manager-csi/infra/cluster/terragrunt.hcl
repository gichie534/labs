# Regional GKE Autopilot cluster, with two independent cluster features both turned on:
#   - Secret Manager add-on (secret_manager_config) — installs the GKE-managed Secrets Store CSI
#     Driver + GCP provider (driver name secrets-store-gke.csi.k8s.io). Powers the volume mount.
#   - SecretSync (secret_sync_config) — installs the SecretSync controller, which materializes a
#     Secret Manager secret as a Kubernetes Secret consumed via valueFrom.secretKeyRef / envFrom.
#     Powers the env-var consumption.
#
# Neither feature requires the other on the GKE side; they're documented as independent (and as
# alternatives to each other for projects that only need one path). The lab enables both to
# demonstrate both consumption patterns in a single Deployment:
#   - secret as a tmpfs file (CSI volume)            -> Secret Manager add-on
#   - secret as an env var (valueFrom.secretKeyRef)  -> SecretSync
#
# Autopilot has Workload Identity Federation for GKE on by default, which the CSI driver and the
# SecretSync controller use to authenticate to Secret Manager as the pod's KSA.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so a developer (or CI) can reach the
# public control-plane endpoint to run kubectl. Lab-only.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/gke?ref=gcp-gke-v0.2.0"
}

dependency "network" {
  config_path = "../network"

  # Lets `plan`/`validate` run before the network exists (cost-free checks).
  mock_outputs = {
    network_self_link  = "projects/mock/global/networks/mock"
    subnets_self_links = { nodes = "projects/mock/regions/mock/subnetworks/nodes" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name       = "gke-secret-manager-csi"
  project_id = local.project_id
  region     = local.region

  network             = dependency.network.outputs.network_self_link
  subnetwork          = dependency.network.outputs.subnets_self_links["nodes"]
  pods_range_name     = "pods"
  services_range_name = "services"

  # Public endpoint reachable by the developer; nodes remain private. Lab-only.
  enable_private_endpoint = false
  master_authorized_networks = [
    { display_name = "world", cidr_block = "0.0.0.0/0" },
  ]

  # The whole point of the lab.
  enable_secret_manager_addon = true
  enable_secret_sync          = true

  # The lab is meant to be torn down with `task csi:down`.
  deletion_protection = false
}
