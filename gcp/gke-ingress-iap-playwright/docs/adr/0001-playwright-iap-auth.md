# 0001 — Authenticating Playwright end-to-end tests through IAP

Status: accepted
Date: 2026-07-24

## Context

This lab extends `gcp/gke-ingress-iap`: same regional GKE Autopilot cluster, registry, keyless CI
via direct Workload Identity Federation, delegated Cloud DNS zone, classic GKE Ingress (external
Application Load Balancer) with a Google-managed TLS certificate and HTTP→HTTPS redirect, and a
`BackendConfig` (`iap.enabled: true`, Google-managed OAuth client) putting Identity-Aware Proxy in
front. What's new is the **verification method**: **Playwright** end-to-end tests, run from
GitHub-hosted runners, that must both be **blocked** when unauthenticated and **admitted** when
authenticated — i.e. a browser test that authenticates *through* IAP.

The reference lab tested IAP with `curl`: a credential-free negative test in CI, and an
operator-only positive test (a service-account-signed JWT) via the Taskfile. CI was deliberately
**not** allowed to run the positive test. This lab's whole point is to let CI run the positive test
with Playwright, so that decision is revisited here.

## Decisions

### Playwright authenticates with a service-account JWT injected as a Bearer header

IAP with the **Google-managed OAuth client** accepts programmatic access only via a **service-account
self-signed JWT whose `aud` is the resource URL** (`https://<domain>/`); there is no OAuth client ID
to run the interactive/OIDC flow against, and the IAP OAuth Admin APIs were shut down in 2026.

Two consequences shaped the test design:

- **You cannot get an IAP token from WIF alone.** A federated WIF principal has no signing keys IAP
  trusts and cannot self-sign a JWT IAP accepts; the STS exchange yields an *access* token, which
  IAP does not honor for the web resource. The only keyless path is: impersonate a **service
  account** that holds `roles/iap.httpsResourceAccessor` and sign the JWT as it. So a service
  account is structurally required — WIF removes the SA *key*, not the SA.
- **The browser can't do interactive sign-in.** Driving Google's real sign-in UI (password, 2FA,
  org policy, bot defenses) is impractical and flaky. Instead Playwright injects the signed JWT as
  an `Authorization: Bearer` header on every request via `extraHTTPHeaders`, and IAP admits the
  traffic. The JWT is minted **outside** Playwright (Taskfile locally, workflow in CI) and passed in
  via `IAP_JWT`.

The test suite has two Playwright projects, each pinned to one spec so credentials never cross:

- **Negative** (`iap-negative.spec.ts`, no header): a request-context `GET /` with redirects
  disabled must be a 302 to `accounts.google.com` or a 401/403. A 200 is a hard failure.
- **Positive** (`iap-positive.spec.ts`, Bearer header): a browser `page.goto('/')` returns 200 and
  the rendered body contains the app's greeting.

### Reuse the test SA, renamed; grant the CI federated principal Token Creator on it

The reference lab already had a dedicated test SA (`iap-tester`). We reuse that pattern, **renamed to
`playwright-iap-tester`** to reflect its purpose, and — the key change — grant
`roles/iam.serviceAccountTokenCreator` on it to **both** the operator (`IAP_MEMBER`, for local runs)
**and the CI WIF principalSet** (for the GitHub Actions job). The pool id is shared via `root.hcl`
so `deployer-wif` (which creates the pool) and `iap-sa` (which references its principalSet) cannot
drift. `roles/iap.httpsResourceAccessor` for the SA stays in the `iap-access` unit, unchanged.

### CI runs both the negative and positive tests (the deliberate tradeoff)

Granting CI Token Creator on the test SA widens CI's blast radius: a workflow on this repo can now
mint IAP tokens *as that SA* and reach anything the SA is allowed through. That is an accepted,
lab-scoped tradeoff — it is exactly the capability required to run an authenticated browser test in
CI, the reason this lab exists. It is contained by the WIF `attribute_condition` (only this repo's
tokens federate) and by the SA holding IAP access to just this lab's app. CI still keeps its minimal
project roles (`artifactregistry.writer` + `container.developer`); the only added capability is
impersonating this one SA.

### Unchanged from the reference lab

Ephemeral LB IP + two-phase DNS, load-balancer-authorized managed cert, and
`master_authorized_networks = 0.0.0.0/0` so GitHub-hosted runners can run `helm`. All lab-only
tradeoffs, carried over as-is.

## Consequences

- CI can prove IAP enforcement in both directions on every push, in a real browser engine.
- A GitHub Actions run on this repo can mint IAP tokens as `playwright-iap-tester`; treat that SA's
  access as CI-reachable.
- The positive test depends on the JWT's ~1h lifetime; the Playwright job must finish within it
  (it does — the suite is seconds).
- Module tags pinned are identical to the reference lab: `gcp-vpc-v0.1.0`, `gcp-gke-v0.1.0`,
  `gcp-artifact-registry-v0.2.0`, `gcp-workload-identity-federation-v0.2.1`, `gcp-cloud-dns-v0.3.0`,
  `gcp-service-account-v0.1.0`, `gcp-iap-access-v0.1.0`.
