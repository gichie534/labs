# 0001 — CPU-driven scaling with a target-tracking ASG

- Status: accepted
- Date: 2026-07-02

## Context

The lab demonstrates EC2 Auto Scaling reacting to CPU: load the fleet to force scale-out, release
the load to force scale-in. Several choices shaped how minimal and reproducible that demo is.

## Decisions

### Target tracking, not step scaling

We use a single `TargetTrackingScaling` policy on the `ASGAverageCPUUtilization` predefined metric
(target 30%) instead of step scaling with hand-authored CloudWatch alarms. Target tracking lets AWS
create and manage the alarms; the lab declares one number (the target) rather than an alarm +
scale-out policy + scale-in policy + thresholds. That keeps the control loop to one resource and
still shows the full out/in behaviour. A low target (30%) means a stress load reliably crosses the
threshold within minutes and idle reliably drops below it — good for a live demo. Step scaling would
be the choice if the lab needed to illustrate custom, non-linear step adjustments; it doesn't.

### Load driven over SSM with stress-ng

Instances install `stress-ng` at first boot and are exercised via `aws ssm send-command`
(`AWS-RunShellScript`) rather than SSH. This mirrors the sibling `ec2-instance-profile` lab: the only
IAM grant the instances need is `AmazonSSMManagedInstanceCore`, so there's no SSH key, no key pair,
and no inbound port 22 or security-group rule. One `load` command fans out across every InService
instance so the *fleet average* moves, which is what the policy tracks.

### Public subnets, no NAT

The ASG launches into the default VPC's public subnets with public IPs and no NAT gateway. SSM and
the AWS APIs are reached over the internet gateway, so the lab avoids the ~$32/mo NAT cost. A
production topology would put the fleet in private subnets behind NAT (or VPC endpoints); that
realism isn't worth the cost for a scaling demo.

### New `aws/autoscaling-group` module

No ASG module existed in `infrastructure-catalog`. An Auto Scaling group + launch template + CPU
policy is clearly reusable infra, and the steering forbids inlining reusable module source into a
lab, so it was implemented in the catalog and released as `aws-autoscaling-group-v0.1.0`, then
referenced here by pinned `?ref=`. The module owns only the launch template, the group, and the CPU
scaling policy; the AMI, subnets, security groups, and instance profile are inputs — keeping it
region- and account-agnostic.

## Consequences

- The demo is exercised entirely through Task commands (`load` / `unload` / `watch`) with no manual
  console steps.
- Scale-in is intentionally slow (target tracking is conservative about removing capacity), so the
  README sets the expectation to wait several minutes after `unload`.
- If a second lab needs an ASG, it reuses the same pinned module rather than copying this wiring.
