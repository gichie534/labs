# aws-gcp/eks-gke-private-vpn

One question, nothing else: **can a Pod in GKE reach a Pod in EKS over private addressing only?**

It stands up an EKS cluster and a GKE Autopilot cluster in separate clouds, joins their VPCs with a
**BGP-routed IPsec VPN** (AWS Site-to-Site VPN ⇄ GCP HA VPN), and proves the path with an echo server
behind an **internal** load balancer. No public listener exists at any point.

The echo server reports **the client address AWS saw**, which is the part worth looking at — see
"What the test actually proves" below.

## Architecture

```
AWS  10.20.0.0/16                              GCP  nodes 10.30.0.0/20, pods 10.31.0.0/16
┌─────────────────────────────┐                ┌────────────────────────────────────────┐
│ EKS  xcvpn-source           │                │ GKE Autopilot  xcvpn-target            │
│                             │                │                                        │
│  echo-server (2 pods)       │◀───────────────│  connectivity-test Job                 │
│  echo-private-lb            │   HA VPN ⇄     │  (a Pod, calling across the VPN)       │
│  INTERNAL load balancer      │  S2S VPN, BGP  │                                        │
│  (no public listener)       │   2 tunnels    │                                        │
└─────────────────────────────┘                └────────────────────────────────────────┘
```

| Unit              | Module                 |
| ----------------- | ---------------------- |
| `aws/network`     | `aws/vpc`              |
| `aws/cluster`     | `aws/eks`              |
| `gcp/network`     | `gcp/vpc`              |
| `gcp/cluster`     | `gcp/gke`              |
| `gcp/vpn-gateway` | `gcp/ha-vpn-gateway`   |
| `aws/vpn`         | `aws/site-to-site-vpn` |
| `gcp/vpn-tunnels` | `gcp/ha-vpn-tunnels`   |

The peering is **three units** because it genuinely cannot be built in one pass: AWS needs the GCP
gateway's interface addresses, and GCP needs the tunnel addresses and pre-shared keys AWS only produces
afterwards. `gcp/vpn-gateway -> aws/vpn -> gcp/vpn-tunnels`.

## Run it

```bash
task init-env      # then edit .env
task init-state

task validate      # cost-free
task build         # cost-free: compile both Go programs
task plan          # cost-free

task up            # both VPCs, both clusters, the three-phase VPN
task vpn-status    # repeat until both tunnels are ESTABLISHED and BGP has learned 10.20.0.0/16
task kubeconfig

task deploy        # echo server on EKS behind an internal load balancer
task test          # a Pod in GKE calls it across the VPN
```

Both programs are Go (`deploy/echo/`, `deploy/probe/`), delivered as ConfigMaps and compiled in-pod by
`go run`. That keeps the lab free of a container registry, which matters more here than usual: a
connectivity lab that needed a working cross-cloud image pull before it could test connectivity would
have the dependency backwards. `go` 1.24+ is needed locally only for `task build`.

**Do not skip `task vpn-status`.** It checks BGP peer state and learned routes, not just tunnel status:
an ASN mismatch leaves tunnels `ESTABLISHED` while nothing routes.

## What the test actually proves

The echo server prints `client_address_as_seen_by_aws`. When a GKE Pod calls it, that is typically a
**GKE Pod address** (`10.31.x.x`), not a node address — because GKE does **not** masquerade Pod traffic
to RFC 1918 destinations.

Pod addresses come from a subnet **secondary** range, which is not a subnet, so a Cloud Router's
`ALL_SUBNETS` advertisement never includes it. So this response only happens because
`gcp/vpn-tunnels` advertises the Pod range explicitly. Remove that advertisement and the request
**hangs** rather than failing — AWS has no route back, and there is nothing to send a rejection with.
That hang is the single most time-consuming failure in this whole setup, which is why the test names it
in its own output.

The test also asserts that the load balancer hostname resolves to a **private** address. An AWS internal
load balancer's hostname is published in **public** DNS but resolves to a private address, so an ordinary
cluster resolver is enough and no private DNS zone is needed.

## Expected non-failures

- The **second tunnel of each AWS VPN connection stays `DOWN`**. An HA VPN interface pairs with one
  connection, so only tunnel 1 of each is used. Two connections exist because each HA VPN interface
  sources traffic from its own address and AWS accepts traffic only from the address its customer
  gateway names — one connection cannot serve both.
- Both Kubernetes **control planes** are public so `kubectl` works from anywhere. Only the control
  planes; the workload path between clusters is private-only.

## Tear down

```bash
task down
```

`down` runs `clean-k8s` first, and that order is **required**: the internal load balancer is created by
Kubernetes, so Terraform does not know it exists. Left behind, its ENIs and security groups keep the VPC
alive and `terragrunt destroy` fails partway through with a dependency violation.

> **Cost.** An EKS control plane, a NAT gateway, 2 small EC2 nodes, a GKE Autopilot cluster, Cloud NAT,
> one internal load balancer, two AWS VPN connections and two Cloud VPN tunnels. VPN connections and
> tunnels bill from creation whether or not traffic flows.

## Learned / decisions

See [`docs/adr/0001-cross-cloud-vpn-topology.md`](docs/adr/0001-cross-cloud-vpn-topology.md).
