# Ephemeral tool activity protocol (B1 → B2)

REQ-LIVE-1..5. This is volatile Hub memory, independent of conversation messages
and the persisted extension Activity timeline. No historical rows are deleted.
Historical `tool_activity` / `shell_run` transcript rows must be hidden by B2.

The machine-readable schema is [tool-activity-live.schema.json](tool-activity-live.schema.json).
It describes the snapshot data and owner WS frame; HTTP uses the standard envelope.

## Reads and authorization

- `GET /api/v1/agent-instances/{instance_id}/tool-activity-live`: standard
  user API authentication (trusted proxy session or user API token), same-owner
  authorization. Foreign owners receive 404. Response uses the standard success
  envelope; its `data` is the snapshot below.
- `GET /api/v1/task-chains/{chain_id}/tool-activity-live`: user authentication
  as above, or the existing bridge + instance assertion authentication.
  Requires the chain's owner; an instance caller additionally needs its current
  `chain_id` binding to match, the chain coordinator field, or an explicit
  coordinator membership in that chain.
  Foreign owner: 404; unrelated same-owner instance: 403.
- Chain membership is the current owner-scoped `agent_instances.chain_id`
  selection used by task dispatch, plus the chain coordinator and explicit
  coordinator member rows.
  A coordinator can belong to multiple chains. Worker/reviewer runs are never
  collapsed by durable agent identity. Each result includes `agent_id`,
  `instance_id`, `display_name` and that instance's full snapshot.
- Reads use identity/membership repositories for authorization only. Neither
  conversations nor historical extension events are read to reconstruct calls.

## Owner WebSocket frame / instance snapshot

Every change publishes a complete `tool_activity_live` frame on the existing
owner-authenticated user WebSocket. No additional subscription is needed.
All fields below are always present; strings may be empty when unavailable.

```json
{
  "type": "tool_activity_live",
  "instance_id": "inst_worker_1",
  "agent_id": "agt_worker",
  "display_name": "Worker 1",
  "chain_id": "chain_1",
  "epoch": "1792670400000000000",
  "generation": 1,
  "revision": 1,
  "active": [
    {
      "call_id": "[\"provider\",\"session_1\",\"child_1\",\"use_1\"]",
      "source": "provider",
      "provider_session_id": "session_1",
      "agent_id": "child_1",
      "tool_use_id": "use_1",
      "tool_name": "Read",
      "shell_session_id": "",
      "shell_run_seq": 0,
      "started_at_ms": 1792670401000
    }
  ],
  "last_completion": null
}
```

`call_id` is opaque. Sources are `provider` and `shell`. `active[].agent_id`
is a provider subagent identity; top-level `agent_id` is the durable Heimdall
identity. Shell keys include session id and run sequence. An optional canonical event
payload `shell_session_id` plus `shell_run_seq` explicitly links a provider wrapper
to that exact shell run; no command-text or timing correlation is used.
A linked provider end does not complete a still-running background shell.

When the final call ends the frame MUST clear the running UI:

```json
{
  "type": "tool_activity_live",
  "instance_id": "inst_worker_1",
  "agent_id": "agt_worker",
  "display_name": "Worker 1",
  "chain_id": "chain_1",
  "epoch": "1792670400000000000",
  "generation": 1,
  "revision": 2,
  "active": [],
  "last_completion": {
    "call_id": "[\"provider\",\"session_1\",\"child_1\",\"use_1\"]",
    "source": "provider",
    "tool_name": "Read",
    "duration_ms": 1200,
    "completed_at_ms": 1792670402200,
    "status": "completed"
  }
}
```

Render running rows ONLY from `active`. Render `last_completion.duration_ms`
as the separate last-duration value; never turn that summary into a running row.
Provider `payload.duration_ms` is used when supplied; otherwise duration is
computed from canonical timestamps. No completion means `last_completion:null`. Completion status `completed`
records an observed end, without claiming success. Failure/kill status is retained.
Missing ends do not fabricate successful completion. There is no completed list.

## Chain snapshot

```json
{
  "chain_id": "chain_1",
  "epoch": "1792670400000000000",
  "members": [
    {
      "agent_id": "agt_worker",
      "instance_id": "inst_worker_1",
      "display_name": "Worker 1",
      "snapshot": {
        "type": "tool_activity_live",
        "instance_id": "inst_worker_1",
        "agent_id": "agt_worker",
        "display_name": "Worker 1",
        "chain_id": "chain_1",
        "epoch": "1792670400000000000",
        "generation": 1,
        "revision": 0,
        "active": [],
        "last_completion": null
      }
    }
  ]
}
```

The list authoritatively replaces the current chain roster; remove absent members
and their displayed activity. For live frames, show only instances in that roster.
The owner WebSocket also carries the owner's other chains: never infer chain
membership merely from receiving a tool frame. Refetch the chain snapshot on
existing instance/chain membership resource changes and after reconnect/resync.
A coordinator explicitly belonging to multiple chains may have a different current
`snapshot.chain_id`; its roster inclusion is authoritative.

## Snapshot / live ordering and recovery

1. Open the user WebSocket and wait for `user_ws_ready`.
2. Buffer tool frames while fetching the instance or chain snapshot.
3. Replace local memory with that snapshot. For chain views replace the roster.
4. Apply buffered/live frames for selected instances only. Within the same epoch,
   apply only a strictly greater revision. Parallel publishers may deliver revision
   3 before 2; ignore 2. Every frame replaces the entire active list and summary.
5. On reconnect, `resync_required`, or stream gaps, repeat this process. The
   existing connection `stream_epoch`/`stream_seq` detects delivery gaps.
   The tool `epoch` identifies the Hub boot, and is distinct from stream_epoch.
   A changed tool epoch requires replacement even when revisions are lower.
   Do not use chat pagination or Activity history for recovery.

`generation` increments when lifecycle/session cleanup resets activity.
`revision` never decreases within an instance's Hub epoch, including resets.
A fresh Hub starts empty at revision 0, without rehydrating persisted shell rows
or extension history. Snapshots for a chain are copied under one projection lock.
Membership selection uses the current repository read; membership-change hints
require a refetch, as with the existing chain UI.

## Lifecycle, identity and bounds

- Canonical provider `tool.start` / `tool.end` use session + subagent + use id.
  Duplicate starts/ends are no-ops; an early end tombstones a delayed start.
- Provider hello/session changes, session end, subagent stop, instance terminal
  status and bridge loss clear affected active calls. Main idle does not complete
  background subagent calls. Lifecycle resets publish an empty snapshot.
- Only shell creation adds shell calls. Background conversion and row inventory
  cannot reconstruct or duplicate them. Refusal, failure, observed exit/kill and
  unobserved terminal cleanup remove the corresponding call.
- No commands or input/output bodies are retained in this projection.
- Provider events need a parseable canonical RFC3339 timestamp newer than the Hub
  boot/reset cutoff, not more than 60 seconds in the future. Historical or
  untimestamped events remain available in Activity but do not create live calls.
  Coarse timestamps at the boot/reset second are conservatively fenced.
- Memory caps: 2048 instance entries, 128 active calls per instance, 256 recent
  tombstones per instance; identity fields at most 512 bytes and tool names 128
  bytes. Tombstone eviction advances a timestamp floor, preventing old starts from
  reappearing. The projection never accumulates a completed-call list.

