# Product analytics (PostHog)

Ninjy sends a small set of funnel events to PostHog Cloud (US) so we can see where new users
drop off between the landing page and their first running agent. It covers two clients that
share one PostHog project:

| Client | Code | Gated by |
| --- | --- | --- |
| Marketing site (`www.ninjy.ai`, `homelab/sites/heimdall/` in `nix-homelab-config`) | `posthog-js` snippet + shared `assets/analytics.js` | the key constant in that file (empty = off) |
| App: web (`web.ninjy.ai`) and Electron desktop | [`src/ui/analytics/`](../src/ui/analytics) | the runtime config `/posthog-config.json` (no key = off) |

There is no autocapture, no session recording, no surveys/heatmaps, and no automatic
pageviews in the app. Every event is listed below; nothing else is sent.

## Funnel

```text
$pageview → invite_requested → app_login → bridge_connected → provider_configured → first_chain_created → first_agent_started
 (landing)     (landing)          (app)          (app)               (app)                 (app)                  (app)
```

The landing steps are anonymous and cookieless (in-memory PostHog), and the hop from
`invite_requested` to `app_login` is an invite email, so a landing visitor and the app user they
become are different PostHog persons. Read the funnel in two parts:

- **Landing** (`$pageview → invite_requested`) and the hand-off to `app_login`: compare unique
  counts per period (a Trends insight), not a person-level funnel.
- **App** (`app_login → … → first_agent_started`): a person-level Funnel insight with these
  events in order; break down by `platform` to compare web and desktop.

## Event taxonomy

### Landing page (www.ninjy.ai)

Lives in the `nix-homelab-config` repo (chain task T1), not in this repository. Super-properties:
`platform: 'web'`, `site: 'www'`.

| Event | When | Properties |
| --- | --- | --- |
| `$pageview` | every page load (`capture_pageview: true`) | PostHog defaults |
| `invite_requested` | the waitlist request (`/api/waitlist`) succeeds | `result` (`invited` \| `waitlisted`, else `ok`) |
| `invite_failed` | the waitlist request fails | `reason` (HTTP status or error class only) |
| `download_click` | a download link is clicked | `package` (`appimage` \| `deb` \| `headless` \| `nightly`), `os` |
| `community_click` | a community link is clicked | `channel` (`github` \| `discord` \| `whatsapp`), `location` (`nav` \| `footer` \| `other`) |

The site keeps PostHog in memory only (`persistence: 'memory'`): no cookies and no banner, and
no email in any property. Its own `/ingest` proxy runs on the `ninjy-local` nginx vhost.
The landing implementation is authoritative for these properties; keep this table in sync.

### App (web + Electron)

All app events carry two super-properties:

| Property | Values |
| --- | --- |
| `platform` | `web` \| `electron` (Electron is detected by its preload API) |
| `app_version` | `VITE_APP_VERSION`, else `package.json` `version` |

| Event | Fired when (source of truth) | Properties | Frequency |
| --- | --- | --- | --- |
| `app_opened` | the app boots (`src/ui/main.tsx`) | none | once per browser session |
| `app_login` | `/api/v1/me` answers authenticated and the user is identified (`AuthGate` in `AppShell.tsx`) | none | once per user |
| `bridge_connected` | the cached `listBridges` rows first contain an online bridge (`runtime_connected` or status `online`/`connected`), whether from a fetch or a WebSocket patch | `bridge_count`, `online_count` | once per user |
| `provider_configured` | a `listBridgeProviders` answer first contains a provider that is enabled, present and active | `provider` (type slug, e.g. `claude`), `provider_count` | once per user |
| `first_chain_created` | a `createTaskChain` mutation succeeds, or the user WebSocket reports a chain `created` (e.g. made by an agent for the user) | `chain_kind` (only from the mutation) | once per user |
| `first_agent_started` | the Hub accepts an agent launch: `createLaunchConversation`, `launchAgentInstance`, `startAgentInstance`, `startAgent` or `createAgentInstanceInChain` succeeds | `via` (endpoint name), `provider` (type slug, when given) | once per user |

The milestones are read in a Redux middleware ([`milestones.ts`](../src/ui/analytics/milestones.ts))
from Hub answers rather than button clicks, so an event means the thing happened.
`first_agent_started` means the Hub accepted the start; it does not wait for the process to be
running.

**Once per user.** A milestone is sent at most once per user per device (a local flag
`ninjy-analytics.once.<user_id>.<event>`, kept across account switches) and also sets a
`<event>_at` person property with `$set_once`, so the first occurrence is kept even when a second
device sends it again. Funnels count unique persons, so a repeat from another device does not
change them.

## Identity

- After sign-in the app calls `identify(<hub user id>)` with **no person properties**: no
  email, name or display name.
- `reset()` runs on sign-out, before identifying a different user on an in-page account switch,
  and when the signed-in user differs from the last user seen on this device (a switch across
  page loads, alongside `clearPriorUserClientState`).
- Events before sign-in (`app_opened`) are anonymous and merge into the person on identify.

## Privacy rules

- Event properties are limited to counts, type slugs and endpoint names. Never send message,
  task, chain, vault, file, prompt or terminal content, titles, names, emails or free text.
- [`sanitizeProps`](../src/ui/analytics/analytics.ts) drops anything that is not a number, a
  boolean or a string of at most 64 characters, and the event props are typed per event.
- posthog-js adds `$current_url`, `$referrer` and their `$initial_*` forms by itself. A
  `before_send` hook strips their query and hash, because the app routes in the hash and some
  routes carry secrets (for example `#/device/add?code=…`). Only origin and path are sent.
- No autocapture, session recording, surveys, heatmaps, dead clicks, exception capture or web
  experiments; `disable_external_dependency_loading` stops posthog-js from fetching remote
  scripts.
- `person_profiles: 'identified_only'`: no person profiles for anonymous visitors.
- Self-hosted and dev builds have no key, so posthog-js is not in their bundle and nothing is
  sent (see below).

## Configuration (app)

The app takes its PostHog key at **runtime**, not at build time. One build therefore runs keyless
(self-hosted, dev) or keyed (the hosted deployment), and the key never enters the bundle or the
repository.

### Runtime config: `/posthog-config.json`

```json
{"key": "phc_…", "host": "/ingest"}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `key` | yes | PostHog project API key. **Missing, empty or blank disables analytics.** |
| `host` | no | Ingest host (`api_host`). A relative value is resolved against the origin the config was fetched from. Without one, the platform default below applies. |

- **Where it is read:** web fetches the same-origin `/posthog-config.json`. Electron always
  fetches `https://web.ninjy.ai/posthog-config.json`, whatever UI origin its window loads, so a
  relative `host` becomes `https://web.ninjy.ai/ingest`. Both requests use `fetch` with
  `credentials: 'omit'` and `cache: 'no-store'`
  ([`runtimeConfig.ts`](../src/ui/analytics/runtimeConfig.ts)).
- **Format:** JSON is fetched rather than a `<script>` file (`window.__POSTHOG__`) because a
  script tag cannot be validated: an SPA `index.html` fallback served for a missing file would
  throw on the page. A bad answer only turns analytics off.
- **Off:** a 404, network error, non-JSON body (for example the SPA fallback), non-object JSON, or
  missing/empty key means analytics stays off. Nothing is thrown, shown or logged by the app
  (the browser still lists the failed request in devtools). `posthog-js` is never imported and
  no request goes to the ingest host.
- **Startup:** `main.tsx` calls `analytics.start()`, which reads the config and then imports the
  lazy `posthog-js` chunk only when a key is present. `identify`/`reset`/`track` calls made while
  the config is loading are replayed in order once a key is found, and dropped when none is.
- **Source of the key (hosted):** the sops secret
  `secrets/trusted/ai/posthog.yaml` → `posthog_project_key` in `nix-homelab-config`. The
  `web.ninjy.ai` nginx config renders it into `/posthog-config.json` (sops template
  `posthog-config-json`) and serves it unauthenticated with `Content-Type: application/json`,
  `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` and
  `Access-Control-Allow-Origin: *` (needed when Electron is pointed at another UI origin). If the
  secret is absent the location is not emitted, so the app sees the SPA fallback and stays off.
  To rotate the key, update the sops secret and redeploy; no app rebuild is needed.
- **Self-hosting:** serve your own `/posthog-config.json` at the UI origin to enable analytics,
  or serve nothing to keep it off. Electron reads the hosted config even when it points at a
  self-hosted UI.

### Build-time variables (dev override)

| Variable | Default | Meaning |
| --- | --- | --- |
| `VITE_POSTHOG_KEY` | unset | Dev override only. When set, it is used instead of the runtime config and no config is fetched. Never set it for release builds. |
| `VITE_POSTHOG_HOST` | web: `/ingest`; Electron: `https://web.ninjy.ai/ingest` | Ingest host used with `VITE_POSTHOG_KEY` (the runtime config has its own `host`). |
| `VITE_APP_VERSION` | `package.json` `version` | `app_version` super-property. |

`ui_host` is always `https://us.posthog.com`.

- **Bundle:** `posthog-js` is always built as a separate lazy chunk. It is downloaded and run only
  after a key is resolved; calls made before it loads are queued in order. If it fails to load
  (ad blocker, offline), events are dropped.
- **Ingest proxy:** `/ingest` on `web.ninjy.ai` reverse-proxies to PostHog
  (`us.i.posthog.com`, and `us-assets.i.posthog.com` for `/ingest/static`), so events are
  same-origin for the web app and less likely to be blocked. Electron loads the UI from the
  configured UI URL and posts to the absolute `https://web.ninjy.ai/ingest`.
- **CSP:** the app sets no Content-Security-Policy (neither `index.html` nor the Electron
  session), so nothing needs allowing. If one is added, allow `connect-src` for the ingest host
  only. The CSP in `src/ui/utils/htmlBundle.ts` applies to sandboxed HTML artifacts, not the app.

## Adding an event

1. Add it with its allowed properties to `AnalyticsEventProps` in
   [`analytics.ts`](../src/ui/analytics/analytics.ts).
2. Fire it from a Hub answer (the milestone middleware or the API layer), not a click handler,
   with `analytics.track` (every time) or `analytics.trackOnce` (once per user).
3. Extend [`tests/ui_analytics_test.ts`](../tests/ui_analytics_test.ts) and this document.
