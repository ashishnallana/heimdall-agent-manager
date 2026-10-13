package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_task_created_wire_valid_populated :: proc(t: ^testing.T) {
	raw := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_001","status":"queued","assignee_ref":{"type":"agent_instance","agent_instance_id":"inst_worker_1"},"reviewer_refs":[{"type":"agent_id","agent_id":"agt_reviewer_1"}],"depends_on":["task_dep_a","task_dep_b"],"blocked":true,"bridge_id":"brg_host_1"}}}`
	envelope: Task_Created_Envelope_Wire
	err := json.unmarshal_string(raw, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal should succeed for populated response")

	testing.expect_value(t, envelope.data.data.task_id, "task_001")
	testing.expect_value(t, envelope.data.data.status, "queued")
	testing.expect_value(t, envelope.data.data.assignee_ref.agent_instance_id, "inst_worker_1")
	testing.expect_value(t, len(envelope.data.data.reviewer_refs), 1)
	testing.expect_value(t, len(envelope.data.data.depends_on), 2)
	testing.expect_value(t, envelope.data.data.blocked, true)
	testing.expect_value(t, envelope.data.data.bridge_id, "brg_host_1")

	assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, assignee, "inst_worker_1")
	testing.expect_value(t, reviewers, "assigned")
	testing.expect_value(t, deps_str, `["task_dep_a","task_dep_b"]`)
	testing.expect_value(t, blocked_str, "\x1b[31mtrue\x1b[0m")
	testing.expect_value(t, bridge_str, "brg_host_1")
}

@(test)
test_task_created_wire_declarative_agent_assignee :: proc(t: ^testing.T) {
	raw := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_decl","status":"assigned","assignee_ref":{"type":"agent_id","agent_id":"agt_durable_worker"},"reviewer_refs":[],"depends_on":[],"blocked":false,"bridge_id":""}}}`
	envelope: Task_Created_Envelope_Wire
	err := json.unmarshal_string(raw, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal should succeed for declarative agent assignee")

	testing.expect_value(t, envelope.data.data.assignee_ref.agent_id, "agt_durable_worker")
	testing.expect_value(t, envelope.data.data.assignee_ref.agent_instance_id, "")

	assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, assignee, "agt_durable_worker")
	testing.expect_value(t, reviewers, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str, "none")
	testing.expect_value(t, blocked_str, "false")
	testing.expect_value(t, bridge_str, "inherited")
}

@(test)
test_task_created_wire_null_and_empty_assignee_and_reviewers :: proc(t: ^testing.T) {
	// Case 1: null fields
	raw_null := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_null","status":"queued","assignee_ref":null,"reviewer_refs":null,"depends_on":null,"blocked":false,"bridge_id":""}}}`
	envelope1: Task_Created_Envelope_Wire
	err1 := json.unmarshal_string(raw_null, &envelope1, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err1 == nil, "unmarshal should succeed with null fields")

	assignee1, reviewers1, deps_str1, blocked_str1, bridge_str1 := format_task_created_summary(envelope1.data.data, context.temp_allocator)
	testing.expect_value(t, assignee1, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, reviewers1, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str1, "none")
	testing.expect_value(t, blocked_str1, "false")
	testing.expect_value(t, bridge_str1, "inherited")

	// Case 2: empty object / empty arrays
	raw_empty := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_empty","status":"queued","assignee_ref":{},"reviewer_refs":[],"depends_on":[],"blocked":false,"bridge_id":""}}}`
	envelope2: Task_Created_Envelope_Wire
	err2 := json.unmarshal_string(raw_empty, &envelope2, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err2 == nil, "unmarshal should succeed with empty fields")

	assignee2, reviewers2, deps_str2, blocked_str2, bridge_str2 := format_task_created_summary(envelope2.data.data, context.temp_allocator)
	testing.expect_value(t, assignee2, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, reviewers2, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str2, "none")
	testing.expect_value(t, blocked_str2, "false")
	testing.expect_value(t, bridge_str2, "inherited")
}

@(test)
test_task_created_wire_dependencies_and_blocked :: proc(t: ^testing.T) {
	// Blocked with single dependency
	raw1 := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_dep1","status":"queued","assignee_ref":null,"reviewer_refs":[],"depends_on":["task_parent"],"blocked":true,"bridge_id":""}}}`
	envelope1: Task_Created_Envelope_Wire
	err1 := json.unmarshal_string(raw1, &envelope1, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err1 == nil, "unmarshal dep1 ok")

	assignee1, reviewers1, deps1, blocked1, bridge1 := format_task_created_summary(envelope1.data.data, context.temp_allocator)
	testing.expect_value(t, deps1, `["task_parent"]`)
	testing.expect_value(t, blocked1, "\x1b[31mtrue\x1b[0m")

	// Unblocked with multiple dependencies
	raw2 := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_dep2","status":"queued","assignee_ref":null,"reviewer_refs":[],"depends_on":["dep_1","dep_2","dep_3"],"blocked":false,"bridge_id":""}}}`
	envelope2: Task_Created_Envelope_Wire
	err2 := json.unmarshal_string(raw2, &envelope2, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err2 == nil, "unmarshal dep2 ok")

	assignee2, reviewers2, deps2, blocked2, bridge2 := format_task_created_summary(envelope2.data.data, context.temp_allocator)
	testing.expect_value(t, deps2, `["dep_1","dep_2","dep_3"]`)
	testing.expect_value(t, blocked2, "false")
}

@(test)
test_task_created_wire_bridge_id_specified_vs_inherited :: proc(t: ^testing.T) {
	// Explicit bridge
	raw_bridge := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_b1","status":"queued","assignee_ref":null,"reviewer_refs":[],"depends_on":[],"blocked":false,"bridge_id":"brg_pinned_prod"}}}`
	envelope1: Task_Created_Envelope_Wire
	err1 := json.unmarshal_string(raw_bridge, &envelope1, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err1 == nil, "unmarshal bridge specified ok")

	_, _, _, _, bridge1 := format_task_created_summary(envelope1.data.data, context.temp_allocator)
	testing.expect_value(t, bridge1, "brg_pinned_prod")

	// Omitted bridge_id
	raw_no_bridge := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_b2","status":"queued","assignee_ref":null,"reviewer_refs":[],"depends_on":[],"blocked":false}}}`
	envelope2: Task_Created_Envelope_Wire
	err2 := json.unmarshal_string(raw_no_bridge, &envelope2, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err2 == nil, "unmarshal bridge omitted ok")

	_, _, _, _, bridge2 := format_task_created_summary(envelope2.data.data, context.temp_allocator)
	testing.expect_value(t, bridge2, "inherited")
}

@(test)
test_task_created_wire_key_reordering_and_whitespace_tolerance :: proc(t: ^testing.T) {
	// Scrambled keys with whitespace, newlines, and tabs
	raw_reordered := `
	{
		"ok":   true,
		"data": {
			"meta": { "request_id": "req_xyz", "server_time": "2026-10-03T18:00:00Z" },
			"data": {
				"bridge_id": "brg_reordered_99",
				"blocked": true,
				"depends_on": [
					"task_prior_1",
					"task_prior_2"
				],
				"status": "in_progress",
				"reviewer_refs": [
					{
						"agent_id": "agt_rev_007",
						"type": "agent_id"
					}
				],
				"assignee_ref": {
					"agent_instance_id": "inst_reorder_worker",
					"type": "agent_instance"
				},
				"task_id": "task_reordered_123"
			}
		},
		"id": "ham-ctl-agent",
		"v": 1
	}
	`
	envelope: Task_Created_Envelope_Wire
	err := json.unmarshal_string(raw_reordered, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal should tolerate key reordering and multiline whitespace")

	testing.expect_value(t, envelope.data.data.task_id, "task_reordered_123")
	testing.expect_value(t, envelope.data.data.status, "in_progress")
	testing.expect_value(t, envelope.data.data.assignee_ref.agent_instance_id, "inst_reorder_worker")
	testing.expect_value(t, len(envelope.data.data.reviewer_refs), 1)
	testing.expect_value(t, envelope.data.data.reviewer_refs[0].agent_id, "agt_rev_007")
	testing.expect_value(t, len(envelope.data.data.depends_on), 2)
	testing.expect_value(t, envelope.data.data.blocked, true)
	testing.expect_value(t, envelope.data.data.bridge_id, "brg_reordered_99")

	assignee, reviewers, deps, blocked, bridge := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, assignee, "inst_reorder_worker")
	testing.expect_value(t, reviewers, "assigned")
	testing.expect_value(t, deps, `["task_prior_1","task_prior_2"]`)
	testing.expect_value(t, blocked, "\x1b[31mtrue\x1b[0m")
	testing.expect_value(t, bridge, "brg_reordered_99")
}

@(test)
test_task_created_wire_tracking_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	payloads := [?]string{
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t1","status":"queued","assignee_ref":{"type":"agent_instance","agent_instance_id":"inst_t1"},"reviewer_refs":[{"type":"agent_id","agent_id":"agt_t1"}],"depends_on":["dep_t1"],"blocked":true,"bridge_id":"brg_t1"}}}`,
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t2","status":"assigned","assignee_ref":null,"reviewer_refs":null,"depends_on":[],"blocked":false,"bridge_id":""}}}`,
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t3","status":"completed","assignee_ref":{"type":"agent_id","agent_id":"agt_t3"},"reviewer_refs":[],"depends_on":["d1","d2"],"blocked":false,"bridge_id":"brg_t3"}}}`,
	}

	for p in payloads {
		envelope: Task_Created_Envelope_Wire
		err := json.unmarshal_string(p, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
		testing.expect(t, err == nil, "unmarshal should succeed")

		assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(envelope.data.data, context.temp_allocator)
		testing.expect(t, len(assignee) > 0, "assignee should be formatted")
		testing.expect(t, len(reviewers) > 0, "reviewers should be formatted")
		testing.expect(t, len(deps_str) > 0, "deps_str should be formatted")
		testing.expect(t, len(blocked_str) > 0, "blocked_str should be formatted")
		testing.expect(t, len(bridge_str) > 0, "bridge_str should be formatted")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	if len(track.allocation_map) > 0 {
		testing.fail_now(t, "Memory leak detected in task created wire operations")
	}
}

@(test)
test_task_created_wire_user_mode_envelope :: proc(t: ^testing.T) {
	raw_user := `{"data":{"task_id":"task_direct_hub","status":"queued","assignee_ref":{"type":"agent_instance","agent_instance_id":"inst_user_mode"},"reviewer_refs":[],"depends_on":["dep_direct"],"blocked":false,"bridge_id":"brg_user"},"meta":{"request_id":"req_1","server_time":"2026-10-03T18:00:00Z"}}`
	user_env: struct {
		data: Task_Created_Data_Wire `json:"data"`,
	}
	err := json.unmarshal_string(raw_user, &user_env, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal user mode envelope should succeed")
	testing.expect_value(t, user_env.data.task_id, "task_direct_hub")
	testing.expect_value(t, user_env.data.status, "queued")

	assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(user_env.data, context.temp_allocator)
	testing.expect_value(t, assignee, "inst_user_mode")
	testing.expect_value(t, reviewers, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str, `["dep_direct"]`)
	testing.expect_value(t, blocked_str, "false")
	testing.expect_value(t, bridge_str, "brg_user")
}

// ── Task & Task-Chain Subscription CLI Parameter Tests ──

@(test)
test_agentmode_chain_subscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_chain_subscribe_params("chain_abc", "all")
	testing.expect(t, strings.contains(p1, `"chain_id":"chain_abc"`), "chain_id should match")
	testing.expect(t, strings.contains(p1, `"events":"all"`), "events should match default 'all'")

	p2 := ctl_agentmode_chain_subscribe_params("chain_xyz", "chain_status")
	testing.expect(t, strings.contains(p2, `"chain_id":"chain_xyz"`), "chain_id should match")
	testing.expect(t, strings.contains(p2, `"events":"chain_status"`), "events should match specific event")
}

@(test)
test_agentmode_chain_unsubscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_chain_unsubscribe_params("chain_abc", "")
	testing.expect(t, strings.contains(p1, `"chain_id":"chain_abc"`), "chain_id should match")
	testing.expect(t, strings.contains(p1, `"events":""`), "events should be empty when not specified")

	p2 := ctl_agentmode_chain_unsubscribe_params("chain_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"chain_id":"chain_xyz"`), "chain_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_agentmode_task_subscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_task_subscribe_params("task_abc", "all")
	testing.expect(t, strings.contains(p1, `"task_id":"task_abc"`), "task_id should match")
	testing.expect(t, strings.contains(p1, `"events":"all"`), "events should match default 'all'")

	p2 := ctl_agentmode_task_subscribe_params("task_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"task_id":"task_xyz"`), "task_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_agentmode_task_unsubscribe_params :: proc(t: ^testing.T) {
	p1 := ctl_agentmode_task_unsubscribe_params("task_abc", "")
	testing.expect(t, strings.contains(p1, `"task_id":"task_abc"`), "task_id should match")
	testing.expect(t, strings.contains(p1, `"events":""`), "events should be empty when not specified")

	p2 := ctl_agentmode_task_unsubscribe_params("task_xyz", "task_status")
	testing.expect(t, strings.contains(p2, `"task_id":"task_xyz"`), "task_id should match")
	testing.expect(t, strings.contains(p2, `"events":"task_status"`), "events should match specific event")
}

@(test)
test_user_chain_subscribe_body :: proc(t: ^testing.T) {
	b1 := ctl_user_chain_subscribe_body("all", "inst_agent_1")
	defer delete(b1)
	testing.expect(t, strings.contains(b1, `"events":"all"`), "events should match 'all'")
	testing.expect(t, strings.contains(b1, `"agent_instance_id":"inst_agent_1"`), "agent_instance_id should match")

	b2 := ctl_user_chain_subscribe_body("chain_status", "")
	defer delete(b2)
	testing.expect(t, strings.contains(b2, `"events":"chain_status"`), "events should match 'chain_status'")
	testing.expect(t, !strings.contains(b2, "agent_instance_id"), "agent_instance_id should be omitted when empty")
}

@(test)
test_user_chain_unsubscribe_body :: proc(t: ^testing.T) {
	b1 := ctl_user_chain_unsubscribe_body("", "")
	defer delete(b1)
	testing.expect_value(t, b1, "{}")

	b2 := ctl_user_chain_unsubscribe_body("task_status", "inst_agent_2")
	defer delete(b2)
	testing.expect(t, strings.contains(b2, `"events":"task_status"`), "events should match")
	testing.expect(t, strings.contains(b2, `"agent_instance_id":"inst_agent_2"`), "agent_instance_id should match")
}

@(test)
test_command_tokens_skips_events_flags :: proc(t: ^testing.T) {
	args := []string{"ham-ctl", "task-chain", "subscribe", "chain_123", "--events", "all"}
	tokens := command_tokens(args)
	defer delete(tokens)

	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0], "task-chain")
	testing.expect_value(t, tokens[1], "subscribe")
	testing.expect_value(t, tokens[2], "chain_123")

	args2 := []string{"ham-ctl", "task", "unsubscribe", "task_456", "--event-type", "task_status"}
	tokens2 := command_tokens(args2)
	defer delete(tokens2)

	testing.expect_value(t, len(tokens2), 3)
	testing.expect_value(t, tokens2[0], "task")
	testing.expect_value(t, tokens2[1], "unsubscribe")
	testing.expect_value(t, tokens2[2], "task_456")
}
