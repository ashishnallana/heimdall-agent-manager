package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// T10: GET /api/v1/task-chains/{id}/token-usage aggregates the chain's instances
// from sqlite (snapshot + counted totals), names agents, and is owner-scoped.
@(test)
test_task_chain_token_usage_handler :: proc(t: ^testing.T) {
	f := wire_setup(t, "token_usage")
	defer wire_teardown(f)
	path := fmt.tprintf("/api/v1/task-chains/%s/token-usage", f.chain_id)

	// No token data yet: empty state, the fixture instance still listed.
	resp := task_chain_token_usage_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, resp.status, 200)
	data := token_usage_data(t, resp.body)
	testing.expect_value(t, data["has_data"].(json.Boolean), false)
	testing.expect_value(t, len(data["agents"].(json.Array)), 1)
	testing.expect_value(t, data["total"].(json.Object)["total_tokens"].(json.Integer), 0)

	// Fixture instance (agt_wire_tb2, running): run 1 counted, live run 2.
	_, _, _ = iface.agent_save(&f.ag_repo, domain.Agent{agent_id = "agt_wire_tb2", owner_user_id = f.owner, name = "Wire Worker", slug = "wire-worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = "2026-09-25T10:00:00Z", updated_at = "2026-09-25T10:00:00Z"})
	inst, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	inst.run_count = 2
	_, saved, save_err := iface.agent_save_instance(&f.ag_repo, inst)
	testing.expectf(t, saved, "run_count saved (%s)", save_err.message)
	added, _ := iface.agent_add_token_totals(&f.ag_repo, f.instance_id, f.bridge_pin, 1, 100000, 2000, 500)
	testing.expect(t, added)
	_, _ = iface.agent_update_token_usage(&f.ag_repo, f.instance_id, f.bridge_pin,
		`{"tool_calls":2,"est_tokens_total":300,"context_tokens":150000,"context_window":200000,"window_source":"config","output_tokens_total":50,"run_count":2,"compactions":0,"updated_at_ms":1}`, "2026-11-02T10:00:00Z")
	// Second instance of another agent on the chain, stopped, counted only.
	_, ok2, err2 := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{agent_instance_id = "inst_wire_rev", owner_user_id = f.owner, agent_id = "agt_wire_rev", bridge_id = f.bridge_pin, chain_id = string(f.chain_id), runtime_status = "stopped", startup_status = "ready", run_count = 1, created_at = "2026-09-25T11:00:00Z", updated_at = "2026-09-25T11:00:00Z"})
	testing.expectf(t, ok2, "second instance saved (%s)", err2.message)
	added, _ = iface.agent_add_token_totals(&f.ag_repo, "inst_wire_rev", f.bridge_pin, 1, 10000, 100, 20)
	testing.expect(t, added)

	resp = task_chain_token_usage_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, resp.status, 200)
	data = token_usage_data(t, resp.body)
	testing.expect_value(t, data["has_data"].(json.Boolean), true)
	testing.expect_value(t, data["instances_with_data"].(json.Integer), 2)
	total := data["total"].(json.Object)
	// (100000+150000+10000) context + (500+50+20) output.
	testing.expect_value(t, total["context_tokens"].(json.Integer), 260000)
	testing.expect_value(t, total["output_tokens"].(json.Integer), 570)
	testing.expect_value(t, total["total_tokens"].(json.Integer), 260570)
	testing.expect_value(t, total["runs"].(json.Integer), 3)
	agents := data["agents"].(json.Array)
	testing.expect_value(t, len(agents), 2)
	w := agents[0].(json.Object)
	testing.expect_value(t, w["agent_id"].(json.String), "agt_wire_tb2")
	testing.expect_value(t, w["agent_name"].(json.String), "Wire Worker")
	testing.expect_value(t, w["context"].(json.Object)["pct"].(json.Integer), 75)
	testing.expect_value(t, w["lifetime"].(json.Object)["est_tool_tokens"].(json.Integer), 2300)
	wi := w["instances"].(json.Array)[0].(json.Object)
	testing.expect_value(t, wi["context_pct"].(json.Integer), 75)
	testing.expect_value(t, wi["window_source"].(json.String), "config")
	testing.expect_value(t, wi["snapshot_counted"].(json.Boolean), false)
	r := agents[1].(json.Object)
	testing.expect_value(t, r["agent_name"].(json.String), "") // no agent row
	_, has_ctx := r["context"]
	testing.expect(t, !has_ctx, "stopped agent has no current context")

	// Unknown chain -> error, never another owner's data.
	missing := task_chain_token_usage_handler(&f.th, wire_cookie_request(f, "GET", "/api/v1/task-chains/chain_nope/token-usage", ""))
	testing.expect(t, missing.status >= 400, "unknown chain is rejected")
}

// Estimate-only live snapshot: the chain payload carries context_source,
// the effective (estimated) tokens and the pct, never a raw 0 context_tokens.
@(test)
test_task_chain_token_usage_handler_estimate :: proc(t: ^testing.T) {
	f := wire_setup(t, "token_usage_est")
	defer wire_teardown(f)
	path := fmt.tprintf("/api/v1/task-chains/%s/token-usage", f.chain_id)
	_, _ = iface.agent_update_token_usage(&f.ag_repo, f.instance_id, f.bridge_pin,
		`{"tool_calls":5,"est_tokens_total":100000,"context_source":"estimate","estimated_context_tokens":150000,"context_window":200000,"run_count":1,"compactions":0,"updated_at_ms":1}`, "2026-11-02T10:00:00Z")
	resp := task_chain_token_usage_handler(&f.th, wire_cookie_request(f, "GET", path, ""))
	testing.expect_value(t, resp.status, 200)
	data := token_usage_data(t, resp.body)
	agent := data["agents"].(json.Array)[0].(json.Object)
	ctx := agent["context"].(json.Object)
	testing.expect_value(t, ctx["pct"].(json.Integer), 75)
	testing.expect_value(t, ctx["tokens"].(json.Integer), 150000)
	testing.expect_value(t, ctx["context_source"].(json.String), "estimate")
	inst := agent["instances"].(json.Array)[0].(json.Object)
	testing.expect_value(t, inst["context_pct"].(json.Integer), 75)
	testing.expect_value(t, inst["context_source"].(json.String), "estimate")
	testing.expect_value(t, inst["estimated_context_tokens"].(json.Integer), 150000)
	_, raw := inst["context_tokens"]
	testing.expect(t, !raw, "raw provider context_tokens stays absent")
}

@(private = "file")
token_usage_data :: proc(t: ^testing.T, body: string) -> json.Object {
	v, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "valid JSON: %s", body)
	root, _ := v.(json.Object)
	data, _ := root["data"].(json.Object)
	return data
}

// Per-instance and per-agent-context thresholds are emitted from each row's own snapshot.
@(test)
test_chain_token_usage_json_per_row_thresholds :: proc(t: ^testing.T) {
	instances := []domain.Agent_Instance{
		{agent_instance_id = "inst_old", agent_id = "agt_a", runtime_status = "stopped", kind = "agent",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":1,"context_tokens":10,"context_window":200000,"warn_pct":40,"rollover_pct":70,"run_count":1,"compactions":0,"updated_at_ms":1}`},
		{agent_instance_id = "inst_live", agent_id = "agt_a", runtime_status = "running", kind = "agent",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":1,"context_tokens":150000,"context_window":200000,"warn_pct":60,"rollover_pct":80,"run_count":2,"compactions":0,"updated_at_ms":1}`},
	}
	usage := domain.chain_token_usage_aggregate(instances, nil, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	write_chain_token_usage_json(&b, "chain_x", usage)
	v, err := json.parse(transmute([]u8)strings.to_string(b), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	agent := v.(json.Object)["agents"].(json.Array)[0].(json.Object)
	insts := agent["instances"].(json.Array)
	testing.expect_value(t, insts[0].(json.Object)["warn_pct"].(json.Integer), 40)
	testing.expect_value(t, insts[1].(json.Object)["warn_pct"].(json.Integer), 60)
	testing.expect_value(t, insts[1].(json.Object)["rollover_pct"].(json.Integer), 80)
	ctx := agent["context"].(json.Object)
	testing.expect_value(t, ctx["warn_pct"].(json.Integer), 60)
	testing.expect_value(t, ctx["rollover_pct"].(json.Integer), 80)
}
