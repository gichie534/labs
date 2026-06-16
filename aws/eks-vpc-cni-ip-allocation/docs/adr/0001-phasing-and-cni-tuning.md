# 0001 — Phasing, node sizing, and how the CNI is tuned

Status: accepted
Date: 2026-06-16

## Context

This lab demonstrates, in isolation, how the AWS VPC CNI allocates pod IPs from VPC subnets and how
that allocation changes when you set `WARM_IP_TARGET` / `MINIMUM_IP_TARGET`. Several design points
weren't obvious and are worth recording.

## Decisions

### Baseline has one node, not zero

The thesis ("nodes warm whole ENIs of secondary IPs, draining the subnet") is best shown by holding
the cluster constant and changing only the CNI knobs. But `aws-eks-v0.1.0` validates
`length(var.node_groups) > 0`, so a genuinely node-less control plane isn't possible without a
module change. Rather than fork the module, phase 1 is **cluster + one node**, phase 2 scales that
same node group up, and phase 3 tunes the CNI and recycles the nodes. This keeps the module pinned
and isolates the CNI effect (same node count before and after the tuning), at the cost of the
baseline not being literally zero-node.

### Large nodes (`m5.xlarge`), modest `/25` subnets

The waste the lab targets scales with ENI size. A first attempt used `t3.small` (~3-4 IPs/ENI): the
default `WARM_ENI_TARGET=1` warmed so few IPs that tuning had nothing meaningful to reclaim — the
before/after delta was zero and the assertion failed. The fix is **large instances**: an `m5.xlarge`
supports 3 ENIs × 15 IPs, so a node running a few pods holds a warmed spare ENI of ~15 idle IPs, and
tuning visibly reclaims them. The instance type is overridable via `NODE_INSTANCE_TYPE`.

Subnets are two `/25` (123 usable IPs each): small enough that the drain moves
`AvailableIpAddressCount` obviously, large enough that 3 large untuned nodes (each warming ~30 IPs)
don't exhaust the subnet mid-lab and wedge the cluster. (An earlier `/26` risked exhaustion once the
nodes grew.) This is a teaching choice, not a production pattern — real clusters size subnets
generously precisely to avoid CNI IP exhaustion.

### Phase 2 (scale) is an AWS CLI op, not a Terraform apply

The `aws/eks` module sets `ignore_changes = [scaling_config[0].desired_size]` on the node group (so
the Cluster Autoscaler can move desired size without Terraform fighting it). That means changing
`desired_size` in Terragrunt is a no-op after create. We embrace this: phase 2 scales with
`aws eks update-nodegroup-config`. It fits the lab — scaling is exactly the kind of imperative,
operational event the CLI is for, while Terragrunt keeps owning declarative config.

### Phase 3 (tune) is Terragrunt-owned, driven by env vars; nodes are recycled

The CNI knobs flow through the module's `vpc-cni` addon `configuration_values`. The cluster unit
reads `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` from the environment: unset → `configuration_values =
null` (true defaults, phase 1/2); set → a `{"env": {...}}` JSON string (phase 3). Driving phases
with env vars (rather than editing files mid-run) keeps every phase reproducible and lets the same
config serve both the Taskfile and CI.

After applying the addon change we **recycle the nodes** — terminate the node group's instances so
its ASG launches fresh ones that boot under the new IP targets. We originally just rolled the
`aws-node` daemonset, but that does NOT reliably reclaim already-warmed ENIs: the CNI frees excess
ENIs lazily with cooldowns, so the restarted daemonset kept the old warm IPs and the "after" report
showed no reduction (the bug that motivated this revision). Recycling the nodes gives a clean,
deterministic re-allocation under the new targets, so the reclaim is immediate and measurable.

### Measure secondary IPs across all node ENIs

The report counts secondary private IPs on **every ENI attached to the worker instances** (primary
ENI + the CNI's extra ENIs), scoped by node instance ID — not just ENIs with the `aws-K8S-*`
description. The warm pool can sit on the primary ENI too, so the description filter under-counted.
Instance-scoped counting is the true measure of "IPs these nodes are holding."

### One shared `report.sh`, text + JSON

The snapshot logic (subnet free IPs, node ENIs and secondary IPs, node allocatable-pods, live
`aws-node` env) lives in a single `scripts/report.sh` consumed by both the Taskfile tutorial and the
CI workflow, so all three phase reports are produced by identical logic. It prints human-readable
text (the tutorial's teaching value — real `aws`/`kubectl` commands) and writes a JSON snapshot per
phase. The Go test reads those JSON snapshots, making the script the single source of truth for both
the human story and the automated red/green assertion.

### The test asserts a delta, not an absolute

Exact IP counts depend on instance type (ENI/IP limits), node count, and add-on pods, so the test
asserts the **direction** of change between the phase-2 (untuned) and phase-3 (tuned) snapshots:
secondary IPs held by nodes go down, free subnet IPs go up, with node count held equal. An opt-in
`RUN_LIVE=1` path re-reads subnets from EC2 to catch stale snapshots.

### Keyless CI via a separate bootstrap unit, not the phase walk

CI authenticates with **GitHub OIDC → an IAM role** (no static access keys), built by the new
`aws/oidc-federation` module. That module is the AWS analogue of the gke lab's
`gcp/workload-identity-federation`: IdP-neutral, owning the mechanism (IAM OIDC provider + a role
whose trust policy gates on the token's `aud`/`sub` claims) while the policy (issuer, subjects,
permissions) is input.

The role is created in `bootstrap/ci-identity`, deliberately **outside** `infra/`. It's a
chicken-and-egg resource — CI can't create the role it itself assumes — so it's applied once from an
admin context (`task eks-cni:ci-bootstrap`) and is not part of the `up`/`down` phase walk. CI's
`run --all` only ever touches `infra/` (network + cluster).

The role gets broad AWS-managed policies (EKS/EC2/VPC/IAM/S3 admin) plus an inline `eks:*` grant,
because the workflow stands up and tears down a whole cluster. This is the AWS counterpart of the
gke lab's `0.0.0.0/0` caveat — a lab-only convenience, not a pattern to copy. The OIDC provider is
account-global and the module is create-only, so a second consumer in the same account must share or
import it rather than recreate it.

### S3-native state locking, no DynamoDB

State locking uses S3's native lockfile support (`use_lockfile`, Terraform ≥ 1.10; the lab pins
1.14.1) instead of a DynamoDB lock table. One fewer resource to create, and the CI role needs no
DynamoDB permissions.

## Consequences

- Real, costed resources (EKS control plane, NAT gateway, EC2 nodes) exist for the lab's lifetime —
  tear down with `task eks-cni:down`.
- The lab pins three module tags: `aws-vpc-v0.1.0`, `aws-eks-v0.1.0`, and `aws-oidc-federation-v0.1.0`.
- `t3.small` nodes are used to keep ENI/IP limits (and therefore the numbers) small and the cost
  low; the effect is identical on larger instances, just with bigger numbers.
