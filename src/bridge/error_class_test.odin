package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-ERR-1: every code has a default class (the table is an exhaustive
// enumerated array, so this also guards against a code losing its entry).
@(test)
test_error_class_defaults_cover_every_code :: proc(t: ^testing.T) {
	defaults := contracts.BRIDGE_LOG_CODE_DEFAULT_CLASS
	counts: [contracts.Bridge_Error_Class]int
	for class in defaults do counts[class] += 1
	testing.expect_value(t, counts[.retriable] + counts[.recoverable] + counts[.fatal], len(contracts.Bridge_Log_Code))
	testing.expect_value(t, defaults[.provider_missing], contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, defaults[.hub_ws_closed], contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, defaults[.internal], contracts.Bridge_Error_Class.fatal)
}

@(test)
test_error_classify_precedence :: proc(t: ^testing.T) {
	// Hub HTTP status beats the default and the reason.
	testing.expect_value(t, contracts.bridge_error_classify(.hub_rejected, .other, 503), contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, contracts.bridge_error_classify(.hub_rejected, .other, 429), contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, contracts.bridge_error_classify(.hub_rejected, .other, 401), contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, contracts.bridge_error_classify(.hub_rejected, .other, 409), contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, contracts.bridge_error_classify(.hub_rejected, .other, 404), contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, contracts.bridge_error_classify(.agent_bootstrap_invalid, .timeout, 400), contracts.Bridge_Error_Class.fatal)
	// Reason refines the default.
	testing.expect_value(t, contracts.bridge_error_classify(.agent_launch_failed), contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, contracts.bridge_error_classify(.agent_launch_failed, .missing_binary), contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, contracts.bridge_error_classify(.agent_launch_failed, .unsupported), contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, contracts.bridge_error_classify(.agent_bootstrap_invalid, .transport), contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, contracts.bridge_error_classify(.enroll_failed, .denied), contracts.Bridge_Error_Class.recoverable)
	// A fatal default is final: no reason or status softens it.
	testing.expect_value(t, contracts.bridge_error_classify(.update_apply_failed, .missing_binary), contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, contracts.bridge_error_classify(.internal, .timeout, 503), contracts.Bridge_Error_Class.fatal)
}

// REQ-ERR-3: shared backoff math.
@(test)
test_backoff_delay_doubles_caps_and_jitters_within_bounds :: proc(t: ^testing.T) {
	exact := Bridge_Backoff_Policy{base_ms = 1_000, max_ms = 8_000}
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 0), i64(0))
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 1), i64(1_000))
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 2), i64(2_000))
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 4), i64(8_000))
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 5), i64(8_000))
	testing.expect_value(t, bridge_backoff_delay_ms(exact, 10_000), i64(8_000)) // no overflow on huge counts
	uncapped := Bridge_Backoff_Policy{base_ms = 150}
	testing.expect_value(t, bridge_backoff_delay_ms(uncapped, 4), i64(1_200))

	jittered := Bridge_Backoff_Policy{base_ms = 10_000, max_ms = 60_000, jitter_pct = 20}
	for seed in u64(0)..<200 {
		d := bridge_backoff_delay_ms(jittered, 1, seed * 7919)
		testing.expectf(t, d >= 8_000 && d <= 12_000, "seed %d: %d outside +-20%%", seed, d)
	}
	testing.expect(t, bridge_backoff_delay_ms(jittered, 1, 0) != bridge_backoff_delay_ms(jittered, 1, 1_000), "jitter varies with the seed")

	// retry_after is a floor, never shortened by the policy.
	err := bridge_error(.hub_rejected, .other, 503, 90_000)
	testing.expect_value(t, bridge_backoff_next_at_ms(exact, 1, 1_000, err), i64(91_000))
}

// The credential refresh keeps its exact pre-refactor schedule.
@(test)
test_refresh_backoff_schedule_unchanged :: proc(t: ^testing.T) {
	want := [?]int{5, 10, 20, 40, 80, 160, 300, 300}
	for w, i in want do testing.expect_value(t, bridge_refresh_backoff_seconds(i + 1), w)
}

@(test)
test_http_is_retriable_matches_http_class :: proc(t: ^testing.T) {
	testing.expect(t, bridge_http_is_retriable(0, false), "transport")
	testing.expect(t, bridge_http_is_retriable(503, true), "5xx")
	testing.expect(t, bridge_http_is_retriable(429, true), "429")
	testing.expect(t, !bridge_http_is_retriable(200, true), "2xx")
	testing.expect(t, !bridge_http_is_retriable(304, true), "3xx")
	testing.expect(t, !bridge_http_is_retriable(401, true), "401")
	testing.expect(t, !bridge_http_is_retriable(409, true), "409")
}

// REQ-ERR-4: wake gate + transitions.
@(test)
test_wake_gate_coalesces_backs_off_and_parks :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_wake_gate({}, false, 1_000_000), Bridge_Wake_Decision.Wake)
	st := Bridge_Wake_State{last_wake_ms = 1_000_000}
	testing.expect_value(t, bridge_wake_gate(st, true, 1_000_000 + BRIDGE_WAKE_COALESCE_MS - 1), Bridge_Wake_Decision.Coalesced)
	testing.expect_value(t, bridge_wake_gate(st, true, 1_000_000 + BRIDGE_WAKE_COALESCE_MS), Bridge_Wake_Decision.Wake)
	st.next_at_ms = 1_000_000 + 120_000
	testing.expect_value(t, bridge_wake_gate(st, true, 1_000_000 + 60_000), Bridge_Wake_Decision.Backing_Off)
	testing.expect_value(t, bridge_wake_gate(st, true, 1_000_000 + 120_000), Bridge_Wake_Decision.Wake)
	parked := Bridge_Wake_State{parked = true}
	testing.expect_value(t, bridge_wake_gate(parked, true, 999_999_999), Bridge_Wake_Decision.Parked)
	testing.expect_value(t, bridge_wake_gate(parked, true, 999_999_999, true), Bridge_Wake_Decision.Wake)
}

@(test)
test_wake_record_backoff_grows_then_resets_on_success :: proc(t: ^testing.T) {
	st: Bridge_Wake_State
	transient := bridge_error(.pty_host_unreachable)
	now := i64(10_000_000)
	testing.expect_value(t, bridge_wake_record(&st, false, transient, now, 0), Bridge_Wake_Transition.Backoff)
	first := st.next_at_ms - now
	testing.expect(t, first >= 48_000 && first <= 72_000, "first retry ~60s +-20%")
	testing.expect_value(t, bridge_wake_record(&st, false, transient, now, 0), Bridge_Wake_Transition.Backoff)
	testing.expect(t, st.next_at_ms - now > first, "second retry waits longer")
	for _ in 0..<20 do bridge_wake_record(&st, false, transient, now, 0)
	testing.expect(t, st.next_at_ms - now <= BRIDGE_WAKE_BACKOFF.max_ms * 12 / 10, "capped at 30m +-20%")
	testing.expect(t, !st.parked, "retriable never parks")
	testing.expect_value(t, bridge_wake_record(&st, true, {}, now, 0), Bridge_Wake_Transition.Recovered)
	testing.expect_value(t, st.failures, 0)
	testing.expect_value(t, st.next_at_ms, i64(0))
	testing.expect_value(t, bridge_wake_record(&st, true, {}, now, 0), Bridge_Wake_Transition.None)
}

@(test)
test_wake_record_parks_recoverable_and_fatal_once :: proc(t: ^testing.T) {
	st: Bridge_Wake_State
	missing := bridge_error(.provider_missing)
	testing.expect_value(t, missing.class, contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, bridge_wake_record(&st, false, missing, 1_000, 0), Bridge_Wake_Transition.Parked)
	testing.expect(t, st.parked, "parked")
	testing.expect_value(t, bridge_wake_gate(st, true, 1_000 + 24 * 3_600_000), Bridge_Wake_Decision.Parked)
	// A repeat failure while parked (an unpark attempt that failed) logs nothing new.
	testing.expect_value(t, bridge_wake_record(&st, false, missing, 2_000, 0), Bridge_Wake_Transition.None)
	testing.expect_value(t, bridge_wake_record(&st, true, {}, 3_000, 0), Bridge_Wake_Transition.Recovered)
	testing.expect(t, !st.parked, "a successful launch unparks")

	bad := bridge_error(.agent_launch_failed, .unsupported)
	testing.expect_value(t, bad.class, contracts.Bridge_Error_Class.fatal)
	st = {}
	testing.expect_value(t, bridge_wake_record(&st, false, bad, 1_000, 0), Bridge_Wake_Transition.Parked)
	// Fatal never unparks on a trigger: only a successful launch elsewhere resets it.
	testing.expect_value(t, bridge_wake_unpark_trigger(&st, 1_000 + BRIDGE_WAKE_PARK_PROBE_MS), "")
}

// Launch-path classification (REQ-ERR-2).
@(test)
test_bootstrap_result_error_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "manifest_get"}).class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "blob_fetch", http_status = 502}).class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "manifest_get", http_status = 409}).class, contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "manifest_get", http_status = 404}).class, contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "validate"}).class, contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, bridge_bootstrap_result_error({stage = "assemble"}).class, contracts.Bridge_Error_Class.recoverable)
}

// The wake-race tests share the global scheduler state; serialize them.
@(private = "file")
wake_global_state_mu: sync.Mutex

// NGTM regression: a launch that succeeds while a scheduler wake is in flight
// invalidates that wake; the wake's later failure must not park or back off.
@(test)
test_wake_stale_failure_after_successful_launch_is_dropped :: proc(t: ^testing.T) {
	sync.mutex_lock(&wake_global_state_mu)
	defer sync.mutex_unlock(&wake_global_state_mu)
	bridge_task_scheduler_reset()
	defer bridge_task_scheduler_reset()
	id := "inst_wake_race"
	bridge_agent_wake[id] = Bridge_Wake_State{last_wake_ms = 1_000}
	in_flight_generation := bridge_agent_wake[id].generation

	bridge_task_wake_note_launched(id, 1_500) // launch B succeeds first
	bridge_task_wake_record_result(id, in_flight_generation, false, "late failure", bridge_error(.provider_missing), "", 2_000)
	st := bridge_agent_wake[id]
	testing.expect(t, !st.parked, "stale failure must not park")
	testing.expect_value(t, st.failures, 0)
	testing.expect_value(t, st.next_at_ms, i64(0))

	// A result from the CURRENT generation still applies.
	bridge_task_wake_record_result(id, st.generation, false, "current failure", bridge_error(.pty_host_unreachable), "", 3_000)
	testing.expect_value(t, bridge_agent_wake[id].failures, 1)
}

// NGTM regression 2: the success lands BEFORE the wake registers (no entry yet;
// the wake read a stale "not active" snapshot). The success must create the
// entry and coalesce the late wake, and a result from the pre-success
// generation must be dropped.
@(test)
test_wake_success_before_registration_coalesces_and_invalidates :: proc(t: ^testing.T) {
	sync.mutex_lock(&wake_global_state_mu)
	defer sync.mutex_unlock(&wake_global_state_mu)
	bridge_task_scheduler_reset()
	defer bridge_task_scheduler_reset()
	id := "inst_wake_race_noentry"
	testing.expect(t, id not_in bridge_agent_wake, "no wake entry yet")

	bridge_task_wake_note_launched(id, 50_000)
	st, has := bridge_agent_wake[id]
	testing.expect(t, has, "a successful launch creates the wake entry")
	testing.expect(t, st.generation > 0, "generation advanced")
	testing.expect_value(t, bridge_wake_gate(st, has, 50_000 + 1_000), Bridge_Wake_Decision.Coalesced)

	bridge_task_wake_record_result(id, 0, false, "stale failure", bridge_error(.provider_missing), "", 51_000)
	testing.expect(t, !bridge_agent_wake[id].parked, "a pre-success generation never parks")
	testing.expect_value(t, bridge_agent_wake[id].failures, 0)
}

// NGTM regression 3: a launch can record itself before the scheduler thread
// starts. Init is once-only and idempotent: calling it again (as
// bridge_task_scheduler_start does) must keep what the early launch recorded.
@(test)
test_wake_note_before_scheduler_start_survives_init :: proc(t: ^testing.T) {
	sync.mutex_lock(&wake_global_state_mu)
	defer sync.mutex_unlock(&wake_global_state_mu)
	bridge_task_scheduler_reset()
	defer bridge_task_scheduler_reset()
	id := "inst_wake_early_launch"
	bridge_task_wake_note_launched(id, 7_000) // hub worker launch, scheduler not started yet
	generation := bridge_agent_wake[id].generation
	bridge_task_scheduler_init() // what bridge_task_scheduler_start does
	st, has := bridge_agent_wake[id]
	testing.expect(t, has, "early launch record survives scheduler start")
	testing.expect_value(t, st.generation, generation)
	testing.expect_value(t, st.last_wake_ms, i64(7_000))
}

@(test)
test_error_classify_unknown_code :: proc(t: ^testing.T) {
	testing.expect_value(t, contracts.bridge_error_classify_unknown(), contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, contracts.bridge_error_classify_unknown(.transport), contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, contracts.bridge_error_classify_unknown(.login_required), contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, contracts.bridge_error_classify_unknown(.other, 503), contracts.Bridge_Error_Class.retriable)
}

// ---- REQ-ERR-PROTO-A: every reply failure is the typed wire error ---------------

@(test)
test_err_proto_cause_maps_to_contract_code :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_cause_error_code("vault_locked"), contracts.Error_Code.Vault_Locked)
	testing.expect_value(t, bridge_cause_error_code("path_not_found"), contracts.Error_Code.Not_Found)
	testing.expect_value(t, bridge_cause_error_code("path_outside_root"), contracts.Error_Code.Forbidden)
	testing.expect_value(t, bridge_cause_error_code("session_not_running"), contracts.Error_Code.Conflict)
	testing.expect_value(t, bridge_cause_error_code("output_reclaimed"), contracts.Error_Code.Gone)
	testing.expect_value(t, bridge_cause_error_code("bridge_busy"), contracts.Error_Code.Bridge_Busy)
	testing.expect_value(t, bridge_cause_error_code("commit_failed"), contracts.Error_Code.Unprocessable_Entity)
	testing.expect_value(t, bridge_cause_error_code("something_new"), contracts.Error_Code.Internal_Error)
	testing.expect_value(t, bridge_cause_error_code(""), contracts.Error_Code.None)
	empty := bridge_result_error("", "")
	testing.expect_value(t, empty.code, "")
	fs := bridge_result_error("path_not_found", "Path does not exist")
	testing.expect_value(t, fs.code, "not_found")
	testing.expect_value(t, fs.class, "fatal")
	testing.expect_value(t, fs.cause, "path_not_found")
}

@(test)
test_err_proto_command_failed_json_is_typed :: proc(t: ^testing.T) {
	busy := bridge_command_dispatch_busy_json("cmd_busy", "agent", 2500)
	defer delete(busy)
	werr, found := contracts.wire_error_parse(busy, context.temp_allocator)
	testing.expect(t, found, busy)
	testing.expect_value(t, werr.code, contracts.Error_Code.Bridge_Busy)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, werr.retry_after_ms, i64(2500))
	testing.expect_value(t, werr.scope, "agent")

	deadline := bridge_command_dispatch_deadline_json("cmd_dl")
	defer delete(deadline)
	werr, _ = contracts.wire_error_parse(deadline, context.temp_allocator)
	testing.expect_value(t, werr.code, contracts.Error_Code.Bridge_Timeout)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.fatal)

	// A launch failure keeps the classifier's class, not the code's table default.
	launch := bridge_command_failed_json("cmd_launch", bridge_error_wire(bridge_error(.provider_not_logged_in), "claude: login required"), "failed")
	defer delete(launch)
	werr, _ = contracts.wire_error_parse(launch, context.temp_allocator)
	testing.expect_value(t, werr.code, contracts.Error_Code.Provider_Unavailable)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, werr.cause, "provider_not_logged_in")
	testing.expect(t, strings.contains(launch, `"payload":{"status":"failed","result":{"runtime_status":"failed"}}`), launch)

	ok := bridge_command_result_json("cmd_ok", "succeeded", "")
	defer delete(ok)
	_, found = contracts.wire_error_parse(ok, context.temp_allocator)
	testing.expect(t, !found, "success carries no error")
	testing.expect(t, strings.contains(ok, `"ok":true`), ok)
}

@(test)
test_err_proto_failed_instance_status_carries_last_error :: proc(t: ^testing.T) {
	id := "inst_err_proto_status"
	bridge_runtime_set_status(id, "failed", "idle")
	bridge_runtime_record_failure(id, bridge_error(.pty_host_unreachable))
	failed := bridge_instance_status_json(id)
	defer delete(failed)
	werr, found := contracts.wire_error_parse(failed, context.temp_allocator)
	testing.expect(t, found, failed)
	testing.expect_value(t, werr.cause, "pty_host_unreachable")
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.retriable)

	// Any other status clears it, and a failure is only recorded on a failed instance.
	bridge_runtime_set_status(id, "starting", "active")
	bridge_runtime_record_failure(id, bridge_error(.provider_missing))
	starting := bridge_instance_status_json(id)
	defer delete(starting)
	_, found = contracts.wire_error_parse(starting, context.temp_allocator)
	testing.expect(t, !found, starting)
}

// REQ-ERR-PROTO-A: a parked recoverable wake resumes on its trigger: unsealing the
// vault for vault_locked, a slow re-check for causes with no local signal.
@(test)
test_wake_unpark_triggers_for_recoverable_causes :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is process-wide: hold the same locks as every other vault test
	// (config, then keystore) so a concurrent vault-status test never sees it mid-change.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			os.set_env("HEIMDALL_VAULT_KEY", prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
		delete(prev_key)
	}

	locked: Bridge_Wake_State
	locked.parked = true
	locked.err = bridge_error(.vault_locked)
	testing.expect_value(t, locked.err.class, contracts.Bridge_Error_Class.recoverable)
	locked.catalog_etag = bridge_provider_catalog_current_etag()
	defer delete(locked.catalog_etag)
	os.set_env("HEIMDALL_VAULT_KEY", "not-a-valid-key") // set but invalid: locked, no fallthrough
	testing.expect_value(t, bridge_wake_unpark_trigger(&locked, BRIDGE_WAKE_PARK_PROBE_MS), "")
	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	testing.expect_value(t, bridge_wake_unpark_trigger(&locked, BRIDGE_WAKE_PARK_PROBE_MS), "") // probed this tick already
	testing.expect_value(t, bridge_wake_unpark_trigger(&locked, 2 * BRIDGE_WAKE_PARK_PROBE_MS), "vault_unsealed")

	refused: Bridge_Wake_State
	refused.parked = true
	refused.err = bridge_bootstrap_result_error({stage = "manifest_get", http_status = 409})
	testing.expect_value(t, refused.err.class, contracts.Bridge_Error_Class.recoverable)
	refused.catalog_etag = bridge_provider_catalog_current_etag()
	defer delete(refused.catalog_etag)
	refused.last_wake_ms = 1_000
	testing.expect_value(t, bridge_wake_unpark_trigger(&refused, 1_000 + BRIDGE_WAKE_BACKOFF.max_ms - 1), "")
	testing.expect_value(t, bridge_wake_unpark_trigger(&refused, 1_000 + BRIDGE_WAKE_BACKOFF.max_ms), "periodic_recheck")
}

// REQ-ERR-PROTO-A: a stop that fails (here: the pty-host daemon is unreachable, as the
// real stop reports it) never leaves the instance "stopping". With no pre-stop
// snapshot (an empty registry after a bridge restart) it becomes "unreachable" for
// the liveness reconciler to settle; with one, the prior status is put back. The
// failed command_result names the status for the hub either way.
@(test)
test_err_proto_failed_stop_never_stays_stopping :: proc(t: ^testing.T) {
	// The real stop's prelude (intent + "stopping"), then a transport failure.
	failing_stop :: proc(instance_id: string, force: bool) -> bool {
		bridge_runtime_mark_stop_intent(instance_id)
		bridge_runtime_set_status(instance_id, "stopping", "idle")
		return false
	}

	no_snapshot := "inst_err_proto_stop_cold"
	ok, restored := bridge_runtime_stop_or_restore(no_snapshot, false, failing_stop)
	defer delete(restored)
	testing.expect(t, !ok)
	testing.expect_value(t, restored, "unreachable")
	status, _, found := bridge_runtime_status_snapshot(no_snapshot)
	defer delete(status)
	testing.expect(t, found)
	testing.expect_value(t, status, "unreachable")
	result := bridge_command_failed_json("cmd_stop_1_inst_err_proto_stop_cold", bridge_cause_wire_error("stop_failed", "the agent did not stop"), restored)
	defer delete(result)
	testing.expect(t, strings.contains(result, `"runtime_status":"unreachable"`), result)

	warm := "inst_err_proto_stop_warm"
	bridge_runtime_set_status(warm, "running", "busy")
	ok2, restored2 := bridge_runtime_stop_or_restore(warm, false, failing_stop)
	defer delete(restored2)
	testing.expect(t, !ok2)
	testing.expect_value(t, restored2, "running")
	status2, activity2, _ := bridge_runtime_status_snapshot(warm)
	defer { delete(status2); delete(activity2) }
	testing.expect_value(t, status2, "running")
	testing.expect_value(t, activity2, "busy")
}
