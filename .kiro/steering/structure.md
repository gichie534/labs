---
inclusion: always
---

# Project Structure

## Repository layout

```
Taskfile.yml                # root: includes each lab's Taskfile (namespaced)
<provider>/                 # provider grouping directory (e.g. aws, gcp)
  <name>/                   # one self-contained lab (vertical slice)
    root.hcl                # this lab's root Terragrunt config: remote_state + provider generation
    .terraform-version      # pinned Terraform version (read by tenv)
    .terragrunt-version     # pinned Terragrunt version (read by tenv)
    infra/                  # Terragrunt units that compose modules from the modules repo
    app/                    # sample application (app/python or app/go) — only if the lab deploys one
    deploy/                 # k8s manifests / GitOps (Argo CD Application) — only when relevant
    docs/
      adr/                  # architecture decision records
    Taskfile.yml            # this lab's lifecycle (standard task interface)
    README.md               # what it is, how to run, what was learned
```

There is no `labs/` wrapper directory — labs are grouped by provider directly at the repo root, as
`<provider>/<name>/`. Each lab owns its own `root.hcl` (named `root.hcl`, the name Terragrunt and
tenv now recommend, not `terragrunt.hcl`); there is no shared root config at the repo root.

## Lab naming

Labs live under a provider directory and are addressed as `<provider>/<short-name>`, lowercase,
hyphenated within each segment. Examples: `aws/secure-vpc`, `aws/serverless-3tier`,
`aws/eks-cicd`, `gcp/gke-cluster`.

## Rules

- A lab is **self-contained**: everything specific to it lives inside its folder.
- A lab **never** contains reusable module source. Reusable infra is referenced from the modules
  repo by a pinned tag. The moment a second lab needs the same thing, promote it to the modules
  repo and reference it (rule of three).
- `infra/` is split into small Terragrunt units (e.g. `vpc/`, `cluster/`, `platform/`) wired with
  `dependency` blocks, not one giant unit. Each unit discovers the lab's `root.hcl` via
  `find_in_parent_folders("root.hcl")`.
- Apps go under `app/python/...` or `app/go/...`, each with its own tests.
- For Kubernetes labs, deployment is GitOps: manifests / an Argo CD `Application` under `deploy/`,
  which the cluster reconciles.
- Each lab has a `README.md` and at least one ADR explaining a non-obvious decision.