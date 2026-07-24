import { defineConfig } from '@playwright/test';

// End-to-end tests against the LIVE, IAP-protected GKE Ingress endpoint.
//
// Two projects, each pinned to one spec so credentials never leak across:
//   - "unauthenticated" sends NO Authorization header  -> IAP must block  (iap-negative.spec.ts)
//   - "authenticated"   injects a service-account IAP JWT as a Bearer header on EVERY request, so
//     IAP admits the traffic and the app renders                          (iap-positive.spec.ts)
//
// The JWT is minted OUTSIDE Playwright (by the Taskfile locally, or the workflow in CI) by signing
// a self-signed JWT as the Playwright test service account — the only IAP-programmatic path that
// works with the Google-managed OAuth client. It is passed in via IAP_JWT. See the lab README/ADR.

const domain = process.env.INGRESS_DOMAIN;
if (!domain) {
    throw new Error('INGRESS_DOMAIN is required (the public hostname, e.g. gke-iap-pw.gcp.example.com)');
}

const baseURL = `https://${domain}`;
const iapJwt = process.env.IAP_JWT ?? '';

export default defineConfig({
    testDir: './tests',
    // The endpoint may still be settling (managed cert going Active, DNS propagating), so give the
    // whole suite room and retry transient failures.
    timeout: 60_000,
    expect: { timeout: 30_000 },
    retries: 3,
    reporter: [['list'], ['html', { open: 'never' }]],

    projects: [
        {
            name: 'unauthenticated',
            testMatch: /iap-negative\.spec\.ts/,
            use: { baseURL },
        },
        {
            name: 'authenticated',
            testMatch: /iap-positive\.spec\.ts/,
            use: {
                baseURL,
                // Injected on every request the browser makes, so IAP sees the SA JWT and lets it through.
                extraHTTPHeaders: iapJwt ? { Authorization: `Bearer ${iapJwt}` } : {},
            },
        },
    ],
});
