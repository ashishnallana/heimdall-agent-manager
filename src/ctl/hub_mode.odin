package main

import "core:fmt"
import "core:os"
import "core:strings"
import base64 "core:encoding/base64"
import http "odin_test:lib/http_client"

ctl_hub_user_mode :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "hub" do idx = 1
	if idx >= len(cmd) || has_flag(args, "--help") || has_flag(args, "-h") || (idx < len(cmd) && cmd[idx] == "help") { print_hub_help(cmd[idx:]); return }
	resource := cmd[idx]
	action := ""
	if idx + 1 < len(cmd) do action = cmd[idx + 1]
	if action == "help" { print_hub_help(cmd[idx:]); return }
	hub_url := hub_user_mode_url(args)
	user_token := hub_user_mode_token(args)
	if ctl_user_token_removed(user_token) do return
	if hub_url == "" || user_token == "" { fmt.println(`{"ok":false,"message":"hub mode requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`); return }
	base := strings.trim_right(hub_url, "/")
	if resource == "me" { ctl_hub_request(base, user_token, "GET", "/api/v1/me", ""); return }
	if resource == "health" { ctl_hub_request(base, user_token, "GET", "/api/v1/health", ""); return }
	if resource == "agents" { ctl_hub_agents(base, user_token, action, args); return }
	if resource == "launch" { ctl_hub_launch(base, user_token, args); return }
	if resource == "chats" { ctl_hub_chats(base, user_token, action, args); return }
	if resource == "tasks" {
		fmt.eprintln("Notice: 'ham-ctl hub tasks' is deprecated; use top-level 'ham-ctl tasks' instead.")
		ctl_tasks_command(cmd[idx:], args)
		return
	}
	if resource == "task-chains" {
		fmt.eprintln("Notice: 'ham-ctl hub task-chains' is deprecated; use top-level 'ham-ctl task-chains' instead.")
		ctl_task_chains_command(cmd[idx:], args)
		return
	}
	if resource == "projects" || resource == "project" { ctl_hub_projects(base, user_token, action, args); return }
	if resource == "artifacts" || resource == "artifact" { ctl_hub_artifacts(base, user_token, cmd[idx + 1:], args); return }
	if resource == "memories" || resource == "memory" { ctl_hub_memories(base, user_token, cmd[idx + 1:], args); return }
	if resource == "cards" || resource == "card" { ctl_hub_cards(base, user_token, cmd[idx + 1:], args); return }
	if resource == "actions" || resource == "action" || resource == "scheduled-prompts" || resource == "scheduled-prompt" { ctl_hub_actions(base, user_token, cmd[idx + 1:], args); return }
	if resource == "issues" || resource == "issue" { ctl_issues_command(cmd[idx:], args); return }
	fmt.println("usage: ham-ctl hub <me|health|agents|launch|chats|tasks|task-chains|projects|artifacts|memories|cards|actions|issues> ...")
}

ctl_hub_agents :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/agents", ""); return }
	if action == "instances" { ctl_hub_request(base, token, "GET", "/api/v1/agent-instances", ""); return }
	if action == "running" || action == "live" { ctl_hub_request(base, token, "GET", "/api/v1/agent-instances?runtime_status=live", ""); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub agents create --name <name> [--slug <slug>] [--template <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("slug", option_value(args, "--slug", name))); append(&fields, json_kv("template_id", option_value(args, "--template", ""))); append(&fields, json_kv("instructions", option_value(args, "--instructions", "")))
		ctl_hub_request(base, token, "POST", "/api/v1/agents", json_object_from_slice(fields[:]))
		return
	}
	if action == "update" {
		// User token only: an agent must not be able to lift its own permission
		// gate, so the hub PATCH stays user-authenticated (REQ-EXT-PERM-2).
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" { fmt.println(CTL_HUB_AGENTS_UPDATE_USAGE); return }
		body, ok, msg := ctl_agents_update_params(args)
		if !ok { fmt.println(msg); fmt.println(CTL_HUB_AGENTS_UPDATE_USAGE); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/agents/%s", safe_path_part(agent_id)), body)
		return
	}
	fmt.println("usage: ham-ctl hub agents <list|instances|running|live|create|update>")
}

CTL_HUB_AGENTS_UPDATE_USAGE :: "usage: ham-ctl hub agents update --agent-id <agt_id> [--name <n>] [--slug <s>] [--template <id>] [--instructions <t>] [--permission-mode yolo|ask]"

// ctl_agents_update_params builds the PATCH /api/v1/agents/<id> body: only the
// fields passed are sent (the hub keeps the rest). --permission-mode is checked
// here so a typo fails locally instead of as a hub validation error.
ctl_agents_update_params :: proc(args: []string) -> (params: string, ok: bool, msg: string) {
	fields := make([dynamic]string)
	updates := 0
	if v := option_value(args, "--name", ""); v != "" { append(&fields, json_kv("name", v)); updates += 1 }
	if v := option_value(args, "--slug", ""); v != "" { append(&fields, json_kv("slug", v)); updates += 1 }
	if v := option_value(args, "--template", ""); v != "" { append(&fields, json_kv("template_id", v)); updates += 1 }
	if v := option_value(args, "--instructions", ""); v != "" { append(&fields, json_kv("instructions", v)); updates += 1 }
	if v := option_value(args, "--permission-mode", ""); v != "" {
		if v != "yolo" && v != "ask" do return "", false, "--permission-mode must be 'yolo' or 'ask'"
		append(&fields, json_kv("permission_mode", v)); updates += 1
	}
	if updates == 0 do return "", false, "agents update needs at least one of --name, --slug, --template, --instructions, --permission-mode"
	return json_object_from_slice(fields[:]), true, ""
}

ctl_hub_launch :: proc(base, token: string, args: []string) {
	agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
	provider := option_value(args, "--provider", "")
	model := option_value(args, "--model", "")
	if agent_id == "" || option_value(args, "--bridge-id", "") == "" || provider == "" || model == "" { fmt.println("usage: ham-ctl hub launch --agent-id <agent_id> --bridge-id <bridge_id> --provider <provider> --model <model> [--display-name <name>] [--project-id <id>] [--chain-id <id>]"); return }
	fields := make([dynamic]string)
	append(&fields, json_kv("agent_id", agent_id)); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("provider", provider)); append(&fields, json_kv("model", model)); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", "")))); append(&fields, json_kv("chain_id", option_value(args, "--chain-id", option_value(args, "--chain", ""))))
	if dn := option_value(args, "--display-name", ""); dn != "" do append(&fields, json_kv("display_name", dn))
	ctl_hub_request(base, token, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:]))
}

ctl_hub_chats :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/chats", ""); return }
	if action == "create" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		instance_id := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
		if agent_id == "" && instance_id == "" { fmt.println("usage: ham-ctl hub chats create --agent-id <agent_id>|--agent-instance-id <id> [--body <text>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id)); append(&fields, json_kv("agent_instance_id", instance_id)); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("provider", option_value(args, "--provider", ""))); append(&fields, json_kv("model", option_value(args, "--model", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", "")))); append(&fields, json_kv("chain_id", option_value(args, "--chain-id", option_value(args, "--chain", ""))))
		// The title and the first message are vault content (the UI seals and decrypts
		// both); sealed here too, never sent in plaintext (finding N3).
		title := option_value(args, "--title", "")
		body := option_value(args, "--body", "")
		if title != "" || body != "" {
			kr := ctl_vault_keyring_for_write(args)
			title = ctl_seal_if(title, kr)
			body = ctl_seal_if(body, kr)
		}
		append(&fields, json_kv("title", title))
		if body != "" do append(&fields, strings.concatenate({"\"initial_message\":", json_object(json_kv("body", body))}))
		ctl_hub_request(base, token, "POST", "/api/v1/chats", json_object_from_slice(fields[:]))
		return
	}
	if action == "send" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if cid == "" || body == "" { fmt.println("usage: ham-ctl hub chats send --conversation-id <id> --body <text>"); return }
		body = ctl_seal_if(body, ctl_vault_keyring_for_write(args))
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/chats/%s/messages", safe_path_part(cid)), json_object(json_kv("body", body)))
		return
	}
	if action == "messages" || action == "fetch" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		if cid == "" { fmt.println("usage: ham-ctl hub chats messages --conversation-id <id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/chats/%s/messages", safe_path_part(cid)), "")
		return
	}
	fmt.println("usage: ham-ctl hub chats <list|create|send|messages>")
}

ctl_hub_task_chains :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" {
		if has_flag(args, "--pinned") { ctl_hub_request(base, token, "GET", "/api/v1/task-chains?pinned=1", ""); return }
		ctl_hub_request(base, token, "GET", "/api/v1/task-chains", "")
		return
	}
	if action == "create" {
		title := option_value(args, "--title", "")
		if title == "" { fmt.println("usage: ham-ctl hub task-chains create --title <title> [--description <text>] [--kind <kind>] [--coordinator <id>]"); return }
		kr := ctl_vault_keyring_for_write(args)
		fields := make([dynamic]string)
		append(&fields, json_kv("title", ctl_seal_if(title, kr))); append(&fields, json_kv("description", ctl_seal_if(option_value(args, "--description", ""), kr))); append(&fields, json_kv("kind", option_value(args, "--kind", "team_work"))); append(&fields, json_kv("coordinator_agent_id", option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", "")))); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/task-chains", json_object_from_slice(fields[:]))
		return
	}
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains <show|update|members|publish|complete|pin|unpin> --chain-id <id>"); return }
	if action == "pin" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/pin", safe_path_part(chain_id)), "{\"pinned\":true}"); return }
	if action == "unpin" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/pin", safe_path_part(chain_id)), "{\"pinned\":false}"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), ""); return }
	if action == "update" {
		kr := ctl_vault_keyring_for_write(args)
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", ctl_seal_if(title, kr)))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", ctl_seal_if(desc, kr)))
		if status := option_value(args, "--status", ""); status != "" do append(&fields, json_kv("status", status))
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		return
	}
	if action == "members" {
		sub := option_value(args, "--action", "")
		if len(args) > 4 && (args[3] == "add" || args[3] == "remove" || args[3] == "list") do sub = args[3]
		if sub == "" || sub == "list" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), ""); return }
		if sub == "add" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
			role := option_value(args, "--role", "assignee")
			if inst == "" { fmt.println("usage: ham-ctl hub task-chains members --chain-id <id> add --agent-instance-id <id> [--role <role>]"); return }
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), json_object(json_kv("agent_instance_id", inst), json_kv("role", role))); return
		}
		if sub == "remove" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
			if inst == "" { fmt.println("usage: ham-ctl hub task-chains members --chain-id <id> remove --agent-instance-id <id>"); return }
			ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/members/%s", safe_path_part(chain_id), safe_path_part(inst)), ""); return
		}
	}
	if action == "directory" || action == "directories" {
		sub := option_value(args, "--action", "")
		if len(args) > 4 && (args[3] == "add" || args[3] == "update" || args[3] == "remove" || args[3] == "list") do sub = args[3]
		if sub == "" || sub == "list" {
			if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains directory list --chain-id <id>"); return }
			ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/directories", safe_path_part(chain_id)), ""); return
		}
		if sub == "add" {
			path := option_value(args, "--path", option_value(args, "--dir", ""))
			if chain_id == "" || path == "" {
				fmt.println("usage: ham-ctl hub task-chains directory add --chain-id <id> --path <path> [--bridge-id <id>] [--vcs-kind <kind>] [--vcs <json>]")
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
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/directories", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
			return
		}
		if sub == "update" {
			dir_id := option_value(args, "--directory-id", option_value(args, "--directory", option_value(args, "--dir-id", option_value(args, "--id", ""))))
			if chain_id == "" || dir_id == "" {
				fmt.println("usage: ham-ctl hub task-chains directory update --chain-id <id> --directory-id <id> [--path <path>] [--bridge-id <id>] [--vcs-kind <kind>] [--vcs <json>]")
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
			ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/directories/%s", safe_path_part(chain_id), safe_path_part(dir_id)), json_object_from_slice(fields[:]))
			return
		}
		if sub == "remove" || sub == "delete" {
			dir_id := option_value(args, "--directory-id", option_value(args, "--directory", option_value(args, "--dir-id", option_value(args, "--id", ""))))
			if chain_id == "" || dir_id == "" {
				fmt.println("usage: ham-ctl hub task-chains directory remove --chain-id <id> --directory-id <id>")
				return
			}
			ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/directories/%s", safe_path_part(chain_id), safe_path_part(dir_id)), ""); return
		}
	}
	if action == "add-agent" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if chain_id == "" || agent_id == "" { fmt.println("usage: ham-ctl hub task-chains add-agent --chain-id <id> --agent-id <id> [--bridge-id <id>] [--provider <profile>] [--model <model>] [--project-id <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		append(&fields, json_kv("chain_id", chain_id))
		if b := option_value(args, "--bridge-id", ""); b != "" do append(&fields, json_kv("bridge_id", b))
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
		if t := option_value(args, "--model", ""); t != "" do append(&fields, json_kv("model", t))
		if pr := option_value(args, "--project-id", ""); pr != "" do append(&fields, json_kv("project_id", pr))
		ctl_hub_request(base, token, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:])); return
	}
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/publish", safe_path_part(chain_id)), "{}"); return }
	if action == "complete" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/complete", safe_path_part(chain_id)), "{}"); return }
	if action == "set-status" || action == "status" {
		status := option_value(args, "--status", "")
		if status == "" || chain_id == "" { fmt.println("usage: ham-ctl hub task-chains set-status --chain-id <id> --status <active|cancelled|archived>"); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", status)))
		return
	}
	if action == "archive" {
		if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains archive --chain-id <id>"); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "archived")))
		return
	}
	if action == "unarchive" {
		if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains unarchive --chain-id <id>"); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "active")))
		return
	}
	fmt.println("usage: ham-ctl hub task-chains <list|create|show|update|members|directory|add-agent|publish|complete|set-status|archive|unarchive|pin|unpin>")
}

ctl_hub_tasks :: proc(base, token, action: string, args: []string) {
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if action == "list" {
		if chain_id == "" { fmt.println("usage: ham-ctl hub tasks list --chain-id <id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), ""); return
	}
	if action == "create" {
		title := option_value(args, "--title", "")
		if chain_id == "" || title == "" { fmt.println("usage: ham-ctl hub tasks create --chain-id <id> --title <title> [--description <desc>] [--assignee <agt_id>] [--reviewer <agt_id>]... [--require-user-approval] [--depends-on <id,id>]"); return }
		if !ctl_task_reviewer_flags_valid(args, false) do return
		kr := ctl_vault_keyring_for_write(args)
		fields := make([dynamic]string)
		append(&fields, json_kv("title", ctl_seal_if(title, kr)))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", ctl_seal_if(desc, kr)))
		if assignee := option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")); assignee != "" do append(&fields, ctl_v2_assignee_field(assignee))
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do append(&fields, ctl_v2_reviewers_field(args))
		if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
		if deps := option_value(args, "--depends-on", option_value(args, "--on", "")); deps != "" {
			parts := strings.split(deps, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"depends_on\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), json_object_from_slice(fields[:])); return
	}
	task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
	if chain_id == "" || task_id == "" { fmt.println("usage: ham-ctl hub tasks <update|publish|cancel|depend|comments> --chain-id <id> --task-id <id>"); return }
	if action == "update" {
		if !ctl_task_reviewer_flags_valid(args, true) do return
		kr := ctl_vault_keyring_for_write(args)
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", ctl_seal_if(title, kr)))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", ctl_seal_if(desc, kr)))
		if assignee := option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")); assignee != "" do append(&fields, ctl_v2_assignee_field(assignee))
		if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") do append(&fields, ctl_v2_reviewers_field(args))
		if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
		if has_flag(args, "--no-require-user-approval") do append(&fields, `"requires_user_approval":false`)
		if deps := option_value(args, "--depends-on", option_value(args, "--on", "")); deps != "" {
			parts := strings.split(deps, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"depends_on\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:])); return
	}
	if action == "depend" {
		on_id := option_value(args, "--on", option_value(args, "--depends-on", ""))
		if on_id == "" { fmt.println("usage: ham-ctl hub tasks depend --chain-id <id> --task-id <id> --on <depends_on_task_id>"); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object(strings.concatenate({"\"depends_on\":[\"", on_id, "\"]"}))); return
	}
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/publish", safe_path_part(chain_id), safe_path_part(task_id)), "{}"); return }
	if action == "cancel" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", safe_path_part(chain_id), safe_path_part(task_id)), "{}"); return }
	if action == "comments" {
		sub := option_value(args, "--action", "")
		if len(args) > 5 && (args[5] == "add" || args[5] == "list") do sub = args[5]
		if sub == "" || sub == "list" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), ""); return }
		if sub == "add" {
			body := option_value(args, "--body", "")
			if body == "" { fmt.println("usage: ham-ctl hub tasks comments --chain-id <id> --task-id <id> add --body <text> [--notify <id,id...>]"); return }
			kr := ctl_vault_keyring_for_write(args)
			fields := make([dynamic]string)
			append(&fields, json_kv("body", ctl_seal_if(body, kr)))
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
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:])); return
		}
	}
	fmt.println("usage: ham-ctl hub tasks <list|create|update|publish|cancel|depend|comments>")
}

ctl_hub_projects :: proc(base, token, action: string, args: []string) {
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)

	if action == "" || action == "list" {
		resp, ok := ctl_hub_request_string(base, token, "GET", "/api/v1/projects", "")
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub projects create --name <name> [--slug <slug>] [--description <text>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"); return }
		desc := option_value(args, "--description", option_value(args, "--desc", ""))
		keyring = ctl_vault_keyring_for_write(args)
		key_ok = true
		if !is_vault_armored(name) {
			name = ctl_seal_or_exit(name, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("name", name))
		append(&fields, json_kv("slug", option_value(args, "--slug", "")))
		if desc != "" do append(&fields, json_kv("description", desc))
		append(&fields, json_kv("repo_url", option_value(args, "--repo-url", option_value(args, "--repo", ""))))
		append(&fields, json_kv("vcs_kind", option_value(args, "--vcs-kind", "")))
		append(&fields, json_kv("default_path", option_value(args, "--default-path", option_value(args, "--path", ""))))
		resp, ok := ctl_hub_request_string(base, token, "POST", "/api/v1/projects", json_object_from_slice(fields[:]))
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	project_id := option_value(args, "--project-id", option_value(args, "--project", ""))
	if project_id == "" { fmt.println("usage: ham-ctl hub projects <show|update> --project-id <id>"); return }
	if action == "show" {
		resp, ok := ctl_hub_request_string(base, token, "GET", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), "")
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	if action == "update" {
		keyring = ctl_vault_keyring_for_write(args)
		key_ok = true
		fields := make([dynamic]string)
		defer delete(fields)
		if name := option_value(args, "--name", ""); name != "" {
			if !is_vault_armored(name) {
				name = ctl_seal_or_exit(name, keyring)
			}
			append(&fields, json_kv("name", name))
		}
		if slug := option_value(args, "--slug", ""); slug != "" do append(&fields, json_kv("slug", slug))
		if desc := option_value(args, "--description", option_value(args, "--desc", "")); desc != "" {
			if !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
			append(&fields, json_kv("description", desc))
		}
		if repo := option_value(args, "--repo-url", option_value(args, "--repo", "")); repo != "" do append(&fields, json_kv("repo_url", repo))
		if vcs := option_value(args, "--vcs-kind", ""); vcs != "" do append(&fields, json_kv("vcs_kind", vcs))
		if path := option_value(args, "--default-path", option_value(args, "--path", "")); path != "" do append(&fields, json_kv("default_path", path))
		resp, ok := ctl_hub_request_string(base, token, "PATCH", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), json_object_from_slice(fields[:]))
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	fmt.println("usage: ham-ctl hub projects <list|create|show|update>")
}

ctl_hub_artifacts :: proc(base, token: string, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := make([dynamic]string)
		defer delete(query)
		if p := option_value(args, "--project-id", option_value(args, "--project", "")); p != "" do query_param(&query, "project_id", p)
		if ai := option_value(args, "--agent-instance-id", option_value(args, "--agent-instance", "")); ai != "" do query_param(&query, "agent_instance_id", ai)
		if a := option_value(args, "--agent-id", option_value(args, "--agent", "")); a != "" do query_param(&query, "agent_id", a)
		if t := option_value(args, "--task-id", option_value(args, "--task", "")); t != "" do query_param(&query, "task_id", t)
		if c := option_value(args, "--chain-id", option_value(args, "--chain", "")); c != "" do query_param(&query, "chain_id", c)
		if k := option_value(args, "--kind", ""); k != "" do query_param(&query, "kind", k)
		if s := option_value(args, "--since", ""); s != "" do query_param(&query, "since", s)
		if u := option_value(args, "--until", ""); u != "" do query_param(&query, "until", u)
		if s := option_value(args, "--sort", option_value(args, "--sort-field", "")); s != "" do query_param(&query, "sort", s)
		if o := option_value(args, "--order", option_value(args, "--sort-order", "")); o != "" do query_param(&query, "order", o)
		if l := option_value(args, "--limit", ""); l != "" do query_param(&query, "limit", l)
		if cur := option_value(args, "--cursor", ""); cur != "" do query_param(&query, "cursor", cur)
		if has_flag(args, "--include-deleted") do append(&query, "include_deleted=true")

		path := "/api/v1/artifacts"
		if len(query) > 0 {
			path = fmt.tprintf("/api/v1/artifacts?%s", strings.join(query[:], "&"))
		}
		ctl_hub_request(base, token, "GET", path, "")
		return
	}
	if action == "create" {
		name := option_value(args, "--name", "")
		content := option_value(args, "--content", "")
		content_base64 := ""
		if file_path := option_value(args, "--file", ""); file_path != "" { data, err := os.read_entire_file(file_path, context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if name == "" { fmt.println("usage: ham-ctl hub artifacts create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("kind", option_value(args, "--kind", "file")))
		if content_base64 != "" { append(&fields, json_kv("content_base64", content_base64)) } else { append(&fields, json_kv("content", content)) }
		append(&fields, json_kv("description", option_value(args, "--description", ""))); append(&fields, json_kv("content_type", option_value(args, "--content-type", option_value(args, "--mime", "")))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/artifacts", json_object_from_slice(fields[:]))
		return
	}
	artifact_id := pos(tokens, 1)
	if artifact_id == "" do artifact_id = option_value(args, "--artifact-id", option_value(args, "--artifact", option_value(args, "--id", "")))
	if artifact_id == "" { fmt.println("usage: ham-ctl hub artifacts <show|content|update|delete> --artifact-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), ""); return }
	if action == "content" || action == "get" { ctl_hub_request_raw(base, token, "GET", fmt.tprintf("/api/v1/artifacts/%s/content", safe_path_part(artifact_id)), ""); return }
	if action == "update" { ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), json_object(json_kv("name", option_value(args, "--name", "")), json_kv("description", option_value(args, "--description", "")))); return }
	if action == "delete" { ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), ""); return }
	fmt.println("usage: ham-ctl hub artifacts <list|create|show|content|update|delete>")
}

ctl_hub_memories :: proc(base, token: string, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := make([dynamic]string)
		defer delete(query)
		if s := option_value(args, "--status", ""); s != "" do query_param(&query, "status", s)
		if t := option_value(args, "--type", ""); t != "" do query_param(&query, "type", t)
		if l := option_value(args, "--limit", ""); l != "" do query_param(&query, "limit", l)

		agent_ids := collect_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"); defer delete(agent_ids)
		if len(agent_ids) > 0 do query_param(&query, "agent_ids", strings.join(agent_ids[:], ","))

		project_ids := collect_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"); defer delete(project_ids)
		if len(project_ids) > 0 do query_param(&query, "project_ids", strings.join(project_ids[:], ","))

		bridge_ids := collect_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"); defer delete(bridge_ids)
		if len(bridge_ids) > 0 do query_param(&query, "bridge_ids", strings.join(bridge_ids[:], ","))

		template_ids := collect_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"); defer delete(template_ids)
		if len(template_ids) > 0 do query_param(&query, "template_ids", strings.join(template_ids[:], ","))

		path := "/api/v1/memories"
		if len(query) > 0 {
			path = fmt.tprintf("/api/v1/memories?%s", strings.join(query[:], "&"))
		}
		ctl_hub_request(base, token, "GET", path, "")
		return
	}
	if action == "create" || action == "propose" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if body == "" { fmt.println("usage: ham-ctl hub memories create --body <text> [--type <type>] [--title <title>] [--description <text>] [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("body", body)); append(&fields, json_kv("type", option_value(args, "--type", "fact"))); append(&fields, json_kv("title", option_value(args, "--title", ""))); append(&fields, json_kv("description", option_value(args, "--description", ""))); append(&fields, json_kv("evidence", option_value(args, "--evidence", "")))
		// Targeting lists match the T1 contract (agent_ids/project_ids/bridge_ids/
		// template_ids). Each dimension is repeatable AND/OR comma-separated; an
		// omitted dimension is sent as an empty array (applies to all).
		agent_ids := collect_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"); defer delete(agent_ids)
		project_ids := collect_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"); defer delete(project_ids)
		bridge_ids := collect_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"); defer delete(bridge_ids)
		template_ids := collect_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"); defer delete(template_ids)
		append(&fields, json_string_array_field("agent_ids", agent_ids[:]))
		append(&fields, json_string_array_field("project_ids", project_ids[:]))
		append(&fields, json_string_array_field("bridge_ids", bridge_ids[:]))
		append(&fields, json_string_array_field("template_ids", template_ids[:]))
		ctl_hub_request(base, token, "POST", "/api/v1/memories", json_object_from_slice(fields[:]))
		return
	}
	memory_id := pos(tokens, 1)
	if memory_id == "" do memory_id = option_value(args, "--memory-id", option_value(args, "--memory", option_value(args, "--id", "")))
	if memory_id == "" { fmt.println("usage: ham-ctl hub memories <show|content|approve|reject|archive> <id> (or --memory-id <id>)"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/memories/%s", safe_path_part(memory_id)), ""); return }
	if action == "content" || action == "get" {
		ctl_hub_memory_content(base, token, memory_id)
		return
	}
	if action == "approve" || action == "reject" || action == "archive" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/memories/%s/%s", safe_path_part(memory_id), action), "{}"); return }
	fmt.println("usage: ham-ctl hub memories <list|create|show|content|approve|reject|archive>")
}

ctl_hub_memory_content :: proc(base, user_token, memory_id: string) {
	full_path := hub_url_path_prefix_join(base, fmt.tprintf("/api/v1/memories/%s", safe_path_part(memory_id)))
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", user_token})}}
	response, ok := http.request_with_headers_timeout("GET", base, full_path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return }
	if response.status >= 400 {
		fmt.println(response.body)
		return
	}
	body := extract_json_string_unescaped(response.body, "body", "")
	fmt.print(body)
}

ctl_hub_cards :: proc(base, token: string, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := make([dynamic]string)
		defer delete(query)
		if s := option_value(args, "--status", ""); s != "" do query_param(&query, "status", s)
		if sc := option_value(args, "--scope", ""); sc != "" do query_param(&query, "scope", sc)
		if p := option_value(args, "--provider", ""); p != "" do query_param(&query, "provider", p)
		if pid := option_value(args, "--project", option_value(args, "--project-id", "")); pid != "" do query_param(&query, "project_id", pid)
		if l := option_value(args, "--limit", ""); l != "" do query_param(&query, "limit", l)

		path := "/api/v1/cards"
		if len(query) > 0 {
			path = fmt.tprintf("/api/v1/cards?%s", strings.join(query[:], "&"))
		}
		ctl_hub_request(base, token, "GET", path, "")
		return
	}
	if action == "show" || action == "get" {
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { fmt.println("usage: ham-ctl hub cards show <card-id>"); return }
		if has_flag(args, "--json") || has_flag(args, "--raw") {
			ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/cards/%s", safe_path_part(card_id)), "")
			return
		}
		full_path := hub_url_path_prefix_join(base, fmt.tprintf("/api/v1/cards/%s", safe_path_part(card_id)))
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
		response, ok := http.request_with_headers_timeout("GET", base, full_path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
		if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return }
		render_human_card(response.body)
		return
	}
	if action == "create" {
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { fmt.println("usage: ham-ctl hub cards create --title <title> [--rationale <text>] [--scope <project|global>] [--provider <provider>] [--confidence <float>] [--project <id>] [--source-refs <json>] [--operations <json>] [--guard <json>]"); return }
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("title", title))
		if r := option_value(args, "--rationale", ""); r != "" do append(&fields, json_kv("rationale", r))
		if sc := option_value(args, "--scope", ""); sc != "" do append(&fields, json_kv("scope", sc))
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
		if c := option_value(args, "--confidence", ""); c != "" do append(&fields, json_kv_raw("confidence", c))
		if pid := option_value(args, "--project", option_value(args, "--project-id", "")); pid != "" do append(&fields, json_kv("project_id", pid))
		if sr := option_value(args, "--source-refs", ""); sr != "" do append(&fields, json_kv_raw("source_refs", sr))
		if ops := option_value(args, "--operations", ""); ops != "" do append(&fields, json_kv_raw("operations", ops))
		if g := option_value(args, "--guard", ""); g != "" do append(&fields, json_kv_raw("guard", g))
		if s := option_value(args, "--status", ""); s != "" do append(&fields, json_kv("status", s))
		if su := option_value(args, "--snooze-until", ""); su != "" do append(&fields, json_kv("snooze_until", su))
		if ttl := option_value(args, "--ttl-at", ""); ttl != "" do append(&fields, json_kv("ttl_at", ttl))
		ctl_hub_request(base, token, "POST", "/api/v1/cards", json_object_from_slice(fields[:]))
		return
	}
	if action == "discard" || action == "accept" || action == "reject" || action == "snooze" {
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { fmt.printf("usage: ham-ctl hub cards %s <card-id>\n", action); return }
		body := "{}"
		if action == "snooze" {
			su := option_value(args, "--snooze-until", "")
			body = json_object(json_kv("snooze_until", su))
		}
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/cards/%s/%s", safe_path_part(card_id), action), body)
		return
	}
	fmt.println("usage: ham-ctl hub cards <list|show|create|discard|accept|reject|snooze> ...")
}

ctl_hub_actions :: proc(base, token: string, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := make([dynamic]string)
		defer delete(query)
		if inst := option_value(args, "--instance", option_value(args, "--instance-id", option_value(args, "--target-instance-id", ""))); inst != "" {
			query_param(&query, "instance_id", inst)
		}
		path := "/api/v1/actions"
		if len(query) > 0 {
			path = fmt.tprintf("/api/v1/actions?%s", strings.join(query[:], "&"))
		}
		ctl_hub_request(base, token, "GET", path, "")
		return
	}
	if action == "show" || action == "get" {
		action_id := pos(tokens, 1)
		if action_id == "" do action_id = option_value(args, "--action-id", option_value(args, "--action", option_value(args, "--id", "")))
		if action_id == "" { fmt.println("usage: ham-ctl hub actions show <action-id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/actions/%s", safe_path_part(action_id)), "")
		return
	}
	if action == "delete" || action == "remove" {
		action_id := pos(tokens, 1)
		if action_id == "" do action_id = option_value(args, "--action-id", option_value(args, "--action", option_value(args, "--id", "")))
		if action_id == "" { fmt.println("usage: ham-ctl hub actions delete <action-id>"); return }
		ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/actions/%s", safe_path_part(action_id)), "")
		return
	}
	if action == "run" {
		action_id := pos(tokens, 1)
		if action_id == "" do action_id = option_value(args, "--action-id", option_value(args, "--action", option_value(args, "--id", "")))
		if action_id == "" { fmt.println("usage: ham-ctl hub actions run <action-id>"); return }
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/actions/%s/run", safe_path_part(action_id)), "{}")
		return
	}
	if action == "create" {
		prompt := option_value(args, "--prompt", option_value(args, "--body", ""))
		if prompt == "" {
			fmt.println("usage: ham-ctl hub actions create --prompt <text> (--instance <id> | --agent-id <id> --bridge <id>) [--provider <p>] [--model <t>] [--project <id>] [--instance-strategy reuse|fresh_per_run] [--cron <expr>] [--timezone <tz>] [--interval <int>] [--active-from <t>] [--active-until <t>] [--blackout-dates <json>] [--target-run-at <t>]")
			return
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("prompt_text", prompt))

		if inst := option_value(args, "--instance", option_value(args, "--instance-id", option_value(args, "--target-instance-id", ""))); inst != "" {
			append(&fields, json_kv("target_instance_id", inst))
		}
		if agt := option_value(args, "--agent-id", option_value(args, "--agent", option_value(args, "--target-agent-id", ""))); agt != "" {
			append(&fields, json_kv("target_agent_id", agt))
		}
		if br := option_value(args, "--bridge", option_value(args, "--bridge-id", option_value(args, "--target-bridge-id", ""))); br != "" {
			append(&fields, json_kv("target_bridge_id", br))
		}
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("target_provider", p))
		if t := option_value(args, "--model", ""); t != "" do append(&fields, json_kv("target_model", t))
		if pid := option_value(args, "--project", option_value(args, "--project-id", option_value(args, "--target-project-id", ""))); pid != "" {
			append(&fields, json_kv("target_project_id", pid))
		}
		if strat := option_value(args, "--instance-strategy", ""); strat != "" do append(&fields, json_kv("instance_strategy", strat))
		if cron := option_value(args, "--cron", ""); cron != "" do append(&fields, json_kv("cron_expr", cron))
		if tz := option_value(args, "--timezone", ""); tz != "" do append(&fields, json_kv("timezone", tz))
		if interval := option_value(args, "--interval", ""); interval != "" do append(&fields, json_kv("interval", interval))
		if af := option_value(args, "--active-from", ""); af != "" do append(&fields, json_kv("active_from", af))
		if au := option_value(args, "--active-until", ""); au != "" do append(&fields, json_kv("active_until", au))
		if bo := option_value(args, "--blackout-dates", ""); bo != "" do append(&fields, json_kv("blackout_dates", bo))
		if tra := option_value(args, "--target-run-at", ""); tra != "" do append(&fields, json_kv("target_run_at", tra))

		ctl_hub_request(base, token, "POST", "/api/v1/actions", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl hub actions <list|show|create|delete|run> ...")
}

hub_user_mode_url :: proc(args: []string) -> string {
	if v := option_value(args, "--hub-url", ""); v != "" do return v
	if v := option_value(args, "--daemon-url", ""); v != "" do return v
	if v := os.get_env_alloc("HAM_HUB_URL", context.allocator); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_HUB_URL", context.allocator); v != "" do return v
	return ""
}

hub_user_mode_token :: proc(args: []string) -> string {
	if v := option_value(args, "--user-token", ""); v != "" do return v
	if v := option_value(args, "--token", ""); v != "" do return v
	if v := os.get_env_alloc("HAM_HUB_USER_TOKEN", context.allocator); v != "" do return v
	if v := os.get_env_alloc("HAM_USER_TOKEN", context.allocator); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_USER_TOKEN", context.allocator); v != "" do return v
	return ""
}

ctl_hub_request_string :: proc(base, user_token, method, path, body: string) -> (string, bool) {
	full_path := hub_url_path_prefix_join(base, path)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", user_token})}}
	response, ok := http.request_with_headers_timeout(method, base, full_path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return "", false }
	return response.body, true
}

ctl_hub_request :: proc(base, user_token, method, path, body: string) {
	// Preserve any path prefix present in the hub base URL (e.g. when the Hub is
	// served behind a reverse proxy under /heimdall). The HTTP client drops the
	// path from the base URL, so we prepend the prefix to the request path.
	// This makes `ham-ctl hub ... --hub-url http://host/prefix` match `curl`.
	resp, ok := ctl_hub_request_string(base, user_token, method, path, body)
	if !ok do return
	fmt.println(resp)
}

ctl_hub_request_raw :: proc(base, user_token, method, path, body: string) {
	full_path := hub_url_path_prefix_join(base, path)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", user_token})}}
	response, ok := http.request_with_headers_timeout(method, base, full_path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return }
	_, _ = os.write(os.stdout, transmute([]byte)response.body)
}

hub_url_path_prefix :: proc(base: string) -> string {
	url := base
	if strings.has_prefix(url, "https://") {
		url = url[len("https://"):]
	} else if strings.has_prefix(url, "http://") {
		url = url[len("http://"):]
	}
	slash := strings.index_byte(url, '/')
	if slash < 0 do return ""
	return strings.trim_right(url[slash:], "/")
}

hub_url_path_prefix_join :: proc(base, path: string) -> string {
	prefix := hub_url_path_prefix(base)
	if prefix == "" do return path
	return strings.concatenate({prefix, path})
}

print_hub_help :: proc(cmd: []string) {
	resource := ""
	if len(cmd) > 0 {
		if cmd[0] == "hub" || cmd[0] == "help" { if len(cmd) > 1 do resource = cmd[1] } else { resource = cmd[0] }
	}
	if resource == "agents" { fmt.println("ham-ctl hub agents <list|create|update>\nPurpose: manage durable Hub agent identities.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents create --name reviewer --model normal\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents update --agent-id agt_123 --permission-mode ask"); return }
	if resource == "launch" { fmt.println("ham-ctl hub launch --agent-id <id> [--bridge-id <id>] [--model <model>]\nPurpose: start a new agent instance through Hub/Bridge.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... launch --agent-id reviewer --model normal"); return }
	if resource == "chats" { fmt.println("ham-ctl hub chats <list|create|send|messages>\nPurpose: read/write user chat conversations.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats send --conversation-id chat_123 --body 'Hello'"); return }
	if resource == "tasks" { fmt.println("ham-ctl hub tasks <list|create|update|publish|cancel|depend|comments> --chain-id <id>\nPurpose: manage Hub task records.\nUser approval:\n  create ... --require-user-approval\n  update ... --require-user-approval | --no-require-user-approval\n  --assignee/--reviewer take durable agent ids (agt_...) only.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... tasks list --chain-id chain_123"); return }
	if resource == "task-chains" { fmt.println("ham-ctl hub task-chains <list|create|show|directory|publish|complete|pin|unpin>\nPurpose: manage Hub task chains.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... task-chains create --title 'Fix bug'"); return }
	if resource == "projects" { fmt.println("ham-ctl hub projects <list|create|show|update>\nPurpose: manage Hub projects.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects create --name demo --repo-url https://example/repo.git"); return }
	if resource == "artifacts" { fmt.println("ham-ctl hub artifacts <list|create|show|content|update|delete>\nPurpose: manage Hub artifacts.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts create --name notes --content 'hello'"); return }
	if resource == "memories" || resource == "memory" { fmt.println("ham-ctl hub memories <list|create|show|content|approve|reject|archive>\nPurpose: manage Hub memories.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories show mem_123\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories content mem_123\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories create --body 'Use nix check.' --title 'Test command'"); return }
	if resource == "cards" || resource == "card" {
		fmt.println("ham-ctl hub cards — action cards (user/Hub mode)")
		fmt.println("")
		fmt.println("VERBS")
		fmt.println("  list [--status <s>] [--scope <s>] [--provider <p>] [--project <id>] [--limit <n>]")
		fmt.println("                          List cards matching filters.")
		fmt.println("  show    <card-id> [--json|--raw]   Show card detail (formatted or raw JSON).")
		fmt.println("  create  --title <title> [--rationale <t>] [--scope <project|global>] [--provider <p>]")
		fmt.println("          [--confidence <f>] [--project <id>] [--source-refs <json>] [--operations <json>]")
		fmt.println("          [--guard <json>]   Create a new action card.")
		fmt.println("  discard <card-id>       Discard a card without executing operations.")
		fmt.println("  accept  <card-id>       Accept card and atomically execute all operations.")
		fmt.println("  reject  <card-id>       Reject a card (declined; operations not executed).")
		fmt.println("  snooze  <card-id> --snooze-until <ts>   Hide a card until the given time.")
		fmt.println("")
		fmt.println("OPERATIONS  (a card's operation types; each carries a human `label` shown in the dashboard)")
		fmt.println("  task.review             Post your review verdict on a task. args: task_id, attempt_no,")
		fmt.println("                          [verdict approve|request_changes (default approve)],")
		fmt.println("                          [summary (required for request_changes)], [findings <json array>].")
		fmt.println("  memory.approve          Approve a pending memory proposal.")
		fmt.println("  memory.reject           Reject a pending memory proposal.")
		fmt.println("  memory.create           Create a new durable memory.")
		fmt.println("  memory.update           Edit an existing memory's fields (incl. scope: agent/project/bridge/template ids).")
		fmt.println("  memory.delete           Archive (soft-delete) a memory.  (alias: memory.archive)")
		fmt.println("  project.update          Edit a project's name/description.")
		fmt.println("  project.delete          Archive (soft-delete) a project.")
		fmt.println("  task_chain.set_status   Change a task chain's status.")
		fmt.println("  agent.prompt            Send a prompt/message to an agent instance's conversation.")
		fmt.println("  agent.update            Edit a durable agent's fields (name/provider/model/instructions/...).")
		fmt.println("  agent.delete            Archive (soft-delete) a durable agent.")
		fmt.println("")
		fmt.println("  Operations run ATOMICALLY (all-or-nothing) only when a card is ACCEPTED; a single")
		fmt.println("  card may bundle several, applied in order.")
		fmt.println("")
		fmt.println("EXAMPLES")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards list")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards show crd_123")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards accept crd_123")
		return
	}
	if resource == "actions" || resource == "action" || resource == "scheduled-prompts" || resource == "scheduled-prompt" { fmt.println("ham-ctl hub actions <list|show|create|delete|run>\nPurpose: manage scheduled prompt actions.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... actions list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... actions create --prompt 'Run review' --agent-id curator --bridge brg_123 --cron '0 * * * *'\n  ham-ctl hub ... actions create --prompt 'Nightly' --agent-id curator --bridge brg_123 --cron '0 3 * * *' --instance-strategy fresh_per_run  # new instance each run, reaps the previous\nFlags:\n  --instance-strategy reuse|fresh_per_run  reuse (default) reuses/wakes an existing instance of the agent-id; fresh_per_run mints a NEW instance every run and stops the prior one (durable agent-id targets only)."); return }
	if resource == "issues" || resource == "issue" { print_issues_help(); return }
	fmt.println("ham-ctl hub — Hub /api/v1 user mode; uses Authorization: Bearer only")
	fmt.println("commands:")
	fmt.println("  me           Show authenticated user")
	fmt.println("  health       Check Hub API health")
	fmt.println("  agents       List/create durable agent identities")
	fmt.println("  launch       Start an agent instance")
	fmt.println("  chats        List/create/send/fetch chat")
	fmt.println("  tasks        List/create/update tasks")
	fmt.println("  task-chains  List/create/publish/complete chains")
	fmt.println("  projects     List/create/show/update projects")
	fmt.println("  artifacts    List/create/show/update artifacts")
	fmt.println("  memories     List/create/show/content/approve/reject/archive memories")
	fmt.println("  cards        List/show/create/discard/accept/reject/snooze action cards")
	fmt.println("  actions      List/create/show/delete/run scheduled prompt actions")
	fmt.println("  issues       List/show/create/update/comment/vote/unvote issues")
	fmt.println("examples:")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... me")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards list")
}

