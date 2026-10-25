package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

// Task System v2 wire: tasks carry `state` (not `status`) and a `brief` object
// (goal/acceptance/verify/review_roles/assignee) instead of assignee_ref /
// reviewer_refs. These tests pin the ctl's typed read of a task create response
// in both the agent-mode (double `data`) and user-mode (single `data`) envelopes.

@(test)
test_task_created_wire_valid_populated :: proc(t: ^testing.T) {
	raw := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_001","state":"backlog","kind":"work","attempt_no":0,"brief":{"goal":"ship it","acceptance":["a","b"],"verify":"make test","review_roles":["reviewer"],"assignee":"agt_worker_1"},"blocked_on":{"kind":"task","ref":"task_dep_a","reason":"dependency not done","since":"2026-10-03T18:00:00Z"},"requires_user_approval":true,"depends_on":["task_dep_a","task_dep_b"],"blocked":true,"bridge_id":"brg_host_1"}}}`
	envelope: Task_Created_Envelope_Wire
	err := json.unmarshal_string(raw, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal should succeed for populated response")

	testing.expect_value(t, envelope.data.data.task_id, "task_001")
	testing.expect_value(t, envelope.data.data.state, "backlog")
	testing.expect_value(t, envelope.data.data.kind, "work")
	testing.expect_value(t, envelope.data.data.attempt_no, 0)
	testing.expect_value(t, envelope.data.data.brief.goal, "ship it")
	testing.expect_value(t, len(envelope.data.data.brief.acceptance), 2)
	// A legacy row's removed `verify` key is ignored by the typed read.
	testing.expect_value(t, envelope.data.data.brief.assignee, "agt_worker_1")
	testing.expect_value(t, len(envelope.data.data.brief.review_roles), 1)
	testing.expect_value(t, envelope.data.data.blocked_on.kind, "task")
	testing.expect_value(t, envelope.data.data.requires_user_approval, true)
	testing.expect_value(t, len(envelope.data.data.depends_on), 2)
	testing.expect_value(t, envelope.data.data.blocked, true)
	testing.expect_value(t, envelope.data.data.bridge_id, "brg_host_1")

	assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, assignee, "agt_worker_1")
	testing.expect_value(t, reviewers, "reviewer")
	testing.expect_value(t, deps_str, `["task_dep_a","task_dep_b"]`)
	testing.expect_value(t, blocked_str, "\x1b[31mtrue\x1b[0m (task)")
	testing.expect_value(t, bridge_str, "brg_host_1")
}

@(test)
test_task_created_wire_null_and_empty_brief :: proc(t: ^testing.T) {
	// Case 1: null fields (hub sends blocked_on:null when not blocked)
	raw_null := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_null","state":"ready","brief":null,"blocked_on":null,"depends_on":null,"blocked":false,"bridge_id":""}}}`
	envelope1: Task_Created_Envelope_Wire
	err1 := json.unmarshal_string(raw_null, &envelope1, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err1 == nil, "unmarshal should succeed with null fields")

	assignee1, reviewers1, deps_str1, blocked_str1, bridge_str1 := format_task_created_summary(envelope1.data.data, context.temp_allocator)
	testing.expect_value(t, assignee1, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, reviewers1, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str1, "none")
	testing.expect_value(t, blocked_str1, "false")
	testing.expect_value(t, bridge_str1, "inherited")

	// Case 2: empty brief object / empty arrays
	raw_empty := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_empty","state":"backlog","brief":{"goal":"","acceptance":[],"review_roles":[]},"depends_on":[],"blocked":false,"bridge_id":""}}}`
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
test_task_created_wire_multiple_review_roles :: proc(t: ^testing.T) {
	raw := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_rr","state":"ready","brief":{"goal":"g","review_roles":["reviewer","security"],"assignee":"agt_w"},"blocked_on":null,"depends_on":[],"blocked":false,"bridge_id":""}}}`
	envelope: Task_Created_Envelope_Wire
	err := json.unmarshal_string(raw, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal ok")
	_, reviewers, _, _, _ := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, reviewers, "reviewer,security")
}

@(test)
test_task_created_wire_bridge_id_specified_vs_inherited :: proc(t: ^testing.T) {
	raw_bridge := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_b1","state":"backlog","brief":{},"blocked_on":null,"depends_on":[],"blocked":false,"bridge_id":"brg_pinned_prod"}}}`
	envelope1: Task_Created_Envelope_Wire
	err1 := json.unmarshal_string(raw_bridge, &envelope1, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err1 == nil, "unmarshal bridge specified ok")
	_, _, _, _, bridge1 := format_task_created_summary(envelope1.data.data, context.temp_allocator)
	testing.expect_value(t, bridge1, "brg_pinned_prod")

	raw_no_bridge := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_b2","state":"backlog","brief":{},"blocked_on":null,"depends_on":[],"blocked":false}}}`
	envelope2: Task_Created_Envelope_Wire
	err2 := json.unmarshal_string(raw_no_bridge, &envelope2, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err2 == nil, "unmarshal bridge omitted ok")
	_, _, _, _, bridge2 := format_task_created_summary(envelope2.data.data, context.temp_allocator)
	testing.expect_value(t, bridge2, "inherited")
}

@(test)
test_task_created_wire_key_reordering_and_whitespace_tolerance :: proc(t: ^testing.T) {
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
				"requires_user_approval": false,
				"brief": {
					"assignee": "agt_reorder_worker",
					"review_roles": [ "reviewer" ],
					"goal": "reorder"
				},
				"state": "in_progress",
				"attempt_no": 2,
				"kind": "work",
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
	testing.expect_value(t, envelope.data.data.state, "in_progress")
	testing.expect_value(t, envelope.data.data.attempt_no, 2)
	testing.expect_value(t, envelope.data.data.brief.assignee, "agt_reorder_worker")
	testing.expect_value(t, envelope.data.data.brief.goal, "reorder")
	testing.expect_value(t, len(envelope.data.data.depends_on), 2)
	testing.expect_value(t, envelope.data.data.blocked, true)

	assignee, reviewers, deps, blocked, bridge := format_task_created_summary(envelope.data.data, context.temp_allocator)
	testing.expect_value(t, assignee, "agt_reorder_worker")
	testing.expect_value(t, reviewers, "reviewer")
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
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t1","state":"backlog","brief":{"goal":"g","review_roles":["reviewer"],"assignee":"agt_t1"},"blocked_on":{"kind":"task","ref":"dep_t1"},"depends_on":["dep_t1"],"blocked":true,"bridge_id":"brg_t1"}}}`,
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t2","state":"ready","brief":null,"blocked_on":null,"depends_on":[],"blocked":false,"bridge_id":""}}}`,
		`{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"task_id":"task_t3","state":"done","brief":{"assignee":"agt_t3","review_roles":[]},"blocked_on":null,"depends_on":["d1","d2"],"blocked":false,"bridge_id":"brg_t3"}}}`,
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
	raw_user := `{"data":{"task_id":"task_direct_hub","state":"backlog","brief":{"assignee":"agt_user_mode","review_roles":[]},"blocked_on":null,"depends_on":["dep_direct"],"blocked":false,"bridge_id":"brg_user"},"meta":{"request_id":"req_1","server_time":"2026-10-03T18:00:00Z"}}`
	user_env: struct {
		data: Task_Created_Data_Wire `json:"data"`,
	}
	err := json.unmarshal_string(raw_user, &user_env, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal user mode envelope should succeed")
	testing.expect_value(t, user_env.data.task_id, "task_direct_hub")
	testing.expect_value(t, user_env.data.state, "backlog")

	assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(user_env.data, context.temp_allocator)
	testing.expect_value(t, assignee, "agt_user_mode")
	testing.expect_value(t, reviewers, "\x1b[31mNONE\x1b[0m")
	testing.expect_value(t, deps_str, `["dep_direct"]`)
	testing.expect_value(t, blocked_str, "false")
	testing.expect_value(t, bridge_str, "brg_user")
}

// ── Task create/update actor fields (Task System v2) ──

@(test)
test_v2_assignee_field_is_plain_agent_id :: proc(t: ^testing.T) {
	testing.expect_value(t, ctl_v2_assignee_field("agt_worker"), `"assignee":"agt_worker"`)
	testing.expect_value(t, ctl_v2_assignee_field("  agt_worker "), `"assignee":"agt_worker"`)
}

@(test)
test_v2_reviewers_field_repeatable_and_csv :: proc(t: ^testing.T) {
	one := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a"})
	testing.expect_value(t, one, `"reviewers":["agt_a"]`)

	repeated := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a", "--title", "x", "--reviewer", "agt_b"})
	testing.expect_value(t, repeated, `"reviewers":["agt_a","agt_b"]`)

	csv := ctl_v2_reviewers_field([]string{"--reviewer", "agt_a, agt_b,,"})
	testing.expect_value(t, csv, `"reviewers":["agt_a","agt_b"]`)

	// `--reviewer ""` must still emit an empty array so update can CLEAR the list.
	cleared := ctl_v2_reviewers_field([]string{"--reviewer", ""})
	testing.expect_value(t, cleared, `"reviewers":[]`)
}

@(test)
test_agentmode_task_params_use_v2_actor_keys :: proc(t: ^testing.T) {
	create := unseal_out(ctl_agentmode_task_create_params(with_kr([]string{"--title", "t", "--assignee", "agt_w", "--reviewer", "agt_r1", "--reviewer", "agt_r2"})))
	testing.expect(t, strings.contains(create, `"assignee":"agt_w"`), "create sends assignee as a plain agent_id")
	testing.expect(t, strings.contains(create, `"reviewers":["agt_r1","agt_r2"]`), "create sends reviewers as an agent_id array")
	testing.expect(t, !strings.contains(create, "assignee_ref") && !strings.contains(create, "reviewer_refs"), "legacy ref shapes are gone")

	update := unseal_out(ctl_agentmode_task_update_params("task_1", with_kr([]string{"--assignee", "agt_w2", "--reviewer", ""})))
	testing.expect(t, strings.contains(update, `"assignee":"agt_w2"`), "update sends assignee as a plain agent_id")
	testing.expect(t, strings.contains(update, `"reviewers":[]`), "update --reviewer \"\" clears the list")
}

@(test)
test_task_actor_flags_reject_instance_pins :: proc(t: ^testing.T) {
	testing.expect(t, ctl_task_reviewer_flags_valid([]string{"--assignee", "agt_w", "--reviewer", "agt_r"}, false), "agent ids are accepted")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--assignee", "inst_worker"}, false), "inst_ assignee must be rejected client-side")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--reviewer", "agt_a,inst_b"}, true), "inst_ reviewer in a csv must be rejected")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--reviewer", "agt_a", "--reviewer", "inst_b"}, true), "inst_ reviewer in a repeated flag must be rejected")
	testing.expect(t, !ctl_task_reviewer_flags_valid([]string{"--assignee-agent-instance-id", "inst_x"}, true), "removed instance-pin flags must be rejected")
}
