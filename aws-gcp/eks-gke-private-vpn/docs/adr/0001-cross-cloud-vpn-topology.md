# 0001 — Cross-cloud VPN topology: two connections, three units, and the Pod range

Status: accepted

## Context

Two Kubernetes clusters in two clouds need to talk over private addressing. Both providers document a
BGP-routed IPsec peering: AWS Site-to-Site VPN on one side, Cloud HA VPN on the other.

The configuration looks symmetric, and is not. Three details determine whether it works, and each one
fails in a way that does not point at itself.

## Decision

Peer an AWS Site-to-Site VPN with a GCP HA VPN gateway over BGP. Expose the AWS-side workload on an
**internal** load balancer only. Advertise **both** the GKE node subnet and the GKE Pod secondary range.

## The three details

**One AWS VPN connection per HA VPN interface.** A GCP HA VPN gateway has two interfaces, and each
sources traffic from its own address. AWS accepts traffic on a connection only from the address its
customer gateway names. So a single connection physically cannot serve both interfaces — two are
required. AWS then builds two tunnels per connection, of which this topology uses tunnel 1 of each; **the
other two stay `DOWN` and that is correct.** Expect to second-guess this.

**The peering needs three apply phases.** Each side needs an address the other only produces once it
exists:

```
gcp/ha-vpn-gateway   ->  Google assigns two interface addresses
aws/site-to-site-vpn ->  configured with those; returns tunnel addresses, inside addresses, PSKs
gcp/ha-vpn-tunnels   ->  external gateway + tunnels + BGP, built from those
```

This is why `gcp/ha-vpn-gateway` is a module that creates exactly one resource. Splitting along that
seam lets ordinary `dependency` wiring express the ordering, instead of a targeted apply or a documented
two-pass ritual.

**The GKE Pod range must be advertised explicitly.** Pods draw from a subnet **secondary** range, which
is not a subnet, so `ALL_SUBNETS` never covers it. GKE also does not masquerade Pod traffic to RFC 1918
destinations, so packets reach AWS with a Pod source address AWS has no route back to. The symptom is a
**hang**, not a refusal — the slowest kind to diagnose. Advertising the Pod range alongside the node
subnet makes the path work whether or not Pod traffic is masqueraded. On Autopilot the `ip-masq-agent`
ConfigMap is not editable, so this is the only in-Terraform remedy.

A fourth, adjacent trap: **route propagation on the AWS side is a separate step from the tunnel.** Without
it the tunnels establish, BGP exchanges routes, and traffic still fails — presenting as a one-way network.
The `aws/site-to-site-vpn` module takes `route_table_ids` so this is a named input that can be forgotten
loudly rather than a step buried in a runbook.

## Consequences

- Non-overlapping CIDRs become load-bearing and are documented in `root.hcl`. Overlap makes the two sides
  unroutable in a way no VPN configuration can fix.
- `task up` returning does not mean the VPN is ready. `task vpn-status` checks **BGP peer state and
  learned routes**, because tunnel status alone is not evidence of a working path.
- Tunnels and VPN connections bill hourly from creation, traffic or not.
- Both control planes stay public for operator access; only the workload path is private. The asymmetry
  is deliberate and is the thing worth narrowing first for anything longer-lived.

## Alternatives rejected

- **Public endpoint with an IP allowlist** — simpler and cheaper, and defensible when the exposed thing is
  narrow. Rejected because the private path is this lab's entire subject.
- **Cloud Interconnect / Direct Connect** — the production answer for sustained cross-cloud traffic, but
  needs physical or partner provisioning and cannot be created and destroyed by `task up` / `task down`.
- **WireGuard or Tailscale overlay** — fewer billed resources, but moves the trust boundary into a
  third-party service or a hand-rolled relay, and the thing worth practising is the peering both cloud
  providers document.
- **One connection, both of its tunnels** — halves VPN cost and cannot work: both tunnels terminate on one
  customer gateway, which names a single GCP interface address.
