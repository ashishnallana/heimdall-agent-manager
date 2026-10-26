package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import httpc "odin_test:lib/httpc"

// Task_Brief_Wire is the Task System v2 brief object carried under `brief` on
// every task read. Only the fields ham-ctl renders are typed; the hub stores the
// brief verbatim, so unknown keys (inputs, budget, output, …) are ignored.
Task_Brief_Wire :: struct {
	goal:         string   `json:"goal"`,
	acceptance:   []string `json:"acceptance"`,
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
	// hub: user_base_url parsed once (resolve_ctl_transport) for the User kind.
	hub: Ctl_Hub,
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

// ctl_user_token_removed reports (and explains) a Hub user token (hut_): the Hub
// no longer accepts them; users authenticate with OIDC only.
ctl_user_token_removed :: proc(user_tok: string) -> bool {
	if !strings.has_prefix(user_tok, "hut_") do return false
	fmt.println(`{"ok":false,"message":"Heimdall user tokens (hut_) were removed: the Hub accepts only OIDC sign-in for users. ham-ctl user mode is not available; run ham-ctl inside an agent instance (agent mode) or use the web UI."}`)
	return true
}

resolve_ctl_transport :: proc(args: []string) -> (Ctl_Transport, bool) {
	as_override := option_value(args, "--as", "")
	hub_url := hub_user_mode_url(args)
	user_tok := hub_user_mode_token(args)
	ag_endpoint := agent_mode_endpoint(args)
	ag_tok := agent_mode_token(args)

	if ctl_user_token_removed(user_tok) do return Ctl_Transport{}, false
	if as_override == "user" {
		if hub_url == "" || user_tok == "" {
			fmt.println(`{"ok":false,"message":"--as user requires --hub-url and --user-token (or HAM_HUB_URL and HAM_USER_TOKEN)"}`)
			return Ctl_Transport{}, false
		}
		return ctl_user_transport(hub_url, user_tok), true
	}

	if as_override == "agent" {
		if ag_endpoint == "" || ag_tok == "" {
			fmt.println(`{"ok":false,"message":"--as agent requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint and --agent-token)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	if hub_url != "" && user_tok != "" {
		return ctl_user_transport(hub_url, user_tok), true
	}

	if ag_endpoint != "" && ag_tok != "" {
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	return ctl_user_transport(hub_url, user_tok), true
}

ctl_user_transport :: proc(hub_url, user_tok: string) -> Ctl_Transport {
	base := strings.trim_right(hub_url, "/")
	return Ctl_Transport{kind = .User, user_base_url = base, user_token = user_tok, hub = ctl_hub_make(base, user_tok)}
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
		ctl_tasks_request(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "fleets")})
		return
	}
	if sub == "pause" || sub == "resume" {
		chain_id := pos(tokens, 1)
		if chain_id == "" do chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" do chain_id = resolve_chain_id(transport, args)
		agent_id := option_value(args, "--agent", option_value(args, "--agent-id", ""))
		if chain_id == "" || agent_id == "" {
			fmt.printfln("usage: ham-ctl task-chains fleet %s <chain-id> --agent <agent_id> [--roles <worker,reviewer>]", sub)
			return
		}
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "fleets", agent_id, sub), body = httpc.json_body(ctl_v2_fleet_pause_body(args))})
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
		ctl_tasks_request(transport, {method = .PUT, path = ctl_api("task-chains", chain_id, "fleets", agent_id), body = httpc.json_body(body)})
		return
	}
	chain_id := sub
	ctl_tasks_request(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "fleets")})
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
	fmt.println("usage: ham-ctl tasks <list|show|create|update|depend|cancel|comment|comments|fetch|unblock|hold|release>")
	fmt.println("  unblock <task-id> --chain <id> [--note <reason>]  (retry a dispatch block after fixing placement)")
	fmt.println("  hold <task-id> --chain <id> --reason <text>  (no new lease until released; a current holder is asked to checkpoint)")
	fmt.println("  release <task-id> --chain <id>  (clear a hold)")
	fmt.println("  create --chain <id> --title <title> [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval]")
	fmt.println("  update <task-id> [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval | --no-require-user-approval]")
	fmt.println("  depend <task-id> --chain <id> --on <task-id>|task:<id>|workflow_run:<run-id>   (workflow runs become chain-level graph edges)")
	fmt.println("  --assignee/--reviewer take durable agent ids (agt_...) only; instance pins (inst_...) were removed in Task System v2")
	fmt.println("  (status/done/vote/votes/nudge/subscribe/unsubscribe were removed in Task System v2; use lease/review)")
}

ctl_task_chain_request_and_decrypt :: proc(transport: Ctl_Transport, req: Ctl_Request, args: []string = nil) {
	ctl_tasks_request_and_decrypt(transport, req, args)
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
		body, p_ok := ctl_v2_task_chain_summary_body(cmd[idx + 1:], args, stdin_text)
		cid := resolve_chain_id(transport, args)
		if !p_ok || cid == "" {
			fmt.println(`{"ok":false,"message":"task-chains summary requires set <text> (or --stdin) and --chain <id>"}`)
			os.exit(1)
		}
		ctl_task_chain_request_and_decrypt(transport, {method = .PUT, path = ctl_api("task-chains", cid, "summary"), body = httpc.json_body(body)}, args)
		return
	}

	if action == "propose" {
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
		body, p_ok := ctl_v2_task_chain_propose_body(args, file_text)
		if !p_ok {
			fmt.println(`{"ok":false,"message":"task-chains propose requires --file <proposal.json> [--auto-approve] [--chain <id>]"}`)
			os.exit(1)
		}
		ctl_task_chain_request_and_decrypt(transport, {method = .POST, path = ctl_api("agent-actions", "chain", "propose"), body = httpc.json_body(body)}, args)
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
		body := Ctl_Proposal_Decide_Body{decision = decision, reason = option_value(args, "--reason", "")}
		ctl_task_chain_request_and_decrypt(transport, {method = .POST, path = ctl_api("task-chains", cid, "proposal", "decide"), body = httpc.json_body(body)}, args)
		return
	}

	if action == "" || action == "list" {
		query := ctl_query_make()
		if has_flag(args, "--pinned") do ctl_query_add(&query, "pinned", "1")
		ctl_task_chain_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains"), query = query[:]}, args)
		return
	}

	// H9 R4: list the chains an agent coordinates (single canonical source). With no
	// --agent-id, the hub defaults to the caller's own instance (from its token), so
	// an agent can fetch "chains I coordinate" with only its agent token.
	if action == "coordinated" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		query := []httpc.Query_Param{{"coordinated_by", agent_id}}
		ctl_task_chain_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains"), query = query}, args)
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
		body := Ctl_Chain_Create_Body{
			title                = title,
			description          = desc,
			kind                 = option_value(args, "--kind", "mixed_work"),
			coordinator_agent_id = option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", "")),
			bridge_id            = option_value(args, "--bridge-id", option_value(args, "--bridge", "")),
			project_id           = option_value(args, "--project-id", option_value(args, "--project", "")),
		}
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains"), body = httpc.json_body(body)})
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
		ctl_task_chain_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains", chain_id)}, args)
		return
	}

	if action == "update" {
		body: Ctl_Chain_Update_Body
		keyring := ctl_vault_keyring_for_write(args)
		if title := option_value(args, "--title", ""); title != "" {
			if !is_vault_armored(title) {
				title = ctl_seal_or_exit(title, keyring)
			}
			body.title = title
		}
		if desc := option_value(args, "--description", ""); desc != "" {
			if !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
			body.description = desc
		}
		body.status = option_value(args, "--status", "")
		ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id), body = httpc.json_body(body)})
		return
	}

	if action == "members" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "members")})
			return
		}
		if sub == "add" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			role := option_value(args, "--role", "worker")
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> add --agent <instance_id> [--role <role>]")
				return
			}
			ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "members"), body = httpc.json_body(Ctl_Chain_Member_Body{agent_instance_id = inst, role = role})})
			return
		}
		if sub == "remove" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> remove --agent <instance_id>")
				return
			}
			ctl_tasks_request(transport, {method = .DELETE, path = ctl_api("task-chains", chain_id, "members", inst)})
			return
		}
	}

	if action == "directory" || action == "directories" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "directories")})
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
			body := ctl_directory_body(args)
			body.path = path
			ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "directories"), body = httpc.json_body(body)})
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
			body := ctl_directory_body(args)
			body.path = option_value(args, "--path", option_value(args, "--dir", ""))
			ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id, "directories", dir_id), body = httpc.json_body(body)})
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
			ctl_tasks_request(transport, {method = .DELETE, path = ctl_api("task-chains", chain_id, "directories", dir_id)})
			return
		}
	}

	if action == "add-agent" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" {
			fmt.println("usage: ham-ctl task-chains add-agent --chain <id> --agent <id> [--bridge <id>] [--provider <profile>] [--model <model>] [--project <id>]")
			return
		}
		body := Ctl_Add_Agent_Body{
			agent_id   = agent_id,
			chain_id   = chain_id,
			bridge_id  = option_value(args, "--bridge-id", option_value(args, "--bridge", "")),
			provider   = option_value(args, "--provider", ""),
			model      = option_value(args, "--model", ""),
			project_id = option_value(args, "--project-id", option_value(args, "--project", "")),
		}
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("agent-instances"), body = httpc.json_body(body)})
		return
	}

	if action == "publish" {
		// Task System v2: a 422 brief_incomplete is rendered per task and exits 1.
		resp_str, ok := ctl_tasks_request_local(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "publish"), body = ctl_empty_object_body()})
		if !ok { if resp_str != "" do fmt.println(resp_str); os.exit(1) }
		ctl_publish_print_and_exit(resp_str)
		return
	}



	if action == "pin" {
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "pin"), body = httpc.json_body(Ctl_Pinned_Body{pinned = true})})
		return
	}

	if action == "unpin" {
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "pin"), body = httpc.json_body(Ctl_Pinned_Body{pinned = false})})
		return
	}

	// Coordinator-only recovery: return an accidentally-completed chain to active.
	if action == "reopen" {
		ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id), body = httpc.json_body(Ctl_Status_Body{status = "active"})})
		return
	}

	if action == "archive" {
		ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id), body = httpc.json_body(Ctl_Status_Body{status = "archived"})})
		return
	}

	if action == "unarchive" {
		ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id), body = httpc.json_body(Ctl_Status_Body{status = "active"})})
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
		ctl_tasks_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "tasks")}, args)
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
		body := Ctl_Task_Create_Body{title = title, description = desc}
		if prio := option_value(args, "--priority", ""); prio != "" {
			// REQ-CLI-2: this field was already being sent and silently discarded by
			// the Hub; now that create honours it, a bad value must not slide to p2.
			if !ctl_valid_task_priority(prio) {
				fmt.printfln("usage: --priority must be one of p0, p1, p2 (got %q)", prio)
				return
			}
			body.priority = prio
		}
		body.assignee = strings.trim_space(option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")))
		// --reviewer is repeatable and/or comma-separated for multiple reviewers.
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do body.reviewers = ctl_v2_reviewers(args)
		if has_flag(args, "--require-user-approval") do body.requires_user_approval = true
		if deps, present := ctl_task_depends_on_flag(args, "--depends-on", "--on"); present && deps != "" {
			body.depends_on = ctl_csv_list(deps)
		}
		body.bridge_id = option_value(args, "--bridge", "")
		if brief, replace, ok := ctl_task_brief_value(args); ok {
			body.brief = brief
			body.replace_brief = replace
		}
		resp_str, ok := ctl_tasks_request_local(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks"), body = httpc.json_body(body)})
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
		ctl_tasks_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "tasks", task_id)}, args)
		return
	}
	if action == "hold" || action == "release" {
		body := ctl_empty_object_body()
		if action == "hold" {
			reason := strings.trim_space(option_value(args, "--reason", ""))
			if reason == "" {
				fmt.println(`{"ok":false,"message":"tasks hold requires --reason <text>"}`)
				os.exit(1)
			}
			body = httpc.json_body(Ctl_Task_Reason_Body{reason = reason})
		}
		ctl_tasks_request_and_decrypt(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", task_id, action), body = body}, args)
		return
	}
	if action == "unblock" {
		body := Ctl_Task_Note_Body{note = option_value(args, "--note", "")}
		ctl_tasks_request_and_decrypt(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", task_id, "answer"), body = httpc.json_body(body)}, args)
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
		ctl_tasks_request_and_decrypt(transport, ctl_task_fetch_request(chain_id, task_id, ref), args)
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
		body := Ctl_Task_Update_Body{title = title, description = desc, priority = option_value(args, "--priority", "")}
		body.assignee = strings.trim_space(option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")))
		// --reviewer is repeatable/comma-separated for MULTIPLE reviewers;
		// presence-checked so `--reviewer ""` clears the list.
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do body.reviewers = ctl_v2_reviewers(args)
		if has_flag(args, "--require-user-approval") do body.requires_user_approval = true
		if has_flag(args, "--no-require-user-approval") do body.requires_user_approval = false
		// --bridge is presence-checked so `--bridge ""` clears the pin back to inherit.
		if has_flag(args, "--bridge") do body.bridge_id = option_value(args, "--bridge", "")
		if deps, present := ctl_task_depends_on_flag(args, "--depends-on", "--on"); present {
			body.depends_on = ctl_csv_list(deps)
		}
		if brief, replace, ok := ctl_task_brief_value(args); ok {
			body.brief = brief
			body.replace_brief = replace
		}
		ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id, "tasks", task_id), body = httpc.json_body(body)})
		return
	}

	if action == "depend" {
		kind, prereq, msg := ctl_task_depend_target(option_value(args, "--on", option_value(args, "--depends-on", "")))
		switch kind {
		case .Invalid:
			ctl_print_error_exit(msg)
		case .Task:
			ctl_tasks_request(transport, {method = .PATCH, path = ctl_api("task-chains", chain_id, "tasks", task_id), body = httpc.json_body(Ctl_Task_Depends_Body{depends_on = ctl_csv_list(prereq)})})
		case .Workflow_Run:
			// Whole-run prerequisites live in the chain-level work graph.
			ctl_tasks_request_and_decrypt(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "work", "depend"), body = httpc.json_body(ctl_task_depend_workflow_body(chain_id, task_id, prereq))}, args)
		}
		return
	}

	if action == "cancel" {
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", task_id, "cancel"), body = ctl_empty_object_body()})
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
		ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", task_id, "comments"), body = httpc.json_body(ctl_task_comment_body(body, args))})
		return
	}

	if action == "comments" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) && (cmd[idx + 1] == "add" || cmd[idx + 1] == "list") do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request_and_decrypt(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "tasks", task_id, "comments")}, args)
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
			ctl_tasks_request(transport, {method = .POST, path = ctl_api("task-chains", chain_id, "tasks", task_id, "comments"), body = httpc.json_body(ctl_task_comment_body(body, args))})
			return
		}
	}

	fmt.println("usage: ham-ctl tasks <list|show|create|update|depend|cancel|comment|comments|fetch>")
}

// ---- hub request bodies (user transport task/chain routes) ----------------------

Ctl_Proposal_Decide_Body :: struct {
	decision: string `json:"decision"`,
	reason:   string `json:"reason,omitempty"`,
}

Ctl_Chain_Create_Body :: struct {
	title:                string `json:"title"`,
	description:          string `json:"description"`,
	kind:                 string `json:"kind"`,
	coordinator_agent_id: string `json:"coordinator_agent_id"`,
	bridge_id:            string `json:"bridge_id"`,
	project_id:           string `json:"project_id"`,
}

Ctl_Chain_Update_Body :: struct {
	title:       string `json:"title,omitempty"`,
	description: string `json:"description,omitempty"`,
	status:      string `json:"status,omitempty"`,
}

Ctl_Chain_Member_Body :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	role:              string `json:"role"`,
}

// Ctl_Directory_Body: chain directory add/update. --vcs-info holding a JSON
// object is sent as `vcs`; any other --vcs-info value is a vcs_kind (and wins
// over --vcs-kind, as the later duplicate key did).
Ctl_Directory_Body :: struct {
	path:      string     `json:"path,omitempty"`,
	bridge_id: string     `json:"bridge_id,omitempty"`,
	vcs_kind:  string     `json:"vcs_kind,omitempty"`,
	vcs:       json.Value `json:"vcs,omitempty"`,
}

ctl_directory_body :: proc(args: []string) -> (body: Ctl_Directory_Body) {
	body.bridge_id = option_value(args, "--bridge-id", option_value(args, "--bridge", ""))
	body.vcs_kind = option_value(args, "--vcs-kind", option_value(args, "--vcs", ""))
	if vcs := option_value(args, "--vcs-info", ""); vcs != "" {
		if strings.starts_with(vcs, "{") {
			body.vcs = ctl_parse_json_flag("--vcs-info", vcs)
		} else {
			body.vcs_kind = vcs
		}
	}
	return
}

Ctl_Add_Agent_Body :: struct {
	agent_id:   string `json:"agent_id"`,
	chain_id:   string `json:"chain_id"`,
	bridge_id:  string `json:"bridge_id,omitempty"`,
	provider:   string `json:"provider,omitempty"`,
	model:      string `json:"model,omitempty"`,
	project_id: string `json:"project_id,omitempty"`,
}

Ctl_Task_Create_Body :: struct {
	title:                  string          `json:"title"`,
	description:            string          `json:"description,omitempty"`,
	priority:               string          `json:"priority,omitempty"`,
	assignee:               string          `json:"assignee,omitempty"`,
	reviewers:              Maybe([]string) `json:"reviewers,omitempty"`,
	requires_user_approval: Maybe(bool)     `json:"requires_user_approval,omitempty"`,
	depends_on:             []string        `json:"depends_on,omitempty"`,
	bridge_id:              string          `json:"bridge_id,omitempty"`,
	brief:                  json.Value      `json:"brief,omitempty"`,
	replace_brief:          Maybe(bool)     `json:"replace_brief,omitempty"`,
}

// Ctl_Task_Update_Body: presence-checked flags (reviewers, approval, bridge,
// depends_on) are Maybe so an explicit empty value is still sent.
Ctl_Task_Update_Body :: struct {
	title:                  string          `json:"title,omitempty"`,
	description:            string          `json:"description,omitempty"`,
	priority:               string          `json:"priority,omitempty"`,
	assignee:               string          `json:"assignee,omitempty"`,
	reviewers:              Maybe([]string) `json:"reviewers,omitempty"`,
	requires_user_approval: Maybe(bool)     `json:"requires_user_approval,omitempty"`,
	bridge_id:              Maybe(string)   `json:"bridge_id,omitempty"`,
	depends_on:             Maybe([]string) `json:"depends_on,omitempty"`,
	brief:                  json.Value      `json:"brief,omitempty"`,
	replace_brief:          Maybe(bool)     `json:"replace_brief,omitempty"`,
}

Ctl_Task_Depends_Body :: struct {
	depends_on: []string `json:"depends_on"`,
}

Ctl_Task_Comment_Body :: struct {
	body:   string   `json:"body"`,
	notify: []string `json:"notify,omitempty"`,
}

ctl_task_comment_body :: proc(body: string, args: []string) -> Ctl_Task_Comment_Body {
	out := Ctl_Task_Comment_Body{body = body}
	if notify := option_value(args, "--notify", ""); notify != "" do out.notify = ctl_csv_list(notify)
	return out
}
