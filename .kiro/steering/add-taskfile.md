---
inclusion: manual
---

# Playbook: Add a Taskfile to an existing lab

Invoke with `#add-taskfile` (or the `/add-taskfile` slash command) while working in a lab folder.
Follow the `taskfile-conventions` steering for the standard interface.

## Steps

1. **Confirm the lab path** (e.g. `aws/secure-vpc`, a `<provider>/<name>` folder at the repo root).
   Inspect its `infra/`, and whether it has an `app/` and/or `deploy/` — this decides whether
   `build` and `deploy` tasks are needed.
2. **Create `<lab>/Taskfile.yml`** with the standard interface
   (`default, init-env, fmt, validate, lint, plan, up, build, deploy, test, down`), omitting
   `build`/`deploy` if the lab has no app.
   - Point infra tasks at `dir: infra`.
   - Add `vars:` for region, image name, cluster name as needed.
   - Wire `deps:` where one task requires another (e.g. `deploy` deps on `build`).
   - Load runtime inputs from a `.env` file via per-task `dotenv:` (committed `.env.example`,
     gitignored `.env`); mind the `dir: infra` → `['../.env']` path rule. Include an `init-env` task
     that seeds `.env` from `.env.example` (no-op if `.env` exists). See the dotenv section in
     `taskfile-conventions`.
3. **Pin tools** — if missing, add `.terraform-version` and `.terragrunt-version` to the lab (read
   by tenv — a single version string each).
4. **Register in the root Taskfile** — add an `includes:` entry with a short namespace so the lab
   is drivable from the repo root (`task <ns>:up`).
5. **Smoke-test cost-free** — run `task <ns>:fmt`, `task <ns>:validate`, `task <ns>:plan`. Do not
   run `up`/`deploy` as part of verification.
6. **Update the lab's `README.md`** with the available `task` commands.

## Acceptance

- `task --list` at the repo root shows the new namespaced tasks.
- `task <ns>:validate` passes.
- No reusable module source was copied into the lab — modules are still referenced by pinned tag.
