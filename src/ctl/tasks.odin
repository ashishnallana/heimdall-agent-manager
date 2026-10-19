package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import http "odin_test:lib/http_client"

// Task_Brief_Wire is the Task System v2 brief object carried under `brief` on
// every task read. Only the fields ham-ctl renders are typed; the hub stores the
// brief verbatim, so unknown keys (inputs, budget, auto_submit, …) are ignored.
Task_Brief_Wire :: struct {
	goal:         string   `json:"goal"`,
	acceptance:   []string `json:"acceptance"`,
	verify:       string   `json:"verify"`,
	review_roles: []string `json:"review_roles"`,
	assignee:     string   `json:"assignee"`,
}

// Task_Blocked_On_Wire mirrors the hub's blocked_on object (zero value when the
// task is not blocked; the hub sends null then).
Task_Blocked_On_Wire :: struct {
	kind:   string `json:"kind"`,
	ref:    string `json:"ref"`,
	reason: string `json:"reason"`,
	since:  string `json:"since"`,
}

// Task_Created_Data_Wire is the subset of the Task System v2 task wire that the
// `tasks create` summary reads back: `state` replaces the old `status`, and
// `brief.assignee` / `brief.review_roles` replace assignee_ref / reviewer_refs.
Task_Created_Data_Wire :: struct {
	task_id:                string               `json:"task_id"`,
	state:                  string               `json:"state"`,
	kind:                   string               `json:"kind"`,
	attempt_no:             int                  `json:"attempt_no"`,
	brief:                  Task_Brief_Wire      `json:"brief"`,
	blocked_on:             Task_Blocked_On_Wire `json:"blocked_on"`,
	requires_user_approval: bool                 `json:"requires_user_approval"`,
	depends_on:             []string             `json:"depends_on"`,
	blocked:                bool                 `json:"blocked"`,
	bridge_id:              string               `json:"bridge_id"`,
}

Task_Created_Envelope_Wire :: struct {
	ok:   bool `json:"ok"`,
	data: struct {
		data: Task_Created_Data_Wire `json:"data"`,
	} `json:"data"`,
}

format_task_created_summary :: proc(task: Task_Created_Data_Wire, allocator := context.temp_allocator) -> (assignee, reviewers, deps_str, blocked_str, bridge_str: string) {
	assignee = "\x1b[31mNONE\x1b[0m"
	if task.brief.assignee != "" {
		assignee = task.brief.assignee
	}

	reviewers = "\x1b[31mNONE\x1b[0m"
	if len(task.brief.review_roles) > 0 {
		reviewers = strings.join(task.brief.review_roles, ",", allocator)
	}

	deps_str = "none"
	if len(task.depends_on) > 0 {
		if b, err := json.marshal(task.depends_on, allocator = allocator); err == nil {
			deps_str = string(b)
		}
	}

	blocked_str = "\x1b[31mtrue\x1b[0m" if task.blocked else "false"
	if task.blocked && task.blocked_on.kind != "" {
		blocked_str = strings.concatenate({blocked_str, " (", task.blocked_on.kind, ")"}, allocator)
	}

	bridge_str = "inherited"
	if task.bridge_id != "" {
		bridge_str = task.bridge_id
	}

	return
}



Ctl_Transport_Kind :: enum {
	User,
	Agent,
}

Ctl_Transport :: struct {
	kind: Ctl_Transport_Kind,
	user_base_url: string,
	user_token: string,
	agent_endpoint: string,
	agent_token: string,
}

// ctl_valid_task_priority gates --priority on task CREATE in both CLI modes.
// The Hub coerces an unrecognised priority to p2, so an unvalidated flag value
// would land silently at the default; REQ-CLI-2 requires a usage error instead.
// Create-only by design: the update path's existing behaviour is unchanged.
ctl_valid_task_priority :: proc(value: string) -> bool {
	switch value {
	case "p0", "p1", "p2": return true
	}
	return false
}

resolve_ctl_transport :: proc(args: []string) -> (Ctl_Transport, bool) {
	as_override := option_value(args, "--as", "")
	hub_url := hub_user_mode_url(args)
	user_tok := hub_user_mode_token(args)
	ag_endpoint := agent_mode_endpoint(args)
	ag_tok := agent_mode_token(args)

	if as_override == "user" {
		if hub_url == "" || user_tok == "" {
			fmt.println(`{"ok":false,"message":"--as user requires --hub-url and --user-token (or HAM_HUB_URL and HAM_USER_TOKEN)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
	}

	if as_override == "agent" {
		if ag_endpoint == "" || ag_tok == "" {
			fmt.println(`{"ok":false,"message":"--as agent requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint and --agent-token)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	if hub_url != "" && user_tok != "" {
		return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
	}

	if ag_endpoint != "" && ag_tok != "" {
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
}

ctl_tasks_request :: proc(transport: Ctl_Transport, method, path, body_json: string) {
	if transport.kind == .User {
		if transport.user_base_url == "" || transport.user_token == "" {
			fmt.println(`{"ok":false,"message":"user transport requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`)
			return
		}
		ctl_hub_request(transport.user_base_url, transport.user_token, method, path, body_json)
		return
	}

	if transport.kind == .Agent {
		if transport.agent_endpoint == "" || transport.agent_token == "" {
			fmt.println(`{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
			return
		}
		params := json_object(
			json_kv("http_method", method),
			json_kv("path", path),
			json_kv("body", body_json),
		)
		ctl_agent_call(transport.agent_endpoint, transport.agent_token, "agent.rest.request", params)
		return
	}
}

ctl_tasks_request_local :: proc(transport: Ctl_Transport, method, path, body_json: string) -> (string, bool) {
	if transport.kind == .User {
		if transport.user_base_url == "" || transport.user_token == "" {
			return `{"ok":false,"message":"user transport requires --hub-url and --user-token"}`, false
		}
		full_path := hub_url_path_prefix_join(transport.user_base_url, path)
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", transport.user_token})}}
		response, ok := http.request_with_headers_timeout(method, transport.user_base_url, full_path, body_json, headers[:], http.DEFAULT_TIMEOUT_MS)
		if !ok do return `{"ok":false,"message":"Hub request failed"}`, false
		return response.body, true
	}

	if transport.kind == .Agent {
		if transport.agent_endpoint == "" || transport.agent_token == "" {
			return `{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN"}`, false
		}
		params := json_object(json_kv("http_method", method), json_kv("path", path), json_kv("body", body_json))
		return ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.rest.request", params)
	}
	return "", false
}

ctl_tasks_request_and_decrypt :: proc(transport: Ctl_Transport, method, path, body_json: string, args: []string = nil) {
	resp_str, ok := ctl_tasks_request_local(transport, method, path, body_json)
	if !ok {
		if resp_str != "" {
			fmt.println(resp_str)
		}
		return
	}

	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_json_string(resp_str, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
}

resolve_chain_id :: proc(transport: Ctl_Transport, args: []string) -> string {
	cid := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if cid != "" do return cid
	if transport.kind == .Agent {
		res, ok := ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.context.get", "{}")
		if ok {
			chain_id := extract_json_string_unescaped(res, "chain_id", "")
			if chain_id != "" do return chain_id
		}
	}
	return ""
}

resolve_task_id :: proc(transport: Ctl_Transport, args: []string) -> string {
	tid := option_value(args, "--task-id", option_value(args, "--task", ""))
	if tid != "" do return tid
	if transport.kind == .Agent {
		res, ok := ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.context.get", "{}")
		if ok {
			task_id := extract_json_string_unescaped(res, "current_task_id", "")
			if task_id == "" do task_id = extract_json_string_unescaped(res, "task_id", "")
			if task_id != "" do return task_id
		}
	}
	return ""
}

print_task_chains_help :: proc(action: string) {
	_ = action
	fmt.println("usage: ham-ctl task-chains <list|coordinated|create|show|update|members|fleet|directory|add-agent|publish|graph|depend|remove-dependency|scope|complete|reopen|archive|unarchive|pin|unpin>")
	fmt.println("  coordinated [--agent-id <instance_id>]  list chains an agent coordinates (default: your own instance)")
	fmt.println("  fleet <list|set>                        manage chain fleet capacities")
    fmt.println("  graph [<chain-id>]                     read dependencies (with ids), scope and current work_revision")
    fmt.println("  depend [<chain-id>] --item task:ID|workflow_run:ID --on task:ID|workflow_run:ID")
    fmt.println("  remove-dependency [<chain-id>] --dependency ID --reason TEXT")
    fmt.println("  scope [<chain-id>] --item task:ID|workflow_run:ID --action include|exclude --reason TEXT")
    fmt.println("  complete <chain-id> --expected-work-revision N --summary TEXT   (explicit chain required)")
    fmt.println("  [<chain-id>] may also be given as --chain ID; graph/depend/remove-dependency/scope default to your chain.")
    fmt.println("  Same verbs and flags in agent mode (`ham-ctl task-chain --help`); Hub enforces owner/coordinator.")
    fmt.println("All chains are mixed_work. Completing a batch does not complete the chain.")
}

ctl_task_chains_fleet_command :: proc(transport: Ctl_Transport, tokens: []string, args: []string) {
	if has_flag(args, "--help") || has_flag(args, "-h") || (len(tokens) > 0 && tokens[0] == "help") {
		print_help_task_chain_fleet()
		return
	}
	sub := pos(tokens, 0)
	if sub == "" || sub == "list" {
		chain_id := pos(tokens, 1)
		if chain_id == "" do chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" do chain_id = resolve_chain_id(transport, args)
		if chain_id == "" {
			fmt.println("usage: ham-ctl task-chains fleet list <chain-id>")
			return
		}
		path := fmt.tprintf("/api/v1/task-chains/%s/fleets", safe_path_part(chain_id))
		ctl_tasks_request(transport, "GET", path, "")
		return
	}
	if sub == "set" {
		chain_id := pos(tokens, 1)
		if chain_id == "" do chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" do chain_id = resolve_chain_id(transport, args)
		agent_id := option_value(args, "--agent", option_value(args, "--agent-id", ""))
		bm_file, _ := ctl_read_json_file_flag(args, "--bridge-models-file")
		body, body_ok := ctl_v2_fleet_set_body(args, bm_file)
		if chain_id == "" || agent_id == "" || !body_ok {
			fmt.println("usage: ham-ctl task-chains fleet set <chain-id> --agent <agent_id> --capacity <N> [--roles <worker,reviewer>] [--bridge <id>] [--provider <p>] [--model <m>] [--bridge-models <json>]")
			return
		}
		path := fmt.tprintf("/api/v1/task-chains/%s/fleets/%s", safe_path_part(chain_id), safe_path_part(agent_id))
		ctl_tasks_request(transport, "PUT", path, body)
		return
	}
	chain_id := sub
	path := fmt.tprintf("/api/v1/task-chains/%s/fleets", safe_path_part(chain_id))
	ctl_tasks_request(transport, "GET", path, "")
}

// Destructive chain verbs must NEVER fall back to the auto-resolved caller
// chain: acting on the wrong chain here (e.g. completing your own chain by
// omitting --chain) is unrecoverable-by-accident. These verbs require an
// explicit --chain/--chain-id. Non-destructive verbs (show/list) keep the
// convenience default via resolve_chain_id.
is_destructive_chain_verb :: proc(action: string) -> bool {
	return action == "complete" || action == "publish" || action == "reopen" || action == "archive" || action == "unarchive"
}

print_tasks_help :: proc(action: string) {
	_ = action
	fmt.println("usage: ham-ctl tasks <list|show|create|update|depend|cancel|comment|comments|fetch>")
	fmt.println("  create --chain <id> --title <title> [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval]")
	fmt.println("  update <task-id> [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval | --no-require-user-approval]")
	fmt.println("  depend <task-id> --chain <id> --on <task-id>|task:<id>|workflow_run:<run-id>   (workflow runs become chain-level graph edges)")
	fmt.println("  --assignee/--reviewer take durable agent ids (agt_...) only; instance pins (inst_...) were removed in Task System v2")
	fmt.println("  (status/done/vote/votes/nudge/subscribe/unsubscribe were removed in Task System v2; use lease/verify/review)")
}

ctl_task_chain_request_and_decrypt :: proc(transport: Ctl_Transport, method, path, body_json: string, args: []string = nil) {
	resp_str, ok := ctl_tasks_request_local(transport, method, path, body_json)
	if !ok {
		if resp_str != "" {
			fmt.println(resp_str)
		}
		return
	}

	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_vault_json(resp_str, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
}

ctl_task_chains_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "task-chains" || cmd[0] == "task-chain" || cmd[0] == "chains" || cmd[0] == "chain") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_task_chains_help(action)
		return
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	if ctl_is_mixed_work_verb(action) {
		ctl_mixed_work_command(transport, action, args, pos(cmd[idx:], 1))
		return
	}

	if action == "fleet" || action == "fleets" {
		ctl_task_chains_fleet_command(transport, cmd[idx + 1:], args)
		return
	}

	if action == "summary" || action == "set-summary" {
		stdin_text := ""
		if has_flag(args, "--stdin") {
			if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
				stdin_text = string(data)
			}
		}
		params, p_ok := ctl_v2_task_chain_summary_params(cmd[idx + 1:], args, stdin_text)
		cid := resolve_chain_id(transport, args)
		if !p_ok || cid == "" {
			fmt.println(`{"ok":false,"message":"task-chains summary requires set <text> (or --stdin) and --chain <id>"}`)
			os.exit(1)
		}
		ctl_task_chain_request_and_decrypt(transport, "PUT", fmt.tprintf("/api/v1/task-chains/%s/summary", safe_path_part(cid)), params, args)
		return
	}

	if action == "propose" {
		file_text := ""
		path := option_value(args, "--file", option_value(args, "--proposal-file", ""))
		if path != "" {
			data, err := os.read_entire_file(path, context.allocator)
			if err != nil {
				fmt.printfln(`{"ok":false,"message":"--file %s: cannot read"}`, path)
				os.exit(1)
			}
			file_text = string(data)
		} else if has_flag(args, "--stdin") {
			if data, err := os.read_entire_file("/dev/stdin", context.allocator); err == nil {
				file_text = string(data)
			}
		}
		params, p_ok := ctl_v2_task_chain_propose_params(args, file_text)
		if !p_ok {
			fmt.println(`{"ok":false,"message":"task-chains propose requires --file <proposal.json> [--auto-approve] [--chain <id>]"}`)
			os.exit(1)
		}
		ctl_task_chain_request_and_decrypt(transport, "POST", "/api/v1/agent-actions/chain/propose", params, args)
		return
	}

	if action == "decide" || action == "proposal" {
		cid := resolve_chain_id(transport, args)
		if cid == "" && idx + 1 < len(cmd) && !strings.has_prefix(cmd[idx + 1], "--") {
			cid = cmd[idx + 1]
		}
		decision := strings.trim_space(option_value(args, "--decision", ""))
		if cid == "" || (decision != "approve" && decision != "reject") {
			fmt.println(`{"ok":false,"message":"task-chains decide requires --chain <id> --decision approve|reject [--reason <text>]"}`)
			os.exit(1)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("decision", decision))
		if r := option_value(args, "--reason", ""); r != "" do append(&fields, json_kv("reason", r))
		ctl_task_chain_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/proposal/decide", safe_path_part(cid)), json_object_from_slice(fields[:]), args)
		return
	}

	if action == "" || action == "list" {
		path := "/api/v1/task-chains?pinned=1" if has_flag(args, "--pinned") else "/api/v1/task-chains"
		ctl_task_chain_request_and_decrypt(transport, "GET", path, "", args)
		return
	}

	// H9 R4: list the chains an agent coordinates (single canonical source). With no
	// --agent-id, the hub defaults to the caller's own instance (from its token), so
	// an agent can fetch "chains I coordinate" with only its agent token.
	if action == "coordinated" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		ctl_task_chain_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains?coordinated_by=%s", safe_path_part(agent_id)), "", args)
		return
	}

	if action == "create" {
		title := option_value(args, "--title", "")
		if title == "" {
			fmt.println("usage: ham-ctl task-chains create --title <title> [--description <text>] [--kind <kind>] [--coordinator <id>] [--bridge <id>] [--project <id>]")
			return
		}
		desc := option_value(args, "--description", "")
		keyring := ctl_vault_keyring_for_write(args)
		if !is_vault_armored(title) {
			title = ctl_seal_or_exit(title, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("title", title))
		append(&fields, json_kv("description", desc))
		append(&fields, json_kv("kind", option_value(args, "--kind", "mixed_work")))
		append(&fields, json_kv("coordinator_agent_id", option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", ""))))
		append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", option_value(args, "--bridge", ""))))
		append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_tasks_request(transport, "POST", "/api/v1/task-chains", json_object_from_slice(fields[:]))
		return
	}

	// Guard destructive verbs: require an explicit --chain, never the caller default.
	if is_destructive_chain_verb(action) {
		explicit := option_value(args, "--chain-id", option_value(args, "--chain", ""))
		if explicit == "" && idx + 1 < len(cmd) && !strings.has_prefix(cmd[idx + 1], "--") {
			explicit = cmd[idx + 1]
		}
		if explicit == "" {
			msg := strings.concatenate({"ham-ctl task-chains ", action, " requires an explicit --chain <id>; refusing to act on the auto-resolved caller chain"})
			fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("message", msg)))
			os.exit(1)
		}
	}

	chain_id := resolve_chain_id(transport, args)
	if chain_id == "" && idx + 1 < len(cmd) && !strings.has_prefix(cmd[idx + 1], "--") {
		chain_id = cmd[idx + 1]
	}
	if chain_id == "" {
		fmt.println("usage: ham-ctl task-chains <show|update|members|directory|add-agent|publish|complete|reopen|archive|unarchive> --chain <id>")
		return
	}

	if action == "show" {
		ctl_task_chain_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), "", args)
		return
	}

	if action == "update" {
		fields := make([dynamic]string)
		defer delete(fields)
		keyring := ctl_vault_keyring_for_write(args)
		if title := option_value(args, "--title", ""); title != "" {
			if !is_vault_armored(title) {
				title = ctl_seal_or_exit(title, keyring)
			}
			append(&fields, json_kv("title", title))
		}
		if desc := option_value(args, "--description", ""); desc != "" {
			if !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
			append(&fields, json_kv("description", desc))
		}
		if status := option_value(args, "--status", ""); status != "" do append(&fields, json_kv("status", status))
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "members" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), "")
			return
		}
		if sub == "add" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			role := option_value(args, "--role", "worker")
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> add --agent <instance_id> [--role <role>]")
				return
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), json_object(json_kv("agent_instance_id", inst), json_kv("role", role)))
			return
		}
		if sub == "remove" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> remove --agent <instance_id>")
				return
			}
			ctl_tasks_request(transport, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/members/%s", safe_path_part(chain_id), safe_path_part(inst)), "")
			return
		}
	}

	if action == "directory" || action == "directories" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/directories", safe_path_part(chain_id)), "")
			return
		}
		if sub == "add" {
			path := option_value(args, "--path", option_value(args, "--dir", ""))
			if path == "" && idx + 2 < len(cmd) && !strings.has_prefix(cmd[idx + 2], "--") {
				path = cmd[idx + 2]
			}
			if path == "" {
				fmt.println("usage: ham-ctl task-chains directory add --chain <id> --path <path> [--bridge <id>] [--vcs-kind <kind>] [--vcs <json>]")
				return
			}
			fields := make([dynamic]string)
			defer delete(fields)
			append(&fields, json_kv("path", path))
			if b := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); b != "" do append(&fields, json_kv("bridge_id", b))
			if v := option_value(args, "--vcs-kind", option_value(args, "--vcs", "")); v != "" do append(&fields, json_kv("vcs_kind", v))
			if vcs := option_value(args, "--vcs-info", ""); vcs != "" {
				if strings.starts_with(vcs, "{") {
					append(&fields, fmt.tprintf("\"vcs\":%s", vcs))
				} else {
					append(&fields, json_kv("vcs_kind", vcs))
				}
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/directories", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
			return
		}
		if sub == "update" {
			dir_id := option_value(args, "--directory-id", option_value(args, "--directory", option_value(args, "--dir-id", option_value(args, "--id", ""))))
			if dir_id == "" && idx + 2 < len(cmd) && !strings.has_prefix(cmd[idx + 2], "--") {
				dir_id = cmd[idx + 2]
			}
			if dir_id == "" {
				fmt.println("usage: ham-ctl task-chains directory update --chain <id> --directory <id> [--path <path>] [--bridge <id>] [--vcs-kind <kind>] [--vcs <json>]")
				return
			}
			fields := make([dynamic]string)
			defer delete(fields)
			if p := option_value(args, "--path", option_value(args, "--dir", "")); p != "" do append(&fields, json_kv("path", p))
			if b := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); b != "" do append(&fields, json_kv("bridge_id", b))
			if v := option_value(args, "--vcs-kind", option_value(args, "--vcs", "")); v != "" do append(&fields, json_kv("vcs_kind", v))
			if vcs := option_value(args, "--vcs-info", ""); vcs != "" {
				if strings.starts_with(vcs, "{") {
					append(&fields, fmt.tprintf("\"vcs\":%s", vcs))
				} else {
					append(&fields, json_kv("vcs_kind", vcs))
				}
			}
			ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/directories/%s", safe_path_part(chain_id), safe_path_part(dir_id)), json_object_from_slice(fields[:]))
			return
		}
		if sub == "remove" || sub == "delete" {
			dir_id := option_value(args, "--directory-id", option_value(args, "--directory", option_value(args, "--dir-id", option_value(args, "--id", ""))))
			if dir_id == "" && idx + 2 < len(cmd) && !strings.has_prefix(cmd[idx + 2], "--") {
				dir_id = cmd[idx + 2]
			}
			if dir_id == "" {
				fmt.println("usage: ham-ctl task-chains directory remove --chain <id> --directory <id>")
				return
			}
			ctl_tasks_request(transport, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/directories/%s", safe_path_part(chain_id), safe_path_part(dir_id)), "")
			return
		}
	}

	if action == "add-agent" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" {
			fmt.println("usage: ham-ctl task-chains add-agent --chain <id> --agent <id> [--bridge <id>] [--provider <profile>] [--model <model>] [--project <id>]")
			return
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		append(&fields, json_kv("chain_id", chain_id))
		if b := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); b != "" do append(&fields, json_kv("bridge_id", b))
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
		if t := option_value(args, "--model", ""); t != "" do append(&fields, json_kv("model", t))
		if pr := option_value(args, "--project-id", option_value(args, "--project", "")); pr != "" do append(&fields, json_kv("project_id", pr))
		ctl_tasks_request(transport, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:]))
		return
	}

	if action == "publish" {
		// Task System v2: a 422 brief_incomplete is rendered per task and exits 1.
		resp_str, ok := ctl_tasks_request_local(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/publish", safe_path_part(chain_id)), "{}")
		if !ok { if resp_str != "" do fmt.println(resp_str); os.exit(1) }
		ctl_publish_print_and_exit(resp_str)
		return
	}



	if action == "pin" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/pin", safe_path_part(chain_id)), "{\"pinned\":true}")
		return
	}

	if action == "unpin" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/pin", safe_path_part(chain_id)), "{\"pinned\":false}")
		return
	}

	// Coordinator-only recovery: return an accidentally-completed chain to active.
	if action == "reopen" {
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "active")))
		return
	}

	if action == "archive" {
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "archived")))
		return
	}

	if action == "unarchive" {
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "active")))
		return
	}

	fmt.println("usage: ham-ctl task-chains <list|coordinated|create|show|update|summary|propose|decide|members|directory|add-agent|publish|complete|reopen|archive|unarchive|pin|unpin>")
}

ctl_tasks_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "tasks" || cmd[0] == "task") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_tasks_help(action)
		return
	}

	// `tasks show` is an explicit-id lookup and requires --task-id (there is no
	// current-task fallback for it). Fail with a clear JSON error when it is
	// omitted instead of silently producing no output.
	if action == "show" {
		tid := strings.trim_space(option_value(args, "--task-id", option_value(args, "--task", "")))
		if tid == "" {
			fmt.println(`{"ok":false,"message":"missing required --task-id"}`)
			return
		}
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	chain_id := resolve_chain_id(transport, args)

	if action == "" || action == "list" {
		if chain_id == "" {
			fmt.println("usage: ham-ctl tasks list --chain <id>")
			return
		}
		ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), "", args)
		return
	}

	if action == "create" {
		title := option_value(args, "--title", "")
		if chain_id == "" || title == "" {
			fmt.println("usage: ham-ctl tasks create --chain <id> --title <title> [--description <desc>] [--priority p0|p1|p2] [--assignee <id>] [--reviewer <agent-id,...>] [--require-user-approval] [--depends-on <id,id>] [--bridge <bridge-id>]")
			return
		}
		if !ctl_task_reviewer_flags_valid(args, false) do return
		desc := option_value(args, "--description", "")
		keyring := ctl_vault_keyring_for_write(args)
		if !is_vault_armored(title) {
			title = ctl_seal_or_exit(title, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if desc != "" do append(&fields, json_kv("description", desc))
		if prio := option_value(args, "--priority", ""); prio != "" {
			// REQ-CLI-2: this field was already being sent and silently discarded by
			// the Hub; now that create honours it, a bad value must not slide to p2.
			if !ctl_valid_task_priority(prio) {
				fmt.printfln("usage: --priority must be one of p0, p1, p2 (got %q)", prio)
				return
			}
			append(&fields, json_kv("priority", prio))
		}
		if assignee := option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")); assignee != "" {
			append(&fields, ctl_v2_assignee_field(assignee))
		}
		// --reviewer is repeatable and/or comma-separated for multiple reviewers.
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do append(&fields, ctl_v2_reviewers_field(args))
		if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
		if deps, present := ctl_task_depends_on_flag(args, "--depends-on", "--on"); present && deps != "" {
			append(&fields, ctl_v2_json_string_array("depends_on", deps))
		}
		if b := option_value(args, "--bridge", ""); b != "" do append(&fields, json_kv("bridge_id", b))
		if brief, ok := ctl_task_brief_field(args); ok do append(&fields, brief)
		resp_str, ok := ctl_tasks_request_local(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		if !ok {
			fmt.println(resp_str)
			return
		}
		
		envelope: Task_Created_Envelope_Wire
		if err := json.unmarshal_string(resp_str, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil || envelope.data.data.task_id == "" {
			user_env: struct {
				data: Task_Created_Data_Wire `json:"data"`,
			}
			if uerr := json.unmarshal_string(resp_str, &user_env, json.DEFAULT_SPECIFICATION, context.temp_allocator); uerr == nil && user_env.data.task_id != "" {
				envelope.data.data = user_env.data
				envelope.ok = true
			} else {
				fmt.println(resp_str)
				return
			}
		}

		t_id := envelope.data.data.task_id
		t_state := envelope.data.data.state
		assignee, reviewers, deps_str, blocked_str, bridge_str := format_task_created_summary(envelope.data.data, context.temp_allocator)

		fmt.printf("Task created successfully (ID: %s)\n", t_id)
		fmt.printf("State: %s | Assignee: %s | Review roles: %s | Depends on: %s | Blocked: %s\n", t_state, assignee, reviewers, deps_str, blocked_str)
		if goal := strings.trim_space(envelope.data.data.brief.goal); goal != "" do fmt.printf("Goal: %s\n", goal)
		fmt.printf("Bridge: %s | Requires user approval: %t\n", bridge_str, envelope.data.data.requires_user_approval)
		return
	}

	task_id := resolve_task_id(transport, args)
	if task_id == "" && idx + 1 < len(cmd) && !strings.has_prefix(cmd[idx + 1], "--") {
		task_id = cmd[idx + 1]
	}

	if chain_id == "" || task_id == "" {
		fmt.println("usage: ham-ctl tasks <show|update|depend|cancel|comment|comments|fetch> --chain <id> --task <id>")
		return
	}

	if action == "show" {
		ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), "", args)
		return
	}

	if action == "fetch" {
		ref := option_value(args, "--ref", "")
		if ref == "" && idx + 2 < len(cmd) && !strings.has_prefix(cmd[idx + 2], "--") {
			ref = cmd[idx + 2]
		}
		if ref == "" {
			fmt.println(`{"ok":false,"message":"tasks fetch requires --ref <ref> or positional <ref>"}`)
			os.exit(1)
		}
		ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/fetch?ref=%s", safe_path_part(chain_id), safe_path_part(task_id), safe_path_part(ref)), "", args)
		return
	}

	if action == "update" {
		if !ctl_task_reviewer_flags_valid(args, true) do return
		title := option_value(args, "--title", "")
		desc := option_value(args, "--description", "")
		keyring := ctl_vault_keyring_for_write(args)
		if title != "" && !is_vault_armored(title) {
			title = ctl_seal_or_exit(title, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		fields := make([dynamic]string)
		if title != "" do append(&fields, json_kv("title", title))
		if desc != "" do append(&fields, json_kv("description", desc))
		if prio := option_value(args, "--priority", ""); prio != "" do append(&fields, json_kv("priority", prio))
		if assignee := option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")); assignee != "" {
			append(&fields, ctl_v2_assignee_field(assignee))
		}
		// --reviewer is repeatable/comma-separated for MULTIPLE reviewers;
		// presence-checked so `--reviewer ""` clears the list.
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do append(&fields, ctl_v2_reviewers_field(args))
		if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
		if has_flag(args, "--no-require-user-approval") do append(&fields, `"requires_user_approval":false`)
		// --bridge is presence-checked so `--bridge ""` clears the pin back to inherit.
		if has_flag(args, "--bridge") do append(&fields, json_kv("bridge_id", option_value(args, "--bridge", "")))
		if deps, present := ctl_task_depends_on_flag(args, "--depends-on", "--on"); present {
			append(&fields, ctl_v2_json_string_array("depends_on", deps))
		}
		if brief, ok := ctl_task_brief_field(args); ok do append(&fields, brief)
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "depend" {
		kind, prereq, msg := ctl_task_depend_target(option_value(args, "--on", option_value(args, "--depends-on", "")))
		switch kind {
		case .Invalid:
			ctl_print_error_exit(msg)
		case .Task:
			ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object(ctl_v2_json_string_array("depends_on", prereq)))
		case .Workflow_Run:
			// Whole-run prerequisites live in the chain-level work graph.
			ctl_tasks_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/work/depend", safe_path_part(chain_id)), ctl_task_depend_workflow_params(chain_id, task_id, prereq), args)
		}
		return
	}

	if action == "cancel" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", safe_path_part(chain_id), safe_path_part(task_id)), "{}")
		return
	}

	if action == "comment" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") {
			data, err := os.read_entire_file("/dev/stdin", context.allocator)
			if err == nil do body = string(data)
		}
		if body == "" {
			fmt.println("usage: ham-ctl tasks comment --chain <id> --task <id> --body <text> [--notify <id,id...>]")
			return
		}
		keyring := ctl_vault_keyring_for_write(args)
		if !is_vault_armored(body) {
			body = ctl_seal_or_exit(body, keyring)
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("body", body))
		if notify := option_value(args, "--notify", ""); notify != "" {
			parts := strings.split(notify, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"notify\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "comments" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) && (cmd[idx + 1] == "add" || cmd[idx + 1] == "list") do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), "", args)
			return
		}
		if sub == "add" {
			body := option_value(args, "--body", "")
			if has_flag(args, "--stdin") {
				data, err := os.read_entire_file("/dev/stdin", context.allocator)
				if err == nil do body = string(data)
			}
			if body == "" {
				fmt.println("usage: ham-ctl tasks comments --chain <id> --task <id> add --body <text> [--notify <id,id...>]")
				return
			}
			keyring := ctl_vault_keyring_for_write(args)
			if !is_vault_armored(body) {
				body = ctl_seal_or_exit(body, keyring)
			}
			fields := make([dynamic]string)
			append(&fields, json_kv("body", body))
			if notify := option_value(args, "--notify", ""); notify != "" {
				parts := strings.split(notify, ",")
				defer delete(parts)
				buf := strings.builder_make()
				strings.write_string(&buf, "\"notify\":[")
				for p, i in parts {
					if i > 0 do strings.write_byte(&buf, ',')
					strings.write_byte(&buf, '"')
					strings.write_string(&buf, strings.trim_space(p))
					strings.write_byte(&buf, '"')
				}
				strings.write_byte(&buf, ']')
				append(&fields, strings.to_string(buf))
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:]))
			return
		}
	}

	fmt.println("usage: ham-ctl tasks <list|show|create|update|depend|cancel|comment|comments|fetch>")
}
