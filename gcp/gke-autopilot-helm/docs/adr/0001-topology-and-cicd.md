# 0001 — Topology, modules, and the CI deploy path

Status: accepted
Date: 2026-06-14

## Context

This lab provisions a GKE Autopilot cluster from the shared modules repo and ships a Go "hello
world" HTTP server onto it from GitHub Actions using Helm. Several decisions weren't obvious.

## Decisions

### Regional Autopilot, private nodes, public control-plane endpoint

We use the `gcp/gke` module as-is: a regional Autopilot cluster with private nodes (egress via the
VPC's Cloud NAT) and a public, authorized-networks-restricted control-plane endpoint. Autopilot
removes node-pool management, which keeps the lab focused on the deploy path rather than cluster ops.

### `master_authorized_networks = 0.0.0.0/0` (lab-only tradeoff)

GitHub-hosted runners have unpredictable egress IPs, so a locked-down API allowlist would block
`helm` from CI. For this throwaway lab we open the control-plane endpoint to `0.0.0.0/0`. This
widens exposure (the endpoint still requires IAM auth, but is reachable from anywhere). A future v2
of this lab will replace this with **GKE Connect Gateway** — IAM-brokered API access with no IP
allowlist — to demonstrate the difference explicitly. Until then this is the single biggest
security caveat of the lab and must not be copied into anything real.

### Keyless CI auth via direct Workload Identity Federation

CI authenticates to GCP with **Workload Identity Federation** (GitHub OIDC), not a service-account
JSON key. No long-lived secret is stored in GitHub. This required a new, reusable
`gcp/workload-identity-federation` module in the modules repo.

We deliberately made that module **IdP-neutral** (a generic OIDC→GCP federation), not a
`github-oidc` module. WIF always has the same shape — pool, OIDC provider(s), attribute
mapping/condition, and the IAM grants — regardless of whether the issuer is GitHub, GitLab,
Terraform Cloud, or another cloud. Only the issuer URL, claim mappings, and the gate condition vary,
and those are *values*, so they're inputs. A `github-oidc` module would force a near-duplicate the
first time we needed a second IdP; the neutral module satisfies rule-of-three on first reuse. The
lab supplies the GitHub-specific policy (issuer, `attribute.repository` condition, principalSet).

### Direct WIF, not service-account impersonation

We grant the federated `principalSet` its project roles (`artifactregistry.writer`,
`container.developer`) **directly** — CI acts as the federated identity itself. We do **not** mint a
service account for CI to impersonate.

This follows Google's current guidance: prefer direct resource access for federated identities, and
use service-account impersonation only for the services that still cannot accept a federated
principal directly. Everything this lab touches (Artifact Registry, GKE) supports direct WIF, so an
intermediary GSA would add a privilege-escalation hop and a managed identity for no benefit. The
`gcp/workload-identity-federation` module keeps impersonation available as a documented fallback
(`service_account_bindings`) for when it is genuinely required; this lab simply doesn't need it. As
a result the lab no longer consumes the `gcp/workload-iam` module.

### Push-based deploy with Helm (not GitOps)

The deploy is push-based: GitHub Actions builds the image, pushes to Artifact Registry, fetches
cluster credentials, and runs `helm upgrade --install`. The repo's k8s steering leans toward GitOps
(Argo CD), but that guidance is being revised; this lab intentionally demonstrates the CI+Helm path.

## Consequences

- The cluster control plane is internet-reachable for the lab's lifetime — tear it down with
  `task gke-helm:down` when finished.
- The lab depends on four module tags being published: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`,
  `gcp-artifact-registry-v0.1.0`, and the new `gcp-workload-identity-federation-v0.1.0`.
