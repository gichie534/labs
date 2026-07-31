# 0001 — Google Workspace SSO (Dex) + multi-tenant RBAC on Argo CD

- Status: accepted
- Date: 2026-07-31

## Context

This lab extends `gke-argocd` (GKE Autopilot + Argo CD via kustomize, Gateway API + Certificate
Manager, app-of-apps) with two capabilities: single sign-on through Google Workspace / Cloud
Identity, and multi-tenancy so different kinds of users get different permissions. The base lab is
unchanged; this is a separate, self-contained lab (see the base lab's discussion on why a new lab
rather than a toggle).

## Decisions

### SSO via Argo CD's bundled Dex, Google connector (not direct OIDC)

Google's OIDC ID tokens do **not** carry group membership. Since multi-tenancy here is group-based,
we use Argo CD's bundled **Dex** with its **Google connector**, which queries the **Admin SDK
Directory API** for a user's groups and passes them to Argo CD as a `groups` claim. Direct Google
OIDC (no Dex) was rejected because it can't produce groups, only per-email RBAC.

Consequences: the connector needs (a) an OAuth 2.0 **Web client**, (b) a service account with
**domain-wide delegation** authorized for `admin.directory.group.readonly` +
`admin.directory.user.readonly`, and (c) a super-admin email to impersonate. Two of these are
**manual Google steps** with no Terraform resource: creating the OAuth web client, and authorizing
the SA's DWD scopes in the Workspace Admin console.

### Keyless via Workload Identity, not a service-account key

Dex's Google connector supports two ways to authenticate as the directory SA: a mounted JSON **key
file** (`serviceAccountFilePath`), or **GKE Workload Identity** (Dex > v2.34.0). We use Workload
Identity: the `argocd-dex-server` KSA is bound to the directory GSA (`roles/iam.workloadIdentityUser`),
the KSA is annotated `iam.gke.io/gcp-service-account`, and Dex authenticates with no key at all.
Keyless is strictly better — no long-lived credential to store, rotate, or leak. Keyless
domain-wide delegation signs the per-user assertion via the IAM Credentials API (`signJwt`), so the
GSA is granted `serviceAccountTokenCreator` on itself and that API is enabled. GKE Autopilot always
runs with Workload Identity enabled, so no cluster change is needed.

### Multi-tenancy via AppProjects + RBAC groups

Tenancy is two `AppProject`s (`team-a`, `team-b`), each locked to its own namespace and this repo.
`argocd-rbac-cm` maps Workspace groups to roles: an admins group to the built-in `role:admin`, and
one scoped role per project (`role:team-a`/`role:team-b`) that can act only on Applications in that
project. `policy.default` is deny, so a user with no mapped group can log in but see nothing.

### Secrets in Secret Manager, injected at deploy time (not GitOps, not in Git)

The only long-lived secret is the OAuth client secret (the Dex→Directory auth is keyless via
Workload Identity). It lives in **GCP Secret Manager** (the `sso-secrets` unit creates it); `task
deploy` reads it and creates the `argocd-google-sso` k8s Secret, which Argo CD resolves through its
`$<secret>:<key>` interpolation. No secret is ever committed or rendered into a manifest.

### Platform config is operator-applied; only the tenant layer is GitOps

Unlike the base lab (where the app-of-apps self-manages the whole Argo CD install), here the platform
overlay (`deploy/argocd`) carries **identity values** — the Argo CD URL, OAuth client id, admin
email, and Workspace group emails. To keep the real domain/identities out of Git, those are written
as `__TOKENS__` and filled from `.env` at deploy time (`kubectl kustomize | sed | apply`). Because
that render can't be reproduced by Argo CD from Git, the platform is applied by the operator, and the
**app-of-apps manages only the domain-free tenant layer** (AppProjects + sample apps). This mirrors a
real split: a platform team owns the control-plane config; GitOps delivers tenant workloads.

## Consequences / tradeoffs

- Two unavoidable manual Google steps (OAuth client, DWD scope authorization) gate a clean run.
- Argo CD no longer fully self-manages its own install (the base lab does) — a deliberate trade to
  keep identities out of Git.
- The `0.0.0.0/0` control-plane exposure tradeoff is inherited from the base lab.
