# Labs

Self-contained infrastructure labs, grouped by provider as `<provider>/<name>/` (e.g.
`gcp/organization-layout-terragrunt`). Each lab is a vertical slice with its own Terragrunt config,
`Taskfile.yml`, and `README.md`. See `.kiro/steering/` for the conventions these labs follow.

## Bootstrap toolchain

Dependencies are managed with [mise](https://mise.jdx.dev) and [tenv](https://github.com/tofuutils/tenv),
split by responsibility:

- **mise** (`mise.toml` at the repo root) pins the repo-wide dev tools: **Task**, **tflint**, and
  **tenv** itself.
- **tenv** owns **Terraform** and **Terragrunt**, resolving the version from each lab's
  `.terraform-version` / `.terragrunt-version` files. These are intentionally left out of `mise.toml`
  so the two managers never compete over the same binary and per-lab pinning stays the source of truth.

### One-time setup

1. Install mise: https://mise.jdx.dev/getting-started.html (e.g. `brew install mise`), then hook it
   into your shell so its shims are on `PATH`.
2. From the repo root, trust and install the pinned tools:

   ```sh
   mise trust
   mise install
   ```

That gives you `task`, `tflint`, and `tenv`. Terraform and Terragrunt are then fetched by tenv on
first use inside a lab, matching that lab's pinned versions.

## Running a lab

Every lab exposes the standard Task interface and is namespaced from the repo root:

```sh
task --list                 # all labs' tasks
task org-layout:validate    # cost-free
task org-layout:plan        # cost-free
task org-layout:up          # creates cloud resources
```
