# PHASE 1 of the cross-cloud VPN: the Cloud HA VPN gateway.
#
# This unit exists on its own because the peering cannot be built in one pass — AWS needs the two
# addresses Google assigns to this gateway's interfaces before it can create its customer gateways,
# and only then does AWS reveal the tunnel addresses and pre-shared keys that phase 3 needs:
#
#   gcp/vpn-gateway  ->  aws/vpn  ->  gcp/vpn-tunnels
#
# The gateway itself is free; the tunnels created in phase 3 are what get billed.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/ha-vpn-gateway?ref=gcp-ha-vpn-gateway-vX.Y.Z"
# Using a local relative path while the tag is unreleased (allowed by the tech steering while iterating).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/gcp/ha-vpn-gateway"
}

locals {
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link = "projects/mock/global/networks/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name       = "${include.root.locals.lab}-havpn"
  project_id = local.project_id
  region     = local.region
  network    = dependency.network.outputs.network_self_link
}
