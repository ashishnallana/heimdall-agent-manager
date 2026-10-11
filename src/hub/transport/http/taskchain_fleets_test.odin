package http

import "core:strings"
import "core:testing"
import json "core:encoding/json"
import domain "odin_test:hub/domain"

@(test)
test_fleet_bridge_models_wire_roundtrip :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{bridge_models_json = `{"bridge-a":{"provider":"codex","model":"model-a"},"bridge-b":{"provider":"claude","model":"model-b"}}`}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	parsed: Task_Chain_Fleet_Wire
	err := json.unmarshal((transmute([]u8) strings.to_string(b)), &parsed, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil, "fleet response is valid JSON") do return
	testing.expect_value(t, len(parsed.bridge_models), 2)
	testing.expect_value(t, parsed.bridge_models["bridge-a"].provider, "codex")
	testing.expect_value(t, parsed.bridge_models["bridge-b"].model, "model-b")
}

@(test)
test_write_fleet_json :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_abc"),
		agent_id         = "agt_worker",
		capacity         = 4,
		min_warm         = 2,
		idle_ttl_seconds = 600,
		provider         = "claude",
		model             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"task_chain_id":"chain_fleet_abc"`), "must contain task_chain_id")
	testing.expect(t, strings.contains(out, `"agent_id":"agt_worker"`), "must contain agent_id")
	testing.expect(t, strings.contains(out, `"capacity":4`), "must contain capacity 4")
	testing.expect(t, strings.contains(out, `"active_count":0`), "must contain active_count 0")
	testing.expect(t, strings.contains(out, `"min_warm":2`), "must contain min_warm 2")
	testing.expect(t, strings.contains(out, `"idle_ttl_seconds":600`), "must contain idle_ttl_seconds 600")
	testing.expect(t, strings.contains(out, `"created_at":"2026-09-23T10:00:00Z"`), "must contain created_at")
	testing.expect(t, strings.contains(out, `"updated_at":"2026-09-23T10:05:00Z"`), "must contain updated_at")
	testing.expect(t, strings.contains(out, `"provider":"claude"`), "must contain provider claude")
	testing.expect(t, strings.contains(out, `"model":"smart"`), "must contain model smart")
}

// write_fleet_json is shared by the PUT response and the GET list, so this pins
// the payload contract REQ-FLEET-PT-2 relies on for both verbs.
@(test)
test_write_fleet_json_omitted_provider_model_empty :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_empty"),
		agent_id         = "agt_worker",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"provider":""`), "omitted provider must serialize as empty string (inherit)")
	testing.expect(t, strings.contains(out, `"model":""`), "omitted model must serialize as empty string (inherit)")
}

@(test)
test_fleet_provider_model_parse :: proc(t: ^testing.T) {
	body := `{"capacity":2,"provider":"claude","model":"smart"}`
	testing.expect_value(t, json_string(body, "provider"), "claude")
	testing.expect_value(t, json_string(body, "model"), "smart")

	spaced := `{"provider": "claude", "model": "smart"}`
	testing.expect_value(t, json_string(spaced, "provider"), "claude")
	testing.expect_value(t, json_string(spaced, "model"), "smart")

	omitted := `{"capacity":2}`
	testing.expect_value(t, json_string(omitted, "provider"), "")
	testing.expect_value(t, json_string(omitted, "model"), "")
}

// restart_live_instances is an optional boolean body field: only a well-formed
// JSON boolean literal counts as "carried the flag" — absent or malformed values
// behave exactly like today's flag-less PUT.
@(test)
test_fleet_restart_live_instances_bool_parse :: proc(t: ^testing.T) {
	true_body := `{"capacity":1,"restart_live_instances":true}`
	value, ok := json_bool_literal(true_body, "restart_live_instances")
	testing.expect(t, ok, "present true must parse as a boolean literal")
	testing.expect(t, value, "true must parse to true")

	false_body := `{"restart_live_instances": false}`
	value_false, ok_false := json_bool_literal(false_body, "restart_live_instances")
	testing.expect(t, ok_false, "present false must parse as a boolean literal")
	testing.expect(t, !value_false, "false must parse to false")

	absent_body := `{"capacity":2,"provider":"claude","model":"smart"}`
	_, ok_absent := json_bool_literal(absent_body, "restart_live_instances")
	testing.expect(t, !ok_absent, "absent flag must not report ok")

	malformed_body := `{"restart_live_instances":"true"}`
	value_malformed, ok_malformed := json_bool_literal(malformed_body, "restart_live_instances")
	testing.expect(t, !ok_malformed, "quoted string value is not a boolean literal")
	testing.expect(t, !value_malformed, "malformed value must fall back to false")
}

// The restart selection mirrors the fleet list's active_count predicate: every
// runtime_status except the three terminal states counts as live.
@(test)
test_fleet_restart_instance_live_predicate :: proc(t: ^testing.T) {
	testing.expect(t, fleet_restart_instance_live("running"), "running is live")
	testing.expect(t, fleet_restart_instance_live("idle"), "idle is live")
	testing.expect(t, fleet_restart_instance_live("busy"), "busy is live")
	testing.expect(t, fleet_restart_instance_live("launching"), "launching is live")
	testing.expect(t, fleet_restart_instance_live("starting"), "starting is live")
	testing.expect(t, fleet_restart_instance_live("stopping"), "stopping is live")
	testing.expect(t, fleet_restart_instance_live("blocked"), "blocked is live")
	testing.expect(t, !fleet_restart_instance_live("stopped"), "stopped is not live")
	testing.expect(t, !fleet_restart_instance_live("failed"), "failed is not live")
	testing.expect(t, !fleet_restart_instance_live("terminated"), "terminated is not live")
}

// Only a real provider/model change versus the prior row restarts live instances;
// capacity-only edits never do.
@(test)
test_fleet_provider_model_changed :: proc(t: ^testing.T) {
	testing.expect(t, !fleet_provider_model_changed("claude", "smart", "claude", "smart"), "identical provider/model is no change")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "codex", "smart"), "provider change must be detected")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "claude", "cheap"), "model change must be detected")
	testing.expect(t, fleet_provider_model_changed("", "", "claude", "smart"), "unset (inherit) to set values is a change")
	testing.expect(t, fleet_provider_model_changed("claude", "smart", "", ""), "clearing to inherit is a change")
}

// The GET list calls write_fleet_json with the default nil restart params, so its
// payload must stay byte-identical to the pre-restart contract.
@(test)
test_write_fleet_json_default_omits_restart_fields :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_default"),
		agent_id         = "agt_worker",
		capacity         = 1,
		idle_ttl_seconds = 600,
		provider         = "claude",
		model             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, !strings.contains(out, "restarted_instance_ids"), "default output must not carry restart bookkeeping")
	testing.expect(t, !strings.contains(out, "restart_failures"), "default output must not carry restart bookkeeping")
}

// A PUT that carried the flag gets both fields even when nothing was restarted.
@(test)
test_write_fleet_json_restart_fields_empty_when_flagged :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_flagged"),
		agent_id         = "agt_worker",
		capacity         = 1,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}
	restarted: []string
	failures: []Fleet_Restart_Failure

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet, 0, &restarted, &failures)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"restarted_instance_ids":[]`), "flagged PUT must carry an empty restarted list")
	testing.expect(t, strings.contains(out, `"restart_failures":[]`), "flagged PUT must carry an empty failure list")
}

@(test)
test_write_fleet_json_restart_fields_present :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_restart"),
		agent_id         = "agt_worker",
		capacity         = 2,
		idle_ttl_seconds = 600,
		provider         = "codex",
		model             = "cheap",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}
	restarted := []string{"inst_a", "inst_b"}
	failures := []Fleet_Restart_Failure{{instance_id = "inst_c", message = `bridge "offline"`}}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet, 0, &restarted, &failures)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"restarted_instance_ids":["inst_a","inst_b"]`), "restarted ids must be emitted in order")
	testing.expect(t, strings.contains(out, `"restart_failures":[{"instance_id":"inst_c","message":"bridge \"offline\""}]`), "failures must carry instance_id + escaped message")
}

@(test)
test_json_int_field :: proc(t: ^testing.T) {
	body1 := `{"capacity": 3, "min_warm": 1}`
	testing.expect_value(t, json_int_field(body1, "capacity", 1), 3)
	testing.expect_value(t, json_int_field(body1, "min_warm", 0), 1)
	testing.expect_value(t, json_int_field(body1, "idle_ttl_seconds", 600), 600)

	body2 := `{"capacity": "5", "min_warm": "2", "idle_ttl_seconds": "900"}`
	testing.expect_value(t, json_int_field(body2, "capacity", 1), 5)
	testing.expect_value(t, json_int_field(body2, "min_warm", 0), 2)
	testing.expect_value(t, json_int_field(body2, "idle_ttl_seconds", 600), 900)
}
