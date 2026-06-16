# aws/eks-vpc-cni-ip-allocation

Demonstrates, in isolation, how the **AWS VPC CNI** allocates pod IP addresses out of VPC subnets,
and how that allocation changes when you set the CNI's `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` flags.
The lab walks three phases and snapshots the IP state after each, so you can literally watch a small
private subnet drain as nodes join — then recover once the CNI is tuned.

## The idea

By default the VPC CNI keeps a **whole spare ENI** of secondary IPs warm on every node
(`WARM_ENI_TARGET=1`). On a large instance this is expensive: an `m5.xlarge` supports 3 ENIs × 15
IPs, so a node running just a handful of pods still holds a warmed spare ENI of ~15 idle IPs — pure
waste. Setting `WARM_IP_TARGET` (keep only N spare IPs) and `MINIMUM_IP_TARGET` (floor the pool)
makes nodes hold far fewer idle IPs, returning addresses to the subnet. This lab proves that with a
before/after report and an assertive test.

The nodes are intentionally **large** (`m5.xlarge` by default, override with `NODE_INSTANCE_TYPE`) so
the warmed-ENI waste — and its reclaim — is large enough to see and assert. The private subnets are
kept modest (two `/25`, 123 usable IPs each) so the drain is visible without exhausting them. See
`docs/adr/0001-phasing-and-cni-tuning.md` for why.

## Architecture

```
infra/ (Terragrunt units, each pinned to the modules repo by tag)
  network ──(private_subnet_ids)──▶ cluster
   VPC                               EKS control plane + 1 managed node group
   2× /26 private subnets            vpc-cni addon (configuration_values driven by env)
   NAT gateway                       coredns, kube-proxy, eks-pod-identity-agent

scripts/report.sh   one snapshot of IP state -> text (stdout) + JSON (reports/<phase>.json)
test/               Go + AWS SDK: asserts free IPs went UP / secondary IPs went DOWN after tuning
```

| Unit      | Module    | Pinned tag       |
| --------- | --------- | ---------------- |
| `network` | `aws/vpc` | `aws-vpc-v0.1.0` |
| `cluster` | `aws/eks` | `aws-eks-v0.1.0` |

`cluster` depends on `network` and runs nodes in its private subnets.

The CI identity (GitHub OIDC provider + the role the workflow assumes) is a separate bootstrap unit,
not part of the phase walk:

| Unit                    | Module                | Pinned tag                   |
| ----------------------- | --------------------- | ---------------------------- |
| `bootstrap/ci-identity` | `aws/oidc-federation` | `aws-oidc-federation-v0.1.0` |

## The three phases

| Phase | What happens                                                 | Driven by                          | Report             |
| ----- | ------------------------------------------------------------ | ---------------------------------- | ------------------ |
| 1     | Provision VPC + EKS + **1 node**, CNI at defaults            | `terragrunt run --all apply`       | `phase-1-baseline` |
| 2     | **Scale** the node group to 2 — watch the subnet drain       | `aws eks update-nodegroup-config`  | `phase-2-scaled`   |
| 3     | **Tune** `WARM_IP_TARGET`/`MINIMUM_IP_TARGET`, recycle nodes | `terragrunt apply` (env-var input) | `phase-3-tuned`    |

Phase 2 uses the AWS CLI because the `aws/eks` module sets `ignore_changes` on the node group's
desired size (so the autoscaler can own it) — scaling is therefore an imperative op, not a Terraform
apply. Phase 3 flows the flags through the module's `vpc-cni` addon `configuration_values`, selected
by the `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` environment variables (unset = defaults), then
**recycles the nodes** (terminates the instances so the node group's ASG launches fresh ones). The
recycle is deliberate: the CNI frees already-warmed ENIs only lazily, so restarting the `aws-node`
daemonset doesn't reliably reclaim them — fresh nodes booting under the new targets does.

## What the report shows

`scripts/report.sh <phase>` captures, for that moment:

1. **Private subnet IP availability** (`aws ec2 describe-subnets`) — the headline `AvailableIpAddressCount` per subnet.
2. **Node ENIs and secondary IPs** (`aws ec2 describe-network-interfaces`) — every ENI attached to the worker instances (primary + CNI ENIs) and how many secondary IPs each holds. The total is the real "IPs these nodes are holding," and the *why* behind (1).
3. **Kubernetes node capacity** (`kubectl get nodes`) — allocatable pods vs running, i.e. how the ENI math becomes max-pods.
4. **Live `aws-node` CNI config** — `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` / `WARM_ENI_TARGET`, so you see the flags actually change between phases. (Set `PROBE_CNI=1` to also query the CNI's `/v1/enis` introspection API.)

It prints the above as text and writes `reports/<phase>.json`, which the Go test consumes.

## Prerequisites

- An AWS account and an S3 bucket for Terraform state. State locking is **S3-native**
  (`use_lockfile`, Terraform ≥ 1.10) — no DynamoDB table required.
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, `kubectl`, `jq`, `go`, and Task installed.
- The module tags above published in `gichie534/infrastructure-catalog`.

Set these before running:

```bash
export AWS_REGION=us-east-1
export TF_STATE_BUCKET=my-tf-state-bucket
# optional: export AWS_AZS=us-east-1a,us-east-1b   # if your account lacks the first two AZs
```

> Heads up: this creates real, costed resources (EKS control plane, a NAT gateway, and 2
> `m5.xlarge` EC2 nodes by default). The large instances are deliberate — they're where warmed-ENI
> IP waste is worth showing. 2 nodes = 8 vCPUs, which fits a fresh account's default On-Demand vCPU
> quota; raise the *Running On-Demand Standard instances* quota (L-1216C47A) and pass `NODE_SCALE=3+`
> for more. Tear it down with `task eks-cni:down` when you're done.

## Run it

One-time setup — create the S3 state bucket (recent Terragrunt no longer auto-creates it):

```bash
task eks-cni:state-bootstrap   # creates TF_STATE_BUCKET; run once with admin creds
```

Cost-free checks:

```bash
task eks-cni:validate
task eks-cni:plan
```

Then walk the phases (each `report-*` prints to your terminal and writes `reports/<phase>.json`):

```bash
task eks-cni:up                # phase 1: VPC + EKS + 1 node
task eks-cni:report-baseline

task eks-cni:scale             # phase 2: scale to 2 nodes (NODE_SCALE=N to change)
task eks-cni:report-scaled

task eks-cni:tune              # phase 3: WARM_IP_TARGET=1 MINIMUM_IP_TARGET=4 (override via env)
task eks-cni:report-tuned

task eks-cni:test              # assert: tuning reclaimed IPs (reads reports/)
```

Or run the whole sequence (including the assertion) in one go:

```bash
task eks-cni:walk
```

Compare `reports/phase-2-scaled.json` (untuned) with `reports/phase-3-tuned.json`: with the same
node count, `total_secondary_ips` drops and `total_free_private_ips` rises. That delta is exactly
what `task eks-cni:test` asserts.

## Three ways to run the same sequence

1. **Taskfile tutorial** (above) — local, step by step, readable.
2. **GitHub Actions** — `.github/workflows/eks-vpc-cni-ip-allocation.yml` runs the identical phase
   sequence (Terragrunt + AWS CLI + kubectl), runs the assertion with `RUN_LIVE=1`, and uploads the
   three reports as a build artifact. Manual-dispatch only (it creates costed infra). Auth is keyless
   via GitHub OIDC → an AWS IAM role. The workflow lives in the lab; move or symlink it to the repo's
   top-level `.github/workflows/` for GitHub to pick it up.

   One-time CI bootstrap (run from an admin context, **not** from CI — it creates the role CI uses):

   ```bash
   export GITHUB_REPOSITORY=owner/repo   # the repo allowed to assume the role
   task eks-cni:ci-bootstrap             # creates the GitHub OIDC provider + CI role
   task eks-cni:ci-config                # prints AWS_ROLE_ARN=...
   ```

   Then set repo variables `AWS_REGION`, `TF_STATE_BUCKET`, and `AWS_ROLE_ARN` (from `ci-config`).
   The bootstrap role is granted broad AWS-managed policies because the workflow creates and destroys
   a whole cluster — a deliberate lab-only tradeoff (see the ADR). Remove it later with
   `task eks-cni:ci-bootstrap-down`.

   > An AWS account holds only one OIDC provider per issuer URL. If `token.actions.githubusercontent.com`
   > already exists in your account, `ci-bootstrap` will collide — import the existing provider or
   > reuse it. See the `aws/oidc-federation` module README.
3. **Assertive Go test** — `test/` reads the phase JSON snapshots and asserts the free-IP delta
   (red/green), with an opt-in `RUN_LIVE=1` path that cross-checks against live EC2. This turns the
   lab from "look at the numbers" into "prove the setting works."

## Tear it down

```bash
task eks-cni:down
```

## Learned / decisions

See `docs/adr/0001-phasing-and-cni-tuning.md` for why the baseline is one node (not zero), why the
subnets are deliberately tiny, why scaling is a CLI op while tuning is Terragrunt, why the nodes are
recycled after tuning, and why the test asserts a delta rather than absolute counts.
