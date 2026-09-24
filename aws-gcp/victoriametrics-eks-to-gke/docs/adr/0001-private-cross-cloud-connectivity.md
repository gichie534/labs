# 0001 — Join EKS and GKE with a BGP-routed IPsec VPN, not a public endpoint

Status: accepted

## Context

The migration needs a process in the GKE (target) cluster to read VictoriaMetrics and VictoriaLogs in
the EKS (source) cluster. Those two live in different clouds, in different private address spaces.

The obvious shortcut is to expose the source's two HTTP APIs on internet-facing load balancers and
restrict them by source IP. It works, and an earlier lab in this repo
(`aws-gcp/rds-to-cloudsql-postgres`) does exactly that, allowlisting the target's static Cloud NAT
egress address.

## Decision

Join the two VPCs with an **AWS Site-to-Site VPN peered to a GCP HA VPN gateway over BGP**, and give the
source's VictoriaMetrics and VictoriaLogs **internal** load balancers only. No data-plane endpoint is
reachable from the internet at any point.

Three new modules were added to the catalog for this, rather than inlining the VPN into the lab:
`aws/site-to-site-vpn`, `gcp/ha-vpn-gateway`, `gcp/ha-vpn-tunnels`.

## Why

**An IP allowlist is not the same class of control as unroutability.** The allowlist approach leaves a
public listener in front of a database that holds everything you know about your systems, with a single
misconfigured CIDR between the internet and it. The VPN removes the listener from the internet
altogether. For a lab whose subject is moving observability data, "the data path was never public" is
worth the extra moving parts.

**Two AWS VPN connections, not one.** A GCP HA VPN gateway has two interfaces, and each sources traffic
from its **own** address. AWS accepts traffic on a connection only from the address its customer gateway
names. So one connection physically cannot serve both interfaces. AWS then creates two tunnels per
connection; this lab uses tunnel 1 of each, giving two tunnels across two interfaces. **The second
tunnel of each AWS connection stays `DOWN`, and that is correct** — it is the single most likely thing
to be mistaken for a fault here.

**Three Terragrunt units, because the peering genuinely cannot be built in one pass.** AWS needs the
GCP gateway's interface addresses before it can create customer gateways; GCP needs the tunnel
addresses, inside addresses and pre-shared keys that AWS only produces afterwards:

```
gcp/vpn-gateway  ->  aws/vpn  ->  gcp/vpn-tunnels
```

Splitting the modules along that seam means the ordering is expressed by ordinary `dependency` blocks
instead of a targeted apply or a documented two-pass ritual. It is why `gcp/ha-vpn-gateway` is a module
that creates exactly one resource.

## The two details that cost the most time to discover

**GKE Pod addresses are not covered by subnet advertisement.** Pods draw from a subnet **secondary**
range, which is not a subnet, so a Cloud Router's `ALL_SUBNETS` advertisement never includes it. GKE
also does not masquerade Pod traffic to RFC 1918 destinations, so the migration Job's packets arrive at
AWS with a **Pod** source address that AWS has no route back to. The failure mode is a **hang**, not a
refusal, which is the slowest kind to diagnose. The fix is to advertise the Pod range explicitly via
`advertised_ip_ranges`; the node subnet is advertised automatically, so between the two the path works
whether or not Pod traffic happens to be masqueraded. On Autopilot the `ip-masq-agent` ConfigMap is not
editable, so this is the only in-Terraform remedy.

**Route propagation is a separate step from the tunnel.** Without `aws_vpn_gateway_route_propagation`
the tunnels establish, BGP exchanges routes, and traffic still fails — presenting as a one-way network
rather than a missing route. The `aws/site-to-site-vpn` module takes `route_table_ids` specifically so
this is a named input that can be forgotten loudly rather than a step buried in a runbook.

A useful consequence of EKS's VPC CNI: pods get **real VPC addresses**, so the routes advertised over
BGP reach the source's pods directly. The internal load balancers exist only to provide a **stable**
address, not to bridge a network boundary.

## Consequences

- Cost rises by roughly **$0.20/hour**: two AWS VPN connections at ~$0.05/h and two Cloud VPN tunnels at
  ~$0.05/h, billed from creation whether or not they carry traffic.
- `task up` is not finished when Terraform returns. Tunnels take a couple of minutes to establish and
  BGP a little longer to settle, hence `task vpn-status` — which checks **BGP peer state and learned
  routes**, not just tunnel status, because an ASN mismatch leaves tunnels `ESTABLISHED` while nothing
  routes.
- The CIDR plan becomes load-bearing and is documented in `root.hcl`. Overlapping ranges would make the
  two sides unroutable in a way no amount of VPN configuration can fix.
- Both Kubernetes **control planes** keep public endpoints (`0.0.0.0/0`) so `kubectl` works from
  anywhere. This is a deliberate lab tradeoff and the asymmetry is the point: the control planes are
  public, the **data path** is not. Narrow `endpoint_public_access_cidrs` and
  `master_authorized_networks` for anything longer-lived.

## Alternatives rejected

- **Public endpoints with an IP allowlist** — cheaper and simpler, and genuinely fine for the RDS lab,
  where the exposed thing was a single database being cut over once. Rejected here because the subject
  of this lab is the private path.
- **Cloud Interconnect / Direct Connect** — the production answer for sustained cross-cloud traffic, but
  it needs physical or partner provisioning and cannot be stood up and destroyed by `task up` / `task
  down`.
- **A WireGuard or Tailscale overlay** — fewer billed resources and less BGP, but it moves the trust
  boundary into a third-party service or a hand-rolled relay, and the thing worth practising here is the
  cloud-native peering both providers document.
- **One AWS VPN connection with both of its tunnels** — halves the VPN cost, but cannot work: both
  tunnels of a connection terminate on one customer gateway, which names a single GCP interface address.
