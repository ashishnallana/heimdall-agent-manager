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

Hub traffic budget (T14). A status frame sent for any other reason carries a
pending change and counts as its push, so no usage-only frame follows it. The
hub writes the snapshot only when it differs from the stored one; an unchanged
snapshot (every status frame repeats it) causes no row write and no event. A
frame produces at most one `agent_instance` event: a token change on a frame
that also changed status rides on `status_changed` (`summary.token_changed`)
instead of a second `token_usage_changed`. Instance event summaries carry
`token_usage`, `token_usage_updated_at` and `token_totals`, so the UI patches its
cached instance and instance list without refetching. The chain overview's token
card (a hub aggregate) refetches only while it is shown, at most once per
15 seconds per chain (`src/ui/api/chainTokenUsageRefresh.ts`); a chain whose
events arrived while hidden refetches once when shown.

### Usage capability

An adapter's `ham.ext.v1` hello lists `usage` when the provider can emit
`usage.context_tokens` (Claude, Codex; not Antigravity, and Pi has no
extension). The bridge stores it as `usage_supported` on the snapshot, only
once a hello was seen (`test_ext_tokens_usage_supported_from_hello`), so the
hub and UI can tell "unsupported" (`usage_supported:false`, no figure) from
"no signal yet" (`true`, no figure) and from "unknown" (field absent). The UI
shows "Context tracking unavailable for <provider>" or "Waiting for signal"
accordingly (`tests/ui_extension_token_usage_test.ts`: `usage_supported:
unavailable copy when false, "waiting for signal" when true without a figure`;
chain rows: `chain rows: waiting / unavailable(provider) come from LIVE
instances only`). The bridge logs `usage_unavailable` once per session, only
when `usage_supported` is true (`test_ctxwin_usage_dark_log_gated_on_usage_supported`,
`test_ctxwin_usage_dark_log_state_survives_relaunch`). The `ham-ctl extension`
adapters read transcripts through one usage-source table
(`src/ctl/extension/transcript_usage.odin`;
`test_usage_source_table_covers_readers_and_antigravity_has_none`).

### Idle from `pane_diff` drives rollover

Rollover used to advance only on extension events. Activity detected from the
tmux pane (`pane_diff`) is now also fed to the state machine
(`bridge_rollover_on_activity`, `src/bridge/context_rollover.odin`): only an
explicit `idle` counts as a finished turn. `waiting_user` / `waiting_approval`
do not (`test_rollover_pane_diff_idle_advances_rollover`,
`test_rollover_pane_diff_waiting_is_not_idle`), idle reported by two sources acts
once (`test_rollover_duplicate_idle_from_two_sources_acts_once`) and idle that
was withheld is acted on when re-reported
(`test_rollover_pane_diff_idle_withheld_then_rereported`). An estimate-only
stream (Antigravity-shaped `tool.end` metrics) reaches the pending state
(`test_rollover_pending_from_estimate_only_stream`). Pane idle can only advance a
rollover that is already pending; it does not detect the threshold, so Pi (no
usage or metrics source) is not rolled over automatically.

### Thresholds: one source

`warn_pct` (40) and `rollover_pct` (70) are defined only in
`src/bridge/context_windows.json`. The bridge copies them onto every snapshot
and `context_window_op_result`; the hub stores and returns them per row, and the
UI reads them from the row (`CONTEXT_WARN_PCT` / `CONTEXT_ROLLOVER_PCT` and the
hub constants are fallbacks for rows from older bridges only).
Tests: `test_ctxwin_snapshot_thresholds_match_shipped_config`,
`test_agent_token_usage_thresholds_round_trip`,
`test_chain_token_usage_per_row_thresholds`, UI `contexts use their own
snapshot thresholds, not the first/historical pair`.

## Context window

Each snapshot also carries `context_window`, `window_source`
(`override`|`reported`|`config`|`default`) and, once a context size is known,
`context_pct` (whole percent, floor). The bridge resolves it at launch
(`src/bridge/context_window.odin`) from, in order:

1. a user override persisted on the bridge in
   `<data_dir>/bridge/context_window_overrides.json`, keyed by provider + model
   (exact id, the configured model or its `resolved_model`); values below
   100000 are rejected;
2. the read-only config shipped in the binary
   (`src/bridge/context_windows.json`): ordered `{provider, model_regex,
   context_window}` entries, first match wins, the regex anchored to the whole
   id, tried against the `resolved_model` from model discovery first and then
   the configured model (which may be an alias such as `default`); it also
   ships `warn_pct` 40 and `rollover_pct` 70;
3. the 200000 default.

A window the provider reports itself (`usage.context_window`, Codex
`model_context_window`) is layered on top: with no override it replaces the
config/default result and the source becomes `reported`; an override always
wins. The snapshot then also carries `reported_window` and `window_mismatch`,
which is true when the reported window differs from the config/default result
by more than 10% (exactly 10% is not a mismatch; never set under an override).
The Runtime card shows a "reported"
badge plus an amber note.

The shipped map (first match wins, trying `resolved_model` before the configured model; `src/bridge/context_window_test.odin`
resolves every id below):

| Provider | `model_regex` | Window | Why | Source / confidence |
| --- | --- | --- | --- | --- |
| claude | `.*\[1m\].*` | 1000000 | explicit 1M variant | Anthropic docs |
| claude | `.*haiku-4-5.*` | 200000 | no 1M variant | Anthropic docs |
| claude | `.*(opus\|sonnet)-4-6.*` | 200000 | Claude Code needs `[1m]` for 1M on these | Claude Code model-config docs |
| claude | `(default\|opus\|sonnet\|haiku\|fable)` | 200000 | unresolved alias: could be on a 200K plan, so resolve small; a known `resolved_model` is matched first and gets its own row | unverified alias target; conservative |
| claude | `claude-(opus\|sonnet\|haiku\|fable)-(5\|4-7\|4-8).*` | 1000000 | Claude 5.x and Opus 4.7+ run at a native 1M in Claude Code | Anthropic docs |
| codex | `gpt-6\.1-(sol\|terra).*` | 475000 | Codex `model_context_window`, 95% of 500K (observed on this host) | Codex rollout on this host |
| codex | `gpt-.*` | 258400 | 95% of Codex's default 272K; conservative for the rest | openai/codex issue 53336; conservative |
| pi | `anthropic/claude-(opus\|sonnet\|haiku)-4-5.*` | 200000 | Claude 4.5 models | `pi --list-models`; authoritative |
| pi | `anthropic/.*` | 200000 | every other Anthropic model in pi, including unknown or newer ids; no id is verified at 1M, so none maps large | conservative; override per model |
| pi | `openai-codex/gpt-5\.3-codex-spark.*` | 128000 | Codex Spark | `pi --list-models`; authoritative |
| pi | `openai-codex/.*` | 272000 | gpt-5.5, 5.6-\*, 6-\*, 6.1-sol | `pi --list-models`; authoritative |
| pi | `zai/glm-4\.7.*` | 204800 | GLM-4.7 | `pi --list-models`; authoritative |
| pi | `zai/glm-5-turbo.*` | 200000 | GLM-5 Turbo | `pi --list-models`; authoritative |
| pi | `zai/glm-5\..*` | 1000000 | glm-5.2, 5.2-highspeed, 5.3, 5.3-flash, 5.3-highspeed | `pi --list-models`; authoritative |
| antigravity | `gemini-.*` | 256000 | native 1048576, but a 256K platform compression limit is reported | Google model docs + third-party monitor; conservative |
| antigravity | `claude-.*` | 200000 | in-app limit unknown | undocumented; conservative |
| antigravity | `gpt-oss-120b.*` | 131072 | native gpt-oss-120b window | model card; in-app limit unknown |

Any other Claude id gets the 200000 default, the same assumption Claude Code
makes for a model it does not know. Sources: the Anthropic platform docs
(models overview, context windows), the Claude Code model-configuration docs,
and openai/codex issue 53336 for Codex's effective window. Caveat: a Claude
Code launched with `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` runs those models at
200K; the bridge cannot see that, so set a 200000 override for the model on
that bridge.

Pi and Antigravity rows come from dawnstar's `provider_models.json` and
`pi --list-models`, read on 2026-11-02 (agy 1.2.16). Pi ids are
`<provider>/<model>`, and pi's own registry gives the windows, so those rows
are authoritative. Antigravity does not document its in-app limit: the rows are
set low so rollover fires before the platform compacts. Pi has no Heimdall
extension yet, so the bridge receives neither a `usage` block nor the
`tool.end` metrics the estimate is built from: a Pi agent has no context figure
and **automatic threshold detection is unavailable for Pi** until a usage or
metrics source exists. Its window rows only take effect once such a source exists. Copilot is not in the map (no models were listed; it needed
authentication on dawnstar).

### Estimate fallback (`context_source: "estimate"`)

A provider that reports no context size but does emit `tool.end` metrics
(Antigravity: tool metrics only) would otherwise never reach the rollover
threshold. The estimate is built only from those metrics, so a provider with
neither (Pi, which has no extension) gets no figure. While no provider `usage.context_tokens` has been seen, the
bridge uses `estimated_context_tokens = (est_tokens_total since last reset) *
BRIDGE_EXT_ESTIMATE_MULTIPLIER` (`src/bridge/extension_token_usage.odin`,
default **1.5**: tool traffic understates the real context, so the estimate is
scaled up to stay conservative). The snapshot then carries
`context_source:"estimate"`, `estimated_context_tokens` and `context_pct`
computed from it; `context_tokens` stays absent (it is only ever the raw
provider figure). The estimate restarts from zero on a session start (not a
`source=compact` restart) and on a `compaction` event (either phase);
`est_tokens_total` itself remains a lifetime sum. A provider-reported usage
block always wins from then on. Rollover, the hub's `context_pct` recompute
and the UI all use this effective figure; the UI prefixes it with `~` and the
tooltip says "estimated from tool traffic".

| Source | `context_source` | Confidence |
|---|---|---|
| provider usage block (Claude/Codex transcript) | the provider's `usage.source` | measured |
| tool-metrics fallback | `estimate` | rough, deliberately high (x1.5) |

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
