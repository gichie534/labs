# 0001 — Demonstrating ALB path- and host-based routing minimally

Status: accepted
Date: 2026-07-02

## Context

This lab is a reference for the two content-based routing styles an Application Load Balancer offers
on a single listener: **path-based** and **host-based**. A few design points aren't obvious and are
worth recording.

## Decisions

### A new `aws/alb` module, not inline ALB code

The ALB (load balancer + listener + rules + target groups) is the reusable heart of the lab, so it
was built as a proper catalog module (`aws/alb`, released as `aws-alb-v0.1.0`) and referenced here by
pinned tag — not inlined into the lab. This follows the repo's rule that reusable infrastructure
lives in the modules repo. The module takes `vpc_id`, `subnet_ids`, `target_groups`, and
`listener_rules` as its contract and owns nothing environment-specific.

### Host-based routing via the `Host` header, not real DNS

Host-based rules match on the HTTP `Host` header. Rather than register a domain and create Route 53
records (cost, and a delay waiting for DNS to propagate), the lab uses fake hostnames (`a.alb.lab`,
`b.alb.lab`) and sends them explicitly with `curl -H "Host: a.alb.lab" http://<alb-dns>/`. The ALB
sees the header and routes accordingly — identical behaviour to real DNS, with nothing to provision
and nothing to pay for. For a teaching lab, that trade is clearly worth it.

### Two single instances, not Auto Scaling groups

The lab launches two individual EC2 instances (`app-a`, `app-b`) via the `aws/ec2-instance` module,
one per target group. ASGs would be more production-realistic but add launch templates, desired
capacity, and dynamic target registration — none of which teaches anything about *routing*. Two
fixed instances keep the focus on the ALB, and each is registered into its target group by instance
ID.

### The app security group is scoped to the VPC CIDR, to break a dependency cycle

There's a natural ordering problem: the instances need a security group before they launch, and the
ALB needs the instance IDs to register as targets — but the "correct" instance rule is "allow port
80 from the ALB's security group", which would make the instances depend on the ALB while the ALB
depends on the instances. Rather than create that cycle (or a fourth SG-rule unit to break it), the
app SG admits port 80 from the **VPC CIDR**. The ALB lives in the same default VPC, so this admits
its health checks and forwarded traffic, while the instances stay closed to direct internet access
(clients must go through the ALB). The units then form a clean line:
`lookups -> security -> app-a/app-b -> alb`.

### Instances answer every path; the ALB does not strip prefixes

A path rule that matches `/a/*` forwards the request unchanged — the target receives `/a/foo`, not
`/foo`. So each instance runs a tiny Python handler that returns its identity for *any* path, rather
than serving files from disk (which would 404 on `/a/...`). The handler is installed as a systemd
unit in `user_data` so it survives reboots.

### AMI resolved dynamically, not pinned

The AMI is resolved from the `al2023-ami-kernel-default-x86_64` SSM public parameter so the lab is
region-portable and always launches a current, patched image. A new AL2023 release can change the
AMI ID and cause a plan to want to replace an instance — acceptable for a teaching lab.

## Consequences

- Real, costed resources exist for the lab's lifetime: two t3.micro instances and one ALB. Tear down
  with `task alb:down`.
- The lab pins two module tags: `aws-ec2-instance-v0.1.0` and `aws-alb-v0.1.0`.
- Requires a default VPC with subnets in ≥2 AZs in the target region (an ALB needs ≥2 AZs).
- Host-based routing is only exercised via explicit `Host` headers; there is no real DNS.
