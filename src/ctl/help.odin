package main

import "core:fmt"
import "core:os"
import "core:strings"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

ctl_help :: proc(cmd: []string) {
	if len(cmd) >= 2 && cmd[1] == "work-guide" {
		fmt.println(strings.trim_space(#load("../prompts/bootstrap_profile_guidance.md", string)))
		return
	}
	// REQ-CLI-3: `ham-ctl help search` renders the mode the caller is actually in,
	// matching `ham-ctl search --help` (main.odin) rather than always showing the
	// user-mode page to an agent.
	if len(cmd) >= 2 && cmd[1] == "search" {
		print_search_help(agent_mode_endpoint(os.args) != "" && agent_mode_token(os.args) != "")
		return
	}
	if len(cmd) >= 2 && cmd[1] == "hub" { print_hub_help(cmd[2:]); return }
	// `help agent` and any group name render the skill-style agent help.
	if len(cmd) >= 2 && cmd[1] == "agent" { print_agent_help(cmd[2:]); return }
	if len(cmd) >= 2 {
		switch cmd[1] {
		case "bridge", "bridges", "agents", "task-chain", "task-chains",
		     "task", "tasks", "chat", "chats", "artifact", "artifacts",
		     "memory", "context", "start-success", "issue", "issues", "lease", "review", "verify",
		     "workflow", "workflows":
			print_agent_help(cmd[1:]); return
		case "vault":
			print_vault_help(); return
		}
	}
	print_usage(cfg_lib.config_path_from_args(os.args), "")
}

// print_usage renders the Level-1 skill-style overview (agent API v2). The
// canonical text lives in print_help_overview (agent_mode.odin) so `ham-ctl`,
// `ham-ctl help`, and `ham-ctl --help` all show the same thing.
print_usage :: proc(config_path, daemon_url: string) {
	_ = config_path
	_ = daemon_url
	print_help_overview()
	fmt.println("")
	fmt.println("OTHER")
	// REQ-CLI-3: this line used to read "(needs --hub-url + --user-token)", which is
	// false for an agent — `ham-ctl search` works on a bare agent token in agent
	// mode — and read as "I lack credentials I cannot obtain", so agents abandoned
	// the single most useful retrieval command they have. The `hub` line below was
	// checked too and is CORRECT as written: hub_mode.odin hard-gates on
	// --hub-url + --user-token and has no agent-mode route, so it is left alone.
	fmt.println("  search Global entity search across the Hub; works on your agent token in")
	fmt.println("         agent mode (--hub-url + --user-token are for user mode only)")
	fmt.println("         Run `ham-ctl search --help` for the flags your mode accepts")
	fmt.println("  hub    Hub /api/v1 user commands (needs --hub-url + --user-token)")
	fmt.println("  help   ham-ctl <group> --help | ham-ctl help hub | ham-ctl help work-guide")
}

