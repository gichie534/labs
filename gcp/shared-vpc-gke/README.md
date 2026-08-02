# gcp/shared-vpc-gke

Stands up a **Shared VPC** across two GCP projects and runs a regional **GKE Autopilot** cluster in
one of them on the other's network:

- a **host project** that owns the VPC (one GKE-ready subnet with Pods/Services secondary ranges +
  Cloud NAT) and is nominated as a Shared VPC host;
- a **service project** that is attached to the host and runs the Autopilot cluster on the host's
  subnet — with the exact IAM a service-project GKE cluster needs on the host network.

The lab is laid out as a **directory-as-hierarchy** of Terragrunt units (the same style as
`gcp/organization-layout-terragrunt`): each directory under `root-folder/` is a node, wired to its
parent/peers by `dependency` blocks.

## Architecture

```
organization
└── folder: shared-vpc-gke                    (root-folder/)
    ├── HOST project  ── Shared VPC host ──┐   (root-folder/host)
    │     └── VPC: subnet "shared-gke"     │   (root-folder/host/vpc)
    │            + Pods/Services ranges    │
    │            + Cloud NAT               │
    │     └── shared-vpc-access ───────────┤   (root-folder/host/shared-vpc-access)
    │            grants the service project's GKE agents:
    │              • roles/compute.networkUser on the subnet
    │              • roles/container.hostServiceAgentUser on the host project
    └── SERVICE project ── attached to host ┘   (root-folder/service)
          └── GKE Autopilot cluster ───────▶ runs on the HOST subnet
                                              (root-folder/service/gke)
```

## Units & modules

| Unit (directory)                     | Module                | Source                   |
| ------------------------------------ | --------------------- | ------------------------ |
| `root-folder`                        | `gcp/folder`          | `?ref=gcp-folder-v0.3.0` |
| `root-folder/host`                   | `gcp/host-project`    | local path (unreleased)  |
| `root-folder/host/vpc`               | `gcp/vpc`             | `?ref=gcp-vpc-v0.1.0`    |
| `root-folder/host/shared-vpc-access` | `gcp/shared-vpc-iam`  | local path (unreleased)  |
| `root-folder/service`                | `gcp/service-project` | local path (unreleased)  |
| `root-folder/service/gke`            | `gcp/gke`             | `?ref=gcp-gke-v0.2.0`    |

`gcp/host-project`, `gcp/service-project`, and `gcp/shared-vpc-iam` are **new** modules added to the
`infrastructure-catalog` repo for this lab. They are referenced by **local path**
(`${get_repo_root()}/../infrastructure-catalog/modules/...`) while unreleased.

> **TODO before this lab is "done":** cut `gcp-host-project-v0.1.0`, `gcp-service-project-v0.1.0`,
> and `gcp-shared-vpc-iam-v0.1.0` in `infrastructure-catalog` and switch the two `_envcommon`
> project templates and the `shared-vpc-access` unit from the local path to pinned `?ref=` sources.

## How the Shared VPC IAM works

Two Google-managed agents in the **service** project need access to the **host** network (both
derived from the service project *number*):

- `<number>@cloudservices.gserviceaccount.com` and
  `service-<number>@container-engine-robot.iam.gserviceaccount.com` get
  `roles/compute.networkUser` **scoped to the subnet** (least privilege — not the whole host project);
- the `container-engine-robot` agent additionally gets `roles/container.hostServiceAgentUser` on the
  **host project** so the cluster can manage its networking (firewall rules, etc.) there.

The `container-engine-robot` agent only exists once the Container API is enabled in the service
project, so the DAG applies the service project (which enables it) before `shared-vpc-access`.

> The **host** project also enables `container.googleapis.com` (not just Compute): GKE on a Shared
> VPC provisions a container service agent in the host project to manage the cluster's firewall
> rules, and cluster creation fails with a `TM_FAILED_PRECONDITION` "should enable
> service:container.googleapis.com" error if it isn't enabled there.

## Prerequisites

- `terraform`, `terragrunt` (pinned via tenv), `gcloud`, `tflint`, and Task installed.
- The three new module directories present in the sibling `infrastructure-catalog` checkout.
- The identity running `up` must hold **`roles/compute.xpnAdmin`** at the org/folder (to nominate a
  host and attach a service project), plus rights to **create projects** and **use the billing
  account**.
- A GCP project (separate bootstrap project) to own the GCS state bucket.

Config is loaded from a local `.env` via the Taskfile's dotenv; `root.hcl` reads it through
`get_env(...)`. Seed and edit it:

```bash
task init-env    # copies .env.example -> .env (no-op if .env exists)
$EDITOR .env                # set org/billing, region, the two project IDs, and the state bucket
```

`.env` keys: `GCP_ORG_ID`, `GCP_BILLING_ACCOUNT`, `GCP_REGION`, `HOST_PROJECT_ID`,
`SERVICE_PROJECT_ID`, `TF_STATE_BUCKET`, `TF_STATE_PROJECT`, `TF_STATE_LOCATION`.

## Stand it up

```bash
task init-env    # seed .env, then edit it
task init-state  # create the GCS state bucket (idempotent; run once)
task validate    # cost-free
task plan        # cost-free
task up          # creates the folder, both projects, VPC, Shared VPC grants, and cluster
```

Then fetch cluster credentials:

```bash
gcloud container clusters get-credentials shared-vpc-gke \
  --region us-central1 --project svc-gke-service-richard-test
kubectl get nodes
```

## Tear it down

```bash
task down
```

## Security caveats

- The cluster's control-plane endpoint is opened to `0.0.0.0/0` (`master_authorized_networks`) so an
  operator/CI can reach it; nodes stay private behind Cloud NAT. Deliberate lab-only tradeoff — see
  `docs/adr/0001-shared-vpc-gke-topology.md`.

## Learned / decisions

See `docs/adr/0001-shared-vpc-gke-topology.md` for why the host/service split lives in dedicated
project modules (no conditionals), why the IAM is its own module (mirroring `gcp/workload-iam`), and
why `networkUser` is scoped to the subnet.
