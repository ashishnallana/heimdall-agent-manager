package http

import "core:mem"
import "core:testing"
import project_service "odin_test:hub/service/project"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"

// REQ-P1-HEARTBEAT: Heartbeat digest parsing with normal key order.
@(test)
test_bridge_heartbeat_digest_normal_order :: proc(t: ^testing.T) {
	text := `{"type":"bridge_heartbeat","active_instance_ids":["inst_1","inst_2"],"digest":[{"agent_instance_id":"inst_1","state_seq":1,"runtime_status":"running","activity_status":"active"},{"agent_instance_id":"inst_2","state_seq":2,"runtime_status":"running","activity_status":"idle"}]}`
	active := bridge_apply_heartbeat_digest(nil, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 2)
	testing.expect_value(t, active[0], "inst_1")
	testing.expect_value(t, active[1], "inst_2")
}

// REQ-P1-HEARTBEAT: Heartbeat digest parsing with reversed key order.
@(test)
test_bridge_heartbeat_digest_reversed_order :: proc(t: ^testing.T) {
	text := `{"type":"bridge_heartbeat","active_instance_ids":["inst_rev"],"digest":[{"activity_status":"working","runtime_status":"running","state_seq":42,"agent_instance_id":"inst_rev"}]}`
	active := bridge_apply_heartbeat_digest(nil, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "inst_rev")
}

// REQ-P1-HEARTBEAT: Real bridge wire frame compatibility ("instances" array key).
@(test)
test_bridge_heartbeat_digest_instances_field :: proc(t: ^testing.T) {
	text := `{"type":"bridge_heartbeat","active_instance_ids":["inst_wire"],"instances":[{"agent_instance_id":"inst_wire","state_seq":5,"runtime_status":"running","activity_status":"busy"}]}`
	active := bridge_apply_heartbeat_digest(nil, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "inst_wire")
}

// REQ-P1-HEARTBEAT: Whitespace, tabs, and newlines in heartbeat JSON.
@(test)
test_bridge_heartbeat_digest_whitespace_newlines :: proc(t: ^testing.T) {
	text := `
	{
		"type": "bridge_heartbeat",
		"active_instance_ids": [ "inst_ws" ],
		"digest": [
			{
				"agent_instance_id": "inst_ws",
				"state_seq": 10,
				"runtime_status": "running",
				"activity_status": "active"
			}
		]
	}
	`
	active := bridge_apply_heartbeat_digest(nil, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "inst_ws")
}

// REQ-P1-HEARTBEAT: Empty or missing digest and malformed JSON resilience.
@(test)
test_bridge_heartbeat_digest_empty_and_missing :: proc(t: ^testing.T) {
	// Empty string
	testing.expect_value(t, len(bridge_apply_heartbeat_digest(nil, "brg_test", "")), 0)

	// Malformed JSON
	testing.expect_value(t, len(bridge_apply_heartbeat_digest(nil, "brg_test", "{invalid json")), 0)

	// Missing digest and instances
	testing.expect_value(t, len(bridge_apply_heartbeat_digest(nil, "brg_test", `{"type":"bridge_heartbeat"}`)), 0)

	// Empty digest array
	testing.expect_value(t, len(bridge_apply_heartbeat_digest(nil, "brg_test", `{"type":"bridge_heartbeat","digest":[]}`)), 0)

	// Entry with empty agent_instance_id
	empty_id_active := bridge_apply_heartbeat_digest(nil, "brg_test", `{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"","state_seq":1,"runtime_status":"running"}]}`)
	defer {
		for s in empty_id_active do delete(s)
		delete(empty_id_active)
	}
	testing.expect_value(t, len(empty_id_active), 0)
}

// REQ-P1-HEARTBEAT: Substring collision safety (agent status containing "agent_instance_id").
@(test)
test_bridge_heartbeat_digest_substring_collision_safety :: proc(t: ^testing.T) {
	text := `{"type":"bridge_heartbeat","active_instance_ids":["inst_real"],"digest":[{"agent_instance_id":"inst_real","state_seq":7,"runtime_status":"running","activity_status":"inspecting \"agent_instance_id\":\"fake_id\" bug"}]}`
	active := bridge_apply_heartbeat_digest(nil, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "inst_real")
}

// REQ-P1-HEARTBEAT: Applying digest updates Bridge_Runtime_Registry state.
@(test)
test_bridge_heartbeat_digest_applies_runtime_registry :: proc(t: ^testing.T) {
	registry := project_service.Bridge_Runtime_Registry{}
	_, _, _ = bridge_runtime_service.runtime_accept_hello(&registry, "brg_test", bridge_runtime_service.PROTOCOL_VERSION, "")
	defer bridge_runtime_service.runtime_command_cache_destroy(&registry)
	h := Bridge_Handlers{
		bridge_runtime_registry = &registry,
	}

	text := `{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"inst_reg","state_seq":3,"runtime_status":"running","activity_status":"executing_task"}]}`
	active := bridge_apply_heartbeat_digest(&h, "brg_test", text)
	defer {
		for s in active do delete(s)
		delete(active)
	}

	testing.expect_value(t, len(active), 1)
	testing.expect_value(t, active[0], "inst_reg")

	runtime_status, activity_status, state_seq, ok := bridge_runtime_service.runtime_instance_status(&registry, "brg_test", project_service.bridge_runtime_registry_generation(&registry, "brg_test"), "inst_reg")
	defer delete(runtime_status)
	defer delete(activity_status)
	testing.expect(t, ok, "instance registered in registry")
	testing.expect_value(t, runtime_status, "running")
	testing.expect_value(t, activity_status, "executing_task")
	testing.expect_value(t, state_seq, 3)


}

// REQ-P1-HEARTBEAT: Zero memory leaks under Odin tracking allocator.
@(test)
test_bridge_heartbeat_digest_zero_leaks_tracking_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	fixtures := []string{
		`{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"inst_1","state_seq":1,"runtime_status":"running","activity_status":"active"}]}`,
		`{"type":"bridge_heartbeat","digest":[{"activity_status":"idle","runtime_status":"stopped","state_seq":2,"agent_instance_id":"inst_2"}]}`,
		`{"type":"bridge_heartbeat","instances":[{"agent_instance_id":"inst_3","state_seq":3,"runtime_status":"running","activity_status":"busy"}]}`,
		`{"type":"bridge_heartbeat","digest":[]}`,
		`{"type":"bridge_heartbeat"}`,
		`{invalid json`,
	}

	for f in fixtures {
		active := bridge_apply_heartbeat_digest(nil, "brg_test", f)
		for s in active do delete(s)
		delete(active)
	}

	testing.expectf(t, len(track.allocation_map) == 0, "expected 0 live allocations, found %d", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "expected 0 bad frees, found %d", len(track.bad_free_array))
}
