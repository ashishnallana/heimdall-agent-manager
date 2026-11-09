package main

// Simulated-clock tests for the credential owner (docs/plans/bridge-auth-resume-
// recovery.md §3). The wall and monotonic clocks are injected, so a "suspend" is the
// wall clock jumping while the monotonic clock stands still, exactly as Linux
// CLOCK_MONOTONIC behaves. The Hub is a fake that knows which access token is live
// and when it expires on ITS clock, and counts exchanges and stale dials.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"

CS_HUB :: "https://hub.test"
CS_T0_WALL :: i64(1_800_000_000_000)

cs_wall: i64
cs_mono: i64
cs_wall_ms :: proc() -> i64 { return sync.atomic_load(&cs_wall) }
cs_mono_ms :: proc() -> i64 { return sync.atomic_load(&cs_mono) }
cs_advance :: proc(wall_ms, mono_ms: i64) {
	sync.atomic_add(&cs_wall, wall_ms)
	sync.atomic_add(&cs_mono, mono_ms)
	sync.atomic_add(&cs_hub.now, wall_ms) // the Hub's clock is real elapsed time
}

Cs_Hub_Mode :: enum { Ok, Bare_401, Repo_Error, Invalid_Grant, Typed_401_Other }
Cs_Hub :: struct {
	now:          i64, // Hub wall ms
	access:       string,
	access_until: i64,
	exchanges:    int,
	dials:        int,
	stale_dials:  int,
	mode:         Cs_Hub_Mode,
	during:       proc(), // runs inside the exchange (races injected by a test)
}
cs_hub: Cs_Hub

cs_exchange :: proc(api, token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
	cs_hub.exchanges += 1
	if cs_hub.during != nil do cs_hub.during()
	switch cs_hub.mode {
	case .Bare_401:
		return bridge_refresh_response_classify(httpc.Response{status = 401}, true, api)
	case .Repo_Error:
		return bridge_refresh_response_classify(httpc.Response{status = 500, body = transmute([]byte)string(`{"error":{"code":"internal_error","message":"the bridge credential store is temporarily unavailable; retry"}}`)}, true, api)
	case .Invalid_Grant:
		return bridge_refresh_response_classify(httpc.Response{status = 401, body = transmute([]byte)string(`{"error":{"code":"unauthenticated","cause":"invalid_grant","message":"invalid_grant"}}`)}, true, api)
	case .Typed_401_Other:
		return bridge_refresh_response_classify(httpc.Response{status = 401, body = transmute([]byte)string(`{"error":{"code":"unauthenticated","message":"gateway says no"}}`)}, true, api)
	case .Ok:
	}
	n := cs_hub.exchanges
	cs_hub.access = fmt.aprintf("hba_g%d.secret", n)
	cs_hub.access_until = cs_hub.now + 3600_000
	return {access_token = strings.clone(cs_hub.access), refresh_token = fmt.aprintf("hbf_g%d.secret", n), expires_in = 3600, refresh_expires_in = 2_592_000}, true, {}, false
}

// cs_dial is one WS dial: acquire (expiry-aware), then the Hub's verdict. A
// rejected dial reports the typed expiry exactly as the WS frame path does.
cs_dial :: proc(wait_ms: i64 = 0) -> bool {
	token, generation, ok := bridge_credential_acquire(wait_ms)
	defer delete(token)
	if !ok do return false
	cs_hub.dials += 1
	if token == cs_hub.access && cs_hub.now <= cs_hub.access_until do return true
	cs_hub.stale_dials += 1
	_ = bridge_credential_note_rejection(generation, .Access_Expired)
	return false
}

Cs_Fixture :: struct {
	dir, credential_file: string,
	env:                  Bridge_Renewal_Env,
	saved_config:         Bridge_Config,
	saved_state:          Bridge_Credential_State,
	saved_clock:          Bridge_Credential_Clock,
}

cs_setup :: proc(tag: string) -> ^Cs_Fixture {
	f := new(Cs_Fixture)
	hub_pause_test_reset()
	f.saved_config = bridge_config
	f.saved_state = g_bridge_cred
	f.saved_clock = g_bridge_credential_clock
	f.dir = fmt.aprintf("%s/.cache/heimdall-tests/cred-state-%s-%d-%d", os.get_env("HOME", context.temp_allocator), tag, os.get_pid(), time.to_unix_nanoseconds(time.now()))
	f.credential_file = fmt.aprintf("%s/credential", f.dir)
	sync.atomic_store(&cs_wall, CS_T0_WALL)
	sync.atomic_store(&cs_mono, 1000)
	g_bridge_credential_clock = {wall_ms = cs_wall_ms, mono_ms = cs_mono_ms}
	bridge_config.daemon_url = CS_HUB
	bridge_config.daemon_id = fmt.aprintf("brg_cs%s", tag)
	bridge_config.bridge_token = "hba_g0.secret"
	cs_hub = {now = CS_T0_WALL, access = "hba_g0.secret", access_until = CS_T0_WALL + 3600_000}
	_ = bridge_write_secret_file(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator), "hbf_g0.secret")
	_ = bridge_write_credential_file(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g0.secret")
	g_bridge_cred = {
		renewable = true, epoch = 1, generation = 1, known = true,
		issued_wall_ms = CS_T0_WALL, issued_mono_ms = 1000, expires_in_s = 3600, phase = .Valid,
	}
	f.env = bridge_renewal_env_make(f.credential_file)
	f.env.exchange = cs_exchange
	f.env.config_path = "" // never write a re-enroll marker into a real profile
	f.env.jitter_seed = 7
	return f
}

cs_teardown :: proc(f: ^Cs_Fixture) {
	bridge_config = f.saved_config
	g_bridge_cred = f.saved_state
	g_bridge_credential_clock = f.saved_clock
	sync.atomic_store(&bridge_credential_reauth_wanted_generation, 0)
	hub_pause_test_reset()
	_ = os.remove_all(f.dir)
}

// cs_drive runs the renewal worker's decisions on the simulated clock until it
// publishes or gives up; each Wait advances both clocks (the process is awake).
cs_drive :: proc(f: ^Cs_Fixture, max_steps := 200) -> (outcome: Bridge_Renewal_Outcome, waited_ms: i64) {
	for _ in 0..<max_steps {
		needs, wait := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
		if !needs && !f.env.loaded {
			cs_advance(wait, wait)
			waited_ms += wait
			continue
		}
		o, hold := bridge_renewal_attempt(&f.env, cs_wall_ms())
		if o != .Wait do return o, waited_ms
		cs_advance(hold, hold)
		waited_ms += hold
	}
	return .Wait, waited_ms
}

cs_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	token, _, _, _ := bridge_credential_split(string(data))
	return strings.clone(token, context.temp_allocator)
}

// S1: the laptop sleeps past access expiry (monotonic clock frozen). The first dial
// after wake must not present the dead token: acquire renews first. Exactly one
// exchange, zero stale dials, and the worker notices the suspend within one tick.
@(test)
cred_sleep_past_expiry_refreshes_before_first_dial :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s1"); defer cs_teardown(f)

	testing.expect(t, cs_dial(), "a fresh credential dials")
	_, _ = bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	// Suspend for two hours: wall +7200 s, monotonic +0; then the process runs 1 s.
	cs_advance(7_200_000, 0)
	cs_advance(1000, 1000)
	needs, _ := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, needs, "the first re-evaluation after wake finds the credential due")
	testing.expect_value(t, g_bridge_cred.suspend_detected, 1)

	// The real ordering: the runtime dials while the worker runs on its own thread.
	worker := thread.create_and_start_with_poly_data(&f.env, proc(env: ^Bridge_Renewal_Env) {
		context.allocator = runtime.heap_allocator()
		bridge_credential_renewal_loop(env)
	})
	ok := cs_dial(wait_ms = 5000)
	bridge_credential_set_phase(.Renewal_Unavailable, "test_stop")
	thread.join(worker); thread.destroy(worker)

	testing.expect(t, ok, "the first dial after wake uses the renewed credential")
	testing.expect_value(t, cs_hub.stale_dials, 0)
	testing.expect_value(t, cs_hub.exchanges, 1)
	testing.expect_value(t, g_bridge_cred.generation, u64(2))
	testing.expect_value(t, cs_read(f.credential_file), "hba_g1.secret")
	testing.expect_value(t, cs_read(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "hbf_g1.secret")
	meta, meta_ok := bridge_credential_meta_load(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g1.secret")
	testing.expect(t, meta_ok && meta.expires_in == 3600 && meta.access_token_id == "g1", "expiry metadata is bound to the new access token")
	testing.expect_value(t, sync.atomic_load(&bridge_credential_reauth_wanted_generation), u64(2))
}

// The worker never sleeps past one 30 s re-evaluation, whatever the lifetime.
@(test)
cred_reevaluation_interval_is_bounded :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("reeval"); defer cs_teardown(f)
	needs, wait := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, !needs && wait == BRIDGE_CREDENTIAL_REEVAL_MAX_MS)
	// Due at 3600 - max(300, 360) = 3240 s.
	cs_advance(3_239_000, 3_239_000)
	needs, wait = bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, !needs && wait == 1000)
	cs_advance(1000, 1000)
	needs, _ = bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, needs, "due inside the skew margin")
}

// Clock rules (D2): a backward wall step is ignored (monotonic governs); a forward
// jump costs at most an early renewal; unknown age is due.
@(test)
cred_elapsed_uses_the_larger_valid_clock :: proc(t: ^testing.T) {
	e, known := bridge_credential_elapsed_ms(10_000, 100, 5_000, 2_100)
	testing.expect(t, known && e == 2_000, "a backward wall step leaves the monotonic term")
	e, known = bridge_credential_elapsed_ms(10_000, 100, 7_210_000, 1_100)
	testing.expect(t, known && e == 7_200_000, "a frozen monotonic clock leaves the wall term")
	_, known = bridge_credential_elapsed_ms(0, 0, 5_000, 5_000)
	testing.expect(t, !known)
	testing.expect_value(t, bridge_credential_skew_ms(3600), i64(360_000))
	testing.expect_value(t, bridge_credential_skew_ms(120), i64(60_000))
	testing.expect_value(t, bridge_credential_skew_ms(0), i64(0))
}

// S3c: suspend plus a backward NTP step undercounts age on both clocks, so acquire
// believes the expired token is fresh. One stale dial, its typed rejection triggers
// ONE renewal, and the next dial succeeds. Further rejections never renew again.
@(test)
cred_rejection_renews_at_most_once_per_generation :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s3c"); defer cs_teardown(f)
	// The Hub's clock moved 2 h; the bridge's wall and monotonic clocks only 10 s.
	sync.atomic_add(&cs_hub.now, 7_200_000)
	cs_advance(10_000, 10_000)
	testing.expect(t, !cs_dial(), "the undercounted credential is rejected once")
	testing.expect_value(t, cs_hub.stale_dials, 1)
	testing.expect(t, g_bridge_cred.renewal_requested, "the typed rejection requested a renewal")
	testing.expect_value(t, bridge_credential_note_rejection(1, .Access_Expired), Bridge_Credential_Rejection_Action.Coalesced)
	outcome, _ := cs_drive(f)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Published)
	testing.expect(t, cs_dial(), "the renewed generation dials")
	testing.expect_value(t, cs_hub.exchanges, 1)
	testing.expect_value(t, cs_hub.stale_dials, 1)
	// A late rejection of the OLD generation retries with the current one.
	testing.expect_value(t, bridge_credential_note_rejection(1, .Access_Expired), Bridge_Credential_Rejection_Action.Retry_Now)
	// The rejection-minted generation rejected again (Hub clock skew): no second
	// renewal, no loop.
	testing.expect_value(t, bridge_credential_note_rejection(2, .Access_Expired), Bridge_Credential_Rejection_Action.Rejected_After_Renewal)
	testing.expect_value(t, bridge_credential_note_rejection(2, .Access_Expired), Bridge_Credential_Rejection_Action.Coalesced)
	testing.expect(t, !g_bridge_cred.renewal_requested)
	needs, _ := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, !needs, "nothing asks for another exchange")
	testing.expect_value(t, cs_hub.exchanges, 1)
}

// Transient failures (a gateway's bare 401, a typed 401 that is not invalid_grant,
// a Hub repository error) never park, never stop traffic and never wipe the pair.
// Exchanges are bounded (6 per 120 s budget) with escalating 60/120/300 s pauses.
@(test)
cred_transient_refresh_failures_never_park_or_reenroll :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	for mode, i in ([]Cs_Hub_Mode{.Bare_401, .Typed_401_Other, .Repo_Error}) {
		f := cs_setup(fmt.tprintf("transient%d", i))
		cs_hub.mode = mode
		cs_advance(3_300_000, 3_300_000) // due
		outcome, waited := cs_drive(f, max_steps = 40)
		testing.expectf(t, outcome == .Wait, "mode %v keeps retrying (got %v)", mode, outcome)
		testing.expect(t, !sync.atomic_load(&bridge_hub_traffic_stopped), "traffic is never stopped")
		testing.expect(t, !bridge_hub_traffic_final)
		phase, _ := bridge_credential_phase()
		testing.expectf(t, phase == .Offline_Retry, "mode %v phase %v", mode, phase)
		testing.expect_value(t, cs_read(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "hbf_g0.secret")
		testing.expect_value(t, cs_read(f.credential_file), "hba_g0.secret")
		testing.expect(t, f.env.pauses >= 2, "spent budgets pause and reopen")
		// Bounded: at most 6 exchanges per budget, one budget per pause.
		testing.expectf(t, cs_hub.exchanges <= 6 * (f.env.pauses + 1), "mode %v: %d exchanges over %d pauses", mode, cs_hub.exchanges, f.env.pauses)
		_ = waited
		token, _, ok := bridge_credential_acquire(0)
		testing.expect(t, ok && token == "hba_g0.secret", "the still-held credential is served")
		delete(token)
		// The gateway or database recovers: the same pair renews.
		cs_hub.mode = .Ok
		outcome, _ = cs_drive(f)
		testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Published)
		cs_teardown(f)
	}
}

@(test)
cred_refresh_pause_escalates_with_jitter :: proc(t: ^testing.T) {
	for base, i in ([]i64{60_000, 120_000, 300_000, 300_000}) {
		for seed in ([]u64{0, 1, 999_999, max(u64)}) {
			p := bridge_refresh_pause_ms(i + 1, seed)
			testing.expectf(t, p >= base - base / 5 && p <= base + base / 5, "pause %d seed %d = %d", i + 1, seed, p)
		}
	}
	testing.expect(t, bridge_refresh_pause_ms(1, 1) != bridge_refresh_pause_ms(1, 50_000), "jittered")
}

// S2: a TYPED invalid_grant is final: pair and metadata wiped, re-enrollment
// required, no further exchange or dial.
@(test)
cred_typed_invalid_grant_requires_reenrollment :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s2"); defer cs_teardown(f)
	_ = bridge_credential_meta_write(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g0.secret", CS_T0_WALL, 3600, 2_592_000, 1)
	cs_hub.mode = .Invalid_Grant
	cs_advance(31 * 86_400_000, 0) // asleep past the refresh lifetime
	outcome, _ := cs_drive(f)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Final_Rejected)
	testing.expect_value(t, cs_hub.exchanges, 1)
	phase, reason := bridge_credential_phase()
	testing.expect_value(t, phase, Bridge_Credential_Phase.Reenroll_Required)
	testing.expect_value(t, reason, "refresh_rejected")
	testing.expect(t, !os.exists(f.credential_file) && !os.exists(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "pair wiped")
	testing.expect(t, !os.exists(bridge_credential_meta_path(f.credential_file)), "metadata wiped")
	testing.expect(t, bridge_hub_traffic_final)
	dials := cs_hub.dials
	testing.expect(t, !cs_dial(), "no dial after a final refusal")
	testing.expect_value(t, cs_hub.dials, dials)
	testing.expect_value(t, bridge_credential_note_rejection(1, .Access_Expired), Bridge_Credential_Rejection_Action.Not_Renewable)
}

// Only a typed invalid_grant is final; a bodyless 401/403 from a proxy is not.
@(test)
cred_refresh_classification_only_typed_invalid_grant_is_final :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, ok, err, _ := bridge_refresh_response_classify(httpc.Response{status = 401}, true, CS_HUB)
	testing.expect(t, !ok && !bridge_refresh_error_is_final(err) && err.class == .retriable && err.code != .Unauthenticated)
	_, ok, err, _ = bridge_refresh_response_classify(httpc.Response{status = 403, body = transmute([]byte)string("<html>denied</html>")}, true, CS_HUB)
	testing.expect(t, !ok && !bridge_refresh_error_is_final(err) && err.class == .retriable)
	testing.expect(t, !bridge_refresh_apply_rejection("", CS_HUB, "brg_x", "", "", "", err), "a proxy refusal never wipes the pair")
	_, ok, err, _ = bridge_refresh_response_classify(httpc.Response{status = 401, body = transmute([]byte)string(`{"error":{"code":"unauthenticated","message":"invalid_grant"}}`)}, true, CS_HUB)
	testing.expect(t, !ok && bridge_refresh_error_is_final(err), "an older Hub's invalid_grant (message only) is final")
	_, ok, err, _ = bridge_refresh_response_classify(httpc.Response{status = 500, body = transmute([]byte)string(`{"error":{"code":"internal_error","message":"the bridge credential store is temporarily unavailable; retry"}}`)}, true, CS_HUB)
	testing.expect(t, !ok && !bridge_refresh_error_is_final(err) && err.class == .retriable)
}

// S9b: with one exchanger the generation cannot change during an exchange. If it
// does (assertion), the received pair is STILL committed and published, then the
// owner parks: no further exchange, no dial, no HTTP request.
@(test)
cred_generation_mismatch_writes_then_parks :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s9b"); defer cs_teardown(f)
	cs_hub.during = proc() {
		_, _ = bridge_credential_publish({access_token = "hba_rogue.secret", expires_in = 3600}, 0, check_base = false)
	}
	cs_advance(3_300_000, 3_300_000)
	outcome, _ := cs_drive(f)
	cs_hub.during = nil
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Parked)
	phase, reason := bridge_credential_phase()
	testing.expect_value(t, phase, Bridge_Credential_Phase.Parked)
	testing.expect_value(t, reason, "generation_assertion")
	testing.expect_value(t, g_bridge_cred.assertion_failures, 1)
	// Written: the received pair is on disk, with its metadata; the pending record is gone.
	testing.expect_value(t, cs_read(f.credential_file), "hba_g1.secret")
	testing.expect_value(t, cs_read(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "hbf_g1.secret")
	_, meta_ok := bridge_credential_meta_load(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g1.secret")
	testing.expect(t, meta_ok)
	testing.expect(t, !os.exists(f.env.pending_path))
	// Published, then parked: nothing is handed out, dialled or sent.
	testing.expect_value(t, bridge_config.bridge_token, "hba_g1.secret")
	_, _, ok := bridge_credential_acquire(0)
	testing.expect(t, !ok, "a parked owner hands out no credential")
	_, http_err := bridge_hub_http_send_using({}, proc(req: httpc.Request) -> (httpc.Response, httpc.Error) { return {}, .None })
	testing.expect_value(t, http_err, httpc.Error.Aborted)
	testing.expect_value(t, bridge_credential_note_rejection(3, .Access_Expired), Bridge_Credential_Rejection_Action.Not_Renewable)
	// The worker loop exits instead of exchanging again.
	exchanges := cs_hub.exchanges
	bridge_credential_renewal_loop(&f.env)
	testing.expect_value(t, cs_hub.exchanges, exchanges)
}

// S9a: a pair arriving after the epoch changed (re-enrollment) is the ONLY discard;
// the current enrollment's files are untouched.
@(test)
cred_epoch_change_discards_a_late_pair_without_touching_files :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s9a"); defer cs_teardown(f)
	cs_hub.during = proc() { _ = bridge_credential_bump_epoch() }
	cs_advance(3_300_000, 3_300_000)
	outcome, _ := cs_drive(f)
	cs_hub.during = nil
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Stopped)
	testing.expect_value(t, cs_read(f.credential_file), "hba_g0.secret")
	testing.expect_value(t, cs_read(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "hbf_g0.secret")
	testing.expect(t, !os.exists(f.env.pending_path))
	testing.expect_value(t, g_bridge_cred.generation, u64(1))
}

// D5/S6c: a pair the Hub already rotated (pending record from a crash) is committed
// and adopted BEFORE the first dial, with no exchange.
@(test)
cred_pending_pair_is_recovered_before_the_first_dial :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("s6c"); defer cs_teardown(f)
	pending := Bridge_Refresh_Pending{version = 1, key = f.env.key, api_base = CS_HUB, bridge_id = bridge_config.daemon_id, first_ms = CS_T0_WALL,
		credential = {access_token = "hba_pend.secret", refresh_token = "hbf_pend.secret", expires_in = 3600}}
	testing.expect(t, bridge_refresh_pending_save(f.env.pending_path, pending))
	cs_hub.access = "hba_pend.secret" // the Hub rotated before the crash
	cs_hub.access_until = cs_hub.now + 3600_000
	testing.expect(t, bridge_credential_recover_at_start(&f.env), "recovered at start")
	testing.expect_value(t, cs_hub.exchanges, 0)
	testing.expect(t, cs_dial(), "the first dial uses the recovered pair")
	testing.expect_value(t, cs_hub.stale_dials, 0)
	testing.expect_value(t, cs_read(f.credential_file), "hba_pend.secret")
	testing.expect_value(t, cs_read(bridge_enroll_refresh_file_for(f.credential_file, context.temp_allocator)), "hbf_pend.secret")
	testing.expect(t, !os.exists(f.env.pending_path))
}

// A received pair whose local commit fails stays Pending_Commit and retries the
// LOCAL commit with backoff; the spent refresh token is never exchanged again.
@(test)
cred_local_commit_failure_never_reexchanges :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("commit"); defer cs_teardown(f)
	f.env.commit_pair = proc(path, refresh_path, api, bridge_id: string, cred: Bridge_Enroll_Credential) -> bool { return false }
	cs_advance(3_300_000, 3_300_000)
	outcome, _ := cs_drive(f, max_steps = 30)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Wait)
	testing.expect_value(t, cs_hub.exchanges, 1)
	phase, _ := bridge_credential_phase()
	testing.expect_value(t, phase, Bridge_Credential_Phase.Pending_Commit)
	f.env.commit_pair = bridge_refresh_pair_commit
	outcome, _ = cs_drive(f)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Published)
	testing.expect_value(t, cs_hub.exchanges, 1)
	testing.expect_value(t, cs_read(f.credential_file), "hba_g1.secret")
}

// The mandatory early fix: an unknown-token refusal on WS connect (older Hubs send it
// as bridge_credential_revoked "bridge token is invalid"; H2 Hubs as
// bridge_token_invalid) is NOT a permanent park. A real revocation still is.
@(test)
cred_ws_unknown_token_is_not_classified_as_revoked :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("ws"); defer cs_teardown(f)
	sync.atomic_store(&bridge_hub_dial_generation, 1)
	testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_credential_revoked","message":"bridge token is invalid"}}`))
	testing.expect(t, !sync.atomic_load(&bridge_hub_traffic_stopped), "an unknown token does not park")
	testing.expect(t, g_bridge_cred.renewal_requested, "it asks for one renewal")
	testing.expect(t, bridge_hub_is_auth_rejection_frame("bridge_credential_revoked", `{"payload":{"code":"bridge_credential_revoked","message":"bridge token is invalid"}}`))
	testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_token_invalid","message":"bridge token is invalid"}}`))
	testing.expect(t, !sync.atomic_load(&bridge_hub_traffic_stopped))
	testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_token_expired","message":"bridge access token has expired"}}`))
	testing.expect(t, !sync.atomic_load(&bridge_hub_traffic_stopped))
	testing.expect_value(t, cs_hub.exchanges, 0)
	// A real revocation (Forbidden on the Hub) parks as before.
	testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_credential_revoked","message":"bridge credential is revoked"}}`))
	testing.expect(t, sync.atomic_load(&bridge_hub_traffic_stopped) && bridge_hub_traffic_final)
	testing.expect(t, !bridge_hub_is_auth_rejection_frame("bridge_credential_revoked", `{"payload":{"code":"bridge_credential_revoked","message":"bridge credential is revoked"}}`))
	hello := bridge_hub_hello_json()
	defer delete(hello)
	testing.expect(t, strings.contains(hello, `"credential_refresh_on_invalid":true`), "the hello advertises H2")
}

// HTTP callers (D3): a typed expired-access 401 for the CURRENT credential asks for
// one renewal; an older credential or a bare 401 asks for nothing.
cs_http_status: int
cs_http_body: string
cs_http_fetch :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	return hub_test_response(cs_http_status, cs_http_body), .None
}

@(test)
cred_http_expired_401_requests_one_renewal :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("http"); defer cs_teardown(f)
	cs_http_status = 401
	cs_http_body = ""
	resp, _ := bridge_hub_http_send_using({headers = []httpc.Header{httpc.bearer("hba_g0.secret")}}, cs_http_fetch)
	httpc.response_destroy(&resp)
	testing.expect(t, !g_bridge_cred.renewal_requested, "a bare 401 never triggers renewal")
	cs_http_body = `{"error":{"code":"unauthenticated","message":"bridge access token has expired"}}`
	resp, _ = bridge_hub_http_send_using({headers = []httpc.Header{httpc.bearer("hba_old.secret")}}, cs_http_fetch)
	httpc.response_destroy(&resp)
	testing.expect(t, !g_bridge_cred.renewal_requested, "an older credential retries with the current one")
	resp, _ = bridge_hub_http_send_using({headers = []httpc.Header{httpc.bearer("hba_g0.secret")}}, cs_http_fetch)
	httpc.response_destroy(&resp)
	testing.expect(t, g_bridge_cred.renewal_requested, "the current credential's typed expiry renews")
	testing.expect_value(t, g_bridge_cred.rejection_renewal_gen, u64(1))
}

// The expiry-aware acquire is what every HTTP caller gets through
// bridge_credential_snapshot (executor_local_native included): an expired credential
// is renewed before it is handed out; a fresh one is returned at once.
@(test)
cred_snapshot_is_expiry_aware :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("snap"); defer cs_teardown(f)
	fresh := bridge_credential_snapshot()
	testing.expect_value(t, fresh, "hba_g0.secret")
	delete(fresh)
	testing.expect(t, !g_bridge_cred.renewal_requested)
	cs_advance(7_200_000, 0)
	worker := thread.create_and_start_with_poly_data(&f.env, proc(env: ^Bridge_Renewal_Env) {
		context.allocator = runtime.heap_allocator()
		bridge_credential_renewal_loop(env)
	})
	renewed := bridge_credential_snapshot()
	bridge_credential_set_phase(.Renewal_Unavailable, "test_stop")
	thread.join(worker); thread.destroy(worker)
	testing.expect_value(t, renewed, "hba_g1.secret")
	delete(renewed)
	testing.expect_value(t, cs_hub.exchanges, 1)
}

// D4 reauth fencing: a hello on a connection dialled with an OLD generation does
// not clear a newer renewal; the drain sends it once.
@(test)
cred_reauth_is_fenced_by_generation :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("reauth"); defer cs_teardown(f)
	_, _ = bridge_credential_publish({access_token = "hba_g1.secret", expires_in = 3600}, 1)
	// The session was dialled with generation 1 and reached ready after the publish.
	sync.atomic_store(&bridge_hub_session_generation, 1)
	sync.atomic_store(&bridge_hub_reauth_sent_generation, 0)
	testing.expect(t, sync.atomic_load(&bridge_credential_reauth_wanted_generation) > sync.atomic_load(&bridge_hub_session_generation), "the newer generation is still wanted on the session")
	sync.atomic_store(&bridge_hub_credential_reauth_supported, true)
	defer sync.atomic_store(&bridge_hub_credential_reauth_supported, false)
	testing.expect(t, bridge_hub_session_frame("bridge_reauth_result", `{"payload":{"ok":true,"expires_in":3600}}`))
	testing.expect_value(t, sync.atomic_load(&bridge_hub_session_generation), u64(0))
	sync.atomic_store(&bridge_hub_session_generation, 1)
	sync.atomic_store(&bridge_hub_reauth_sent_generation, 2)
	testing.expect(t, bridge_hub_session_frame("bridge_reauth_result", `{"payload":{"ok":true,"expires_in":3600}}`))
	testing.expect_value(t, sync.atomic_load(&bridge_hub_session_generation), u64(2))
}

// D9: metadata is bound to the access token; a mismatch, a foreign hub or a loose
// mode is "unknown" (renew early), never fatal.
@(test)
cred_metadata_is_bound_to_the_access_token :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("meta"); defer cs_teardown(f)
	testing.expect(t, bridge_credential_meta_write(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g0.secret", CS_T0_WALL, 3600, 2_592_000, 1))
	meta, ok := bridge_credential_meta_load(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_g0.secret")
	testing.expect(t, ok && meta.issued_wall_ms == CS_T0_WALL && meta.access_token_id == "g0")
	_, ok = bridge_credential_meta_load(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_other.secret")
	testing.expect(t, !ok, "a replaced access file makes the metadata unknown")
	_, ok = bridge_credential_meta_load(f.credential_file, "https://other.test", bridge_config.daemon_id, "hba_g0.secret")
	testing.expect(t, !ok)
	data, _ := os.read_entire_file(bridge_credential_meta_path(f.credential_file), context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), "secret"), "no token material in metadata")
	// Activation with matching metadata: known age, no immediate renewal.
	bridge_credential_activate(f.credential_file, true)
	needs, _ := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, !needs, "a fresh token with metadata does not rotate at start")
	bridge_credential_meta_remove(f.credential_file)
	bridge_credential_activate(f.credential_file, true)
	needs, _ = bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, needs, "without metadata the age is unknown: renew before the first dial")
	bridge_credential_activate("", false)
	phase, reason := bridge_credential_phase()
	testing.expect(t, phase == .Renewal_Unavailable && reason == "renewal_unavailable")
	token, _, acquired := bridge_credential_acquire(0)
	testing.expect(t, acquired && token == "hba_g0.secret", "an explicit token passes through")
	delete(token)
}

// M1: an unknown token this process CANNOT renew (explicit --bridge-token, no
// refresh file, renewal stopped) parks and marks re-enrollment as before H2,
// instead of redialling a dead credential forever.
@(test)
cred_ws_unknown_token_without_renewal_parks :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	for frame, i in ([]string{
		`{"payload":{"code":"bridge_credential_revoked","message":"bridge token is invalid"}}`,
		`{"payload":{"code":"bridge_token_invalid","message":"bridge token is invalid"}}`,
	}) {
		for phase in ([]Bridge_Credential_Phase{.Renewal_Unavailable, .Renewal_Stopped}) {
			f := cs_setup(fmt.tprintf("m1%d%v", i, phase))
			g_bridge_cred.renewable = phase == .Renewal_Stopped
			g_bridge_cred.phase = phase
			testing.expect(t, bridge_hub_session_frame("bridge_error", frame))
			testing.expectf(t, sync.atomic_load(&bridge_hub_traffic_stopped) && bridge_hub_traffic_final, "frame %d phase %v parks finally", i, phase)
			testing.expect_value(t, cs_hub.exchanges, 0)
			cs_teardown(f)
		}
	}
	// With a config path the park writes the re-enrollment marker.
	f := cs_setup("m1mark"); defer cs_teardown(f)
	g_bridge_cred.renewable = false
	testing.expect(t, os.make_directory_all(f.dir) == nil || os.exists(f.dir))
	bridge_hub_traffic_config_path = fmt.tprintf("%s/config.toml", f.dir)
	testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_token_invalid","message":"bridge token is invalid"}}`))
	marker := fmt.tprintf("%s/needs-reenrollment.json", f.dir)
	testing.expect(t, os.exists(marker), "re-enrollment is marked")
}

// M2: a pending pair recovered long after it was received is aged from its
// persisted receipt time, not from the recovery: after a 2 h gap it is due at once.
@(test)
cred_recovered_pair_keeps_its_receipt_age :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("m2"); defer cs_teardown(f)
	pending := Bridge_Refresh_Pending{version = 1, key = f.env.key, api_base = CS_HUB, bridge_id = bridge_config.daemon_id, first_ms = CS_T0_WALL - 5_000,
		credential = {access_token = "hba_old.secret", refresh_token = "hbf_old.secret", expires_in = 3600, received_wall_ms = CS_T0_WALL}}
	testing.expect(t, bridge_refresh_pending_save(f.env.pending_path, pending))
	// The process restarts two hours later (fresh monotonic clock).
	cs_advance(7_200_000, 0)
	g_bridge_cred.issued_mono_ms = 0
	testing.expect(t, bridge_credential_recover_at_start(&f.env))
	testing.expect_value(t, g_bridge_cred.issued_wall_ms, CS_T0_WALL)
	testing.expect_value(t, g_bridge_cred.issued_mono_ms, i64(0))
	needs, _ := bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, needs, "a recovered pair received 2 h ago is due immediately")
	meta, ok := bridge_credential_meta_load(f.credential_file, CS_HUB, bridge_config.daemon_id, "hba_old.secret")
	testing.expect(t, ok && meta.issued_wall_ms == CS_T0_WALL, "metadata records the receipt time")
	// A record from an older binary (no receipt time) falls back to first_ms.
	f2 := cs_setup("m2old"); defer cs_teardown(f2)
	pending.key = f2.env.key; pending.bridge_id = bridge_config.daemon_id
	pending.credential.received_wall_ms = 0
	testing.expect(t, bridge_refresh_pending_save(f2.env.pending_path, pending))
	cs_advance(7_200_000, 0)
	testing.expect(t, bridge_credential_recover_at_start(&f2.env))
	testing.expect_value(t, g_bridge_cred.issued_wall_ms, CS_T0_WALL - 5_000)
	needs, _ = bridge_credential_evaluate(cs_wall_ms(), cs_mono_ms())
	testing.expect(t, needs)
}

// L5: no acquire wait while a received pair sits in a local-commit backoff.
@(test)
cred_acquire_does_not_wait_during_pending_commit :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("l5"); defer cs_teardown(f)
	cs_advance(7_200_000, 0)
	g_bridge_cred.phase = .Pending_Commit
	started := time.tick_now()
	token, _, ok := bridge_credential_acquire(5_000)
	delete(token)
	testing.expect(t, ok)
	testing.expect(t, time.tick_since(started) < time.Second, "returned without waiting")
}
