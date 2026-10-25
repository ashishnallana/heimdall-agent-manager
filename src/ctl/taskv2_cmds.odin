package main

// ── Task System v2 (M2): brief flags, lease verbs, review, fetch ──────────────
//
// Everything here talks to the local Bridge endpoint over the same JSONL client
// the rest of agent mode uses (ctl_agent_local_call). The hub contract is the
// M2 wire contract:
//
//   agent.lease.submit   {lease_id?, summary, handoff?, output?, artifacts?}       (bridge adds vcs)
//   agent.lease.handoff  {lease_id?, summary, handoff?}                            (bridge adds vcs)
//   agent.lease.block    {lease_id?, waiting_on:{kind, ref?, reason}, summary?}
//   agent.review.post    {task_id?, verdict: approve|request_changes, findings?}
//   agent.task.fetch     {task_id, ref}   ref = "#<event_id>" | "facet:<task>:<attempt>:<kind>"
//
// Configured verification commands were removed (REQ-TV2-1): workers choose and
// report their own checks, and an independent reviewer judges them. For one
// release `ham-ctl verify` is an inert stub, and the old brief flags
// (--verify/--auto-submit/--require-independent-verify) and submit flags
// (--verify/--skip-verify/--skip-verify-reason/--auto) are accepted, dropped and
// reported on stderr; nothing is sent or executed.
//
// The lease verbs also send `cwd` (ham-ctl's own working directory, which is the
// agent's) so the bridge can find the repository for its vcs enrichment; the hub
// ignores the key.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import jsonx "odin_test:lib/jsonx"

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
	for f in ([?]string{"--goal", "--acceptance", "--input", "--inputs", "--review-role", "--review-roles", "--on-output-workflow", "--output-schema", "--brief-file"}) {
		if has_flag(args, f) do return true
	}
	return false
}

// ctl_task_brief_json builds the `brief` object from an optional --brief-file
// body (the base) and the brief flags (which override the file's fields).
// Pure: the file's text is passed in. Returns ("", false) when there is nothing
// to send. Only the brief keys the hub documents are carried from the file
// (goal, acceptance, inputs, review_roles, assignee, budget, output, on_output);
// flags win field by field. The removed verify keys are never carried.
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

	if file != "" {
		if a := extract_json_string_unescaped(file, "assignee", "", context.temp_allocator); a != "" do append(&fields, json_kv("assignee", a))
		if raw, ok := extract_json_object_raw(file, "budget", context.temp_allocator); ok do append(&fields, json_kv_raw("budget", raw))
	}

	if out_schema := strings.trim_space(option_value(args, "--output-schema", "")); out_schema != "" {
		append(&fields, json_kv("output", out_schema))
	} else if file != "" {
		if raw, ok := extract_json_object_raw(file, "output", context.temp_allocator); ok {
			append(&fields, json_kv_raw("output", raw))
		} else if out_s := extract_json_string_unescaped(file, "output", "", context.temp_allocator); out_s != "" {
			append(&fields, json_kv("output", out_s))
		}
	}

	if on_wf := strings.trim_space(option_value(args, "--on-output-workflow", "")); on_wf != "" {
		append(&fields, json_kv_raw("on_output", json_object(json_kv("start_workflow", on_wf))))
	} else if file != "" {
		if raw, ok := extract_json_object_raw(file, "on_output", context.temp_allocator); ok {
			append(&fields, json_kv_raw("on_output", raw))
		}
	}

	if len(fields) == 0 do return "", false
	return json_object_from_slice(fields[:]), true
}

// CTL_REMOVED_BRIEF_KEYS / CTL_REMOVED_BRIEF_FLAGS: the verification brief
// fields that were removed. They are accepted for one release and dropped.
CTL_REMOVED_BRIEF_KEYS :: [?]string{"verify", "auto_submit", "require_independent_verify"}
CTL_REMOVED_BRIEF_FLAGS :: [?]string{"--verify", "--auto-submit", "--require-independent-verify"}

// ctl_task_brief_removed_fields names the removed verification fields the
// caller passed, as flags or as --brief-file keys. Pure.
ctl_task_brief_removed_fields :: proc(args: []string, brief_file_text: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	keys := CTL_REMOVED_BRIEF_KEYS
	for f, i in CTL_REMOVED_BRIEF_FLAGS {
		if has_flag(args, f) do append(&out, keys[i])
	}
	if file := strings.trim_space(brief_file_text); file != "" {
		for k in keys {
			if !jsonx.has_key(file, k, top_level_only = true) do continue
			dup := false
			for o in out { if o == k { dup = true; break } }
			if !dup do append(&out, k)
		}
	}
	return out[:]
}

// ctl_warn_removed prints the one-release compatibility warning for dropped
// verification flags on stderr, so stdout stays the command's JSON.
ctl_warn_removed :: proc(what: string, fields: []string) {
	if len(fields) == 0 do return
	fmt.eprintfln("ham-ctl: warning: %s %s ignored: verification commands were removed; choose and report your own checks", what, strings.join(fields, ", ", context.temp_allocator))
}

// ctl_task_brief_field returns the `"brief":{...}` field for create/update from
// the flags and --brief-file, or ("", false) when no brief was given. Exits 1
// when --brief-file cannot be read or is not a JSON object. Removed verification
// fields are dropped with a stderr warning.
ctl_task_brief_field :: proc(args: []string) -> (string, bool) {
	file_text := ""
	if path := option_value(args, "--brief-file", ""); path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--brief-file %s: cannot read", path))
		}
		file_text = string(data)
		if t := strings.trim_space(file_text); t == "" || t[0] != '{' {
			ctl_print_error_exit(fmt.tprintf("--brief-file %s: must contain a JSON object", path))
		}
	}
	ctl_warn_removed("brief", ctl_task_brief_removed_fields(args, file_text))
	if file_text == "" && !ctl_task_brief_flags_present(args) do return "", false
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
	strings.write_string(&b, "rules: goal (≤2000 chars); 1..20 acceptance items (≤200 chars each); every review_role needs a fleet row carrying that role.\n")
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
ctl_v2_task_publish :: proc(endpoint, token, tid: string, args: []string, unblock := false) {
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
		fmt.println(`{"ok":false,"message":"could not resolve the task's chain; pass --chain <id>"}`)
		os.exit(1)
	}
	params := json_object(
		json_kv("http_method", "POST"),
		json_kv("path", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/%s", safe_path_part(chain_id), safe_path_part(tid), "answer" if unblock else "publish")),
		json_kv("body", json_object(json_kv("note", option_value(args, "--note", ""))) if unblock else "{}"),
	)
	response, ok := ctl_agent_local_call(endpoint, token, "agent.rest.request", params)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	ctl_publish_print_and_exit(response)
}

// ---- lease verbs --------------------------------------------------------------

// ctl_read_json_file_flag reads `--<flag> <path>` and returns the file's JSON
// text (validated to parse). Exits 1 on a missing/invalid file. ("", false)
// when the flag is absent.
// ctl_handoff_flags: the handoff object from --handoff-file, or one built from
// the inline flags TASK.md teaches: --next-steps <text>, and repeatable
// --decision <text> / --dead-end <text> (one item per flag). Not both forms.
// Decisions and dead ends reach every task that waits for this one.
ctl_handoff_flags :: proc(args: []string) -> (string, bool) {
	next := strings.trim_space(option_value(args, "--next-steps", ""))
	decisions := option_values_trimmed(args, "--decision")
	dead_ends := option_values_trimmed(args, "--dead-end")
	inline := next != "" || len(decisions) > 0 || len(dead_ends) > 0
	h, has_file := ctl_read_json_file_flag(args, "--handoff-file")
	if has_file && inline { fmt.println(`{"ok":false,"message":"use --next-steps/--decision/--dead-end or --handoff-file (put them in the file), not both"}`); os.exit(1) }
	if has_file do return h, true
	if !inline do return "", false
	fields := make([dynamic]string, context.temp_allocator)
	if next != "" do append(&fields, json_kv("next_steps", next))
	if len(decisions) > 0 do append(&fields, json_string_array_field("decisions", decisions))
	if len(dead_ends) > 0 do append(&fields, json_string_array_field("dead_ends", dead_ends))
	return json_object_from_slice(fields[:]), true
}

// option_values_trimmed: every non-blank value of a repeatable `name <value>` flag.
option_values_trimmed :: proc(args: []string, name: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] != name do continue
		if v := strings.trim_space(args[i + 1]); v != "" do append(&out, v)
	}
	return out[:]
}

ctl_read_json_file_flag :: proc(args: []string, flag: string) -> (string, bool) {
	path := option_value(args, flag, "")
	if path == "" do return "", false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		ctl_print_error_exit(fmt.tprintf("%s %s: cannot read", flag, path))
	}
	text := strings.trim_space(string(data))
	parsed, perr := json.parse(transmute([]byte)text, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		ctl_print_error_exit(fmt.tprintf("%s %s: not valid JSON", flag, path))
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

// ctl_lease_dir_or: the lease's chain directory when it exists on this machine,
// else `fallback` (ham-ctl's own cwd).
ctl_lease_dir_or :: proc(directory_path, fallback: string) -> string {
	dp := strings.trim_space(directory_path)
	if dp != "" && os.exists(dp) do return dp
	return fallback
}

// ctl_lease_work_dir: where the current lease's work lives, for the lease verbs'
// `cwd` (the bridge reads the repository's VCS state from it). Peeks the lease
// for placement.directory_path; falls back to ham-ctl's own cwd.
ctl_lease_work_dir :: proc(endpoint, token: string) -> string {
	cwd := ctl_agent_cwd()
	resp, ok := ctl_agent_local_call(endpoint, token, "agent.lease.next", json_object(json_kv("cwd", cwd), json_kv_raw("peek", "true")))
	if !ok do return cwd
	lease, parsed := ctl_lease_peek_parse(resp)
	if !parsed do return cwd
	return ctl_lease_dir_or(lease.directory_path, cwd)
}

ctl_agent_cwd_field :: proc() -> string {
	return json_kv("cwd", ctl_agent_cwd())
}

// CTL_REMOVED_SUBMIT_FLAGS: the verification flags `lease submit` no longer
// sends. They are accepted for one release with a stderr warning.
CTL_REMOVED_SUBMIT_FLAGS :: [?]string{"--verify", "--skip-verify", "--skip-verify-reason", "--auto"}

// ctl_lease_submit_removed_flags names the removed submit flags present. Pure.
ctl_lease_submit_removed_flags :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f in CTL_REMOVED_SUBMIT_FLAGS {
		if has_flag(args, f) do append(&out, f)
	}
	return out[:]
}

ctl_v2_lease_submit_params :: proc(args: []string, handoff_json := "", output_json := "", artifacts_json := "", cwd_override := "") -> (string, bool) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" do return "", false
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if handoff_json != "" do append(&fields, json_kv_raw("handoff", handoff_json))
	if output_json != "" do append(&fields, json_kv_raw("output", output_json))
	if artifacts_json != "" do append(&fields, json_kv_raw("artifacts", artifacts_json))
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	cwd := cwd_override if cwd_override != "" else ctl_agent_cwd()
	append(&fields, json_kv("cwd", cwd))
	return json_object_from_slice(fields[:]), true
}

ctl_v2_lease_submit :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease submit requires --summary <text>"}`); os.exit(1) }
	ctl_warn_removed("lease submit", ctl_lease_submit_removed_flags(args))
	h, _ := ctl_handoff_flags(args)
	o, _ := ctl_read_json_file_flag(args, "--output-file")
	a, a_ok := ctl_read_json_file_flag(args, "--artifacts-file")
	if !a_ok {
		if raw_a := strings.trim_space(option_value(args, "--artifacts", "")); raw_a != "" {
			if _, perr := json.parse(transmute([]byte)raw_a, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); perr != nil {
				fmt.println(`{"ok":false,"message":"--artifacts: not valid JSON"}`)
				os.exit(1)
			}
			a = raw_a
		}
	}
	params, ok := ctl_v2_lease_submit_params(args, h, o, a, ctl_lease_work_dir(endpoint, token))
	if !ok { fmt.println(`{"ok":false,"message":"lease submit requires --summary <text>"}`); os.exit(1) }
	ctl_agent_call_task(endpoint, token, "agent.lease.submit", params, args)
}

ctl_v2_lease_handoff :: proc(endpoint, token: string, args: []string) {
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if summary == "" { fmt.println(`{"ok":false,"message":"lease handoff requires --summary <text>"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_handoff_flags(args); ok do append(&fields, json_kv_raw("handoff", h))
	if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
	append(&fields, json_kv("cwd", ctl_lease_work_dir(endpoint, token)))
	ctl_agent_call_task(endpoint, token, "agent.lease.handoff", json_object_from_slice(fields[:]), args)
}

// ctl_v2_lease_switch (solo mode): hand the current task off and take another
// ready task in one step. `ham-ctl lease switch <task_id> --summary <s>`.
ctl_v2_lease_switch :: proc(endpoint, token: string, args: []string, positional_task := "") {
	task_id := strings.trim_space(option_value(args, "--task", ""))
	if task_id == "" do task_id = strings.trim_space(positional_task)
	summary := strings.trim_space(option_value(args, "--summary", ""))
	if task_id == "" || summary == "" { fmt.println(`{"ok":false,"message":"lease switch requires <task_id> and --summary <text> (where you left the current task)"}`); os.exit(1) }
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("task_id", task_id))
	append(&fields, json_kv("summary", summary))
	if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
	if h, ok := ctl_handoff_flags(args); ok do append(&fields, json_kv_raw("handoff", h))
	append(&fields, json_kv("cwd", ctl_lease_work_dir(endpoint, token)))
	ctl_agent_call_task(endpoint, token, "agent.lease.switch", json_object_from_slice(fields[:]), args)
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

ctl_v2_review_post_params :: proc(tokens, args: []string, findings_json := "") -> (string, bool) {
	verdict := strings.trim_space(option_value(args, "--verdict", ""))
	if verdict != "approve" && verdict != "request_changes" do return "", false
	fields := make([dynamic]string)
	defer delete(fields)
	if v := option_value(args, "--task", option_value(args, "--task-id", pos(tokens, 1))); v != "" do append(&fields, json_kv("task_id", v))
	append(&fields, json_kv("verdict", verdict))
	if findings_json != "" do append(&fields, json_kv_raw("findings", findings_json))
	// --summary: the reason in words (enough on its own for request_changes;
	// a rejected gate's re-plan reads it).
	if v := strings.trim_space(option_value(args, "--summary", "")); v != "" do append(&fields, json_kv("summary", v))
	if obo := strings.trim_space(option_value(args, "--on-behalf-of", "")); obo != "" {
		append(&fields, json_kv("on_behalf_of", obo))
	}
	return json_object_from_slice(fields[:]), true
}

ctl_v2_review :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "post":
		f, _ := ctl_read_json_file_flag(args, "--findings-file")
		params, ok := ctl_v2_review_post_params(tokens, args, f)
		if !ok {
			fmt.println(`{"ok":false,"message":"review post requires --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]"}`)
			os.exit(1)
		}
		ctl_agent_call_task(endpoint, token, "agent.review.post", params, args)
	case:
		print_help_review()
	}
}

// ---- task-chain summary / propose / fleet --------------------------------------

ctl_v2_task_chain_summary_params :: proc(tokens, args: []string, stdin_text := "", file_text := "") -> (string, bool) {
	sub := pos(tokens, 0)
	summary := strings.trim_space(option_value(args, "--summary", option_value(args, "--body", "")))
	if file_text != "" && summary == "" {
		summary = strings.trim_right_space(file_text)
	} else if has_flag(args, "--stdin") {
		summary = stdin_text
	} else if summary == "" {
		if sub == "set" {
			summary = pos(tokens, 1)
		} else {
			summary = sub
		}
	}
	if summary == "" && !has_flag(args, "--summary") && !has_flag(args, "--body") && !has_flag(args, "--file") && !has_flag(args, "--stdin") {
		return "", false
	}
	fields := make([dynamic]string)
	defer delete(fields)
	if cid := option_value(args, "--chain", option_value(args, "--chain-id", "")); cid != "" {
		append(&fields, json_kv("chain_id", cid))
	}
	append(&fields, json_kv("summary", summary))
	return json_object_from_slice(fields[:]), true
}

ctl_v2_task_chain_summary :: proc(endpoint, token: string, tokens, args: []string) {
	stdin_text := ""
	file_text := ""
	if path := option_value(args, "--file", ""); path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
		}
		file_text = string(data)
	} else if has_flag(args, "--stdin") {
		if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
			stdin_text = string(data)
		}
	}
	params, ok := ctl_v2_task_chain_summary_params(tokens, args, stdin_text, file_text)
	if !ok {
		fmt.println(`{"ok":false,"message":"task-chain summary requires set <text>, --body <text>, --file <path>, or --stdin [--chain <id>]"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task_chain.set_summary", params, args)
}

ctl_v2_task_chain_propose_params :: proc(args: []string, file_text: string) -> (string, bool) {
	trimmed := strings.trim_space(file_text)
	if trimmed == "" || trimmed[0] != '{' do return "", false
	parsed, perr := json.parse(transmute([]byte)trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return "", false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return "", false

	fields := make([dynamic]string)
	defer delete(fields)

	cid := option_value(args, "--chain", option_value(args, "--chain-id", ""))
	if cid == "" {
		if s, ok := obj["chain_id"].(json.String); ok do cid = string(s)
	}
	if cid != "" do append(&fields, json_kv("chain_id", cid))

	if s, ok := obj["kind"].(json.String); ok && string(s) != "" {
		append(&fields, json_kv("kind", string(s)))
	} else if k := option_value(args, "--kind", ""); k != "" {
		append(&fields, json_kv("kind", k))
	}
	if s, ok := obj["rationale"].(json.String); ok && string(s) != "" {
		append(&fields, json_kv("rationale", string(s)))
	} else if r := option_value(args, "--rationale", ""); r != "" {
		append(&fields, json_kv("rationale", r))
	}
	if s, ok := obj["alternative"].(json.String); ok && string(s) != "" {
		append(&fields, json_kv("alternative", string(s)))
	} else if alt := option_value(args, "--alternative", ""); alt != "" {
		append(&fields, json_kv("alternative", alt))
	}
	auto_approve := has_flag(args, "--auto-approve")
	if !auto_approve {
		if b, ok := obj["auto_approve"].(json.Boolean); ok do auto_approve = bool(b)
	}
	if auto_approve do append(&fields, `"auto_approve":true`)

	if raw_tasks, ok := ctl_extract_json_array_raw(trimmed, "tasks"); ok {
		append(&fields, json_kv_raw("tasks", raw_tasks))
	} else {
		wf_ref := option_value(args, "--workflow", option_value(args, "--template", ""))
		if wf_ref == "" {
			if s, ok := obj["workflow"].(json.String); ok do wf_ref = string(s)
		}
		if wf_ref == "" {
			if s, ok := obj["template"].(json.String); ok do wf_ref = string(s)
		}
		if wf_ref == "" {
			return "", false
		}
		append(&fields, json_kv("workflow", wf_ref))
		if raw_in, ok := extract_json_object_raw(trimmed, "inputs", context.temp_allocator); ok {
			append(&fields, json_kv_raw("inputs", raw_in))
		}
	}
	return json_object_from_slice(fields[:]), true
}

ctl_v2_task_chain_propose :: proc(endpoint, token: string, tokens, args: []string) {
	_ = tokens
	file_text := ""
	path := option_value(args, "--file", option_value(args, "--proposal-file", ""))
	if path != "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
		}
		file_text = string(data)
	} else if has_flag(args, "--stdin") {
		if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
			file_text = string(data)
		}
	}
	params, ok := ctl_v2_task_chain_propose_params(args, file_text)
	if !ok {
		fmt.println(`{"ok":false,"message":"task-chain propose requires --file <proposal.json> (with tasks array) [--auto-approve] [--chain <id>]"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task_chain.propose", params, args)
}

ctl_v2_fleet_set_body :: proc(args: []string, bridge_models_file_json := "") -> (string, bool) {
	capacity_str := option_value(args, "--capacity", "")
	roles := collect_multi_values(args, "--role", "--roles")
	defer delete(roles)
	has_placement := len(roles) > 0 || has_flag(args, "--bridge") || has_flag(args, "--bridge-id") || has_flag(args, "--provider") || has_flag(args, "--model") || has_flag(args, "--bridge-models") || bridge_models_file_json != ""
	if capacity_str == "" && !has_placement do return "", false

	capacity := 1
	if capacity_str != "" {
		if c, c_ok := strconv_parse_int_agent(capacity_str); c_ok {
			capacity = c
		}
	}
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv_raw("capacity", fmt.tprintf("%d", capacity)))
	if mw := option_value(args, "--min-warm", ""); mw != "" {
		if v, v_ok := strconv_parse_int_agent(mw); v_ok do append(&fields, json_kv_raw("min_warm", fmt.tprintf("%d", v)))
	}
	if ttl := option_value(args, "--idle-ttl", option_value(args, "--idle-ttl-seconds", "")); ttl != "" {
		if v, v_ok := strconv_parse_int_agent(ttl); v_ok do append(&fields, json_kv_raw("idle_ttl_seconds", fmt.tprintf("%d", v)))
	}
	if len(roles) > 0 {
		append(&fields, json_string_array_field("roles", roles[:]))
	}
	if has_flag(args, "--bridge") || has_flag(args, "--bridge-id") {
		append(&fields, json_kv("bridge_id", option_value(args, "--bridge", option_value(args, "--bridge-id", ""))))
	}
	if has_flag(args, "--provider") {
		append(&fields, json_kv("provider", option_value(args, "--provider", "")))
	}
	if has_flag(args, "--model") {
		append(&fields, json_kv("model", option_value(args, "--model", "")))
	}
	bm_raw := bridge_models_file_json
	if bm_raw == "" {
		bm_raw = strings.trim_space(option_value(args, "--bridge-models", ""))
	}
	if bm_raw != "" {
		if _, perr := json.parse(transmute([]byte)bm_raw, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); perr != nil {
			return "", false
		}
		append(&fields, json_kv_raw("bridge_models", bm_raw))
	}
	return json_object_from_slice(fields[:]), true
}

// ---- task fetch ------------------------------------------------------------------

ctl_v2_task_fetch :: proc(endpoint, token: string, tokens, args: []string) {
	tid := pos(tokens, 1)
	ref := pos(tokens, 2)
	if ref == "" do ref = option_value(args, "--ref", "")
	if tid == "" || ref == "" {
		fmt.println(`{"ok":false,"message":"task fetch requires <task_id> <ref>; ref is #<event_id>, output:<task_id>, facet:<task_id>:<attempt_no>:<kind>, dir:<dir_id>:<rev>:<path>, <path>@<rev>, or <path>"}`)
		os.exit(1)
	}
	ctl_agent_call_task(endpoint, token, "agent.task.fetch", json_object(json_kv("task_id", tid), json_kv("ref", ref)), args)
}

// ---- lease peek -------------------------------------------------------------------

// Ctl_Lease_Peek is what the lease verbs need from a `lease next` peek: where
// the leased task's work lives, for the bridge's vcs enrichment.
Ctl_Lease_Peek :: struct {
	status:     string,
	lease_id:   string,
	task_id:    string,
	attempt_no: int,
	// placement.workdir (the task's own git worktree) when the hub names one,
	// else placement.directory_path.
	directory_path: string,
}

// ctl_lease_peek_parse reads a lease.next (or task.show) response. The
// placement may sit on the lease, at the top level, or in the context pack.
ctl_lease_peek_parse :: proc(response: string) -> (Ctl_Lease_Peek, bool) {
	parsed, perr := json.parse(transmute([]byte)response, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return {}, false
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}, false
	node := obj
	for _ in 0 ..< 5 {
		if _, has := node["lease"]; has do break
		if _, has := node["task"]; has do break
		if _, has := node["brief"]; has do break
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	placement_dir :: proc(out: ^Ctl_Lease_Peek, holder: json.Object) {
		if out.directory_path != "" do return
		pl, ok := holder["placement"].(json.Object)
		if !ok do return
		if dp, dok := pl["directory_path"].(json.String); dok do out.directory_path = strings.clone(string(dp))
		if wd, wok := pl["workdir"].(json.String); wok && string(wd) != "" do out.directory_path = strings.clone(string(wd))
	}
	out: Ctl_Lease_Peek
	if v, ok := node["status"].(json.String); ok do out.status = strings.clone(string(v))
	if lease, ok := node["lease"].(json.Object); ok {
		if l, lok := lease["lease_id"].(json.String); lok do out.lease_id = strings.clone(string(l))
		if n, nok := lease["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
		if n, nok := lease["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		if t, tok := lease["task_id"].(json.String); tok do out.task_id = strings.clone(string(t))
		placement_dir(&out, lease)
	}
	task_obj, has_task := node["task"].(json.Object)
	if !has_task {
		if _, has_brief := node["brief"]; has_brief {
			task_obj = node
			has_task = true
		}
	}
	if has_task {
		if t, tok := task_obj["task_id"].(json.String); tok && out.task_id == "" do out.task_id = strings.clone(string(t))
		if out.attempt_no == 0 {
			if n, nok := task_obj["attempt_no"].(json.Float); nok do out.attempt_no = int(n)
			if n, nok := task_obj["attempt_no"].(json.Integer); nok do out.attempt_no = int(n)
		}
	}
	placement_dir(&out, node)
	if pack, pok := node["pack"].(json.Object); pok {
		// lease.next returns {status, lease, task, pack}; the placement (with the
		// chain directory's path) lives in the pack, at its top level and under
		// pack.lease.
		placement_dir(&out, pack)
		if pl_lease, lok := pack["lease"].(json.Object); lok do placement_dir(&out, pl_lease)
	}
	return out, out.task_id != ""
}

// ---- verify (removed; one-release stub) -------------------------------------------

// ctl_verify_removed_json is the M3 stub's whole output. Pure.
ctl_verify_removed_json :: proc() -> string {
	return json_object(
		json_kv_raw("ok", "true"),
		json_kv("verify", "removed"),
		json_kv("message", "Verification commands were removed; choose and report your own checks"),
	)
}

// ctl_v2_verify is the inert `ham-ctl verify` kept for one release so old
// instructions do not fail: it runs nothing, records nothing, never submits,
// and exits 0.
ctl_v2_verify :: proc(endpoint, token: string, tokens, args: []string) {
	_, _ = endpoint, token
	if pos(tokens, 0) == "help" || has_flag(args, "--help") || has_flag(args, "-h") { print_help_verify(); return }
	fmt.println(ctl_verify_removed_json())
}

// ---- help ------------------------------------------------------------------------

print_help_review :: proc() {
	fmt.println("ham-ctl review — post a review verdict on the task you were woken to review")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  post --verdict approve|request_changes [--summary <reason>] [--findings-file <json>] [--task <id>] [--on-behalf-of user]")
	fmt.println("      Record your verdict. --task defaults to the task your lease names. request_changes")
	fmt.println("      needs --summary or findings. The")
	fmt.println("      findings file is a JSON array of {path?, line?, severity?, text}.")
	fmt.println("      Coordinator instances can pass `--on-behalf-of user` when the user said so in chat.")
	fmt.println("      Response: {gate: waiting|approved|changes_requested, task}.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl review post --verdict approve")
	fmt.println("  ham-ctl review post --verdict request_changes --findings-file findings.json")
	fmt.println("  ham-ctl review post --verdict request_changes --summary \"the zero case still crashes\"")
	fmt.println("  ham-ctl review post --task task_1 --verdict approve --on-behalf-of user")
}

print_help_verify :: proc() {
	fmt.println("ham-ctl verify — removed")
	fmt.println("")
	fmt.println("Configured verification commands were removed. Choose the checks that fit your")
	fmt.println("task, run them yourself (for example with `ham-ctl shell run`), and report the")
	fmt.println("exact commands and outcomes in your `lease submit` summary; an independent")
	fmt.println("reviewer judges correctness.")
	fmt.println("")
	fmt.println("For one release `ham-ctl verify` still exists as a stub: it prints")
	fmt.println("{\"ok\":true,\"verify\":\"removed\",…}, runs nothing, never submits, and exits 0.")
}

// ---- workflow (M3b) --------------------------------------------------------------

ctl_v2_workflow_define_params :: proc(args: []string, file_text: string) -> (string, bool) {
	trimmed := strings.trim_space(file_text)
	if trimmed == "" || trimmed[0] != '{' do return "", false
	parsed, perr := json.parse(transmute([]byte)trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil do return "", false
	_, is_obj := parsed.(json.Object)
	if !is_obj do return "", false

	fields := make([dynamic]string)
	defer delete(fields)
	if name := strings.trim_space(option_value(args, "--name", "")); name != "" {
		append(&fields, json_kv("name", name))
	}
	append(&fields, json_kv_raw("definition", trimmed))
	return json_object_from_slice(fields[:]), true
}

ctl_v2_workflow_inputs_json :: proc(args: []string, inputs_file_text := "") -> (string, bool) {
	Ordered_KV :: struct {
		key:   string,
		field: string,
	}
	entries := make([dynamic]Ordered_KV, context.temp_allocator)
	upsert :: proc(list: ^[dynamic]Ordered_KV, k, field_str: string) {
		for &e in list^ {
			if e.key == k {
				e.field = field_str
				return
			}
		}
		append(list, Ordered_KV{key = k, field = field_str})
	}

	base_json := strings.trim_space(inputs_file_text)
	if base_json == "" {
		raw_flag := strings.trim_space(option_value(args, "--inputs", ""))
		if strings.has_prefix(raw_flag, "{") {
			base_json = raw_flag
		}
	}
	if base_json != "" {
		if !strings.has_prefix(base_json, "{") do return "", false
		parsed, perr := json.parse(transmute([]byte)base_json, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
		if perr != nil do return "", false
		obj, is_obj := parsed.(json.Object)
		if !is_obj do return "", false
		for k, v in obj {
			if mb, merr := json.marshal(v, allocator = context.temp_allocator); merr == nil {
				upsert(&entries, k, json_kv_raw(k, string(mb)))
			}
		}
	}

	kv_flags := ctl_collect_repeated(args, "--input", "--inputs")
	defer delete(kv_flags)
	for item in kv_flags {
		trimmed := strings.trim_space(item)
		if trimmed == "" || strings.has_prefix(trimmed, "{") do continue
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 do return "", false
		k := strings.trim_space(trimmed[:eq])
		v := trimmed[eq + 1:]
		if k == "" do return "", false
		upsert(&entries, k, json_kv(k, v))
	}

	if len(entries) == 0 do return "", true
	fields := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for e in entries {
		append(&fields, e.field)
	}
	return json_object_from_slice(fields[:]), true
}

// Run identity is distinct from its containing chain. Creation requires a caller
// request key so a network retry can never silently create duplicate work.
ctl_v2_workflow_run_params :: proc(tokens, args: []string, inputs_file_text := "", def_file_text := "") -> (string, bool) {
 ref := strings.trim_space(option_value(args, "--ref", pos(tokens, 1)))
 request_id := strings.trim_space(option_value(args, "--request-id", ""))
 if ref == "" || request_id == "" || def_file_text != "" do return "", false
 for flag in ([?]string{"--file", "--template", "--workflow", "--name", "--project", "--bridge", "--coordinator", "--description"}) { if has_flag(args, flag) do return "", false }
 inputs, ok := ctl_v2_workflow_inputs_json(args, inputs_file_text)
 if !ok do return "", false
 if inputs == "" do inputs = "{}"
 fields := make([dynamic]string, context.temp_allocator)
 append(&fields, json_kv("ref", ref), json_kv("request_id", request_id), json_kv_raw("inputs", inputs))
 if cid := option_value(args, "--chain", ""); cid != "" do append(&fields, json_kv("chain_id", cid))
 if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", title))
 prerequisites := ctl_collect_repeated(args, "--after")
 defer delete(prerequisites)
 refs := make([dynamic]string, context.temp_allocator)
 for item in prerequisites {
  ref_json, valid := ctl_work_ref_json(item)
  if !valid do return "", false
  append(&refs, ref_json)
 }
 append(&fields, json_kv_raw("prerequisites", fmt.tprintf("[%s]", strings.join(refs[:], ",", context.temp_allocator))))
 return json_object_from_slice(fields[:]), true
}

ctl_v2_workflow_status_params :: proc(tokens, args: []string) -> (run_id, params: string) {
 id := strings.trim_space(option_value(args, "--run", pos(tokens, 1)))
 fields := make([dynamic]string, context.temp_allocator)
 append(&fields, json_kv("run_id", id))
 if no := option_value(args, "--execution", ""); no != "" {
  n, parsed := strconv.parse_int(no)
  if !parsed || n <= 0 do return "", "{}"
  append(&fields, json_kv_raw("execution_no", no))
 }
 return id, json_object_from_slice(fields[:])
}

ctl_v2_workflow_output_params :: proc(tokens, args: []string) -> (run_id, stage_key, params: string, ok: bool) {
 id, base := ctl_v2_workflow_status_params(tokens, args)
 stage := option_value(args, "--stage", pos(tokens, 2))
 if id == "" || stage == "" do return "", "", "", false
 return id, stage, strings.concatenate({base[:len(base)-1], ",", json_kv("stage_key", stage), "}"}), true
}

ctl_v2_workflow_retry_params :: proc(tokens, args: []string) -> (run_id, target, params: string, ok: bool) {
 id := strings.trim_space(option_value(args, "--run", pos(tokens, 1)))
 reason := strings.trim_space(option_value(args, "--reason", ""))
 revision := option_value(args, "--expected-revision", "")
 n, parsed := strconv.parse_int(revision)
 for flag in ([?]string{"--stage", "--task", "--task-id", "--cascade", "--chain", "--execution"}) { if has_flag(args, flag) do return "", "", "", false }
 if id == "" || reason == "" || !parsed || n <= 0 || pos(tokens, 2) != "" do return "", "", "", false
 return id, "", json_object(json_kv("run_id", id), json_kv("reason", reason), json_kv_raw("expected_revision", revision)), true
}

ctl_v2_workflow_cancel_params :: proc(tokens, args: []string) -> (run_id, params: string) {
 id := strings.trim_space(option_value(args, "--run", pos(tokens, 1)))
 generation := option_value(args, "--execution", "0")
 n, valid := strconv.parse_int(generation)
 if !valid || n <= 0 do return "", "{}"
 return id, json_object(json_kv("run_id", id), json_kv("reason", option_value(args, "--reason", "")), json_kv_raw("execution_no", generation))
}

ctl_v2_workflow :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "templates":
		ctl_agent_call_task(endpoint, token, "agent.workflow.templates", "{}", args)
	case "list":
        params := json_object(json_kv("chain_id", option_value(args, "--chain", "")))
        ctl_agent_call_task(endpoint, token, "agent.workflow.runs", params, args)
    case "history":
        id, params := ctl_v2_workflow_status_params(tokens, args)
        if id == "" { fmt.println(`{"ok":false,"message":"workflow history requires a run ID"}`); os.exit(1) }
        ctl_agent_call_task(endpoint, token, "agent.workflow.history", params, args)
    case "define":
        file_text := ""
		path := option_value(args, "--file", pos(tokens, 1))
		if path != "" {
			data, err := os.read_entire_file(path, context.allocator)
			if err != nil {
				ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
			}
			file_text = string(data)
		} else if has_flag(args, "--stdin") {
			if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
				file_text = string(data)
			}
		}
		params, ok := ctl_v2_workflow_define_params(args, file_text)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow define requires --file <def.json> (or --stdin)"}`)
			os.exit(1)
		}
		ctl_agent_call_task(endpoint, token, "agent.workflow.define", params, args)
	case "run":
		in_text, _ := ctl_read_json_file_flag(args, "--inputs-file")
		def_text, _ := ctl_read_json_file_flag(args, "--file")
		params, ok := ctl_v2_workflow_run_params(tokens, args, in_text, def_text)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow run requires <ref> --request-id <key> [--chain <id>] [--input k=v] [--after task:<id>|workflow_run:<id>]"}`)
			os.exit(1)
		}
		ctl_agent_call_task(endpoint, token, "agent.workflow.run", params, args)
	case "status":
		_, params := ctl_v2_workflow_status_params(tokens, args)
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.status", params, args)
	case "output":
		_, _, params, ok := ctl_v2_workflow_output_params(tokens, args)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow output requires <run_id> <stage_key>"}`)
			os.exit(1)
		}
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.output", params, args)
	case "retry":
		_, _, params, ok := ctl_v2_workflow_retry_params(tokens, args)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow retry requires <run_id> --expected-revision <n> --reason <text>"}`)
			os.exit(1)
		}
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.retry", params, args)
	case "cancel":
		id, params := ctl_v2_workflow_cancel_params(tokens, args)
        if id == "" { fmt.println(`{"ok":false,"message":"workflow cancel requires <run_id> --execution <number>"}`); os.exit(1) }
		defer delete(params)
		ctl_agent_call_task(endpoint, token, "agent.workflow.cancel", params, args)
	case:
		print_help_workflow()
	}
}

ctl_workflow_user_mode :: proc(cmd, args: []string) {
	tokens := cmd[1:] if len(cmd) > 1 else []string{}
	verb := pos(tokens, 0)
	if verb == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_help_workflow()
		return
	}
	transport, tok := resolve_ctl_transport(args)
	if !tok do os.exit(1)
	if transport.kind == .Agent {
		ctl_v2_workflow(transport.agent_endpoint, transport.agent_token, tokens, args)
		return
	}
	if transport.user_base_url == "" || transport.user_token == "" {
		fmt.println(`{"ok":false,"message":"workflow in user mode requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`)
		os.exit(1)
	}
	switch verb {
	case "", "templates":
		ctl_tasks_request_and_decrypt(transport, "GET", "/api/v1/workflows/templates", "", args)
	case "list":
        cid := option_value(args, "--chain", "")
        if cid == "" { fmt.println(`{"ok":false,"message":"workflow list requires --chain"}`); os.exit(1) }
        ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/workflow-runs", safe_path_part(cid)), "", args)
    case "history":
        id, _ := ctl_v2_workflow_status_params(tokens, args)
        if id == "" { fmt.println(`{"ok":false,"message":"workflow history requires a run ID"}`); os.exit(1) }
        ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/workflow-runs/%s/executions", safe_path_part(id)), "", args)
    case "define":
        file_text := ""
		path := option_value(args, "--file", pos(tokens, 1))
		if path != "" {
			data, err := os.read_entire_file(path, context.allocator)
			if err != nil {
				ctl_print_error_exit(fmt.tprintf("--file %s: cannot read", path))
			}
			file_text = string(data)
		} else if has_flag(args, "--stdin") {
			if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
				file_text = string(data)
			}
		}
		params, ok := ctl_v2_workflow_define_params(args, file_text)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow define requires --file <def.json> (or --stdin)"}`)
			os.exit(1)
		}
		ctl_tasks_request_and_decrypt(transport, "POST", "/api/v1/workflows/definitions", params, args)
	case "run":
		in_text, _ := ctl_read_json_file_flag(args, "--inputs-file")
		def_text, _ := ctl_read_json_file_flag(args, "--file")
		params, ok := ctl_v2_workflow_run_params(tokens, args, in_text, def_text)
		if !ok {
			fmt.println(`{"ok":false,"message":"workflow run requires <ref> --request-id <key> [--chain <id>] [--input k=v] [--after task:<id>|workflow_run:<id>]"}`)
			os.exit(1)
		}
		cid := option_value(args, "--chain", "")
        if cid == "" { fmt.println(`{"ok":false,"message":"workflow run in user mode requires --chain"}`); os.exit(1) }
        ctl_tasks_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/workflow-runs", safe_path_part(cid)), params, args)
	case "status":
		cid, _ := ctl_v2_workflow_status_params(tokens, args)
		if cid == "" {
			fmt.println(`{"ok":false,"message":"workflow status requires <run_id>"}`)
			os.exit(1)
		}
		ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/workflow-runs/%s?execution_no=%s", safe_path_part(cid), query_escape(option_value(args, "--execution", "0"))), "", args)
	case "output":
		cid, stage, _, ok := ctl_v2_workflow_output_params(tokens, args)
		if !ok || cid == "" {
			fmt.println(`{"ok":false,"message":"workflow output requires <run_id> <stage_key>"}`)
			os.exit(1)
		}
		ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/workflow-runs/%s/output?stage_key=%s&execution_no=%s", safe_path_part(cid), query_escape(stage), query_escape(option_value(args, "--execution", "0"))), "", args)
	case "retry":
		cid, _, params, ok := ctl_v2_workflow_retry_params(tokens, args)
		if !ok || cid == "" {
			fmt.println(`{"ok":false,"message":"workflow retry requires <run_id> --expected-revision <n> --reason <text>"}`)
			os.exit(1)
		}
		defer delete(params)
		ctl_tasks_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/workflow-runs/%s/retry", safe_path_part(cid)), params, args)
	case "cancel":
		cid, params := ctl_v2_workflow_cancel_params(tokens, args)
		defer delete(params)
		if cid == "" {
			fmt.println(`{"ok":false,"message":"workflow cancel requires <run_id> --execution <number>"}`)
			os.exit(1)
		}
		ctl_tasks_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/workflow-runs/%s/cancel", safe_path_part(cid)), params, args)
	case:
		print_help_workflow()
	}
}

print_help_workflow :: proc() {
 fmt.println("ham-ctl workflow: runs inside an existing task chain; owner or coordinator controls them")
 fmt.println("  templates | define --file <definition.json>")
 fmt.println("  run <ref> --chain <id> --request-id <key> [--title <text>] [--input k=v ...] [--inputs-file <json>] [--after task:<id>|workflow_run:<id> ...]")
 fmt.println("  list --chain <id>")
 fmt.println("  status <run_id> [--execution <n>]")
 fmt.println("  output <run_id> <stage_key> [--execution <n>]")
 fmt.println("  history <run_id>")
 fmt.println("  retry <run_id> --expected-revision <n> --reason <text>")
 fmt.println("  cancel <run_id> --execution <number> [--reason <text>]")
 fmt.println("Fan-out: a stage may set \"for_each\": \"inputs.<array-input>\" (pass the list via --inputs-file; --input k=v is always a string)")
 fmt.println("  or \"<stage>.outputs[0].<field>\"; at most 256 items per stage. A missing/null input uses its declared default, otherwise invalid")
 fmt.println("  inputs fail before anything is created. An empty array completes the stage with zero tasks.")
 fmt.println("A retry creates a fresh execution. Consumed outputs block retry. Stage retry is unsupported.")
 fmt.println("Agent mode may omit --chain when creating/listing runs; run IDs are always explicit.")
}
