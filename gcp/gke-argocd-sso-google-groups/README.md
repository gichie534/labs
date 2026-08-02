# gcp/gke-argocd-sso-google-groups

The [`gke-argocd`](../gke-argocd) lab **plus Google Workspace SSO and multi-tenant RBAC**. A regional
GKE Autopilot cluster runs a production-ready (HA) Argo CD, exposed on a public HTTPS endpoint via the
Gateway API + a Google-managed Certificate Manager cert. Users sign in with their **Google Workspace**
identity (Argo CD's bundled **Dex**, Google connector), and their **Workspace group** membership maps
to Argo CD roles so different tenants get different permissions.

## What's added on top of the base lab

- **SSO** — Dex Google connector reads a user's Workspace groups via the Admin SDK Directory API,
  authenticating **keylessly** through GKE Workload Identity (no service-account key).
- **Multi-tenancy** — two `AppProject`s (`team-a`, `team-b`), each locked to its own namespace, with
  `argocd-rbac-cm` mapping groups → roles (admins group → full admin; each team group → scoped to its
  own project). A sample app per tenant demonstrates the isolation.
- **Secret in Secret Manager** — the one long-lived secret (the OAuth client secret) lives in GCP
  Secret Manager (`sso-secrets` unit); `task deploy` injects it into the cluster. Nothing sensitive
  is in Git.

## Architecture

```
   Google Workspace ──identity+groups──▶ Dex (in-cluster) ──▶ Argo CD (OIDC + RBAC)
        │  (Admin SDK Directory API, via a domain-wide-delegated SA)
        ▼
        │  (keyless: dex KSA -> directory GSA via Workload Identity)
   client ─https─▶ Gateway (global external ALB, certmap "argocd") ─▶ argocd-server
                                                                        │ app-of-apps
                                                     ┌──────────────────┴───────────────────┐
                                               AppProject team-a                     AppProject team-b
                                               (ns team-a, sample app)               (ns team-b, sample app)
```

Infra units under `infra/` (pinned to modules-repo tags, except the two inline glue units):

| Unit          | Source                                                            | Pinned tag                       |
| ------------- | ----------------------------------------------------------------- | -------------------------------- |
| `network`     | `gcp/vpc`                                                         | `gcp-vpc-v0.1.0`                 |
| `cluster`     | `gcp/gke` (regional Autopilot)                                    | `gcp-gke-v0.2.0`                 |
| `address`     | inline `google_compute_global_address`                            | — (lab-local)                    |
| `certs`       | `gcp/certificate-manager`                                         | `gcp-certificate-manager-v0.1.0` |
| `dns`         | `gcp/cloud-dns`                                                   | `gcp-cloud-dns-v0.3.0`           |
| `sso-secrets` | inline (directory SA + Workload Identity + APIs + Secret Manager) | — (lab-local)                    |

## Prerequisites

Everything from the base lab (GCS state bucket, existing parent DNS zone, `terraform`/`terragrunt`
via tenv, `gcloud`, `kubectl`, Task), **plus** you must be a **Google Workspace super-admin** for the
domain, and complete two manual Google steps below.

### Manual step 1 — create the OAuth 2.0 Web client (before `up`)

In the **Cloud Console** (`console.cloud.google.com`, not the Admin console), under **Google Auth
Platform** — this is where OAuth clients now live (the old *APIs & Services → Credentials* path):

1. **Branding** — if prompted, configure the consent screen and set **Audience: Internal** (so only
   your Workspace users can log in).
2. **Clients → Create client → Application type: Web application**. Set the **Authorized redirect
   URI** to:

   ```
   https://<ARGOCD_DOMAIN>/api/dex/callback
   ```

3. Put the resulting client id/secret into `.env` (`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`).

### Manual step 2 — authorize domain-wide delegation (after `up`)

`up` creates the Dex directory-reader service account. Print its client id and authorize it in the
**Admin console → Security → API controls → Domain-wide delegation**:

```bash
task dwd-id
# authorize that client_id for scopes:
#   https://www.googleapis.com/auth/admin.directory.group.readonly
#   https://www.googleapis.com/auth/admin.directory.user.readonly
```

## Configure `.env`

```bash
task init-env
$EDITOR .env
```

Variables (see `.env.example`): the base set (`GCP_PROJECT`, `GCP_REGION`, `TF_STATE_BUCKET`,
`ARGOCD_DOMAIN`, `PARENT_DNS_ZONE`, `PARENT_DNS_PROJECT`) plus SSO:
`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `DEX_ADMIN_EMAIL` (a super-admin to impersonate), and the
Workspace group emails `ADMIN_GROUP`, `TEAM_A_GROUP`, `TEAM_B_GROUP`. Group emails live only in
`.env` — they're filled into the committed manifests as tokens at deploy time, so the Workspace
domain never lands in Git.

## Stand it up

```bash
# 0. create the OAuth Web client (manual step 1) and fill in .env
task init-state
task validate            # cost-free
task up                  # infra + Dex SA + Secret Manager secrets

task dwd-id              # manual step 2: authorize DWD in the Admin console

task creds
task deploy              # inject SM secrets, render+apply Argo CD, apply app-of-apps
task verify              # wait for the Gateway IP + managed cert, GET the HTTPS endpoint
```

Then open `https://<ARGOCD_DOMAIN>` and choose **LOG IN VIA GOOGLE**. What each user sees:

- a member of `ADMIN_GROUP` → full admin (both tenants),
- a member of `TEAM_A_GROUP` → only the `team-a-hello` app in project `team-a`,
- a member of `TEAM_B_GROUP` → only the `team-b-hello` app in project `team-b`,
- anyone else → logs in but sees nothing (default deny).

The local `admin` user still works for break-glass (`task password`).

## Tear it down

```bash
task down
```

## Security caveats

- Inherits the base lab's `0.0.0.0/0` control-plane exposure (lab-only).
- Dex authenticates to the Directory API **keylessly** via Workload Identity — no service-account
  key is ever created.
- SSO/RBAC config is operator-applied (rendered from `.env`), not GitOps — see the ADR.

## Learned / decisions

See `docs/adr/0001-sso-and-multitenancy.md` for why Dex (not direct OIDC), why the platform config is
operator-applied while only the tenant layer is GitOps, and how secrets stay in Secret Manager and
out of Git.
