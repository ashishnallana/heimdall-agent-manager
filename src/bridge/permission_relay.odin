package main

// Canonical permission-relay contract (Task 1: wrapper core + bridge contract).
//
// This is the second half of the normalized bridge contract that per-provider
// adapters (Pi, Antigravity, ...) build on. The first half — agent_activity —
// is already implemented via agent.activity.report + bridge_runtime_note_agent_activity.
//
// Contract:
//   upstream   (adapter -> bridge): agent.permission.request
//                {request_id, tool, input, risk, summary}
//   downstream (bridge  -> adapter): {"push":"permission_reply","payload":
//                {request_id, decision:"allow"|"deny"|"ask", reason}}
//
// The bridge holds each request in a pending registry and BLOCKS the calling
// adapter (the tool_call handler in Pi) until a permission_reply arrives on the
// wrapper notifications channel, or the request times out (fail-safe: deny).
//
// The reply is delivered locally via agent.permission.reply (so a local UI /
// wrapper can answer) and can also be injected by the hub through the wrapper
// push channel. Either path resolves the same pending entry by request_id.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"

PERMISSION_DEFAULT_TIMEOUT_MS :: 120000
PERMISSION_MAX_TIMEOUT_MS :: 600000
PERMISSION_MIN_TIMEOUT_MS :: 1000

Bridge_Permission_Pending :: struct {
	request_id: string,
	agent_instance_id: string,
	tool: string,
	risk: string,
	// Resolution
	decided: bool,
	decision: string, // allow | deny | ask
	reason: string,
	created_unix_ms: i64,
	deadline_unix_ms: i64,
}

bridge_permission_mutex: sync.Mutex
bridge_permission_pending: [dynamic]Bridge_Permission_Pending

// Normalize a decision string to the canonical set, defaulting unknown/empty to "deny".
// "none" is kept (no decision); legacy callers map it to their own fail-safe.
bridge_permission_normalize_decision :: proc(value: string) -> string {
	switch strings.to_lower(strings.trim_space(value), context.temp_allocator) {
	case "allow", "allowed", "approve", "approved", "yes", "ok": return "allow"
	case "ask", "prompt", "defer": return "ask"
	// "none": no decision was made (relay timed out or was cancelled). The
	// extension path hands this back so the provider shows its own TUI prompt.
	case "none", "cancel", "cancelled", "expired": return "none"
	case: return "deny"
	}
}

bridge_permission_clamp_timeout :: proc(value_ms: int) -> int {
	out := value_ms
	if out <= 0 do out = PERMISSION_DEFAULT_TIMEOUT_MS
	if out < PERMISSION_MIN_TIMEOUT_MS do out = PERMISSION_MIN_TIMEOUT_MS
	if out > PERMISSION_MAX_TIMEOUT_MS do out = PERMISSION_MAX_TIMEOUT_MS
	return out
}

// Register a pending request. Returns false if request_id is empty or already active.
bridge_permission_register :: proc(pending: Bridge_Permission_Pending) -> bool {
	if strings.trim_space(pending.request_id) == "" do return false
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	if bridge_permission_pending == nil do bridge_permission_pending = make([dynamic]Bridge_Permission_Pending, runtime.default_allocator())
	for i in 0..<len(bridge_permission_pending) {
		if bridge_permission_pending[i].request_id == pending.request_id && bridge_permission_pending[i].agent_instance_id == pending.agent_instance_id {
			return false
		}
	}
	append(&bridge_permission_pending, pending)
	return true
}

// Reset / clear pending permission requests under lock (for tests).
bridge_permission_test_reset :: proc() {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	clear(&bridge_permission_pending)
}

// Resolve a pending request by (request_id, instance). Returns true if a match was found.
bridge_permission_resolve :: proc(agent_instance_id, request_id, decision, reason: string) -> bool {
	if strings.trim_space(request_id) == "" do return false
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for i in 0..<len(bridge_permission_pending) {
		p := &bridge_permission_pending[i]
		if p.request_id != request_id do continue
		if agent_instance_id != "" && p.agent_instance_id != agent_instance_id do continue
		if p.decided do return true
		p.decided = true
		p.decision = bridge_permission_normalize_decision(decision)
		p.reason = strings.clone(reason)
		return true
	}
	return false
}

// Wait (blocking) for a pending request to be resolved or to time out.
// On timeout the fail-safe decision is "deny". Removes the entry before returning.
bridge_permission_wait :: proc(agent_instance_id, request_id: string, timeout_ms: int) -> (string, string) {
	decision, reason, _ := bridge_permission_wait_ex(agent_instance_id, request_id, timeout_ms, "deny", nil)
	return decision, reason
}

// Bridge_Permission_Cancelled_Proc reports whether a waiter should give up early
// (e.g. its instance stopped). Polled about every 250ms.
Bridge_Permission_Cancelled_Proc :: proc(agent_instance_id: string) -> bool

// bridge_permission_wait_ex is bridge_permission_wait with the timeout outcome
// chosen by the caller (timeout_decision) and an optional cancellation probe.
// timed_out is true only when the deadline passed with no decision.
bridge_permission_wait_ex :: proc(agent_instance_id, request_id: string, timeout_ms: int, timeout_decision: string, cancelled: Bridge_Permission_Cancelled_Proc) -> (decision: string, reason: string, timed_out: bool) {
	deadline := bridge_runtime_now_ms() + i64(timeout_ms)
	polls := 0
	for bridge_runtime_now_ms() < deadline {
		polls += 1
		if cancelled != nil && polls % 25 == 0 && cancelled(agent_instance_id) {
			bridge_permission_remove(agent_instance_id, request_id)
			return "none", "permission request cancelled", false
		}
		sync.mutex_lock(&bridge_permission_mutex)
		for i in 0..<len(bridge_permission_pending) {
			p := bridge_permission_pending[i]
			if p.request_id != request_id do continue
			if agent_instance_id != "" && p.agent_instance_id != agent_instance_id do continue
			if p.decided {
				unordered_remove(&bridge_permission_pending, i)
				sync.mutex_unlock(&bridge_permission_mutex)
				return p.decision, p.reason, false
			}
			break
		}
		sync.mutex_unlock(&bridge_permission_mutex)
		time.sleep(10 * time.Millisecond)
	}
	// Timed out: remove and return the caller's timeout outcome. A decision that
	// landed between the last poll and the removal still wins.
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for i in 0..<len(bridge_permission_pending) {
		p := bridge_permission_pending[i]
		if p.request_id != request_id do continue
		if agent_instance_id != "" && p.agent_instance_id != agent_instance_id do continue
		unordered_remove(&bridge_permission_pending, i)
		if p.decided do return p.decision, p.reason, false
		break
	}
	return timeout_decision, "permission request timed out", true
}

// bridge_permission_cancel_instance resolves every undecided request of an
// instance with "none" (the instance stopped; nobody can answer any more).
// Returns how many waiters it released.
bridge_permission_cancel_instance :: proc(agent_instance_id: string) -> int {
	if strings.trim_space(agent_instance_id) == "" do return 0
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	n := 0
	for i in 0..<len(bridge_permission_pending) {
		p := &bridge_permission_pending[i]
		if p.agent_instance_id != agent_instance_id || p.decided do continue
		p.decided = true
		p.decision = "none"
		p.reason = "agent instance stopped"
		n += 1
	}
	return n
}

bridge_permission_remove :: proc(agent_instance_id, request_id: string) {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for i in 0..<len(bridge_permission_pending) {
		p := bridge_permission_pending[i]
		if p.request_id != request_id do continue
		if agent_instance_id != "" && p.agent_instance_id != agent_instance_id do continue
		unordered_remove(&bridge_permission_pending, i)
		return
	}
}

// Build the downstream push line that mirrors the request to the wrapper/UI so a
// local or remote user can be prompted. Payload matches agent_message/task_nudge shape.
bridge_permission_request_push_json :: proc(p: Bridge_Permission_Pending, input_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"push\":\"permission_request\",\"payload\":{\"request_id\":\"")
	bridge_runtime_write_json_string(&b, p.request_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, p.agent_instance_id)
	strings.write_string(&b, "\",\"tool\":\"")
	bridge_runtime_write_json_string(&b, p.tool)
	strings.write_string(&b, "\",\"risk\":\"")
	bridge_runtime_write_json_string(&b, p.risk)
	strings.write_string(&b, "\",\"input\":")
	if strings.trim_space(input_json) == "" {
		strings.write_string(&b, "{}")
	} else {
		strings.write_string(&b, input_json)
	}
	strings.write_string(&b, "}}\n")
	return strings.to_string(b)
}

// Build the downstream permission_reply push (bridge -> wrapper/adapter) used when
// the hub or a local answer resolves a request out-of-band.
bridge_permission_reply_push_json :: proc(agent_instance_id, request_id, decision, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"push\":\"permission_reply\",\"payload\":{\"request_id\":\"")
	bridge_runtime_write_json_string(&b, request_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, agent_instance_id)
	strings.write_string(&b, "\",\"decision\":\"")
	bridge_runtime_write_json_string(&b, bridge_permission_normalize_decision(decision))
	strings.write_string(&b, "\",\"reason\":\"")
	bridge_runtime_write_json_string(&b, reason)
	strings.write_string(&b, "\"}}\n")
	return strings.to_string(b)
}

// Handle agent.permission.request (blocking). Registers the request, mirrors it to
// the wrapper/UI push channel, and waits for a decision or timeout.
bridge_permission_handle_request :: proc(agent_instance_id, params: string) -> (decision: string, reason: string) {
	request_id := bridge_local_extract_json_string(params, "request_id", "")
	if strings.trim_space(request_id) == "" do return "deny", "permission request missing request_id"
	tool := bridge_local_extract_json_string(params, "tool", "tool")
	risk := bridge_local_extract_json_string(params, "risk", "unknown")
	input_json := bridge_local_extract_json_object(params, "input")
	timeout_ms := bridge_permission_clamp_timeout(bridge_local_extract_json_int(params, "timeout_ms", PERMISSION_DEFAULT_TIMEOUT_MS))

	now := bridge_runtime_now_ms()
	pending := Bridge_Permission_Pending{
		request_id = strings.clone(request_id),
		agent_instance_id = strings.clone(agent_instance_id),
		tool = strings.clone(tool),
		risk = strings.clone(risk),
		created_unix_ms = now,
		deadline_unix_ms = now + i64(timeout_ms),
	}
	if !bridge_permission_register(pending) {
		return "deny", "permission request_id already in flight"
	}

	// Mark the agent as waiting on user input while the request is outstanding.
	// Source is 'permission_gate' (NOT 'pi_extension', which was removed as an
	// activity source): the pane_diff detector is the sole activity source, and
	// this gate signal is ranked equal to pane_diff so it shows immediately and
	// pane_diff can reflect the resolved state right after.
	bridge_runtime_note_agent_activity(agent_instance_id, "waiting_user", "permission_gate")

	// Mirror to the wrapper/UI push channel (observe + mirror). A missing wrapper
	// subscription is non-fatal: the request can still be resolved via
	// agent.permission.reply or the hub push path.
	_ = bridge_wrapper_push_line(agent_instance_id, bridge_permission_request_push_json(pending, input_json))

	decision, reason = bridge_permission_wait(agent_instance_id, request_id, timeout_ms)
	// This legacy contract has no "no decision" outcome: keep its fail-safe deny.
	if decision == "none" do decision = "deny"

	// Restore activity to active now that the gate has resolved; the pane_diff
	// detector will emit the next authoritative active/idle on its following cycle.
	bridge_runtime_note_agent_activity(agent_instance_id, "active", "permission_gate")
	return decision, reason
}
