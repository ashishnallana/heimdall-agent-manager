package main

import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Test helper: is a (instance, request_id) still pending? Safe under the parallel
// test runner, which shares the global bridge_permission_pending list.
bridge_permission_test_is_pending :: proc(agent_instance_id, request_id: string) -> bool {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for p in bridge_permission_pending {
		if p.request_id == request_id && p.agent_instance_id == agent_instance_id do return true
	}
	return false
}

bridge_permission_test_mutex: sync.Mutex

@(test)
bridge_permission_normalize_decision_maps_canonical :: proc(t: ^testing.T) {
	testing.expect(t, bridge_permission_normalize_decision("allow") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("Approved") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("yes") == "allow")
	testing.expect(t, bridge_permission_normalize_decision("ask") == "ask")
	testing.expect(t, bridge_permission_normalize_decision("deny") == "deny")
	// Unknown / empty fail safe to deny.
	testing.expect(t, bridge_permission_normalize_decision("") == "deny")
	testing.expect(t, bridge_permission_normalize_decision("garbage") == "deny")
}

@(test)
bridge_permission_clamp_timeout_bounds :: proc(t: ^testing.T) {
	testing.expect(t, bridge_permission_clamp_timeout(0) == PERMISSION_DEFAULT_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(-5) == PERMISSION_DEFAULT_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(10) == PERMISSION_MIN_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(9_000_000) == PERMISSION_MAX_TIMEOUT_MS)
	testing.expect(t, bridge_permission_clamp_timeout(5000) == 5000)
}

@(test)
bridge_permission_register_rejects_dupes :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r1", agent_instance_id = "inst_a", tool = "bash", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 1000}
	testing.expect(t, bridge_permission_register(p))
	// Same request_id + instance is rejected.
	testing.expect(t, !bridge_permission_register(p))
	// Empty request_id rejected.
	testing.expect(t, !bridge_permission_register(Bridge_Permission_Pending{request_id = "", agent_instance_id = "inst_a"}))
	bridge_permission_remove("inst_a", "r1")
}

@(test)
bridge_permission_wait_resolves_from_reply :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r2", agent_instance_id = "inst_b", tool = "write", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 5000}
	testing.expect(t, bridge_permission_register(p))

	// A decision that lands before (or during) wait resolves it; the entry persists
	// as decided until wait consumes it, so pre-resolving is a valid deterministic case.
	testing.expect(t, bridge_permission_resolve("inst_b", "r2", "allow", "ok by user"))

	decision, reason := bridge_permission_wait("inst_b", "r2", 3000)
	testing.expect(t, decision == "allow")
	testing.expect(t, reason == "ok by user")
	// Entry consumed.
	testing.expect(t, !bridge_permission_test_is_pending("inst_b", "r2"))
}

@(test)
bridge_permission_wait_times_out_to_deny :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()
	now := bridge_runtime_now_ms()
	p := Bridge_Permission_Pending{request_id = "r3", agent_instance_id = "inst_c", tool = "bash", risk = "risky", created_unix_ms = now, deadline_unix_ms = now + 50}
	testing.expect(t, bridge_permission_register(p))
	decision, reason := bridge_permission_wait("inst_c", "r3", 50)
	testing.expect(t, decision == "deny")
	testing.expect(t, strings.contains(reason, "timed out"))
	testing.expect(t, !bridge_permission_test_is_pending("inst_c", "r3"))
}

@(test)
bridge_permission_request_push_json_shape :: proc(t: ^testing.T) {
	p := Bridge_Permission_Pending{request_id = "r4", agent_instance_id = "inst_d", tool = "edit", risk = "risky"}
	line := bridge_permission_request_push_json(p, "{\"path\":\"a.txt\"}")
	testing.expect(t, strings.contains(line, "\"push\":\"permission_request\""))
	testing.expect(t, strings.contains(line, "\"request_id\":\"r4\""))
	testing.expect(t, strings.contains(line, "\"tool\":\"edit\""))
	testing.expect(t, strings.contains(line, "\"input\":{\"path\":\"a.txt\"}"))
	testing.expect(t, strings.has_suffix(line, "}\n"))
}

@(test)
bridge_permission_reply_push_json_shape :: proc(t: ^testing.T) {
	line := bridge_permission_reply_push_json("inst_e", "r5", "APPROVE", "looks good")
	testing.expect(t, strings.contains(line, "\"push\":\"permission_reply\""))
	testing.expect(t, strings.contains(line, "\"request_id\":\"r5\""))
	// Decision normalized to canonical allow.
	testing.expect(t, strings.contains(line, "\"decision\":\"allow\""))
	testing.expect(t, strings.contains(line, "\"reason\":\"looks good\""))
}

// ---- End-to-end handler roundtrip tests ----

Perm_Integ_Result :: struct {
	response: string,
	done: bool,
	mu: sync.Mutex,
}

@(test)
bridge_permission_request_reply_roundtrip_via_handler :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_integ", role = .Agent}

	shared := new(Perm_Integ_Result)
	defer free(shared)

	Ctx :: struct { rec: Bridge_Local_Agent_Token_Record, shared: ^Perm_Integ_Result }
	c := new(Ctx)
	defer free(c)
	c.rec = rec
	c.shared = shared

	worker_thread := thread.create_and_start_with_data(rawptr(c), proc(data: rawptr) {
		cc := (^Ctx)(data)
		params := "{\"request_id\":\"rq_integ_roundtrip\",\"tool\":\"bash\",\"risk\":\"risky\",\"input\":{\"cmd\":\"rm -rf x\"},\"timeout_ms\":5000}"
		resp := bridge_local_handle_agent_method("id-req", "agent.permission.request", params, cc.rec)
		sync.mutex_lock(&cc.shared.mu)
		cc.shared.response = strings.clone(resp)
		cc.shared.done = true
		sync.mutex_unlock(&cc.shared.mu)
	})

	registered := false
	for _ in 0..<200 {
		if bridge_permission_test_is_pending("inst_integ", "rq_integ_roundtrip") { registered = true; break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, registered)

	reply_params := "{\"request_id\":\"rq_integ_roundtrip\",\"decision\":\"allow\",\"reason\":\"approved in test\"}"
	reply_resp := bridge_local_handle_agent_method("id-reply", "agent.permission.reply", reply_params, rec)
	testing.expect(t, strings.contains(reply_resp, "\"accepted\":true"))

	got := false
	response := ""
	for _ in 0..<400 {
		sync.mutex_lock(&shared.mu)
		if shared.done { response = shared.response; got = true }
		sync.mutex_unlock(&shared.mu)
		if got do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, got)
	testing.expect(t, strings.contains(response, "\"decision\":\"allow\""))
	testing.expect(t, strings.contains(response, "\"reason\":\"approved in test\""))
	testing.expect(t, strings.contains(response, "\"request_id\":\"rq_integ_roundtrip\""))

	thread.join(worker_thread)
	thread.destroy(worker_thread)
}

@(test)
bridge_permission_reply_unknown_request_not_accepted :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_integ2", role = .Agent}
	resp := bridge_local_handle_agent_method("id-x", "agent.permission.reply", "{\"request_id\":\"nope\",\"decision\":\"allow\"}", rec)
	testing.expect(t, strings.contains(resp, "\"accepted\":false"))
}
