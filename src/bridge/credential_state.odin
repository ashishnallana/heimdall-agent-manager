package main

// ===== Bridge credential owner (auth recovery after laptop sleep) =====
//
// Plan: docs/plans/bridge-auth-resume-recovery.md (R6a, D1-D10). One process-wide
// owner is responsible for every Hub-bound use of the access credential:
//
//   - EXPIRY-AWARE ACQUISITION (D2). Every WS dial and every authenticated HTTP call
//     goes through bridge_credential_acquire (bridge_credential_snapshot is now a thin
//     wrapper over it). Age is max(wall elapsed, monotonic elapsed), each term used
//     only when valid. When the token is expired, inside the skew margin, or its age
//     is unknown, acquire requests a renewal and waits (bounded) for the next
//     generation before handing out a credential, so a laptop that slept past expiry
//     renews BEFORE its first dial instead of redialling with a dead token.
//   - WALL-CLOCK RE-EVALUATION (D6). The renewal worker never sleeps longer than
//     BRIDGE_CREDENTIAL_REEVAL_MAX_MS, and every wake recomputes age, so a suspend
//     is noticed within 30 s of the process running again whatever the platform's
//     timer does during sleep (Linux CLOCK_MONOTONIC excludes suspend).
//   - REJECTION-DRIVEN RENEWAL (D3). A typed expiry (WS bridge_token_expired, HTTP
//     "bridge access token has expired") or a typed unknown-token refusal triggers
//     AT MOST ONE renewal per credential generation. A rejection of an older
//     generation retries at once with the current one and spends nothing.
//   - SINGLE EXCHANGER, GENERATION + EPOCH FENCING (D4). Only the renewal worker
//     exchanges. Each exchange captures (epoch, base_generation). A pair the Hub
//     returned is ALWAYS committed within its epoch (the old refresh token is already
//     spent on the Hub); only an epoch change or a final stop discards it. A
//     generation mismatch at publish is an assertion failure: the pair is written and
//     published first, then the owner PARKS (phase Parked, reason
//     generation_assertion).
//
// WHAT "PARKED" STOPS. Phase Parked (reason generation_assertion) stops BOTH renewal
// and Hub traffic: acquire returns ok=false (no credential), the WS loop does not dial,
// bridge_hub_http_send_using refuses new requests, and the renewal worker exits. The
// credential files on disk already hold the newest pair, so restarting the bridge is
// the recovery; `ham-bridge status` shows auth.phase=parked with the reason.
// Phase Renewal_Stopped (pending_record_invalid, refresh_receipt_terminal) stops only
// renewal: the current access token keeps working until it expires, exactly as before,
// and status shows the operator repair command. Reenroll_Required (typed invalid_grant
// only) stops everything and is the re-enrollment state.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"
import cfg_lib "odin_test:lib/config"

BRIDGE_CREDENTIAL_REEVAL_MAX_MS :: i64(30_000)
BRIDGE_CREDENTIAL_ACQUIRE_WAIT_MS :: i64(10_000)
BRIDGE_CREDENTIAL_SKEW_MIN_SECONDS :: 300
BRIDGE_CREDENTIAL_SUSPEND_DETECT_MS :: i64(60_000)
// Exchange pauses after a spent retriable budget: 60 s, 120 s, then 300 s, +-20%.
BRIDGE_REFRESH_PAUSE_STEPS_SECONDS :: [3]i64{60, 120, 300}
// Local-commit retries of a received pair: 5 s doubling to 300 s, +-20%.
BRIDGE_REFRESH_COMMIT_BACKOFF :: Bridge_Backoff_Policy{base_ms = 5_000, max_ms = 300_000, jitter_pct = 20}
// The Hub's typed expired-access message (until a typed cause ships, H1).
BRIDGE_HUB_ACCESS_EXPIRED_MESSAGE :: "bridge access token has expired"
BRIDGE_HUB_ACCESS_INVALID_MESSAGE :: "bridge token is invalid"
BRIDGE_CREDENTIAL_META_MAX_BYTES :: 4096

Bridge_Credential_Phase :: enum {
	Valid,
	Due,
	Renewing,
	Pending_Commit,
	Offline_Retry,
	Renewal_Stopped,
	Parked,
	Reenroll_Required,
	Renewal_Unavailable,
}

bridge_credential_phase_word :: proc(p: Bridge_Credential_Phase) -> string {
	switch p {
	case .Valid:               return "valid"
	case .Due:                 return "due"
	case .Renewing:            return "renewing"
	case .Pending_Commit:      return "pending_commit"
	case .Offline_Retry:       return "offline_retry"
	case .Renewal_Stopped:     return "renewal_stopped"
	case .Parked:              return "parked"
	case .Reenroll_Required:   return "reenroll_required"
	case .Renewal_Unavailable: return "renewal_unavailable"
	}
	return "unknown"
}

// Phases in which no credential is handed out and nothing is dialled.
bridge_credential_phase_blocks_traffic :: proc(p: Bridge_Credential_Phase) -> bool {
	return p == .Parked || p == .Reenroll_Required
}

// Phases in which the renewal worker does not exchange.
bridge_credential_phase_blocks_renewal :: proc(p: Bridge_Credential_Phase) -> bool {
	return p == .Parked || p == .Reenroll_Required || p == .Renewal_Stopped || p == .Renewal_Unavailable
}

// Bridge_Credential_Clock is injectable so tests can model suspend: the monotonic
// term may stand still while the wall clock jumps.
Bridge_Credential_Clock :: struct {
	wall_ms: proc() -> i64,
	mono_ms: proc() -> i64,
}

g_bridge_credential_mono_base: time.Tick

@(init)
bridge_credential_clock_init :: proc "contextless" () {
	g_bridge_credential_mono_base = time.tick_now()
}

bridge_credential_real_wall_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// Process-local monotonic milliseconds, never 0 (0 means "no anchor").
bridge_credential_real_mono_ms :: proc() -> i64 {
	return i64(time.tick_since(g_bridge_credential_mono_base) / time.Millisecond) + 1
}

g_bridge_credential_clock := Bridge_Credential_Clock{wall_ms = bridge_credential_real_wall_ms, mono_ms = bridge_credential_real_mono_ms}

// Bridge_Credential_State is guarded by g_bridge_credential_mu. The token bytes stay
// in bridge_config.bridge_token (same mutex). Never logged; never persisted here.
Bridge_Credential_State :: struct {
	// True only while a renewal worker owns this credential. The zero state is a
	// pass-through (explicit tokens, enroll-only runtimes, unit fixtures).
	renewable:            bool,
	epoch:                u64,
	generation:           u64,
	known:                bool, // issue time and lifetime are known
	issued_wall_ms:       i64,
	issued_mono_ms:       i64, // 0 = no anchor in this process
	expires_in_s:         int,
	refresh_expires_in_s: int,
	phase:                Bridge_Credential_Phase,
	reason:               string, // static literal only
	renewal_requested:    bool,
	renewal_reason:       string,
	// Highest generation for which a typed rejection already requested renewal.
	rejection_renewal_gen: u64,
	rejection_pending:     bool, // the in-flight renewal was requested by a rejection
	minted_by_rejection:   bool, // the current generation came from such a renewal
	last_error_code:      contracts.Error_Code,
	attempts:             int,
	exchanges:            int,
	updated_wall_ms:      i64,
	assertion_failures:   int,
	suspend_detected:     int,
	clock_steps_back:     int,
	last_eval_wall_ms:    i64,
	last_eval_mono_ms:    i64,
}

g_bridge_cred: Bridge_Credential_State
g_bridge_credential_cond: sync.Cond

// Reauth fencing (D4): the generation the live Hub session is authenticated with
// (captured BEFORE the dial, advanced only by an ok bridge_reauth_result) and the
// newest published generation that the session should be renewed to.
bridge_credential_reauth_wanted_generation: u64
bridge_hub_session_generation: u64
bridge_hub_dial_generation: u64
bridge_hub_reauth_sent_generation: u64

bridge_credential_now :: proc() -> (wall, mono: i64) {
	return g_bridge_credential_clock.wall_ms(), g_bridge_credential_clock.mono_ms()
}

// bridge_credential_skew_ms: max(300 s, 10% of lifetime), capped at half the lifetime.
bridge_credential_skew_ms :: proc(expires_in_s: int) -> i64 {
	if expires_in_s <= 0 do return 0
	skew := max(BRIDGE_CREDENTIAL_SKEW_MIN_SECONDS, expires_in_s / 10)
	skew = min(skew, expires_in_s / 2)
	return i64(skew) * 1000
}

// bridge_credential_elapsed_ms is max(wall elapsed, monotonic elapsed), each term
// used only when valid. A backward wall step makes the wall term invalid (negative)
// and the monotonic term governs; a suspend freezes the monotonic term and the wall
// term governs. known=false when neither is usable.
bridge_credential_elapsed_ms :: proc(issued_wall, issued_mono, now_wall, now_mono: i64) -> (elapsed: i64, known: bool) {
	if issued_wall > 0 && now_wall >= issued_wall {
		elapsed = now_wall - issued_wall
		known = true
	}
	if issued_mono > 0 && now_mono >= issued_mono {
		elapsed = max(elapsed, now_mono - issued_mono)
		known = true
	}
	return
}

// bridge_credential_due_locked: due_in_ms until renewal is due (<= 0: due now).
bridge_credential_due_locked :: proc(now_wall, now_mono: i64) -> (due_in_ms: i64, needs: bool) {
	s := &g_bridge_cred
	if !s.renewable do return BRIDGE_CREDENTIAL_REEVAL_MAX_MS, false
	if !s.known do return 0, true
	if s.expires_in_s <= 0 do return BRIDGE_CREDENTIAL_REEVAL_MAX_MS, false
	elapsed, ok := bridge_credential_elapsed_ms(s.issued_wall_ms, s.issued_mono_ms, now_wall, now_mono)
	if !ok do return 0, true
	due_in_ms = i64(s.expires_in_s) * 1000 - bridge_credential_skew_ms(s.expires_in_s) - elapsed
	return due_in_ms, due_in_ms <= 0
}

bridge_credential_request_renewal_locked :: proc(reason: string) {
	s := &g_bridge_cred
	if s.renewal_requested do return // coalesced: the worker was already woken
	s.renewal_reason = reason
	s.renewal_requested = true
	if s.phase == .Valid do s.phase = .Due
	sync.cond_broadcast(&g_bridge_credential_cond)
}

// bridge_credential_request_renewal asks the worker for a renewal (coalesced).
bridge_credential_request_renewal :: proc(reason: string) {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	if !g_bridge_cred.renewable || bridge_credential_phase_blocks_renewal(g_bridge_cred.phase) do return
	bridge_credential_request_renewal_locked(reason)
}

// bridge_credential_acquire returns the newest credential for a Hub-bound use.
//
// When the owner manages renewal and the credential is expired, inside the skew
// margin or of unknown age, it requests one renewal and waits up to wait_ms (real
// time) for the generation to advance. It then returns the newest published
// credential either way: the Hub stays authoritative, so a local guess never blocks
// a still-valid token for longer than the deadline. While renewal is paused
// (Offline_Retry) it does not wait; the caller's own backoff applies.
//
// ok=false (and no token) only in Parked and Reenroll_Required: no dial, no request.
bridge_credential_acquire :: proc(wait_ms := BRIDGE_CREDENTIAL_ACQUIRE_WAIT_MS, allocator := context.allocator) -> (token: string, generation: u64, ok: bool) {
	now_wall, now_mono := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	if s.renewable {
		if bridge_credential_phase_blocks_traffic(s.phase) do return strings.clone("", allocator), s.generation, false
		_, due := bridge_credential_due_locked(now_wall, now_mono)
		// A typed rejection already asked for a renewal: wait for it too, so the
		// next dial does not present the rejected generation again (S3c).
		if (due || s.renewal_requested) && !bridge_credential_phase_blocks_renewal(s.phase) {
			bridge_credential_request_renewal_locked("acquire_due")
			start := s.generation
			started := time.tick_now()
			for s.generation == start && s.phase != .Offline_Retry && s.phase != .Pending_Commit && !bridge_credential_phase_blocks_renewal(s.phase) {
				spent := i64(time.tick_since(started) / time.Millisecond)
				if spent >= wait_ms do break
				_ = sync.cond_wait_with_timeout(&g_bridge_credential_cond, &g_bridge_credential_mu, time.Duration(min(wait_ms - spent, 1000)) * time.Millisecond)
			}
			if bridge_credential_phase_blocks_traffic(s.phase) do return strings.clone("", allocator), s.generation, false
		}
	}
	return strings.clone(bridge_config.bridge_token, allocator), s.generation, true
}

// bridge_credential_peek returns the current credential with no expiry check and no
// wait: for comparisons (fences) and the in-band reauth, never for a new request.
bridge_credential_peek :: proc(allocator := context.allocator) -> (token: string, generation: u64) {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	return strings.clone(bridge_config.bridge_token, allocator), g_bridge_cred.generation
}

bridge_credential_current_generation :: proc() -> u64 {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	return g_bridge_cred.generation
}

bridge_credential_traffic_blocked :: proc() -> bool {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	return g_bridge_cred.renewable && bridge_credential_phase_blocks_traffic(g_bridge_cred.phase)
}

// bridge_credential_publish installs a received pair's access token as the next
// generation. base_generation is the generation the exchange started from; with a
// single exchanger it always equals the current one. A mismatch is an assertion
// failure: the token is STILL published (it is the only one whose refresh half is
// unspent) and the owner then parks with reason generation_assertion. The caller
// has already written the pair to disk. Returns the new generation and whether the
// publish was consistent.
//
// recovered=true is a pair read back from a pending record: its age is measured
// from its persisted receipt time (wall only; the monotonic anchor of another
// process or boot is meaningless), never from now.
bridge_credential_publish :: proc(cred: Bridge_Enroll_Credential, base_generation: u64, check_base := true, recovered := false) -> (generation: u64, consistent: bool) {
	now_wall, now_mono := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	consistent = !check_base || s.generation == base_generation
	bridge_config.bridge_token = strings.clone(cred.access_token, runtime.heap_allocator())
	s.generation += 1
	s.known = true
	s.issued_wall_ms = now_wall
	s.issued_mono_ms = now_mono
	if recovered {
		s.issued_wall_ms = cred.received_wall_ms if cred.received_wall_ms > 0 else 0
		s.issued_mono_ms = 0
		s.known = s.issued_wall_ms > 0
	}
	s.expires_in_s = cred.expires_in
	s.refresh_expires_in_s = cred.refresh_expires_in
	s.renewal_requested = false
	s.renewal_reason = ""
	s.minted_by_rejection = s.rejection_pending
	s.rejection_pending = false
	s.updated_wall_ms = now_wall
	s.attempts = 0
	if consistent {
		if !bridge_credential_phase_blocks_traffic(s.phase) {
			s.phase = .Valid
			s.reason = ""
		}
	} else {
		s.phase = .Parked
		s.reason = "generation_assertion"
		s.assertion_failures += 1
	}
	generation = s.generation
	sync.cond_broadcast(&g_bridge_credential_cond)
	sync.mutex_unlock(&g_bridge_credential_mu)
	sync.atomic_store(&bridge_credential_reauth_wanted_generation, generation)
	if !consistent {
		fmt.eprintfln("bridge credential: ASSERTION generation changed during a renewal (base=%d); the received pair was written and published; renewal and Hub traffic are parked until restart", base_generation)
	}
	return
}

// bridge_credential_set_phase records a phase transition (no token material).
bridge_credential_set_phase :: proc(phase: Bridge_Credential_Phase, reason: string, code: contracts.Error_Code = .None, attempts := -1) {
	now_wall, _ := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	// Final phases are sticky within a process.
	if !(bridge_credential_phase_blocks_traffic(s.phase) && !bridge_credential_phase_blocks_traffic(phase)) {
		s.phase = phase
		s.reason = reason
	}
	if code != .None do s.last_error_code = code
	if attempts >= 0 do s.attempts = attempts
	s.updated_wall_ms = now_wall
	sync.cond_broadcast(&g_bridge_credential_cond)
	sync.mutex_unlock(&g_bridge_credential_mu)
}

bridge_credential_phase :: proc() -> (Bridge_Credential_Phase, string) {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	return g_bridge_cred.phase, g_bridge_cred.reason
}

// bridge_credential_bump_epoch ends the current activation: any exchange still in
// flight will not write its pair over the next enrollment's files.
bridge_credential_bump_epoch :: proc() -> u64 {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	g_bridge_cred.epoch += 1
	sync.cond_broadcast(&g_bridge_credential_cond)
	return g_bridge_cred.epoch
}

bridge_credential_epoch :: proc() -> u64 {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	return g_bridge_cred.epoch
}

// bridge_credential_commit_fence is the ONLY reason a received pair is not written:
// the epoch changed (re-enrollment/activation) or traffic was finally stopped.
bridge_credential_commit_fence :: proc(epoch: u64) -> (ok: bool, reason: string) {
	if bridge_credential_epoch() != epoch do return false, "epoch_changed"
	if sync.atomic_load(&bridge_hub_traffic_final) do return false, "final_stop"
	return true, ""
}

Bridge_Credential_Rejection :: enum {
	Access_Expired, // WS bridge_token_expired / HTTP expired-access 401
	Access_Invalid, // WS bridge_token_invalid (H2) / unknown-token refusal
}

Bridge_Credential_Rejection_Action :: enum {
	Not_Renewable,          // no renewal owner (or final): keep today's behavior
	Retry_Now,              // an older generation was rejected: dial again now
	Renewal_Requested,      // first rejection of this generation: one renewal
	Coalesced,              // this generation already triggered its one renewal
	Rejected_After_Renewal, // a rejection-minted generation was rejected again
}

// bridge_credential_note_rejection applies D3: at most one renewal per generation.
bridge_credential_note_rejection :: proc(attempted: u64, kind: Bridge_Credential_Rejection) -> Bridge_Credential_Rejection_Action {
	now_wall, _ := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	if !s.renewable || bridge_credential_phase_blocks_renewal(s.phase) do return .Not_Renewable
	if attempted < s.generation do return .Retry_Now
	if s.rejection_renewal_gen >= attempted do return .Coalesced
	s.rejection_renewal_gen = attempted
	s.updated_wall_ms = now_wall
	if s.minted_by_rejection {
		// Likely Hub clock skew or a Hub-side fault: fall back to the normal reconnect
		// and renewal schedule instead of looping on rotations.
		s.phase = .Offline_Retry
		s.reason = "rejected_after_renewal"
		sync.cond_broadcast(&g_bridge_credential_cond)
		return .Rejected_After_Renewal
	}
	s.rejection_pending = true
	bridge_credential_request_renewal_locked("rejected_expired" if kind == .Access_Expired else "rejected_invalid")
	return .Renewal_Requested
}

// bridge_credential_wait_newer waits (real time) until the generation passes
// `generation`, or the owner can no longer renew. Returns whether it advanced.
bridge_credential_wait_newer :: proc(generation: u64, wait_ms: i64) -> bool {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	started := time.tick_now()
	for s.generation <= generation && s.renewable && s.phase != .Offline_Retry && s.phase != .Pending_Commit && !bridge_credential_phase_blocks_renewal(s.phase) {
		spent := i64(time.tick_since(started) / time.Millisecond)
		if spent >= wait_ms do break
		_ = sync.cond_wait_with_timeout(&g_bridge_credential_cond, &g_bridge_credential_mu, time.Duration(min(wait_ms - spent, 1000)) * time.Millisecond)
	}
	return s.generation > generation
}

// bridge_credential_evaluate is one wall-clock re-evaluation (D6). It notes a
// suspend (wall advanced far more than the monotonic clock) or a backward wall
// step, and reports whether renewal is needed now or how long until it is due.
bridge_credential_evaluate :: proc(now_wall, now_mono: i64) -> (needs: bool, wait_ms: i64) {
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	if s.last_eval_wall_ms > 0 && s.last_eval_mono_ms > 0 {
		dw := now_wall - s.last_eval_wall_ms
		dm := now_mono - s.last_eval_mono_ms
		if dw - dm > BRIDGE_CREDENTIAL_SUSPEND_DETECT_MS {
			s.suspend_detected += 1
			fmt.printfln("bridge credential: suspend_or_clock_jump_detected (wall advanced %ds more than the monotonic clock); re-evaluating", (dw - dm) / 1000)
		} else if dw < -BRIDGE_CREDENTIAL_SUSPEND_DETECT_MS {
			s.clock_steps_back += 1
		}
	}
	s.last_eval_wall_ms = now_wall
	s.last_eval_mono_ms = now_mono
	if s.renewal_requested do return true, 0
	due, due_now := bridge_credential_due_locked(now_wall, now_mono)
	if due_now {
		if s.phase == .Valid do s.phase = .Due
		return true, 0
	}
	return false, clamp(due, 1, BRIDGE_CREDENTIAL_REEVAL_MAX_MS)
}

// bridge_credential_worker_wait sleeps up to ms (real time) but wakes on any
// renewal request, publish, phase change or stop broadcast. During a hold (budget
// backoff or pause) a pending request does not end the wait: requests never bypass
// the exchange budget (D7).
bridge_credential_worker_wait :: proc(ms: i64, holding := false) {
	if ms <= 0 do return
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	if (g_bridge_cred.renewal_requested && !holding) || bridge_credential_phase_blocks_renewal(g_bridge_cred.phase) do return
	_ = sync.cond_wait_with_timeout(&g_bridge_credential_cond, &g_bridge_credential_mu, time.Duration(min(ms, BRIDGE_CREDENTIAL_REEVAL_MAX_MS)) * time.Millisecond)
}

// ===== Persisted expiry metadata (D5, D9): <credential_file>.meta-v1 =====
//
// Non-secret: the token's record id (the plain prefix of hba_<id>.<secret>), issue
// time and lifetimes. Bound to the access file by access_token_id, so a crash
// between the access and metadata writes, an external replacement, or a rollback
// leaves it "unknown", never wrong. Old binaries ignore it.
Bridge_Credential_Meta :: struct {
	version:            int,
	hub:                string,
	bridge_id:          string,
	access_token_id:    string,
	issued_wall_ms:     i64,
	expires_in:         int,
	refresh_expires_in: int,
	local_generation:   u64,
}

bridge_credential_meta_path :: proc(credential_file: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({strings.trim_space(credential_file), ".meta-v1"}, allocator)
}

// bridge_credential_access_token_id: "hba_<id>.<secret>" -> "<id>" ("" otherwise).
bridge_credential_access_token_id :: proc(token: string) -> string {
	t := strings.trim_space(token)
	if !strings.has_prefix(t, "hba_") do return ""
	rest := t[4:]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 do return ""
	return rest[:dot]
}

bridge_credential_meta_write :: proc(credential_file, hub, bridge_id, access_token: string, issued_wall_ms: i64, expires_in, refresh_expires_in: int, generation: u64) -> bool {
	if strings.trim_space(credential_file) == "" do return false
	id := bridge_credential_access_token_id(access_token)
	if id == "" do return false
	meta := Bridge_Credential_Meta{
		version = 1, hub = bridge_credential_meta_hub(hub), bridge_id = strings.trim_space(bridge_id), access_token_id = id,
		issued_wall_ms = issued_wall_ms, expires_in = expires_in, refresh_expires_in = refresh_expires_in,
		local_generation = generation,
	}
	data, err := json.marshal(meta, allocator = context.temp_allocator)
	if err != nil || len(data) > BRIDGE_CREDENTIAL_META_MAX_BYTES do return false
	return bridge_retry_atomic_write(bridge_credential_meta_path(credential_file), data)
}

// bridge_credential_meta_load returns metadata only when it is well formed, owner
// only, small, and bound to this exact access token; anything else is "unknown".
bridge_credential_meta_load :: proc(credential_file, hub, bridge_id, access_token: string) -> (meta: Bridge_Credential_Meta, ok: bool) {
	path := bridge_credential_meta_path(credential_file)
	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil || info.type != .Regular || info.size > BRIDGE_CREDENTIAL_META_MAX_BYTES do return {}, false
	when ODIN_OS != .Windows {
		forbidden := os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
		if info.mode & forbidden != {} do return {}, false
	}
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return {}, false
	if json.unmarshal(bytes, &meta, allocator = context.temp_allocator) != nil do return {}, false
	id := bridge_credential_access_token_id(access_token)
	if meta.version != 1 || id == "" || meta.access_token_id != id do return {}, false
	if meta.hub != bridge_credential_meta_hub(hub) || meta.bridge_id != strings.trim_space(bridge_id) do return {}, false
	if meta.issued_wall_ms <= 0 || meta.expires_in < 0 do return {}, false
	return meta, true
}

bridge_credential_meta_hub :: proc(hub: string) -> string {
	if base, ok := bridge_hub_canonical_base(hub, context.temp_allocator); ok do return base
	return strings.trim_space(hub)
}

bridge_credential_meta_remove :: proc(credential_file: string) {
	if strings.trim_space(credential_file) == "" do return
	_ = os.remove(bridge_credential_meta_path(credential_file))
}

// bridge_credential_activate starts a new activation epoch for the credential the
// process resolved at startup, and loads its expiry metadata. renewable is set by
// the renewal worker's start; without it the owner is a pass-through.
bridge_credential_activate :: proc(credential_file: string, renewable: bool) {
	token, _ := bridge_credential_peek(context.temp_allocator)
	meta, has_meta := Bridge_Credential_Meta{}, false
	if renewable do meta, has_meta = bridge_credential_meta_load(credential_file, bridge_config.daemon_url, bridge_config.daemon_id, token)
	now_wall, _ := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	s.epoch += 1
	s.renewable = renewable
	s.generation = max(s.generation, 1)
	s.known = has_meta
	s.issued_wall_ms = meta.issued_wall_ms if has_meta else 0
	s.issued_mono_ms = 0 // a new process has no monotonic anchor for a stored token
	s.expires_in_s = meta.expires_in if has_meta else 0
	s.refresh_expires_in_s = meta.refresh_expires_in if has_meta else 0
	s.phase = .Valid if renewable else .Renewal_Unavailable
	s.reason = "" if renewable else "renewal_unavailable"
	s.updated_wall_ms = now_wall
	sync.cond_broadcast(&g_bridge_credential_cond)
	sync.mutex_unlock(&g_bridge_credential_mu)
}

// ===== Renewal (the single exchanger) =====

Bridge_Renewal_Env :: struct {
	credential_file, refresh_path, pending_path, request_path: string,
	key, api_base, bridge_id, config_path: string,
	exchange:     type_of(bridge_credential_refresh_typed),
	save_pending: type_of(bridge_refresh_pending_save),
	commit_pair:  type_of(bridge_refresh_pair_commit),
	recovery:     Bridge_Refresh_Recovery,
	loaded:       bool,
	pauses:       int,
	commit_failures: int,
	// Not before (by max(wall, monotonic) elapsed since the hold began): a requested
	// renewal never bypasses a pause or a budget backoff (D7).
	hold_wall_ms, hold_mono_ms, hold_ms: i64,
	jitter_seed:  u64, // 0 = random
	recovered:    bool, // the pair came from a pending record on disk
}

Bridge_Renewal_Outcome :: enum {
	Published,
	Wait,
	Final_Rejected,
	Renewal_Stopped,
	Parked,
	Stopped,
}

bridge_renewal_env_make :: proc(credential_file: string) -> Bridge_Renewal_Env {
	api_base := bridge_config.daemon_url
	bridge_id := strings.trim_space(bridge_config.daemon_id)
	return Bridge_Renewal_Env{
		credential_file = credential_file,
		refresh_path = bridge_enroll_refresh_file_for(credential_file),
		pending_path = strings.concatenate({credential_file, ".pending-rotation-v1"}),
		request_path = bridge_refresh_request_path(credential_file),
		key = fmt.aprintf("refresh:%s:%s", api_base, bridge_id),
		api_base = api_base, bridge_id = bridge_id,
		config_path = cfg_path_from_args_heap(),
		exchange = bridge_credential_refresh_typed,
		save_pending = bridge_refresh_pending_save,
		commit_pair = bridge_refresh_pair_commit,
	}
}

bridge_renewal_jitter :: proc(env: ^Bridge_Renewal_Env) -> u64 {
	if env.jitter_seed != 0 do return env.jitter_seed
	return rand.uint64()
}

// bridge_refresh_pause_ms: the escalating, jittered pause after the n-th (1-based)
// spent budget: 60 s, 120 s, 300 s cap, +-20%.
bridge_refresh_pause_ms :: proc(n: int, seed: u64) -> i64 {
	steps := BRIDGE_REFRESH_PAUSE_STEPS_SECONDS
	base := steps[clamp(n - 1, 0, len(steps) - 1)] * 1000
	span := base / 5
	if span <= 0 do return base
	return base - span + i64(seed % u64(2 * span + 1))
}

bridge_renewal_hold :: proc(env: ^Bridge_Renewal_Env, ms: i64) -> (Bridge_Renewal_Outcome, i64) {
	env.hold_wall_ms, env.hold_mono_ms = bridge_credential_now()
	env.hold_ms = max(ms, 1)
	return .Wait, env.hold_ms
}

bridge_renewal_hold_remaining :: proc(env: ^Bridge_Renewal_Env) -> i64 {
	if env.hold_ms <= 0 do return 0
	now_wall, now_mono := bridge_credential_now()
	elapsed, known := bridge_credential_elapsed_ms(env.hold_wall_ms, env.hold_mono_ms, now_wall, now_mono)
	if !known do return 0
	remaining := env.hold_ms - elapsed
	if remaining <= 0 { env.hold_ms = 0; return 0 }
	return remaining
}

bridge_renewal_finish_published :: proc(env: ^Bridge_Renewal_Env) -> Bridge_Renewal_Outcome {
	cred := env.recovery.pending.credential
	_, consistent := bridge_credential_publish(cred, env.recovery.base_generation, recovered = env.recovered)
	bridge_refresh_after_publish()
	_ = os.remove(env.pending_path); _ = os.remove(env.request_path)
	// The journal receipt for this rotation is complete; the next rotation starts fresh.
	_ = bridge_retry_operator_resume_sync(env.key, refresh = true)
	fmt.printfln("bridge credential refreshed (access token valid for %ds)", cred.expires_in)
	env.recovery = {}
	env.loaded = false
	env.recovered = false
	env.pauses = 0
	env.commit_failures = 0
	env.hold_ms = 0
	return .Published if consistent else .Parked
}

// bridge_renewal_attempt performs at most ONE exchange or ONE local commit and says
// what to do next. It never sleeps: the worker (or a simulated-clock test) waits.
bridge_renewal_attempt :: proc(env: ^Bridge_Renewal_Env, now_ms: i64) -> (Bridge_Renewal_Outcome, i64) {
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return .Stopped, 0
	if remaining := bridge_renewal_hold_remaining(env); remaining > 0 do return .Wait, remaining
	if !env.loaded {
		recovery, valid := bridge_refresh_pending_load(env.pending_path, env.key, env.api_base, env.bridge_id)
		if !valid {
			fmt.eprintln("bridge credential recovery parked: invalid pending rotation record; repair with: ham-bridge recovery resume-refresh")
			bridge_credential_set_phase(.Renewal_Stopped, "pending_record_invalid")
			return .Renewal_Stopped, 0
		}
		env.recovery = recovery
		env.recovery.pending.version = 1
		env.recovery.pending.key = env.key; env.recovery.pending.api_base = env.api_base; env.recovery.pending.bridge_id = env.bridge_id
		env.recovery.epoch = bridge_credential_epoch()
		env.recovery.base_generation = bridge_credential_current_generation()
		env.recovered = env.recovery.has_pair
		if env.recovered && env.recovery.pending.credential.received_wall_ms <= 0 {
			// A record written before receipt times were persisted: the first attempt
			// precedes the receipt, so this over-states the age (renews early, safely).
			env.recovery.pending.credential.received_wall_ms = env.recovery.pending.first_ms
		}
		if !env.recovery.has_pair {
			bridge_retry_reopen_success(env.key)
			// A receipt left terminal by a RETRIABLE failure gets a fresh bounded budget
			// at every start and after every pause.
			bridge_retry_reopen_retriable(env.key)
		}
		env.loaded = true
	}
	if env.recovery.has_pair {
		// A received pair (this process or a pending record from a crash): LOCAL commit
		// only. The old refresh token is spent; it is never exchanged again.
		bridge_credential_set_phase(.Pending_Commit, "pending_commit")
		ok, err := bridge_refresh_recovery_step(&env.recovery, env.pending_path, env.credential_file, env.refresh_path, env.api_base, env.bridge_id, "", {first_ms = env.recovery.pending.first_ms}, 0, env.exchange, env.save_pending, env.commit_pair)
		if ok do return bridge_renewal_finish_published(env), 0
		if err.cause == "epoch_changed" || err.cause == "final_stop" {
			env.recovery = {}; env.loaded = false
			return .Stopped, 0
		}
		env.commit_failures += 1
		bridge_credential_set_phase(.Pending_Commit, "pending_commit", err.code, env.commit_failures)
		return bridge_renewal_hold(env, bridge_backoff_delay_ms(BRIDGE_REFRESH_COMMIT_BACKOFF, env.commit_failures, bridge_renewal_jitter(env)))
	}
	budget, reserved := bridge_retry_reserve(env.key, now_ms)
	if !reserved {
		if bridge_operation_terminal(budget) {
			if bridge_refresh_terminal_is_retriable(budget) do return bridge_renewal_pause(env, budget)
			// A journal receipt alone is never a Hub refusal: stop renewing (visible),
			// never wipe the pair from local state.
			fmt.eprintfln("bridge credential recovery stopped: state=%v attempts=%d code=%v class=%v", budget.state, budget.attempts, budget.code, budget.class)
			bridge_credential_set_phase(.Renewal_Stopped, "refresh_receipt_terminal", budget.code, budget.attempts)
			return .Renewal_Stopped, 0
		}
		return bridge_renewal_hold(env, max(1, min(budget.next_ms - now_ms, budget.deadline_ms - now_ms)))
	}
	stored, has_stored := bridge_read_token_file(env.refresh_path)
	defer delete(stored)
	if !has_stored || !bridge_enroll_credential_usable(stored) {
		// A missing or malformed LOCAL refresh token is not a Hub answer, so it is not
		// final: renewal stops visibly and nothing is wiped.
		_ = bridge_retry_finish(env.key, now_ms, false, contracts.wire_error(.Internal_Error, "refresh_token_unreadable"))
		fmt.eprintln("bridge credential renewal stopped: the stored refresh token is missing or malformed")
		bridge_credential_set_phase(.Renewal_Stopped, "refresh_token_unreadable")
		return .Renewal_Stopped, 0
	}
	err: contracts.Wire_Error
	success := false
	{
		// The request id is durable BEFORE the first send and reused by every retry of
		// this rotation, across restarts, until the new pair is committed.
		if env.recovery.request_id == "" {
			request_id, request_ok := bridge_refresh_request_ensure(env.request_path, env.key, env.api_base, env.bridge_id)
			if request_ok do env.recovery.request_id = request_id
		}
		if env.recovery.request_id != "" {
			// Fence base: the exchange starts from the CURRENT epoch and generation.
			env.recovery.epoch = bridge_credential_epoch()
			env.recovery.base_generation = bridge_credential_current_generation()
			bridge_credential_set_phase(.Renewing, "renewing")
			sync.mutex_lock(&g_bridge_credential_mu); g_bridge_cred.exchanges += 1; sync.mutex_unlock(&g_bridge_credential_mu)
			success, err = bridge_refresh_recovery_step(&env.recovery, env.pending_path, env.credential_file, env.refresh_path, env.api_base, env.bridge_id, stored, budget, bridge_operation_timeout_ms(budget, now_ms), env.exchange, env.save_pending, env.commit_pair)
		} else {
			// Nothing was sent: retrying is safe.
			err = contracts.wire_error(.Internal_Error, "refresh_request_unpersisted")
		}
	}
	if err.cause == "epoch_changed" || err.cause == "final_stop" {
		_ = bridge_retry_finish(env.key, now_ms, false, contracts.wire_error(.Bridge_Offline))
		env.recovery = {}; env.loaded = false
		return .Stopped, 0
	}
	finished := bridge_retry_finish(env.key, now_ms, success, err, base_ms = 5000, jitter_seed = env.jitter_seed)
	if success do return bridge_renewal_finish_published(env), 0
	if bridge_refresh_error_is_final(err) {
		bridge_refresh_apply_rejection(env.config_path, env.api_base, env.bridge_id, env.credential_file, env.refresh_path, env.request_path, err)
		fmt.eprintfln("bridge credential refresh REJECTED by the Hub (invalid_grant); re-enrollment is required")
		return .Final_Rejected, 0
	}
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return .Stopped, 0
	if env.recovery.unknown_outcome {
		fmt.eprintfln("bridge credential refresh outcome unknown (attempt %d, code=%v); retrying the same rotation", finished.attempts, err.code)
	}
	bridge_credential_set_phase(.Offline_Retry if !env.recovery.has_pair else .Pending_Commit, "refresh_retry" if !env.recovery.has_pair else "pending_commit", err.code, finished.attempts)
	if env.recovery.has_pair {
		env.commit_failures += 1
		return bridge_renewal_hold(env, bridge_backoff_delay_ms(BRIDGE_REFRESH_COMMIT_BACKOFF, env.commit_failures, bridge_renewal_jitter(env)))
	}
	if bridge_operation_terminal(finished) {
		if bridge_refresh_terminal_is_retriable(finished) do return bridge_renewal_pause(env, finished)
		fmt.eprintfln("bridge credential recovery stopped: state=%v attempts=%d code=%v class=%v", finished.state, finished.attempts, finished.code, finished.class)
		bridge_credential_set_phase(.Renewal_Stopped, "refresh_receipt_terminal", finished.code, finished.attempts)
		return .Renewal_Stopped, 0
	}
	return bridge_renewal_hold(env, max(1, finished.next_ms - now_ms))
}

// bridge_renewal_pause: a spent retriable budget rests 60/120/300 s (+-20%) and
// then reopens with a fresh bounded budget. Renewal never stops for a retriable
// failure: an unreachable hub, a proxy 401 or a lost reply must not cost the
// machine its enrollment.
bridge_renewal_pause :: proc(env: ^Bridge_Renewal_Env, b: Bridge_Operation_Budget) -> (Bridge_Renewal_Outcome, i64) {
	env.pauses += 1
	pause := bridge_refresh_pause_ms(env.pauses, bridge_renewal_jitter(env))
	fmt.eprintfln("bridge credential refresh paused: state=%v attempts=%d code=%v; retrying in %ds", b.state, b.attempts, b.code, pause / 1000)
	_ = bridge_retry_reopen_retriable(env.key)
	bridge_credential_set_phase(.Offline_Retry, "refresh_paused", b.code, b.attempts)
	return bridge_renewal_hold(env, pause)
}

// bridge_refresh_after_publish: renew the live session in-band and reopen a sync
// budget parked on the old credential.
bridge_refresh_after_publish :: proc() {
	key := bridge_action_scheduler_sync_key()
	defer delete(key)
	bridge_retry_credential_repaired(key)
	bridge_credential_status_changed()
}

// bridge_credential_recover_at_start finishes a pending rotated pair BEFORE the first
// dial (D5): local commit and adoption only, never an exchange, bounded by local I/O.
// A failure leaves the pair pending for the worker (phase Pending_Commit).
bridge_credential_recover_at_start :: proc(env: ^Bridge_Renewal_Env) -> bool {
	if !os.exists(env.pending_path) do return true
	outcome, _ := bridge_renewal_attempt(env, bridge_runtime_now_ms())
	return outcome == .Published
}

// bridge_credential_renewal_loop is the worker body: an event loop over the
// credential condition. It never sleeps longer than BRIDGE_CREDENTIAL_REEVAL_MAX_MS
// without re-evaluating age against both clocks.
bridge_credential_renewal_loop :: proc(env: ^Bridge_Renewal_Env) {
	for {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do return
		phase, _ := bridge_credential_phase()
		if bridge_credential_phase_blocks_renewal(phase) {
			bridge_credential_status_changed()
			return
		}
		now_wall, now_mono := bridge_credential_now()
		needs, wait := bridge_credential_evaluate(now_wall, now_mono)
		if !needs && !env.loaded {
			bridge_credential_worker_wait(wait)
			continue
		}
		outcome, hold := bridge_renewal_attempt(env, bridge_runtime_now_ms())
		switch outcome {
		case .Published:
			continue
		case .Wait:
			bridge_credential_status_changed()
			bridge_credential_worker_wait(min(hold, BRIDGE_CREDENTIAL_REEVAL_MAX_MS), holding = true)
		case .Final_Rejected, .Renewal_Stopped, .Parked, .Stopped:
			bridge_credential_status_changed()
			return
		}
	}
}

// ===== Status (no token material) =====

bridge_credential_auth_status :: proc() -> bridgesvc.Auth_Status {
	now_wall, now_mono := bridge_credential_now()
	sync.mutex_lock(&g_bridge_credential_mu)
	defer sync.mutex_unlock(&g_bridge_credential_mu)
	s := &g_bridge_cred
	st := bridgesvc.Auth_Status{
		phase = bridge_credential_phase_word(s.phase), reason = s.reason, generation = s.generation,
		last_error_code = contracts.error_code_string(s.last_error_code) if s.last_error_code != .None else "",
		attempts = s.attempts, updated_at = s.updated_wall_ms / 1000,
	}
	if s.renewable && s.known && s.expires_in_s > 0 {
		due, _ := bridge_credential_due_locked(now_wall, now_mono)
		st.due_in_s = max(due / 1000, 0)
	}
	return st
}

bridge_credential_status_changed :: proc() {
	when ODIN_TEST { return } else {
		if bridge_hub_is_enroll_only_runtime() do return
		bridge_local_status_write(sync.atomic_load(&bridge_hub_runtime_up))
	}
}

// Recognise the Hub's typed final refresh refusal: 401 Unauthenticated whose cause
// (newer Hubs) or message (all Hubs) is invalid_grant. Nothing else is final.
BRIDGE_INVALID_GRANT :: "invalid_grant"
bridge_refresh_error_is_final :: proc(err: contracts.Wire_Error) -> bool {
	return err.code == .Unauthenticated && (err.cause == BRIDGE_INVALID_GRANT || err.message == BRIDGE_INVALID_GRANT)
}

cfg_path_from_args_heap :: proc() -> string {
	return strings.clone(cfg_lib.config_path_from_args(os.args))
}
