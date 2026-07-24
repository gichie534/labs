import { test, expect } from '@playwright/test';

// POSITIVE: with the service-account IAP JWT injected as a Bearer header (see playwright.config.ts),
// IAP admits the request and the app renders. This is the whole point of the lab — a browser test
// authenticating THROUGH IAP.
//
// The header is applied to the browser context, so page navigations (and their sub-resources) carry
// it too. We assert both the HTTP 200 and the app's greeting in the rendered body.

test.beforeAll(() => {
    if (!process.env.IAP_JWT) {
        throw new Error(
            'IAP_JWT is not set — the positive test needs a service-account IAP JWT. ' +
            'Run via `task gke-iap-pw:test-e2e` (or the CI workflow), which mints it.',
        );
    }
});

test('authenticated request reaches the app through IAP', async ({ page }) => {
    const response = await page.goto('/');

    expect(response, 'no response from the endpoint').not.toBeNull();
    expect(
        response!.status(),
        'expected HTTP 200 with the IAP JWT — a 302/401/403 means the token was rejected',
    ).toBe(200);

    await expect(page.locator('body')).toContainText('Hello, world');
});
