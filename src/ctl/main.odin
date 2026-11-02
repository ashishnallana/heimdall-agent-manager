package main

import "core:fmt"
import "core:os"
import "core:strings"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import httpc "odin_test:lib/httpc"

main :: proc() {
	// libcurl's global init must run once before any thread starts.
	if ok, msg := httpc.init(); !ok {
		fmt.eprintln(msg)
		os.exit(1)
	}
	// Zero the resolved vault keyring on every normal return path.
	defer ctl_vault_wipe()
	if len(os.args) == 2 && os.args[1] == "--version" {
		fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}

	cmd := command_tokens(os.args)
	defer delete(cmd)
	if len(cmd) == 0 {
		print_usage(cfg_lib.config_path_from_args(os.args), "")
		return
	}

	if cmd[0] == "health" {
		url := hub_user_mode_url(os.args)
		if url == "" do url = "http://127.0.0.1:49328"
		tok := hub_user_mode_token(os.args)
		ctl_hub_request(ctl_hub_make(strings.trim_right(url, "/"), tok), {method = .GET, path = ctl_api("health")})
		return
	}

	if cmd[0] == "help" {
		ctl_help(cmd[:])
		return
	}

	// Harness extension hooks run inside the provider's hook processes: dispatch
	// them before any mode logic so a missing agent context is a silent no-op.
	if cmd[0] == "extension" || cmd[0] == "extensions" {
		ctl_extension_command(cmd[:], os.args)
		return
	}

	// REQ-CLI-3: `search --help` must reach SEARCH help in BOTH modes. This check
	// used to live inside the user-mode-only block below, so in an agent context it
	// was unreachable: search fell through to the agent_ctx switch and ctl_agent_mode
	// answered --help with the ROOT overview, leaving the agent-mode flag surface
	// (--cursor, the typed id filters, the negations, --exclude) undocumented. It is
	// hoisted above the mode split and told which mode to render, because the two
	// modes genuinely accept different flags.
	// The positional `search help` is honoured in AGENT MODE ONLY, and that is a
	// deliberate asymmetry rather than an oversight. In agent mode it already
	// resolved to help (ctl_agent_mode treats a "help" action that way) and merely
	// printed the WRONG page, so only which page prints changes. In USER mode it
	// resolved to a genuine search for the word "help" — verified against a binary
	// built from HEAD — so treating it as help there would silently change search
	// behavior, which this task explicitly must not do.
	search_agent_ctx := agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != ""
	search_help_asked := has_flag(os.args, "--help") || has_flag(os.args, "-h") ||
		(search_agent_ctx && len(cmd) >= 2 && cmd[1] == "help")
	if cmd[0] == "search" && search_help_asked {
		print_search_help(search_agent_ctx)
		return
	}

	// User-mode search hits GET /api/v1/search with a user token. In an agent
	// context (bridge endpoint + agent token present) search instead routes
	// through agent mode (agent.search RPC) via the agent_ctx switch below, so
	// this early user-mode return is skipped when running as an agent.
	if cmd[0] == "search" && !(agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != "") {
		ctl_search_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "vault" {
		ctl_vault_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "setup" || cmd[0] == "doctor" {
		ctl_setup_command(os.args)
		return
	}

	if cmd[0] == "hub" || has_flag(os.args, "--hub") {
		ctl_hub_user_mode(cmd[:], os.args)
		return
	}

	if cmd[0] == "agent" || has_flag(os.args, "--agent-mode") {
		ctl_agent_mode(cmd[:], os.args)
		return
	}

	// Agent API v2: when running inside a Bridge-launched agent (local endpoint +
	// token exported by the managed run-dir bin/ham-ctl shim), the agent-facing
	// groups dispatch through agent mode WITHOUT the `agent` prefix. This takes
	// priority over the legacy user-mode task/task-chain commands.
	agent_ctx := agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != ""
	if agent_ctx {
		switch cmd[0] {
		case "bridge", "bridges", "agents", "task-chain", "task-chains",
		     "task", "tasks", "chat", "chats", "artifact", "artifacts",
		     "memory", "cards", "card", "action", "actions", "context", "search", "shell",
		     "issue", "issues", "project", "projects", "lease", "review", "verify",
		     "workflow", "workflows":
			ctl_agent_mode(cmd[:], os.args)
			return
		}
	}

	// Agent-facing groups always render v2 help on --help even without an agent
	// context (so `ham-ctl task --help` documents the agent surface).
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		switch cmd[0] {
		case "bridge", "bridges", "agents", "task-chain", "task-chains", "task", "tasks", "chat", "chats", "artifact", "artifacts", "memory", "cards", "card", "action", "actions", "shell", "issue", "issues", "project", "projects", "lease", "review", "verify", "workflow", "workflows":
			print_agent_help(cmd[:]); return
		}
	}

	if cmd[0] == "workflow" || cmd[0] == "workflows" {
		ctl_workflow_user_mode(cmd[:], os.args)
		return
	}

	// User-mode (no agent context): legacy hub-scoped task/chain commands.
	if cmd[0] == "task-chains" || cmd[0] == "task-chain" || cmd[0] == "chains" || cmd[0] == "chain" {
		ctl_task_chains_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "tasks" || cmd[0] == "task" {
		ctl_tasks_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "actions" || cmd[0] == "action" || cmd[0] == "scheduled-prompts" || cmd[0] == "scheduled-prompt" {
		url := hub_user_mode_url(os.args)
		tok := hub_user_mode_token(os.args)
		if url == "" || tok == "" {
			fmt.println(`{"ok":false,"message":"actions requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`)
			return
		}
		ctl_hub_actions(ctl_hub_make(strings.trim_right(url, "/"), tok), cmd[1:], os.args)
		return
	}

	if cmd[0] == "issue" || cmd[0] == "issues" {
		ctl_issues_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "projects" || cmd[0] == "project" {
		ctl_projects_command(cmd[:], os.args)
		return
	}

	if cmd[0] == "start-success" {
		if agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != "" {
			agent_cmd := [?]string{"agent", "start-success"}
			ctl_agent_mode(agent_cmd[:], os.args)
			return
		}
		fmt.println(`{"ok":false,"message":"start-success is only available as 'ham-ctl agent start-success' inside a Bridge-launched agent"}`)
		os.exit(1)
	}

	print_usage(cfg_lib.config_path_from_args(os.args), "")
}
