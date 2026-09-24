# PHASE 2 of the cross-cloud VPN: the AWS side.
#
# Consumes the two interface addresses of the GCP HA VPN gateway and creates one customer gateway plus
# one VPN connection per address. Two connections rather than one is not redundancy theatre: each HA
# VPN interface sources traffic from its OWN address, and AWS accepts traffic only from the address its
# customer gateway names, so one connection physically cannot serve both interfaces.
#
# route_table_ids is the input whose absence is hardest to debug: without route propagation the
# tunnels establish, BGP exchanges routes, and traffic still fails — looking like a one-way network
# rather than a missing route. It is wired to every PRIVATE route table, which is where the EKS nodes
# and their pods live.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/site-to-site-vpn?ref=aws-site-to-site-vpn-v0.1.0"
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id                  = "vpc-mock"
    private_route_table_ids = { mock-az = "rtb-mock" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

dependency "gcp_vpn_gateway" {
  config_path = "../../gcp/vpn-gateway"

  mock_outputs = {
    # Documentation-range placeholders: real, valid public addresses are required for the customer
    # gateways, and these make a `plan` on a clean checkout parse without inventing plausible ones.
    interface_ip_addresses = ["203.0.113.1", "203.0.113.2"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name   = "${include.root.locals.lab}-to-gcp"
  vpc_id = dependency.network.outputs.vpc_id

  peer_gateway_ip_addresses = dependency.gcp_vpn_gateway.outputs.interface_ip_addresses

  peer_bgp_asn    = include.root.locals.gcp_bgp_asn
  amazon_side_asn = include.root.locals.amazon_side_asn

  # Without this, nothing in the VPC has a route back to GCP.
  route_table_ids = values(dependency.network.outputs.private_route_table_ids)

  tags = {
    Role = "cross-cloud-vpn"
  }
}
