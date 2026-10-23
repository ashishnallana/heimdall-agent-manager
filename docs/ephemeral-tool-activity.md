# Summary-only tool activity stream

Tools are cosmetic, best-effort display state. Bridge owns bounded current active
calls and, **only while watched**, a transient completion batch. Hub retains
subscription routing, refcounts, order metadata, and bounded outgoing queues;
it has no permanent tool-content cache. This stream never writes conversation
messages or database history. Activity, files, subagents, permissions, shell
sessions, logs and terminal streams retain their separate APIs.

## Browser contract

Open `GET /api/v1/tool-activity/stream` as a WebSocket. Use the existing single-use
`?ticket=` from `POST /api/v1/me/ws-ticket`, or normal user cookie/header auth.
Bridge/instance tokens are refused; no experiment flag is required. The old
instance/chain `tool-activity-live` REST routes, waiters, roster tokens, and
general user-event tool fan-out are removed. Full JSON schema:
[tool-activity-live.schema.json](tool-activity-live.schema.json).

Replace the entire set using **instance** IDs, not durable agent IDs:

```json
{"type":"subscribe","instance_ids":["inst_one","inst_two"]}
```

At most 256 unique IDs, each at most 64 bytes and beginning `inst_`. Every ID
must currently belong to the authenticated owner. Invalid/unauthorized replacement
is rejected atomically, preserving the previous set. Repeated sets are idempotent;
empty `instance_ids:[]` unsubscribes all. Acknowledgement:

```json
{"type":"subscribed","instance_ids":["inst_one","inst_two"]}
```

First and additional viewers earn a Bridge-produced baseline. Additional viewers
share one producer; a baseline may also reach existing viewers. Baseline has
current `active` and empty `completed_since_last`, without consuming pending
completions. Changed snapshots are coalesced at 1000 ms boundaries:

```json
{
  "type":"state",
  "instance_id":"inst_one",
  "baseline":false,
  "snapshot":{
    "type":"tool_activity_live",
    "instance_id":"inst_one",
    "agent_id":"agt_worker",
    "display_name":"Worker",
    "chain_id":"chain_one",
    "bridge_id":"brg_one",
    "availability":"ready",
    "run_count":2,
    "epoch":"1792670000000000000",
    "generation":1,
    "revision":4,
    "active":[],
    "completed_since_last":[{
      "call_id":"[\"provider\",\"s1\",\"\",\"tool_1\"]",
      "source":"provider",
      "tool_name":"Bash",
      "summary":"rg pattern src",
      "summary_truncated":false,
      "duration_ms":1200,
      "completed_at_ms":1792670002200,
      "status":"completed"
    }]
  }
}
```

Replace the entire active list on each snapshot. The completion batch contains up
to 32 calls completed since the preceding emitted upstream snapshot; oldest drops
on overflow. It drains once, with identical bytes fanned out to current viewers.
No replay guarantee, per-client ACK, retransmission, missing-callback repair,
stale-tool heuristic, or frontend history accumulation. Subsecond calls may
appear only as completions. Idle intervals send nothing, including after a
completion batch; no extra empty tick is sent merely to erase the old batch.

Active fields: `call_id`, `source`, `provider_session_id`, `agent_id`,
`tool_use_id`, `tool_name`, `summary`, `summary_truncated`, `shell_session_id`,
`shell_run_seq`, `started_at_ms`. Active and completed summaries are at most
**512 UTF-8 bytes**, cut at a code-point boundary. Bridge selects command/cmd for
Bash/exec_command; file_path/path for Read/Edit/Write; pattern for Grep/Glob;
query for WebSearch; url for WebFetch; description for Agent/Task; otherwise a
recognized readable field or tool name. Managed shell uses its registered real
command. The tracker retains no arbitrary arguments/results. Explicit shell
correlation avoids duplicate provider wrappers.

Status and protocol frames:

```json
{"type":"unavailable","instance_id":"inst_one","reason":"bridge_offline"}
{"type":"error","code":"forbidden","message":"subscription replacement rejected"}
{"type":"ping"}
{"type":"pong"}
```

Unavailable reasons: `bridge_offline`, `instance_changed`, `not_found`,
`capacity`, `state_too_large`. Error codes: `invalid_frame`,
`invalid_subscription`, `invalid_instance_id`, `duplicate_instance_id`,
`too_many_instances`, `forbidden`, `capacity`, `closed`, `unknown_type`.
Unavailable clears displayed state. Browser reconnect opens a new socket and
resends the desired set, without REST baseline or polling. Hub reattaches current
subscriptions after Bridge reconnect. Completion delivery remains best effort.
Idle receive timeouts are wakes, not EOF.

## Lifecycle and bounds

Hub asynchronously sends controls over the authenticated Bridge runtime socket:

```json
{"type":"tool_stream_attach","instance_id":"inst_one","subscription_id":"opaque_token","run_count":2}
{"type":"tool_stream_detach","instance_id":"inst_one","subscription_id":"opaque_token","run_count":2}
```

First viewer attaches, additional viewers request a baseline using the same
producer token, last viewer detaches. Token-matched detach cannot remove a
replacement. A new token discards old pending completions. A sole bounded control
worker serializes/coalesces upstream controls, never on the Bridge reader.
Bridge emits `tool_stream_reset` with its process epoch per connection, then
`tool_stream_state` carrying `epoch`, increasing `seq`, `subscription_id`,
`run_count`, `baseline`, `snapshot`. Failure controls are
`tool_stream_unavailable` with `instance_id`, `reason` and the same routing/order
fields. Hub rechecks owner, Bridge, run, connection generation and token before
delivery. Epoch/sequence and per-route generation/revision fence old responses.

Bridge retains bounded active state without viewers. **It does not serialize
snapshots, collect completions, or deliver tool snapshots without listeners.**
Last detach/Hub disconnect clears watching, pending completions and comparison
state. Ingestion only marks watched instances dirty; baseline/flush serializes
state. Visible equality excludes revision; a completion batch counts as a change.

Bounds: 256 tracker instances, 32 active calls, 32 pending completions, 32 replay
tombstones per instance; 512-byte summaries; 256 KiB upstream frame cap.
Oversized encoded states produce `state_too_large`, without replay. Tracker owned
data/array capacities have a conservative 80 MiB ceiling, excluding allocator
metadata. Bridge retains one active-only comparison per subscription. Hub allows
64 tool sockets, 1024 instance routes, 2048 coalesced upstream controls, and
512 frames / 2 MiB per viewer including its in-flight frame. Overflow shuts down
only that viewer. Each viewer has its own writer; the Bridge reader performs no
viewer socket writes or joins. The HTTP reader joins its writer before the router
closes the socket; other threads use shutdown only.

## Verification

Run `bash verify-tool-stream-backend.sh`. It enters `nix develop`, runs scoped
tracker/Bridge/Hub/HTTP regressions, then compiles Hub, Bridge and CLI. Tests cover
summary selection/UTF-8 bounds, multiple completions/drain/cap, demand gating,
one-second coalescing, real Bridge frame sockets, real HTTP upgrade/ticket/
subscription/baseline sockets, shared routes/last detach, owner isolation, slow
queue independence and basic reconnect fences. Full browser + real Hub + real
Bridge integration belongs to the dependent integration task; module tests do
not claim that coverage.
