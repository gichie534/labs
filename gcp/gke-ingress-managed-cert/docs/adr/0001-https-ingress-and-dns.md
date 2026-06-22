# 0001 — Public HTTPS via classic GKE Ingress, managed cert, and a delegated DNS zone

Status: accepted
Date: 2026-06-19

## Context

This lab extends `gcp/gke-autopilot-helm`: same regional Autopilot cluster, registry, keyless CI via
direct Workload Identity Federation, and push-based Helm deploy. What's new is a **public HTTPS
endpoint** — the Go "hello world" server is reachable at `https://<INGRESS_DOMAIN>` (apex of a
delegated Cloud DNS zone, e.g. `gke-ingress.gcp.richardbatyrov.com`) with a Google-managed TLS
certificate and an HTTP→HTTPS redirect.

Several choices here had real alternatives.

## Decisions

### Classic Ingress + ManagedCertificate CRD (not Gateway + Certificate Manager)

GKE offers two managed-TLS paths and they are not interchangeable:

- **Classic Ingress** (`kubernetes.io/ingress.class: gce`) uses the **ManagedCertificate CRD**
  (`networking.gke.io/managed-certificates`). Per current GCP docs, classic Ingress **does not
  support Certificate Manager** certificates.
- **Gateway API** (`gke-l7-global-external-managed`) supports **Certificate Manager** via the
  `networking.gke.io/certmap` annotation.

This lab deliberately takes the **classic Ingress + ManagedCertificate** path. It is the simplest
thing that yields a public HTTPS Ingress, and it matches the literal "ingress" objective. A planned
v2 will implement the **Gateway API + Certificate Manager** variant (and will actually exercise the
catalog's `certificate-manager` module, which this variant does not). The catalog's
`certificate-manager` README claim that GKE *Ingress* uses `certmap` is inaccurate for current GKE —
that annotation is a Gateway feature.

Consequence: this lab does **not** use the `gcp/certificate-manager` module. The cert is a Kubernetes
CRD shipped in the Helm chart, not Terraform-managed.

### Ephemeral LB IP, published as an A record in a second phase

We do **not** reserve a static IP (no `kubernetes.io/ingress.global-static-ip-name`). GKE allocates
an **ephemeral** global IP bound to the load balancer's lifecycle. That is acceptable for a
throwaway lab and keeps the infra smaller (no address module).

The cost is a **two-phase** stand-up, because the IP doesn't exist until the Ingress is deployed and
the managed cert validates by **load-balancer authorization** (it only goes Active *after* the
domain already resolves to the LB IP):

1. `up` — infra + the public child zone + parent delegation (no A record yet).
2. `deploy` — app + Ingress + ManagedCertificate; the LB gets its ephemeral IP.
3. `dns` — read the Ingress IP and re-apply the `dns` unit with `INGRESS_IP` set, publishing the
   apex A record. Kept in Terraform (not a raw `gcloud` write) so it's state-managed and torn down
   with the zone.
4. `verify` — wait for the cert to go Active and DNS to resolve, then `GET https://<domain>`.

A production setup that needs a stable IP up front would reserve a global address in Terraform and
feed its name to the Ingress, collapsing this to a single phase. That belongs in a reusable
`gcp/global-address` module, intentionally out of scope here.

### Reproducible subdomain delegation (cloud-dns v0.3.0)

The app host is the **apex of a child zone** delegated from the existing parent zone
(`gcp.richardbatyrov.com`). GCP assigns fresh name servers every time the child zone is created, so a
one-time manual NS delegation would silently break on the next teardown/recreate.

To keep the lab reproducible, the `gcp/cloud-dns` module was extended (new tag
`gcp-cloud-dns-v0.3.0`) with a `delegate_to_parent_zone` input: when set, it writes the child zone's
`NS` record into the named parent managed zone using the child's own current name servers. The
delegation is rewritten in lock-step with the zone, so destroy/recreate never leaves a stale NS
record. This is a genuinely reusable DNS primitive ("delegate a subdomain"), so it was promoted to
the catalog rather than inlined in the lab.

### Container-native load balancing (ClusterIP + NEG)

The Service is `ClusterIP` annotated with `cloud.google.com/neg: '{"ingress": true}'`. GKE Ingress on
a VPC-native cluster (Autopilot always is) routes through **Network Endpoint Groups** straight to Pod
IPs — the production default — rather than via NodePort/kube-proxy.

### Taskfile owns stand-up; CI owns the app loop

The **Taskfile** runs the full one-time stand-up (`up` → `deploy` → `dns` → `verify`). The **GitHub
Action** is the steady-state app loop (build → push → deploy → verify HTTPS). We deliberately did
**not** grant the CI federated principal `roles/dns.admin` or state-bucket write just to publish one
A record — that would widen CI's blast radius well beyond what shipping an image needs. The Ingress
and its ephemeral IP persist across CI helm-upgrades, so the operator-published A record and managed
cert stay valid; CI only ships new image versions and re-tests. CI keeps the same minimal roles as
the reference lab: `artifactregistry.writer` + `container.developer`.

### master_authorized_networks = 0.0.0.0/0 (inherited lab-only tradeoff)

Same as the reference lab: the control-plane endpoint is opened so GitHub-hosted runners can reach it
to run `helm`. Lab-only; tear down when finished.

## Consequences

- HTTPS is live only after the two-phase flow completes; first managed-cert issuance can take
  10–20 minutes.
- The lab depends on these module tags: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`,
  `gcp-artifact-registry-v0.2.0`, `gcp-workload-identity-federation-v0.2.1`, and the new
  `gcp-cloud-dns-v0.3.0`.
- The `gcp/certificate-manager` module is unused here by design; it returns in the Gateway-API v2.
