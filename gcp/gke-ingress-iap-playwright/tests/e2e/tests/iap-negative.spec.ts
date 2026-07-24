import { test, expect } from '@playwright/test';

// NEGATIVE: an unauthenticated request must NOT reach the app. IAP either redirects to Google
// sign-in (302 -> accounts.google.com) or refuses outright (401/403). A 200 here means IAP is not
// enforcing — a hard failure.
//
// Uses the request context (not a browser page) so the assertion is deterministic: we inspect the
// raw first response instead of chasing a redirect into Google's real sign-in UI.
test('unauthenticated request is blocked by IAP', async ({ request }) => {
    const res = await request.get('/', { maxRedirects: 0 });
    const status = res.status();

    if (status === 302) {
        const location = res.headers()['location'] ?? '';
        expect(
            location,
            `expected a redirect to Google sign-in, got Location: ${location}`,
        ).toContain('accounts.google.com');
        return;
    }

    expect(
        [401, 403],
        `expected 302->accounts.google.com or 401/403, but got HTTP ${status} (200 would mean IAP is NOT enforcing)`,
    ).toContain(status);
});
