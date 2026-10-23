# Ephemeral live tools: Bridge owner, Hub relay

REQ-LIVE-1..3/5/7/8/9. Bridge alone owns active provider/shell calls and one last
completion per agent instance. Hub authenticates and forwards frames and proxies
explicit snapshot requests. It retains no tool-content cache, completed list,
tombstones, or historical state. No conversation tool_activity/shell_run writes
occur; the authenticated legacy tool-activity endpoint returns
{"accepted":true,"persisted":false}. Historical rows are not deleted. Separate
Activity/file/subagent/permission persistence and shell controls/logs remain.

## UI protocol

Authenticate the existing user WebSocket with its ticket/cookie flow. REST uses
the existing authenticated API envelope. Exact snapshot schema:
[tool-activity-live.schema.json](tool-activity-live.schema.json).

GET /api/v1/agent-instances/:instance_id/tool-activity-live performs one bounded
request over the owning Bridge's existing authenticated command WebSocket.
No chat, extension history, shell inventory, or cached Hub tool state is read.
Owner checks use existing get_instance authorization.

Example response data and live user-WS frame (stream_epoch/stream_seq are added
only by the existing user event bus):
```json
{
  "type": "tool_activity_live",
  "instance_id": "inst_worker",
  "agent_id": "agt_worker",
  "display_name": "Worker",
  "chain_id": "chain_one",
  "bridge_id": "brg_one",
  "epoch": "1792670000000000000",
  "generation": 1,
  "revision": 4,
  "availability": "ready",
  "active": [
    {
      "call_id": "[\"provider\",\"session\",\"child\",\"tool_1\"]",
      "source": "provider",
      "provider_session_id": "session",
      "agent_id": "child",
      "tool_use_id": "tool_1",
      "tool_name": "Read",
      "shell_session_id": "",
      "shell_run_seq": 0,
      "started_at_ms": 1792670001000
    }
  ],
  "last_completion": null
}
```

Final completion replaces active with [] and sets last_completion to one object:
```json
{
  "call_id": "[\"provider\",\"session\",\"child\",\"tool_1\"]",
  "source": "provider",
  "tool_name": "Read",
  "duration_ms": 1200,
  "completed_at_ms": 1792670002200,
  "status": "completed"
}
```
Other statuses: failed, killed, exited, interrupted. Missing observed end never
means successful completion. Returning from an explicitly correlated provider
wrapper does not finish a background shell.

Additional owner-scoped WS frames:
```json
{"type":"tool_activity_live_unavailable","instance_id":"inst_worker","availability":"unknown"}
```
```json
{"type":"tool_activity_live_resync","bridge_id":"brg_one"}
```
Unavailable clears visible state and fences buffered pushes until a fresh
snapshot succeeds. Existing instance/Bridge terminal lifecycle events also clear
offline state. Resync is emitted on Bridge reconnect, actual agent launch/relaunch,
and dirty-queue overflow/rate shedding. It triggers one initial/resync read,
never a periodic status request.

GET /api/v1/task-chains/:chain_id/tool-activity-live?cursor=:last_instance_id
returns a lexicographically sorted page of at most eight current same-owner
instances, including the canonical coordinator and explicit coordinator members.
Each page independently checks owner/current chain membership. Instance tokens
must currently belong to the chain or be an explicit/canonical coordinator.
```json
{
  "chain_id":"chain_one",
  "roster_token":"9e72abdf801e0314",
  "next_cursor":"",
  "members":[
    {"agent_id":"agt_worker","instance_id":"inst_worker","display_name":"Worker","availability":"offline","snapshot":null}
  ]
}
```
Ready members carry the snapshot above. Continue cursor pages only as part of
initial/reconnect/resync/membership-triggered loading. Replace the roster only
after the complete page set. Restart loading if roster_token changes across
pages or a membership-change hint arrives. Token is a bounded non-security FNV
fingerprint of current sorted instance IDs; all authorization is independent.
Roster capacity is 256. Over-cap rosters return validation_failed; no silent
partial roster. One page has an absolute five-second assembly deadline; members
unavailable within it become null/offline.

Errors use shared repository mapping: bridge_offline is HTTP409 (disconnected,
cancelled or deadline); bridge_busy HTTP503 (bounded request capacity);
validation_failed HTTP422; owner/auth errors retain existing 403/404 behavior.
Retries may occur after actual failure with bounded backoff, never on success.

## Ordering and recovery

1. Wait for user_ws_ready, then buffer relevant tool frames while fetching the
   explicit instance snapshot or complete chain page set.
2. Replace local state with fresh snapshots. Apply buffered/live frames only for
   currently selected/authorized instance IDs.
3. epoch is Bridge boot Unix-nanoseconds as a decimal string. Compare with BigInt
   or decimal-string ordering; never round through Number. A newer Bridge epoch
   replaces old state; older epochs are ignored.
4. Within one epoch accept only strictly newer revision. Every frame completely
   replaces active and last_completion. generation advances on local lifecycle
   reset; revision remains monotonic, including inactive reclamation/re-admission.
5. Reconnect, user-stream gap/resync_required, Bridge resync, and membership changes
   initiate a fresh one-shot read. There is no polling. A still-live Bridge
   answers current state after Hub restart; a restarted Bridge starts empty.
6. Unavailable remains fenced until that read succeeds. A live frame alone
   cannot undo an offline boundary. A launch/relaunch resync explicitly recovers.

Hub validates instance-to-Bridge binding, owner and current run_count for every
snapshot/live frame. Current Bridge socket generation fences replaced sockets.
Its immutable process epoch is established once on that connection; old epochs
cannot replace it. Connection-local sequence fences reordered live frames.
No historical extension or shell rows repopulate Bridge state.

## Bridge/Hub internal frames

Bridge -> Hub first sends tool_activity_live_reset {epoch,seq}; epoch is immutable
until a new socket connection. It then sends tool_activity_live_resync. Changes:
tool_activity_live_snapshot {epoch,seq,run_count,snapshot}; snapshot is the same
source snapshot, with internal run_count and without Hub-sourced labels.
Hub overwrites labels/owner routing from current bounded identity metadata.

Hub -> Bridge: tool_activity_live_request {request_id,instance_id,timeout_ms:5000}.
Bridge -> Hub: tool_activity_live_reply {request_id,epoch,run_count,snapshot}.
Replies bypass the generic runtime result cache. Only a matching unexpired
waiter for the current socket generation, instance/run/owner can retain a reply.
It is freed immediately after the caller consumes it or the request terminates.
Unsolicited/late replies are dropped. Waiting uses a condition variable, not
recurring network/RPC queries. Source changes are coalesced by instance; only
the latest unsent snapshot survives.

## Memory, admission and backpressure

- Bridge: 256 instance entries, 32 active calls and 32 key-only tombstones per
  instance. Decoded identity fields <=64 bytes; names <=96 bytes; generated keys
  <=2048 bytes. These field/count/dynamic-capacity bounds give a conservative
  <=48MiB owned content/backing ceiling (allocator bookkeeping/RSS is external).
  No input/output/commands are stored. One last completion, never a completed list.
- Bridge dirty queue: <=256 latest-only entries and <=8MiB encoded bytes, checked
  for both insertion and replacement. Overflow drops queued copies and sends
  one explicit resync hint; it does not grow or reconstruct from history.
- Live frame/reply <=256KiB and depth<=8, with <=4096 string/container tokens,
  checked before parsing/cloning at the tool boundary. Existing generic WS
  reader/chunk buffers have their separate transport caps.
- Hub: eight transient snapshot waiters globally, two per owner, <=256KiB reply
  each (<=2MiB retained reply content); request ID<=128 bytes, owner<=512 bytes,
  instance/Bridge IDs<=64 bytes. Five-second absolute deadline, terminal/socket
  cancellation and cleanup. No permanent tool-content state.
- Chain: two page assemblies globally, one per owner, eight snapshots/<=2MiB
  per page; one absolute five-second page deadline. Routing roster SQL LIMIT257
  detects capacity overflow without reading unbounded instance history.
- Hub live relay: zero queued tool content. Each Bridge connection admits up to
  128 frames and 4MiB per one-second window; shedding emits a resync hint.
  Existing user event bus has 128 socket slots, serialized per-slot writes,
  five-second write deadlines and failed/slow-socket removal. Existing stream
  sequence/gap recovery obtains fresh Bridge state.
- Capacity reclaims the least recently touched inactive Bridge entry; active
  calls are never evicted. A global admission timestamp floor retains forgotten
  lifecycle/tombstone fences and a revision floor prevents rollback. Under
  pressure, delayed legitimate starts at/before that floor are conservatively
  ignored; future events recover tracking. All-active admission refuses new
  instances until inactive capacity exists.
- Canonical provider timestamps must be parseable RFC3339, newer than boot/reset
  cutoff, and no more than 60 seconds ahead. Coarse cutoff-second events may be
  conservatively ignored. Lifecycle cleanup retains cutoffs even for unseen
  instances. Actual successful shell restart retires the old run and starts
  the new key; failed/refused spawn does not invent a running call.
