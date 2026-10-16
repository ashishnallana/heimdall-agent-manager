package main

// ── Task System v2 (M2): brief flags, lease verbs, review, fetch, verify ──────
//
// Everything here talks to the local Bridge endpoint over the same JSONL client
// the rest of agent mode uses (ctl_agent_local_call). The hub contract is the
// M2 wire contract:
//
//   agent.lease.submit   {lease_id?, summary, handoff?, output?, verify?:"none"}   (bridge adds vcs)
//   agent.lease.handoff  {lease_id?, summary, handoff?}                            (bridge adds vcs)
//   agent.lease.block    {lease_id?, waiting_on:{kind, ref?, reason}, summary?}
//   agent.review.post    {task_id?, verdict: approve|request_changes, findings?}
//   agent.task.fetch     {task_id, ref}   ref = "#<event_id>" | "facet:<task>:<attempt>:<kind>"
//
// `ham-ctl verify` runs the task brief's verify command as a Run shell session
// labelled `verify <task_id> #<attempt_no> @<head>`; the hub attributes the exit
// (and the bridge's vcs/tail enrichment of it) to the attempt by that label.
//
// The lease verbs also send `cwd` (ham-ctl's own working directory, which is the
// agent's) so the bridge can find the repository for its vcs enrichment; the hub
// ignores the key.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import vcs "odin_test:lib/vcs"

// ---- brief ------------------------------------------------------------------

// ctl_collect_repeated gathers every value of the named flags WITHOUT splitting
// on commas (acceptance criteria are prose and legitimately contain commas).
// Blank values are skipped. Caller owns the result.
ctl_collect_repeated :: proc(args: []string, names: ..string) -> [dynamic]string {
	out := make([dynamic]string)
	for i := 0; i + 1 < len(args); i += 1 {
		matched := false
		for name in names { if args[i] == name { matched = true; break } }
		if !matched do continue
		v := strings.trim_space(args[i + 1])
		if v != "" do append(&out, v)
	}
	return out
}

// ctl_task_brief_flags_present reports whether any brief flag was given, so
// `task update` without them does not send an (empty) brief.
ctl_task_brief_flags_present :: proc(args: []string) -> bool {
	for f in ([?]string{"--goal", "--acceptance", "--verify", "--input", "--inputs", "--review-role", "--review-roles", "--auto-submit", "--brief-file"}) {
		if has_flag(args, f) do return true
	}
	return false
}

// ctl_task_brief_json builds the `brief` object from an optional --brief-file
// body (the base) and the brief flags (which override the file's fields).
// Pure: the file's text is passed in. Returns ("", false) when there is nothing
// to send. Only the brief keys the hub documents are carried from the file
// (goal, acceptance, verify, inputs, review_roles, assignee, budget, output,
// auto_submit); flags win field by field.
ctl_task_brief_json :: proc(args: []string, brief_file_text: string) -> (string, bool) {
	file := strings.trim_space(brief_file_text)
	fields := make([dynamic]string)
	defer delete(fields)

	goal := option_value(args, "--goal", "")
	if goal == "" && file != "" do goal = extract_json_string_unescaped(file, "goal", "", context.temp_allocator)
	if goal != "" do append(&fields, json_kv("goal", goal))

	acceptance := ctl_collect_repeated(args, "--acceptance")
	defer delete(acceptance)
	if len(acceptance) > 0 {
		append(&fields, json_string_array_field("acceptance", acceptance[:]))
	} else if file != "" {
		if raw, ok := ctl_extract_json_array_raw(file, "acceptance"); ok do append(&fields, json_kv_raw("acceptance", raw))
	}

	verify := option_value(args, "--verify", "")
	if verify == "" && file != "" do verify = extract_json_string_unescaped(file, "verify", "", context.temp_allocator)
	if verify != "" do append(&fields, json_kv("verify", verify))

	inputs := collect_multi_values(args, "--input", "--inputs")
	defer delete(inputs)
	if len(inputs) > 0 {
		append(&fields, json_string_array_field("inputs", inputs[:]))
	} else if file != "" {
		if raw, ok := ctl_extract_json_array_raw(file, "inputs"); ok do append(&fields, json_kv_raw("inputs", raw))
	}

	roles := collect_multi_values(args, "--review-role", "--review-roles")
	defer delete(roles)
	if len(roles) > 0 {
		append(&fields, json_string_array_field("review_roles", roles[:]))
	} else if file != "" {
		if raw, ok := ctl_extract_json_array_raw(file, "review_roles"); ok do append(&fields, json_kv_raw("review_roles", raw))
	}

	if has_flag(args, "--auto-submit") {
		append(&fields, `"auto_submit":true`)
	} else if file != "" {
		if v, ok := ctl_extract_json_bool_raw(file, "auto_submit"); ok do append(&fields, json_kv_raw("auto_submit", "true" if v else "false"))
	}

	if file != "" {
		if a := extract_json_string_unescaped(file, "assignee", "", context.temp_allocator); a != "" do append(&fields, json_kv("assignee", a))
		if raw, ok := extract_json_object_raw(file, "budget", context.temp_allocator); ok do append(&fields, json_kv_raw("budget", raw))
		if raw, ok := extract_json_object_raw(file, "output", context.temp_allocator); ok do append(&fields, json_kv_raw("output", raw))
	}

	if len(fields) == 0 do return "", false
	return json_object_from_slice(fields[:]), true
}

// ctl_task_brief_field returns the `"brief":{...}` field for create/update from
// the flags and --brief-file, or ("", false) when no brief was given. Exits 1
// when --brief-file cannot be read or is not a JSON object.
ctl_task_brief_field :: proc(args: []string) -> (string, bool) {
	file_text := ""
	if path := option_value(args, "--brief-file", ""); path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.printfln(`{"ok":false,"message":"--brief-file %s: cannot read"}`, path)
			os.exit(1)
		}
		file_text = string(data)
		if t := strings.trim_space(file_text); t == "" || t[0] != '{' {
			fmt.printfln(`{"ok":false,"message":"--brief-file %s: must contain a JSON object"}`, path)
			os.exit(1)
		}
	} else if !ctl_task_brief_flags_present(args) {
		return "", false
	}
	brief, ok := ctl_task_brief_json(args, file_text)
	if !ok do return "", false
	return json_kv_raw("brief", brief), true
}

// ctl_extract_json_array_raw returns the raw `[...]` text of a top-level array
// member (string-aware; "" / false when absent or not an array).
ctl_extract_json_array_raw :: proc(body, key: string) -> (string, bool) {
	probe := strings.concatenate({"\"", key, "\""}, context.temp_allocator)
	idx := strings.index(body, probe)
	if idx < 0 do return "", false
	rest := body[idx + len(probe):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return "", false
	rest = strings.trim_left_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '[' do return "", false
	depth := 0
	in_str := false
	esc := false
	for i := 0; i < len(rest); i += 1 {
		ch := rest[i]
		if in_str {
			if esc { esc = false; continue }
			if ch == '\\' { esc = true; continue }
			if ch == '"' do in_str = false
			continue
		}
		if ch == '"' { in_str = true; continue }
		if ch == '[' do depth += 1
		if ch == ']' { depth -= 1; if depth == 0 do return rest[:i + 1], true }
	}
	return "", false
}

ctl_extract_json_bool_raw :: proc(body, key: string) -> (bool, bool) {
	probe := strings.concatenate({"\"", key, "\""}, context.temp_allocator)
	idx := strings.index(body, probe)
	if idx < 0 do return false, false
	rest := body[idx + len(probe):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return false, false
	rest = strings.trim_left_space(rest[colon + 1:])
	if strings.has_prefix(rest, "true") do return true, true
	if strings.has_prefix(rest, "false") do return false, true
	return false, false
}

// ---- publish: brief_incomplete rendering -------------------------------------

// ctl_brief_incomplete_render turns a publish refusal into a per-task list of
// missing brief fields. Accepts BOTH envelopes: the agent-mode one, where the
// bridge wraps the hub's error body as a JSON string in `error.message`, and the
// user-mode one, where the hub body is the response itself. Pure. Returns
// ("", false) when the response is not a brief_incomplete 422.
ctl_brief_incomplete_render :: proc(response: string) -> (string, bool) {
	if !strings.contains(response, "brief_incomplete") do return "", false
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return "", false
	root, is_obj := parsed.(json.Object)
	if !is_obj do return "", false

	hub := root
	if e, has := root["error"].(json.Object); has {
		if msg, is_str := e["message"].(json.String); is_str && strings.contains(string(msg), "brief_incomplete") {
			inner, ierr := json.parse(transmute([]byte)string(msg), json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
			if ierr == nil {
				if io, ok := inner.(json.Object); ok do hub = io
			}
		}
	}
	err_obj, has_err := hub["error"].(json.Object)
	if !has_err do return "", false
	details, has_details := err_obj["details"].(json.Object)
	if !has_details do return "", false
	if code, ok := details["code"].(json.String); !ok || string(code) != "brief_incomplete" do return "", false

	b := strings.builder_make()
	strings.write_string(&b, "publish refused: brief incomplete\n")
	if tasks, ok := details["tasks"].(json.Array); ok {
		for t in tasks {
			to, tok := t.(json.Object)
			if !tok do continue
			tid := ""
			if v, sok := to["task_id"].(json.String); sok do tid = string(v)
			strings.write_string(&b, "  ")
			strings.write_string(&b, tid)
			strings.write_string(&b, ": missing ")
			if missing, mok := to["missing"].(json.Array); mok {
				for m, i in missing {
					if i > 0 do strings.write_string(&b, ", ")
					if ms, msok := m.(json.String); msok do strings.write_string(&b, string(ms))
				}
			}
			strings.write_byte(&b, '\n')
		}
	}
	strings.write_string(&b, "rules: goal (≤2000 chars); 1..20 acceptance items (≤200 chars each); verify command (or \"none\" with an output contract); every review_role needs a fleet row carrying that role.\n")
	return strings.to_string(b), true
}

// ctl_publish_print_and_exit prints the response; a brief_incomplete refusal is
// rendered readably (then the raw envelope) and exits 1.
ctl_publish_print_and_exit :: proc(response: string) {
	if text, found := ctl_brief_incomplete_render(response); found {
		fmt.print(text)
		fmt.println(response)
		os.exit(1)
	}
	fmt.println(response)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

// ctl_v2_task_publish publishes ONE task (coordinator only). The hub route is
// chain-scoped, so the chain is taken from --chain, else this agent's own chain
// (context), else the task itself (task show).
ctl_v2_task_publish :: proc(endpoint, token, tid: string, args: []string) {
	chain_id := option_value(args, "--chain", "")
	if chain_id == "" {
		if res, ok := ctl_agent_local_call(endpoint, token, "agent.task.show", json_object(json_kv("task_id", tid))); ok {
			chain_id = extract_json_string_unescaped(res, "chain_id", "", context.temp_allocator)
		}
	}
	if chain_id == "" {
		if res, ok := ctl_agent_local_call(endpoint, token, "agent.context.get", "{}"); ok {
			chain_id = extract_json_string_unescaped(res, "chain_id", "", context.temp_allocator)
		}
	}
	if chain_id == "" {
		fmt.println(`{"ok":false,"message":"task publish could not resolve the task's chain; pass --chain <id>"}`)
		os.exit(1)
	}
	params := json_object(
		json_kv("http_method", "POST"),
		json_kv("path", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/publish", safe_path_part(chain_id), safe_path_part(tid))),
		json_kv("body", "{}"),
	)
	response, ok := ctl_agent_local_call(endpoint, token, "agent.rest.request", params)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	ctl_publish_print_and_exit(response)
}

// ---- lease verbs --------------------------------------------------------------

// ctl_read_json_file_flag reads `--<flag> <path>` and returns the file's JSON
// text (validated to parse). Exits 1 on a missing/invalid file. ("", false)
// when the flag is absent.
ctl_read_json_file_flag :: proc(args: []string, flag: string) -> (string, bool) {
	path := option_value(args, flag, "")
	if path == "" do return "", false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.printfln(`{"ok":false,"message":"%s %s: cannot read"}`, flag, path)
		os.exit(1)
	}
	text := strings.trim_space(string(data))
	parsed, perr := json.parse(transmute([]byte)text, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		fmt.printfln(`{"ok":false,"message":"%s %s: not valid JSON"}`, flag, path)
		os.exit(1)
	}
	_ = parsed
	return text, true
}

// ctl_agent_cwd returns ham-ctl's working directory — the agent's cwd, since
// ham-ctl runs as the agent's child ("" when unavailable).
ctl_agent_cwd :: proc(allocator := context.temp_allocator) -> string {
	cwd, err := os.get_working_directory(allocator)
	if err != nil do return ""
	return cwd
}

ctl_agent_cwd_field :: proc() -> string {
	return json_kv("cwd", ctl_agent_cwd())
}

ctl_v2_lease_submit :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease submit requires --summary <text>"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_read_json_file_flag(args, "--handoff-file"); ok do append(&fields, json_kv_raw("handoff", h))
	if o, ok := ctl_read_json_file_flag(args, "--output-file"); ok do append(&fields, json_kv_raw("output", o))
	if v := strings.trim_space(option_value(args, "--verify", "")); v != "" {
		if v != "none" { fmt.println(`{"ok":false,"message":"lease submit --verify accepts only 'none' (skip the verify gate for tasks with an output contract)"}`); os.exit(1) }
		append(&fields, json_kv("verify", "none"))
	}
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	append(&fields, ctl_agent_cwd_field())
	ctl_agent_call_task(endpoint, token, "agent.lease.submit", json_object_from_slice(fields[:]), args)
}

ctl_v2_lease_handoff :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease handoff requires --summary <text>"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_read_json_file_flag(args, "--handoff-file"); ok do append(&fields, json_kv_raw("handoff", h))
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	append(&fields, ctl_agent_cwd_field())
	ctl_agent_call_task(endpoint, token, "agent.lease.handoff", json_object_from_slice(fields[:]), args)
}

ctl_v2_lease_block :: proc(endpoint, token: string, args: []string) {
	kind := strings.trim_space(option_value(args, "--waiting-on", ""))
	reason := strings.trim_space(option_value(args, "--reason", ""))
	if kind == "" || reason == "" { fmt.println(`{"ok":false,"message":"lease block requires --waiting-on <kind> and --reason <text> [--ref <id>] [--summary <text>]"}`); os.exit(1) }
	wo := make([dynamic]string)
	defer delete(wo)
	append(&wo, json_kv("kind", kind))
	if v := option_value(args, "--ref", ""); v != "" do append(&wo, json_kv("ref", v))
	append(&wo, json_kv("reason", reason))
	fields := make([dynamic]string)
	defer delete(fields)
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	append(&fields, json_kv_raw("waiting_on", json_object_from_slice(wo[:])))
	if v := option_value(args, "--summary", ""); v != "" do append(&fields, json_kv("summary", v))
	ctl_agent_call_task(endpoint, token, "agent.lease.block", json_object_from_slice(fields[:]), args)
}

// ---- review ---------------------------------------------------------------------

ctl_v2_review :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "post":
		verdict := strings.trim_space(option_value(args, "--verdict", ""))
		if verdict != "approve" && verdict != "request_changes" {
			fmt.println(`{"ok":false,"message":"review post requires --verdict approve|request_changes [--findings-file <json>] [--task <id>]"}`)
			os.exit(1)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		if v := option_value(args, "--task", pos(tokens, 1)); v != "" do append(&fields, json_kv("task_id", v))
		append(&fields, json_kv("verdict", verdict))
		if f, ok := ctl_read_json_file_flag(args, "--findings-file"); ok do append(&fields, json_kv_raw("findings", f))
		ctl_agent_call_task(endpoint, token, "agent.review.post", json_object_from_slice(fields[:]), args)
	case:
		print_help_review()
	}
}

// ---- task fetch ------------------------------------------------------------------

ctl_v2_task_fetch :: proc(endpoint, token: string, tokens, args: []string) {
	tid := pos(tokens, 1)
	ref := pos(tokens, 2)
	if ref == "" do ref = option_value(args, "--ref", "")
	if tid == "" || ref == "" {
		fmt.println(`{"ok":false,"message":"task fetch requires <task_id> <ref>; ref is #<event_id> or facet:<task_id>:<attempt_no>:<kind>"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task.fetch", json_object(json_kv("task_id", tid), json_kv("ref", ref)), args)
}

// ---- verify -----------------------------------------------------------------------

CTL_VERIFY_WAIT_SLICE_MS :: 300_000

// Ctl_Verify_Lease is what `verify` needs from `lease next`.
Ctl_Verify_Lease :: struct {
	status:     string,
	task_id:    string,
	attempt_no: int,
	verify_cmd: string,
}

// ctl_verify_parse_lease reads status / task_id / attempt_no / brief.verify out
// of a lease.next response (any envelope depth). Pure.
ctl_verify_parse_lease :: proc(response: string) -> (Ctl_Verify_Lease, bool) {
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return {}, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}, false
	node := obj
	for _ in 0 ..< 5 {
		if _, has := node["lease"]; has do break
		if _, has := node["task"]; has do break
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	out: Ctl_Verify_Lease
	if v, ok := node["status"].(json.String); ok do out.status = strings.clone(string(v))
	if lease, ok := node["lease"].(json.Object); ok {
		if n, nok := lease["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
		if n, nok := lease["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		if t, tok := lease["task_id"].(json.String); tok do out.task_id = strings.clone(string(t))
	}
	if task, ok := node["task"].(json.Object); ok {
		if t, tok := task["task_id"].(json.String); tok && out.task_id == "" do out.task_id = strings.clone(string(t))
		if out.attempt_no == 0 {
			if n, nok := task["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
			if n, nok := task["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		}
		if brief, bok := task["brief"].(json.Object); bok {
			if v, vok := brief["verify"].(json.String); vok do out.verify_cmd = strings.clone(string(v))
		}
	}
	return out, out.task_id != ""
}

// ctl_verify_label is the exact label the hub attributes a verify exit by:
// `verify <task_id> #<attempt_no> @<head>` (head may be empty -> "@").
ctl_verify_label :: proc(task_id: string, attempt_no: int, head: string) -> string {
	return fmt.aprintf("verify %s #%d @%s", task_id, attempt_no, head)
}

// Ctl_Verify_Wait is one agent.shell.wait answer reduced to what verify acts on.
Ctl_Verify_Wait :: struct {
	ok:        bool,
	timed_out: bool,
	finished:  bool,
	status:    string,
	exit_code: int,
	has_code:  bool,
	output:    string,
}

ctl_verify_parse_wait :: proc(response: string) -> Ctl_Verify_Wait {
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return {}
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}
	if okv, has := obj["ok"].(json.Boolean); has && !bool(okv) do return {}
	node := obj
	for _ in 0 ..< 4 {
		if _, has := node["session_id"]; has do break
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	w := Ctl_Verify_Wait{ok = true}
	if v, ok := node["timed_out"].(json.Boolean); ok && bool(v) { w.timed_out = true; return w }
	if v, ok := node["status"].(json.String); ok do w.status = strings.clone(string(v))
	if n, ok := node["exit_code"].(json.Float); ok { w.exit_code = int(n); w.has_code = true }
	if n, ok := node["exit_code"].(json.Integer); ok { w.exit_code = int(n); w.has_code = true }
	if v, ok := node["output"].(json.String); ok do w.output = strings.clone(string(v))
	w.finished = w.status != "" && w.status != "running" && w.status != "starting"
	return w
}

ctl_v2_verify :: proc(endpoint, token: string, tokens, args: []string) {
	if pos(tokens, 0) == "help" || has_flag(args, "--help") || has_flag(args, "-h") { print_help_verify(); return }
	independent := has_flag(args, "--independent")
	cwd := ctl_agent_cwd(context.allocator)

	// 1. the lease (status current) carries the task + brief.verify.
	//    peek:true ensures `ham-ctl verify` inspects an existing lease without
	//    implicitly claiming a new ready task.
	lease_resp, lok := ctl_agent_local_call(endpoint, token, "agent.lease.next", json_object(json_kv("cwd", cwd), json_kv_raw("peek", "true")))
	if !lok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	lease, parsed := ctl_verify_parse_lease(lease_resp)
	if !parsed || (lease.status != "current" && lease.status != "granted") {
		fmt.println(`{"ok":false,"message":"verify: you hold no lease (lease next did not return a current task)"}`)
		fmt.println(lease_resp)
		os.exit(1)
	}
	if has_flag(args, "--cmd") {
		fmt.println(`{"ok":false,"message":"verify: --cmd is not supported; verify always runs brief.verify from your current task"}`)
		os.exit(1)
	}
	verify_cmd := strings.trim_space(lease.verify_cmd)
	if verify_cmd == "" {
		fmt.printfln(`{"ok":false,"message":"verify: task %s has no brief.verify command; update the brief first"}`, lease.task_id)
		os.exit(1)
	}
	if verify_cmd == "none" {
		fmt.printfln(`{"ok":true,"task_id":"%s","verify":"none","message":"brief.verify is none: nothing to run; submit with --verify none"}`, lease.task_id)
		return
	}

	// 2. head of cwd ("" when not a repo).
	head := ""
	if sha, ok, _ := vcs.git_repo_head_sha(cwd); ok do head = sha

	// 3. start the Run session with the attributable label.
	label := ctl_verify_label(lease.task_id, lease.attempt_no, head)
	ctx, ctx_ok := ctl_shell_context(endpoint, token)
	bridge_id := option_value(args, "--bridge", ctx.bridge_id)
	if bridge_id == "" || !ctx_ok {
		fmt.println(`{"ok":false,"message":"verify could not resolve your bridge/agent instance; pass --bridge <bridge_id>"}`)
		os.exit(1)
	}
	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, json_kv("kind", "run"))
	append(&fields, json_kv("cmd", verify_cmd))
	append(&fields, json_kv("agent_instance_id", ctx.agent_instance_id))
	if ctx.conversation_id != "" do append(&fields, json_kv("conversation_id", ctx.conversation_id))
	if v := option_value(args, "--project", ctx.project_id); v != "" do append(&fields, json_kv("project_id", v))
	append(&fields, json_kv("cwd", cwd))
	append(&fields, json_kv("label", label))
	ctl_shell_attach_enc_spec(args, verify_cmd, cwd, &fields)
	create_resp, cok := ctl_agent_local_call(endpoint, token, "agent.rest.request", json_object(
		json_kv("http_method", "POST"),
		json_kv("path", fmt.tprintf("/api/v1/bridges/%s/shells", safe_path_part(bridge_id))),
		json_kv("body", json_object_from_slice(fields[:])),
	))
	if !cok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	session_id := ctl_shell_session_id_from_response(create_resp)
	if session_id == "" {
		fmt.println(create_resp)
		os.exit(1)
	}
	fmt.printfln("verify: task %s attempt #%d session %s head %s", lease.task_id, lease.attempt_no, session_id, head if head != "" else "(no repo)")
	fmt.printfln("verify: $ %s", verify_cmd)
	if independent do fmt.println("verify: --independent stored (no effect yet)")

	// 4. wait in ≤300 s slices, heartbeating between slices so the lease TTL
	//    cannot expire under a long verify.
	call_fn :: proc(ctx: rawptr, method, params_json: string) -> (string, bool) {
		pair := (^([2]string))(ctx)
		return ctl_agent_local_call(pair[0], pair[1], method, params_json)
	}
	pair := [2]string{endpoint, token}
	w, wait_err := ctl_verify_wait_with_heartbeats(session_id, CTL_VERIFY_WAIT_SLICE_MS, &pair, call_fn)
	if wait_err != "" {
		fmt.println(wait_err)
		os.exit(1)
	}
	// 5. print the log tail and exit with the run's code.
	if w.output != "" {
		fmt.print(w.output)
		if !strings.has_suffix(w.output, "\n") do fmt.println()
	}
	code := w.exit_code if w.has_code else 1
	fmt.printfln("verify: %s exit %d (session %s)", w.status, code, session_id)
	os.exit(code)
}

ctl_verify_wait_with_heartbeats :: proc(
	session_id: string,
	slice_ms: int,
	ctx: rawptr,
	call: proc(ctx: rawptr, method, params_json: string) -> (string, bool),
) -> (Ctl_Verify_Wait, string) {
	first := true
	for {
		wait_resp, wok := call(ctx, "agent.shell.wait", json_object(
			json_kv("session_id", session_id),
			json_kv_raw("timeout_ms", fmt.tprintf("%d", slice_ms)),
		))
		if !wok do return {}, `{"ok":false,"message":"local Bridge endpoint is not reachable while waiting on the verify run"}`
		w := ctl_verify_parse_wait(wait_resp)
		if !w.ok do return {}, wait_resp
		if w.timed_out {
			hb := "{}"
			if first do hb = json_object(json_kv("note", "verify running"))
			first = false
			_, _ = call(ctx, "agent.lease.heartbeat", hb)
			continue
		}
		if !w.finished do return {}, wait_resp
		return w, ""
	}
}

// ---- help ------------------------------------------------------------------------

print_help_review :: proc() {
	fmt.println("ham-ctl review — post a review verdict on the task you were woken to review")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  post --verdict approve|request_changes [--findings-file <json>] [--task <id>]")
	fmt.println("      Record your verdict. --task defaults to the task your lease names. The")
	fmt.println("      findings file is a JSON array of {path?, line?, severity?, text}.")
	fmt.println("      Response: {gate: waiting|approved|changes_requested, task}.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl review post --verdict approve")
	fmt.println("  ham-ctl review post --verdict request_changes --findings-file findings.json")
}

print_help_verify :: proc() {
	fmt.println("ham-ctl verify — run your task's verify command as an attributable Run session")
	fmt.println("")
	fmt.println("  ham-ctl verify [--independent] [--bridge <id>]")
	fmt.println("")
	fmt.println("Reads brief.verify from your current lease, runs it in your cwd as a shell Run")
	fmt.println("labelled `verify <task_id> #<attempt_no> @<head>`, heartbeats your lease while it")
	fmt.println("runs, prints the log tail and exits with the run's exit code. The hub records the")
	fmt.println("exit (plus repo head/dirty state) as the attempt's verify facet; `lease submit`")
	fmt.println("requires a passing verify at the current head unless the brief says verify: none.")
	fmt.println("  --independent   accepted and stored only (no effect yet).")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl verify")
	fmt.println("  ham-ctl verify && ham-ctl lease submit --summary 'tests green'")
}
