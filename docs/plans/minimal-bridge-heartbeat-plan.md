# Minimal Bridge heartbeat implementation plan

**Status:** plan only — awaiting independent review and explicit user approval. No production code, runtime state, deployment, restart, extension install or Git publication is authorized by this document.

- Task: `task_18e21428f41d2209` (REQ-HBP-1 … REQ-HBP-4).
- Source baseline: `dec3c833ce817e4575d4d78b1a35ecda8ea430e6` (assigned worktree). All `path:line` references are at this commit.
- Inputs: approved audit `task_18e209204d8ad6ea` ([report](artifact://art_18e209d63725a651), [evidence](artifact://art_18e209d4381c3a43)) at snapshot `1c75ee445a2b5d149731004bd95de28f7508b7c2`; approved diagnostic `task_18e20277815cb2b5`.
- **Changed assumptions since the audit:** none for this scope. `git diff --stat 1c75ee44 HEAD` over every heartbeat producer, decoder, service, repository, reaper, metrics and search file listed in the brief (plus `src/contracts/bridge.odin`, `src/hub/service/bridge_runtime/runtime_protocol.odin`) is empty, so audit line numbers remain valid. The 42 files that did change between the snapshots are outside this path.

## 1. Summary table

| Kind | Statement | Evidence |
| --- | --- | --- |
| Confirmed | Heartbeat is hand-built JSON with 15 top-level members; `stats` is optional; reliability objects are unconditional. | `src/bridge/hub_runtime_client.odin:3210-3282` |
| Confirmed | Durable Bridge `last_seen_at`/`Online` are refreshed **only** inside `update_runtime_capabilities`, which the Hub calls only when the frame text contains `"capabilities"`; it does a full-row `INSERT … ON CONFLICT` save. | `src/hub/transport/http/bridge_handlers.odin:2337-2345`; `src/hub/service/bridge/bridge_service.odin:260-284`; `src/hub/repository/sqlite/bridge_repo_sqlite.odin:72-75` |
| Confirmed | Hello persists four features (incl. `tool_stream_demand_v2`) via `bridge_runtime_connect` before `bridge_ready`; every heartbeat then replaces the record with a hardcoded three-feature list. | `hub_runtime_client.odin:3933` vs `:3964`; `bridge_service.odin:198-213`; `bridge_handlers.odin:1747`, `:1795` |
| Confirmed | Typed heartbeat instance report decodes only id/launch_epoch/state_seq/runtime_status/activity_status; `activity_source` and `error` are ignored. | `bridge_handlers.odin:2697-2703` |
| Confirmed | Empty `active_instance_ids` + non-empty digest falls back to **all** digest IDs, including terminal ones. | `bridge_handlers.odin:2352-2357`, `:2766` |
| Confirmed | Absent search members overwrite live projection with false/false/0; missing metric scalars parse as 0. | `bridge_handlers.odin:2331-2335`; `bridge_heartbeat_stats.odin:254-258` |
| Confirmed | Heartbeat `protocol_version` is a literal `1`; hello sends `contracts.BRIDGE_WS_FRAME_VERSION` (2), which `runtime_accept_hello` checks. The heartbeat arm never reads `protocol_version`. | `hub_runtime_client.odin:3232`, `:3938`; `bridge_handlers.odin:1730`; `src/hub/service/bridge_runtime/runtime_protocol.odin:31` |
| Confirmed | Unknown Bridge frame types get `protocol_error`/`unknown_frame_type` — a new frame type must never be sent to an old Hub. | `bridge_handlers.odin:2676-2679` |
| Confirmed | A Hub→Bridge command with wire type `set_telemetry` (built by `bridge_set_telemetry_payload`) already exists and toggles `heartbeat_stats` at runtime. | `bridge_handlers.odin:3202-3209`; `hub_runtime_client.odin:843-856` |
| Confirmed | The heartbeat path has **three** full-row Bridge writers, each a read-modify-write `INSERT … ON CONFLICT DO UPDATE` over every mutable column: `update_runtime_capabilities` (liveness+capabilities), `update_vault_status` (on change only) and, on disconnect, `mark_bridge_offline`. | `bridge_service.odin:260-284`, `:382-412`, `:245`; `bridge_handlers.odin:2349`; `bridge_repo_sqlite.odin:75` |
| Confirmed | The Bridge sends its first heartbeat one full interval (45s) after connecting, not immediately: `last_heartbeat` is initialised to `now` at loop start. | `hub_runtime_client.odin:577`, `:666`; `bridge_handlers.odin:3144` |
| Confirmed | The heartbeat decoder also accepts a legacy `digest` array, preferred over `instances` when non-empty. | `bridge_handlers.odin:2706-2710`, `:2746-2747` |
| Recommended | Recurring core = 8 top-level members, 5-member instance tuple, unchanged ~45s cadence. | §2 |
| Recommended | Features/capabilities travel only in hello (full replacement per authenticated connection); heartbeat omission is negotiated via a `bridge_ready` flag. | §4 |
| Recommended | Consumed diagnostics move to a negotiated `bridge_diagnostics` WS frame (full snapshots); unconsumed members are removed. | §3, §4.3 |
| Recommended | Hub-first: liveness write separated from capability processing with a narrow `UPDATE`, generation-fenced. | §5 |
| Unresolved | External alert / scrape SLOs; diagnostic cadence (proposal 180s is **not** justified yet); error-repair guarantee; live cardinalities and DB/CPU costs. | §8 |

## 2. REQ-HBP-1 — validation of the recurring core

The audit's proposal is challenged member by member below. "Alternative" names the strongest on-change + repair design and why it is not chosen *now*.

| Member | Why it must recur (freshness / recovery) | On-change + repair alternative | Verdict |
| --- | --- | --- | --- |
| `type` | Routes to the heartbeat arm, which is the only path doing liveness, reconciliation and the schedule/supersede ack (`bridge_handlers.odin:2328`, `:3218`). | n/a | Retain (envelope). |
| `protocol_version` | Not validated by Hub; costs ~22 bytes. Removing it gains nothing and changes the legacy envelope shared with other frames. It is **not** the negotiated version — hello v2 is. | Drop entirely in a future envelope revision. | Retain as constant `1`; document that it is the legacy per-frame envelope, unrelated to hello's negotiated `2`. |
| `vault_status` | Re-samples key availability that can change outside commands (keyring/filesystem); repairs a lost `bridge_vault_status` push; unchanged values skip write/publish (`bridge_service.odin:353-362`). UI search eligibility depends on it (`src/ui/utils/taskChainSearch.ts:196`). | Watch keyring + ack'd `bridge_vault_status` — requires a watcher that does not exist. | Retain. |
| `task_chain_search_ready` / `_stale` / `_revision` | No separate status push exists; readiness changes after connect; projection is in-memory and lost on Hub restart (`runtime_registry.odin:499`). The three must stay an atomic tuple. | Whole tuple sent on change + at connect with Hub ack of revision. ~95 bytes saving; needs presence-aware application because absence currently means false/false/0. | Retain for now; listed as optional later task T8. |
| `active_instance_ids` | Complete positive liveness set: refreshes durable instance `last_seen_at`, prevents 90s stale → unreachable (`agent_service.odin:1301`), drives superseded-token invalidation in the ack. Cannot be event-driven without replacing lease semantics. | Lease renewal frame — equivalent bytes, more machinery. | Retain every beat. |
| `instances[]` (tuple) | Repairs dropped `agent_instance_status` pushes whose acks are deliberately ignored (`hub_runtime_client.odin:809`); rebuilds runtime registry/quota after Hub restart (`runtime_registry.odin:598`) — today only at the first heartbeat, 45s after reconnect (see §5 item 4, T1b). | Ack'd status pushes with resend + connect-time snapshot; would let terminal rows stop recurring. | Retain every beat; remove `activity_source` and `error` from the heartbeat tuple (§3). |

Instance tuple semantics (unchanged): `agent_instance_id` binds the canonical row on this bridge; `launch_epoch` rejects superseded launches; `state_seq` orders most updates (not strictly — `agent_service.odin:1138` lets lower/equal active reports recover unreachable/starting; `runtime_registry.odin:612` differs); `runtime_status`/`activity_status` repair durable and UI projections.

**Active vs terminal inventory.** `active_instance_ids` lists only instances with an active runtime status (`hub_runtime_client.odin:3255`); `instances[]` lists every instance with a non-empty status, active or terminal (`:3265`), until the Bridge's local expiry drops it. Terminal rows recur so a dropped terminal status push is repaired; keep this until status pushes are acknowledged.

**Presence / empty / malformed handling (target contract).**

| Input | Current Hub behaviour | Target |
| --- | --- | --- |
| `active_instance_ids: []` with complete `instances[]` that has active entries | Falls back to digest IDs **including terminal** | Fallback filters to active runtime statuses only (T2). |
| `active_instance_ids: []`, `instances: []` | Empty set: all instances become eligible for unreachable after 90s | Unchanged — an empty complete inventory is authoritative. |
| member absent | Parsed as empty → same as above | Absent is **not** authoritative absence: skip absence reconciliation for that beat, still refresh Bridge liveness, count `bridge_frames_rejected{reason=inventory_absent}` (T2). |
| malformed/truncated `instances` | Digest parses to nil, active set still applied | Reject whole inventory (no absence mutation) and count rejection; still refresh Bridge liveness (T2). |
| legacy `digest` alias (no current producer emits it; `hub_runtime_client.odin:3210-3282` sends only `instances`) | Non-empty `digest` wins over `instances` (`bridge_handlers.odin:2746`) | **Retained** on the decoder for old/unknown Bridges; T2 applies the same absent/empty/malformed rules to whichever array is selected, and a frame carrying both with differing contents is treated as malformed. Removal is deferred to a future envelope revision after the alias is confirmed unused in the fleet (D6). |

### 2.1 Representative target JSON (illustrative values, not captured traffic)

Idle Bridge, no instances:

```json
{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"locked","task_chain_search_ready":false,"task_chain_search_stale":false,"task_chain_search_revision":0,"active_instance_ids":[],"instances":[]}
```

Two running agents:

```json
{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":false,"task_chain_search_revision":412,
 "active_instance_ids":["inst_18e1aa00000000a1","inst_18e1aa00000000b2"],
 "instances":[
  {"agent_instance_id":"inst_18e1aa00000000a1","launch_epoch":"ep_18e1aa0000000001","state_seq":1729940000123,"runtime_status":"running","activity_status":"busy"},
  {"agent_instance_id":"inst_18e1aa00000000b2","launch_epoch":"ep_18e1aa0000000002","state_seq":1729940000456,"runtime_status":"running","activity_status":"idle"}]}
```

Terminal status repair (the immediate `failed` push was dropped; the instance is no longer active but its tuple still recurs):

```json
{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":true,"task_chain_search_revision":412,
 "active_instance_ids":["inst_18e1aa00000000b2"],
 "instances":[
  {"agent_instance_id":"inst_18e1aa00000000a1","launch_epoch":"ep_18e1aa0000000001","state_seq":1729940009001,"runtime_status":"failed","activity_status":"idle"},
  {"agent_instance_id":"inst_18e1aa00000000b2","launch_epoch":"ep_18e1aa0000000002","state_seq":1729940000456,"runtime_status":"running","activity_status":"idle"}]}
```

Note: this repairs `runtime_status=failed` but **not** the failure's error object (§3 row `instances[].error`).

## 3. REQ-HBP-2 — exhaustive current → target mapping

Decision codes: **E** every beat · **C** startup/reconnect (hello) · **O+R** on change with repair · **D** separate diagnostics snapshot (§4.3) · **X** remove from wire (local measurement may remain).

### 3.1 Top-level (15)

| # | Member | Current consumer | Decision | Compatibility / what remains |
| --- | --- | --- | --- | --- |
| 1 | `type` | dispatch `bridge_handlers.odin:2328` | E | — |
| 2 | `protocol_version` | none (heartbeat arm) | E (constant) | — |
| 3 | `vault_status` | `bridge_service.odin:353` | E | — |
| 4 | `task_chain_search_ready` | `runtime_registry.odin:499` | E | — |
| 5 | `task_chain_search_stale` | same | E | — |
| 6 | `task_chain_search_revision` | same | E | — |
| 7 | `capabilities` (always `[]`) | presence triggers capability save **and liveness** (`bridge_handlers.odin:2337`) | C (hello only) after T1+T3 | Old Hub needs it for liveness → kept unless `bridge_ready.heartbeat_metadata_omission=true`. |
| 8 | `features` | replaces persisted list (`bridge_service.odin:271`) → gates `tool_stream.odin:528`, `instance_reconfiguration.odin:53`, `content_service.odin:462` | C after T1+T3; legacy fallback must serialize `BRIDGE_RUNTIME_FEATURES` (T0) | Fixes `tool_stream_demand_v2` erasure. |
| 9 | `command_dispatch` | `bridge_heartbeat_stats.odin:207` (4 members) | D (consumed members) / X (rest) | §3.2 |
| 10 | `dependency_breakers` | `bridge_heartbeat_stats.odin:231` (2 members) | D / X | §3.2 |
| 11 | `http_retries` | `bridge_heartbeat_stats.odin:219` | D | §3.2 |
| 12 | `operation_recovery` | `bridge_heartbeat_stats.odin:190` (rows subset) | D / X | §3.2 |
| 13 | `stats` (optional) | `bridge_heartbeat_stats.odin:124-177` | D | §3.2 |
| 14 | `active_instance_ids` | `agent_service.odin:1301`, ack supersede | E | — |
| 15 | `instances` | `bridge_handlers.odin:2697-2766` | E (5-member tuple) | §3.2 |

### 3.2 Nested members

| Member(s) | Consumer evidence | Decision | Removal justification / local measurement |
| --- | --- | --- | --- |
| `features[]` strings | `bridge_service.odin:271` | C | — |
| `capabilities[]` | always `[]` at both producers; UI provider pickers use lazy discovery (`src/ui/api/endpoints/bridgeSupport.ts:182`, `:403`) | C (stays `[]` in hello for compatibility) | — |
| `command_dispatch.accepted/.rejected/.completed/.deadline_expired` | `bridge_heartbeat_stats.odin:207` counter_set | D | — |
| `command_dispatch.queued/.active_workers/.owned_bytes/.outbox_bytes/.queued_cost/.stale_completions/.response_backpressure/.queue_high_water/.max_queue_wait_ms/.max_execution_ms/.max_loop_delay_ms` | not read by any Hub decoder (`rg` over `src/hub`, `src/ui`) | X | Local dispatcher bounds unchanged (`hub_command_dispatch.odin:768`); values remain in Bridge logs/local diagnostics. Adding a consumer later is a new, separately justified field. |
| `dependency_breakers.open/.opened` | `bridge_heartbeat_stats.odin:231` | D | — |
| `dependency_breakers.tracked/.rejected` | not read | X | Breaker logic is local (`dependency_breaker.odin:94`). |
| `http_retries.retry/.recovered/.gave_up/.deferred` | `bridge_heartbeat_stats.odin:219` | D | — |
| `operation_recovery.rows[].operation/.state/.code/.class/.receipts` | `bridge_heartbeat_stats.odin:190` (≤256 rows / 8 KiB) | D | — |
| `operation_recovery.journal_failed/.capacity_exhausted/.capacity`, `rows[].attempts/.remaining` | typed wire struct omits them (`bridge_heartbeat_stats.odin:191`) | X | Journal fencing stays local (`retry_journal.odin:262-283`). Flag as an **open question**: these sound operationally important; if wanted, add an explicit consumer + alert in a separate task. |
| `stats.rss/.pty_host_rss/.cpu_s` | `bridge_heartbeat_stats.odin:124`, `:168` | D | — |
| `stats.host_mem_total/.host_mem_avail` | `:127`, `:171` | D (kept together) | — |
| `stats.load1/.disk_free` | `:129`, `:175` | D | Target schema distinguishes unavailable from 0 (§4.3). |
| `stats.instances[].provider/.rss/.cpu_s` (provider aggregates, ≤16) | `:133`, `:177` | D | — |
| `instances[].agent_instance_id/.launch_epoch/.state_seq/.runtime_status/.activity_status` | `bridge_handlers.odin:2697`, `:2759` | E | — |
| `instances[].activity_source` | absent from `Bridge_Agent_Status_Report`; no Hub code decodes or emits it (`rg activity_source src/hub` → no matches). The UI reads it (`src/ui/api/agentCatalog.ts:40`, `:277`) but the Hub never forwards it, so that read is dead (always falls back to `''`/existing). | X (heartbeat only) | Still sent in `agent_instance_status` push. Old/new Hubs ignore it in heartbeat → zero compatibility impact. Dead UI read recorded; cleanup is out of scope. |
| `instances[].error{code,class,cause,message,retry_after_ms}` | absent from heartbeat report type; decoded only on status push (`bridge_handlers.odin:2430`) | X (heartbeat only) — **pending decision D3** | Zero consumer → zero behaviour change. Existing gap stays documented: a dropped error push is not repaired. Alternative D3-b: add idempotent error decoding to heartbeat (then E). |
| `instances[].error.scope` | writer supports it (`src/contracts/errors.odin:219`), heartbeat converter never emits | n/a | Not emitted today. |

## 4. Contracts for relocated information

### 4.1 Options compared

| Option | Pros | Cons | Choice |
| --- | --- | --- | --- |
| Reuse `bridge_hello` for features/capabilities | Already persisted before `bridge_ready` (`bridge_service.odin:198-213`, `bridge_handlers.odin:1747-1795`); authenticated; generation assigned; replaced per connection. | Only on connect — dynamic changes need reconnect. | **Chosen** for binary-static metadata. |
| Dedicated `bridge_metadata` frame with revision/ack | Supports runtime change | Machinery with no current need | Deferred until a feature is genuinely dynamic (§4.2). |
| New HTTP endpoint for diagnostics | Independent of WS | Needs new auth path, generation fencing, client; Hub metrics are per-connection in memory | Rejected. |
| Keep diagnostics in heartbeat on every Nth beat | No new frame type | Couples liveness latency to `ps`/`/proc` collection; still mixed parse path | Acceptable fallback for old Hubs only (legacy). |
| New `bridge_diagnostics` WS frame | Same auth + generation as socket; separate cadence; own size cap | New frame type → must be negotiated | **Chosen.** |

### 4.2 Bridge metadata (features, capabilities)

- **Frame:** existing `bridge_hello` (Bridge→Hub), unchanged schema.
- **Semantics:** full replacement on every authenticated connection; `features` omitted ⇒ treat as `[]` (withdraw all) for hello only; never union.
- **Ordering/admission:** already applied before `bridge_ready` is written; T3 adds an assertion/test that feature-gated admission reads only metadata installed for the **current** generation.
- **Heartbeat:** when negotiated, heartbeat carries no `capabilities`/`features`; the Hub must then never touch `capabilities_json` from heartbeat. When not negotiated (old Hub), the Bridge sends the legacy members serialized from `BRIDGE_RUNTIME_FEATURES` (T0).
- **Metadata loss with a surviving connection** (e.g. DB restore under a live Hub): Hub closes the connection with a `resync_required` reason, forcing fresh hello. No new resync frame is required.
- **Future dynamic metadata (not in scope):** `bridge_metadata{revision, features[]}` full replacement, Hub ack of applied revision, Bridge resends while unacknowledged, resync on mismatch.

### 4.3 Diagnostics snapshot (`bridge_diagnostics`)

- **Direction:** Bridge→Hub WS text frame on the authenticated socket; sent only if `bridge_ready.diagnostics_frame_v1=true`.
- **Schema (bounded, full snapshot, cumulative counters):**

```json
{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_18e1aa0000000c3d","sample_seq":17,"collected_at_ms":1729940000000,
 "command_dispatch":{"accepted":120,"rejected":0,"completed":118,"deadline_expired":2},
 "dependency_breakers":{"open":0,"opened":1},
 "http_retries":{"retry":3,"recovered":3,"gave_up":0,"deferred":0},
 "operation_recovery":{"rows":[{"operation":"sync","state":"Backoff","code":"","class":"retriable","receipts":1}]},
 "stats":{"rss":52428800,"pty_host_rss":10485760,"cpu_s":12.34,"host_mem_total":33554432000,"host_mem_avail":16777216000,"load1":0.42,"disk_free":50000000000,
          "instances":[{"provider":"claude","rss":209715200,"cpu_s":88.10}]},
 "unavailable":["load1"]}
```

  Field vocabularies (must match the existing validator, `bridge_heartbeat_stats.odin:190-205`; producer `retry_journal.odin:262-283` always emits an enum class):
  - `operation_recovery.rows[].operation` ∈ `sync | readiness | refresh | slot`.
  - `rows[].state` ∈ `Pending | In_Flight | Backoff | Succeeded | Waiting_Repair | Exhausted | Cancelled` (capitalized enum names, exact match).
  - `rows[].class` must parse via `contracts.error_class_parse` (`src/contracts/errors.odin:111`) ∈ `retriable | recoverable | fatal` (`src/contracts/bridge_log.odin:324-334`) — **empty string is rejected**; `rows[].code` is `""` or a value accepted by `contracts.error_code_parse`.
  - `rows[].receipts` integer 0…4096.
  - **Whole-object rejection:** one invalid row rejects the entire `operation_recovery` object and leaves the previous series untouched (current behaviour, retained).
  - `process_epoch`: opaque non-empty string generated once per Bridge process start (random, not reused across restarts); `sample_seq` is a per-process counter starting at 1.

  Limits: whole frame ≤ 16 KiB; `operation_recovery.rows` ≤ 256 / 8 KiB (existing); `stats.instances` ≤ 16 (existing). Over-limit ⇒ whole frame rejected, counted, previous series untouched.
- **Fencing:** Hub reads the connection generation captured at hello (same as heartbeat, `bridge_handlers.odin:2250`) and drops frames from a non-current generation.
- **Ordering and reset (replaces the attempt-4 `sample_seq`-only rule, which could not detect a Bridge restart because `sample_seq` resets with the counters):** the Hub keeps `(process_epoch, sample_seq)` per Bridge. Same epoch and `sample_seq` ≤ last ⇒ drop as stale/duplicate. Same epoch and greater `sample_seq` ⇒ apply. Different epoch ⇒ new process: apply as a reset regardless of `sample_seq`. The existing `unseal_boot_id` in hello (`hub_runtime_client.odin:3951`) is **not** used because it is tied to vault unseal rather than process start and may be empty while locked.
- **Counter representation:** today the Hub stores absolute cumulative values with `metrics.counter_set` (`bridge_heartbeat_stats.odin:207-237`) and `operation_recovery` as gauges replaced via `remove_where` + `gauge_set`; there is no delta arithmetic. Reset handling is defined for that representation: on an epoch change the Hub calls `counter_set` with the new (lower) absolutes and exposes `bridge_diagnostics_process_restarts_total{bridge}` so downstream `rate()`/`increase()` see a normal Prometheus counter reset. Within one epoch a lower value is treated as a malformed sample and the sub-object is rejected.
- **Cadence/trigger:** one snapshot immediately after `bridge_ready` (new behaviour introduced by T6 — unlike heartbeat today, see §5 item 4), then every *N* seconds where *N* defaults to the heartbeat interval (preserving today's sampling) and may be raised by a Hub-provided `bridge_ready.diagnostics_interval_seconds` only after D1 is resolved. `stats` sub-object obeys existing `heartbeat_stats` / `set_telemetry` switches; reliability objects keep today's unconditional behaviour unless D4 decides otherwise.
- **Reconnect / Hub state loss:** connect-time snapshot (T6) repopulates metrics; existing disconnect tombstoning (`runtime_metrics.odin:121-152`) remains.
- **Omission/reset semantics:** a sub-object absent ⇒ its series unchanged and `bridge_diagnostics_age_seconds{family}` keeps growing; listed in `unavailable` ⇒ gauge cleared; counters lower than previous with greater `sample_seq` ⇒ treated as process restart (reset), not negative delta. Missing scalars inside a present sub-object ⇒ whole sub-object rejected (fixes current missing-as-zero, `bridge_heartbeat_stats.odin:254`) — new parser only; legacy parser unchanged.
- **Freshness:** Hub exports `bridge_diagnostics_last_sample_seconds` per bridge; no UI change.
- **Opt-out:** the existing `set_telemetry` command (built by `bridge_set_telemetry_payload`) disabling stats stops `stats` in subsequent snapshots and the Hub clears stats series on the first snapshot without it when telemetry is disabled (explicit, not inferred from absence).

### 4.4 Negotiation (both directions)

`bridge_ready` gains two booleans (old Bridges ignore unknown keys; `extract_json_bool` default false):

| Flag | Meaning when `true` |
| --- | --- |
| `heartbeat_metadata_omission` | Hub refreshes Bridge liveness without capabilities (T1) and ignores heartbeat metadata; Bridge may omit `capabilities`/`features`. |
| `diagnostics_frame_v1` | Hub accepts `bridge_diagnostics`; Bridge stops sending diagnostic members in heartbeat. |

**How the Hub knows a peer negotiated omission (implemented in T3).** A `bridge_ready` flag is only a Hub advertisement — an old Bridge ignores it. `heartbeat_metadata_omission` is therefore negotiated per connection only when **both** the Hub sent the flag **and** that connection's `bridge_hello.features` lists `heartbeat_metadata_omission` (`contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION`). T4 must add that string to the Bridge's hello feature list and omit metadata only when the ready flag is also true. On a negotiated connection heartbeat `capabilities`/`features` are ignored whether present or not; otherwise a legacy beat that carries them remains a full replacement, and one that omits them changes nothing. Whenever a beat does not apply metadata, the stored `features` must equal what this connection installed (hello, or the last legacy beat on a non-negotiated connection); a missing or different list makes the Hub send `protocol_error{code:conflict, cause:resync_required}` and close, counted as `bridge_frames_rejected{reason=metadata_resync}`. Hello is a full replacement: an absent `features` member is stored as `[]`.

**Bridge side (implemented in T4).** The Bridge lists `heartbeat_metadata_omission` in `BRIDGE_RUNTIME_FEATURES` (hello and legacy beat) and parses both `bridge_ready` flags independently into per-connection state, cleared before every hello. Metadata flag ⇒ heartbeat drops only `capabilities`/`features`. `diagnostics_frame_v1` is recorded, but diagnostic members are dropped only when `BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE` is also true; it stays `false` until T6 (`hb_impl_diag_bridge`) actually sends `bridge_diagnostics`, so no diagnostic data disappears early. Heartbeat instance tuples are always the five decoded members; `activity_source`/`error` remain in `agent_instance_status` pushes (D3-a). Serialization is `bridge_heartbeat_frame_json(frame, shape)` in `src/bridge/hub_runtime_client.odin`, with byte-exact goldens in `src/bridge/heartbeat_shape_test.odin`.

| Hub \ Bridge | Old Bridge | New Bridge |
| --- | --- | --- |
| Old Hub | unchanged | No flags ⇒ legacy 15-member heartbeat, with corrected 4-feature list (T0). |
| New Hub | Legacy heartbeat accepted; capability path still runs (now writes narrow liveness separately and full replacement from legacy list). | Minimal heartbeat + `bridge_diagnostics`. |

## 5. REQ-HBP-3 — Hub-first safe evolution

1. **Narrow, fenced Bridge row writes (T1).** Every Bridge-row write reachable from a heartbeat becomes a narrow `UPDATE` with a `status!='revoked'` predicate — never a full-row save:
   - **Liveness:** new `bridge_service.touch_runtime_liveness(bridge_id, generation)` → `UPDATE bridges SET status='online', last_seen_at=?, updated_at=? WHERE bridge_id=? AND status!='revoked'`, on every current-generation heartbeat regardless of `capabilities`.
   - **Capabilities/features** (legacy path, when present): `UPDATE bridges SET capabilities_json=?, updated_at=? WHERE bridge_id=? AND status!='revoked'` instead of `update_runtime_capabilities`' UPSERT (`bridge_service.odin:260-284`).
   - **Vault status:** `update_vault_status` (`bridge_service.odin:382-412`, reached on every heartbeat via `bridge_apply_vault_status_report`, `bridge_handlers.odin:2349`) currently reads the row and, when the value changed, calls `bridge_save_bridge`. It becomes `UPDATE bridges SET vault_status=?, updated_at=? WHERE bridge_id=? AND status!='revoked' AND vault_status IS NOT ?` with `changed` taken from the affected-row count, so unchanged beats still write nothing and publish nothing.
   - **Columns at risk from the current full-row UPSERT** (`bridge_repo_sqlite.odin:75`), i.e. silently reverted to the value read earlier if a concurrent writer changed them between read and save: `label`, `label_is_user_customized`, `status` (incl. a concurrent revoke), `bridge_token_hash` (token rotation), `revoked_at`, `telemetry_enabled`, `vault_status`, `enrollment_pending_until`, `capabilities_json`, `hub_url`, `machine_hostname/os/arch`, `version/commit_sha/build_timestamp`, `update_status/message/progress/error`, `last_seen_at`. (`plan_disabled_at`, `owner_user_id`, `created_at` are insert-only and not at risk.)
   - **`mark_bridge_offline`** (`bridge_service.odin:245`) is also a full-row read-modify-save. It is not on the heartbeat path and is guarded by `connection.retired` on disconnect, but it shares the same lost-update exposure; T1 converts it to `UPDATE … SET status='offline', updated_at=? WHERE bridge_id=? AND status='online'` in the same change so no full-row Bridge save remains on runtime paths.
2. **Generation fencing (T1/T3).** Today generation is checked on entry (`bridge_handlers.odin:2250`) but liveness/capability, vault, reliability and active-ID writes are not serialized against a concurrent replacement; only instance status writes take the validated-status path with retirement locking (`:2715`). New liveness/metadata writes must run under the same retirement barrier (or re-check `connection_generation` inside the lock) so a delayed old connection cannot write after the new hello has been admitted.
3. **Static features.** Hello replacement already happens per connection; T3 removes the heartbeat overwrite when negotiated and guarantees legacy fallback serializes the same list (T0). Feature-gated admission (`tool_stream.odin:528`) reads only the record written by the current generation's hello.
4. **Hub restart / reconnect (corrected).** Every Bridge reconnects and sends hello, but the first heartbeat is sent only after a full interval: `bridge_hub_runtime_loop` sets `last_heartbeat := now` at loop start (`hub_runtime_client.odin:577`) and sends when `now - last_heartbeat >= interval` (`:666`), interval 45s from `bridge_ready` (`bridge_handlers.odin:3144`, `:3152`). Consequences for up to 45s after every reconnect today: the in-memory search projection reads false/false/0 (UI search ineligible); the runtime registry/quota is rebuilt only from hello's launch IDs, without status tuples; dropped status pushes from before the disconnect are not repaired; Bridge `last_seen_at` is refreshed only by hello. Durable instance rows are not at risk in that window (90s stale threshold > 45s). **T1b** fixes this Bridge-side: send one heartbeat immediately after `bridge_ready` is processed (old Hubs accept an early heartbeat — it is an ordinary frame), then continue the normal cadence. Diagnostics get their own immediate snapshot only via T6. **DB loss/restore:** heartbeat never fabricates enrollment, auth or canonical instance rows; unknown bridge/instance ⇒ reject and require restore/re-enrollment (current behaviour, kept and tested).
5. **Known blocker fix first (T0).** `bridge_runtime_features_json` (`hub_runtime_client.odin:3964`) hardcodes three features and erases `tool_stream_demand_v2` on every beat, so tool streams get `upgrade_required`. This is a source-proven admission defect; it is **not** claimed to explain every UI symptom, and no complete browser trace exists.

## 6. REQ-HBP-4 — implementation task breakdown

Each task is a separate lease with its own independent review. Order: T0 → T1 → T1b → T2 → T3 → T4 → T5 → T6 → (T7, T8 optional). Hub tasks (T1–T3, T5) must ship and be deployed before any Bridge task that relies on their flags (T4, T6); Bridges never act on a flag the Hub does not advertise.

| Task | Scope (files) | Acceptance | Regression scenarios |
| --- | --- | --- | --- |
| **T0** Bridge: legacy heartbeat features from one source | `src/bridge/hub_runtime_client.odin` (`bridge_runtime_features_json` → serialize `BRIDGE_RUNTIME_FEATURES`); Bridge tests | Hello and heartbeat feature lists byte-identical; tool-stream v2 survives N heartbeats against current Hub. | hello→many beats; upgrade/downgrade withdraws features. |
| **T1** Hub: narrow, fenced Bridge row writes | `src/hub/service/bridge/bridge_service.odin` (`update_runtime_capabilities`, `update_vault_status`, `mark_bridge_offline`, new `touch_runtime_liveness`), `src/hub/repository/sqlite/bridge_repo_sqlite.odin` (+ repository iface), `src/hub/transport/http/bridge_handlers.odin` heartbeat arm | Liveness refreshed on every current-generation heartbeat regardless of `capabilities`; no full-row `bridge_save_bridge` on heartbeat or disconnect paths (liveness, capabilities, vault, offline); revoked stays revoked; concurrent label, token rotation (`bridge_token_hash`), `telemetry_enabled`, enrollment and revocation edits are not overwritten. | Idle Bridge >1h with metadata omitted: `last_seen_at` advances, reaper (`src/hub/app/reaper.odin:32`, `:346`) does not terminalize shells; unchanged beat writes no capability/vault row and publishes nothing; vault flip between read and write with concurrent token rotation / telemetry toggle preserves both; revoke racing a heartbeat stays revoked; delayed old generation cannot write. |
| **T1b** Bridge: immediate heartbeat after `bridge_ready` | `src/bridge/hub_runtime_client.odin` (loop start `:577`, send `:666`); Bridge tests | First heartbeat is sent right after `bridge_ready` handling, then every interval; no double send in the same tick. Independent of T1 and safe against old Hubs. | Hub restart: search tuple, registry status tuples and Bridge liveness restored on the first beat (<1 interval); reconnect storm does not double-send; interval change via `bridge_ready` still honoured. |
| **T2** Hub: authoritative-inventory rules | `bridge_handlers.odin:2350-2370`, `:2738-2770`; `agent_service.odin` reconcile | Fallback filters terminal IDs; absent/malformed inventory skips absence reconciliation; rejections counted. | Empty / absent / malformed / terminal-only inventory; agents idle >90s with unchanged `state_seq` remain live; true disappearance → unreachable; superseded IDs still reported in ack; schedule epoch/revision still in ack. |
| **T3** Hub: metadata from hello only when negotiated; advertise `heartbeat_metadata_omission` | `bridge_handlers.odin` (`bridge_ready_payload`, heartbeat arm), `bridge_service.odin` | With flag set, heartbeat never mutates `capabilities_json`; feature admission uses current-generation hello record; metadata loss under live connection ⇒ close with `resync_required`. | Old Bridge × new Hub legacy path; capability withdrawal during active tool-stream demand fails closed; Hub restart; DB restore. |
| **T4** Bridge: honor omission flag | `hub_runtime_client.odin` (ready parse ~`:410`, heartbeat builder `:3210-3282`); drop `activity_source`/`error` from heartbeat tuple | With flag: 8-member core; without: legacy 15 members (T0 list). Status push still carries `activity_source`/`error`. | New Bridge × old Hub; mixed flags; JSON golden tests for §2.1 examples. |
| **T5** Hub: `bridge_diagnostics` frame + `diagnostics_frame_v1` | `bridge_handlers.odin`, new parser in `src/hub/transport/http/bridge_heartbeat_stats.odin` (or sibling), `src/hub/service/project/runtime_metrics.odin` | Bounded strict parser; generation fenced; reset detection; `unavailable` clears; freshness gauge; legacy heartbeat diagnostics still ingested for old Bridges. | Full snapshot at connect; Bridge restart (new `process_epoch`, lower counters, `sample_seq` back to 1) accepted as reset; same-epoch duplicate/old `sample_seq` dropped; same-epoch lower counter rejected; invalid recovery row (lower-case state, unknown operation, empty class) rejects whole object; stale gauges after missing sub-object; oversize/malformed reject whole frame; opt-out clears stats; provider/recovery series tombstoned on valid empty snapshot. |
| **T6** Bridge: emit diagnostics frame | `hub_runtime_client.odin`, `heartbeat_stats.odin`, `hub_command_dispatch.odin`, `dependency_breaker.odin`, `retry_policy.odin`, `retry_journal.odin` (builders trimmed to consumed members for the new frame only) | Separate timer; diagnostics collection cannot delay heartbeat; default cadence = heartbeat interval. | Collection stalls (slow `ps`) do not delay liveness; cadence changes keep CPU/counters interpretable. |
| **T7** (optional, after D1) slower diagnostics cadence | Hub `bridge_ready.diagnostics_interval_seconds` | Only after external alert windows verified. | Alert windows satisfied. |
| **T8** (optional) search tuple on-change | `task_chain_search_index.odin`, `runtime_registry.odin` | Presence-aware; ack'd revision; repair on reconnect. | Readiness flip after connect, Hub restart. |

**Review boundaries:** each Hub task reviewed for persistence/fencing; each Bridge task for wire compatibility against both Hub generations. Workers choose their own proportionate checks; this plan prescribes no mandatory command.

## 7. Risks and rollback

| Risk | Mitigation | Rollback |
| --- | --- | --- |
| Liveness regression ⇒ reaper kills shells after 1h | T1 ships alone first, with idle >1h regression; flags not advertised until T1 is deployed. | Revert T1; legacy capability path still refreshes liveness because old Bridges keep sending capabilities. |
| New Bridge, rolled-back Hub | Bridge only omits on explicit flag per connection. | Automatic: rolled-back Hub sends no flags ⇒ legacy heartbeat. |
| Diagnostic gaps break unknown external alerts | Default cadence unchanged; T7 gated on D1. | Hub stops advertising `diagnostics_frame_v1` ⇒ Bridges resume legacy members. |
| Stale-generation writes | Retirement barrier for all new writes (T1/T3). | — |
| Lost error repair remains | Documented; D3 decides. | — |

## 8. Unresolved decisions (need user/coordinator input before affected tasks)

- **D1** External Prometheus scrape/alert windows for Bridge diagnostics → governs T7; 180s is a proposal only.
- **D2** Whether `operation_recovery.journal_failed/.capacity_exhausted/.capacity` should gain a real consumer/alert (else removed).
- **D3** Error repair: (a) keep heartbeat error-free and document the gap, or (b) add idempotent heartbeat error decoding (then `error` becomes E).
- **D4** Whether reliability diagnostics should obey the telemetry opt-out like `stats` (currently unconditional).
- **D6** Whether to remove the legacy heartbeat `digest` alias (requires fleet evidence that no Bridge sends it).
- **D5** Live cardinalities and DB/CPU cost measurements (no benchmark exists; byte figures are synthetic: 835-byte empty legacy frame vs 207-byte core).

## 9. Verification performed for this plan

**Attempt 5 (review changes on `c2bcbe93`):** each finding re-read at source before editing — `bridge_service.odin:245-250`, `:378-412`; `bridge_repo_sqlite.odin:75` (UPSERT column list); `hub_runtime_client.odin:570-580`, `:660-672`, `:843`, `:3951`; `bridge_handlers.odin:2349`, `:2700-2712`, `:2742-2750`, `:3140-3152`, `:3194-3209`; `bridge_heartbeat_stats.odin:185-240`; `retry_journal.odin:74-84`; `src/ui/api/agentCatalog.ts:40`, `:277`; `rg activity_source src/hub` (no matches). All findings confirmed; no source assumptions changed.

**Attempt 4:**

- `git diff --stat 1c75ee445a2b5d149731004bd95de28f7508b7c2 HEAD -- <19 heartbeat-path files>` → empty.
- Direct reads at `dec3c833`: `hub_runtime_client.odin:3210-3282`, `:3925-3964`; `bridge_service.odin:198-213`, `:258-290`; `bridge_handlers.odin:1680-1796`, `:2326-2358`, `:2694-2770`, `:2676`, `:3146-3209`; `bridge_heartbeat_stats.odin:250-258`; `bridge_repo_sqlite.odin:70-75`.
- JSON examples in §2.1 and §4.3 parse with `python3 -m json.tool`.
- No builds or tests: no source changes. Prior attempts' managed-shell revalidation (task comments 12:33Z, 12:43Z) is consistent with these reads.
