package main

import "core:encoding/json"
import "core:testing"

@(private = "file")
agent_search_test_hits := [?]Task_Chain_Search_Hit{
	{chain_id = "chain_secret", project_id = "proj", status = "completed", title = "Preview tunnel hardening", description_snippet = "harden the [tunnel]"},
	{chain_id = "chain_plain", project_id = "proj", status = "active", title = "Plain chain"},
}

@(private = "file")
agent_search_test_chain_ids :: proc(t: ^testing.T, body: string) -> [dynamic]string {
	ids := make([dynamic]string, context.temp_allocator)
	parsed, err := json.parse(transmute([]u8)body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	groups := parsed.(json.Object)["data"].(json.Object)["groups"].(json.Array)
	for group in groups {
		obj := group.(json.Object)
		if obj["type"].(json.String) != "task-chain" do continue
		for hit in obj["hits"].(json.Array) do append(&ids, string(hit.(json.Object)["id"].(json.String)))
	}
	return ids
}

@(test)
agent_search_routes_to_local_merge :: proc(t: ^testing.T) {
	route := bridge_agent_route("agent.search", `{"query":"tunnel"}`)
	testing.expect_value(t, route.kind, Bridge_Agent_Route_Kind.Local)
	testing.expect_value(t, route.local_op, "search")
}

@(test)
agent_search_local_plan_only_for_unfiltered_first_page_chain_searches :: proc(t: ^testing.T) {
	Case :: struct { params: string, merge: bool, project_id: string, limit: int }
	cases := [?]Case{
		{`{"query":"tunnel"}`, true, "", AGENT_SEARCH_DEFAULT_LOCAL_LIMIT},
		{`{"query":"tunnel","scopes":"task,task-chain","limit":3}`, true, "", 3},
		{`{"query":"tunnel","limit":500}`, true, "", TASK_CHAIN_SEARCH_RPC_MAX_LIMIT},
		{`{"query":"tunnel","project_ids":"proj_1"}`, true, "proj_1", AGENT_SEARCH_DEFAULT_LOCAL_LIMIT},
		{`{"query":"tunnel","scopes":"task,conversation"}`, false, "", 0},
		{`{"query":"tunnel","cursor":"Y3Vyc29y"}`, false, "", 0},
		{`{"query":"tunnel","exclude":"draft"}`, false, "", 0},
		{`{"query":"tunnel","not_in_chain_ids":"chain_x"}`, false, "", 0},
		{`{"query":"tunnel","project_ids":"proj_1,proj_2"}`, false, "", 0},
		{`{"query":"t"}`, false, "", 0},
	}
	for c in cases {
		plan := bridge_agent_search_local_plan(c.params)
		defer agent_search_local_plan_destroy(plan)
		testing.expectf(t, plan.merge == c.merge, "%s: merge=%v want %v", c.params, plan.merge, c.merge)
		if !c.merge do continue
		testing.expect_value(t, plan.query, "tunnel")
		testing.expect_value(t, plan.project_id, c.project_id)
		testing.expect_value(t, plan.limit, c.limit)
	}
}

@(test)
agent_search_merge_prepends_local_hits_and_dedupes :: proc(t: ^testing.T) {
	hub := `{"data":{"groups":[{"type":"task","hits":[{"id":"task_1","label":"T","parent":null}]},{"type":"task-chain","hits":[{"id":"chain_plain","label":"Plain chain","score":0.8,"parent":null}]}]},"page":{"limit":10,"next_cursor":"","has_more":false}}`
	merged, ok := bridge_agent_search_merge(hub, agent_search_test_hits[:])
	defer delete(merged)
	testing.expect(t, ok)
	ids := agent_search_test_chain_ids(t, merged)
	testing.expect_value(t, len(ids), 2)
	if len(ids) == 2 {
		testing.expect_value(t, ids[0], "chain_secret")
		testing.expect_value(t, ids[1], "chain_plain")
	}
	parsed, _ := json.parse(transmute([]u8)merged, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	root := parsed.(json.Object)
	testing.expect_value(t, len(root["data"].(json.Object)["groups"].(json.Array)), 2)
	testing.expect(t, root["page"] != nil, "page must survive the merge")
	local := root["data"].(json.Object)["groups"].(json.Array)[1].(json.Object)["hits"].(json.Array)[0].(json.Object)
	testing.expect_value(t, local["label"].(json.String), "Preview tunnel hardening")
	testing.expect_value(t, local["route"].(json.String), "/chains/chain_secret")
	testing.expect_value(t, local["source"].(json.String), "bridge")
}

@(test)
agent_search_merge_creates_missing_chain_group :: proc(t: ^testing.T) {
	merged, ok := bridge_agent_search_merge(`{"data":{"groups":[]},"page":{"has_more":false}}`, agent_search_test_hits[:1])
	defer delete(merged)
	testing.expect(t, ok)
	ids := agent_search_test_chain_ids(t, merged)
	testing.expect_value(t, len(ids), 1)
	if len(ids) == 1 do testing.expect_value(t, ids[0], "chain_secret")
}

@(test)
agent_search_merge_leaves_hub_body_alone_when_nothing_to_add :: proc(t: ^testing.T) {
	already := `{"data":{"groups":[{"type":"task-chain","hits":[{"id":"chain_secret"}]}]}}`
	_, ok := bridge_agent_search_merge(already, agent_search_test_hits[:1])
	testing.expect(t, !ok, "every local hit was already present")
	_, ok = bridge_agent_search_merge(`{"data":{"groups":[]}}`, nil)
	testing.expect(t, !ok, "no local hits")
	_, ok = bridge_agent_search_merge(`not json`, agent_search_test_hits[:])
	testing.expect(t, !ok, "unexpected hub shape")
}
