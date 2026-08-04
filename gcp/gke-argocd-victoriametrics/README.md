# gcp/gke-argocd-victoriametrics

A regional GKE Autopilot cluster running **Argo CD** (public HTTPS, **direct Google SSO**) that
GitOps-installs a **VictoriaMetrics** observability stack — **VMSingle** (metrics), **Grafana**
(Google OAuth, public HTTPS, with VictoriaMetrics + VictoriaLogs datasources), **VictoriaLogs** plus
its **collector**, and a **sample log/metric generator**. Public DNS is managed by **external-dns**.

Everything Argo CD reconciles lives in a **separate private repo** (so your domain/identities aren't
in this public lab). All secrets come from **Secret Manager** via the **GKE managed Secret Manager
add-ons** — never hand-created, never committed, keyless via Workload Identity.

## How it fits together

```
 this lab (public)                          your private infra repo (GitOps source)
 ─────────────────                          ────────────────────────────────────────
 infra/  Terraform units:                   argocd-install/ Argo CD install + SSO/RBAC + repo conn + SecretSyncs
   network, cluster (+ SM add-ons),         root-app/       app-of-apps
   certs, dns,                              infrastructure/ argocd (self-manage), external-dns,
   secrets/{argocd-oidc,grafana-oauth,                      vm-k8s-stack, victoria-logs(+collector), platform, generators
            github-app}  (SM containers)    manifests/      Gateway + routes, generators
   iam/{argocd-secret-sync,grafana,
        external-dns}    (workload GSAs)
 private-repo-template/  ──── task init-infra-repo ────▶  (renders into your private repo)
 Taskfile, docs, README
```

Secret delivery (all from Secret Manager, keyless, nothing hand-created or in Git):

| Secret                      | Mechanism                                          | Consumed as                      |
| --------------------------- | -------------------------------------------------- | -------------------------------- |
| Grafana OAuth client secret | Secret Manager **CSI add-on** (file mount)         | `grafana.ini` `$__file{...}`     |
| Argo CD OIDC client secret  | **SecretSync** → k8s Secret `argocd-oidc`          | `$argocd-oidc:oidc.clientSecret` |
| GitHub App repo credential  | **SecretSync** → `repository` Secret `github-repo` | Argo CD repo connection          |

## Prerequisites

A GCS state bucket, an existing parent DNS zone (in a **different** project from `GCP_PROJECT`),
`terraform`/`terragrunt` via tenv, `gcloud`, `kubectl`, Task, and a **private Git repo** for the
GitOps manifests. Cluster is GKE 1.33+ (required by the SecretSync add-on; Autopilot on a current
release channel satisfies this).

### Manual one-time setup
1. Two **OAuth 2.0 Web clients** (Cloud console): Argo CD (redirect `https://argocd.<BASE_DOMAIN>/auth/callback`)
   and Grafana (redirect `https://grafana.<BASE_DOMAIN>/login/google`).
2. A **GitHub App** installed on your private repo (Contents: read-only); note its App ID +
   Installation ID and download its **private key** `.pem`.

The three secret values (two client secrets + the App key) are seeded into Secret Manager by
Terraform — the client secrets from `.env`, the App key from the `.pem` path (gitignored).

## Run it

```bash
task init-env                 # then edit .env

task init-infra-repo          # render private-repo-template into $INFRA_REPO_DIR from .env
cd "$INFRA_REPO_DIR" && git init && git add -A && git commit -m init && git push   # to your private repo
cd -                          # back to the lab

task init-state
task validate                 # cost-free
task up                       # infra: cluster (+ SM add-ons), certs, DNS zone, SM secret containers + IAM
task seed-secrets             # push the secret VALUES into the containers (from .env / the .pem)
task creds
task deploy                   # install Argo CD from $INFRA_REPO_DIR/argocd-install + apply the app-of-apps
task verify                   # wait for the LB IP + managed certs + DNS, GET both HTTPS endpoints
```

- **Argo CD** `https://argocd.<BASE_DOMAIN>` — LOG IN VIA GOOGLE (`ARGOCD_ADMIN_EMAIL` = admin, others
  read-only; `task password` for break-glass local admin).
- **Grafana** `https://grafana.<BASE_DOMAIN>` — Sign in with Google (`GRAFANA_ADMIN_EMAIL` = Admin).
  Explore the VictoriaMetrics datasource (avalanche) and VictoriaLogs (flog).

## Tear down

```bash
task down
```

Deletes the app-of-apps + Argo CD, purges external-dns's DNS records (it's `upsert-only`), then
`terragrunt destroy`.

## Notes / caveats

- **Only the GitOps bootstrap is imperative** (install Argo CD + apply the root app). No secret or
  ServiceAccount is ever created by hand; secrets flow from Secret Manager via the add-ons.
- **CSI/SecretSync access is keyless**: each KSA (`observability/grafana`, `argocd/argocd-secret-sync`,
  `external-dns/external-dns`) is annotated to impersonate a GSA (created by the `gcp/workload-iam`
  module) that holds the grants — no service-account keys.
- **node-exporter is disabled** (GKE Autopilot blocks its host mounts); vmagent still scrapes the
  kubelet/cAdvisor + kube-state-metrics.
- `INFRA_REPO_DIR` must be pushed to the private repo before `task deploy` (Argo CD reads it remotely
  via the GitHub App; `task deploy` applies `argocd-install/` from your local checkout).
- The VictoriaLogs service is `victoria-logs-single-server.observability.svc:9428` (used by the
  collector + Grafana datasource); if you rename that Application, update both.

## Learned / decisions

See `docs/adr/0001-observability-with-external-dns.md`.
