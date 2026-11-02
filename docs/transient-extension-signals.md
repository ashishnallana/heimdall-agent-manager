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
   ships `warn_pct` 60 and `rollover_pct` 80;
3. the 200000 default.

The hub drives overrides with the `context_window_op` frame
`{command_id, op: list|set|clear, provider?, model?, context_window?}`. The
bridge answers `context_window_op_result {command_id, op, ok, error?,
default_window, min_window, max_window, warn_pct, rollover_pct, entries,
overrides, windows:[{provider, model, resolved_model?, context_window, source}]}`
for every op, so a caller re-renders from any reply. `windows` lists discovered
models, launched instances, overrides and the pair named in the request. A set
or clear re-resolves running instances; the new window goes up with their next
snapshot.

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
