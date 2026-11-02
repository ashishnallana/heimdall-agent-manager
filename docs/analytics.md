# Product analytics (PostHog)

Ninjy sends a small set of funnel events to PostHog Cloud (US) so we can see where new users
drop off between the landing page and their first running agent. It covers two clients that
share one PostHog project:

| Client | Code | Gated by |
| --- | --- | --- |
| Marketing site (`www.ninjy.ai`, `homelab/sites/heimdall/` in `nix-homelab-config`) | `posthog-js` snippet + shared `assets/analytics.js` | the key constant in that file (empty = off) |
| App: web (`web.ninjy.ai`) and Electron desktop | [`src/ui/analytics/`](../src/ui/analytics) | `VITE_POSTHOG_KEY` at build time |

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
- `reset()` runs on sign-out, and before identifying a different user on an account switch.
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

| Variable | Default | Meaning |
| --- | --- | --- |
| `VITE_POSTHOG_KEY` | unset | PostHog project API key (`phc_…`). **Empty or unset disables analytics entirely.** |
| `VITE_POSTHOG_HOST` | web: `/ingest`; Electron: `https://web.ninjy.ai/ingest` | Ingest host (`api_host`). |
| `VITE_APP_VERSION` | `package.json` `version` | `app_version` super-property. |

`ui_host` is always `https://us.posthog.com`. All three are Vite build-time variables: set them in
the environment of `npm run build` / `vite build`.

- **No key:** `main.tsx` checks `import.meta.env.VITE_POSTHOG_KEY`, which Vite replaces at build
  time. Without a key the check is constant-false, so the dynamic `import('posthog-js')` is
  removed and the bundle contains no PostHog code at all.
- **With a key:** posthog-js is a separate lazy chunk loaded after boot; calls made before it
  loads are queued in order. If it fails to load (ad blocker, offline), events are dropped.
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
