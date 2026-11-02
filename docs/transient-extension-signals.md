# Transient extension signals

Provider extension ingestion performs local readiness, activity, permission and
live-tool reduction. Extension-sourced activity never queues immediate status
pushes; the normal coalesced control-plane heartbeat samples local activity.
Explicit readiness and lifecycle status remain independent. It does not queue
or forward raw events. No lifecycle or
completion event has a durable exception. The local instance metadata cache is
bounded to 256 instances; native tool state retains its existing bounded reducer.

## Token usage snapshot

The one derived value that goes upstream from extension events is a per-instance
token snapshot (`src/bridge/extension_token_usage.odin`): tool calls, the sum of
`tool.end` `metrics.est_tokens`, the latest provider `usage.context_tokens` with
its source, `output_tokens_total`, a compaction count
(a context drop of 50% or more) and its update time. Counters reset on a session
start (except `source: compact`) and on a new provider session id. It rides as an
optional `token_usage` member of `agent_instance_status`, which older hubs ignore;
a dedicated frame type would be refused by them as `unknown_frame_type`. Pushes
are bounded to one per instance per 10 seconds, or sooner when context moves by
5 percentage points of the window, and only when the snapshot changed.
`ham-ctl extension status` shows the same object locally.

## Context window

Each snapshot also carries `context_window`, `window_source`
(`override`|`config`|`default`) and, once a context size is known,
`context_pct` (whole percent, floor). The window is never detected at runtime:
a provider-reported `usage.context_window` is ignored. The bridge resolves it at
launch (`src/bridge/context_window.odin`) from, in order:

1. a user override persisted on the bridge in
   `<data_dir>/bridge/context_window_overrides.json`, keyed by provider + model
   (exact id, the configured model or its `resolved_model`); values below
   100000 are rejected;
2. the read-only config shipped in the binary
   (`src/bridge/context_windows.json`): ordered `{provider, model_regex,
   context_window}` entries, first match wins, the regex anchored to the whole
   id, tried against the configured model (which may be an alias such as
   `default`) and then the `resolved_model` from model discovery; it also
   ships `warn_pct` 40 and `rollover_pct` 70;
3. the 200000 default.

The shipped map (first match wins; `src/bridge/context_window_test.odin`
resolves every id below):

| Provider | `model_regex` | Window | Why |
| --- | --- | --- | --- |
| claude | `.*\[1m\].*` | 1000000 | explicit 1M variant |
| claude | `.*haiku-4-5.*` | 200000 | no 1M variant |
| claude | `.*(opus\|sonnet)-4-6.*` | 200000 | Claude Code needs `[1m]` for 1M on these |
| claude | `(default\|opus\|sonnet\|haiku\|fable)` | 1000000 | aliases; on the Anthropic API they resolve to the 5.5 / 5.1 models |
| claude | `claude-(opus\|sonnet\|haiku\|fable)-(5\|4-7\|4-8).*` | 1000000 | Claude 5.x and Opus 4.7+ run at a native 1M in Claude Code |
| codex | `gpt-6\.1-(sol\|terra).*` | 475000 | Codex `model_context_window`, 95% of 500K (observed on this host) |
| codex | `gpt-.*` | 258400 | 95% of Codex's default 272K; conservative for the rest |

Any other Claude id gets the 200000 default, the same assumption Claude Code
makes for a model it does not know. Sources: the Anthropic platform docs
(models overview, context windows), the Claude Code model-configuration docs,
and openai/codex issue 53336 for Codex's effective window. Caveat: a Claude
Code launched with `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` runs those models at
200K; the bridge cannot see that, so set a 200000 override for the model on
that bridge.

The hub drives overrides with the `context_window_op` frame
`{command_id, op: list|set|clear, provider?, model?, context_window?}`. The
bridge answers `context_window_op_result {command_id, op, ok, error?,
default_window, min_window, max_window, warn_pct, rollover_pct, entries,
overrides, windows:[{provider, model, resolved_model?, context_window, source}]}`
for every op, so a caller re-renders from any reply. `windows` lists discovered
models, launched instances, overrides and the pair named in the request. A set
or clear re-resolves running instances; the new window goes up with their next
snapshot.

The hub relays this frame and stores nothing
(`src/hub/transport/http/bridge_context_window_handlers.odin`, owner-checked,
10 s timeout):

| Method | Path | Op |
| --- | --- | --- |
| `GET` | `/api/v1/bridges/{id}/context-windows` | `list` |
| `PUT` | `/api/v1/bridges/{id}/context-windows` body `{provider, model, context_window}` | `set` |
| `DELETE` | `/api/v1/bridges/{id}/context-windows?provider=&model=` (or the same JSON body) | `clear` |

The hub rejects a missing provider/model and a `context_window` that is not a
whole JSON number or is outside 100000..100000000 before relaying. A bridge
`ok:false` becomes an API error (`validation_failed`, or `internal_error` for
`persist_failed`) with `details.bridge_error` set to the bridge's code. The
bridge management view in Settings shows the list (`BridgeContextWindows.tsx`)
with a source badge per row, highlights `default` rows (missing from the
shipped config), and offers 200K / 500K / 1M presets, a custom value (min 100K,
checked before sending) and clearing an override.

## Open conversations

The UI sends version 2 subscription views containing a parent conversation ID
and its explicit instance roster. An open chain coordinator conversation requests
the coordinator and each displayed member. Multiple views/tabs share one producer
per member; closing a parent releases that parent's roster. Inactive panes and
hidden documents release demand. A member's separate conversation can keep its
own subscription alive.

The hub checks conversation ownership, instance ownership and current chain
membership before accepting a replacement and again before fanout/writing queued
frames. Rejected replacements preserve existing demand. Socket authentication
uses the existing single-use tool-stream ticket. Opaque token identity is carried
through tickets and rechecked for expiry/revocation/user disable before renewal
and delivery, without updating token last-used data. Trusted proxy users are
rechecked for disabled status. No raw event history is exposed.

Viewer and producer leases expire after 15 seconds and renew every 5 seconds.
Lost detach messages therefore cannot retain a producer indefinitely. Bridge
connection generation, instance run, and subscription token fence late frames.
No unwatched completions are replayed; a fresh subscription receives current
bounded active state.

Limits are 256 instances per viewer, 64 viewers, 1024 upstream routes,
512 queued frames / 2 MiB per viewer and 64 MiB globally, including in-flight
bytes. Controls batch at most 64 members / 32 KiB. Slow viewers disconnect.
Blocker display snapshots use the same leased demand, while local permission
handling remains independent. Viewer reconnects stop after six connections or
120 seconds per failure episode.

## Compatibility and rollout

Upgrade hub, bridge and UI together. New bridges advertise
`tool_stream_demand_v2`; the hub rejects subscriptions to older bridges with
`upgrade_required`. Instance-only legacy subscriptions also fail closed.
Old attach controls cannot activate a new bridge producer without a v2 lease.

Authenticated legacy extension ingestion returns a dropped/non-persisted upgrade
response; legacy history endpoints return HTTP 410 after owner authorization.
Old tool-activity POSTs remain authenticated no-ops. Legacy blocker payloads
without subscription/run fencing are rejected. There is no safe-data forwarding
fallback. An old bridge may continue attempting its legacy POST until upgraded;
the new hub never writes those payloads.

Migration 125 drops the event table and its indexes, and clears old event-fed
provider/transcript/extension metadata from instances. It does not archive events
or run VACUUM. Cleared session metadata can be rebuilt locally by providers.

Before deployment, take the normal database backup. Rolling back the executable
does not restore the removed table or its content: restore the pre-migration
database backup as well, with the hub stopped, or roll forward with a corrected
build. Historical payloads intentionally cannot be reconstructed from this
migration. No production deployment is part of this change.

## Verification

Run `python3 scripts/verify-transient-signals.py` from the repository root.
It builds hub/bridge/CLI and UI and runs contracts, tool reducers, bridge,
SQLite, service/HTTP and affected UI tests. Four unrelated baseline failures
were separately reproduced on unchanged 35622400. The verifier reports their
names and excludes them only while their containing test source has the exact
recorded SHA256; changed source restores those tests automatically. Bridge and SQLite suites run
serially because fixtures share runtime queues / process-global mutex state.
Fresh checkouts install dependencies with `npm ci --legacy-peer-deps`.

The ingestion fixture sends 10,000 local events without creating an event
outbox. A separate wire-to-hub regression alternates 100 activity signals and
drains status after each signal: zero event-triggered frames and hub saves,
while explicit lifecycle controls still save. Removing only the activity guards
makes that fixture observe 100 saves, demonstrating the regression.
Stream fixtures cover explicit member authorization, zero-demand
rejection, sharing, expiry/lost detach, reconnect/run fences, in-flight controls,
bounded queues and legacy rejection. The SQLite upgrade fixture seeds an old
event, applies migration 125 and verifies the table and indexes are gone.
These are local tests, not production traffic or load measurements.
