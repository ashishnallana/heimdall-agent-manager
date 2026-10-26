package main

// SRCH-2: agent.search merges this bridge's decrypted task-chain hits.
//
// The hub's search FTS only ever holds ciphertext for vault-encrypted chains, so
// relaying agent.search to it can never match their titles. The bridge already
// keeps a decrypted in-memory index of the owner's chain titles/descriptions
// (task_chain_search_index.odin) for the UI relay; this file lets agents use it
// too. The hub relay stays the source of truth: its body is returned untouched
// unless the request is one the local index can answer exactly (first page,
// task-chain in scope, no filters the index cannot apply).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"

AGENT_SEARCH_DEFAULT_LOCAL_LIMIT :: 10
AGENT_SEARCH_LOCAL_SCORE :: 0.9

// Filters the hub applies that the local chain index cannot reproduce. When any
// is set, merging local hits would return chains the caller filtered out.
@(private = "file")
agent_search_unsupported_filters := [?]string{
	"task_ids", "chain_ids", "conversation_ids",
	"not_in_task_ids", "not_in_chain_ids", "not_in_project_ids", "not_in_conversation_ids",
	"exclude",
}

Agent_Search_Local_Plan :: struct {
	merge:      bool,
	query:      string,
	project_id: string,
	limit:      int,
}

// bridge_agent_search_local_plan decides (purely, from the agent params) whether
// and how to query the local chain index. Strings are allocated with `allocator`.
bridge_agent_search_local_plan :: proc(params: string, allocator := context.allocator) -> Agent_Search_Local_Plan {
	plan: Agent_Search_Local_Plan
	if strings.trim_space(jsonx.extract_string(params, "cursor", "", true, context.temp_allocator)) != "" do return plan
	scopes := strings.trim_space(jsonx.extract_string(params, "scopes", "", true, context.temp_allocator))
	if scopes != "" {
		wants_chains := false
		for scope in strings.split(scopes, ",", context.temp_allocator) {
			if strings.trim_space(scope) == "task-chain" { wants_chains = true; break }
		}
		if !wants_chains do return plan
	}
	for key in agent_search_unsupported_filters {
		if strings.trim_space(jsonx.extract_string(params, key, "", true, context.temp_allocator)) != "" do return plan
	}
	project_ids := strings.trim_space(jsonx.extract_string(params, "project_ids", "", true, context.temp_allocator))
	if strings.contains(project_ids, ",") do return plan
	query := strings.trim_space(jsonx.extract_string(params, "query", "", true, context.temp_allocator))
	if len(query) < 2 do return plan
	limit, limit_ok := jsonx.extract_int_found(params, "limit", true)
	if !limit_ok || limit <= 0 do limit = AGENT_SEARCH_DEFAULT_LOCAL_LIMIT
	if limit > TASK_CHAIN_SEARCH_RPC_MAX_LIMIT do limit = TASK_CHAIN_SEARCH_RPC_MAX_LIMIT
	return Agent_Search_Local_Plan{
		merge = true,
		query = strings.clone(query, allocator),
		project_id = strings.clone(project_ids, allocator),
		limit = limit,
	}
}

agent_search_local_plan_destroy :: proc(plan: Agent_Search_Local_Plan, allocator := context.allocator) {
	delete(plan.query, allocator)
	delete(plan.project_id, allocator)
}

// bridge_agent_search_merge splices local chain hits into the hub's search body
// ({"data":{"groups":[{"type","hits":[…]}]},"page":…}). Local hits go first in the
// task-chain group (created when absent); chains the hub already returned are
// skipped. Returns (merged body, true), or ("", false) when the body is not the
// expected shape, in which case the caller must return the hub body unchanged.
bridge_agent_search_merge :: proc(hub_body: string, hits: []Task_Chain_Search_Hit, allocator := context.allocator) -> (string, bool) {
	if len(hits) == 0 do return "", false
	ta := context.temp_allocator
	parsed, err := json.parse(transmute([]u8)hub_body, json.DEFAULT_SPECIFICATION, true, ta)
	if err != .None do return "", false
	root, root_ok := parsed.(json.Object)
	if !root_ok do return "", false
	data, data_ok := root["data"].(json.Object)
	if !data_ok do return "", false
	groups: json.Array
	if existing, has_groups := data["groups"]; has_groups {
		arr, arr_ok := existing.(json.Array)
		if !arr_ok do return "", false
		groups = arr
	} else {
		groups = make(json.Array, ta)
	}

	chain_group := -1
	for group, i in groups {
		obj, ok := group.(json.Object)
		if !ok do continue
		if kind, _ := obj["type"].(json.String); kind == "task-chain" { chain_group = i; break }
	}
	existing_hits: json.Array
	if chain_group >= 0 {
		if arr, ok := groups[chain_group].(json.Object)["hits"].(json.Array); ok do existing_hits = arr
	}
	seen := make(map[string]bool, allocator = ta)
	for hit in existing_hits {
		obj, ok := hit.(json.Object)
		if !ok do continue
		if id, id_ok := obj["id"].(json.String); id_ok do seen[id] = true
	}

	merged := make(json.Array, ta)
	for hit in hits {
		if seen[hit.chain_id] do continue
		seen[hit.chain_id] = true
		append(&merged, agent_search_local_hit_value(hit, ta))
	}
	if len(merged) == 0 do return "", false
	for hit in existing_hits do append(&merged, hit)

	if chain_group >= 0 {
		group := groups[chain_group].(json.Object)
		group["hits"] = merged
		groups[chain_group] = group
	} else {
		group := make(json.Object, allocator = ta)
		group["type"] = json.String("task-chain")
		group["hits"] = merged
		inject_at(&groups, 0, json.Value(group))
	}
	data["groups"] = groups
	root["data"] = data

	out, merr := json.marshal(json.Value(root), json.Marshal_Options{}, allocator)
	if merr != nil do return "", false
	return string(out), true
}

@(private = "file")
agent_search_local_hit_value :: proc(hit: Task_Chain_Search_Hit, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator = allocator)
	obj["id"] = json.String(hit.chain_id)
	obj["label"] = json.String(hit.title)
	obj["sublabel"] = json.String(fmt.aprintf("task_chain · %s", hit.status, allocator = allocator))
	obj["score"] = json.Float(AGENT_SEARCH_LOCAL_SCORE)
	obj["route"] = json.String(fmt.aprintf("/chains/%s", hit.chain_id, allocator = allocator))
	obj["parent"] = json.Null{}
	preview := hit.description_snippet if strings.trim_space(hit.description_snippet) != "" else hit.title
	obj["preview"] = json.String(preview)
	obj["matched_field"] = json.String("label")
	obj["source"] = json.String("bridge")
	return obj
}

// bridge_agent_search_rpc fulfils agent.search: relay to the hub (unchanged
// behaviour and errors), then merge local decrypted chain hits when applicable.
bridge_agent_search_rpc :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
	relay := bridge_local_relay_agent_envelope(route_path("api", "v1", "agent-actions", "search"), "agent.search", params, rec)
	if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
	if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
	if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")

	plan := bridge_agent_search_local_plan(params)
	defer agent_search_local_plan_destroy(plan)
	if !plan.merge do return bridge_local_response_data(request_id, relay.body)
	hits, queried, _, _ := bridge_task_chain_search_query(plan.query, plan.project_id, "", plan.limit)
	defer task_chain_search_hits_destroy(hits)
	if !queried do return bridge_local_response_data(request_id, relay.body)
	merged, merged_ok := bridge_agent_search_merge(relay.body, hits)
	if !merged_ok do return bridge_local_response_data(request_id, relay.body)
	defer delete(merged)
	return bridge_local_response_data(request_id, merged)
}
