# Account billing and plan limits

The hub persists subscriptions and effective entitlements, connects Settings → Account to the hub, and integrates Paddle Checkout, customer portal sessions, and verified subscription webhooks. When enforcement is enabled, the hub applies bridge, terminal input, concurrent stream, and user shell limits. UI controls and upgrade prompts reflect the server checks.

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
| `HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS` | Explicit `true`/`false` enforcement switch, independent of checkout readiness |
| `HEIMDALL_PADDLE_PAST_DUE_GRACE_SECONDS` | Payment failure grace period; default `259200` (three days), `0` disables grace |

Set `--ui-origin` to the exact browser origin, such as `https://heimdall.mundus.in`. Billing mutations accept JSON and reject cookie-authenticated browser origins different from this setting. Explicit user bearer tokens also work for desktop/CLI clients; they do not rely on ambient cookies.

Checkout remains disabled until the API key, client token, and webhook secret are configured. Catalog prices must be configured before checkout offers appear. The API key and webhook secret are never returned to the UI. The configured environment is pinned in the billing database once server credentials are supplied, preventing a sandbox/live mixup.

The CLI flag `--billing-enforce-plan-limits true|false` takes precedence over
`HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS`. If neither is set, enforcement is enabled
when **any** Paddle API key, client token, webhook secret, or Hobbyist price ID is
non-empty. Setting only the environment name or grace duration does not enable
limits. Hubs without Paddle configuration stay unlimited by default. Explicit
`true` enables limits without Paddle; explicit `false` disables them even with
Paddle configured. Checkout availability remains a separate decision.

## Enforced entitlements

Migration `103_plan_enforcement.sql` adds the input, stream count, and shell
capabilities, updates existing effective snapshots while preserving overrides,
and adds `bridges.plan_disabled_at`.

| Effective entitlement | Free | Hobbyist |
| --- | --- | --- |
| `max_bridges` | `1` | `2` |
| `terminal_streaming_enabled` | `true` | `true` |
| `terminal_input_enabled` | `false` (view-only) | `true` |
| `max_concurrent_streams` | `2` | `-1` (unlimited) |
| `shells_enabled` | `false` | `true` |

For `max_bridges` and `max_concurrent_streams`, **`-1` means unlimited and `0`
means zero allowed**. Nullable override columns distinguish inheritance (`NULL`)
from explicit zero/false restrictions.

The hub enforces these values as follows:

- **Bridges:** new device approvals count non-revoked bridges, including pending
  enrollments. Reusing an existing enrolled bridge is allowed at the cap.
  Over-limit bridges are disabled, preserving credentials and durable state.
  Among eligible bridges, ranking uses `last_seen_at` descending, semver
  descending, then `created_at` descending and a stable ID tie-break. Retained
  bridges stay enabled across heartbeats from suspended bridges. Disabled bridges
  cannot reconnect at hello or be chosen for new launches. Reconciliation runs
  at startup, on billing changes and entitlement refresh, and after revocation.
  Upgrades and overrides can re-enable bridges; revocation can free a slot.
- **View-only terminals:** agent and permitted shell-session streams advertise
  `read_only: true`, keep output and the first-resize snapshot, drop binary input,
  and suppress bridge resizes. REST input, resize, and signal routes return a plan
  error. The agent pane shows **View-only · Upgrade plan**.
- **Concurrent streams:** the Free allowance is shared across agent and shell
  stream routes for the same user. An excess WebSocket receives a
  `plan_limit_reached` error frame and close code `4402`. Disconnecting a viewer
  frees its slot. Pane polling also checks this allowance and has a shared
  two-captures-per-second budget for accounts with a finite stream allowance.
  The UI stops polling on `402` and does not reconnect or fall back to polling
  after a stream plan refusal. Retry explicitly after freeing a slot.
- **User shells:** Free users cannot create or restart `kind=shell` or a
  user-started `kind=server`. Existing interactive shells remain alive after a
  downgrade, but new user stream attaches to them are refused. Agent instance
  tokens retain their existing authority for automated `run` and `serve`.

Plan gates apply to user authentication (trusted proxy sessions and user bearer
tokens); agent instance tokens retain existing authorization checks. Streams
retain their attach-time input capability until reconnect; REST mutations
recheck on every request. Existing sessions are not killed by a plan change.

HTTP refusals use `402 Payment Required` with a typed error and details:

```json
{
  "error": {
    "code": "plan_limit_reached",
    "details": {
      "limit": "max_bridges",
      "allowed": 1,
      "current": 1,
      "plan_label": "Free",
      "upgrade_path": "/settings/account"
    }
  }
}
```

`plan_label` is the effective account plan, including Free after cancellation or
grace expiry, or a custom catalog label. The UI uses the limit for a specific
message and links Upgrade to Account settings (`#/settings/account`).

The hub caches entitlements and their plan label for up to **30 seconds**, bounded
by a past-due grace deadline. Webhooks invalidate the cache immediately. Account
billing reads also invalidate it and reconcile bridges. The UI loads billing once
in `AppShell` and shares the persistent RTK cache through `useEntitlements()` and
`selectEntitlements`. Components do not start separate billing subscriptions.
Checkout, checkout-return focus, and `402` responses trigger refresh.

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
- `account_entitlements`: all five effective entitlements from the table above, their nullable `override_*` columns, and operator/reason fields.
- `billing_checkouts`: server-created purchase references and preparation state.
- `billing_events`: successfully processed or stale event IDs for deduplication.
- `billing_settings`: environment binding.

Billing resolution maps catalog plans and account overrides to effective parameters; feature gates consume the cached result. Custom `false` and `0` overrides are valid and survive webhook updates. Overrides currently have no expiry and survive cancellation; they are explicit operator agreements, not subscription data.

Defaults are Free: one bridge, view-only terminals, two streams, and no user shells; Hobbyist: two bridges, terminal input, unlimited streams, and user shells. Active/trialing subscriptions receive their catalog defaults. Paused/canceled subscriptions receive Free defaults. Past-due subscriptions retain their catalog defaults until the configured grace deadline; repeated past-due updates do not extend it. Reads refresh and persist expired-grace parameters, without contacting Paddle.

No public entitlement-editing endpoint exists. Trusted operators can manage custom plans and overrides in the database during this phase. For example, after an account row exists:

```sql
BEGIN IMMEDIATE;
UPDATE account_entitlements
SET override_max_bridges = 6,
    override_terminal_streaming_enabled = 1,
    override_terminal_input_enabled = 1,
    override_max_concurrent_streams = -1,
    override_shells_enabled = 1,
    override_reason = 'Agreed custom account allowance',
    override_updated_by = 'operator-identity'
WHERE user_id = 'target-internal-account-id';
COMMIT;
```

Raw SQL changes become effective at the next entitlement cache miss (within 30 seconds on a subsequent request), or immediately on the next authenticated `GET /api/v1/account/billing`. Application code that writes overrides must call `invalidate_entitlements(service, user_id)` after the write. Entitlement refresh also reconciles disabled bridges; do not manually edit `plan_disabled_at`. Set an override column to `NULL` to resume catalog defaults. Add custom catalog rows and corresponding approved price mappings to support additional plans. A custom agreement without Paddle can use an arbitrary catalog plan with account billing status `custom`. An authenticated admin workflow, full audit history, override expiry, multiple price/billing interval offers, periodic reconciliation, and a durable asynchronous webhook queue remain follow-up work.

## Verification

Tests cover database restart persistence, owner isolation, custom plan parameters, explicit zero/false overrides, stale/duplicate events, rejected prices with rollback, grace expiry, account-bound checkout/portal logic, raw-byte signatures and microsecond event ordering, checkout URL validation and redirect, and portal URL validation.

A built hub can run the isolated HTTP smoke test:

```bash
HEIMDALL_BILLING_TEST_BINARY=/path/to/ham-hub python3 tests/test_account_billing_http.py
```

The test creates a temporary database and random loopback listener, uses a fake
webhook secret, and never contacts Paddle or an existing hub/bridge. Terminal rows
represent sessions on an offline fixture bridge. Paid REST checks assert the
specific `bridge_offline` response after the plan gate; they do not claim a
process was spawned or received input. Stream tests use real WebSocket handshakes
and check `read_only`, mixed-route caps, `4402`, owner isolation, disconnect
cleanup, polling refusal, and immediate webhook upgrades. The bridge approval
helper uses real UI signing/pairing modules and public API, with one database
fixture transition from pending to enrolled to test reuse. It does not perform
unseal or run a bridge.

Run focused verification from the repository root (Node and UI dependencies
must be installed; fresh installs use `npm ci --legacy-peer-deps`):

```bash
nix develop -c bash scripts/verify-plan-limits-e2e.sh
```

The script builds under a unique `$HOME/.cache/heimdall-tests` directory, verifies
the affected Odin packages, runs billing HTTP/WS and UI plan-limit regressions,
and removes its build directory on exit.

### Preview checklist

Use separate Free and Hobbyist accounts in the local preview. T8 confirmed only
the Free browser check. Remaining browser interactions are manual checks for the
user; automated API/component coverage is not recorded as a manual pass.

| Scenario | Automated coverage | Manual preview status |
| --- | --- | --- |
| Free terminal shows output, View-only and Upgrade plan; Upgrade opens Account | HTTP/WS read-only policy; UI indicator/link and guards | T8 Free browser check confirmed; explicitly confirm indicator/link |
| Free shell launch shows refusal and upgrade prompt | HTTP create/restart/attach refusal; UI shell launch tests | Pending |
| Third Free stream shows refusal without polling fallback; close a pane and Retry | Real mixed-route cap, `4402`, slot cleanup; UI no-reconnect/no-fallback tests | Pending |
| At the Free bridge cap, approval offers reuse and upgrade; new approval is refused | Signed API pending-cap/reuse/upgrade; UI approval tests | Pending (T8 cap test skipped) |
| Hobbyist terminal accepts input and shell creation works | Paid `read_only: false`, unlimited attaches, REST passes plan gates; component guards | Pending; actual process/input needs an online bridge |
 A real sandbox purchase still requires configuring your Paddle credentials and notification destination. Before paid rollout, finish reconciliation, identity migration policy, refunds/chargebacks policy, and the deployment checklist in [the subscription plan](plans/paddle-subscriptions-checklist.md).

Paddle references: [server-created transactions](https://developer.paddle.com/api-reference/transactions/create-transaction/), [signature verification](https://developer.paddle.com/webhooks/about/signature-verification/), and [customer portal sessions](https://developer.paddle.com/api-reference/customer-portals/create-customer-portal-session/).
