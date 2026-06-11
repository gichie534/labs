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

## Example — lab with a Go app on EKS

```yaml
version: '3'

vars:
  IMAGE: '{{.LAB}}:dev'

tasks:
  default:
    cmds: [task --list]
    silent: true

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
