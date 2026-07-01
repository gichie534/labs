# 0001 — Private access to a GKE Ingress with IAP, and how to test it

Status: accepted
Date: 2026-06-24

## Context

This lab extends `gcp/gke-ingress-managed-cert`: same regional Autopilot cluster, registry, keyless
CI via direct Workload Identity Federation, delegated Cloud DNS zone, classic GKE Ingress (external
Application Load Balancer) with a Google-managed TLS certificate and HTTP→HTTPS redirect. What's new
is **private access**: the public HTTPS endpoint is fronted by **Identity-Aware Proxy (IAP)**, so
only authorised Google identities in the organization can reach the app. The lab also has to
**test** that access, which has real subtleties.

## Decisions

### IAP via a BackendConfig using the Google-managed OAuth client

GKE integrates IAP through the Ingress. A `BackendConfig` CRD with `spec.iap.enabled: true`,
attached to the Service with the `cloud.google.com/backend-config` annotation, turns IAP on for the
backend service the Ingress creates.

We use the **Google-managed OAuth client** (`enabled: true` with no `oauthclientCredentials`). The
original plan was a **self-managed** OAuth client (`google_iap_brand` + `google_iap_client` in
Terraform) for a known audience. That path is **no longer available**: the IAP OAuth Admin APIs were
deprecated in Jan 2025 and **permanently shut down on 19 March 2026**, and the Terraform resources no
longer function (new projects can't call those APIs at all). The Google-managed client is now the
supported way to enable IAP, and for an organization-internal app it needs no brand/client/secret at
all.

Consequence: there is no Kubernetes Secret and no OAuth-client Terraform. IAP enablement is a single
CRD field; **who** may pass through is pure IAM.

### Access control is its own concern — the `gcp/iap-access` catalog module

Enabling IAP is only half of it; the other half is granting `roles/iap.httpsResourceAccessor` to the
principals allowed through. That "grant access through IAP" operation is genuinely reusable, so it
was promoted to a new catalog module **`gcp/iap-access`** (tag `gcp-iap-access-v0.1.0`) rather than
inlined in the lab. It grants the role at the project-wide IAP web scope by default (GKE Ingress
names its backend service dynamically, so project scope is the pragmatic choice) and accepts any IAM
principals. The lab's `infra/iap-access` unit grants two: the operator (`IAP_MEMBER`) and the test
service account.

### Testing access: negative (automated) + positive (service-account JWT)

IAP makes a plain `curl` insufficient, so the lab tests two paths:

1. **Negative (automated, no credentials).** An unauthenticated `GET https://<domain>/` must NOT
   reach the app — IAP responds with a 302 to `accounts.google.com` (or 401/403). A 200 here means
   IAP isn't enforcing and is a hard failure. This is the always-on assertion (Taskfile `verify` and
   the GitHub Action), because it proves enforcement with zero setup.

2. **Positive (service-account-signed JWT).** With the Google-managed OAuth client, a **human** can't
   do the OIDC-token-with-client-ID flow (you don't own the managed client's credentials). But a
   **service account** can still authenticate programmatically using a **self-signed JWT whose
   `aud` is the resource URL** (`https://<domain>/`) — no OAuth client ID required. So the lab:
   - creates a dedicated test SA (`gcp/service-account` module, new tag `gcp-service-account-v0.1.0`);
   - grants it `roles/iap.httpsResourceAccessor` (via `gcp/iap-access`);
   - lets the operator impersonate it (`roles/iam.serviceAccountTokenCreator`) so the JWT is signed
     through the IAM Credentials API with **no exported key**;
   - signs the JWT (`gcloud iam service-accounts sign-jwt`) and sends it as `Authorization: Bearer`,
     expecting 200 with the app body.

   IAP TCP tunnelling was considered and rejected: it's for SSH/TCP to VMs, not for an HTTPS load
   balancer, so it doesn't apply here.

### CI runs only the negative test

CI keeps the reference lab's minimal roles (`artifactregistry.writer` + `container.developer`). The
positive test needs to impersonate the test SA, which we deliberately do **not** grant to the CI
federated principal — widening CI's blast radius to mint IAP tokens isn't justified for shipping an
image. So the GitHub Action runs build → push → deploy → **negative** test; the operator runs the
positive test locally via `task gke-iap:verify-positive`.

### Ephemeral LB IP + two-phase DNS, master_authorized_networks = 0.0.0.0/0

Unchanged from the reference lab. The LB IP is ephemeral, so the apex A record is published in a
second phase after the Ingress exists, and the managed cert validates by load-balancer
authorization. The control-plane endpoint is opened to `0.0.0.0/0` so GitHub-hosted runners can run
`helm`. Both are lab-only tradeoffs — see `gcp/gke-ingress-managed-cert` ADR 0001.

## Consequences

- The app is reachable only by Google identities in the org that hold
  `roles/iap.httpsResourceAccessor`; everyone else is bounced to sign-in.
- First managed-cert issuance can still take 10–20 minutes; HTTPS + IAP are fully live only after the
  two-phase flow completes.
- New catalog modules this lab introduces: `gcp/iap-access` (`gcp-iap-access-v0.1.0`) and
  `gcp/service-account` (`gcp-service-account-v0.1.0`). It also pins the same module tags as the
  reference lab: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`, `gcp-artifact-registry-v0.2.0`,
  `gcp-workload-identity-federation-v0.2.1`, `gcp-cloud-dns-v0.3.0`.
- The Gateway API + Certificate Manager variant remains future work (as noted in the reference lab).
