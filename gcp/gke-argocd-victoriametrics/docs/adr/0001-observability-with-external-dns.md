# 0001 — VictoriaMetrics observability on Argo CD, exposed via external-dns

- Status: accepted
- Date: 2026-08-02

## Context

This lab is a sibling of `gke-argocd-sso-google-groups`: same GKE Autopilot + Argo CD +
Gateway API + Certificate Manager foundation, but a different objective. Here Argo CD GitOps-installs
the **VictoriaMetrics** observability stack (metrics + logs + Grafana) and both Argo CD and Grafana
are published on public HTTPS endpoints whose DNS is managed by **external-dns**.

## Decisions

### SSO via direct Google OIDC (no Dex, no groups)

The groups lab needed Dex because Google's OIDC token doesn't carry group membership. This lab has
**no group-based multi-tenancy** — it only needs "who is an admin". Google's ID token already carries
`email`, so we drop Dex entirely and point Argo CD's built-in OIDC at `accounts.google.com`.

RBAC is email-based: `argocd-rbac-cm` sets `scopes: '[email]'` (treat the email claim as the `g,`
subject), `policy.default: role:readonly` (anyone in the Workspace who signs in can look but not
touch), and one `g, <ADMIN_EMAIL>, role:admin` line. This removes the entire domain-wide-delegation
apparatus (directory-reader SA, Admin SDK, the second manual Google step) that the groups lab needed.

Consequence: still **one manual Google step** — create the OAuth 2.0 Web clients (Google exposes no
Terraform resource for them). This lab needs **two** clients (Argo CD and Grafana) because their
redirect URIs differ (`/auth/callback` vs `/login/google`).

### external-dns for the A records (explicitly wanted), Terraform for the stable records

`external-dns` watches the Gateway API `HTTPRoute`s and writes the hostname **A records** into the
lab's Cloud DNS zone dynamically, following the Gateway's assigned IP. That means **no reserved
static IP** and no A records in Terraform (the groups lab had both).

The split with Terraform is deliberate: Terraform still creates the **managed zone**, its
**delegation** from the parent, and the **Certificate Manager DNS-authorization CNAMEs** — these are
stable and independent of the load-balancer IP, so a controller adds no value there. external-dns
owns only the volatile A (and its TXT ownership) records.

external-dns authenticates to Cloud DNS **keylessly** via Workload Identity — its KSA impersonates a
GSA granted `roles/dns.admin` (via the `gcp/workload-iam` module) — and runs `policy=upsert-only`
so it never deletes a record it didn't create.
The flip side is teardown: `task down` purges the zone's non-NS/SOA records with `gcloud` before
Terragrunt destroys the (now empty) zone.

> Alternative considered: keep the groups lab's approach (reserved IP + Terraform A records, no
> external-dns). Rejected because exercising external-dns is an explicit goal of this lab.

### One shared Gateway (`common`) for two hostnames

A single global external Gateway fronts both services (one load balancer, one IP, two SNI-matched
certs in one Certificate Manager map). It's named **`common`** and lives in its own **`platform`**
namespace, because neither Argo CD nor Grafana owns it. The Argo CD `HTTPRoute` (ns `argocd`) and the
Grafana `HTTPRoute` (ns `observability`, created by the Grafana chart) both attach to it across
namespaces (`allowedRoutes.namespaces.from: All`), so each route keeps its backend in its own
namespace and no `ReferenceGrant` is needed.

### VictoriaMetrics via GitOps; node-exporter disabled on Autopilot

The observability stack is delivered by the app-of-apps as Helm `Application`s: `victoria-metrics-k8s-stack`
(VMSingle + vmagent + kube-state-metrics + Grafana), `victoria-logs-single`, `victoria-logs-collector`
(a vlagent DaemonSet), and the sample generators. Alerting components are disabled to stay minimal.

`prometheus-node-exporter` is **disabled**: GKE Autopilot blocks the host mounts / hostPID it
requires. vmagent still scrapes the kubelet/cAdvisor and kube-state-metrics, so cluster and node
metrics are still collected. Grafana gets two datasources: the auto-provisioned VictoriaMetrics one
plus a **VictoriaLogs** datasource (the `victoriametrics-logs-datasource` plugin) pointed at the
VictoriaLogs service.

### A private repo holds the GitOps manifests; this lab only templates it

Everything Argo CD reconciles carries environment/identity values (domain, OAuth client ids, admin
emails, GitHub App ids, project id). Rather than commit those to the public labs repo or render them
imperatively with `sed`, they live in a **separate private repo**. The lab ships a
`private-repo-template/` and a `task init-infra-repo` generator that renders it once from `.env` into
the user's private-repo checkout (a one-time scaffold, not ongoing templating). Argo CD then
GitOps-reconciles that private repo. Because the repo is private, real values are committed there
plainly.

Argo CD also **self-manages**: an `argocd` child Application points back at the `argocd-install/`
overlay it was bootstrapped from (ServerSideApply, selfHeal), so after the one-time `task deploy` any
drift in the Argo CD install / SSO / SecretSync config is reconciled from Git rather than by kubectl.

### Secrets come from Secret Manager via the GKE managed add-ons — never hand-created, never in Git

The earlier iterations created k8s Secrets imperatively (`gcloud … | kubectl create secret`), which
undercuts a GitOps demo. This lab instead enables the cluster's two managed Secret Manager features
(`enable_secret_manager_addon` + `enable_secret_sync` on the `gcp/gke` module) and delivers every
secret from Secret Manager:

- **Grafana OAuth client secret** → mounted as an in-memory **file** by the CSI add-on (a
  `SecretProviderClass` in the chart's `grafana.extraObjects`); `grafana.ini` reads it via
  `$__file{...}`. No k8s Secret object at all.
- **Argo CD OIDC client secret** and **GitHub App private key** → materialized into k8s Secrets by
  the **SecretSync** controller. Argo CD requires real Secrets here (`$secret:key` interpolation and
  the `repositories` `githubAppPrivateKeySecret` reference can't read files), so SecretSync is the
  closest to "no plain secret" the tool allows: the Secret is controller-managed from Secret Manager,
  never committed, never `kubectl create`d. The OIDC Secret is labelled `part-of: argocd` (supported
  by `SecretSync.secretObject.labels`) so Argo CD will resolve it.

All three read paths are **keyless**: the consuming KSAs (`observability/grafana`,
`argocd/argocd-secret-sync`, `external-dns/external-dns`) are annotated to impersonate a GSA created
by the **`gcp/workload-iam`** catalog module, which holds the `secretmanager.secretAccessor` /
`roles/dns.admin` grants — no service-account keys. The only imperative acts left are installing
Argo CD and applying the app-of-apps (engine bootstrap, not secret handling).

> Alternative considered: External Secrets Operator. Rejected in favour of the GKE-native add-ons
> (nothing to self-install/manage) and the CSI file-mount for Grafana (no k8s Secret at all).

### Secrets/IAM are small Terragrunt units over catalog modules; values seeded out-of-band

Following the repo rule that labs compose catalog modules in small units (not inline Terraform), the
secret material is split:

- `infra/secrets/{argocd-oidc,grafana-oauth,github-app,github-app-id,github-app-installation-id,github-repo-url}/`
  — one unit each, sourcing the **`gcp/secret-manager`** module (an empty container). The last four
  are the fields SecretSync assembles into the Argo CD `repository` Secret.
- `infra/iam/{argocd-secret-sync,grafana,external-dns}/` — one unit each, sourcing the
  **`gcp/workload-iam`** module (a GSA + Workload Identity binding + the accessor / `dns.admin`
  grants), wired to the secret units via `dependency` blocks.

The secret **values** are **not** in Terraform. The `secret-manager` module intentionally creates
only the container ("value added out-of-band by apps/CI"), so `task seed-secrets` pushes the values
(from `.env` / the `.pem`) with `gcloud secrets versions add`. This keeps secret material out of
Terraform state entirely — a deliberate security win, not just a module constraint. Required project
APIs are enabled once by `task init-state`.

### GitHub App for the private-repo credential, as a repository Secret from Secret Manager

Argo CD reads the private repo via a **GitHub App**. Argo CD only accepts repository credentials as a
Secret labelled `argocd.argoproj.io/secret-type: repository` with the fields inline — the legacy
`argocd-cm` `repositories` list does not support GitHub App via a secret reference (it silently fails
to authenticate). So the credential is a full repository Secret (`github-repo`) that **SecretSync
assembles from four Secret Manager entries**: `url`, `githubAppID`, `githubAppInstallationID`, and
`githubAppPrivateKey`. Only the private key is truly sensitive; the other three are stored in Secret
Manager too so one keyless mechanism owns the whole Secret (SecretSync can't mix in static data).
There's **no bootstrap secret step** — the credential materializes from Secret Manager like the rest.

## Consequences / tradeoffs

- Two manual Google steps (two OAuth Web clients) + a GitHub App creation gate a clean run.
- The lab spans two repos (public lab + private GitOps repo); `task init-infra-repo` keeps that a
  single generate-and-push step for users.
- CSI/SecretSync mounts are blocking — if Workload Identity/IAM isn't ready, the consuming pods wait
  on the mount. Fine for a lab, worth knowing.
- Teardown must purge external-dns's records before the DNS zone can be destroyed (handled in `down`).
- The `0.0.0.0/0` control-plane exposure tradeoff is inherited from the base cluster (lab-only).
