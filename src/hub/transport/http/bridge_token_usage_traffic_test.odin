package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import events "odin_test:hub/service/events"

// T14: token usage on agent_instance_status adds no hub traffic when nothing
// changed, and a frame never produces more than one instance event.

@(private = "file")
TRAFFIC_SNAPSHOT_A :: `{"tool_calls":2,"est_tokens_total":40,"context_tokens":90000,"context_window":200000,"window_source":"config","run_count":1,"compactions":0,"updated_at_ms":9}`
@(private = "file")
TRAFFIC_SNAPSHOT_B :: `{"tool_calls":3,"est_tokens_total":60,"context_tokens":95000,"context_window":200000,"window_source":"config","run_count":1,"compactions":0,"updated_at_ms":12}`

@(private = "file")
traffic_frame :: proc(instance_id, usage: string) -> string {
	return strings.concatenate({`{"type":"agent_instance_status","agent_instance_id":"`, instance_id, `","state_seq":1,"runtime_status":"running","activity_status":"idle","token_usage":`, usage, `}`}, context.temp_allocator)
}

@(test)
test_token_usage_unchanged_snapshot_no_write_no_event :: proc(t: ^testing.T) {
	f := wire_setup(t, "token_traffic")
	defer wire_teardown(f)
	bus: events.User_Event_Bus
	h := Bridge_Handlers{agents = &f.ag_svc, event_bus = &bus}

	// First snapshot: one row write, announced once.
	changed := bridge_apply_token_usage_members(&h, f.bridge_pin, f.instance_id, traffic_frame(f.instance_id, TRAFFIC_SNAPSHOT_A))
	testing.expect(t, changed, "a new snapshot is written")
	bridge_publish_status_frame_change(&h, f.instance_id, &domain.Agent_Instance{}, false, changed)
	testing.expect_value(t, bus.event_seq, 1)
	first, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	defer domain.agent_instance_destroy(&first)

	// The same snapshot again (every status frame repeats it): no write, no event.
	for _ in 0 ..< 3 {
		changed = bridge_apply_token_usage_members(&h, f.bridge_pin, f.instance_id, traffic_frame(f.instance_id, TRAFFIC_SNAPSHOT_A))
		testing.expect(t, !changed, "an unchanged snapshot is not rewritten")
		bridge_publish_status_frame_change(&h, f.instance_id, &domain.Agent_Instance{}, false, changed)
	}
	testing.expect_value(t, bus.event_seq, 1)
	again, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	defer domain.agent_instance_destroy(&again)
	testing.expect_value(t, again.token_usage_updated_at, first.token_usage_updated_at)
	testing.expect_value(t, again.token_usage_json, first.token_usage_json)

	// A frame without token members touches nothing.
	testing.expect(t, !bridge_apply_token_usage_members(&h, f.bridge_pin, f.instance_id, `{"type":"agent_instance_status","agent_instance_id":"x"}`))

	// A frame from another bridge cannot write the instance.
	testing.expect(t, !bridge_apply_token_usage_members(&h, "brg_other", f.instance_id, traffic_frame(f.instance_id, TRAFFIC_SNAPSHOT_B)))

	// A changed snapshot that arrives with a status change: ONE coalesced event.
	changed = bridge_apply_token_usage_members(&h, f.bridge_pin, f.instance_id, traffic_frame(f.instance_id, TRAFFIC_SNAPSHOT_B))
	testing.expect(t, changed)
	status_inst, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	bridge_publish_status_frame_change(&h, f.instance_id, &status_inst, true, changed)
	testing.expect_value(t, bus.event_seq, 2)

	// A status change alone is still announced (once), without token_changed.
	status_only, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	bridge_publish_status_frame_change(&h, f.instance_id, &status_only, true, false)
	testing.expect_value(t, bus.event_seq, 3)
}

// The instance event summary carries the token data in the API's shape, so the
// UI patches its caches from the event instead of refetching.
@(test)
test_instance_changed_summary_carries_token_data :: proc(t: ^testing.T) {
	plain := instance_changed_summary_json(domain.Agent_Instance{agent_instance_id = "inst_a", runtime_status = "running"})
	defer delete(plain)
	testing.expect(t, !strings.contains(plain, "token_"), "no token members without data")

	inst := domain.Agent_Instance{
		agent_instance_id = "inst_a", runtime_status = "running", chain_id = "chain_x",
		token_usage_json = TRAFFIC_SNAPSHOT_A, token_usage_updated_at = "2026-11-02T10:00:00Z",
		has_token_totals = true, token_total_context_tokens = 300000, token_total_est_tool_tokens = 9000, token_total_output_tokens = 1200, token_runs_counted = 2, token_totals_last_run = 2,
	}
	summary := instance_changed_summary_json(inst, token_changed = true)
	defer delete(summary)
	v, err := json.parse_string(summary, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := v.(json.Object)
	testing.expect_value(t, root["token_usage"].(json.Object)["context_tokens"].(json.Integer), 90000)
	testing.expect_value(t, root["token_usage_updated_at"].(json.String), "2026-11-02T10:00:00Z")
	testing.expect_value(t, root["token_totals"].(json.Object)["runs_counted"].(json.Integer), 2)
	testing.expect_value(t, root["token_changed"].(json.Boolean), true)
	testing.expect_value(t, root["chain_id"].(json.String), "chain_x")
}
