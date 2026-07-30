# 0001 — How the terminating-pod log hypothesis is set up

Status: accepted
Date: 2026-07-15

## Context

The lab exists to test one hypothesis: **when a pod is stuck in `Terminating` for a long time but
its container is still alive and writing logs, does the node-level Vector agent keep collecting
those logs and get them through to the aggregator — or is there a gap once Kubernetes marks the pod
for deletion?** A few setup choices weren't obvious and are worth recording.

## Decisions

### The workload lingers in Terminating via SIGTERM-trap + a long grace period

To reproduce a "long Terminating" pod deterministically, the `noisy-terminator` container traps
`SIGTERM` and refuses to exit, and its Pod sets `terminationGracePeriodSeconds: 3600`. On
`kubectl delete` the kubelet sends SIGTERM, the process keeps running (now logging
`phase=terminating`), and the kubelet waits the full hour before SIGKILL. That gives a stable,
hour-long window in which the pod is provably `Terminating` while still producing logs. This is a
more faithful reproduction than a finalizer-stuck pod: a finalizer leaves the *pod object* around
after its container has already stopped, so there would be no live log stream to collect — which is
not the scenario under test.

### We delete the Deployment, not the pod

`terminate` deletes the **Deployment**, not the pod. Deleting just the pod would let the ReplicaSet
immediately create a replacement that also logs, muddying the observation. Deleting the Deployment
removes the ReplicaSet, so the single existing pod goes `Terminating` with no replacement and the
signal stays clean.

### Aggregator is a Stateless-Aggregator with a console sink

The Vector chart offers `Agent` (DaemonSet), `Aggregator` (StatefulSet + PVC), and
`Stateless-Aggregator` (Deployment + emptyDir). We use **Stateless-Aggregator** so there is no
PersistentVolumeClaim and therefore no dependency on the EBS CSI driver or a StorageClass — one
fewer moving part for a lab that doesn't need disk buffering. The aggregator's only sink is
`console` (stdout), so the entire "did the log arrive?" surface is a plain
`kubectl logs` on the aggregator pod. No CloudWatch, S3, or IAM/Pod Identity is involved, which
keeps the lab minimal and the answer directly observable.

### Two components, wired over the cluster-DNS service name

The agent's `kubernetes_logs` source is the thing under test; the aggregator is just a sink you can
read. They're separate Helm releases (`vector-agent`, `vector-aggregator`) in the `vector`
namespace. The agent forwards over Vector's native protocol to
`vector-aggregator.vector.svc.cluster.local:6000`, which is why the `coredns` add-on is enabled on
the cluster. `fullnameOverride` pins each release's resource names so the DNS name the agent dials
is stable.

### Vector is installed with Helm driven by Task, not GitOps

The repo's default for Kubernetes labs is GitOps (Argo CD under `deploy/`). Here we deliberately
install with `helm upgrade --install` from the Taskfile instead: this is a short-lived debugging
lab whose whole point is a single observation, and standing up Argo CD would dwarf it. The chart
version is pinned (`0.57.0`) for reproducibility, in keeping with the repo's version-pinning rule.

### Small nodes, no test

Nodes are `t3.medium` × 2 — enough for the agent DaemonSet, the aggregator, and the workload, with
nothing to stress. Per the lab's scope there is **no automated Terratest**: the outcome is confirmed
by the documented `terminate` → `logs` procedure, comparing the pod's own stdout (ground truth)
against what the aggregator collected.

## Consequences

- Real, costed resources (EKS control plane, a NAT gateway, 2 EC2 nodes) exist for the lab's
  lifetime — tear down with `task vector-logs:down`.
- The lab pins two module tags — `aws-vpc-v0.1.0`, `aws-eks-v0.1.0` — and the Vector Helm chart
  `0.57.0`.
- If you wait out the full hour, the container is SIGKILLed and the pod finally disappears; run the
  observation well within that window.
