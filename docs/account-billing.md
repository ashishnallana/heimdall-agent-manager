# Account billing: initial integration

This phase persists account subscription state and effective user parameters, connects Settings → Account to the hub, and implements Paddle Checkout, customer portal sessions, and verified subscription webhooks. Bridge limits and streaming access are **not enforced in this phase**. Existing bridge, terminal, and agent behavior continues.

Authentik remains the authentication provider. Billing requests reuse the existing authenticated hub account; browsers never supply an account owner or entitlement values. The current hub maps Authentik usernames to internal user IDs. Migrating to immutable Authentik identity mapping remains required before relying on account rename support; this phase does not change authentication or existing resource ownership.

## Configuration

Use a separate hub/database for sandbox testing. Set these environment variables on the hub service using your deployment's secret management:

| Variable | Purpose |
| --- | --- |
| `HEIMDALL_PADDLE_ENVIRONMENT` | `sandbox` (default) or `live` |
| `HEIMDALL_PADDLE_API_KEY` | Server API key; transaction creation and customer portal session permissions |
| `HEIMDALL_PADDLE_CLIENT_TOKEN` | Public Paddle.js client token for the matching environment |
| `HEIMDALL_PADDLE_WEBHOOK_SECRET` | Notification destination signing secret |
| `HEIMDALL_PADDLE_HOBBYIST_PRICE_ID` | Approved recurring Hobbyist price ID |
| `HEIMDALL_PADDLE_PAST_DUE_GRACE_SECONDS` | Payment failure grace period; default `259200` (three days), `0` disables grace |

Set `--ui-origin` to the exact browser origin, such as `https://heimdall.mundus.in`. Billing mutations accept JSON and reject cookie-authenticated browser origins different from this setting. Explicit user bearer tokens also work for desktop/CLI clients; they do not rely on ambient cookies.

Checkout remains disabled until the API key, client token, and webhook secret are configured. Catalog prices must be configured before checkout offers appear. The API key and webhook secret are never returned to the UI. The configured environment is pinned in the billing database once server credentials are supplied, preventing a sandbox/live mixup.

Create the Hobbyist product and price in Paddle, configure approved checkout domains/default payment URL, and register this notification destination:

```text
POST https://<hub-host>/api/v1/billing/paddle/webhook
```

Configure subscription lifecycle notifications (`subscription.created`, `subscription.updated`, `subscription.activated`, `subscription.trialing`, `subscription.past_due`, `subscription.paused`, `subscription.resumed`, `subscription.canceled`). The receiver processes signed `subscription.*` snapshots and acknowledges other signed notification types without changing access.

In the reverse proxy, exempt **only this webhook route and POST method** from the Authentik login redirect. Preserve the raw body and `Paddle-Signature` header. Apply a 1 MiB body limit at the proxy as well; the handler refuses larger bodies but the shared HTTP reader has a larger artifact-upload limit. Keep account, checkout, and portal routes authenticated. Checkout leaves the authenticated origin for Paddle's default payment URL, so no Paddle script or frame CSP exemption is needed on the hub.

## API and purchase flow

- `GET /api/v1/account/billing` returns the current authenticated user's plan display metadata, effective parameters, eligible offers, billing dates/state, and public checkout configuration. New users receive persisted Free defaults at provisioning; this read also initializes any missing rows.
- `POST /api/v1/account/billing/checkout` accepts only an `offer_id`. The hub resolves its approved price and creates a Paddle transaction containing a random, persisted checkout reference. It returns `transaction_id` and Paddle's `checkout_url`; the hub and the browser both require HTTPS, no embedded credentials, and exactly one `_ptxn` equal to that transaction before the browser navigates there with `window.location.assign()`. Paddle.js is not loaded on the authenticated origin. Checkout creation does not grant entitlements.
- `POST /api/v1/account/billing/portal` creates a temporary Paddle customer portal URL from the authenticated account's persisted customer mapping. Links are not stored or cached.
- `POST /api/v1/billing/paddle/webhook` verifies HMAC-SHA256 against original request bytes with timestamp bounds, then atomically applies subscription state, resolved parameters, and the event deduplication record.

Webhooks link new subscriptions through a server-created checkout reference, not email or arbitrary client account metadata. Later updates resolve by stored subscription ID. Unmapped subscriptions, unknown prices, and mismatched customers are rejected for operator review/retry. Repeated checkout clicks reuse a prepared transaction and re-fetch its validated checkout URL instead of creating another; concurrent preparation is rejected. Ambiguous API failures retain the reservation for 20 minutes rather than immediately risking another transaction.

The Account page polls pending checkout state and refreshes on focus after the user returns from Paddle; only persisted webhook state changes the displayed plan and parameters.

## Persistence and custom plans

Migration `069_account_billing.sql` creates these tables; `070_free_one_bridge.sql` changes the Free default to one bridge and updates existing snapshots while preserving overrides:

- `billing_plans`: arbitrary plan IDs, display names, current checkout price, and default parameters.
- `billing_plan_prices`: retained approved historical price mappings.
- `account_billing`: owner, subscription/customer IDs, billing lifecycle state and dates, and latest event timestamp.
- `account_entitlements`: persisted effective `max_bridges` and `terminal_streaming_enabled`, plus nullable per-account overrides and operator/reason fields.
- `billing_checkouts`: server-created purchase references and preparation state.
- `billing_events`: successfully processed or stale event IDs for deduplication.
- `billing_settings`: environment binding.

Only billing resolution maps plans to parameters. Feature code will consume effective parameters when enforcement is implemented. Custom `false` and `0` overrides are valid and survive webhook updates. Overrides currently have no expiry and survive cancellation; they are explicit operator agreements, not subscription data.

Initial defaults are Free: one bridge, streaming excluded; Hobbyist: two bridges, streaming included. Active/trialing subscriptions receive their catalog defaults. Paused/canceled subscriptions receive Free defaults. Past-due subscriptions retain their catalog defaults until the configured grace deadline; repeated past-due updates do not extend it. Reads refresh and persist expired-grace parameters, without contacting Paddle.

No public entitlement-editing endpoint exists. Trusted operators can manage custom plans and overrides in the database during this phase. For example, after an account row exists:

```sql
BEGIN IMMEDIATE;
UPDATE account_entitlements
SET override_max_bridges = 6,
    override_terminal_streaming_enabled = 1,
    override_reason = 'Agreed custom account allowance',
    override_updated_by = 'operator-identity'
WHERE user_id = 'target-internal-account-id';
COMMIT;
```

The next account read resolves and persists the effective values. Set an override column to `NULL` to resume catalog defaults. Add custom catalog rows and corresponding approved price mappings to support additional plans. A custom agreement without Paddle can use an arbitrary catalog plan with account billing status `custom`. An authenticated admin workflow, full audit history, override expiry, multiple price/billing interval offers, periodic reconciliation, and a durable asynchronous webhook queue remain follow-up work.

## Verification

Tests cover database restart persistence, owner isolation, custom plan parameters, explicit zero/false overrides, stale/duplicate events, rejected prices with rollback, grace expiry, account-bound checkout/portal logic, raw-byte signatures and microsecond event ordering, checkout URL validation and redirect, and portal URL validation.

A built hub can run the isolated HTTP smoke test:

```bash
HEIMDALL_BILLING_TEST_BINARY=/path/to/ham-hub python3 tests/test_account_billing_http.py
```

The test creates a temporary database and loopback listener, uses a fake webhook secret, and never contacts Paddle or an existing bridge. A real sandbox purchase still requires configuring your Paddle credentials and notification destination. Before paid rollout, finish reconciliation, identity migration policy, refunds/chargebacks policy, and the deployment checklist in [the subscription plan](plans/paddle-subscriptions-checklist.md).

Paddle references: [server-created transactions](https://developer.paddle.com/api-reference/transactions/create-transaction/), [signature verification](https://developer.paddle.com/webhooks/about/signature-verification/), and [customer portal sessions](https://developer.paddle.com/api-reference/customer-portals/create-customer-portal-session/).
