# Bridge authentication recovery after laptop sleep

Status: **proposed plan (milestone R6a); nothing is implemented.** Source baseline `846b1b72` (branch `bridge-owned/r6`). Builds on the approved diagnostic [docs/diagnostics/bridge-auth-sleep.md](../diagnostics/bridge-auth-sleep.md) (commit `9d12513f`, source `873aa65c`). Ordering model: [bridge-auth-resume-recovery-model.py](bridge-auth-resume-recovery-model.py).

No live authentication requests, credential reads or copies, sign-out/re-login, restarts, deploys or installs were performed for this plan. Nothing here parses, prints or logs a token.

## 0. Summary

A laptop Bridge that sleeps past its one-hour access-token lifetime keeps redialling with the expired `hba_` token until its proactive refresh timer fires. On Linux that timer is a relative sleep that does not count suspended time, so the outage can last up to about 51 minutes after wake. Nothing on the rejection path wakes renewal. The plan makes **one credential owner** responsible for every Hub-bound credential use:

- It checks credential age against a wall clock and a monotonic clock before each connect and HTTP request, with a skew margin.
- It re-evaluates at least every 30 seconds, so it notices a wake within one interval.
- Typed rejections can trigger at most one renewal for each credential generation.
- Concurrent triggers share one single-flight exchange.
- It publishes credentials by local generation, with session-epoch fencing.
- It keeps and finishes the existing crash-safe pending-pair protocol, recovering a pending pair before the first dial.

Refresh-token rejection stays final and leads to a visible re-enrollment state.

Hub changes are small and backward compatible: a typed expired-access cause on HTTP 401, and a capability-gated `bridge_token_invalid` WS code, which is optional.

## 1. Current behavior (source at `846b1b72`)

Legend: **C-src** means confirmed by reading source at this commit. **C-test** means an existing test asserts it. **C-model** means the diagnostic or this plan's model reproduces it from source premises. **H** marks a hypothesis or an unmeasured claim.

### 1.0 Reconciliation with the diagnostic

`git diff 873aa65c..846b1b72` shows that `src/bridge/enroll_device_flow.odin`, `main.odin`, `hub_http.odin`, `retry_budget.odin`, `retry_journal.odin`, `action_scheduler.odin`, `src/lib/ws/ws.odin`, the Hub token service and the Hub bridge handlers are **unchanged**. `src/bridge/hub_runtime_client.odin` changed (+130/−59) only in command dispatch (owner migration, legacy delivery and executor observation). Its authentication procedures moved by one or two lines: snapshot 377→378, reauth drain 840→842 and session frame 854→856. Every diagnostic conclusion still holds:

- the tokens are opaque and DB-backed;
- reconnect snapshots the current credential on every attempt;
- the problem is delayed renewal, not a captured token;
- spent-token and pending-pair recovery exist.

The newer Bridge-owned work adds more callers of the **same** Hub access credential (§1.9). It adds no new credential or expiry mechanism.

### 1.1 Access and refresh expiry storage

| Claim | Location | Status |
| --- | --- | --- |
| Hub lifetimes: access 3600 s, refresh 30 days (sliding), family 365 days absolute | `src/hub/service/bridge/bridge_token_service.odin:86-88` | C-src, C-test (`bridge_token_service_test.odin:138`, `:477`) |
| Hub stores `expires_at`/`family_expires_at`/`generation` per row; the reply carries durations only | `bridge_token_service.odin:243-279`; wire `src/contracts/bridge_token_wire.odin:15-22` (no generation and no timestamps on the wire) | C-src |
| Hub judges expiry on its own clock with 60 s grace; an empty `expires_at` counts as expired | `bridge_token_service.odin:110`, `:299-311` | C-src, C-test |
| Bridge receives `expires_in`/`refresh_expires_in` in `Bridge_Enroll_Credential` | `src/bridge/enroll_device_flow.odin:135-145`, `:1797-1823` | C-src |
| **Bridge persists no expiry, issue time or generation for the live pair.** The access file is `owner header + token` (`src/bridge/credential_owner.odin:36-50`); the refresh file is the raw token (`enroll_device_flow.odin:1860-1863`) | as cited | C-src |
| Only the transient pending record keeps `expires_in` (a duration, with no receipt time) | `enroll_device_flow.odin:1826-1831`, `:1841-1845` | C-src |
| The in-memory credential is just `bridge_config.bridge_token`. After adoption the lifetime survives only as the worker-local `delay` | `enroll_device_flow.odin:1884-1887`, `:871` | C-src |

### 1.2 Scheduling: monotonic versus wall clock

| Claim | Location | Status |
| --- | --- | --- |
| A single renewal worker sleeps a relative duration: first 30 s (`BRIDGE_REFRESH_MIN_DELAY_SECONDS`), then 75–85% of `expires_in` | `enroll_device_flow.odin:776-779`, `:701-713`, `:871` | C-src, C-test (`enroll_device_flow_test.odin:286`, `:304`, `:313`) |
| It has no resume callback, no wake signal from reconnect and no age check. A grep of `src/` finds no power or suspend hook (`PrepareForSleep`, `WM_POWERBROADCAST`, `NSWorkspaceDidWake`, `CLOCK_BOOTTIME`) | `enroll_device_flow.odin:776-890` | C-src |
| The Linux `time.sleep` relative nanosleep runs on `CLOCK_MONOTONIC`, which excludes suspend. The timer is therefore suspended along with the machine | diagnostic §"Suspend, clocks" | C-model for Linux; **H** for Darwin and Windows |
| Retry budgets use wall ms with a process-local monotonic floor. A backward wall step sets `Waiting_Repair` | `src/bridge/retry_budget.odin:26-33`, `:36`, `:42`, `:52` | C-src |
| `time.tick_now` uses `CLOCK_MONOTONIC_RAW` on Linux and Darwin, and `QueryPerformanceCounter` on Windows (host Odin `dev-2026-10`, `core/time/time_linux.odin:30-33`, `time_unix.odin:34-35`, `time_windows.odin:26-40`) | Odin core | C-src for that compiler; the release compiler identity and suspend semantics are **H** |
| A retriable terminal budget pauses for a **fixed 60 s with no jitter**, then reopens | `enroll_device_flow.odin:909-915` | C-src, C-test (`refresh_recovery_test.odin:146`) |
| Hub session expiry uses Hub wall ms set at upgrade or reauth | `src/hub/service/project/runtime_registry.odin:169-190` | C-src, C-test (`bridge_session_credential_test.odin:401`, `:434`) |

### 1.3 Connect and auth request acquisition

| Claim | Location | Status |
| --- | --- | --- |
| Startup resolves the credential (explicit, file or default adoption), starts the Hub runtime and then the refresh worker | `src/bridge/main.odin:196-198`, `:541-555`, `:276`, `:280` | C-src |
| Every WS dial takes a fresh mutex-protected snapshot. There is no age check and no disk reread | `src/bridge/hub_runtime_client.odin:378-380`; `enroll_device_flow.odin:1770-1774`; header built per attempt in `src/lib/ws/ws.odin:57-67` and `:154-156` (TLS) | C-src, C-model |
| HTTP callers also snapshot for each operation, with no age check: action scheduler `action_scheduler.odin:687`, owner registry `owner_local.odin:72-76`, executor relay `owner_local_executor.odin:215-219`, migration `owner_migration.odin:31`, `:43`, executor directory and exchange `executor_fence_client.odin:31`, `:68`, agent relay `wrapper_endpoint.odin:542`, `:558`, `:587`, search `task_chain_search_refresh.odin:74` | as cited | C-src |
| `bridge_http_request_retry` reuses that one header across retries and does not retry 401 (`Unauthenticated` is class `recoverable`, `src/contracts/errors.odin:64`) | `src/bridge/retry_policy.odin:97-127`, `:172-200` | C-src |

### 1.4 401 and 403 handling

| Claim | Location | Status |
| --- | --- | --- |
| The Hub upgrades first and verifies after hello. An expired access token gives `Unauthenticated "bridge access token has expired"`; a revoked one gives `Forbidden`; family-max expiry is `Forbidden`; an unknown token gives `Unauthenticated "bridge token is invalid"` | `src/hub/transport/http/bridge_handlers.odin:1715-1767`; `bridge_token_service.odin:341-388` | C-src, C-test |
| WS mapping: `Unauthenticated` **containing "expired"** maps to `bridge_token_expired`. **Every other** `Unauthenticated`/`Forbidden` maps to `bridge_credential_revoked` | `bridge_handlers.odin:3902-3911` | C-src |
| Bridge, pre-ready: a `bridge_error` frame goes to `bridge_hub_session_frame`. `bridge_token_expired` **only logs**, and the loop then backs off and redials with the same snapshot | `hub_runtime_client.odin:428-441`, `:856-912` (`:881-882`), `:515`, `:532-535` | C-src, C-model |
| Bridge: `bridge_credential_revoked` calls `bridge_hub_stop_traffic(true)`, which writes a final pause and the `Revoked` re-enroll marker | `hub_runtime_client.odin:888-890`; `src/bridge/hub_quiescence.odin:50-66` | C-src |
| Established session: the Hub closes it at expiry or on revocation (rechecked every interval). The in-band `bridge_reauth` frame renews the session after a refresh | `bridge_handlers.odin:2155-2190`, `:2246`; Bridge drain `hub_runtime_client.odin:842-853` | C-src, C-test (`bridge_session_credential_test.odin:495`, `:526`) |
| **Reauth race:** `bridge_ready` clears `bridge_credential_reauth_pending` without checking which credential opened that connection | `hub_runtime_client.odin:422` | C-src; impact **H** (bounded by session expiry and reconnect) |
| HTTP: `bridge_hub_http_send_using` reacts only to the `bridge_sunset_pending` and `bridge_credential_revoked` causes. An expired-access 401 is an ordinary failed operation and never triggers refresh | `src/bridge/hub_http.odin:30-41` | C-src |
| The action-scheduler sync budget parks with `Waiting_Repair`/`Unauthenticated` and is reopened by adoption | `retry_journal.odin:348-356`, called from `enroll_device_flow.odin:1893` | C-src |
| A refresh endpoint `Unauthenticated` (any `invalid_grant`) is **final immediately**: stop traffic, wipe the pair and mark `Refresh_Rejected` | `enroll_device_flow.odin:1789`, `:1898-1905` | C-src |
| The Hub comment says "refreshes and retries once", but no Bridge path implements it | `bridge_token_service.odin:318-321` | C-src |

### 1.5 Refresh serialization

| Claim | Location | Status |
| --- | --- | --- |
| Exactly one renewal thread is started once (`thread.run`), and no other runtime caller exchanges a refresh token | `enroll_device_flow.odin:757-770` | C-src |
| A journal reservation (`refresh:<hub>:<bridge>`, `In_Flight`) prevents a second reservation | `retry_budget.odin:34-35`; `retry_journal.odin:172` | C-src |
| The offline `ham-bridge recovery resume-refresh` is a separate process under the config and scope locks | `src/bridge/recovery_command.odin:10-30` | C-src |
| **There is no credential generation counter.** The fences compare token bytes (`action_scheduler.odin:705-709`) or the connection generation | as cited | C-src |
| The Hub serializes concurrent retries | `bridge_token_service_test.odin:599` | C-test |

### 1.6 Rotation persistence

| Claim | Location | Status |
| --- | --- | --- |
| The request ID is durable before the first send and reused across retries and restarts | `enroll_device_flow.odin:934-948`, `:833-843` | C-src, C-test (`refresh_recovery_test.odin:118`, `:177`) |
| Order: pending record (atomic write, fsync and directory fsync), then the refresh file, then the access file, then adopt in memory, then remove the pending and request files | `enroll_device_flow.odin:1865-1882`, `:1860-1863`, `:864-867`; `retry_journal.odin:114-140` | C-src, C-test (`refresh_recovery_test.odin:23`, `:39`) |
| Hub: 30 s reuse grace, a 600 s request-ID retry grace if no descendant was used, otherwise family revocation | `bridge_token_service.odin:130`, `:153`, `:468-516`, `:576` | C-src, C-test (`:265`, `:497`, `:538`, `:637`) |

### 1.7 Pending-pair recovery

| Claim | Location | Status |
| --- | --- | --- |
| The worker loads the pending record; a committed pair is adopted without a new exchange; a resumable receipt continues local commit only | `enroll_device_flow.odin:786-810`; `retry_journal.odin:254-266` | C-src, C-test |
| An invalid pending record, or one without a resumable receipt, **returns from the worker** and stops all renewal until operator repair | `enroll_device_flow.odin:789`, `:805-806` | C-src |
| An exhausted local-commit budget also returns (the pair stays parked) | `enroll_device_flow.odin:878-888` | C-src |
| Recovery runs only **after the worker's first 30 s sleep**, while the runtime worker is already dialling with whatever access file is on disk | `main.odin:276` versus `:280`; `enroll_device_flow.odin:777-779` | C-src; impact **H** (at most one 30 s window) |
| Every process start performs a refresh 30 s after start, whatever the token's age | `enroll_device_flow.odin:777-786` | C-src |

### 1.8 Backoff

| Path | Policy | Location | Status |
| --- | --- | --- | --- |
| WS reconnect | 500 ms doubling to 30 s, ±20% random | `hub_runtime_client.odin:530-535` | C-src |
| Connection replaced | separate doubling backoff | `hub_runtime_client.odin:312-341` | C-src |
| Plan limit | fixed 60 s | `hub_runtime_client.odin:511-514` | C-src |
| Refresh exchange | 6 attempts in 120 s, base 5 s doubling, ±20% random seed in production | `retry_budget.odin:7-8`, `:58`; `retry_journal.odin:189-191`; `enroll_device_flow.odin:862` | C-src |
| Refresh pause | fixed 60 s, no jitter, repeats indefinitely | `enroll_device_flow.odin:909-915` | C-src |
| `bridge_refresh_backoff_seconds` (5 s to 300 s) | **used only by a test** (`error_class_test.odin:71`) | `enroll_device_flow.odin:105-108` | C-src |
| Owner-local intents | linear delay up to 60 s, unbounded retries, no auth classification | `src/lib/owner_local/outbox.odin:89`; maintenance every 30 s at `owner_local_leases.odin:117-123` | C-src |

### 1.9 Owner-local, relay and agent token paths

- **They share the same Hub session credential.** Owner-local registry publishing (`owner_local.odin:59-79`), executor relay (`owner_local_executor.odin:215-225`), migration export and state (`owner_migration.odin:30-50`), executor directory and reverse exchange (`executor_fence_client.odin:30-75`) and the agent `ham-ctl` relay (`wrapper_endpoint.odin:539-600`) all send `Authorization: Bearer <hba_ snapshot>`. None of them has its own expiry or refresh, and none of them triggers renewal on 401. **C-src.**
- **Behavior during the window.** Owner-local intents keep retrying every ≤60 s and record `"401"` as the result (`outbox.odin:72-96`). They self-heal after renewal. Agent relay calls return the Hub's 401 to the agent. Executor and migration fetches fail closed and their callers retry. **C-src** for the retry shape; the user-visible impact is **H**.
- **Agent tokens have their own boundary and no time expiry.** The local `hlat_` tokens are only invalidated, never expired (`agent_token_store.odin:14-25`, `:108-145`). The Hub instance assertion is bound to the launch epoch and needs a valid Bridge token in the same request (`src/hub/service/auth/auth_service.odin:124-162`). The search found no time-to-live on either. **C-src.** That no other expiry exists anywhere is **H**, because the search covered only these files.
- **Consequence:** fixing acquisition in one owner covers all these paths, provided they call `ensure` (step 3).

### 1.10 User-visible status today

- The local `Runtime_Status` file has only `connected`, `vault` and `version` (`src/lib/bridgesvc/status.odin:17-24`, written by `service_cmds.odin:297`). It has no authentication state.
- `operation_recovery` reaches the Hub only inside a heartbeat (`hub_runtime_client.odin:3421`), so it is invisible while authentication fails.
- A re-enroll marker parks the process and prints a hint (`enroll_account_replace.odin:363-369`).
- Hub metrics record upgrade authentication failures as `BRIDGE_ID_UNKNOWN` (`bridge_handlers.odin:1767`).

All **C-src.**

## 2. Target design

### D1. Credential owner and state (Bridge)

Add `src/bridge/credential_state.odin` with one process-wide owner, guarded by `g_bridge_credential_mu` plus a condition variable:

```text
Credential_State {
  epoch:          u64   // activation epoch: (hub, bridge_id, credential_file, enrollment/marker identity); bumps on enroll/reenroll/stop
  generation:     u64   // local, strictly increasing on every publish; 0 = unknown
  access:         owned bytes (never logged)
  access_token_id string // the non-secret record id half of hba_<id>.<secret>, for binding metadata
  issued_wall_ms: i64   // Bridge wall time at receipt (persisted)
  issued_tick:    Tick  // process-local monotonic anchor (never persisted)
  expires_in_s, refresh_expires_in_s: int
  phase: Valid | Due | Renewing | Pending_Commit | Offline_Retry | Reenroll_Required | Parked_Sunset
  last_error: {code, class, at_wall_ms, attempts}   // no token material
}
```

`bridge_credential_snapshot` becomes `bridge_credential_acquire(deadline_ns, purpose) -> (token, generation, ok, status)`. Existing callers keep a thin compatibility wrapper during migration.

### D2. Expiry-aware acquisition before every connect or authenticated request

`acquire` runs the following steps:

1. Compute `elapsed = max(wall_now − issued_wall, tick_since(issued_tick))`. Each term is used only when valid: the wall term only if it is not negative, the tick term only if the anchor exists in this process. If neither is valid (unknown metadata), the credential is **Due**.
2. If `expires_in − elapsed < SKEW_MARGIN`, mark it **Due** and request renewal (D4). `SKEW_MARGIN = max(300 s, 10% of lifetime)`, capped at half of the lifetime.
3. Wait on the condition until the generation advances, the phase becomes final, or `min(deadline, 10 s)`.
4. Return the newest published credential either way. The Hub stays authoritative, so a local guess never blocks a still-valid token for longer than the deadline.

The WS dial at `hub_runtime_client.odin:378` and every HTTP site in §1.3 and §1.9 call `acquire`.

Clock rules:

- A forward wall jump only makes the token look older. That can cost one early rotation, which is safe.
- A backward jump is ignored by the `max`, so the monotonic term governs.
- The Bridge never compares Hub timestamps (they are durations by design, `bridge_token_wire.odin:13-14`) and never parses tokens.

### D3. Bounded renewal driven by rejections

Typed triggers carry the generation that was attempted:

- the WS `bridge_token_expired` frame, either pre-ready (`hub_runtime_client.odin:428-441`) or in-session (`:881`);
- an HTTP 401 whose wire error is expired access (H1; until H1 ships, the exact Hub message `bridge access token has expired`, matched in one helper);
- a failed reauth result.

Handling rules:

- If `attempted < current generation`, retry at once with the current credential and spend nothing.
- Otherwise request **one** renewal for that generation. A set of renewed generations caps this at one per generation.
- If the new generation is rejected as expired again, the phase becomes `Offline_Retry` with the reason `rejected_after_renewal` (likely Hub clock skew or a database problem). The Bridge falls back to the normal reconnect and renewal backoff and does not loop.
- `Forbidden`/revoked, sunset, plan limit and `bridge_error` frames without an authentication code keep their current policies.
- A raw upgrade HTTP status without a typed cause never triggers refresh.

### D4. Single-flight refresh with generation and epoch fencing

- The renewal worker becomes an **event loop** that waits on the condition variable (D6). It is still the only exchanger. `request_renewal(reason, attempted_gen)` sets `Due` and signals. Concurrent requests coalesce, and every waiter observes the same published generation.
- Each exchange captures `(epoch, base_generation, request_id)`. Before writing the pending record, before each file commit and before publishing, it rechecks three things: the epoch is unchanged, traffic is not final-stopped and no re-enroll marker exists, and the generation still equals `base_generation`. On a mismatch the result is **discarded and never written**. A pair from a stale epoch must never overwrite a newer enrollment's files, undo a revocation, clear a newer pending record or delete current files.
- Publishing increments `generation`, swaps the bytes, sets `issued_wall`/`issued_tick`, broadcasts on the condition and sets `reauth_wanted_generation = generation`.
- **Reauth fencing** replaces `bridge_credential_reauth_pending: bool` with two atomic values: `reauth_wanted_generation` and the connection's `session_generation`, which is the generation captured **before** the dial. `bridge_ready` sets `session_generation = dial_generation` instead of clearing a flag (`hub_runtime_client.odin:422`). The drain sends `bridge_reauth` while `wanted > session_generation` and moves `session_generation` forward only on `bridge_reauth_result ok`.
- The action-scheduler fence (`action_scheduler.odin:705-709`) and the other per-operation fences compare `(epoch, generation)` instead of token bytes.

### D5. Durable pending rotated pair and recovery on restart

- Keep the current order and files (`.pending-rotation-v1`, `.refresh-request-v1`, the refresh file, then the access file), then add one non-secret metadata file `<credential_file>.meta-v1` written **after** the access file and before publishing: `{version:1, hub, bridge_id, access_token_id, issued_wall_ms, expires_in, refresh_expires_in, local_generation}`. Metadata whose `access_token_id` differs from the access file's id is ignored as unknown, which covers a crash between the access and metadata writes and an external file replacement.
- **Recover before the first dial.** Move pending-pair recovery (worker lines 786-810) into a synchronous `bridge_credential_recover_at_start` called in `main.odin` before `bridge_hub_runtime_start` (`:276`). It may only commit local files or adopt the pair. It never exchanges, and it is bounded by about 2 s of local I/O.
- **Local-commit failure stays in `Pending_Commit`.** The pair is not abandoned (today the worker returns, `enroll_device_flow.odin:878-888`). Local commit is retried with jittered backoff of 5 s doubling to 300 s, and the status shows `pending_commit`. The old refresh token is never exchanged again.
- An invalid pending record or a missing resumable receipt stays fail-closed, but it now sets `phase = Parked`, reason `pending_record_invalid`, with a status hint for `ham-bridge recovery resume-refresh` instead of a silent `return`.
- Startup with **known, fresh** metadata does not refresh. Today every start spends a rotation 30 s after start (`:777-786`). Startup with unknown or stale metadata renews immediately through `acquire`.

### D6. Short, interruptible wall-clock re-evaluation

- Replace `time.sleep(delay)` (`:779`) with `cond_wait_with_timeout(min(time_until_due, REEVAL_MAX = 30 s))`. Each wake recomputes D2's `elapsed`, so a suspend is noticed within 30 s of the process running again, whatever the platform's sleep semantics.
- Note `wall_elapsed − mono_elapsed > 60 s` as `suspend_or_clock_jump_detected` (counter only).
- Optional optimization, behind `when ODIN_OS` and kept separate: a suspend-inclusive tick (Linux `CLOCK_BOOTTIME`, Darwin `mach_continuous_time`, Windows `QueryInterruptTime`). The design must stay correct without it. Each platform's semantics stay **H** until measured.
- Signals also wake the loop: renewal requests, re-enrollment, stop, and a future OS resume or network-change hook.

### D7. Bounded transient backoff with jitter

- Refresh exchange: keep the 6-attempt/120 s budget with its random ±20% seed. Replace the fixed 60 s pause with an escalating jittered pause: 60 s, 120 s, 300 s cap, ±20%. This finally uses the `BRIDGE_REFRESH_BACKOFF_MAX_SECONDS` intent. A successful exchange or a detected network change resets it.
- WS reconnect: keep 500 ms doubling to 30 s, ±20%. After a renewal publishes a new generation, reset `reconnect_failures` and dial at once, still behind a 250 ms minimum spacing.
- Rejection-driven requests never bypass the exchange budget. If renewal is in a pause, `acquire` returns the current credential when its deadline passes, and the dial loop keeps its own backoff. Neither path can loop tightly. The model bounds offline-at-wake attempts (§3, S4).

### D8. Definitive invalid or revoked refresh handling

- A final refresh rejection (`invalid_grant`, family maximum or spent-token theft) keeps today's semantics: stop traffic, remove the pair and request file **and the new metadata file**, then mark `Refresh_Rejected` (`:1898-1905`).
- In addition, set `phase = Reenroll_Required` and broadcast to the waiters, which fail fast with status `reenroll_required`. No exchange or dial follows. Process parking (`enroll_account_replace.odin:363`) is unchanged.
- **User-visible status.** Add an `auth` object to `bridgesvc.Runtime_Status` (`status.odin:17`): `{phase, reason, generation, due_in_s, last_error_code, attempts, updated_at}`, with no token material. Show it in `ham-bridge status`. Include `auth` in the next heartbeat's `operation_recovery` so the Hub UI sees why the Bridge was offline after it reconnects. Optional Hub change H4 makes it visible before reconnect.
- Distinguish expired from rejected access (§1.4). A `bridge_credential_revoked` caused by an **unknown** access token (`"bridge token is invalid"`) currently parks finally even when the refresh token is still valid. With H2, a capable Bridge first tries one renewal and parks only if the refresh is refused.

### D9. Persisted-expiry metadata migration

| Case | Behavior |
| --- | --- |
| Upgrade: no `.meta-v1` | Unknown age: `acquire` renews before the first dial (eligible pair) or after `REEVAL_MAX`. That is one rotation, the same cost as today's 30 s refresh at start |
| `.meta-v1` present but the token ID mismatches, or the JSON is corrupt or oversized (>4 KiB), or the mode is not 0600 | Treated as unknown and rewritten on the next publish. Never fatal |
| Rollback to an older binary | Old binaries ignore `.meta-v1` and `.pending-rotation-v1` keeps version 1 unchanged, so rollback is safe. A stale `.meta-v1` left behind is token-ID-bound and therefore harmless |
| Enrollment (`bridge_enroll_persist`, `:664-689`) | Writes `.meta-v1` after both files |
| Re-enroll, rejection or offline `resume-refresh` | Remove or ignore `.meta-v1` together with the pair |
| Explicit `--bridge-token` with no credential file | No metadata and no renewal (unchanged, `:757-770`); status reports `renewal_unavailable` instead of nothing |

### D10. Hub-side changes (all optional for the core fix, all backward compatible)

- **H1. Typed expired-access cause.** Return `Unauthenticated` with cause `bridge_token_expired` on HTTP for expired access (`bridge_token_service.odin:369`). This adds one field; the message is unchanged. Old Bridges ignore it.
- **H2. Capability-gated invalid-token code.** When the hello advertises `credential_refresh_on_invalid:true`, `bridge_ws_auth_error` (`bridge_handlers.odin:3902-3911`) sends `bridge_token_invalid` instead of `bridge_credential_revoked` for `"bridge token is invalid"`. Old Bridges keep the current mapping, so no old Bridge starts looping. Family maximum and `Forbidden` revocation stay `bridge_credential_revoked`.
- **H3. No change to refresh security.** The 30 s and 600 s graces and reuse revocation stay as they are (see risk R3).
- **H4 (optional).** After the secret verifies, attribute expired-access upgrade failures to the Bridge ID, which the row already knows, instead of `BRIDGE_ID_UNKNOWN` (`bridge_handlers.odin:1767`). The UI can then show "credential expired, renewing" for a known Bridge. This is metrics and status only.
- Adding a Hub-side generation to the refresh reply is **not needed**, because the local generation is sufficient.

## 3. Verification matrix

Platform evidence columns use these values. **Model** means the scenario is reproduced by `bridge-auth-resume-recovery-model.py` (simulated clocks; it passes at this commit). **Unit/Sim** means it is planned as an Odin test with injected clocks. **Native** means a physical suspend run with redacted timestamps. As of this plan, **no native evidence exists on any platform**, and the incident remains unattributed.

| # | Scenario | Expected behavior (new) | Test type | Linux | macOS | Windows |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Sleep past access expiry (resume at 2 h, token issued at 0) | Renewal at most 30 s after the process runs again; at most one dial with the expired generation; exactly one exchange. Model: old outage 2326 s with 81 expired dials; new 0 s with 0 expired dials | Sim-clock unit (owner plus scheduler with injected wall, tick and sleep) and integration (fake Hub with fake clock) | Model ✔; Native **unproven** | Native **unproven**; Darwin timer semantics **H** | Native **unproven**; `Sleep`/QPC semantics **H** |
| S2 | Sleep past refresh expiry (31 days) | One exchange gets `invalid_grant`, then `Reenroll_Required`, pair wiped, status visible, no further dials. Model: 1 exchange, 0 dials after | Sim unit plus Hub service test (existing `:477` edge cases) | Model ✔; Native **unproven** | **unproven** | **unproven** |
| S3a | Wall clock jumps forward 2 h | At most one early rotation, no outage, no re-enroll | Sim unit | Model ✔ | Native **unproven** | Native **unproven** |
| S3b | Wall clock jumps back 2 h | The monotonic term governs; normal renewal at about 55 min; journal `Waiting_Repair` recovers through the jittered pause; no outage | Sim unit plus `retry_budget` unit | Model ✔ | **unproven** | **unproven** |
| S4 | Network offline at wake (10 min) | Renewal and dial retries bounded (model: 20 exchange attempts and 29 dials over 600 s); recovery at most about 72 s plus 30 s after the network returns | Sim unit plus integration with a failing transport | Model ✔ | **unproven** | **unproven** |
| S5 | Concurrent triggers (timer, WS expiry, dial, 3× HTTP 401, resume) | Exactly one exchange; all waiters get the new generation; a late reauth is not cleared by an old-generation hello | Unit with threads and a barrier (`credential_state_test.odin`) | Model ✔ | n/a (logic) | n/a (logic) |
| S6a | Crash after Hub rotation, before the pending save; restart within 600 s | The same request ID retries and the Hub regrants; no revocation | Unit with injected crash point (extend `refresh_recovery_test.odin:118`) plus Hub test `:497` | Model ✔ | Logic only | Logic only |
| S6b | Same, restart after more than 600 s | Hub treats it as reuse: family revoked, `Reenroll_Required` (documented Hub contract) | Hub test `:637` plus Bridge unit | Model ✔ | Logic only | Logic only |
| S6c | Crash after the pending save, before or between file writes | Restart commits before the first dial with no exchange; metadata rebuilt | Unit for each crash point (extend `:23`, `:39`) | Model ✔ | Logic only | Logic only; Windows rename and fsync durability **H** |
| S7 | Refresh or family revoked while running | WS `bridge_credential_revoked` or `invalid_grant` leads to a final stop; 0 further dials or exchanges | Integration (`bridge_session_credential_test.odin:248`, `:576`) plus Bridge unit | Model ✔ | Logic only | Logic only |
| S8a | Hub restart (10 min down) | DB-backed tokens survive; reconnect with the same generation; no extra exchange | Integration (restart fake Hub, same SQLite) | Model ✔ | Logic only | Logic only |
| S8b | Hub down across access expiry | Renewal retries bounded with jitter; recovery about 60 s after the Hub returns | Integration | Model ✔ | Logic only | Logic only |
| S9 | Stale response after re-enroll or a newer generation | Discarded before any write or publish; does not clear a newer reauth | Unit (fence predicates plus file-state assertions) | Model ✔ (predicate) | n/a | n/a |
| S10 | Cold start: no metadata, stale metadata, invalid pending record, explicit token | Renew before the first dial, a visible `pending_record_invalid`, or `renewal_unavailable`; never a silent stop | Unit | planned | n/a | n/a |

Native evidence protocol, run separately and only with user authorization:

1. On each OS, run a **test Hub with a shortened access lifetime** (for example 120 s) and a test enrollment. Never use production credentials.
2. Suspend for at least 3× the lifetime and resume.
3. Record only the redacted log lines, the UTC suspend and resume times, the first renewal time and the first `bridge_ready`.
4. Record the OS, kernel or build, the sleep mode (s2idle, deep or Modern Standby) and the release compiler identity.

## 4. Implementation breakdown

Each step is a separate ticket. Each needs an independent reviewer LGTM **and** user approval before the next step starts. Workers report the commands and checks they ran.

1. **Credential owner, generation, metadata and fencing (no scheduling change).**
   - Files: new `src/bridge/credential_state.odin` and `credential_state_test.odin`.
   - Changes:
     - `enroll_device_flow.odin`: replace `bridge_credential_snapshot`; publish and adopt with generation; write and remove `.meta-v1` in persist and rejection; add epoch and generation rechecks in `bridge_refresh_recovery_step`.
     - `hub_runtime_client.odin`: dial capture; `:422`; the drain at `:842`.
     - `action_scheduler.odin`: fence by generation.
     - `main.odin`: recover the pending pair before runtime start.
   - Tests: S5, S6c, S9, S10, metadata migration and rollback, the reauth race, plus the existing `refresh_recovery_test`, `enroll_device_flow_test` and `action_scheduler` suites.
   - Gate: reviewer checks fence completeness (every write and publish site) and no token in logs or metadata.
2. **Wakeable scheduler, acquire before connect, rejection-driven renewal, backoff.**
   - Files: `enroll_device_flow.odin` (worker becomes an event loop over an injectable `Clock{wall, tick, wait}`), `credential_state.odin`, `hub_runtime_client.odin` (`:378`, `:428-441`, `:881`), `retry_budget.odin` if the clock is injected, `enroll_device_flow.odin:909-915` (jittered escalating pause).
   - Tests: simulated-clock S1, S2, S3a/b, S4 and S8b. The suite must reproduce the old 2280 s gap with the old scheduler disabled behind a test flag, and fail on it.
   - Gate: reviewer confirms no long uninterruptible sleep remains on the credential path, and that the tight-loop bounds hold.
3. **HTTP callers, status, Hub typed causes.**
   - Files: `hub_http.odin` (expired-access 401 helper that requests renewal), HTTP sites in §1.3 and §1.9 (`owner_local.odin`, `owner_local_executor.odin`, `owner_migration.odin`, `executor_fence_client.odin`, `wrapper_endpoint.odin`, `task_chain_search_refresh.odin`, `agent_wake.odin`, `agent_reconcile.odin`, `shell_reconcile.odin`, `startup_readiness.odin`, `auto_update.odin`) switched to `acquire`; `src/lib/bridgesvc/status.odin` (`auth`); `service_cmds.odin`; Hub H1 in `bridge_token_service.odin` and `src/contracts/errors.odin`; H2 in `bridge_handlers.odin` with a hello capability; optional H4.
   - Tests: Hub `bridge_session_credential_test.odin` (H2 old versus new hello), `bridge_token_service_test.odin` (H1 cause), a Bridge 401 to single-renewal integration test, S7 and S8a.
   - Gate: reviewer checks old-Bridge compatibility (no new loops) and the security review of H2.
4. **Native evidence and rollout (user-authorized only).** Run the §3 protocol on Linux, macOS and Windows test enrollments. Ship behind the normal release train. Watch `auth.phase` counts and `bridge_token_expired` upgrade rates.
   - Gate: the user approves each platform row's evidence before claiming that platform is fixed.

## 5. Risks and open questions

- **R1. Clock semantics are unmeasured.** Darwin `nanosleep` and `CLOCK_MONOTONIC_RAW`, Windows `Sleep` and QPC during Modern Standby, and the release compiler's `core/time`. The design does not depend on them, because the 30 s re-evaluation plus the wall term covers them, but the claimed recovery bounds on macOS and Windows stay **H** until step 4.
- **R2. The process may not run promptly after wake** (App Nap, systemd freezing, network not ready). The fix bounds detection to 30 s of *process* time, not of wall time after the lid opens.
- **R3. Lost reply plus long sleep.** A rotation in flight when the machine sleeps, followed by a retry more than 600 s later, is treated as theft and revokes the family (S6b). That is intended Hub security. Open question: accept it, or have the Bridge avoid starting exchanges when the token has more than `SKEW_MARGIN` left (already true) and record "rotation in flight at suspend" for diagnosis. Extending the Hub window is **not** proposed.
- **R4. A wall clock that is wrong forward causes early rotations,** at most one per `REEVAL_MAX × budget`, bounded by the exchange budget and pause. A Hub clock that is wrong produces `rejected_after_renewal` and no loop.
- **R5. Metadata binding uses the non-secret token record ID.** Confirm with security review that storing `access_token_id` in a 0600 file next to the token adds no exposure. It is already the plain prefix of the file contents.
- **R6. Changing the WS mapping (H2)** must stay capability-gated. Unconditional `bridge_token_invalid` would turn today's final park into an endless backoff loop on old Bridges.
- **R7. Many new `acquire` call sites (§1.9).** A missed caller degrades to today's behavior (401 until the owner renews), not to a new failure. Step 3's reviewer checks with a grep that `bridge_credential_snapshot` has no remaining callers.
- **R8. Explicit-token deployments** (`--bridge-token` with no file) remain non-renewing by design. Should startup refuse an expiring `hba_` token without a credential file instead of only reporting `renewal_unavailable`?
- **Q1.** Is `SKEW_MARGIN = max(300 s, 10%)` acceptable, given the Hub's 60 s grace and refresh latency of up to 10 s?
- **Q2.** Should an OS resume or network-change hook (Electron `powerMonitor`, systemd-logind `PrepareForSleep`, `WM_POWERBROADCAST`) be added later as a wake signal? It is not required for correctness.
- **Q3.** Should the local status `auth` block also go to the Hub before reconnect (H4) or only after?
- **Q4.** The actual laptop incident is still unattributed. Collect the redacted fields listed in the diagnostic's last section before claiming that this plan fixes it.

## 6. Model record

`python3 -I docs/plans/bridge-auth-resume-recovery-model.py` (offline, simulated clocks):

1. It first asserts current-source premises at the working tree: the relative refresh sleep, the fixed 60 s pause, no renewal on `bridge_token_expired`, the unconditional reauth clear at ready, no generation in adopt, the Hub TTL, skew and retry-grace constants, and the WS revoked mapping.
2. It then runs S1–S9 against the old and new designs and asserts the orderings in §3.

Its output is ordering evidence only, not native suspend evidence.
