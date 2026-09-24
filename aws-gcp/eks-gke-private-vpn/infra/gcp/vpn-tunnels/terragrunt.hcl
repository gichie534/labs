# PHASE 3 of the cross-cloud VPN: the GCP tunnels and BGP, built from what AWS reported back.
#
# AWS created two connections, each with two tunnels. An HA VPN gateway pairs ONE interface with ONE
# connection, so we take tunnel 1 of each connection — two tunnels total, one per HA VPN interface.
# The second tunnel of each AWS connection stays DOWN, which is expected rather than a fault.
#
# advertised_ip_ranges carries the detail that otherwise costs an afternoon: the GKE Pod range is a
# subnet SECONDARY range, so `advertise_all_subnets` never covers it, and GKE does not masquerade Pod
# traffic to RFC 1918 destinations. Without advertising it, the migration Job's packets leave with a
# Pod source address that AWS has no route back to — the symptom is a hang, not a refusal. The node
# subnet is advertised automatically, so between the two the path works whether or not Pod traffic
# happens to be masqueraded.
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/ha-vpn-tunnels?ref=gcp-ha-vpn-tunnels-vX.Y.Z"
# Using a local relative path while the tag is unreleased (allowed by the tech steering while iterating).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/gcp/ha-vpn-tunnels"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    network_self_link = "projects/mock/global/networks/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

dependency "vpn_gateway" {
  config_path = "../vpn-gateway"

  mock_outputs = {
    self_link = "projects/mock/regions/mock/vpnGateways/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

dependency "aws_vpn" {
  config_path = "../../aws/vpn"

  mock_outputs = {
    tunnels = [
      {
        connection_index        = 0
        tunnel_index            = 1
        outside_address         = "203.0.113.11"
        cgw_inside_address_cidr = "169.254.10.2/30"
        vgw_inside_address      = "169.254.10.1"
        amazon_side_asn         = 64512
        preshared_key           = "mock-psk-0"
      },
      {
        connection_index        = 1
        tunnel_index            = 1
        outside_address         = "203.0.113.12"
        cgw_inside_address_cidr = "169.254.11.2/30"
        vgw_inside_address      = "169.254.11.1"
        amazon_side_asn         = 64512
        preshared_key           = "mock-psk-1"
      },
    ]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name       = "${include.root.locals.lab}-to-aws"
  project_id = include.root.locals.project_id
  region     = include.root.locals.region
  network    = dependency.network.outputs.network_self_link

  ha_vpn_gateway = dependency.vpn_gateway.outputs.self_link

  # NOTE: the "tunnel 1 of each connection" filter is repeated inline rather than hoisted into a
  # local, because Terragrunt evaluates `locals` BEFORE dependency outputs are available — a local
  # referencing `dependency` fails with "dependency is not defined". Ordering is preserved: the AWS
  # module emits tunnels connection-by-connection, so filtering keeps HA VPN interface N paired with
  # connection N, which is required because connection N names interface N's address.
  peer_gateway_interfaces = [
    for t in dependency.aws_vpn.outputs.tunnels : t.outside_address if t.tunnel_index == 1
  ]

  tunnels = [
    for i, t in [for x in dependency.aws_vpn.outputs.tunnels : x if x.tunnel_index == 1] : {
      vpn_gateway_interface           = i
      peer_external_gateway_interface = i
      router_interface_ip_range       = t.cgw_inside_address_cidr # this side, with prefix
      peer_ip_address                 = t.vgw_inside_address      # the BGP neighbour on the AWS side
      peer_asn                        = t.amazon_side_asn
    }
  ]

  tunnel_shared_secrets = [
    for t in dependency.aws_vpn.outputs.tunnels : t.preshared_key if t.tunnel_index == 1
  ]

  bgp_asn = include.root.locals.gcp_bgp_asn

  # The Pod range is a secondary range, so nothing advertises it for us.
  advertised_ip_ranges = [
    {
      range       = include.root.locals.gcp_pods_cidr
      description = "GKE Pod range — where the migration Job's packets actually come from"
    },
  ]
}
