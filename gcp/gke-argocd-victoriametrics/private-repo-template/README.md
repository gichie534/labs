# private-repo-template

This is a **template** for the private Git repository that Argo CD reconciles for the
`gcp/gke-argocd-victoriametrics` lab. It carries the environment- and identity-specific manifests
(your domain, OAuth client ids, admin emails, GitHub App ids, project id) — which is exactly why it
belongs in a **private** repo, not the public labs repo.

You do not edit these files by hand. From the lab folder run:

```bash
task init-infra-repo    # renders this template into $INFRA_REPO_DIR, filling values from .env
```

Then commit and push `$INFRA_REPO_DIR` to your private repo, and continue with `task up` / `task deploy`.

## Layout

```
argocd-install/    # Argo CD install (HA) + SSO/RBAC + the private-repo connection (GitHub App) +
                   # the two SecretSync resources (Argo CD OIDC secret + GitHub App key). Applied
                   # once, imperatively, by `task deploy` — Argo CD can't install itself.
root-app/          # the app-of-apps root Application (reconciles infrastructure/ from this repo)
infrastructure/    # one Argo CD Application per component: argocd (self-manages argocd-install/),
                   # platform, external-dns, vm-k8s-stack, victoria-logs-single,
                   # victoria-logs-collector, generators
manifests/         # raw resources the Applications point at (Gateway + routes; the generators)
```

## How secrets reach the cluster (never hand-created, never committed)

All three secrets live in Secret Manager (seeded by the lab's Terraform) and are delivered keylessly
via Workload Identity — no service-account keys, no GSAs, no `kubectl create secret`:

- **Grafana OAuth client secret** → mounted as an in-memory **file** by the Secret Manager CSI add-on
  (`SecretProviderClass` in `vm-k8s-stack` `grafana.extraObjects`); `grafana.ini` reads it via
  `$__file{...}`.
- **Argo CD OIDC secret** and the **GitHub App repo credential** → materialized into k8s Secrets by
  the **SecretSync** controller (`argocd-install/secretsync-*.yaml`), because Argo CD needs real
  Secrets. The repo credential is a full `secret-type: repository` Secret (`github-repo`) assembled
  from the four Secret Manager entries (url + App id + installation id + private key).
