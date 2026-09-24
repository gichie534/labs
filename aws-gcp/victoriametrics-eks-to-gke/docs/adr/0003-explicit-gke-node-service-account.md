# 0003 — Give the GKE nodes an explicit service account in Terraform

Status: accepted

## Context

`task up` succeeded. `task deploy` did not, and the cluster looked healthy while being completely
non-functional:

- `gcloud container clusters list` showed `vmmig-target` with `STATUS: RUNNING` and a **blank**
  `CURRENT_NODE_COUNT`.
- 15 pods were `Pending`. None of them were ours — they were `kube-system`, `gke-gmp-system` and
  `gke-managed-cim` components: `kube-dns`, `metrics-server`, `konnectivity-agent`, `event-exporter`,
  `gmp-operator`, `alertmanager`, `kube-state-metrics`.
- Every event said `FailedScheduling: no nodes available to schedule pods`.
- One event said more than that:
  `NodeController ... DeletingNode node/gk3-vmmig-target-default-pool-... because it does not exist in
  the cloud provider`.

So nodes were being *created and then removed*. That last event is the only signal that distinguishes
this from a capacity problem, and it is easy to scroll past.

Every plausible suspect was checked and cleared:

| Suspect                   | Reality                                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| Compute quota             | `CPUS 4/200`, `INSTANCES 2/24`, `SSD_TOTAL_GB 230/500` — nowhere near a limit                       |
| Pod range exhaustion      | `10.31.0.0/16` with zero nodes consuming it                                                         |
| Autopilot resource ratios | The lab's Jobs are within the 1:1–1:6.5 vCPU:GiB window, and in any case `kube-dns` was Pending too |
| A broken lab config       | A sibling cluster in the same project and region was running two nodes fine                         |

The actual cause was IAM. The GKE console said so, in one advisory line with no error styling:

> Grant `roles/container.defaultNodeServiceAccount` role to Node service account to allow for
> non-degraded operations.

Both clusters in the project ran nodes as `<project-number>-compute@developer.gserviceaccount.com`,
and that account held **no project IAM bindings whatsoever**. Google no longer grants `roles/editor`
to the Compute Engine default service account on new projects, and the
`iam.automaticIamGrantsForDefaultServiceAccounts` org policy removes it wherever it is enforced.
Without a role, a node boots, cannot authenticate to the control plane to register, and the control
plane deletes it — forever, on a loop. The sibling cluster kept working because its nodes were
created while the grant still existed; it would have failed the same way on its next node
replacement.

Nothing in the observable failure mentions IAM. The symptom is "no capacity", the cause is
"no permission".

## Decision

The node identity is declared in Terraform, not left implicit.

`modules/gcp/gke` (from `gcp-gke-v0.3.0`) grows `create_node_service_account`, and this lab sets it
`true`. The module then creates a dedicated service account for the cluster and grants it
`roles/container.defaultNodeServiceAccount` on the project, with the cluster `depends_on` the
binding so no node ever boots unauthorised.

Two consequences worth stating:

- **Autopilot takes the node account through `cluster_autoscaling.auto_provisioning_defaults`**, not
  `node_config` — there are no node pools to attach one to, and `node_config` conflicts with
  `enable_autopilot`. An *empty* `cluster_autoscaling` block conflicts with it too, so the module
  emits the block only when an account is known.
- **The binding is `google_project_iam_member`, not `google_project_iam_binding`.** Additive and
  non-authoritative: it cannot strip other members from the role. In a project where a sibling
  cluster still relies on the default account, an authoritative binding would take that cluster down.

## Alternatives considered

**Grant the role to the default Compute Engine service account.** This is what the console suggests
and what was done by hand to unblock the lab. Rejected as the codified answer: it is a project-wide
mutation on an account shared by everything in the project, it grants node permissions to every VM
that uses the default account, and if two labs' Terraform states both managed it, destroying either
one would break the other. It also leaves the cluster's identity implicit, which is how the problem
went unnoticed in the first place.

The manual grant is deliberately **left in place** rather than reverted — the sibling
`gke-argocd-victoriametrics` cluster in this project still runs on the default account and removing
it would break that cluster.

**Compose `gcp/service-account` as a separate Terragrunt unit.** Strictly more single-purpose, and the
module already exists. Rejected because the node account's lifecycle *is* the cluster's — it has no
reason to exist without it — and because splitting them makes the role grant a separate step that can
be forgotten, which is precisely the failure being fixed. Consumers who genuinely want to own the
account elsewhere pass `node_service_account` instead.

**A preflight check in the Taskfile.** A cost-free assertion before `up` would have caught it. Not
needed once Terraform owns the grant: the check would only ever fail if someone bypassed the module.
`task status` does now print the node count, so a zero-node cluster is visible without reading events.

## Open: this fixed a real bug, but it did not bring the cluster back

Stated plainly so nobody re-runs the same dead ends. The missing role is a genuine defect and the
module change above is worth having on its own merit. It was **not** confirmed to be the cause of
this particular outage, and the cluster was still at zero nodes when the investigation was parked.

What was established after the grant was applied:

- The grant landed. `303740800792-compute@developer.gserviceaccount.com` now holds
  `roles/container.defaultNodeServiceAccount`. It was left in place deliberately — the sibling
  `gke-argocd-victoriametrics` cluster still runs on that account.
- Still zero nodes ~10 minutes later, 15 pods `Pending`, no new GKE operation for the cluster since
  `CREATE_CLUSTER`. No node provisioning attempt was retried.
- **The node did not crash.** Logs from 2026-09-23T21:44–21:46 show `anetd` reconciling pods normally,
  then a clean shutdown sequence: `Shutting down redirect service controller`, balloon pods getting
  `Terminated`, fluentbit catching a signal. The node was created around 21:40, was healthy at 21:44,
  and was **gracefully drained and deleted at 21:46:02** — 11 minutes after the cluster was created.
  Something removed a working node and never replaced it.
- The Cilium/`NetworkPluginNotReady` errors surfaced in the console are a red herring: that error
  group dates from 14 Jun 2026, months before this cluster existed, and the address in it
  (`10.16.0.90`) is not in this lab's Pod range (`10.31.0.0/16`).
- Not quota (`CPUS 4/200`, `INSTANCES 2/24`), not billing (`billingEnabled: true`), not cluster
  health (`status: RUNNING`, all five Autopilot node pools `RUNNING`, no `conditions`, no
  `statusMessage`).

The one unexplained observation, and the place to start next time:

> `gcloud compute instances list` and `gcloud compute instance-groups managed list` both return
> **zero items project-wide**, while `gcloud container clusters list` reports the sibling cluster with
> 2 nodes, `kubectl` lists those 2 nodes as `Ready`, and regional quota confirms `INSTANCES usage: 2`.
> Those cannot all be true. Either the aggregated Compute list calls are lying (wrong quota project,
> an API/permission quirk that returns empty instead of erroring) or the managed instance groups
> backing `vmmig-target` really are gone while the cluster still advertises their URLs.

Resolve that contradiction first — it decides whether this is a client-side artifact or genuine
orphaned cluster state. Do not repeat the quota, billing, CIDR, or Autopilot-resource-ratio checks;
all four were cleared.

Pragmatically, for a lab: `task down && task up` is cheaper than further forensics, and recreating
the cluster also applies the node service account fix above from the start.

## Consequences

- A GKE cluster from this catalog works on a fresh project with no manual IAM step.
- Node permissions are least-privilege and reviewable in the module's `node_service_account_roles`
  input rather than inherited from whatever `roles/editor` happens to imply.
- The default for `create_node_service_account` is `false`, so this is opt-in. Existing clusters built
  from `gcp-gke-v0.2.x` are unaffected until they bump the ref and set the flag. That is a deliberate
  trade: the safer posture is not the default, because flipping it would silently re-issue the node
  identity of every already-deployed cluster on its next apply.
- Applying this change to a cluster already running on the default account is an in-place update.
  Existing nodes are replaced with ones using the new account; workloads reschedule.
