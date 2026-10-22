package agent

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// ---- acting on a failed instance's error class (REQ-ERR-PROTO-A) ------------
//
// A failed launch/wake carries the bridge's typed error (instance.last_error_json).
// The hub obeys its class instead of re-waking blindly:
//   retriable   -> re-wake with exponential backoff: 60s * 2^(attempt-1), capped at
//                  30m, never sooner than the bridge's retry_after_ms.
//   recoverable -> hold: no re-wake and no replacement instance. The cause needs an
//                  outside fix (login, unseal, config); the bridge's own scheduler
//                  unparks it on that event, or the user relaunches it.
//   fatal       -> hold as well: the same launch would fail the same way, so neither
//                  a re-wake nor a replacement is attempted until the user acts.
// A failure with no typed error (a crash) is dead and replaceable, as before.

INSTANCE_RETRY_BASE_MS :: 60_000
INSTANCE_RETRY_MAX_MS :: 1_800_000

Failed_Instance_Disposition :: enum {
	Not_Failed, // not failed: normal handling
	Retry_Now,  // retriable and its backoff has elapsed: may be woken again
	Hold,       // backing off, recoverable or fatal: neither wake nor replace
	Dead,       // untyped failure or terminated: replace as before
}

failed_instance_disposition :: proc(inst: domain.Agent_Instance, now_ms: i64) -> Failed_Instance_Disposition {
	if inst.runtime_status == "terminated" do return .Dead
	if inst.runtime_status != "failed" do return .Not_Failed
	werr, found := instance_last_error(inst)
	if !found do return .Dead
	switch werr.class {
	case .fatal, .recoverable:
		return .Hold
	case .retriable:
		failed_ms, ok := platform.rfc3339_to_unix_ms(inst.stopped_at)
		if !ok do return .Retry_Now
		if now_ms >= failed_ms + instance_retry_delay_ms(instance_last_error_attempt(inst), werr.retry_after_ms) do return .Retry_Now
		return .Hold
	}
	return .Dead
}

// instance_retry_delay_ms is the wait before re-waking after failure number attempt.
instance_retry_delay_ms :: proc(attempt: int, retry_after_ms: i64 = 0) -> i64 {
	delay := i64(INSTANCE_RETRY_BASE_MS)
	for _ in 1..<max(attempt, 1) {
		if delay >= INSTANCE_RETRY_MAX_MS do break
		delay *= 2
	}
	delay = min(delay, INSTANCE_RETRY_MAX_MS)
	return max(delay, retry_after_ms)
}

instance_last_error :: proc(inst: domain.Agent_Instance) -> (contracts.Wire_Error, bool) {
	if inst.last_error_json == "" do return {}, false
	return contracts.wire_error_parse(strings.concatenate({"{\"error\":", inst.last_error_json, "}"}, context.temp_allocator), context.temp_allocator)
}

instance_last_error_attempt :: proc(inst: domain.Agent_Instance) -> int {
	if inst.last_error_json == "" do return 0
	return jsonx.extract_int(inst.last_error_json, "attempt", 1, true)
}

// instance_last_error_record is the stored last_error for a new failed report:
// the bridge's error object plus a consecutive-failure "attempt" count, which only
// a successful start (or a deliberate stop) resets. Caller owns the result.
instance_last_error_record :: proc(prev_last_error_json, error_json: string) -> string {
	werr, found := contracts.wire_error_parse(strings.concatenate({"{\"error\":", error_json, "}"}, context.temp_allocator), context.temp_allocator)
	if !found do return strings.clone("")
	attempt := 1
	if prev_last_error_json != "" do attempt = jsonx.extract_int(prev_last_error_json, "attempt", 1, true) + 1
	obj := contracts.wire_error_json(werr, context.temp_allocator)
	return fmt.aprintf("%s,\"attempt\":%d}", obj[:len(obj) - 1], attempt)
}

// apply_stop_command_result handles a failed stop_agent result. stop_instance marks
// the instance "stopping" once the command is sent; if the bridge then reports that
// the stop did not happen, the instance must not stay "stopping" forever. The
// bridge names the status it put back (result.runtime_status); the bridge's own
// status frame normally lands first, so this only matters when the hub's save of
// "stopping" raced past it.
// When out is non-nil the saved row is handed to the caller (who destroys it)
// so it can announce the restored status (REQ-2).
apply_stop_command_result :: proc(service: ^Agent_Service, bridge_id, command_id, result: string, out: ^domain.Agent_Instance = nil) -> bool {
	if !strings.has_prefix(command_id, "cmd_stop_") do return false
	if jsonx.extract_bool(result, "ok", fallback = true, top_level_only = true) do return false
	at := strings.index(command_id, "_inst_")
	if at < 0 do return false
	instance_id := command_id[at + 1:]
	restored := jsonx.extract_string(result, "runtime_status", "", false, context.temp_allocator)
	if restored == "" || restored == "stopping" do return false
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return false
	if inst.bridge_id != bridge_id || inst.runtime_status != "stopping" {
		domain.agent_instance_destroy(&inst)
		return false
	}
	delete(inst.runtime_status)
	inst.runtime_status = strings.clone(restored)
	if len(inst.updated_at) > 0 do delete(inst.updated_at)
	inst.updated_at = strings.clone(platform.clock_now(service.clock))
	// The saved revision shares inst's strings: free exactly one of them.
	saved, saved_ok, _ := iface.agent_save_instance(service.agents, inst)
	if saved_ok {
		if out != nil do out^ = saved
		else do domain.agent_instance_destroy(&saved)
	} else {
		domain.agent_instance_destroy(&inst)
	}
	return saved_ok
}
