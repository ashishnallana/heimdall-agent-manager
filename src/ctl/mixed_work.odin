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

CTL_MIXED_WORK_USAGE :: "usage: task-chain graph [<chain-id>]; depend [<chain-id>] --item task:ID|workflow_run:ID --on task:ID|workflow_run:ID; remove-dependency [<chain-id>] --dependency ID --reason TEXT; scope [<chain-id>] --item task:ID|workflow_run:ID --action include|exclude --reason TEXT; complete <chain-id> --expected-work-revision N --summary TEXT. graph/depend/remove-dependency/scope default to your chain; complete needs an explicit chain id (read work_revision from graph)."

// ctl_is_mixed_work_verb names the chain-level work-graph verbs shared by the
// user-mode and agent-mode task-chain dispatchers.
ctl_is_mixed_work_verb :: proc(verb: string) -> bool {
	switch verb {
	case "graph", "depend", "remove-dependency", "scope", "complete": return true
	}
	return false
}

ctl_mixed_work_agent_method :: proc(action: string) -> string {
	if action == "remove-dependency" do return "agent.work.remove_dependency"
	return fmt.tprintf("agent.work.%s", action)
}

// positional_chain carries the `task-chain <verb> <chain-id>` form; an explicit
// --chain/--chain-id wins. `complete` is destructive and never falls back to the
// caller's own chain. Authorization (owner or chain coordinator), chain status
// and the expected work_revision are enforced by the Hub on both transports.
ctl_mixed_work_command :: proc(transport: Ctl_Transport, action: string, args: []string, positional_chain := "") {
	cid := option_value(args, "--chain", option_value(args, "--chain-id", positional_chain))
	if cid == "" && action != "complete" do cid = resolve_chain_id(transport, args)
	params, ok := ctl_mixed_work_params(action, cid, args)
	if !ok || cid == "" do ctl_print_error_exit(CTL_MIXED_WORK_USAGE)
	if transport.kind == .Agent {
		ctl_agent_call_task(transport.agent_endpoint, transport.agent_token, ctl_mixed_work_agent_method(action), params, args)
		return
	}
	method := "GET" if action == "graph" else "POST"
	ctl_tasks_request_and_decrypt(transport, method, fmt.tprintf("/api/v1/task-chains/%s/work/%s", safe_path_part(cid), action), "" if action == "graph" else params, args)
}

ctl_print_error_exit :: proc(message: string) -> ! {
	fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("message", message)))
	os.exit(1)
}

Ctl_Depend_Target_Kind :: enum {
	Invalid,
	Task,
	Workflow_Run,
}

CTL_DEPEND_REF_HELP :: "accepted prerequisites are <task-id>, task:<task-id> or workflow_run:<run-id>. Workflow stage tasks are engine-managed: depend on the whole run (workflow_run:<run-id>). For any other pair use `ham-ctl task-chain depend --item <ref> --on <ref>`."

// ctl_task_depend_target classifies a `task depend --on` value. A bare id or
// task:<id> is a ticket prerequisite; workflow_run:<id> becomes a chain-level
// graph edge on the whole run. Any other typed ref fails here with guidance
// instead of reaching the Hub as a bogus task id (formerly a bare 404).
ctl_task_depend_target :: proc(value: string) -> (kind: Ctl_Depend_Target_Kind, id: string, message: string) {
	v := strings.trim_space(value)
	if v == "" do return .Invalid, "", strings.concatenate({"task depend requires --on <prerequisite>; ", CTL_DEPEND_REF_HELP}, context.temp_allocator)
	colon := strings.index(v, ":")
	if colon < 0 do return .Task, v, ""
	ref_kind, ref_id := v[:colon], strings.trim_space(v[colon + 1:])
	if ref_id == "" do return .Invalid, "", fmt.tprintf("prerequisite %q has no id; %s", v, CTL_DEPEND_REF_HELP)
	switch ref_kind {
	case "task": return .Task, ref_id, ""
	case "workflow_run": return .Workflow_Run, ref_id, ""
	}
	return .Invalid, "", fmt.tprintf("unsupported prerequisite kind %q in %q; %s", ref_kind, v, CTL_DEPEND_REF_HELP)
}

// ctl_task_depends_on_csv normalizes `task create/update --depends-on`: entries
// are ticket ids (task:<id> is accepted and stripped). Workflow-run and other
// typed refs are rejected with the command that does support them.
ctl_task_depends_on_csv :: proc(csv: string) -> (normalized: string, ok: bool, message: string) {
	parts := strings.split(csv, ",", context.temp_allocator)
	out := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for part in parts {
		p := strings.trim_space(part)
		if p == "" do continue
		kind, id, msg := ctl_task_depend_target(p)
		switch kind {
		case .Task:
			append(&out, id)
		case .Workflow_Run:
			return "", false, fmt.tprintf("--depends-on lists ticket prerequisites only; add the workflow run prerequisite with `ham-ctl task depend <task-id> --on %s` (a chain-level graph edge)", p)
		case .Invalid:
			return "", false, fmt.tprintf("--depends-on: %s", msg)
		}
	}
	return strings.join(out[:], ",", context.temp_allocator), true, ""
}

// ctl_task_depends_on_flag reads --depends-on (or the user-mode --on alias)
// through ctl_task_depends_on_csv, exiting with the actionable error.
ctl_task_depends_on_flag :: proc(args: []string, names: ..string) -> (value: string, present: bool) {
	for name in names {
		if !has_flag(args, name) do continue
		normalized, ok, msg := ctl_task_depends_on_csv(option_value(args, name, ""))
		if !ok do ctl_print_error_exit(msg)
		return normalized, true
	}
	return "", false
}

// ctl_task_depend_workflow_params builds the chain-level edge
// task:<task_id> -> workflow_run:<run_id>. An empty chain_id lets the Hub use
// the calling agent's chain.
ctl_task_depend_workflow_params :: proc(chain_id, task_id, run_id: string) -> string {
	fields := make([dynamic]string, context.temp_allocator)
	if chain_id != "" do append(&fields, json_kv("chain_id", chain_id))
	append(&fields,
		json_kv_raw("dependent", json_object(json_kv("kind", "task"), json_kv("id", task_id))),
		json_kv_raw("prerequisite", json_object(json_kv("kind", "workflow_run"), json_kv("id", run_id))))
	return json_object_from_slice(fields[:])
}
