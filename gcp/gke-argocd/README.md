# gcp/gke-argocd

Provisions a regional **GKE Autopilot** cluster from the shared modules repo and installs a
**production-ready (HA) Argo CD** on it with **kustomize**, exposed on a **public HTTPS endpoint** via
the **Gateway API** (`gke-l7-global-external-managed`, a global external Application Load Balancer)
with a **Google-managed Certificate Manager** certificate attached through the
`networking.gke.io/certmap` annotation. A single **app-of-apps** root Application then makes Argo CD
self-manage its own install and front door from Git.

Argo CD's hostname is the apex of a **delegated Cloud DNS zone** (e.g. `argocd.gcp.example.com`) the
lab creates and delegates from your existing parent zone. The Kubernetes manifests are deliberately
**hostname-agnostic** — the real domain lives only in your `.env`, never in committed GitOps files.

## Architecture

```
                         client
                           │ https://argocd.gcp.example.com
                           ▼
   Cloud DNS (child zone, delegated from parent) ── A ──▶ reserved global static IP
                           │                                   │
                           │                          Gateway (gke-l7-global-external-managed)
                           │                          TLS: Certificate Manager certmap "argocd"
                           │                          HTTP:80 ─301─▶ HTTPS:443
                           ▼                                   │  HTTPRoute → NEG → Pod IPs
                 GKE Autopilot cluster  ◀── argocd-server (insecure/HTTP behind the LB) ─┘
                           ▲
                  Argo CD (HA) ── app-of-apps ──▶ self-manages deploy/argocd from this repo
```

Infra is composed as small Terragrunt units under `infra/`, each sourced from the modules repo by a
pinned tag (except `address`, a single lab-specific glue resource kept inline):

| Unit      | Module / source                        | Pinned tag                       |
| --------- | -------------------------------------- | -------------------------------- |
| `network` | `gcp/vpc`                              | `gcp-vpc-v0.1.0`                 |
| `cluster` | `gcp/gke` (regional Autopilot)         | `gcp-gke-v0.2.0`                 |
| `address` | inline `google_compute_global_address` | — (lab-local)                    |
| `certs`   | `gcp/certificate-manager`              | `gcp-certificate-manager-v0.1.0` |
| `dns`     | `gcp/cloud-dns`                        | `gcp-cloud-dns-v0.3.0`           |

`cluster` depends on `network`; `dns` depends on `address` (apex A record) and `certs` (DNS-auth
CNAME). Argo CD itself is pinned to **v3.4.5** via the kustomize remote base in `deploy/argocd`.

## Prerequisites

- A GCP project and a GCS bucket for Terraform state (`task init-state` creates it).
- An **existing public parent zone** in Cloud DNS (e.g. `gcp.example.com`) whose delegation already
  works (your registrar / DNS provider points at it).
- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `kubectl` (provides `kubectl kustomize`),
  and Task installed.

Configure the lab via a local **`.env`** (loaded automatically by Task's dotenv):

```bash
task init-env   # seeds .env from .env.example
$EDITOR .env           # fill in project, region, domain, parent zone, state bucket
```

`.env` is gitignored; shell exports take precedence; a missing `.env` is harmless for cost-free
tasks. Variables the lab reads:

```bash
GCP_PROJECT=my-project
GCP_REGION=us-central1
TF_STATE_BUCKET=my-tf-state-bucket
ARGOCD_DOMAIN=argocd.gcp.example.com   # apex of the delegated child zone
PARENT_DNS_ZONE=gcp-example-com        # Cloud DNS managed-zone NAME of the parent zone
PARENT_DNS_PROJECT=my-bootstrap-project # project owning the parent zone (omit if same as GCP_PROJECT)
```

> `PARENT_DNS_ZONE` is the parent zone's Cloud DNS **resource name**, not its domain:
> `gcloud dns managed-zones list --project "$PARENT_DNS_PROJECT" --format='table(name,dnsName)'`

## Stand it up

```bash
task init-state   # one-time: GCS bucket for Terraform state
task validate     # cost-free
task plan         # cost-free
task up           # VPC, Autopilot cluster, reserved IP, managed cert, delegated DNS zone

task creds        # kube-context for the cluster
task deploy       # kubectl apply -k deploy/argocd, wait, then apply the app-of-apps root
task verify       # wait for the Gateway IP + managed cert, then GET the HTTPS endpoint
task password     # initial admin password (username: admin)
```

After `deploy`, Argo CD manages itself: the `root` Application syncs `deploy/apps/`, whose
`argocd` child Application reconciles `deploy/argocd`. Add more workloads by dropping additional child
`Application` manifests under `deploy/apps/`.

## Tear it down

```bash
task down   # delete the Argo CD apps/install (removes the Gateway/LB), then destroy all infra
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` so operators/CI can run the one-time
  `kubectl apply -k` bootstrap. Deliberate lab-only tradeoff. See the ADR.
- Argo CD is installed with `server.insecure=true` because TLS is terminated at the Gateway by the
  Google-managed cert; the server never sees plaintext from the internet.

## Learned / decisions

See `docs/adr/0001-argocd-gateway-gitops.md` for why kustomize (not Helm), why Gateway API + certmap
(not Ingress + ManagedCertificate), why a reserved static IP gives single-phase DNS, why the
app-of-apps self-manages Argo CD, and why the manifests are kept hostname-agnostic.
