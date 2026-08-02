---
inclusion: auto
name: taskfile-conventions
description: Conventions for Task (Taskfile.yml) automation in this labs repo. Use when creating or editing a lab's Taskfile or automating a lab's lifecycle.
---

# Taskfile Conventions

Automation uses **Task** (`Taskfile.yml`, schema `version: '3'`). Every lab exposes the **same
standard interface** so any lab can be driven the same way.

Each lab's `Taskfile.yml` is **self-contained** and run from inside the lab folder
(`cd <provider>/<name> && task <name>`). There is **no root `Taskfile.yml`** composing or
namespacing labs — do not create or register anything at the repo root.

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

Declare **one top-level `dotenv: ['.env']`** at the root of the lab's `Taskfile.yml`. It loads once,
resolved relative to the lab root (where `task` is invoked, or the Taskfile's dir when run from a
subfolder), and the resulting vars are visible to every task regardless of its `dir:`. So a task
with `dir: infra` still sees the same lab-root `.env` — no `../.env` juggling.

> A single top-level `dotenv:` used to be impossible here: Task
> [rejects a top-level `dotenv:` in a Taskfile that another Taskfile `include`s](https://github.com/go-task/task/issues/1075),
> and every lab was pulled in by a root Taskfile, which forced a fragile **per-task** `dotenv:` with
> `.env` / `../.env` / `../../.env` paths tuned to each task's `dir:`. With the root Taskfile gone,
> labs are standalone, so the single top-level form is correct — do not reintroduce per-task dotenv.

```yaml
version: '3'

# Loaded once, relative to the lab root; visible to every task regardless of its `dir:`.
dotenv: ['.env']

tasks:
  init-env: # creates the .env; the top-level dotenv having found none is harmless
    desc: Create a local .env from the template (no-op if .env already exists)
    cmds:
      - |
        if [ -f .env ]; then
          echo ".env already exists — leaving it untouched."
        else
          cp .env.example .env
          echo "Created .env from .env.example — fill in your values."
        fi

  up:
    dir: infra
    cmds: [terragrunt run-all apply --non-interactive]

  deploy:
    cmds: [helm upgrade --install ...]
```

Document the `task init-env` step (then edit `.env`) in the lab's README.

## Example — lab with a Go app on EKS

```yaml
version: '3'

# Loaded once, relative to the lab root; visible to every task regardless of its `dir:`.
dotenv: ['.env']

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

Run it from inside the lab folder: `cd aws/eks-cicd && task up`, `task deploy`, `task plan`, etc.
