# aws/eks-vector-terminating-logs

A focused debugging lab for one question: **when a pod is stuck in `Terminating` for a long time but
its container is still alive and logging, does the Vector agent keep collecting those logs all the
way to the aggregator — or does collection stop once Kubernetes marks the pod for deletion?** It
stands up a small EKS cluster, installs Vector as a node agent (DaemonSet) plus a central aggregator
(console sink), runs a workload that logs forever and refuses to die, then lets you delete it and
watch whether its post-delete log lines still show up downstream.

## Architecture

```
infra/ (Terragrunt units, each pinned to the modules repo by tag)
  network ──(private_subnet_ids)──▶ cluster
   VPC                               EKS control plane + 1 managed node group (2× t3.medium)
   2× /20 private subnets            addons: vpc-cni, kube-proxy, coredns
   single NAT gateway

in-cluster (Helm + kubectl, installed by `deploy`):
  vector-agent       DaemonSet   kubernetes_logs (tails /var/log/pods) ──vector proto──▶ aggregator
  vector-aggregator  Deployment  vector source :6000 ──▶ console sink (stdout)
  noisy-terminator   Deployment  busybox: logs every 5s, traps SIGTERM, grace period 3600s
```

| Unit      | Module    | Pinned tag       |
| --------- | --------- | ---------------- |
| `network` | `aws/vpc` | `aws-vpc-v0.1.0` |
| `cluster` | `aws/eks` | `aws-eks-v0.1.0` |

Vector is the official chart `vector/vector`, pinned to `0.57.0`. `cluster` depends on `network` and
runs its nodes in the private subnets.

## How the experiment works

The `noisy-terminator` container writes a line every 5 seconds and **traps `SIGTERM` without
exiting**, and its pod sets `terminationGracePeriodSeconds: 3600`. So when you delete it:

1. The kubelet sends `SIGTERM`; the pod gets a `deletionTimestamp` and shows `STATUS=Terminating`.
2. The container ignores the signal and keeps logging — now tagged `phase=terminating` — for up to
   an hour, until the kubelet gives up and `SIGKILL`s it.
3. During that window you compare two things: the pod's **own stdout** (ground truth,
   `task logs-source`) against **what the aggregator collected**
   (`task logs`). If `phase=terminating` lines reach the aggregator, the agent keeps
   collecting through termination; if they stop at the delete, it doesn't.

We delete the **Deployment** (not just the pod) so no replacement pod is created to muddy the
picture. See `docs/adr/0001-observing-terminating-pod-logs.md` for the reasoning behind each choice.

## Prerequisites

- An AWS account and an S3 bucket for Terraform state. State locking is S3-native (`use_lockfile`,
  Terraform ≥ 1.10) — no DynamoDB table required.
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, `kubectl`, `helm`, and Task installed.
- The module tags above published in `gichie534/infrastructure-catalog`.

> Heads up: this creates real, costed resources (an EKS control plane, a NAT gateway, and 2
> `t3.medium` EC2 nodes). Tear it down with `task down` when you're done.

## Run it

Set up your local env, then create the state bucket once:

```bash
task init-env      # writes .env from .env.example — then edit .env
# set AWS_REGION and TF_STATE_BUCKET in .env
task state-bootstrap
```

Cost-free checks:

```bash
task validate
task plan
```

Stand it up and deploy the in-cluster pieces:

```bash
task up            # VPC + EKS + nodes (creates cloud resources)
task deploy        # Vector agent + aggregator (Helm) + the noisy-terminator workload
task status        # sanity: workload pod Running, both Vector pods Ready
```

Confirm collection is working while the pod is healthy:

```bash
task logs          # aggregator's collected view — you should see phase=running lines
```

Now run the experiment. In one terminal watch the pod state, in another watch the collected logs:

```bash
task watch-pod     # terminal 1 — will flip to Terminating and stay there
task logs          # terminal 2 — aggregator's collected view

task terminate     # delete the Deployment -> the pod enters a long Terminating
```

Then read the result:

- The pod stays `Terminating` (grace period 3600s).
- `task logs-source` shows the pod itself is still emitting `phase=terminating` lines.
- `task logs` shows what the **aggregator actually received**. Whether the
  `phase=terminating` lines appear there — and for how long after the delete — is the hypothesis
  answer. Note the last `#N` line number that made it through versus the pod's current line number.

## Tear it down

```bash
task clean-k8s     # optional: remove just the in-cluster pieces, keep the cluster
task down          # destroy all infra
```

## Learned / decisions

See `docs/adr/0001-observing-terminating-pod-logs.md` for why the workload lingers via a
SIGTERM-trap + long grace period (not a finalizer), why we delete the Deployment rather than the
pod, why the aggregator is a stateless console sink (no PVC/EBS dependency), and why Vector is
installed with Helm rather than GitOps for this lab.
