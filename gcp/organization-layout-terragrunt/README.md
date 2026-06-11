# GCP Organization Layout — Lean Directory-as-Hierarchy

This directory tree is the GCP org hierarchy. Each directory is a node, and each node is a
small `terragrunt.hcl` that includes one shared template. Parent IDs flow to children automatically through a
single dependency declared in the templates.

Requires **Terragrunt >= 1.0** (relies on `get_terragrunt_dir()` inside a shared include resolving against the
including unit, so the parent dependency can be DRY'd into the template).

## Layout

Top-level folders live directly at the repo root (there is no `hierarchy/` wrapper). Each top-level directory
is a folder under the organization; nesting directories deeper nests folders/projects deeper.

```
.
├── root.hcl                      # org_id, billing_account, provider, remote state
├── _envcommon/
│   ├── root-folder.hcl           # folder under the org (static parent, NO dependency)
│   ├── folder.hcl                # folder under a folder (parent = directory above)
│   └── project.hcl               # project in a folder (folder_id = directory above)
├── security/                     # root folder
│   └── audit/                    # project
└── workloads/                    # root folder
    └── production/               # nested folder
        └── app/                  # project
            └── compute-engine/   # resource unit (compute-engine, vpc, gke, gcs, ...)
```

## What a node looks like

A folder or project node is ~8 lines — include root, include the right template, set its own values:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/project.hcl"
}

inputs = {
  name       = "ProductionApp"
  project_id = "my-prod-app"
}
```

The template supplies the module source (a versioned module from the `infrastructure-catalog` git repo) and
wires the parent:

- `root-folder.hcl` → `parent = "organizations/<org_id>"` (no dependency)
- `folder.hcl` / `project.hcl` → `dependency "parent" { config_path = "${get_terragrunt_dir()}/.." }`, and
  the parent's `id` output becomes `parent` (for folders) or `folder_id` (for projects)

## Why this is lean / low-coupling

- **One source of parentage: the directory tree.** A node's parent is always the directory above it. Moving a
  subtree re-parents everything under it automatically. No keys, no maps, no `parent_key` wiring.
- **Dependencies only where a real generated ID exists.** Root folders depend on nothing (org ID is a static
  string from `root.hcl`). Only nested folders and projects have a dependency, and it's declared once per type
  in `_envcommon/`, not repeated per node.
- **High cohesion.** Everything about a node lives in its directory; everything common lives in `_envcommon/` and
  `root.hcl`.
- **`run --all` works.** Every node is `terragrunt.hcl`, so discovery and the DAG work out of the box.

## Adding a node

- New folder under the org: make a directory at the repo root, add a `terragrunt.hcl` including
  `_envcommon/root-folder.hcl`, set `display_name`.
- New nested folder: make a directory under a folder node, include `_envcommon/folder.hcl`, set `display_name`.
- New project: make a directory under a folder node, include `_envcommon/project.hcl`, set `name` + `project_id`.
- New resource (compute-engine/vpc/gke/gcs): make a directory under a project node, depend on
  `"${get_terragrunt_dir()}/.."`, read `dependency.<name>.outputs.project_id`.

## Deploy

Fill in / confirm the `root.hcl` values (`org_id`, `billing_account`, state bucket/project), then from the
repo root:

```sh
terragrunt run --all apply     # creates the org tree top-down following the directory DAG
```

Or apply a single node from its directory with `terragrunt apply` (its parent chain is pulled via dependencies).
