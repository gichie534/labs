---
inclusion: manual
---

# Playbook: Create a new lab from scratch

Invoke with `#new-lab` (or the `/new-lab` slash command). If the provider, short name, and
app choice (none / python / go) aren't given, ask for them first. Follow the `structure`,
`tech`, and `taskfile-conventions` steering throughout.

## 1. Scaffold the folder (vertical slice)

Create `<provider>/<name>/` (grouped by provider directly at the repo root, e.g. `gcp/gke-cluster/`;
there is no `labs/` wrapper):

```
root.hcl                    # this lab's root Terragrunt config: remote_state + provider generation
.terraform-version          # pinned Terraform version (read by tenv)
.terragrunt-version         # pinned Terragrunt version (read by tenv)
infra/                      # Terragrunt units
docs/adr/0001-context.md    # first decision record
README.md
Taskfile.yml
app/                        # only if the lab deploys an app (app/python or app/go)
deploy/                     # only if the app runs on k8s (manifests / Argo CD Application)
```

## 2. Wire infra to the modules repo

- For each piece of infrastructure, create a small Terragrunt unit under `infra/`
  (e.g. `infra/vpc/terragrunt.hcl`).
- Source each unit from the **modules repo by pinned tag**:

  ```hcl
  terraform {
    source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/<provider>/<module>?ref=vX.Y.Z"
  }

  inputs = {
    # ...
  }
  ```

- Compose units with `dependency` blocks (e.g. `cluster` consumes `vpc` outputs) rather than one
  large unit.
- If a needed module does not exist yet, record it as a TODO in the README and either reference a
  local path temporarily **or** implement it in the modules repo first. Never inline reusable module
  code into the lab.

## 3. Remote state

- Create the lab's `root.hcl` with the `remote_state` block + provider generation. Each `infra/`
  unit discovers it via `find_in_parent_folders("root.hcl")`. Do not redefine state config per unit.

## 4. App (if any)

- Put code under `app/python/...` or `app/go/...`, each with its own tests.
- For k8s labs, put manifests / an Argo CD `Application` under `deploy/` and use GitOps — the
  cluster's Argo CD reconciles `deploy/`.

## 5. Automation

- Add `Taskfile.yml` per the `taskfile-conventions` steering (standard interface).
- Register the lab in the root `Taskfile.yml` `includes:` with a short namespace.
- Load the lab's runtime inputs from a `.env` file (committed `.env.example` template, gitignored
  `.env`) via per-task `dotenv:` — see the dotenv section in `taskfile-conventions`.

## 6. Documentation

- `README.md`: one-paragraph purpose, an architecture sketch, the exact `task` commands to stand it
  up and tear it down, and which module versions it pins.
- `docs/adr/0001-*.md`: record the first non-obvious decision (why this topology, why these modules).

## 7. Pin & verify

- Add/confirm `.terraform-version` and `.terragrunt-version` (read by tenv — a single version
  string each).
- Verify the dry path with no cloud cost: `task <ns>:fmt`, `task <ns>:validate`, `task <ns>:plan`.

## Acceptance criteria

- The lab folder is self-contained — everything it involves is visible inside it.
- All reusable infra is referenced from the modules repo by a pinned `?ref=` tag (no copied source).
- The standard Task interface works and the lab is registered in the root Taskfile.
- `README.md` and at least one ADR exist.
