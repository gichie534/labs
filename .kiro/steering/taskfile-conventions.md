---
inclusion: auto
name: taskfile-conventions
description: Conventions for Task (Taskfile.yml) automation in this labs repo. Use when creating or editing a Taskfile, automating a lab's lifecycle, or wiring the root Taskfile to a lab.
---

# Taskfile Conventions

Automation uses **Task** (`Taskfile.yml`, schema `version: '3'`). Every lab exposes the **same
standard interface** so any lab — and the repo as a whole — can be driven the same way.

## Standard task interface (per lab)

Implement these task names where applicable; keep the names identical across labs even when the
bodies differ. A lab without an app omits `build` and `deploy`.

- `default` — list tasks (`task --list`); set as the default, `silent: true`.
- `init-env` — create a local `.env` from `.env.example` (no-op if `.env` already exists, so it
  never clobbers existing values). Every lab that loads runtime inputs via dotenv includes this.
- `fmt` — `terragrunt hclfmt` plus language formatters.
- `validate` — `terragrunt run-all validate`.
- `lint` — tflint / tfsec or checkov / app linters.
- `plan` — `terragrunt run-all plan`.
- `up` — provision infra (`terragrunt run-all apply`).
- `build` — build the app (docker image, lambda zip, …).
- `deploy` — deploy the app onto the infra (kubectl/argocd for k8s; terragrunt or CLI for serverless).
- `test` — Terratest and/or app tests.
- `down` — destroy everything (`terragrunt run-all destroy`).

## Conventions

- Run infra tasks against the lab's `infra/` dir (`dir: infra`).
- Use `deps:` for prerequisites (e.g. `deploy` deps on `build` when deploy needs a fresh image).
- Use `vars:` for repeated values (region, image name, cluster name); avoid hardcoding.
- Only `up` and `deploy` create cloud resources. Never make them a silent dependency of `test`
  without intent — `fmt`, `validate`, `plan` must stay cost-free.

## Environment config via `.env` (dotenv)

A lab's runtime inputs (project ID, region, domain, state bucket, etc.) are loaded from a local
**`.env`** file using Task's built-in dotenv, not exported by hand each session. Terragrunt's
`root.hcl` reads them through `get_env(...)`, so values in `.env` flow straight into the units.

Provide a committed **`.env.example`** template documenting every variable; the real **`.env`** is
gitignored (already covered by the repo `.gitignore`). Shell-exported vars take precedence over
`.env`, and a missing `.env` is harmless (vars stay empty), so cost-free tasks still run on a clean
checkout.

Two non-obvious constraints (Task behavior — both matter):

- **A global top-level `dotenv:` is rejected in a Taskfile that another Taskfile `include`s.** Every
  lab Taskfile is included by the root one, so declare `dotenv:` **per task** instead, on each task
  that needs lab inputs (not on `default` or purely-local tasks).
- **dotenv resolves relative to the task's working dir.** Tasks that set `dir: infra` must load
  `dotenv: ['../.env']` (the lab root); tasks without `dir:` load `dotenv: ['.env']`. Both point at
  the single lab-root `.env`.

```yaml
tasks:
  init-env: # local-only, no dotenv (it creates the .env)
    desc: Create a local .env from the template (no-op if .env already exists)
    cmds:
      - |
        if [ -f .env ]; then
          echo ".env already exists — leaving it untouched."
        else
          cp .env.example .env
          echo "Created .env from .env.example — fill in your values."
        fi

  up: # runs in infra/ -> ../.env
    dir: infra
    dotenv: ['../.env']
    cmds: [terragrunt run-all apply --non-interactive]

  deploy: # runs at lab root -> .env
    dotenv: ['.env']
    cmds: [helm upgrade --install ...]
```

Document the `task <ns>:init-env` step (then edit `.env`) in the lab's README.

## Example — lab with a Go app on EKS

```yaml
version: '3'

vars:
  IMAGE: '{{.LAB}}:dev'

tasks:
  default:
    cmds: [task --list]
    silent: true

  init-env:
    desc: Create a local .env from the template (no-op if .env already exists)
    cmds:
      - |
        if [ -f .env ]; then
          echo ".env already exists — leaving it untouched."
        else
          cp .env.example .env
          echo "Created .env from .env.example — fill in your values."
        fi

  fmt:
    cmds:
      - terragrunt hclfmt
      - gofmt -w ./app

  validate:
    dir: infra
    cmds: [terragrunt run-all validate]

  plan:
    dir: infra
    cmds: [terragrunt run-all plan]

  up:
    desc: Provision infrastructure
    dir: infra
    cmds: [terragrunt run-all apply --non-interactive]

  build:
    desc: Build the app image
    cmds: [docker build -t {{.IMAGE}} ./app]

  deploy:
    desc: Deploy the app (GitOps)
    deps: [build]
    cmds: [kubectl apply -k deploy]

  test:
    cmds: [go test ./app/...]

  down:
    desc: Destroy everything
    dir: infra
    cmds: [terragrunt run-all destroy --non-interactive]
```

## Root Taskfile (repo root)

The root `Taskfile.yml` composes labs via `includes`, namespacing each so it can be driven from the
repo root. Add an entry whenever a new lab is created.

```yaml
version: '3'

includes:
  eks:
    taskfile: aws/eks-cicd/Taskfile.yml
    dir: aws/eks-cicd
  vpc:
    taskfile: aws/secure-vpc/Taskfile.yml
    dir: aws/secure-vpc

tasks:
  default:
    cmds: [task --list]
    silent: true
```

Then: `task eks:up`, `task eks:deploy`, `task vpc:plan`, etc.
