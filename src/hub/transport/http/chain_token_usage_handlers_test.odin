package http

import "core:encoding/json"
import "core:fmt"
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

@(private = "file")
token_usage_data :: proc(t: ^testing.T, body: string) -> json.Object {
	v, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "valid JSON: %s", body)
	root, _ := v.(json.Object)
	data, _ := root["data"].(json.Object)
	return data
}
