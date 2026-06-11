---
inclusion: always
---

# Technology Stack

## Infrastructure as Code

- **Terraform** for resource definitions — these live in the **modules repo**, not here.
- **Terragrunt** for composition, DRY config, remote state, and provider generation — this is what
  labs in this repo are written in.
- Reusable modules are **never** written inline in a lab. They are referenced from the modules repo
  by a **pinned git tag**:

  ```hcl
  terraform {
    source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/vpc?ref=v1.2.0"
  }
  ```

  A local relative path is acceptable **only** while actively iterating on a not-yet-released
  module; switch to a pinned `?ref=` tag before a lab is considered "done".

## Cloud providers

- **AWS** and **GCP**.

## Languages (sample apps)

- **Python** and **Go**.
- Module correctness, where it needs asserting, is tested with **Terratest** (Go) in the modules
  repo — apply a red/green discipline to infra the same way as to app code.

## Automation

- **Task** (https://taskfile.dev) — a task runner driven by `Taskfile.yml`. It is a standalone Go
  binary; **do not assume Make**. The standard task interface is defined in the
  `taskfile-conventions` steering.

## Version pinning (required for reproducibility)

- `.terraform-version` and `.terragrunt-version` (read by [tenv](https://github.com/tofuutils/tenv))
  committed at the lab level. tenv reads these files exactly like tfenv/tgswitch — each contains a
  single version string (e.g. `1.9.5`); no change to their format is needed.
- Provider versions pinned in each module's `versions.tf` (modules repo).
- Module references pinned by git tag (`?ref=vX.Y.Z`).
- Pin the Task version in CI.

## Remote state

- Configured **once per lab** in that lab's `root.hcl` via a `remote_state` block (S3 + DynamoDB
  lock table on AWS; GCS on GCP) plus a generated `provider` block. Terragrunt auto-creates the
  state backend on first run. Each lab's `infra/` units discover the lab's root config via
  `find_in_parent_folders("root.hcl")`.
- Do **not** redefine state configuration per unit; keep it in the lab's `root.hcl`.
