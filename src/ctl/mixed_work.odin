package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

ctl_work_ref_json :: proc(value: string) -> (string, bool) {
	colon := strings.index(value, ":")
	if colon <= 0 || colon + 1 >= len(value) do return "", false
	kind, id := value[:colon], value[colon + 1:]
	if kind != "task" && kind != "workflow_run" do return "", false
	return json_object(json_kv("kind", kind), json_kv("id", id)), true
}

// One parser is used by direct user requests and agent Bridge envelopes.
ctl_mixed_work_params :: proc(action, chain_id: string, args: []string) -> (string, bool) {
	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, json_kv("chain_id", chain_id))
	switch action {
	case "graph":
	case "depend":
		dependent, dok := ctl_work_ref_json(option_value(args, "--item", ""))
		prerequisite, pok := ctl_work_ref_json(option_value(args, "--on", ""))
		if !dok || !pok do return "", false
		append(&fields, json_kv_raw("dependent", dependent), json_kv_raw("prerequisite", prerequisite))
	case "remove-dependency":
		id, reason := option_value(args, "--dependency", ""), strings.trim_space(option_value(args, "--reason", ""))
		if id == "" || reason == "" do return "", false
		append(&fields, json_kv("dependency_id", id), json_kv("reason", reason))
	case "scope":
		item, ok := ctl_work_ref_json(option_value(args, "--item", ""))
		decision, reason := option_value(args, "--action", ""), strings.trim_space(option_value(args, "--reason", ""))
		if !ok || (decision != "include" && decision != "exclude") || reason == "" do return "", false
		append(&fields, json_kv_raw("item", item), json_kv("action", decision), json_kv("reason", reason))
	case "complete":
		revision := option_value(args, "--expected-work-revision", "")
		n, parsed := strconv.parse_int(revision)
		summary := strings.trim_space(option_value(args, "--summary", ""))
		if !parsed || n < 0 || summary == "" do return "", false
		append(&fields, json_kv_raw("expected_work_revision", revision), json_kv("summary", summary))
	case:
		return "", false
	}
	return json_object_from_slice(fields[:]), true
}

ctl_mixed_work_command :: proc(transport: Ctl_Transport, action: string, args: []string) {
	cid := option_value(args, "--chain", "")
	if cid == "" && action != "complete" do cid = resolve_chain_id(transport, args)
	params, ok := ctl_mixed_work_params(action, cid, args)
	if !ok || cid == "" {
		fmt.println(`{"ok":false,"message":"use task-chains graph --chain ID; depend --item task:ID|workflow_run:ID --on task:ID|workflow_run:ID; remove-dependency --dependency ID --reason TEXT; scope --item REF --action include|exclude --reason TEXT; complete --chain ID --expected-work-revision N --summary TEXT"}`)
		os.exit(1)
	}
	if transport.kind == .Agent {
		method := "agent.work.remove_dependency" if action == "remove-dependency" else fmt.tprintf("agent.work.%s", action)
		ctl_agent_call_task(transport.agent_endpoint, transport.agent_token, method, params, args)
		return
	}
	method := "GET" if action == "graph" else "POST"
	ctl_tasks_request_and_decrypt(transport, method, fmt.tprintf("/api/v1/task-chains/%s/work/%s", safe_path_part(cid), action), "" if action == "graph" else params, args)
}
