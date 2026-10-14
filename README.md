# subscription_guard

Shared, serverless subscription check for the Flutter apps (RadioSpy, AirfieldSpy, and later apps).

- iOS: StoreKit 2 `Transaction.latest(for:)` via a small native channel in this plugin.
- Android: Play Billing `queryPastPurchases`. Expiry dates are not available on-device, so a valid purchase is trusted for one recheck window.

Rules (defaults, all configurable through `GuardConfig`):

- Valid result: no re-check for 7 days (capped by the token's own expiry).
- Positively expired: warn and end access 48 hours after the expiry was first seen.
- No response: warn, retry on the next 4 runs, and revoke after at most 7 days from the first failure.

Use it with a unique `appId` per app, so stored state does not clash between apps.

Known limits: client-side checks can be bypassed on a rooted/jailbroken device. Accepted for low-price subscriptions.

Not yet wired into any app.
