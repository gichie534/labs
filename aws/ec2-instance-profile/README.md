# aws/ec2-instance-profile

A minimal reference for **wiring IAM to EC2**: how to give an EC2 instance an identity so its
workload calls AWS APIs with **no static credentials**, using only the permissions it actually needs.

The lab stands up one EC2 instance whose instance profile grants exactly two things, then proves it
works by running `aws s3 ls` on the box at boot — with no access keys anywhere.

## The idea

An EC2 instance doesn't hold AWS credentials. Instead:

```
EC2 service ──assume──▶ IAM role ──policies──▶ permissions
                          │
                   instance profile  (the EC2-shaped wrapper around the role)
                          │
                     attached to the instance ──▶ IMDS vends short-lived creds to the AWS CLI/SDK
```

The AWS CLI on the instance transparently pulls temporary credentials from the instance metadata
service (IMDS), which are the role's. So `aws s3 ls` just works — that's the whole demonstration.

The role carries two deliberately minimal grants:

- **`AmazonSSMManagedInstanceCore`** (AWS-managed) — lets you open a shell on the instance via **SSM
  Session Manager**. No SSH key, no inbound port 22, no bastion.
- **`s3:ListAllMyBuckets`** (inline, least privilege) — exactly what `aws s3 ls` calls, and nothing
  more.

Two security defaults come from the `aws/ec2-instance` module: **IMDSv2 is required** (so the role
credentials can't be siphoned via the legacy unauthenticated IMDSv1 path) and the **root volume is
encrypted**.

## Architecture

```
infra/ (Terragrunt units)
  lookups  ──(ami_id, subnet_id)──▶ instance     local unit: resolve AL2023 AMI + default-VPC subnet
  iam      ──(instance_profile)───▶ instance     IAM role + instance profile (SSM + s3:ListAllMyBuckets)
  instance                                        EC2 instance, attaches the profile, runs `aws s3 ls`
                                                  at boot -> /var/log/s3-ls-demo.log
```

| Unit       | Source                         | Pinned tag                        |
| ---------- | ------------------------------ | --------------------------------- |
| `lookups`  | local (lab glue, no resources) | —                                 |
| `iam`      | `aws/iam-instance-profile`     | `aws-iam-instance-profile-v0.1.0` |
| `instance` | `aws/ec2-instance`             | `aws-ec2-instance-v0.1.0`         |

`lookups` is a lab-local unit (not a reusable module): it only reads data sources (the latest Amazon
Linux 2023 AMI via an SSM public parameter, and a subnet from the account's default VPC) and exposes
them as outputs, because Terragrunt `inputs` can't perform data lookups themselves.

## Prerequisites

- An AWS account with a **default VPC** in your region, and an S3 bucket for Terraform state
  (S3-native locking — no DynamoDB).
- `terraform`, `terragrunt` (pinned via tenv), `aws` CLI, and Task installed.
- For `task ec2-profile:session`: the AWS CLI **Session Manager plugin**.
- The module tags above published in `gichie534/infrastructure-catalog`.

```bash
task ec2-profile:init-env   # creates .env from .env.example (no-op if it already exists)
$EDITOR .env                # set AWS_REGION and a globally-unique TF_STATE_BUCKET
```

> Heads up: this creates a real, costed EC2 instance (t3.micro by default). Tear it down with
> `task ec2-profile:down` when you're done.

## Run it

One-time — create the S3 state bucket:

```bash
task ec2-profile:state-bootstrap
```

Cost-free checks:

```bash
task ec2-profile:validate
task ec2-profile:plan
```

Provision, then see the proof:

```bash
task ec2-profile:up            # IAM role/profile + EC2 instance
task ec2-profile:show-proof    # prints the boot-time `aws s3 ls` log from the instance via SSM
```

`show-proof` reads `/var/log/s3-ls-demo.log`, which contains the instance's own caller identity (the
role) and the `aws s3 ls` output — produced with no credentials on the box. You can also open an
interactive shell:

```bash
task ec2-profile:session       # SSM Session Manager shell (no SSH)
```

## Tear it down

```bash
task ec2-profile:down
```

## Learned / decisions

See `docs/adr/0001-minimal-ec2-iam.md` for why SSM (not SSH), why the S3 grant is inline rather than
a managed policy, why AMI/VPC discovery is a separate local unit, and the two-module split.
