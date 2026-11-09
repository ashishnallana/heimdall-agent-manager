# Bridge authentication recovery after laptop sleep

Status: **implemented in R6b (steps 1-3, Linux logic only); native sleep evidence (step 4) not collected.** See "Implementation status (R6b)" below. Original plan baseline `846b1b72` (branch `bridge-owned/r6`). Builds on the approved diagnostic [docs/diagnostics/bridge-auth-sleep.md](../diagnostics/bridge-auth-sleep.md) (commit `9d12513f`, source `873aa65c`). Ordering model: [bridge-auth-resume-recovery-model.py](bridge-auth-resume-recovery-model.py).

No live authentication requests, credential reads or copies, sign-out/re-login, restarts, deploys or installs were performed for this plan. Nothing here parses, prints or logs a token.

## Implementation status (R6b)

Implemented on `cc/r6b-auth-resume` (base `6f4a119b`). Code: `src/bridge/credential_state.odin` (owner, acquire, evaluation, renewal attempt/loop, metadata, status), `src/bridge/enroll_device_flow.odin` (start, classification, fencing, commit, rejection), `src/bridge/hub_runtime_client.odin` (dial, reauth fencing, session frames, hello), `src/bridge/hub_http.odin` (HTTP admission and typed-expiry hook), `src/lib/bridgesvc/status.odin` + `service_cmds.odin` (`auth` in `ham-bridge status`), Hub `src/hub/service/bridge/bridge_token_service.odin`, `src/hub/repository/sqlite/bridge_{token_,}repo_sqlite.odin` (H0) and `src/hub/transport/http/bridge_handlers.odin` (H2).

- **D1/D4 single owner, generation + epoch fencing.** Only the renewal worker exchanges. A received pair is always committed within its epoch; only `epoch_changed`/`final_stop` discards it. A generation mismatch at publish writes and publishes the pair, then sets phase `Parked`, reason `generation_assertion`.
- **Parked stops renewal AND Hub traffic.** In `Parked`, `bridge_credential_acquire` returns no credential, the WS loop does not dial, `bridge_hub_http_send_using` refuses new requests (`Aborted`), and the worker exits. The files hold the newest pair, so a restart recovers. `Renewal_Stopped` (`pending_record_invalid`, `refresh_receipt_terminal`, `refresh_token_unreadable`) stops renewal only; the current access token keeps serving until it expires. `Reenroll_Required` (typed `invalid_grant` only) stops everything.
- **D2 expiry-aware acquisition.** `bridge_credential_snapshot` is now the expiry-aware `acquire`, so all HTTP call sites (including `executor_local_native.odin:46`) renew first. The WS dial calls `acquire` directly and records the dial generation. Fences, the in-band reauth and the local loopback check use `bridge_credential_peek` (no wait).
- **D3** at most one renewal per generation on a typed expiry/invalid rejection (WS `bridge_token_expired`/`bridge_token_invalid`, older Hubs' `bridge_credential_revoked` + "bridge token is invalid", HTTP 401 "bridge access token has expired" for the current credential). A rejection-minted generation rejected again gives `Offline_Retry`/`rejected_after_renewal`, no loop.
- **D5** pending pair committed before the first dial (`bridge_credential_refresh_start` now runs before `bridge_hub_runtime_start`); local-commit failure stays `Pending_Commit` with 5 s-300 s jittered backoff and never re-exchanges. `.meta-v1` is written after the access file and on enrollment; fresh metadata means no rotation at start.
- **D6** the worker waits at most 30 s between wall/monotonic re-evaluations; suspend (wall minus monotonic > 60 s) and backward steps are counted.
- **D7** exchange budget unchanged (6 in 120 s); pauses 60/120/300 s ±20%; requests never bypass a hold.
- **D8** only a typed `invalid_grant` (cause or message) is final; a bare/proxy 401/403 or any other typed 401 on refresh is retriable and never stops traffic or wipes the pair. Status `auth{phase,reason,generation,due_in_s,last_error_code,attempts}` is in `runtime-status.json` and printed by `ham-bridge status`.
- **H0** repository read failures in refresh, verify, rotate, the grace/retry family reads and the session recheck return `Internal_Error` (session recheck keeps the session); SQLite token/bridge lookups distinguish `SQLITE_DONE` (Not_Found) from step failures. **H2** `bridge_token_invalid` is sent only when the hello carries `credential_refresh_on_invalid:true`. `invalid_grant` now also carries `cause:"invalid_grant"`.
- **Not done:** H1 (typed expired cause on HTTP), H4 (Hub-side attribution), `auth` in the heartbeat's `operation_recovery`, the optional suspend-inclusive tick, and the step-4 native evidence. The model script's source-premise checks describe the pre-fix source and now fail by design; run it against `6f4a119b` to reproduce the old-design numbers.

## 0. Summary

A laptop Bridge that sleeps past its one-hour access-token lifetime keeps redialling with the expired `hba_` token until its proactive refresh timer fires. On Linux that timer is a relative sleep that does not count suspended time, so the outage can last up to about 51 minutes after wake. Nothing on the rejection path wakes renewal. The plan makes **one credential owner** responsible for every Hub-bound credential use:

- It checks credential age against a wall clock and a monotonic clock before each connect and HTTP request, with a skew margin.
- It re-evaluates at least every 30 seconds, so it notices a wake within one interval.
- Typed rejections can trigger at most one renewal for each credential generation.
- Concurrent triggers share one single-flight exchange.
- It publishes credentials by local generation, with session-epoch fencing.
- It keeps and finishes the existing crash-safe pending-pair protocol, recovering a pending pair before the first dial.

Refresh-token rejection stays final and leads to a visible re-enrollment state, but **only** for a typed `invalid_grant` from the Hub. A bare 401 from a proxy or gateway and any Hub repository error are transient.

A received pair is always made durable within its epoch, because after a 200 the old refresh token is already spent on the Hub.

Two Hub and classification fixes are **mandatory**:

- **H0** (step 1): repository errors return `Internal_Error`, never `invalid` or `invalid_grant`.
- **H2** (step 2): a capability-gated `bridge_token_invalid` WS code that a capable Bridge answers with one renewal instead of a permanent park.

**Until H0 and H2 ship, a transient Hub database error or a gateway 401 can still permanently park a Bridge or wipe its pair** (§1.4). The typed expired-access cause (H1) and Bridge attribution (H4) stay optional.

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
| **A bare 401 (no typed body, for example from a proxy or gateway) is treated as `Unauthenticated`.** On the refresh path that is final: stop traffic, then `apply_rejection` wipes the pair | `src/bridge/retry_budget.odin:71-84` (`:79`); `enroll_device_flow.odin:1789`, `:1898-1905` | C-src (model premise check) |
| **The Hub discards repository errors and reads them as "not found".** `refresh_bridge_token` (`bridge_token_service.odin:474`) and `rotate_from` (`:580`) then return `invalid_grant`; `verify_access_token_scoped` (`:345`, `:373`) returns `"bridge token is invalid"`, which `bridge_ws_auth_error` maps to `bridge_credential_revoked`. **A database blip can therefore wipe the pair or permanently park a Bridge** | as cited; `bridge_handlers.odin:3902-3911` | C-src (model premise check); the frequency of such blips is **H** |
| After a 200 the presented refresh token is already spent (`rotate_from` calls `mark_token_rotated`, `:588-603`). Presenting it again after the grace window is treated as reuse and revokes the family (`:501-510`) | as cited | C-src, C-test (`bridge_token_service_test.odin:216`, `:637`) |
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
- **Limit: a suspend followed by a backward NTP step at wake undercounts age on both terms.** The suspend-excluding tick misses the sleep, and the wall term loses the step. After a restart there is no tick anchor at all, so only the (understated) wall term remains. In both cases `acquire` may consider an expired token fresh, and **recovery relies on D3**: the first typed `bridge_token_expired` or expired-access 401 triggers one renewal. Matrix row S3c and the model cover both the in-process and the restart case (outage of at most one reconnect backoff plus one exchange, and at most one dial with the expired generation). The optional suspend-inclusive tick in D6 narrows this case on platforms where its semantics are measured.
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
- Each exchange captures `(epoch, base_generation, request_id)`.
- **A received pair is never silently discarded within its epoch.** After a 200 the presented refresh token is already spent on the Hub (`rotate_from` → `mark_token_rotated`, `bridge_token_service.odin:588-603`). Dropping the pair would force a later reuse of the spent token, which after the grace window revokes the family (`:501-510`).
- **Before the durable write** (pending record, refresh file, access file, metadata) the exchange checks only two things: the epoch is unchanged, and traffic is not final-stopped (no re-enroll marker). If either fails, the pair belongs to an enrollment that no longer exists or has been finally refused. It is not written, and the other enrollment's files, pending record and markers are left untouched. This is the only discard, and it is logged with reason `epoch_changed` or `final_stop`.
- **Within the same epoch, the pair is always committed durably.** A generation that no longer equals `base_generation` at commit or publish time cannot happen with a single exchanger, so it is treated as an **assertion failure**: the pair is still written, it is still published (it is the only usable refresh token), and then the phase becomes `Parked` with reason `generation_assertion`, a visible status and a diagnostic counter. It is never a silent discard. Matrix row S9 asserts the on-disk files after this path.
- A pair from a stale epoch must never overwrite a newer enrollment's files, undo a revocation, clear a newer pending record or delete current files.
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

- **Refresh is final only on a typed Hub refusal:** an HTTP 401 whose parsed wire error is `unauthenticated` with the Hub's `invalid_grant` body (`bridge_refresh_handlers.odin:52`, `:58`).
  - A bare 401 or 403 with no parseable Hub error body (a proxy, gateway or captive portal) is **retriable** under the exchange budget and pauses. It never calls `bridge_hub_stop_traffic(true)` or `apply_rejection`. This changes `bridge_credential_refresh_typed` (`enroll_device_flow.odin:1789`) and the refresh-path use of `bridge_operation_http_error` (`retry_budget.odin:79`). Other callers keep the current mapping.
  - `Internal_Error`, 5xx and transport failures stay retriable (unchanged).
  - This classification change ships in **step 1**, together with Hub H0.
- A final refresh rejection (typed `invalid_grant`, family maximum or spent-token theft) keeps today's semantics: stop traffic, remove the pair and request file **and the new metadata file**, then mark `Refresh_Rejected` (`:1898-1905`).
- In addition, set `phase = Reenroll_Required` and broadcast to the waiters, which fail fast with status `reenroll_required`. No exchange or dial follows. Process parking (`enroll_account_replace.odin:363`) is unchanged.
- **User-visible status.** Add an `auth` object to `bridgesvc.Runtime_Status` (`status.odin:17`): `{phase, reason, generation, due_in_s, last_error_code, attempts, updated_at}`, with no token material. Show it in `ham-bridge status`. Include `auth` in the next heartbeat's `operation_recovery` so the Hub UI sees why the Bridge was offline after it reconnects. Optional Hub change H4 makes it visible before reconnect.
- Distinguish expired from rejected access (§1.4). A `bridge_credential_revoked` caused by an **unknown** access token (`"bridge token is invalid"`), or by a Hub repository error read as unknown, currently parks finally even when the refresh token is still valid.
  - H0 (step 1) removes the repository-error cause.
  - H2 (step 2) makes a capable Bridge first try one renewal. It parks only if the refresh gets a typed refusal.
  - Both are **mandatory**. **Until both ship, the permanent park on a transient Hub fault or an unknown-token reply remains possible**, and the plan does not claim otherwise.

### D9. Persisted-expiry metadata migration

| Case | Behavior |
| --- | --- |
| Upgrade: no `.meta-v1` | Unknown age: `acquire` renews before the first dial (eligible pair) or after `REEVAL_MAX`. That is one rotation, the same cost as today's 30 s refresh at start |
| `.meta-v1` present but the token ID mismatches, or the JSON is corrupt or oversized (>4 KiB), or the mode is not 0600 | Treated as unknown and rewritten on the next publish. Never fatal |
| Rollback to an older binary | Old binaries ignore `.meta-v1` and `.pending-rotation-v1` keeps version 1 unchanged, so rollback is safe. A stale `.meta-v1` left behind is token-ID-bound and therefore harmless |
| Enrollment (`bridge_enroll_persist`, `:664-689`) | Writes `.meta-v1` after both files |
| Re-enroll, rejection or offline `resume-refresh` | Remove or ignore `.meta-v1` together with the pair |
| Explicit `--bridge-token` with no credential file | No metadata and no renewal (unchanged, `:757-770`); status reports `renewal_unavailable` instead of nothing |

### D10. Hub-side changes (H0 and H2 mandatory; H1 and H4 optional; all backward compatible)

- **H0 (mandatory, step 1). Repository errors are not authentication answers.** `refresh_bridge_token` (`bridge_token_service.odin:474`), `rotate_from` (`:580`, and every other repository read or write in it), `verify_access_token_scoped` (`:345`, `:373`), `access_token_session_credential` (`:406`) and `session_credential_state` (`:434`, `:441`) must check the repository error result that is currently discarded (`_`). A real not-found keeps today's uniform `invalid`/`invalid_grant` and its equal-work miss path. Any other repository error returns `Internal_Error` (retriable, HTTP 5xx). On WS it goes through `bridge_ws_auth_error`'s non-authentication branch (`:3903-3906`), which sends a plain `bridge_error` and never `bridge_credential_revoked`. A session recheck that cannot read the row keeps the session until the next check instead of returning `.Revoked`. Tests: inject a failing repository into `bridge_token_service_test.odin` and `bridge_session_credential_test.odin`, and assert no family revocation, no `invalid_grant` and no revoked frame.

- **H1 (optional). Typed expired-access cause.** Return `Unauthenticated` with cause `bridge_token_expired` on HTTP for expired access (`bridge_token_service.odin:369`). This adds one field; the message is unchanged. Old Bridges ignore it.
- **H2 (mandatory, step 2). Capability-gated invalid-token code.** When the hello advertises `credential_refresh_on_invalid:true`, `bridge_ws_auth_error` (`bridge_handlers.odin:3902-3911`) sends `bridge_token_invalid` instead of `bridge_credential_revoked` for `"bridge token is invalid"`. Old Bridges keep the current mapping, so no old Bridge starts looping. Family maximum and `Forbidden` revocation stay `bridge_credential_revoked`. Bridge handling (step 2): on `bridge_token_invalid`, request one renewal (D3). Park only on a typed refresh refusal (D8). Otherwise use the normal backoff.
- **H3. No change to refresh security.** The 30 s and 600 s graces and reuse revocation stay as they are (see risk R3).
- **H4 (optional).** After the secret verifies, attribute expired-access upgrade failures to the Bridge ID, which the row already knows, instead of `BRIDGE_ID_UNKNOWN` (`bridge_handlers.odin:1767`). The UI can then show "credential expired, renewing" for a known Bridge. This is metrics and status only.
- Adding a Hub-side generation to the refresh reply is **not needed**, because the local generation is sufficient.

## 3. Verification matrix

Platform evidence columns use these values. **Model** means the scenario is reproduced by `bridge-auth-resume-recovery-model.py` (simulated clocks; it passes at this commit). **Unit/Sim** means it is planned as an Odin test with injected clocks. **Native** means a physical suspend run with redacted timestamps. As of this plan, **no native evidence exists on any platform**, and the incident remains unattributed.

| # | Scenario | Expected behavior (new) | Test type | Linux | macOS | Windows |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Sleep past access expiry (resume at 2 h, token issued at 0) | Renewal at most 30 s after the process runs again; at most one dial with the expired generation; exactly one exchange. Model: old outage 2326 s with 81 expired dials; new 0 s with 0 expired dials | Sim-clock unit (owner plus scheduler with injected wall, tick and sleep) and integration (fake Hub with fake clock) | Model ✔; Native **unproven** | Native **unproven**; Darwin timer semantics **H** | Native **unproven**; `Sleep`/QPC semantics **H** |
| S2 | Sleep past refresh expiry (31 days) | One exchange gets a **typed** `invalid_grant`, then `Reenroll_Required`, pair wiped, status visible, no further dials. Model: 1 exchange, 0 dials after | Sim unit plus Hub service test (existing `:477` edge cases) | Model ✔; Native **unproven** | **unproven** | **unproven** |
| S2b | A bare 401 from a proxy or gateway on refresh at wake (no Hub body) | Retriable: budget and pause, pair and metadata **kept**, no stop-traffic, no re-enroll marker; recovers once the gateway passes requests | Bridge unit (`bridge_refresh_response_classify` with a bodyless 401) plus sim | Model ✔ | Logic only | Logic only |
| S2c | Hub repository error during refresh (H0) | `Internal_Error`: retriable, no `invalid_grant`, no family revocation, pair kept; recovery within one jittered pause (model: 65 s) | Hub service test with failing repository plus Bridge unit | Model ✔ | Logic only | Logic only |
| S3a | Wall clock jumps forward 2 h | At most one early rotation, no outage, no re-enroll | Sim unit | Model ✔ | Native **unproven** | Native **unproven** |
| S3b | Wall clock jumps back 2 h | The monotonic term governs; normal renewal at about 55 min; journal `Waiting_Repair` recovers through the jittered pause; no outage | Sim unit plus `retry_budget` unit | Model ✔ | **unproven** | **unproven** |
| S3c | Suspend past expiry, then a backward NTP step at wake; also with a process restart at wake (no tick anchor) | `acquire` undercounts age and dials once with the expired generation; the typed rejection triggers one renewal (D3). Model: outage 0 s in process, 1 s after restart, at most 1 expired dial, 1 exchange | Sim unit (both variants) | Model ✔ | **unproven** | **unproven** |
| S4 | Network offline at wake (10 min) | Renewal and dial retries bounded (model: 20 exchange attempts and 29 dials over 600 s); recovery at most about 72 s plus 30 s after the network returns | Sim unit plus integration with a failing transport | Model ✔ | **unproven** | **unproven** |
| S5 | Concurrent triggers (timer, WS expiry, dial, 3× HTTP 401, resume) | Exactly one exchange; all waiters get the new generation; a late reauth is not cleared by an old-generation hello | Unit with threads and a barrier (`credential_state_test.odin`) | Model ✔ | n/a (logic) | n/a (logic) |
| S6a | Crash after Hub rotation, before the pending save; restart within 600 s | The same request ID retries and the Hub regrants; no revocation | Unit with injected crash point (extend `refresh_recovery_test.odin:118`) plus Hub test `:497` | Model ✔ | Logic only | Logic only |
| S6b | Same, restart after more than 600 s | Hub treats it as reuse: family revoked, `Reenroll_Required` (documented Hub contract) | Hub test `:637` plus Bridge unit | Model ✔ | Logic only | Logic only |
| S6c | Crash after the pending save, before or between file writes | Restart commits before the first dial with no exchange; metadata rebuilt | Unit for each crash point (extend `:23`, `:39`) | Model ✔ | Logic only | Logic only; Windows rename and fsync durability **H** |
| S7 | Refresh or family revoked while running | WS `bridge_credential_revoked` or typed `invalid_grant` leads to a final stop; 0 further dials or exchanges | Integration (`bridge_session_credential_test.odin:248`, `:576`) plus Bridge unit | Model ✔ | Logic only | Logic only |
| S7b | Hub repository error during WS upgrade verification or session recheck (H0); an unknown-token reply to a capable Bridge (H2) | H0: plain `bridge_error` and normal reconnect backoff, never `bridge_credential_revoked`, no park (model: reconnect 23 s after the fault clears). H2: one renewal, then park only on a typed refresh refusal. Old hello: today's mapping is unchanged | Hub integration with failing repository; old and new hello variants | Model ✔ (H0) | Logic only | Logic only |
| S8a | Hub restart (10 min down) | DB-backed tokens survive; reconnect with the same generation; no extra exchange | Integration (restart fake Hub, same SQLite) | Model ✔ | Logic only | Logic only |
| S8b | Hub down across access expiry | Renewal retries bounded with jitter; recovery about 60 s after the Hub returns | Integration | Model ✔ | Logic only | Logic only |
| S9 | Late exchange result: (a) after re-enroll or final stop (epoch changed); (b) same epoch, generation mismatch | (a) Not written; the other enrollment's files, pending record and markers are byte-identical afterwards. (b) **Pair committed**: refresh, access and metadata files hold the received pair, pending is cleared, phase `Parked/generation_assertion` is visible, no second exchange. Neither clears a newer reauth | Unit with file-state assertions after each path | Model ✔ (policy plus on-disk asserts) | n/a | n/a |
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
     - Refresh finality (D8): only a typed `invalid_grant` is final; a bare 401 or 403 on the refresh path is retriable (`enroll_device_flow.odin:1789`, refresh-path classification over `retry_budget.odin:71-84`).
     - **Hub H0** (mandatory): `src/hub/service/bridge/bridge_token_service.odin` (`:345`, `:373`, `:474`, `:580` and the other discarded repository errors), with `Internal_Error` passed through `bridge_refresh_handlers.odin` and `bridge_ws_auth_error`.
   - Tests: S2b, S2c, S5, S6c, S7b (H0 part), S9 (both on-disk variants), S10, metadata migration and rollback, the reauth race, plus the existing `refresh_recovery_test`, `enroll_device_flow_test`, `action_scheduler`, `bridge_token_service_test` and `bridge_session_credential_test` suites.
   - Gate: reviewer checks fence completeness (every write and publish site), that no received pair can be dropped within an epoch, that no bare 401 or repository error can reach `apply_rejection`, `revoke_token_family` or `bridge_credential_revoked`, and that no token appears in logs or metadata.
2. **Wakeable scheduler, acquire before connect, rejection-driven renewal, backoff.**
   - Files: `enroll_device_flow.odin` (worker becomes an event loop over an injectable `Clock{wall, tick, wait}`), `credential_state.odin`, `hub_runtime_client.odin` (`:378`, `:428-441`, `:881`, plus a `bridge_token_invalid` case), `retry_budget.odin` if the clock is injected, `enroll_device_flow.odin:909-915` (jittered escalating pause).
   - **Hub H2** (mandatory): `bridge_handlers.odin:3902-3911` sends `bridge_token_invalid` for a hello with `credential_refresh_on_invalid:true`; the Bridge hello (`bridge_hub_hello_json`) advertises it.
   - Tests: simulated-clock S1, S2, S3a/b/c, S4 and S8b; S7b (H2, old and new hello). The suite must reproduce the old design's 2326 s outage from S1 with the old scheduler re-enabled behind a test flag, and must fail on it.
   - Gate: reviewer confirms no long uninterruptible sleep remains on the credential path, the tight-loop bounds hold, and old Bridges keep today's mapping.
3. **HTTP callers, status, Hub typed causes.**
   - Files: `hub_http.odin` (expired-access 401 helper that requests renewal), `src/lib/bridgesvc/status.odin` (`auth`), `service_cmds.odin`, optional Hub H1 in `bridge_token_service.odin` and `src/contracts/errors.odin`, and optional H4.
   - Switch **all** remaining non-test `bridge_credential_snapshot()` call sites to `acquire`. At `846b1b72` there are 34 call sites in 16 files:
     - `action_scheduler.odin:515`, `:687`, `:705`, `:818`, `:902`, `:1240`
     - `agent_reconcile.odin:169`, `:182`
     - `agent_wake.odin:300`, `:303`
     - `auto_update.odin:65`
     - `enroll_device_flow.odin:1075`
     - `executor_fence_client.odin:31`, `:68`
     - **`executor_local_native.odin:46`**
     - `hub_runtime_client.odin:345`, `:378`, `:846`, `:5928`
     - `main.odin:238`, `:241`, `:750`
     - `owner_local.odin:72`
     - `owner_local_executor.odin:215`
     - `owner_migration.odin:31`, `:43`
     - `shell_reconcile.odin:136`, `:149`
     - `startup_readiness.odin:228`
     - `task_chain_search_refresh.odin:71`, `:74`
     - `wrapper_endpoint.odin:542`, `:558`, `:587`

     Steps 1 and 2 already convert the `hub_runtime_client` and `action_scheduler` sites.
   - Tests: a Bridge 401 to single-renewal integration test, `bridge_token_service_test.odin` (H1 cause, if taken), S7 and S8a.
   - Gate: reviewer confirms with a grep that `bridge_credential_snapshot` has no remaining non-test callers, and checks old-Bridge compatibility.
4. **Native evidence and rollout (user-authorized only).** Run the §3 protocol on Linux, macOS and Windows test enrollments. Ship behind the normal release train. Watch `auth.phase` counts and `bridge_token_expired` upgrade rates.
   - Gate: the user approves each platform row's evidence before claiming that platform is fixed.

## 5. Risks and open questions

- **R1. Clock semantics are unmeasured.** Darwin `nanosleep` and `CLOCK_MONOTONIC_RAW`, Windows `Sleep` and QPC during Modern Standby, and the release compiler's `core/time`. The design does not depend on them, because the 30 s re-evaluation plus the wall term covers them, but the claimed recovery bounds on macOS and Windows stay **H** until step 4.
- **R2. The process may not run promptly after wake** (App Nap, systemd freezing, network not ready). The fix bounds detection to 30 s of *process* time, not of wall time after the lid opens.
- **R3. Lost reply plus long sleep.** A rotation in flight when the machine sleeps, followed by a retry more than 600 s later, is treated as theft and revokes the family (S6b). That is intended Hub security. Open question: accept it, or have the Bridge avoid starting exchanges when the token has more than `SKEW_MARGIN` left (already true) and record "rotation in flight at suspend" for diagnosis. Extending the Hub window is **not** proposed.
- **R4. A wall clock that is wrong forward causes early rotations,** at most one per `REEVAL_MAX × budget`, bounded by the exchange budget and pause. A Hub clock that is wrong produces `rejected_after_renewal` and no loop.
- **R5. Metadata binding uses the non-secret token record ID.** Confirm with security review that storing `access_token_id` in a 0600 file next to the token adds no exposure. It is already the plain prefix of the file contents.
- **R6. Changing the WS mapping (H2)** is mandatory but must stay capability-gated. Unconditional `bridge_token_invalid` would turn today's final park into an endless backoff loop on old Bridges.
- **R7. Many new `acquire` call sites (34 sites in 16 files, listed in step 3, including `executor_local_native.odin:46`).** A missed caller degrades to today's behavior (401 until the owner renews), not to a new failure. Step 3's reviewer checks with a grep that `bridge_credential_snapshot` has no remaining non-test callers.
- **R9. Permanent park until H0 and H2 ship.** Today a transient Hub repository error, or a gateway's bare 401 on refresh, can wipe the pair or park the Bridge permanently (§1.4). The sleep fix alone does not remove this. Steps 1 and 2 must ship H0, the refresh-finality change and H2 before the plan is reported as complete.
- **R10. A suspend plus a backward NTP step undercounts age** (D2, S3c). Correctness then rests on the rejection-driven path D3, costing at most one dial with the expired generation and one reconnect backoff.
- **R8. Explicit-token deployments** (`--bridge-token` with no file) remain non-renewing by design. Should startup refuse an expiring `hba_` token without a credential file instead of only reporting `renewal_unavailable`?
- **Q1.** Is `SKEW_MARGIN = max(300 s, 10%)` acceptable, given the Hub's 60 s grace and refresh latency of up to 10 s?
- **Q2.** Should an OS resume or network-change hook (Electron `powerMonitor`, systemd-logind `PrepareForSleep`, `WM_POWERBROADCAST`) be added later as a wake signal? It is not required for correctness.
- **Q3.** Should the local status `auth` block also go to the Hub before reconnect (H4) or only after?
- **Q4.** The actual laptop incident is still unattributed. Collect the redacted fields listed in the diagnostic's last section before claiming that this plan fixes it.

## 6. Model record

`python3 -I docs/plans/bridge-auth-resume-recovery-model.py` (offline, simulated clocks):

1. It first asserts current-source premises at the working tree: the relative refresh sleep, the fixed 60 s pause, no renewal on `bridge_token_expired`, the unconditional reauth clear at ready, no generation in adopt, the Hub TTL, skew and retry-grace constants, and the WS revoked mapping.
2. It also asserts the premises behind the revision: Hub repository errors discarded in `refresh_bridge_token`, `verify_access_token_scoped` and `rotate_from`; a bare 401 mapped to `Unauthenticated`; and refresh `Unauthenticated` stopping traffic.
3. It then runs S1–S9, including S2b, S2c, S3c, S7b and both S9 on-disk variants, against the old and new designs and asserts the orderings in §3.

Its output is ordering evidence only, not native suspend evidence.
