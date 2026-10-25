# Bounded action synchronization and startup recovery

This implements the reviewed design in task `task_18e18418335ffe9e`. No production deployment is included. The historical caller binary, credential identity, and exact old 401/409 reasons remain unproven.

## Retry contract

Action-list recovery, startup confirmation, PTY readiness reminders, and credential renewal use at most six attempts and 120 seconds, including the first attempt. Reminders also respect the existing startup timeout. Each HTTP attempt has at most ten seconds, reduced to the remaining operation budget. DNS/connect/TLS/write/read share that monotonic deadline; slow incoming bytes cannot reset it. Unix TLS relays are killed before reaping during teardown. An unsupported bounded transport returns `not_implemented`; the Windows TLS/system-DNS path is deliberately unavailable to these new strict callers until its backend can enforce cancellation. Existing HTTP APIs retain their compatibility behavior.

The outer controller preserves wire error code/class/retry-after. Fatal and recoverable refusals park; only retriable failures receive bounded backoff with up to 20% jitter and the complete server delay floor. Duplicate startup signals, reconnects, epoch/revision changes and local token rotation do not create fresh failed budgets. A committed credential repair can resume an authentication wait with its original deadline and attempt count. Same-launch generation rejection remains parked.

Readiness identity uses instance ID, run count and a hash of the authenticated launch assertion. Local bearer rotation transfers that identity. Completion rechecks current launch and stop intent; an old completion cannot mark a stopped or replacement launch ready.

## Local durability and uncertain effects

The per-bridge state directory contains a mode-0600 `retry-journal-v1.json`, atomically replaced with file and directory sync. Reservations are durable before I/O. Its initialization marker distinguishes first use from a journal missing after restart. Invalid schema, unknown version, backwards wall clock, missing initialized journal, persistence failure or capacity exhaustion parks work instead of granting attempts. There are at most 4,096 receipts and two MiB of journal data. Live terminal/unknown fences are never evicted to admit new work; the current implementation conservatively retains receipts rather than guessing that an identity is unreachable.

A rotated credential pair is held in a separate mode-0600 pending-rotation record. Refresh and access replacements commit in that order before adoption. Local commit retries spend the same renewal budget and never repeat an exchange of the spent token. Every rotation has a request id, generated and made durable (`<credential>.refresh-request-v1`) before the first send and sent as `X-Heimdall-Refresh-Request-Id` on every attempt. A lost or malformed post-send refresh response is an unknown outcome and is retried with the same request id; the hub answers a retry of the exact rotation it already performed for up to 10 minutes (`BRIDGE_REFRESH_RETRY_GRACE_SECONDS`, only while no descendant token was redeemed) instead of treating the spent token as stolen. A terminal renewal receipt for a retriable reason (exhausted budget, lost reply, crash mid-request) is reopened with a fresh bounded budget at every start and after a 60-second pause, so it never stops renewal across restarts; a refused refresh token (401) still stops and wipes. A durable pair can resume local commit after restart.

A graced re-grant on the hub (the request-id retry or the 30-second crash grace) is one `BEGIN IMMEDIATE` transaction on the dedicated commit connection: a compare-and-set claim on the spent refresh row (`regrant_claim`), revocation of the never-delivered newer generations, and both new rows. A failure anywhere rolls the claim back, so the next retry still recovers. The grace ends once any newer generation was delivered: its access token authenticated something (`first_used_at`) or its refresh token was redeemed. A presentation that loses the claim race is treated as a second holder of the token, so it revokes the whole family, including the pair the winner just received. This is intentional: a bridge must send its retries one at a time, and one that double-sends a retry loses its enrollment.

A due-slot receipt fences the wake/resolve/create/execute pipeline before its first side effect. It records the selected target before execution. Unknown launch or POST outcomes park that slot: subsequent ticks, queue replacement, lease expiry and restart cannot repost or mint another instance. This is conservative: a transient/uncertain failure may require operator reconciliation rather than automatic delivery. The change does not claim transactional exactly-once message or external hook delivery across a crash.

Keep the journal, marker and any pending pair together during backup/recovery. Do not delete an unknown slot receipt to make a schedule run again. Reconcile its target and delivery outcome against the hub first. Capacity cleanup likewise requires proof that removed identities cannot be authenticated or recreated.

## Coherent snapshots and freshness

Migration 126 adds a singleton durable global action revision. Action writes and instance bridge/ID membership changes update it in the same database transaction through triggers; runtime-status/last-seen updates do not. The hub also creates a random process epoch.

The action-list handler authenticates first. A serialized, dedicated read connection reads revision and scoped rows in one SQLite read statement/transaction. A matching canonical validator bypasses the action rows and returns 304; any other validator receives a full snapshot. Read errors return errors, never empty successful lists. Heartbeats add one scalar revision read, with no action scan or schedule-related write. Numeric legacy versions remain additive compatibility fields.

A bridge installs the exact server validator after validating a complete owned candidate queue. It rejects malformed/truncated snapshots, duplicate IDs, missing metadata, old connection/credential responses and decreasing revisions within an epoch. Newer invalidations arriving during a fetch remain pending. Queue jobs own their strings; a matching local in-flight slot retains its lease timestamp.

No more than one list request is in flight, and requests are at least one second apart. A healthy idle bridge does no action GET after initial synchronization except the daily backstop. Matching heartbeats revalidate the cache locally. Execution is disabled during pending newer snapshots, terminal auth failures, cold restart, or 120 seconds without current matching validation. Healthy visibility is bounded by heartbeat interval + one scheduler tick + ten-second request, approximately 71 seconds at the 60-second heartbeat maximum. Outages have no delivery guarantee and become visibly parked/exhausted.

Older bridges remain compatible with the additive hub fields but must be upgraded to remove their retry storms. A new bridge receiving legacy snapshots without coherent metadata parks with `not_implemented` and disables execution.

## Observability and operator recovery

Heartbeats contain aggregate `operation_recovery` state, attempts and remaining counts, journal failure and capacity state. The hub exposes `heimdall_bridge_recovery_receipts` by bridge, bounded operation/state/code/class labels; it writes no new telemetry rows. Transition logs contain a hashed identity and enums, not credentials or request bodies. The local `start-success` response reports the same receipt and returns a terminal error after exhaustion/rejection.

After repairing credentials/configuration, an operator may stop the bridge and explicitly start a new sync episode:

```bash
ham-bridge recovery resume-sync <the same hub/bridge/config arguments used by the service>
```

After re-enrollment/configuration repair, `recovery resume-refresh` likewise starts a new renewal episode for the same bridge identity. It refuses while a pending rotated pair exists, so a spent-token exchange cannot replace local commit recovery.

Each command takes the service config and hub/bridge scope locks before loading or rewriting the journal and holds them through the durable write. A running service/enrollment prevents recovery. Healthy credentials are not required, but refresh recovery requires the same effective credential-file path used by the service (including `HAM_BRIDGE_TOKEN_FILE`) and refuses any pending pair there. Recovery does not perform enrollment repair before acquiring exclusion.

Each command exits after updating its controller receipt. Restart the service normally, without retaining this one-shot command in its service configuration. It refuses to clear readiness/unknown execution fences or a corrupt journal. Automatic reconnects do not invoke it.

## Verification and rollout

Run the task verifier from its checkout:

```bash
python3 scripts/verify-action-recovery.py
```

It builds hub, bridge and CLI, and tests contracts, transport libraries, bridge, SQLite, auth/bridge/agent services and HTTP handlers. It retains the four previously reproduced, source-hash-guarded unrelated baseline exclusions documented by the transient-signal task. No recovery test is excluded. Windows local-socket code is cross-checked separately; the current toolchain's existing SChannel certificate declarations prevent a complete Windows TLS cross-check.

Required deployment order is hub migration/additive metadata first, then bridges. Inspect version inventory and operation state, action GET rate, DB busy/transaction metrics and revision/write budgets before and after. No live load test or deployment is part of this change.

For rollback, retain migration 126 and its triggers and all local receipt schemas. Use a bounded-retry-capable binary; an older unbounded scheduler/readiness relay must be stopped rather than reintroducing the incident loop. Restart the hub after database restore so a new epoch invalidates old validators. Unknown newer receipt versions park safely.
