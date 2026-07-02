# aws/asg-cpu-scaling

A minimal demonstration of **EC2 Auto Scaling driven by CPU**: an Auto Scaling group that grows when
its instances get busy and shrinks when they go idle, with nothing but a target-tracking policy on
fleet-average CPU doing the work.

The lab stands up an ASG (min 1 / max 3) of Amazon Linux 2023 instances, then lets you push a
synthetic CPU load onto the fleet to watch it **scale out**, and release that load to watch it
**scale in** — all over SSM, with no SSH key and no inbound ports.

## The idea

```
           target-tracking policy: keep ASGAverageCPUUtilization ≈ 30%
                                   │
   CPU load ▲  ──▶ average CPU > 30%  ──▶ AWS adds instances  ──▶ toward max_size (3)
   CPU load ▼  ──▶ average CPU < 30%  ──▶ AWS removes instances ──▶ toward min_size (1)
```

A `TargetTrackingScaling` policy on the `ASGAverageCPUUtilization` predefined metric owns the whole
control loop: AWS creates and manages the CloudWatch alarms behind it, adding capacity when the
fleet average rises above the 30% target and removing it when the average falls back. We just pick a
low target so a stress load trips scale-out fast and idle trips scale-in.

Load is generated with **stress-ng**, which each instance installs at first boot (`user_data`). The
`load` task fans an `AWS-RunShellScript` SSM command across every running instance to burn all cores;
`unload` kills it. Driving the demo over SSM Session Manager is why each instance carries the
`AmazonSSMManagedInstanceCore` policy — no SSH, no key pair, no port 22.

## Architecture

```
infra/ (Terragrunt units)
  lookups  ──(ami_id, subnet_ids)──▶ asg      local unit: resolve AL2023 AMI + default-VPC subnets
  iam      ──(instance_profile)────▶ asg      IAM role + instance profile (SSM only)
  asg                                          launch template + Auto Scaling group + CPU
                                               target-tracking policy; installs stress-ng at boot
```

| Unit      | Source                         | Pinned tag                        |
| --------- | ------------------------------ | --------------------------------- |
| `lookups` | local (lab glue, no resources) | —                                 |
| `iam`     | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `asg`     | `aws/autoscaling-group`        | `aws-autoscaling-group-v0.1.0`    |

`lookups` is a lab-local unit (not a reusable module): it only reads data sources (the latest Amazon
Linux 2023 AMI via an SSM public parameter, and the subnets of the account's default VPC) and
exposes them as outputs, because Terragrunt `inputs` can't perform data lookups themselves.

The ASG is placed in the **default VPC's public subnets with public IPs and no NAT gateway** to keep
the lab cheap — instances reach the SSM/AWS endpoints over the internet gateway, so there's no
~$32/mo NAT charge.

## Prerequisites

- An AWS account with a **default VPC** in your region, and an S3 bucket for Terraform state
  (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, and Task installed.
- The module tags above published in `gichie534/infrastructure-catalog` (the
  `aws-autoscaling-group-v0.1.0` tag is created by this lab's companion module — push it before
  running `up`).

```bash
task asg:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env        # set AWS_REGION and a globally-unique TF_STATE_BUCKET
```

> Heads up: this creates real, costed EC2 instances (t3.micro, 1–3 of them). Tear it down with
> `task asg:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task asg:state-bootstrap
```

Cost-free checks:

```bash
task asg:validate
task asg:plan
```

Provision:

```bash
task asg:up          # IAM role/profile + Auto Scaling group (starts at 1 instance)
task asg:instances   # list the running instances
```

Demonstrate scaling — in two terminals:

```bash
# terminal 1: watch capacity change
task asg:watch

# terminal 2: drive the load
task asg:load        # burn CPU on every instance -> average climbs -> group scales OUT to 3
# ...watch desired/in_service climb over the next few minutes...
task asg:unload      # stop the burn -> average falls -> group scales IN back to 1
```

Scale-out typically begins within a few minutes of sustained load; scale-in is deliberately slower
(target tracking is conservative about removing capacity), so give it several minutes after
`unload`.

## Tear it down

```bash
task asg:down
```

## Learned / decisions

See `docs/adr/0001-cpu-target-tracking-asg.md` for why target tracking (not step scaling), why load
is driven over SSM with stress-ng, why the group sits in public subnets with no NAT, and the
new `aws/autoscaling-group` module split.
