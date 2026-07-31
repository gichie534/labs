# 0001 — Argo CD on GKE via kustomize, exposed with Gateway API + Certificate Manager

- Status: accepted
- Date: 2026-07-31

## Context

This lab stands up a production-flavoured Argo CD on GKE and exposes it on a public HTTPS endpoint.
Several decisions had real alternatives worth recording.

## Decisions

### Install Argo CD with kustomize (upstream HA base), not Helm

The sibling GKE labs deploy their app with Helm. Here we install Argo CD straight from its upstream
`manifests/ha/cluster-install` kustomize base, pinned by tag (`?ref=v3.4.5`). Rationale: it is the
Argo-CD-native, GitOps-native packaging (the same manifests Argo CD can later sync itself), needs no
extra chart repo, and the HA variant gives the "production-ready" topology (redis-ha + replicated
server/repo-server/applicationset) out of the box. GKE Autopilot supplies the capacity automatically.

### Expose with the Gateway API, not classic Ingress

We use a `gke-l7-global-external-managed` **Gateway** + **HTTPRoute** rather than a classic Ingress.
Gateway API is the direction GKE steers new workloads, cleanly separates the load-balancer (Gateway)
from routing (HTTPRoute), and lets one Gateway/cert front many routes later.

### TLS via Certificate Manager certmap, not a ManagedCertificate CRD or a Secret

TLS uses a Google-managed **Certificate Manager** cert, DNS-authorized, attached to the Gateway with
the `networking.gke.io/certmap` annotation. Per GKE docs, an HTTPS listener that uses certmap has
**no `tls` block** (the two are mutually exclusive). We chose certmap over:

- a Kubernetes Secret (self-managed cert — we want Google-managed auto-renewal), and
- the `ManagedCertificate` CRD (the Gateway controller does **not** support it — that is an
  Ingress-only path).

DNS authorization (rather than load-balancer authorization) means the cert validates independently
of the LB IP, which enables the single-phase DNS below.

### Reserved global static IP → single-phase DNS

The Gateway pins a reserved `google_compute_global_address` by name (`NamedAddress`). Because the IP
exists before the Gateway, the apex A record is created at `up` time — no two-phase "deploy, read the
ephemeral IP, then publish DNS" dance that the ephemeral-IP sibling lab needs. It also survives
teardown/recreate. The single address resource is lab-specific glue, so it lives inline in the
`address` unit rather than being promoted to the modules catalog (rule of three).

### app-of-apps that self-manages Argo CD

A single root Application (`deploy/bootstrap/root-app.yaml`) watches `deploy/apps/`, whose one child
Application points Argo CD back at its own install path (`deploy/argocd`). After the one-time
`kubectl apply -k` bootstrap, Argo CD manages itself and its front door from Git — drift is
reconciled, and new workloads are added by dropping another child Application under `deploy/apps/`.
`ServerSideApply=true` avoids the client-side "annotations too long" failure on Argo CD's CRDs.

### Hostname-agnostic manifests (keep the domain out of Git)

The Gateway and both HTTPRoutes carry **no** hostname. The real domain lives only in Terraform inputs
(from `.env`), used by the `certs` (SNI) and `dns` (A record) units. The cert is matched by SNI at
the edge; the routes forward whatever host resolves to the Gateway IP. This keeps the committed
GitOps manifests generic and reproducible, and avoids leaking the private DNS zone.

## Consequences / tradeoffs

- The cluster control-plane endpoint is opened to `0.0.0.0/0` so operators/CI can run the one-time
  bootstrap. Deliberate lab-only tradeoff, inherited from the sibling GKE labs.
- First managed-cert issuance can take 10–20 minutes; `task argocd:verify` polls for it.
- Self-managed Argo CD can briefly disrupt itself during a self-upgrade — acceptable for a lab.
