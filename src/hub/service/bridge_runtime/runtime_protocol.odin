package bridge_runtime

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

// The command cache is shared across threads (the runtime loop writes results;
// fs/file HTTP requests poll for them), so every access takes the registry command
// lock. The lock is NOT reentrant, so these helpers must not be called while the
// caller already holds it (socket-write sites lock separately and never nest a
// cache call inside that section).

PROTOCOL_VERSION :: 1

Hello_Result :: struct {
	accepted: bool,
	replaced_existing: bool,
	generation: int,
}

runtime_accept_hello :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, protocol_version: int, validation_ws_url: string, owner_user_id: string = "", replaced_farewell: string = "") -> (Hello_Result, bool, domain.Domain_Error) {
	if protocol_version != PROTOCOL_VERSION do return Hello_Result{}, false, domain.domain_error(.Validation_Failed, "unsupported bridge protocol_version")
	if bridge_id == "" do return Hello_Result{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	replaced, generation, admitted := project_service.bridge_runtime_registry_accept_live(registry, bridge_id, validation_ws_url != "", validation_ws_url, owner_user_id, replaced_farewell)
	if !admitted do return Hello_Result{}, false, domain.domain_error(.Bridge_Busy, "hub live bridge capacity is exhausted")
	return Hello_Result{accepted = true, replaced_existing = replaced, generation = generation}, true, domain.Domain_Error{}
}

RUNTIME_COMMAND_RESULTS_PER_BRIDGE :: 8

runtime_command_cached :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id: string) -> (string, bool) {
	if registry == nil || bridge_id == "" || generation <= 0 || command_id == "" || len(command_id) > 256 do return "", false
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	live := registry.command_slots_used
	for i in 0..<live {
		if registry.command_bridge_ids[i] == bridge_id && registry.command_generations[i] == generation && registry.command_ids[i] == command_id && registry.command_results_terminal[i] do return registry.command_results_json[i], true
	}
	return "", false
}

// Returns an owned process-allocator copy for callers that use the result after
// releasing the cache lock. The borrowed lookup above remains useful for
// immediate assertions/internal inspection, but must never cross a concurrent
// eviction point.
runtime_command_cached_copy :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id: string) -> (string, bool) {
	if registry == nil || bridge_id == "" || generation <= 0 || command_id == "" do return "", false
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	for i in 0..<registry.command_slots_used {
		if registry.command_bridge_ids[i] == bridge_id && registry.command_generations[i] == generation && registry.command_ids[i] == command_id && registry.command_results_terminal[i] {
			return strings.clone(registry.command_results_json[i], runtime.default_allocator()), true
		}
	}
	return "", false
}

// Efficiently parks an HTTP/RPC waiter until a terminal result is published.
// The condition may wake spuriously, so the cache predicate and real deadline are
// checked in a loop under the same mutex used by result insertion.
runtime_command_wait_terminal :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id: string, timeout: time.Duration, require_connection: bool = false) -> (string, bool) {
	if registry == nil || bridge_id == "" || generation <= 0 || command_id == "" || timeout <= 0 do return "", false
	connection := project_service.bridge_runtime_connection_acquire(registry, bridge_id, generation)
	if require_connection && connection == nil do return "", false
	defer project_service.bridge_runtime_connection_release(registry, connection)
	deadline := time.time_add(time.now(), timeout)
	sync.lock(&registry.command_mutex)
	defer sync.unlock(&registry.command_mutex)
	for {
		if connection != nil && sync.atomic_load(&connection.retired) do return "", false
		for i in 0..<registry.command_slots_used {
			if registry.command_bridge_ids[i] == bridge_id && registry.command_generations[i] == generation && registry.command_ids[i] == command_id && registry.command_results_terminal[i] {
				return strings.clone(registry.command_results_json[i], runtime.default_allocator()), true
			}
		}
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 do return "", false
		_ = sync.cond_wait_with_timeout(&registry.command_cond, &registry.command_mutex, remaining)
	}
}

// command_result acknowledgements are observations, not completion. Every
// command-specific result frame is terminal; for the generic envelope only the
// explicit accepted state is non-terminal. Missing status remains terminal for the
// older command-specific payloads which use command_result as their result type.
runtime_command_result_is_terminal :: proc(result_json: string) -> bool {
	frame_type := jsonx.extract_string(result_json, "type")
	defer delete(frame_type)
	if frame_type != "command_result" do return true
	status := jsonx.extract_string(result_json, "status")
	defer delete(status)
	return status != "accepted"
}

runtime_command_result_idempotent :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id, raw_result_json: string) -> (string, bool) {
	result_json := raw_result_json
	if registry == nil || generation <= 0 || command_id == "" do return "", false
	if len(result_json) > RUNTIME_RESULT_BRIDGE_BYTES { result_json = "{\"type\":\"command_result\",\"status\":\"failed\",\"error\":\"response_backpressure\"}" }
	terminal := runtime_command_result_is_terminal(result_json)
	project_service.bridge_runtime_registry_command_lock(registry)
	defer project_service.bridge_runtime_registry_command_unlock(registry)
	// The first TERMINAL result wins. An accepted acknowledgement may be replaced by
	// exactly one terminal result; otherwise a background Bridge worker could be
	// acknowledged successfully while every synchronous Hub caller times out or sees
	// the acknowledgement as the operation result.
	for i in 0..<registry.command_slots_used {
		if registry.command_ids[i] == command_id && registry.command_bridge_ids[i] == bridge_id && registry.command_generations[i] == generation && (registry.command_results_terminal[i] || !terminal) do return registry.command_results_json[i], true
	}
	runtime_result_make_room_locked(registry, bridge_id, generation, command_id, len(result_json))
	live := registry.command_slots_used
	for i in 0..<live {
		if registry.command_ids[i] != command_id || registry.command_bridge_ids[i] != bridge_id || registry.command_generations[i] != generation do continue
		if registry.command_results_terminal[i] || !terminal do return registry.command_results_json[i], true
		delete(registry.command_results_json[i], runtime.default_allocator())
		registry.command_results_json[i] = strings.clone(result_json, runtime.default_allocator())
		registry.command_results_terminal[i] = true
		sync.cond_broadcast(&registry.command_cond)
		return registry.command_results_json[i], false
	}
	// Retention is partitioned by Bridge. Once a Bridge reaches its quota, replace
	// its own oldest terminal observation even when global free slots remain. A
	// reconnect storm or command burst on one machine therefore cannot evict pending
	// results for every other machine.
	live = registry.command_slots_used
	bridge_entries := 0
	oldest_same := -1
	oldest_same_seq := ~u64(0)
	oldest_global := -1
	oldest_global_seq := ~u64(0)
	for i in 0..<live {
		seq := registry.command_result_sequence[i]
		if seq < oldest_global_seq { oldest_global = i; oldest_global_seq = seq }
		if registry.command_bridge_ids[i] == bridge_id {
			bridge_entries += 1
			if seq < oldest_same_seq { oldest_same = i; oldest_same_seq = seq }
		}
	}
	slot := live
	if bridge_entries >= RUNTIME_COMMAND_RESULTS_PER_BRIDGE {
		slot = oldest_same
	} else if live >= len(registry.command_ids) {
		slot = oldest_global
	}
	if slot < live {
		delete(registry.command_ids[slot], runtime.default_allocator())
		delete(registry.command_bridge_ids[slot], runtime.default_allocator())
		delete(registry.command_results_json[slot], runtime.default_allocator())
	} else {
		registry.command_slots_used += 1
	}
	registry.command_ids[slot] = strings.clone(command_id, runtime.default_allocator())
	registry.command_bridge_ids[slot] = strings.clone(bridge_id, runtime.default_allocator())
	registry.command_generations[slot] = generation
	registry.command_results_json[slot] = strings.clone(result_json, runtime.default_allocator())
	registry.command_results_terminal[slot] = terminal
	registry.command_count += 1
	registry.command_result_sequence[slot] = u64(registry.command_count)
	if terminal do sync.cond_broadcast(&registry.command_cond)
	return registry.command_results_json[slot], false
}

// Production insertion holds a generation lease and the state retirement gate.
// An old reader cannot reinsert a result after disconnect cleaned its generation.
runtime_command_result_for_connection :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id, result_json: string) -> bool {
	c := project_service.bridge_runtime_connection_acquire(registry, bridge_id, generation)
	if c == nil do return false
	defer project_service.bridge_runtime_connection_release(registry, c)
	sync.lock(&c.state_mutex)
	defer sync.unlock(&c.state_mutex)
	if sync.atomic_load(&c.retired) do return false
	_, _ = runtime_command_result_idempotent(registry, bridge_id, generation, command_id, result_json)
	return true
}

runtime_command_cache_destroy :: proc(registry: ^project_service.Bridge_Runtime_Registry) {
	if registry == nil do return
	project_service.bridge_runtime_registry_command_lock(registry)
	live := registry.command_slots_used
	for i in 0..<live {
		delete(registry.command_ids[i], runtime.default_allocator())
		delete(registry.command_bridge_ids[i], runtime.default_allocator())
		delete(registry.command_results_json[i], runtime.default_allocator())
		registry.command_ids[i] = ""
		registry.command_bridge_ids[i] = ""
		registry.command_generations[i] = 0
		registry.command_results_json[i] = ""
	}
	registry.command_count = 0
	registry.command_slots_used = 0
	project_service.bridge_runtime_registry_command_unlock(registry)
	project_service.bridge_runtime_registry_destroy(registry)
}

canonical_runtime_status :: proc(s: string) -> string {
	switch s {
	case "running": return "running"
	case "idle": return "idle"
	case "busy": return "busy"
	case "launching": return "launching"
	case "starting": return "starting"
	case "stopping": return "stopping"
	case "blocked": return "blocked"
	case "stopped": return "stopped"
	case "unreachable": return "unreachable"
	case "failed": return "failed"
	}
	return s
}

canonical_activity_status :: proc(s: string) -> string {
	switch s {
	case "idle": return "idle"
	case "busy": return "busy"
	case "waiting": return "waiting"
	}
	return s
}

runtime_apply_state_report :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, instance_id: string, state_seq: int, runtime_status, activity_status, owner_user_id: string) -> bool {
	changed, _, _ := project_service.bridge_runtime_instance_apply(registry, bridge_id, generation, instance_id, owner_user_id, canonical_runtime_status(runtime_status), canonical_activity_status(activity_status), state_seq)
	return changed
}

runtime_reconcile_digest :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, active_instance_ids: []string) -> int {
	c := project_service.bridge_runtime_connection_acquire(registry, bridge_id, generation)
	if c == nil do return 0
	defer project_service.bridge_runtime_connection_release(registry, c)
	sync.lock(&c.state_mutex)
	defer sync.unlock(&c.state_mutex)
	if sync.atomic_load(&c.retired) do return 0
	changed := 0
	now := time.now()._nsec
	for key, &state in c.instances {
		if state.active && !state.reserved && !string_slice_contains(active_instance_ids, key) {
			_ = project_service.runtime_active_change(registry, state.owner_id, -1)
			delete(state.runtime_status, runtime.default_allocator())
			state.runtime_status = strings.clone("unreachable", runtime.default_allocator())
			state.active = false
			c.terminal_count += 1
			state.expires_ns = now + i64(project_service.runtime_registry_limits(registry).terminal_retention)
			sync.atomic_add(&registry.edge_event_count, 1)
			changed += 1
		}
	}
	project_service.runtime_terminal_prune_locked(registry, c)
	return changed
}

// Caller owns both returned status strings; no lookup borrows storage across eviction.
runtime_instance_status :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, instance_id: string) -> (runtime_status: string, activity_status: string, state_seq: int, ok: bool) {
	state, found := project_service.bridge_runtime_instance_get(registry, bridge_id, generation, instance_id)
	if !found do return "", "", 0, false
	delete(state.owner_id)
	return state.runtime_status, state.activity_status, state.state_seq, true
}

string_slice_contains :: proc(values: []string, needle: string) -> bool {
	for value in values { if strings.trim_space(value) == needle do return true }
	return false
}

RUNTIME_RESULT_BRIDGE_BYTES :: 8 * 1024 * 1024
RUNTIME_RESULT_GLOBAL_BYTES :: 64 * 1024 * 1024

runtime_result_make_room_locked :: proc(r: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, command_id: string, incoming_bytes: int) {
	for {
		total, same := 0, 0
		for i in 0..<r.command_slots_used {
			if r.command_ids[i] == command_id && r.command_bridge_ids[i] == bridge_id && r.command_generations[i] == generation do continue
			total += len(r.command_results_json[i])
			if r.command_bridge_ids[i] == bridge_id do same += len(r.command_results_json[i])
		}
		if same + incoming_bytes <= RUNTIME_RESULT_BRIDGE_BYTES && total + incoming_bytes <= RUNTIME_RESULT_GLOBAL_BYTES do return
		oldest := -1
		oldest_seq := ~u64(0)
		for i in 0..<r.command_slots_used {
			if r.command_ids[i] == command_id && r.command_bridge_ids[i] == bridge_id && r.command_generations[i] == generation do continue
			if same + incoming_bytes > RUNTIME_RESULT_BRIDGE_BYTES && r.command_bridge_ids[i] != bridge_id do continue
			if r.command_result_sequence[i] < oldest_seq { oldest = i; oldest_seq = r.command_result_sequence[i] }
		}
		if oldest < 0 do return
		heap := runtime.default_allocator()
		delete(r.command_ids[oldest], heap)
		delete(r.command_bridge_ids[oldest], heap)
		delete(r.command_results_json[oldest], heap)
		last := r.command_slots_used - 1
		r.command_ids[oldest] = r.command_ids[last]
		r.command_bridge_ids[oldest] = r.command_bridge_ids[last]
		r.command_generations[oldest] = r.command_generations[last]
		r.command_results_json[oldest] = r.command_results_json[last]
		r.command_results_terminal[oldest] = r.command_results_terminal[last]
		r.command_result_sequence[oldest] = r.command_result_sequence[last]
		r.command_ids[last] = ""
		r.command_bridge_ids[last] = ""
		r.command_results_json[last] = ""
		r.command_slots_used -= 1
	}
}
