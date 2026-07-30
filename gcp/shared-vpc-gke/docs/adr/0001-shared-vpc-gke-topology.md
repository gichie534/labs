# ADR 0001 — Shared VPC + GKE Autopilot topology

- **Status:** Accepted
- **Date:** 2026-07-15
- **Context:** `gcp/shared-vpc-gke` lab

## Context

The lab demonstrates the canonical GCP **Shared VPC** pattern: a central *host* project owns the
network, and *service* projects run workloads on it. We wanted a GKE Autopilot cluster in a service
project attached to a host project's subnet, laid out like `gcp/organization-layout-terragrunt`
(directory = org node), and composed only from the shared `infrastructure-catalog` modules.

## Decisions

### 1. Host/service status lives in dedicated project modules, not a flag on `gcp/project`

We added two modules — `gcp/host-project` (project + `google_compute_shared_vpc_host_project`) and
`gcp/service-project` (project + `google_compute_shared_vpc_service_project`) — rather than adding
`enable_shared_vpc_host` / `shared_vpc_host_project_id` conditionals to the base `gcp/project`.

- Keeps `gcp/project` unchanged for the many consumers that don't share a VPC.
- Each module is conditional-free and single-purpose: "this project is a host" / "…is a service
  project" is expressed by *which module* you instantiate, not by a boolean.
- The service project attaches **itself** to the host (`shared_vpc_host_project_id`), so the host
  never references its service projects and the dependency graph stays acyclic (host → service).

Trade-off: the ~10 lines of `google_project` + API enablement are duplicated across three modules.
Accepted for standalone clarity and because the new modules are sourced by local path (Terragrunt
copies only the module dir, so cross-module composition via relative `source` wouldn't work anyway).

### 2. The cross-project IAM is its own module (`gcp/shared-vpc-iam`)

Mirroring `gcp/workload-iam`: producer modules stay pure and export identifiers; a dedicated IAM
module is the single home for "the service project may use the host network". It grants the service
project's `cloudservices` and `container-engine-robot` agents access and the host-service-agent
role. This keeps structure (attachment) separate from permissions.

### 3. `roles/compute.networkUser` is scoped to the subnet, not the host project

Least privilege: the service project can use only the one shared subnet (and its Pod/Service
secondary ranges), not every subnet in the host VPC. Granting at the project level would be broader
than this lab needs.

### 4. Ordering: enable the service project's Container API before granting IAM

The `service-<number>@container-engine-robot` agent is created only when the Container API is
enabled in the service project. `shared-vpc-access` therefore depends on the service project unit
(which activates `container.googleapis.com`), so the agent exists when the bindings are created —
avoiding a "member does not exist" apply error.

### 5. Public control-plane endpoint (lab-only)

`master_authorized_networks = 0.0.0.0/0` lets an operator/CI reach the control plane; nodes stay
private with egress via the host's Cloud NAT. This widens control-plane exposure and is acceptable
only for a throwaway lab; a hardened variant would use authorized networks or Connect Gateway.

## Consequences

- Running the lab requires `roles/compute.xpnAdmin` at the org/folder plus project-creation and
  billing rights — a higher bar than a single-project lab.
- The three new modules must be released as pinned tags before the lab is considered "done" (they
  are referenced by local path meanwhile). See the README TODO.
