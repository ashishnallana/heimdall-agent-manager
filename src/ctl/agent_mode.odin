package main

import os_random "odin_test:lib/os_random"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import base64 "core:encoding/base64"
import json "core:encoding/json"
import "core:strings"
import "core:time"
import local_socket "odin_test:lib/local_socket"
import vault "odin_test:lib/vault"

// ── agent mode: local Bridge endpoint client (RTE2E-7) ───────────────────────
// Agent mode talks ONLY to the local Bridge endpoint over JSONL v1 using the
// local agent token. It never holds or sends a Hub URL or Hub credential; the
// Bridge is the sole runtime process with Hub access and relays on the agent's
// behalf. Endpoint discovery: --bridge-endpoint / HEIMDALL_BRIDGE_ENDPOINT.
// Token discovery: --agent-token / HEIMDALL_AGENT_TOKEN.

// Agent API v2 dispatch (docs/agent-api-redesign.md). Groups: bridge, agents
// (identity|template|instance), task-chain, task, chat, memory, artifact,
// context, start-success. Positional ids; one flag per concept. The legacy
// `agent` prefix is still accepted (idx skips it) but not required.
ctl_agent_mode :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "agent" do idx = 1
	if idx >= len(cmd) || has_flag(args, "--help") || has_flag(args, "-h") || (idx < len(cmd) && cmd[idx] == "help") { print_agent_help(cmd[idx:]); return }
	resource := cmd[idx]
	rest := cmd[idx + 1:] // positional tokens after the group
	action := ""
	if len(rest) > 0 do action = rest[0]
	if action == "help" || has_flag(args, "--help") { print_agent_help(cmd[idx:]); return }
	endpoint := agent_mode_endpoint(args)
	token := agent_mode_token(args)
	if endpoint == "" || token == "" {
		fmt.println(`{"ok":false,"message":"agent mode requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
		return
	}
	switch resource {
	case "context":       ctl_agentmode_context(endpoint, token, args); return
	case "start-success": ctl_agent_call(endpoint, token, "agent.start_success", "{}"); return
	case "bridge":        ctl_v2_bridge(endpoint, token, rest, args); return
	case "agents":        ctl_v2_agents(endpoint, token, rest, args); return
	case "task-chain", "task-chains", "chain", "chains": ctl_v2_task_chain(endpoint, token, rest, args); return
	case "task", "tasks": ctl_v2_task(endpoint, token, rest, args); return
	case "lease":         ctl_v2_lease(endpoint, token, rest, args); return
	case "review":        ctl_v2_review(endpoint, token, rest, args); return
	case "verify":        ctl_v2_verify(endpoint, token, rest, args); return
	case "workflow", "workflows": ctl_v2_workflow(endpoint, token, rest, args); return
	case "chat", "chats", "conversation", "conversations": ctl_v2_chat(endpoint, token, rest, args); return
	case "memory":        ctl_v2_memory(endpoint, token, rest, args); return
	case "artifact", "artifacts": ctl_v2_artifact(endpoint, token, rest, args); return
	case "cards", "card":         ctl_v2_cards(endpoint, token, rest, args); return
	case "action", "actions":     ctl_v2_action(endpoint, token, rest, args); return
	case "search":        ctl_agentmode_search(endpoint, token, rest, args); return
	case "shell":         ctl_agentmode_shell(endpoint, token, rest, args); return
	case "issue", "issues": ctl_issues_command(cmd[idx:], args); return
	case "vault":           ctl_vault_command(cmd[idx:], args); return
	case "project", "projects": ctl_projects_command(cmd[idx:], args); return
	}
	print_agent_help(cmd[idx:])
}

// ---- search -------------------------------------------------------------
// Agent-mode search routes through the agent.search RPC (POST
// /api/v1/agent-actions/search), which accepts an agent token and scopes hits
// to the caller's owner. Output is the raw JSON envelope (curators consume it
// programmatically — the human pagination view of ctl_search_command is not
// used here). The non-agent user-mode path (ctl_search_command) is untouched.
ctl_agentmode_search :: proc(endpoint, token: string, tokens, args: []string) {
	// REQ-CLI-4: reject unrecognised flags before searching. Agent mode shares the
	// validator with user mode (src/ctl/search.odin) so the two accepted surfaces
	// cannot drift; agent_mode=true swaps --json for --cursor/--since.
	if bad := search_validate_flags(args, true); bad != "" {
		search_reject_unknown_flag(bad, true)
		return
	}
	query := pos(tokens, 0)
	if strings.trim_space(query) == "" {
		fmt.println(`{"ok":false,"message":"search requires a query: ham-ctl search <query> [--scope csv] [--limit N] [--cursor C] [--task-ids csv] [--chain-ids csv] [--project-ids csv] [--conversation-ids csv] [--not-in-task-ids csv] [--not-in-chain-ids csv] [--not-in-project-ids csv] [--not-in-conversation-ids csv] [--exclude text]"}`)
		return
	}
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("query", query))
	// scopes maps to the REST `types` param; the hub reads it as `scopes`.
	if v := option_value(args, "--scope", ""); v != "" do append(&fields, json_kv("scopes", v))
	// limit is a JSON number (json_int on the hub); emit raw when provided.
	if v := option_value(args, "--limit", ""); v != "" do append(&fields, json_kv_raw("limit", v))
	if v := option_value(args, "--cursor", option_value(args, "--since", "")); v != "" do append(&fields, json_kv("cursor", v))
	if v := option_value(args, "--task-ids", ""); v != "" do append(&fields, json_kv("task_ids", v))
	if v := option_value(args, "--chain-ids", ""); v != "" do append(&fields, json_kv("chain_ids", v))
	if v := option_value(args, "--project-ids", ""); v != "" do append(&fields, json_kv("project_ids", v))
	if v := option_value(args, "--conversation-ids", ""); v != "" do append(&fields, json_kv("conversation_ids", v))
	if v := option_value(args, "--not-in-task-ids", ""); v != "" do append(&fields, json_kv("not_in_task_ids", v))
	if v := option_value(args, "--not-in-chain-ids", ""); v != "" do append(&fields, json_kv("not_in_chain_ids", v))
	if v := option_value(args, "--not-in-project-ids", ""); v != "" do append(&fields, json_kv("not_in_project_ids", v))
	if v := option_value(args, "--not-in-conversation-ids", ""); v != "" do append(&fields, json_kv("not_in_conversation_ids", v))
	if v := option_value(args, "--exclude", ""); v != "" do append(&fields, json_kv("exclude", v))
	ctl_agent_call(endpoint, token, "agent.search", json_object_from_slice(fields[:]))
}

// ctl_shell_uint_flag returns the value of a non-negative integer flag as a bare
// numeric string suitable for json_kv_raw, falling back to `fallback` when the flag
// is absent, empty, or not all digits — so a typo like `--offset x` degrades to the
// default instead of producing invalid JSON on the wire.
ctl_shell_uint_flag :: proc(args: []string, name, fallback: string) -> string {
	v := strings.trim_space(option_value(args, name, ""))
	if v == "" do return fallback
	for ch in v {
		if ch < '0' || ch > '9' do return fallback
	}
	return v
}

// pos returns positional token i (0-based) from the group's remaining tokens, or
// "" if absent. tokens[0] is the verb; ids are typically tokens[1].
pos :: proc(tokens: []string, i: int) -> string {
	if i < len(tokens) do return tokens[i]
	return ""
}

// ---- bridge -------------------------------------------------------------
ctl_v2_bridge :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		scope := option_value(args, "--scope", "all")
		ctl_agent_call(endpoint, token, "agent.bridge.list", json_object(json_kv("scope", scope)))
	case "providers":
		bid := option_value(args, "--bridge", pos(tokens, 1))
		if bid != "" { ctl_agent_call(endpoint, token, "agent.bridge.providers", json_object(json_kv("bridge_id", bid))) }
		else { ctl_agent_call(endpoint, token, "agent.bridge.providers", "{}") }
	case:
		print_agent_help([]string{"bridge"})
	}
}

// ---- agents (identity | template | instance + lifecycle) ----------------
ctl_v2_agents :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		ctl_agent_call(endpoint, token, "agent.agents.list", "{}")
	case "identity":
		sub := pos(tokens, 1)
		if sub == "create" {
			name := option_value(args, "--name", "")
			if name == "" { print_agent_help([]string{"agents"}); return }
			fields := make([dynamic]string)
			append(&fields, json_kv("name", name))
			if v := option_value(args, "--template", ""); v != "" do append(&fields, json_kv("template_id", v))
			if v := option_value(args, "--provider", ""); v != "" do append(&fields, json_kv("provider", v))
			if v := option_value(args, "--model", ""); v != "" do append(&fields, json_kv("model", v))
			if v := option_value(args, "--slug", ""); v != "" do append(&fields, json_kv("slug", v))
			if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
			ctl_agent_call(endpoint, token, "agent.agents.create", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "template":
		sub := pos(tokens, 1)
		if sub == "" || sub == "list" { ctl_agent_call(endpoint, token, "agent.agents.template_list", "{}"); return }
		if sub == "create" {
			name := option_value(args, "--name", "")
			if name == "" { print_agent_help([]string{"agents"}); return }
			fields := make([dynamic]string)
			append(&fields, json_kv("name", name))
			if v := option_value(args, "--description", ""); v != "" do append(&fields, json_kv("description", v))
			if v := option_value(args, "--persona", ""); v != "" do append(&fields, json_kv("persona", v))
			if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
			ctl_agent_call(endpoint, token, "agent.agents.template_create", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "instance":
		sub := pos(tokens, 1)
		if sub == "" || sub == "list" {
			fields := make([dynamic]string)
			if v := option_value(args, "--agent", ""); v != "" do append(&fields, json_kv("agent_id", v))
			if has_flag(args, "--live") do append(&fields, json_kv_raw("live", "true"))
			ctl_agent_call(endpoint, token, "agent.agents.instance_list", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "new-instance":
		agent_id := pos(tokens, 1)
		if agent_id == "" { print_agent_help([]string{"agents"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		if v := option_value(args, "--project", ""); v != "" do append(&fields, json_kv("project_id", v))
		if v := option_value(args, "--bridge", ""); v != "" do append(&fields, json_kv("bridge_id", v))
		if v := option_value(args, "--provider", ""); v != "" do append(&fields, json_kv("provider", v))
		if v := option_value(args, "--model", ""); v != "" do append(&fields, json_kv("model", v))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.agents.new_instance", json_object_from_slice(fields[:]))
	case "start", "stop", "restart":
		inst := pos(tokens, 1)
		if inst == "" { print_agent_help([]string{"agents"}); return }
		method := "agent.agents.instance_start"
		if verb == "stop" do method = "agent.agents.instance_stop"
		if verb == "restart" do method = "agent.agents.instance_restart"
		fields := make([dynamic]string)
		append(&fields, json_kv("instance_id", inst))
		if verb == "stop" { if v := option_value(args, "--reason", ""); v != "" do append(&fields, json_kv("reason", v)) }
		ctl_agent_call(endpoint, token, method, json_object_from_slice(fields[:]))
	case:
		print_agent_help([]string{"agents"})
	}
}

// ---- task-chain ---------------------------------------------------------
ctl_v2_task_chain :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		fields := make([dynamic]string)
		defer delete(fields)
		if has_flag(args, "--mine") do append(&fields, json_kv_raw("coordinated_by_me", "true"))
		if has_flag(args, "--pinned") do append(&fields, json_kv_raw("pinned", "true"))
		if v := option_value(args, "--project", ""); v != "" do append(&fields, json_kv("project_id", v))
		ctl_agent_call_and_decrypt(endpoint, token, "agent.task_chain.list", json_object_from_slice(fields[:]), args)
	case "create":
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { print_agent_help([]string{"task-chain"}); return }
		params := ctl_agentmode_task_chain_create_params(args, pos(tokens, 1))
		defer delete(params)
		ctl_agent_call(endpoint, token, "agent.task_chain.create", params)
	case "show":
		cid := option_value(args, "--chain", pos(tokens, 1))
		if cid != "" { ctl_agent_call_and_decrypt(endpoint, token, "agent.task_chain.show", json_object(json_kv("chain_id", cid)), args) }
		else { ctl_agent_call_and_decrypt(endpoint, token, "agent.task_chain.show", "{}", args) }
	case "set-title":
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { print_agent_help([]string{"task-chain"}); return }
		// REQ-VCAP-4: check the PLAINTEXT budget before encrypting, so the error
		// is in the units the caller controls (the Hub only sees ciphertext).
		if !is_vault_armored(title) && !ctl_check_plaintext_cap("chain title", title, CTL_CHAIN_TITLE_MAX_BYTES) { os.exit(1) }
		keyring := ctl_vault_keyring_for_write(args)
		if !is_vault_armored(title) {
			title = ctl_seal_or_exit(title, keyring)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("title", title))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_title", json_object_from_slice(fields[:]))
	case "set-description":
		// coordinator-only; pass "" to clear. --chain defaults to your chain.
		desc := option_value(args, "--description", pos(tokens, 1))
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do desc = string(data) }
		// REQ-VCAP-4: check the PLAINTEXT budget before encrypting, so the error
		// is in the units the caller controls (the Hub only sees ciphertext).
		if !is_vault_armored(desc) && !ctl_check_plaintext_cap("chain description", desc, CTL_CHAIN_DESCRIPTION_MAX_BYTES) { os.exit(1) }
		keyring := ctl_vault_keyring_for_write(args)
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("description", desc))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_description", json_object_from_slice(fields[:]))
	case "set-status", "status":
		status := option_value(args, "--status", pos(tokens, 1))
		if status == "" { print_agent_help([]string{"task-chain"}); return }
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("status", status))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_status", json_object_from_slice(fields[:]))
	case "archive":
		cid := option_value(args, "--chain", pos(tokens, 1))
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("status", "archived"))
		if cid != "" do append(&fields, json_kv("chain_id", cid))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_status", json_object_from_slice(fields[:]))
	case "unarchive":
		cid := option_value(args, "--chain", pos(tokens, 1))
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("status", "active"))
		if cid != "" do append(&fields, json_kv("chain_id", cid))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_status", json_object_from_slice(fields[:]))
	case "publish":
		// Coordinator only (enforced hub-side). Flips the chain Draft -> Published and
		// cascades Published to its tasks, which is what makes them schedulable.
		cid := option_value(args, "--chain", pos(tokens, 1))
		if cid == "" { print_agent_help([]string{"task-chain"}); return }
		// Task System v2: publish validates every task's brief; a 422
		// brief_incomplete is rendered per task (taskv2_cmds.odin) and exits 1.
		response, ok := ctl_agent_local_call(endpoint, token, "agent.task_chain.publish", json_object(json_kv("chain_id", cid)))
		if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
		ctl_publish_print_and_exit(response)
	case "pin":
		cid := option_value(args, "--chain", pos(tokens, 1))
		if cid == "" { print_agent_help([]string{"task-chain"}); return }
		ctl_agent_call(endpoint, token, "agent.task_chain.pin", json_object(json_kv("chain_id", cid), json_kv_raw("pinned", "true")))
	case "unpin":
		cid := option_value(args, "--chain", pos(tokens, 1))
		if cid == "" { print_agent_help([]string{"task-chain"}); return }
		ctl_agent_call(endpoint, token, "agent.task_chain.pin", json_object(json_kv("chain_id", cid), json_kv_raw("pinned", "false")))
	case "directory", "directories":
		ctl_task_chains_command(tokens, args)
	case "fleet", "fleets":
		ctl_v2_task_chain_fleet(endpoint, token, tokens[1:], args)
	case "summary", "set-summary":
		ctl_v2_task_chain_summary(endpoint, token, tokens[1:], args)
	case "propose":
		ctl_v2_task_chain_propose(endpoint, token, tokens[1:], args)
	case "decide", "proposal":
		cid := option_value(args, "--chain", option_value(args, "--chain-id", pos(tokens, 1)))
		decision := strings.trim_space(option_value(args, "--decision", ""))
		if cid == "" || (decision != "approve" && decision != "reject") {
			fmt.println(`{"ok":false,"message":"task-chain decide requires --chain <id> --decision approve|reject [--reason <text>]"}`)
			os.exit(1)
		}
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("decision", decision))
		if r := option_value(args, "--reason", ""); r != "" do append(&fields, json_kv("reason", r))
		params := json_object(
			json_kv("http_method", "POST"),
			json_kv("path", fmt.tprintf("/api/v1/task-chains/%s/proposal/decide", safe_path_part(cid))),
			json_kv("body", json_object_from_slice(fields[:])),
		)
		ctl_agent_call_task(endpoint, token, "agent.rest.request", params, args)
	case "graph", "depend", "remove-dependency", "scope", "complete":
		// Mixed-work graph verbs: same parser as user mode, relayed through the
		// authenticated agent.work.* Bridge routes (Hub enforces owner/coordinator).
		ctl_mixed_work_command(Ctl_Transport{kind = .Agent, agent_endpoint = endpoint, agent_token = token}, verb, args, pos(tokens, 1))
	case:
		print_agent_help([]string{"task-chain"})
	}
}

ctl_v2_task_chain_fleet :: proc(endpoint, token: string, tokens, args: []string) {
	if has_flag(args, "--help") || has_flag(args, "-h") || (len(tokens) > 0 && tokens[0] == "help") {
		print_help_task_chain_fleet()
		return
	}
	sub := pos(tokens, 0)
	if sub == "" || sub == "list" {
		chain_id := pos(tokens, 1)
		if chain_id == "" do chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" {
			res, ok := ctl_agent_local_call(endpoint, token, "agent.context.get", "{}")
			if ok {
				chain_id = extract_json_string_unescaped(res, "chain_id", "")
			}
		}
		if chain_id == "" {
			fmt.println("usage: ham-ctl task-chain fleet list <chain-id>")
			return
		}
		path := fmt.tprintf("/api/v1/task-chains/%s/fleets", safe_path_part(chain_id))
		params := json_object(
			json_kv("http_method", "GET"),
			json_kv("path", path),
			json_kv("body", ""),
		)
		ctl_agent_call(endpoint, token, "agent.rest.request", params)
		return
	}
	if sub == "set" {
		chain_id := pos(tokens, 1)
		if chain_id == "" do chain_id = option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" {
			res, ok := ctl_agent_local_call(endpoint, token, "agent.context.get", "{}")
			if ok {
				chain_id = extract_json_string_unescaped(res, "chain_id", "")
			}
		}
		agent_id := option_value(args, "--agent", option_value(args, "--agent-id", ""))
		bm_file, _ := ctl_read_json_file_flag(args, "--bridge-models-file")
		body, body_ok := ctl_v2_fleet_set_body(args, bm_file)
		if chain_id == "" || agent_id == "" || !body_ok {
			fmt.println("usage: ham-ctl task-chain fleet set <chain-id> --agent <agent_id> --capacity <N> [--roles <worker,reviewer>] [--bridge <id>] [--provider <p>] [--model <m>] [--bridge-models <json>]")
			return
		}
		path := fmt.tprintf("/api/v1/task-chains/%s/fleets/%s", safe_path_part(chain_id), safe_path_part(agent_id))
		params := json_object(
			json_kv("http_method", "PUT"),
			json_kv("path", path),
			json_kv("body", body),
		)
		ctl_agent_call(endpoint, token, "agent.rest.request", params)
		return
	}
	// Fallback: if sub is a chain_id
	chain_id := sub
	path := fmt.tprintf("/api/v1/task-chains/%s/fleets", safe_path_part(chain_id))
	params := json_object(
		json_kv("http_method", "GET"),
		json_kv("path", path),
		json_kv("body", ""),
	)
	ctl_agent_call(endpoint, token, "agent.rest.request", params)
}

// ---- task (one command per action) --------------------------------------
ctl_v2_task :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		fields := make([dynamic]string)
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call_task(endpoint, token, "agent.task.list", json_object_from_slice(fields[:]), args)
	case "show":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("task_id", tid))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call_task(endpoint, token, "agent.task.show", json_object_from_slice(fields[:]), args)
	case "comments":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("task_id", tid))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		if v := option_value(args, "--last", ""); v != "" do append(&fields, json_kv("last", v))
		ctl_agent_call_task(endpoint, token, "agent.task.comments", json_object_from_slice(fields[:]), args)
	case "create":
		title := option_value(args, "--title", "")
		if title == "" { print_agent_help([]string{"task"}); return }
		// REQ-CLI-2: --priority was advertised on create, accepted, and never sent.
		// Reject a bad value here rather than forwarding it — silently seating an
		// unrecognised priority at p2 is the defect this fixes, not the fix.
		if v := option_value(args, "--priority", ""); v != "" {
			if !ctl_valid_task_priority(v) {
				fmt.printfln("usage: --priority must be one of p0, p1, p2 (got %q)", v)
				return
			}
		}
		if !ctl_task_reviewer_flags_valid(args, false) do return
		params := ctl_agentmode_task_create_params(args)
		ctl_agent_call(endpoint, token, "agent.task.create", params)
	case "comment":
		tid := pos(tokens, 1)
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if tid == "" || body == "" { print_agent_help([]string{"task"}); return }
		params := ctl_agentmode_task_comment_params(tid, body, args)
		ctl_agent_call(endpoint, token, "agent.task.comment", params)
	case "depend":
		tid := pos(tokens, 1)
		on := option_value(args, "--on", option_value(args, "--depends-on", ""))
		if tid == "" { print_agent_help([]string{"task"}); return }
		kind, prereq, msg := ctl_task_depend_target(on)
		switch kind {
		case .Invalid:
			ctl_print_error_exit(msg)
		case .Task:
			ctl_agent_call_task(endpoint, token, "agent.task.depend", json_object(json_kv("task_id", tid), json_kv("depends_on_task_id", prereq)), args)
		case .Workflow_Run:
			// A whole workflow run is a chain-level graph prerequisite (the canonical
			// mixed-work edge), not a ticket row: route through agent.work.depend.
			ctl_agent_call_task(endpoint, token, "agent.work.depend", ctl_task_depend_workflow_params(option_value(args, "--chain", ""), tid, prereq), args)
		}
	case "update":
		// Edit an already-created task: title/description/priority/assignee/
		// reviewers/dependencies/brief. Relayed as a PATCH to the task; only the
		// fields you pass are changed (the hub merges brief fields too). --reviewer
		// and --depends-on are comma-separated and REPLACE the whole list.
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		if !ctl_task_reviewer_flags_valid(args, true) do return
		params := ctl_agentmode_task_update_params(tid, args)
		ctl_agent_call(endpoint, token, "agent.task.update", params)
	case "publish":
		// Coordinator only. 422 brief_incomplete is rendered per task (taskv2_cmds.odin).
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		ctl_v2_task_publish(endpoint, token, tid, args)
	case "unblock":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		ctl_v2_task_publish(endpoint, token, tid, args, unblock = true)
	case "fetch":
		ctl_v2_task_fetch(endpoint, token, tokens, args)
	case "readiness":
		// Read-only: per-edge prerequisite state, merge state and why it is unsatisfied.
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call_task(endpoint, token, "agent.task.readiness", json_object(json_kv("task_id", tid)), args)
	case:
		print_agent_help([]string{"task"})
	}
}

// ---- chat (send --to user|<instance-id>, read) --------------------------
ctl_v2_chat :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "read":
		ctl_agentmode_chat_fetch(endpoint, token, "read", args)
	case "send":
		to := option_value(args, "--to", "")
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if to == "" || body == "" { print_agent_help([]string{"chat"}); return }
		// to == "user" or an agent-instance-id; the bridge routes accordingly.
		params := ctl_agentmode_chat_send_params(to, body, args)
		ctl_agent_call_task(endpoint, token, "agent.chat.send", params, args)
	case "set-title":
		// DEPRECATED (REQ-TN-E): renames the agent's OWN bound conversation. Kept so
		// existing callers do not break; agents name work with `task-chain set-title`.
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { print_agent_help([]string{"chat"}); return }
		params := ctl_agentmode_chat_set_title_params(title, args)
		ctl_agent_call_task(endpoint, token, "agent.conversation.set_title", params, args)
	case:
		print_agent_help([]string{"chat"})
	}
}

// ---- artifact -----------------------------------------------------------
ctl_v2_artifact :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	// artifact verbs keep their existing param shapes; only the method prefix
	// changed (artifacts -> artifact). Delegate to the shared impl.
	ctl_agentmode_artifacts_v2(endpoint, token, verb, tokens, args)
}

// ctl_v2_json_string_array builds "key":["a","b"] from a comma list.
ctl_v2_json_string_array :: proc(key, csv: string) -> string {
	parts := strings.split(csv, ",")
	defer delete(parts)
	b := strings.builder_make()
	strings.write_byte(&b, '"'); strings.write_string(&b, key); strings.write_string(&b, "\":[")
	for p, i in parts {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); strings.write_string(&b, strings.trim_space(p)); strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// collect_multi_values gathers the values for one or more flag spellings,
// supporting BOTH repeated flags (`--agent a --agent b`) AND comma-separated
// values (`--agent a,b`). Blank tokens are skipped. The returned slice is
// caller-owned. Pure (no I/O) so the memory param-builder stays unit-testable.
collect_multi_values :: proc(args: []string, names: ..string) -> [dynamic]string {
	out := make([dynamic]string)
	for i := 0; i + 1 < len(args); i += 1 {
		matched := false
		for name in names { if args[i] == name { matched = true; break } }
		if !matched do continue
		for part in strings.split(args[i + 1], ",") {
			token := strings.trim_space(part)
			if token != "" do append(&out, token)
		}
	}
	return out
}

// json_string_array_field builds `"key":["a","b"]` from a list of already-split
// values, JSON-escaping each. An empty list yields `"key":[]`. Pure helper used
// by the memory propose param-builder so empty vs one vs many ids are explicit.
json_string_array_field :: proc(key: string, values: []string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"'); json_write_string(&b, key); strings.write_string(&b, "\":[")
	for v, i in values {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); json_write_string(&b, v); strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// ctl_v2_assignee_field builds the Task System v2 `"assignee":"<agent_id>"` field.
// Instance pins were removed: only durable agent ids (agt_…) are accepted; an
// inst_… value is rejected earlier by ctl_task_reviewer_flags_valid.
ctl_v2_assignee_field :: proc(id: string) -> string {
	return json_kv("assignee", strings.trim_space(id))
}

// ctl_v2_reviewers_field builds the Task System v2 `"reviewers":[agent_id,…]`
// field from every `--reviewer` occurrence (repeatable AND comma-separated), so a
// task can carry MULTIPLE reviewers. Blank ids are skipped; `--reviewer ""` still
// emits an empty array so callers can CLEAR the reviewer list explicitly.
ctl_v2_reviewers_field :: proc(args: []string) -> string {
	ids := collect_multi_values(args, "--reviewer", "--reviewer-agent-id")
	defer delete(ids)
	return json_string_array_field("reviewers", ids[:])
}

// ctl_task_actor_id_is_instance reports whether a --assignee/--reviewer value is a
// live instance id (inst_…), which Task System v2 no longer accepts as a task actor.
ctl_task_actor_id_is_instance :: proc(id: string) -> bool {
	return strings.has_prefix(strings.trim_space(id), "inst_")
}

ctl_task_reviewer_flags_valid :: proc(args: []string, allow_disable: bool) -> bool {
	if has_flag(args, "--require-user-approval") && has_flag(args, "--no-require-user-approval") {
		fmt.println("--require-user-approval and --no-require-user-approval are mutually exclusive")
		return false
	}
	if has_flag(args, "--no-require-user-approval") && !allow_disable {
		fmt.println("--no-require-user-approval is only valid for task update")
		return false
	}
	if has_flag(args, "--assignee-agent-instance-id") || has_flag(args, "--reviewer-agent-instance-id") {
		fmt.println("--assignee-agent-instance-id / --reviewer-agent-instance-id were removed in Task System v2: tasks target durable agent ids (agt_...), not instances; use --assignee / --reviewer <agt_id>")
		return false
	}
	if a := option_value(args, "--assignee", option_value(args, "--assignee-agent-id", "")); ctl_task_actor_id_is_instance(a) {
		fmt.printfln("--assignee must be a durable agent id (agt_...), got instance id %q: instance pins were removed in Task System v2", strings.trim_space(a))
		return false
	}
	if has_flag(args, "--reviewer") || has_flag(args, "--reviewer-agent-id") {
		ids := collect_multi_values(args, "--reviewer", "--reviewer-agent-id")
		defer delete(ids)
		for id in ids {
			if id == "user" || id == "user_proxy" {
				fmt.println("--reviewer accepts durable agent IDs (agt_...) only; use --require-user-approval for user review")
				return false
			}
			if ctl_task_actor_id_is_instance(id) {
				fmt.printfln("--reviewer must be durable agent ids (agt_...), got instance id %q: instance pins were removed in Task System v2", id)
				return false
			}
		}
	}
	return true
}

agent_mode_endpoint :: proc(args: []string) -> string {
	if v := option_value(args, "--bridge-endpoint", ""); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator); v != "" do return v
	return ""
}

agent_mode_token :: proc(args: []string) -> string {
	if v := option_value(args, "--agent-token", ""); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator); v != "" do return v
	return ""
}

ctl_agentmode_context :: proc(endpoint, token: string, args: []string) {
	_ = args
	ctl_agent_call(endpoint, token, "agent.context.get", "{}")
}

ctl_agentmode_chat_fetch :: proc(endpoint, token, action: string, args: []string) {
	fields := make([dynamic]string)
	append(&fields, json_kv_raw("limit", option_value(args, "--limit", "50")))
	if cursor := option_value(args, "--since", option_value(args, "--cursor", "")); cursor != "" do append(&fields, json_kv("cursor", cursor))
	
	is_read := action == "read" || action == "read-messages"
	
	// Default low-noise
	unread_only := true
	receiver_only := true
	include_outgoing := false
	include_debug := false
	mark_read := is_read

	if has_flag(args, "--include-read") {
		unread_only = false
	}
	
	if has_flag(args, "--transcript") || has_flag(args, "--all") {
		unread_only = false
		receiver_only = false
		include_outgoing = true
		include_debug = true
	}
	
	if has_flag(args, "--include-outgoing") do include_outgoing = true
	if has_flag(args, "--include-debug") do include_debug = true

	if unread_only { append(&fields, json_kv_raw("unread_only", "true")) } else { append(&fields, json_kv_raw("unread_only", "false")) }
	if receiver_only { append(&fields, json_kv_raw("receiver_only", "true")) } else { append(&fields, json_kv_raw("receiver_only", "false")) }
	if mark_read { append(&fields, json_kv_raw("mark_read", "true")) } else { append(&fields, json_kv_raw("mark_read", "false")) }
	
	if include_outgoing { append(&fields, json_kv_raw("include_outgoing", "true")) } else { append(&fields, json_kv_raw("include_outgoing", "false")) }
	if include_debug { append(&fields, json_kv_raw("include_debug", "true")) } else { append(&fields, json_kv_raw("include_debug", "false")) }

	// Optional cross-agent read: read another agent's inbox (same owner user).
	// Omitted -> the hub reads the caller's own inbox exactly as before.
	target := option_value(args, "--agent-instance-id", "")
	if target != "" do append(&fields, json_kv("target_instance_id", target))

	ctl_agent_call_task(endpoint, token, "agent.chat.read", json_object_from_slice(fields[:]), args)
}

// artifact_require_ok prints a non-ok response and exits NON-ZERO (REQ-JSONX-3).
//
// Every artifact path used to `return` here, so a failed lookup printed its error and
// still exited 0:
//
//     $ ham-ctl artifact content art_doesnotexist000; echo $?
//     {"ok":false,"error":{"code":"hub_error","message":"...artifact not found..."}}
//     0
//
// A script or agent branching on the exit code read that as a clean read. Note the
// bounds-check panic was never the swallowed case -- an Odin trap exits 132, and `$?`
// only reads 0 for it inside a pipeline, where POSIX hands back the LAST command's
// status. This error path is the one that genuinely reported success on failure.
//
// SHARED by the artifact and memory command families (REQ-CTL-EXIT-1). The `memory`
// paths carried the byte-identical swallow and now call this too, so the name is the
// only artifact-specific thing left about it -- deliberately not renamed, because that
// would touch every call site and is not worth the churn.
//
// Both families kept the same asymmetry before this: an unreachable ENDPOINT already
// exited 1, while a hub response of `"ok":true` absent -- not found, not permitted, bad
// id -- printed the error and returned success. Only the endpoint half was ever right.
artifact_require_ok :: proc(response: string) {
	if strings.contains(response, `"ok":true`) do return
	fmt.println(response)
	os.exit(1)
}

// artifact_verify_written checks the POSTCONDITION of a download rather than trusting
// the write's return (REQ-JSONX-4): `artifact download` must either leave a
// byte-complete file behind or fail loudly. A short or missing file reported as a
// successful download is a defect in its own right, so it exits non-zero here.
artifact_verify_written :: proc(path: string, expected: int) {
	f, open_err := os.open(path)
	if open_err != nil {
		fmt.println(ctl_error_json("artifact was not written", json_kv("path", path)))
		os.exit(1)
	}
	defer os.close(f)
	size, size_err := os.file_size(f)
	if size_err != nil || int(size) != expected {
		fmt.printf(
			"{\"ok\":false,\"message\":\"artifact written incompletely\",\"path\":\"%s\",\"expected_bytes\":%d,\"written_bytes\":%d}\n",
			path,
			expected,
			size,
		)
		os.exit(1)
	}
}

ctl_agent_artifact_call_and_decrypt :: proc(endpoint, token, method, params_json: string, args: []string) {
	response, ok := ctl_agent_local_call(endpoint, token, method, params_json)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(response)
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_json_string(response, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

ctl_agentmode_artifact_create_params :: proc(args: []string) -> string {
	name := option_value(args, "--name", "")
	kind := option_value(args, "--kind", "markdown")
	content := option_value(args, "--content", "")
	content_base64 := ""
	if file_path := option_value(args, "--file", ""); file_path != "" {
		data, err := os.read_entire_file(file_path, context.allocator)
		if err == nil do content_base64 = base64.encode(data)
	}
	if has_flag(args, "--stdin") {
		data, err := os.read_entire_file("/dev/stdin", context.allocator)
		if err == nil do content_base64 = base64.encode(data)
	}
	desc := option_value(args, "--description", "")

	keyring := ctl_vault_keyring_for_write(args)
	if !is_vault_armored(name) {
		name = ctl_seal_or_exit(name, keyring)
	}
	if desc != "" && !is_vault_armored(desc) {
		desc = ctl_seal_or_exit(desc, keyring)
	}
	if content != "" && !is_vault_armored(content) {
		content = ctl_seal_or_exit(content, keyring)
	} else if content_base64 != "" {
		raw_bytes, b_err := base64.decode(content_base64, allocator = context.temp_allocator)
		if b_err == nil {
			raw_text := string(raw_bytes)
			if !is_vault_armored(raw_text) {
				enc_content := ctl_seal_or_exit(raw_text, keyring)
				content_base64 = base64.encode(transmute([]byte)enc_content, allocator = context.temp_allocator)
			}
		}
	}

	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("name", name))
	append(&fields, json_kv("kind", kind))
	if content_base64 != "" {
		append(&fields, json_kv("content_base64", content_base64))
	} else {
		append(&fields, json_kv("content", content))
	}
	if ct := option_value(args, "--content-type", ""); ct != "" do append(&fields, json_kv("content_type", ct))
	if desc != "" do append(&fields, json_kv("description", desc))
	if p := option_value(args, "--project", option_value(args, "--project-id", "")); p != "" do append(&fields, json_kv("project_id", p))
	if ai := option_value(args, "--agent-instance", option_value(args, "--agent-instance-id", "")); ai != "" do append(&fields, json_kv("agent_instance_id", ai))
	if a := option_value(args, "--agent", option_value(args, "--agent-id", "")); a != "" do append(&fields, json_kv("agent_id", a))
	if t := option_value(args, "--task", option_value(args, "--task-id", "")); t != "" do append(&fields, json_kv("task_id", t))
	if c := option_value(args, "--chain", option_value(args, "--chain-id", "")); c != "" do append(&fields, json_kv("chain_id", c))
	return json_object_from_slice(fields[:])
}

// ctl_agentmode_artifacts_v2 is the v2 artifact dispatch: positional <artifact-id>
// and the singular `agent.artifact.*` methods.
ctl_agentmode_artifacts_v2 :: proc(endpoint, token, verb: string, tokens, args: []string) {
	switch verb {
	case "", "list":
		ctl_agent_artifact_call_and_decrypt(endpoint, token, "agent.artifact.list", ctl_agentmode_artifact_list_params(args), args)
	case "create":
		name := option_value(args, "--name", "")
		if name == "" { print_agent_help([]string{"artifact"}); return }
		params := ctl_agentmode_artifact_create_params(args)
		ctl_agent_call(endpoint, token, "agent.artifact.create", params)
	case "show":
		artifact_id := pos(tokens, 1)
		if artifact_id == "" do artifact_id = option_value(args, "--artifact-id", option_value(args, "--artifact", option_value(args, "--id", "")))
		if artifact_id == "" { print_agent_help([]string{"artifact"}); return }
		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("artifact_id", artifact_id))
		if has_flag(args, "--with-content") do append(&fields, json_kv_raw("with_content", "true"))
		ctl_agent_artifact_call_and_decrypt(endpoint, token, "agent.artifact.show", json_object_from_slice(fields[:]), args)
	case "content", "get", "read":
		artifact_id := pos(tokens, 1)
		if artifact_id == "" do artifact_id = option_value(args, "--artifact-id", option_value(args, "--artifact", option_value(args, "--id", "")))
		if artifact_id == "" { print_agent_help([]string{"artifact"}); return }
		ctl_agent_artifact_content(endpoint, token, artifact_id, args)
	case "download":
		artifact_id := pos(tokens, 1)
		if artifact_id == "" do artifact_id = option_value(args, "--artifact-id", option_value(args, "--artifact", option_value(args, "--id", "")))
		dir := option_value(args, "--dir", option_value(args, "--out", ""))
		if artifact_id == "" || dir == "" { print_agent_help([]string{"artifact"}); return }
		ctl_agent_artifact_download(endpoint, token, artifact_id, dir, args)
	case:
		print_agent_help([]string{"artifact"})
	}
}

ctl_agentmode_artifact_list_params :: proc(args: []string) -> string {
	fields := make([dynamic]string)
	defer delete(fields)
	if p := option_value(args, "--project", option_value(args, "--project-id", "")); p != "" do append(&fields, json_kv("project_id", p))
	if ai := option_value(args, "--agent-instance", option_value(args, "--agent-instance-id", "")); ai != "" do append(&fields, json_kv("agent_instance_id", ai))
	if a := option_value(args, "--agent", option_value(args, "--agent-id", "")); a != "" do append(&fields, json_kv("agent_id", a))
	if t := option_value(args, "--task", option_value(args, "--task-id", "")); t != "" do append(&fields, json_kv("task_id", t))
	if c := option_value(args, "--chain", option_value(args, "--chain-id", "")); c != "" do append(&fields, json_kv("chain_id", c))
	if k := option_value(args, "--kind", ""); k != "" do append(&fields, json_kv("kind", k))
	if s := option_value(args, "--since", ""); s != "" do append(&fields, json_kv("since", s))
	if u := option_value(args, "--until", ""); u != "" do append(&fields, json_kv("until", u))
	if s := option_value(args, "--sort", option_value(args, "--sort-field", "")); s != "" do append(&fields, json_kv("sort", s))
	if o := option_value(args, "--order", option_value(args, "--sort-order", "")); o != "" do append(&fields, json_kv("order", o))
	if l := option_value(args, "--limit", ""); l != "" do append(&fields, json_kv_raw("limit", l))
	if cur := option_value(args, "--cursor", ""); cur != "" do append(&fields, json_kv("cursor", cur))
	if has_flag(args, "--include-deleted") do append(&fields, json_kv_raw("include_deleted", "true"))
	return json_object_from_slice(fields[:])
}

ctl_agent_artifact_content :: proc(endpoint, token, artifact_id: string, args: []string = nil) {
	response, ok := ctl_agent_local_call(endpoint, token, "agent.artifact.content", json_object(json_kv("artifact_id", artifact_id)))
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(response)
	content := extract_json_string_unescaped(response, "content", "")
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted := ctl_decrypt_or_fallback_armored(content, keyring, key_ok, context.temp_allocator)
	fmt.print(decrypted)
}

ctl_agent_artifact_download :: proc(endpoint, token, artifact_id, dir: string, args: []string = nil) {
	meta_response, meta_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.show", json_object(json_kv("artifact_id", artifact_id)))
	if !meta_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(meta_response)
	content_response, content_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.content", json_object(json_kv("artifact_id", artifact_id)))
	if !content_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(content_response)
	// make_directory_all reports an error when the directory ALREADY exists, so the
	// result cannot be the failure test — treating it as one rejected every
	// pre-created --dir. What matters is the postcondition: a usable directory.
	os.make_directory_all(dir)
	if !os.is_dir(dir) { fmt.println(`{"ok":false,"message":"download directory could not be created"}`); os.exit(1) }
	ext := artifact_download_extension(meta_response, content_response)
	filename := artifact_download_random_filename(ext)
	path := path_join_agent(dir, filename)
	content := extract_json_string_unescaped(content_response, "content", "")
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	if is_vault_armored(content) && key_ok {
		if decrypted, res := ctl_vault_open(content, keyring, context.temp_allocator); res == .Ok {
			content = decrypted
		}
	}
	data := transmute([]byte)content
	if os.write_entire_file(path, data) != nil { fmt.println(`{"ok":false,"message":"artifact could not be written"}`); os.exit(1) }
	artifact_verify_written(path, len(data))
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"filename":"`); json_write_string(&b, filename)
	strings.write_string(&b, `","path":"`); json_write_string(&b, path)
	strings.write_string(&b, `","artifact_id":"`); json_write_string(&b, artifact_id)
	strings.write_string(&b, `"}`)
	fmt.println(strings.to_string(b))
}

ctl_v2_memory :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		ctl_agent_memory_call_and_decrypt(endpoint, token, "agent.memory.list", ctl_agentmode_memory_list_params(args), args)
	case "show":
		memory_id := pos(tokens, 1)
		if memory_id == "" do memory_id = option_value(args, "--memory-id", option_value(args, "--memory", option_value(args, "--id", "")))
		if memory_id == "" { print_agent_help([]string{"memory"}); return }
		ctl_agent_memory_call_and_decrypt(endpoint, token, "agent.memory.show", json_object(json_kv("memory_id", memory_id)), args)
	case "content", "get", "read":
		memory_id := pos(tokens, 1)
		if memory_id == "" do memory_id = option_value(args, "--memory-id", option_value(args, "--memory", option_value(args, "--id", "")))
		if memory_id == "" { print_agent_help([]string{"memory"}); return }
		ctl_agent_memory_content(endpoint, token, memory_id, args)
	case "propose", "create":
		mem_type := option_value(args, "--type", "")
		title := option_value(args, "--title", "")
		if mem_type == "" || title == "" {
			fmt.println("usage: ham-ctl memory propose --type <type> --title <title> [--description <text>] [--body <text>] [--evidence <text>] [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]\n  Scope flags target LISTS (repeatable or comma-separated); an omitted dimension applies to all (agent defaults to the caller's own).")
			return
		}
		ctl_agent_call(endpoint, token, "agent.memory.propose", ctl_agentmode_memory_propose_params(args))
	case:
		print_agent_help([]string{"memory"})
	}
}

ctl_v2_cards :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		ctl_agent_call(endpoint, token, "agent.cards.list", ctl_agentmode_cards_list_params(args))
	case "show", "get":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { print_agent_help([]string{"cards"}); return }
		if has_flag(args, "--json") || has_flag(args, "--raw") {
			ctl_agent_call(endpoint, token, "agent.cards.show", json_object(json_kv("card_id", card_id)))
			return
		}
		response, ok := ctl_agent_local_call(endpoint, token, "agent.cards.show", json_object(json_kv("card_id", card_id)))
		if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
		render_human_card(response)
	case "create":
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" {
			fmt.println("usage: ham-ctl cards create --title <title> [--rationale <text>] [--scope <project|global>] [--provider <provider>] [--confidence <float>] [--project <id>] [--source-refs <json>] [--operations <json>] [--guard <json>]")
			return
		}
		ctl_agent_call(endpoint, token, "agent.cards.create", ctl_agentmode_cards_create_params(title, args))
	case "discard":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { print_agent_help([]string{"cards"}); return }
		ctl_agent_call(endpoint, token, "agent.cards.discard", json_object(json_kv("card_id", card_id)))
	case "accept":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { print_agent_help([]string{"cards"}); return }
		ctl_agent_call(endpoint, token, "agent.cards.accept", json_object(json_kv("card_id", card_id)))
	case:
		print_agent_help([]string{"cards"})
	}
}

ctl_agentmode_action_create_params :: proc(args: []string, tokens: []string = nil) -> (string, bool) {
	type_str := option_value(args, "--type", "")
	title := option_value(args, "--title", "")
	if title == "" && tokens != nil && len(tokens) > 1 {
		title = pos(tokens, 1)
	}
	if title == "" do return "", false

	ops_json := ""
	if type_str == "memory.approve" {
		mid := option_value(args, "--memory-id", option_value(args, "--id", ""))
		if mid == "" do return "", false
		b := strings.builder_make()
		strings.write_string(&b, `[{"op":"memory.approve","memory_id":"`)
		json_write_string(&b, mid)
		strings.write_string(&b, `"}]`)
		ops_json = strings.to_string(b)
	} else if type_str == "issue.create" {
		desc := option_value(args, "--description", option_value(args, "--desc", ""))
		scope := option_value(args, "--scope", "")
		b := strings.builder_make()
		strings.write_string(&b, `[{"op":"issue.create","title":"`)
		json_write_string(&b, title)
		strings.write_string(&b, `"`)
		if desc != "" {
			strings.write_string(&b, `,"description":"`)
			json_write_string(&b, desc)
			strings.write_string(&b, `"`)
		}
		if scope != "" {
			strings.write_string(&b, `,"scope":"`)
			json_write_string(&b, scope)
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, `}]`)
		ops_json = strings.to_string(b)
	} else if type_str == "" {
		ops_json = option_value(args, "--operations", option_value(args, "--op", ""))
		if ops_json == "" do return "", false
	} else {
		ops_json = option_value(args, "--operations", option_value(args, "--op", ""))
		if ops_json == "" do return "", false
	}

	// Card title and rationale are vault content the UI decrypts (VaultText /
	// DecryptedMarkdown); they are sealed, never sent in plaintext (finding N3).
	// Operations stay readable to the hub (it executes them) EXCEPT the content
	// fields it only stores (CARD_OP_SEALED_FIELDS: issue/memory titles and bodies,
	// project name/description), which are sealed too.
	kr := ctl_vault_keyring_for_write(args)
	sealed_ops, ops_ok := ctl_seal_card_operations(ops_json, kr, context.temp_allocator)
	if !ops_ok do return "", false
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("title", ctl_seal_if(title, kr)))
	append(&fields, json_kv_raw("operations", sealed_ops))
	if r := option_value(args, "--rationale", ""); r != "" do append(&fields, json_kv("rationale", ctl_seal_if(r, kr)))
	if sc := option_value(args, "--scope", ""); sc != "" do append(&fields, json_kv("scope", sc))
	if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
	if c := option_value(args, "--confidence", ""); c != "" do append(&fields, json_kv_raw("confidence", c))
	if pid := option_value(args, "--project", option_value(args, "--project-id", "")); pid != "" do append(&fields, json_kv("project_id", pid))
	if sr := option_value(args, "--source-refs", ""); sr != "" do append(&fields, json_kv_raw("source_refs", sr))
	if g := option_value(args, "--guard", ""); g != "" do append(&fields, json_kv_raw("guard", g))
	if s := option_value(args, "--status", ""); s != "" do append(&fields, json_kv("status", s))
	if su := option_value(args, "--snooze-until", ""); su != "" do append(&fields, json_kv("snooze_until", su))
	if ttl := option_value(args, "--ttl-at", ""); ttl != "" do append(&fields, json_kv("ttl_at", ttl))
	return json_object_from_slice(fields[:]), true
}

ctl_v2_action :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "create":
		params, ok := ctl_agentmode_action_create_params(args, tokens)
		if !ok {
			fmt.println("usage: ham-ctl action create (--type memory.approve --memory-id <id> --title <title> | --type issue.create --title <title> [--description <desc>] [--scope <scope>] | --title <title> --operations <json>)")
			return
		}
		ctl_agent_call(endpoint, token, "agent.cards.create", params)
	case "", "list":
		ctl_agent_call(endpoint, token, "agent.cards.list", ctl_agentmode_cards_list_params(args))
	case "show", "get":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", option_value(args, "--action-id", ""))))
		if card_id == "" { print_agent_help([]string{"action"}); return }
		if has_flag(args, "--json") || has_flag(args, "--raw") {
			ctl_agent_call(endpoint, token, "agent.cards.show", json_object(json_kv("card_id", card_id)))
			return
		}
		response, r_ok := ctl_agent_local_call(endpoint, token, "agent.cards.show", json_object(json_kv("card_id", card_id)))
		if !r_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
		render_human_card(response)
	case "discard":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", option_value(args, "--action-id", ""))))
		if card_id == "" { print_agent_help([]string{"action"}); return }
		ctl_agent_call(endpoint, token, "agent.cards.discard", json_object(json_kv("card_id", card_id)))
	case "accept":
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", option_value(args, "--action-id", ""))))
		if card_id == "" { print_agent_help([]string{"action"}); return }
		ctl_agent_call(endpoint, token, "agent.cards.accept", json_object(json_kv("card_id", card_id)))
	case:
		print_agent_help([]string{"action"})
	}
}

ctl_agentmode_cards_list_params :: proc(args: []string) -> string {
	fields := make([dynamic]string)
	defer delete(fields)
	if s := option_value(args, "--status", ""); s != "" do append(&fields, json_kv("status", s))
	if sc := option_value(args, "--scope", ""); sc != "" do append(&fields, json_kv("scope", sc))
	if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
	if pid := option_value(args, "--project", option_value(args, "--project-id", "")); pid != "" do append(&fields, json_kv("project_id", pid))
	if l := option_value(args, "--limit", ""); l != "" do append(&fields, json_kv_raw("limit", l))
	return json_object_from_slice(fields[:])
}

ctl_agentmode_cards_create_params :: proc(title: string, args: []string) -> string {
	// Sealed like ctl_agentmode_action_create_params (finding N3).
	kr := ctl_vault_keyring_for_write(args)
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("title", ctl_seal_if(title, kr)))
	if r := option_value(args, "--rationale", ""); r != "" do append(&fields, json_kv("rationale", ctl_seal_if(r, kr)))
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
	return json_object_from_slice(fields[:])
}

// cards_op_arg pulls a string arg from an operation object, checking args.<key>
// then a top-level <key> (mirrors the hub's op_arg_string / the UI's getArg).
cards_op_arg :: proc(op_item: json.Object, key: string) -> string {
	if args, ok := op_item["args"].(json.Object); ok {
		if v, ok2 := args[key].(json.String); ok2 do return string(v)
	}
	if v, ok := op_item[key].(json.String); ok do return string(v)
	return ""
}

// cards_op_fallback_label derives a friendly CLI label for the ops that need one
// when a card omits the per-op `label` (parity with the UI's formatOpLabel). Returns
// "" for ops it doesn't special-case, so the caller falls back to the raw op name.
cards_op_fallback_label :: proc(op_name: string, op_item: json.Object) -> string {
	switch op_name {
	case "agent.update":
		id := cards_op_arg(op_item, "agent_id"); if id == "" do id = cards_op_arg(op_item, "id")
		return fmt.tprintf("Edit agent %s", id) if id != "" else "Edit agent"
	case "agent.delete":
		id := cards_op_arg(op_item, "agent_id"); if id == "" do id = cards_op_arg(op_item, "id")
		return fmt.tprintf("Archive agent %s", id) if id != "" else "Archive agent"
	case "project.delete":
		id := cards_op_arg(op_item, "project_id"); if id == "" do id = cards_op_arg(op_item, "id")
		return fmt.tprintf("Archive project %s", id) if id != "" else "Archive project"
	}
	return ""
}

render_human_card :: proc(body: string) {
	val, err := json.parse(transmute([]byte)body)
	if err != .None {
		fmt.println(body)
		return
	}
	defer json.destroy_value(val)

	root, is_obj := val.(json.Object)
	if !is_obj {
		fmt.println(body)
		return
	}

	if ok_val, has_ok := root["ok"].(json.Boolean); has_ok && !bool(ok_val) {
		fmt.println(body)
		return
	}

	card_obj := root
	if data_obj, has_data := root["data"].(json.Object); has_data {
		card_obj = data_obj
	}

	card_id := ""
	if s, ok := card_obj["card_id"].(json.String); ok do card_id = string(s)
	if card_id == "" {
		if s, ok := card_obj["id"].(json.String); ok do card_id = string(s)
	}
	if card_id == "" {
		fmt.println(body)
		return
	}

	title := ""
	if s, ok := card_obj["title"].(json.String); ok do title = string(s)

	status := ""
	if s, ok := card_obj["status"].(json.String); ok do status = string(s)

	scope := ""
	if s, ok := card_obj["scope"].(json.String); ok do scope = string(s)

	provider := ""
	if s, ok := card_obj["provider"].(json.String); ok do provider = string(s)

	rationale := ""
	if s, ok := card_obj["rationale"].(json.String); ok do rationale = string(s)

	project_id := ""
	if s, ok := card_obj["project_id"].(json.String); ok do project_id = string(s)

	snooze_until := ""
	if s, ok := card_obj["snooze_until"].(json.String); ok do snooze_until = string(s)

	ttl_at := ""
	if s, ok := card_obj["ttl_at"].(json.String); ok do ttl_at = string(s)

	confidence: f64 = 1.0
	if f, ok := card_obj["confidence"].(json.Float); ok do confidence = f
	else if i, ok := card_obj["confidence"].(json.Integer); ok do confidence = f64(i)

	fmt.printfln("Card:       %s", card_id)
	fmt.printfln("Title:      %s", title)
	fmt.printfln("Status:     %s", status)
	if scope != "" do fmt.printfln("Scope:      %s", scope)
	if provider != "" do fmt.printfln("Provider:   %s", provider)
	if confidence < 0.9999 || confidence > 1.0001 {
		fmt.printfln("Confidence: %.2f", confidence)
	}
	if project_id != "" do fmt.printfln("Project:    %s", project_id)
	if snooze_until != "" do fmt.printfln("Snoozed:    %s", snooze_until)
	if ttl_at != "" do fmt.printfln("TTL:        %s", ttl_at)
	if rationale != "" do fmt.printfln("Rationale:  %s", rationale)

	ops, has_ops := card_obj["operations"].(json.Array)
	if has_ops && len(ops) > 0 {
		fmt.println("")
		fmt.printfln("Operations (%d):", len(ops))
		for op_val, idx in ops {
			op_item, ok := op_val.(json.Object)
			if !ok do continue
			op_name := ""
			if s, ok2 := op_item["op"].(json.String); ok2 do op_name = string(s)
			if op_name == "" {
				if s, ok2 := op_item["type"].(json.String); ok2 do op_name = string(s)
			}
			label := ""
			if s, ok2 := op_item["label"].(json.String); ok2 do label = string(s)
			if label == "" do label = cards_op_fallback_label(op_name, op_item)

			if label != "" && op_name != "" {
				fmt.printfln("  %d. %s [%s]", idx + 1, label, op_name)
			} else if label != "" {
				fmt.printfln("  %d. %s", idx + 1, label)
			} else if op_name != "" {
				fmt.printfln("  %d. %s", idx + 1, op_name)
			} else {
				fmt.printfln("  %d. (unnamed operation)", idx + 1)
			}
		}
	} else {
		fmt.println("")
		fmt.println("Operations: (none)")
	}
}

ctl_agentmode_memory :: proc(endpoint, token: string, tokens, args: []string) {
	ctl_v2_memory(endpoint, token, tokens, args)
}

ctl_decrypt_memory_json :: proc(raw_json: string, keyring: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) -> string {
	return ctl_decrypt_issues_json(raw_json, keyring, key_configured, allocator)
}

ctl_agent_memory_call_and_decrypt :: proc(endpoint, token, method, params_json: string, args: []string) {
	response, ok := ctl_agent_local_call(endpoint, token, method, params_json)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(response)
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_memory_json(response, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
}

ctl_agent_memory_content :: proc(endpoint, token, memory_id: string, args: []string = nil) {
	response, ok := ctl_agent_local_call(endpoint, token, "agent.memory.content", json_object(json_kv("memory_id", memory_id)))
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	artifact_require_ok(response)
	content := extract_json_string_unescaped(response, "content", "")
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted := ctl_decrypt_or_fallback_armored(content, keyring, key_ok, context.temp_allocator)
	fmt.print(decrypted)
}

ctl_agentmode_memory_list_params :: proc(args: []string) -> string {
	fields := make([dynamic]string)
	defer delete(fields)
	if s := option_value(args, "--status", ""); s != "" do append(&fields, json_kv("status", s))
	if t := option_value(args, "--type", ""); t != "" do append(&fields, json_kv("type", t))
	if l := option_value(args, "--limit", ""); l != "" do append(&fields, json_kv_raw("limit", l))

	agent_ids := collect_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"); defer delete(agent_ids)
	if len(agent_ids) > 0 do append(&fields, json_string_array_field("agent_ids", agent_ids[:]))

	project_ids := collect_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"); defer delete(project_ids)
	if len(project_ids) > 0 do append(&fields, json_string_array_field("project_ids", project_ids[:]))

	bridge_ids := collect_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"); defer delete(bridge_ids)
	if len(bridge_ids) > 0 do append(&fields, json_string_array_field("bridge_ids", bridge_ids[:]))

	template_ids := collect_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"); defer delete(template_ids)
	if len(template_ids) > 0 do append(&fields, json_string_array_field("template_ids", template_ids[:]))

	return json_object_from_slice(fields[:])
}

// ctl_agentmode_memory_propose_params builds the agent.memory.propose params
// JSON from CLI args. Pure (no I/O) so it is unit-testable. type/title/body are
// always present; evidence and the LIST scope flags are included ONLY when at
// least one id is provided, so the hub's defaults apply for an omitted dimension
// (agent -> caller's own agent, the rest -> applies to all). Each dimension maps
// to a JSON string array matching the T1 contract: agent_ids/project_ids/
// bridge_ids/template_ids. Every dimension accepts repeated flags AND/OR
// comma-separated values, plus singular and plural spellings.
ctl_agentmode_memory_propose_params :: proc(args: []string) -> string {
	fields := make([dynamic]string)
	mem_type := option_value(args, "--type", "")
	title := option_value(args, "--title", "")
	desc := option_value(args, "--description", "")
	body := option_value(args, "--body", "")
	ev := option_value(args, "--evidence", "")

	keyring := ctl_vault_keyring_for_write(args)
	if !is_vault_armored(title) {
		title = ctl_seal_or_exit(title, keyring)
	}
	if desc != "" && !is_vault_armored(desc) {
		desc = ctl_seal_or_exit(desc, keyring)
	}
	if body != "" && !is_vault_armored(body) {
		body = ctl_seal_or_exit(body, keyring)
	}
	if ev != "" && !is_vault_armored(ev) {
		ev = ctl_seal_or_exit(ev, keyring)
	}

	append(&fields, json_kv("type", mem_type))
	append(&fields, json_kv("title", title))
	if desc != "" do append(&fields, json_kv("description", desc))
	append(&fields, json_kv("body", body))
	if ev != "" do append(&fields, json_kv("evidence", ev))

	agent_ids := collect_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"); defer delete(agent_ids)
	if len(agent_ids) > 0 do append(&fields, json_string_array_field("agent_ids", agent_ids[:]))
	project_ids := collect_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"); defer delete(project_ids)
	if len(project_ids) > 0 do append(&fields, json_string_array_field("project_ids", project_ids[:]))
	bridge_ids := collect_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"); defer delete(bridge_ids)
	if len(bridge_ids) > 0 do append(&fields, json_string_array_field("bridge_ids", bridge_ids[:]))
	template_ids := collect_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"); defer delete(template_ids)
	if len(template_ids) > 0 do append(&fields, json_string_array_field("template_ids", template_ids[:]))

	return json_object_from_slice(fields[:])
}

ctl_agentmode_task_chain_create_params :: proc(args: []string, positional_title: string = "") -> string {
	title := option_value(args, "--title", positional_title)
	desc := option_value(args, "--description", "")
	if has_flag(args, "--stdin") {
		data, err := os.read_entire_file("/dev/stdin", context.allocator)
		if err == nil do desc = string(data)
	}
	keyring := ctl_vault_keyring_for_write(args)
	if title != "" && !is_vault_armored(title) {
		title = ctl_seal_or_exit(title, keyring)
	}
	if desc != "" && !is_vault_armored(desc) {
		desc = ctl_seal_or_exit(desc, keyring)
	}
	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("title", title))
	if desc != "" do append(&fields, json_kv("description", desc))
	append(&fields, json_kv("kind", option_value(args, "--kind", "team_work")))
	if coord := option_value(args, "--coordinator", option_value(args, "--coordinator-agent-id", "")); coord != "" {
		append(&fields, json_kv("coordinator_agent_id", coord))
	}
	if bridge := option_value(args, "--bridge", option_value(args, "--bridge-id", "")); bridge != "" {
		append(&fields, json_kv("bridge_id", bridge))
	}
	if project := option_value(args, "--project", option_value(args, "--project-id", "")); project != "" {
		append(&fields, json_kv("project_id", project))
	}
	if provider := option_value(args, "--provider", ""); provider != "" {
		append(&fields, json_kv("provider", provider))
	}
	if model := option_value(args, "--model", ""); model != "" {
		append(&fields, json_kv("model", model))
	}
	return json_object_from_slice(fields[:])
}

ctl_agentmode_task_create_params :: proc(args: []string) -> string {
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
	append(&fields, json_kv("title", title))
	if desc != "" do append(&fields, json_kv("description", desc))
	if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
	if v := option_value(args, "--priority", ""); v != "" do append(&fields, json_kv("priority", v))
	if a := option_value(args, "--assignee", ""); a != "" do append(&fields, ctl_v2_assignee_field(a))
	if has_flag(args, "--reviewer") do append(&fields, ctl_v2_reviewers_field(args))
	if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
	if deps, present := ctl_task_depends_on_flag(args, "--depends-on"); present && deps != "" do append(&fields, ctl_v2_json_string_array("depends_on", deps))
	if b := option_value(args, "--bridge", ""); b != "" do append(&fields, json_kv("bridge_id", b))
	// Task System v2 brief: --goal/--acceptance/--input/--review-role over an
	// optional --brief-file base (taskv2_cmds.odin).
	if brief, ok := ctl_task_brief_field(args); ok do append(&fields, brief)
	return json_object_from_slice(fields[:])
}

ctl_agentmode_task_comment_params :: proc(tid: string, body: string, args: []string) -> string {
	comment_body := body
	keyring := ctl_vault_keyring_for_write(args)
	if comment_body != "" && !is_vault_armored(comment_body) {
		comment_body = ctl_seal_or_exit(comment_body, keyring)
	}
	fields := make([dynamic]string)
	append(&fields, json_kv("task_id", tid))
	append(&fields, json_kv("body", comment_body))
	if notify := option_value(args, "--notify", ""); notify != "" do append(&fields, ctl_v2_json_string_array("notify", notify))
	return json_object_from_slice(fields[:])
}

ctl_agentmode_task_update_params :: proc(tid: string, args: []string) -> string {
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
	append(&fields, json_kv("task_id", tid))
	if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
	if title != "" do append(&fields, json_kv("title", title))
	if desc != "" do append(&fields, json_kv("description", desc))
	if v := option_value(args, "--priority", ""); v != "" do append(&fields, json_kv("priority", v))
	if a := option_value(args, "--assignee", ""); a != "" do append(&fields, ctl_v2_assignee_field(a))
	if has_flag(args, "--reviewer") do append(&fields, ctl_v2_reviewers_field(args))
	if has_flag(args, "--require-user-approval") do append(&fields, `"requires_user_approval":true`)
	if has_flag(args, "--no-require-user-approval") do append(&fields, `"requires_user_approval":false`)
	if deps, present := ctl_task_depends_on_flag(args, "--depends-on"); present do append(&fields, ctl_v2_json_string_array("depends_on", deps))
	if has_flag(args, "--bridge") do append(&fields, json_kv("bridge_id", option_value(args, "--bridge", "")))
	// brief fields are sent only when given; the hub merges them into the stored brief.
	if brief, ok := ctl_task_brief_field(args); ok do append(&fields, brief)
	return json_object_from_slice(fields[:])
}

ctl_agentmode_chat_send_params :: proc(to: string, body: string, args: []string) -> string {
	if has_flag(args, "--questions-file") {
		file := option_value(args, "--questions-file", "")
		if file == "" || strings.has_prefix(file, "--") {
			fmt.println(`{"ok":false,"message":"--questions-file requires a JSON file path"}`)
			os.exit(1)
		}
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fmt.println(`{"ok":false,"message":"cannot read --questions-file"}`)
			os.exit(1)
		}
		params, invalid := ctl_multi_question_send_params(to, body, string(data), args)
		if invalid != "" {
			fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("message", invalid)))
			os.exit(1)
		}
		return params
	}
	chat_body := body
	keyring := ctl_vault_keyring_for_write(args)
	if chat_body != "" && !is_vault_armored(chat_body) {
		chat_body = ctl_seal_or_exit(chat_body, keyring)
	}
	opts := collect_multi_values(args, "--options", "--option", "--expected-answers", "--choices")
	defer delete(opts)
	acts := collect_multi_values(args, "--actions", "--action", "--action-id", "--action-ids")
	defer delete(acts)

	if len(opts) == 0 && len(acts) == 0 {
		return json_object(json_kv("to", to), json_kv("body", chat_body))
	}

	fields := make([dynamic]string)
	defer delete(fields)
	append(&fields, json_kv("to", to))
	append(&fields, json_kv("body", chat_body))
	if len(opts) > 0 {
		append(&fields, json_string_array_field("options", opts[:]))
	}
	if len(acts) > 0 {
		append(&fields, json_string_array_field("action_ids", acts[:]))
		append(&fields, json_string_array_field("actions", acts[:]))
	}
	return json_object_from_slice(fields[:])
}

ctl_agentmode_chat_set_title_params :: proc(title: string, args: []string) -> string {
	chat_title := title
	keyring := ctl_vault_keyring_for_write(args)
	if chat_title != "" && !is_vault_armored(chat_title) {
		chat_title = ctl_seal_or_exit(chat_title, keyring)
	}
	return json_object(json_kv("title", chat_title))
}

ctl_agent_call :: proc(endpoint, token, method, params_json: string) {
	response, ok := ctl_agent_local_call(endpoint, token, method, params_json)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	fmt.println(response)
}

ctl_agent_call_and_decrypt :: proc(endpoint, token, method, params_json: string, args: []string = nil) {
	ctl_agent_call_task(endpoint, token, method, params_json, args)
}

ctl_agent_call_task :: proc(endpoint, token, method, params_json: string, args: []string = nil) {
	response, ok := ctl_agent_local_call(endpoint, token, method, params_json)
	if !ok {
		fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`)
		os.exit(1)
	}
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_json_string(response, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
	if strings.contains(response, `"ok":false`) do os.exit(1)
}

// JSONL v1 local endpoint client. Sends one request line, reads one response
// line. Supports unix:<path> (primary, §12.0.2) and tcp:<host>:<port> (fallback).
ctl_agent_local_call :: proc(endpoint, token, method, params_json: string) -> (string, bool) {
	request := ctl_agent_jsonl_request(token, method, params_json)
	// Task System v2 F2: while the bridge has no hub session it answers
	// `hub_unreachable` WITHOUT sending anything, so the call is safe to retry.
	// `retryable_unavailable` (sent, outcome unknown) is never retried.
	started := time.tick_now()
	backoff := CTL_HUB_RETRY_FIRST_BACKOFF
	announced := false
	for {
		response, ok := ctl_agent_local_send(endpoint, request)
		if ok && strings.contains(response, `"retryable_unavailable"`) {
			fmt.eprintln("ham-ctl: the hub relay failed after the request was sent; its outcome is unknown. Check with `ham-ctl lease next` before retrying.")
		}
		if !ok || !strings.contains(response, `"hub_unreachable"`) do return response, ok
		if time.tick_since(started) >= CTL_HUB_RETRY_WINDOW do return response, ok
		if !announced {
			fmt.eprintln("ham-ctl: hub unavailable (request not sent); retrying for up to 90s…")
			announced = true
		}
		delete(response)
		time.sleep(backoff)
		backoff = min(backoff * 2, CTL_HUB_RETRY_MAX_BACKOFF)
	}
}

CTL_HUB_RETRY_WINDOW :: 90 * time.Second
CTL_HUB_RETRY_FIRST_BACKOFF :: 2 * time.Second
CTL_HUB_RETRY_MAX_BACKOFF :: 15 * time.Second

ctl_agent_local_send :: proc(endpoint, request: string) -> (string, bool) {
	if strings.has_prefix(endpoint, "tcp:") do return ctl_agent_send_tcp(endpoint, request)
	if strings.has_prefix(endpoint, "unix:") do return ctl_agent_send_unix(endpoint, request)
	return "", false
}

ctl_agent_jsonl_request :: proc(token, method, params_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"v":1,"id":"ham-ctl-agent","token":"`)
	json_write_string(&b, token)
	strings.write_string(&b, `","method":"`)
	json_write_string(&b, method)
	strings.write_string(&b, `","params":`)
	if strings.trim_space(params_json) == "" {
		strings.write_string(&b, "{}")
	} else {
		// JSONL framing: a raw newline ends the request line. Params may splice
		// pretty-printed JSON (e.g. `lease submit --output-file`); valid JSON
		// never has a raw newline inside a string, so a space is equivalent.
		for i in 0..<len(params_json) {
			ch := params_json[i]
			strings.write_byte(&b, ' ' if ch == '\n' || ch == '\r' else ch)
		}
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

ctl_agent_send_tcp :: proc(endpoint, line: string) -> (string, bool) {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) != 3 do return "", false
	port_i, port_ok := strconv_parse_int_agent(parts[2])
	if !port_ok do return "", false
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	socket, err := net.dial_tcp(address, int(port_i))
	if err != nil do return "", false
	defer net.close(socket)
	_, send_err := net.send_tcp(socket, transmute([]byte)line)
	if send_err != nil do return "", false
	return ctl_agent_recv_tcp(socket)
}

ctl_agent_send_unix :: proc(endpoint, line: string) -> (string, bool) {
	path := strings.trim_prefix(endpoint, "unix:")
	if strings.trim_space(path) == "" || !local_socket.path_fits(path) do return "", false
	sock, ok := local_socket.dial(path)
	if !ok do return "", false
	defer local_socket.close(sock)
	if local_socket.send(sock, transmute([]byte)line) < 0 do return "", false
	return ctl_agent_recv_unix(sock)
}

ctl_agent_recv_tcp :: proc(socket: net.TCP_Socket) -> (string, bool) {
	out := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for len(out) < 64 * 1024 * 1024 {
		n, err := net.recv_tcp(socket, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
		if byte_slice_contains(out[:], '\n') do return string(out[:]), true
	}
	if len(out) == 0 do return "", false
	return string(out[:]), true
}

ctl_agent_recv_unix :: proc(sock: local_socket.Socket) -> (string, bool) {
	out := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for len(out) < 64 * 1024 * 1024 {
		n := local_socket.recv(sock, buf[:])
		if n <= 0 do break
		append(&out, ..buf[:n])
		if byte_slice_contains(out[:], '\n') do return string(out[:]), true
	}
	if len(out) == 0 do return "", false
	return string(out[:]), true
}

byte_slice_contains :: proc(values: []byte, needle: byte) -> bool {
	for v in values { if v == needle do return true }
	return false
}

artifact_download_extension :: proc(meta_response, content_response: string) -> string {
	if ext := normalize_extension(extract_json_string_unescaped(meta_response, "ext", "")); ext != "" do return ext
	if ext := extension_from_name(extract_json_string_unescaped(meta_response, "name", "")); ext != "" do return ext
	mime := extract_json_string_unescaped(content_response, "mime", "")
	if mime == "" do mime = extract_json_string_unescaped(meta_response, "mime", "")
	if mime == "" do mime = extract_json_string_unescaped(content_response, "content_type", "")
	if mime == "" do mime = extract_json_string_unescaped(meta_response, "content_type", "")
	if ext := extension_from_mime(mime); ext != "" do return ext
	if ext := extension_from_kind(extract_json_string_unescaped(meta_response, "kind", "")); ext != "" do return ext
	return "bin"
}

normalize_extension :: proc(value: string) -> string {
	v := strings.to_lower(strings.trim_space(value))
	for strings.has_prefix(v, ".") do v = v[1:]
	if len(v) == 0 || len(v) > 16 do return ""
	for ch in v { if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) do return "" }
	return v
}

extension_from_name :: proc(name: string) -> string {
	trimmed := strings.trim_space(name)
	slash := strings.last_index_byte(trimmed, '/')
	backslash := strings.last_index_byte(trimmed, '\\')
	sep := slash
	if backslash > sep do sep = backslash
	dot := strings.last_index_byte(trimmed, '.')
	if dot <= sep || dot < 0 || dot + 1 >= len(trimmed) do return ""
	return normalize_extension(trimmed[dot + 1:])
}

extension_from_mime :: proc(mime: string) -> string {
	m := strings.to_lower(strings.trim_space(mime))
	if semicolon := strings.index_byte(m, ';'); semicolon >= 0 do m = strings.trim_space(m[:semicolon])
	switch m {
	case "text/markdown", "text/x-markdown": return "md"
	case "text/plain": return "txt"
	case "application/json", "text/json": return "json"
	case "text/html": return "html"
	case "text/css": return "css"
	case "application/javascript", "text/javascript": return "js"
	case "image/png": return "png"
	case "image/jpeg", "image/jpg": return "jpg"
	case "image/gif": return "gif"
	case "image/webp": return "webp"
	case "image/svg+xml": return "svg"
	case "application/pdf": return "pdf"
	case "application/zip": return "zip"
	case "application/gzip": return "gz"
	case "application/octet-stream": return "bin"
	}
	return ""
}

extension_from_kind :: proc(kind: string) -> string {
	switch strings.to_lower(strings.trim_space(kind)) {
	case "markdown", "md": return "md"
	case "text", "txt", "log": return "txt"
	case "json": return "json"
	case "html": return "html"
	case "png": return "png"
	case "jpeg", "jpg": return "jpg"
	case "gif": return "gif"
	case "webp": return "webp"
	case "pdf": return "pdf"
	}
	return ""
}

artifact_download_random_filename :: proc(ext: string) -> string {
	suffix, ok := random_hex_agent(8)
	if !ok do suffix = fmt.tprintf("%d", os.get_pid())
	clean_ext := normalize_extension(ext)
	if clean_ext == "" do clean_ext = "bin"
	return fmt.tprintf("artifact_%s.%s", suffix, clean_ext)
}

random_hex_agent :: proc(n: int) -> (string, bool) {
	if n <= 0 do return "", true
	buf := make([]byte, n)
	defer delete(buf)
	if !os_random.fill(buf) do return "", false
	b := strings.builder_make()
	hex := "0123456789abcdef"
	for byte_value in buf {
		strings.write_byte(&b, hex[int(byte_value >> 4)])
		strings.write_byte(&b, hex[int(byte_value & 0x0f)])
	}
	return strings.to_string(b), true
}

path_join_agent :: proc(dir, filename: string) -> string {
	base := strings.trim_right(dir, "/")
	if base == "" do return filename
	return strings.concatenate({base, "/", filename})
}

strconv_parse_int_agent :: proc(value: string) -> (int, bool) {
	result := 0
	if value == "" do return 0, false
	for ch in value {
		if ch < '0' || ch > '9' do return 0, false
		result = result * 10 + int(ch - '0')
	}
	return result, true
}

// print_agent_help renders the two-level skill-style help
// (docs/agent-api-redesign.md §4.5). Level 1 = the overview; Level 2 = a
// detailed reference per group. Deterministic + no network.
print_agent_help :: proc(cmd: []string) {
	resource := ""
	sub := ""
	if len(cmd) > 0 {
		if cmd[0] == "agent" || cmd[0] == "help" {
			if len(cmd) > 1 do resource = cmd[1]
			if len(cmd) > 2 do sub = cmd[2]
		} else {
			resource = cmd[0]
			if len(cmd) > 1 do sub = cmd[1]
		}
	}
	switch resource {
	case "bridge", "bridges": print_help_bridge(); return
	case "agents": print_help_agents(); return
	case "task-chain", "task-chains", "chain", "chains":
		if sub == "fleet" || sub == "fleets" {
			print_help_task_chain_fleet()
			return
		}
		print_help_task_chain()
		return
	case "task", "tasks": print_help_task(); return
	case "lease": print_help_lease(); return
	case "review": print_help_review(); return
	case "verify": print_help_verify(); return
	case "workflow", "workflows": print_help_workflow(); return
	case "chat", "chats", "conversation", "conversations": print_help_chat(); return
	case "artifact", "artifacts": print_help_artifact(); return
	case "memory": print_help_memory(); return
	case "cards", "card", "action", "actions": print_help_cards(); return
	case "shell":     print_help_shell(); return
	case "extension", "extensions": print_help_extension(); return
	case "issue", "issues": print_issues_help(); return
	case "project", "projects": print_projects_help(); return
	case "vault": print_vault_help(); return
	case "context": fmt.println("ham-ctl context\nOne-shot snapshot of this instance: chain, current task, unread counts.\nExample:\n  ham-ctl context"); return
	case "start-success": fmt.println("ham-ctl start-success\nSignal this instance is ready (idempotent).\nExample:\n  ham-ctl start-success"); return
	}
	print_help_overview()
}

print_help_overview :: proc() {
	fmt.println("ham-ctl — Heimdall agent CLI (talks to your local Bridge with your agent token)")
	fmt.println("")
	fmt.println("USAGE")
	fmt.println("  ham-ctl <group> <verb> [<positional>] [--flags]")
	fmt.println("  Everything below is callable by any Bridge-launched agent. IDs are positional;")
	fmt.println("  each concept has exactly one flag. Run `ham-ctl <group> --help` for details.")
	fmt.println("")
	fmt.println("GROUPS")
	fmt.println("  bridge      Discover bridges + their providers (Hub-registered and configured)")
	fmt.println("  agents      Durable identities, templates, and runtime instances")
	fmt.println("  task-chain  Your task chains")
	fmt.println("  task        Tasks within a chain (one command per action)")
	fmt.println("  workflow    Workflow chains: templates, define, run, status, output, retry, cancel")
	fmt.println("  chat        Read your inbox / send to the user or another agent")
	fmt.println("  memory      List, show, read, or propose memories")
	fmt.println("  artifact    Create / read / download artifacts")
	fmt.println("  action      Action cards (create, list, show, accept, discard)")
	fmt.println("  cards       Curator action cards (list, show, create, discard, accept)")
	fmt.println("  shell       Manage PTY/shell sessions on the Bridge host (start/kill/signal/restart/list/log/capture)")
	fmt.println("  issue       Issues, bugs, and blockers (list, show, create, update, comment, vote, unvote)")
	fmt.println("  projects    Manage projects (list, show, create, update)")
	fmt.println("  vault       Report the vault key source: env override and bridge status (status)")
	fmt.println("  lease       Task System v2 leases: next, heartbeat, submit, handoff, block")
	fmt.println("  verify      Removed (stub for one release): prints {\"ok\":true,\"verify\":\"removed\"} and exits 0")
	fmt.println("  review      Post a review verdict on the task you were woken to review (post)")
	fmt.println("  context     One-shot snapshot of this instance (chain, task, unread)")
	fmt.println("  extension   Harness extension hooks → Bridge (hook <provider>, event --stdin, status)")
	fmt.println("  start-success  Signal this instance is ready")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl bridge list")
	fmt.println("  ham-ctl bridge providers --bridge brg_abc")
	fmt.println("  ham-ctl agents new-instance agt_abc --project proj_x --bridge brg_abc --provider claude --model smart")
	fmt.println("  ham-ctl agents start   inst_123")
	fmt.println("  ham-ctl agents stop    inst_123 --reason \"done for now\"")
	fmt.println("  ham-ctl agents restart inst_123")
	fmt.println("  ham-ctl workflow templates")
	fmt.println("  ham-ctl workflow run fix_flaky_tests --input target=src/auth")
	fmt.println("  ham-ctl lease next")
	fmt.println("  ham-ctl lease submit --summary \"done; odin test src/ctl: 42/42 pass\"")
	fmt.println("  ham-ctl review post --verdict approve")
	fmt.println("  ham-ctl task show inst_task_1")
	fmt.println("  ham-ctl task comment inst_task_1 --body \"pushed fix, tests green\"")
	fmt.println("  ham-ctl chat read")
	fmt.println("  ham-ctl chat send --to user --body \"Done — ready for review.\"")
	fmt.println("  ham-ctl chat send --to inst_reviewer --body \"Can you LGTM inst_task_1?\"")
	fmt.println("")
	fmt.println("  ham-ctl <group> --help    # detailed help for any group")
}

print_help_bridge :: proc() {
	fmt.println("ham-ctl bridge — discover bridges and their providers")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--scope hub|configured|all]   List bridges. default all: Hub-registered")
	fmt.println("                                      + locally-configured peers + this host (self).")
	fmt.println("  providers [--bridge <id>]           Providers (+ models) for one/all Hub bridges.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl bridge list")
	fmt.println("  ham-ctl bridge list --scope configured")
	fmt.println("  ham-ctl bridge providers --bridge brg_abc")
}

print_help_agents :: proc() {
	fmt.println("ham-ctl agents — durable identities, templates, and runtime instances")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list                                List durable agent identities.")
	fmt.println("  identity create --name <n>          Create a durable agent.")
	fmt.println("      [--template <id>] [--provider <p>] [--model <t>] [--slug <s>] [--instructions <t>]")
	fmt.println("  template list                       List agent templates (personas).")
	fmt.println("  template create --name <n>          Create a template.")
	fmt.println("      [--description <d>] [--persona <t>] [--instructions <t>]")
	fmt.println("  instance list [--agent <id>] [--live]   List instances (durable, or --live).")
	fmt.println("  new-instance <agent-id>             Launch a NEW instance of a durable agent.")
	fmt.println("      [--project <id>] [--bridge <id>] [--provider <p>] [--model <t>] [--chain <id>]")
	fmt.println("  start   <agent-instance-id>          Start a STOPPED instance (409 if already running).")
	fmt.println("  stop    <agent-instance-id> [--reason <t>]   Stop a running instance.")
	fmt.println("  restart <agent-instance-id>          Restart (stop-then-start) an instance.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl agents list")
	fmt.println("  ham-ctl agents new-instance agt_abc --project proj_x --provider claude --model smart")
	fmt.println("  ham-ctl agents start inst_123")
	fmt.println("  ham-ctl agents template create --name coder --persona 'You write code.'")
}

print_help_task_chain :: proc() {
	fmt.println("ham-ctl task-chain — your task chains")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--mine] [--pinned] [--project <id>]   List chains (--mine = ones you coordinate, --pinned = pinned).")
	fmt.println("  show [<chain-id>]                   Show a chain (defaults to your current chain).")
	fmt.println("  create --title <title>              Create a task chain.")
	fmt.println("      [--description <text>] [--kind <kind>] [--coordinator <id>]")
	fmt.println("      [--bridge <id>] [--project <id>] [--provider <p>] [--model <t>]")
	fmt.println("  pin <chain-id>                      Pin a task chain to the top of the sidebar.")
	fmt.println("  unpin <chain-id>                    Unpin a task chain.")
	fmt.println("  set-title <title> [--chain <id>]    Rename a chain (coordinator only).")
	fmt.println("  set-description <text> [--chain <id>] | --stdin   Set the chain description")
	fmt.println("                                      (coordinator only; pass \"\" to clear).")
	fmt.println("  summary set <text> [--chain <id>] | --stdin       Set/override the chain summary (<=60 lines, coordinator only).")
	fmt.println("  propose --file <proposal.json> [--auto-approve] [--chain <id>]")
	fmt.println("                                      Propose a ticket or workflow (creates draft tasks in one UoW;")
	fmt.println("                                      --auto-approve publishes immediately when the user said 'go ahead').")
	fmt.println("  decide [<chain-id>] --decision approve|reject [--reason <text>]")
	fmt.println("                                      Approve or reject a pending proposal on the chain.")
	fmt.println("  set-status <active|cancelled|archived> [--chain <id>] Change chain status (coordinator only).")
	fmt.println("  archive [<chain-id>]                Archive a task chain (coordinator only).")
	fmt.println("  unarchive [<chain-id>]              Restore an archived task chain to active (coordinator only).")
	fmt.println("  publish <chain-id>                  Publish a DRAFT chain (coordinator only). Cascades")
	fmt.println("                                      published to its tasks — until then nothing in the")
	fmt.println("                                      chain is scheduled.")
	fmt.println("  directory <add|update|remove|list>  Manage task chain relevant directories.")
	fmt.println("  fleet <list|set>                    Manage chain fleet capacities, roles, and placement.")
	fmt.println("")
	fmt.println("MIXED-WORK GRAPH (every chain is mixed_work: tickets and workflow runs share one graph)")
	fmt.println("  Refs are typed: task:<task-id> (an ordinary ticket) or workflow_run:<run-id> (a whole run;")
	fmt.println("  stage tasks are engine-managed and cannot be graph endpoints). [<chain-id>] defaults to")
	fmt.println("  your chain (or --chain <id>). Mutations need the chain owner or its coordinator.")
	fmt.println("  graph [<chain-id>]                  Dependencies (with dependency ids), scope decisions,")
	fmt.println("                                      work_revision and completion summary.")
	fmt.println("  depend [<chain-id>] --item <ref> --on <ref>")
	fmt.println("                                      Add a prerequisite edge (idempotent; the dependent must")
	fmt.println("                                      not have started). The dependent becomes eligible only")
	fmt.println("                                      after the prerequisite SUCCEEDS (failed/cancelled never do).")
	fmt.println("  remove-dependency [<chain-id>] --dependency <wdep-id> --reason <text>")
	fmt.println("                                      Remove an edge (kept in history for audit).")
	fmt.println("  scope [<chain-id>] --item <ref> --action include|exclude --reason <text>")
	fmt.println("                                      Record a scope decision (excluded work never satisfies a")
	fmt.println("                                      prerequisite; it must be terminal before completion).")
	fmt.println("  complete <chain-id> --expected-work-revision <N> --summary <text>")
	fmt.println("                                      Complete the chain (explicit id required; N comes from")
	fmt.println("                                      `graph`; a stale N is a work_changed conflict). Every")
	fmt.println("                                      included ticket/run must have succeeded. Finishing a")
	fmt.println("                                      batch never completes the chain.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl task-chain list --mine")
	fmt.println("  ham-ctl task-chain show chain_abc")
	fmt.println("  ham-ctl task-chain create --title 'Build feature' --coordinator agt_coord")
	fmt.println("  ham-ctl task-chain summary set '# Chain summary' --chain chain_abc")
	fmt.println("  ham-ctl task-chain propose --file proposal.json --auto-approve")
	fmt.println("  ham-ctl task-chain fleet list chain_abc")
	fmt.println("  ham-ctl task-chain fleet set chain_abc --agent agt_worker --capacity 4 --roles worker,reviewer --bridge brg_1 --provider claude --model sonnet")
	fmt.println("  ham-ctl task-chain publish chain_abc")
	fmt.println("  ham-ctl task-chain graph")
	fmt.println("  ham-ctl task-chain depend --item task:task_report --on workflow_run:wrun_research")
	fmt.println("  ham-ctl task-chain complete chain_abc --expected-work-revision 7 --summary 'All work merged; evidence: ...'")
}

print_help_task_chain_fleet :: proc() {
	fmt.println("ham-ctl task-chain fleet — fleet management for task chains")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list <chain-id>                             List fleet capacities, roles, placement, and active agent counts.")
	fmt.println("  set <chain-id> --agent <id> --capacity <N>  Set or adjust fleet capacity, roles, and placement for an agent.")
	fmt.println("")
	fmt.println("FLAGS (set)")
	fmt.println("  --agent <agent_id>        Durable agent ID (e.g. agt_worker).")
	fmt.println("  --capacity <N>            Maximum concurrent instances for this agent on the chain.")
	fmt.println("  --min-warm <N>            Minimum warm idle instances to maintain (optional).")
	fmt.println("  --idle-ttl <seconds>      Idle TTL before scaling down warm instances (default: 600).")
	fmt.println("  --roles <worker,reviewer> Roles this fleet row can serve (repeatable or comma-separated).")
	fmt.println("  --bridge <bridge_id>      Pin fleet placement to a specific bridge (pass \"\" to inherit).")
	fmt.println("  --provider <provider>     Provider override for this fleet row (pass \"\" to inherit).")
	fmt.println("  --model <model>           Model override for this fleet row (pass \"\" to inherit).")
	fmt.println("  --bridge-models <json>    Per-bridge provider/model map JSON object.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl task-chain fleet list chain_abc")
	fmt.println("  ham-ctl task-chain fleet set chain_abc --agent agt_worker --capacity 4 --roles worker,reviewer --bridge brg_1 --provider claude --model sonnet")
}

print_help_task :: proc() {
	fmt.println("ham-ctl task — tasks within a task chain")
	fmt.println("")
	fmt.println("Exactly one command per action; there is no `done` or `votes`.")
	fmt.println("Task System v2: `status`, `vote`, `nudge`, `set-current`, `subscribe` and `unsubscribe`")
	fmt.println("were removed. Work flows through leases: `ham-ctl lease next|submit|handoff|block`")
	fmt.println("and `ham-ctl review post` (see `ham-ctl lease --help`).")
	fmt.println("Positional <task-id> identifies the task and is enough on its own — task ids are")
	fmt.println("globally unique, so you never need --chain (the Hub derives the chain for you).")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list                                    List your chain's tasks; each carries a comment_summary")
	fmt.println("                                          (count, last_comment_at, author, preview) — not bodies.")
	fmt.println("  show <task-id>                          Show a task + brief + comment_summary (no bodies).")
	fmt.println("  unblock <task-id> [--note <reason>]     Coordinator/owner clears a blocker and retries matching.")
	fmt.println("                                          Dispatch failures do not spend attempts; fix the cause first.")
	fmt.println("  comments <task-id> [--last N]           Fetch comment bodies; --last N = newest N (max 100).")
	fmt.println("  fetch <task-id> <ref>                   Fetch one event (#<event_id>), output (output:<task_id>),")
	fmt.println("                                          facet (facet:<task_id>:<attempt_no>:<kind>), or file at commit")
	fmt.println("                                          (dir:<dir_id>:<rev>:<path>, <path>@<rev>, or <path>).")
	fmt.println("  create --title <t>                      Create a task (draft until published).")
	fmt.println("      [--description <d>] [--priority p0|p1|p2] [--assignee <agent-id>] [--bridge <bridge-id>]")
	fmt.println("      [--reviewer <agent-id,...>] [--require-user-approval] [--depends-on <id,id>] [--chain <id>]")
	fmt.println("      BRIEF (what publish validates): --goal <g> --acceptance <a> (repeatable)")
	fmt.println("      [--input <ref>]... [--review-role <role>]... [--brief-file <path.json>]")
	fmt.println("      --brief-file is a JSON object with any of: goal, acceptance, inputs, review_roles,")
	fmt.println("      assignee, reviewers, budget, output, on_output, requires_user_approval, approver, gate.")
	fmt.println("      Flags override its fields. Other keys are rejected (unknown_brief_fields). --verify,")
	fmt.println("      --auto-submit and --require-independent-verify were removed: ignored with a warning.")
	fmt.println("  update <task-id>                        Edit an existing task (coordinator only).")
	fmt.println("      [--title <t>] [--description <d>] [--priority p0|p1|p2] [--assignee <agent-id>]")
	fmt.println("      [--reviewer <agent-id,...>] [--require-user-approval | --no-require-user-approval]")
	fmt.println("      [--depends-on <id,id>] [--bridge <bridge-id>] + the same BRIEF flags as create")
	fmt.println("      [--clear-<field>]... [--replace-brief]")
	fmt.println("      Brief fields are a top-level merge into the stored brief: keys you pass replace")
	fmt.println("      the stored value, a JSON null (or --clear-<field>, e.g. --clear-budget) removes the")
	fmt.println("      key, and keys you leave out are kept. --replace-brief replaces the whole brief.")
	fmt.println("      Reviewers are durable agent ids (agt_…); an inst_… id is refused.")
	fmt.println("      --reviewer/--depends-on REPLACE the whole list (pass \"\" to clear); --bridge \"\" clears")
	fmt.println("      the pin. While the task is leased only acceptance (plus priority, dependencies and")
	fmt.println("      user approval) can change; a 409 names the refused fields.")
	fmt.println("  publish <task-id> [--chain <id>]        Publish one draft task (coordinator only). A 422")
	fmt.println("                                          brief_incomplete lists the missing fields per task.")
	fmt.println("  comment <task-id> --body <t>            Add a comment (the only way to comment).")
	fmt.println("      [--notify <id,id>]")
	fmt.println("  depend <task-id> --on <prerequisite>    Add one prerequisite to a ticket. <prerequisite> is")
	fmt.println("      [--chain <id>]                      <task-id>, task:<task-id>, or workflow_run:<run-id> (a")
	fmt.println("                                          chain-level graph edge on the whole run; --chain defaults")
	fmt.println("                                          to your chain). Other kinds are rejected; use")
	fmt.println("                                          `task-chain depend` for run-on-ticket or run-on-run edges.")
	fmt.println("                                          `update --depends-on` replaces the ticket-id list and takes")
	fmt.println("                                          ticket ids only.")
	fmt.println("")
	fmt.println("  --assignee / --reviewer take durable agent ids (agt_...); --reviewer is repeatable or")
	fmt.println("  comma-separated. Instance pins (inst_...) were removed in Task System v2 and are rejected.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl task show task_1")
	fmt.println("  ham-ctl task create --title 'Add retry' --goal 'Retry transient 5xx in the client' \\")
	fmt.println("      --acceptance 'retries 3x with backoff' --acceptance 'unit test covers 503' \\")
	fmt.println("      --review-role reviewer --assignee agt_worker")
	fmt.println("  Leased tasks allow acceptance-only brief patches:")
	fmt.println("  ham-ctl task update task_1 --acceptance 'retries 3x with backoff' --acceptance 'logs each retry'")
	fmt.println("  ham-ctl task update task_1 --assignee agt_worker --reviewer agt_a --reviewer agt_b")
	fmt.println("  ham-ctl task publish task_1")
	fmt.println("  ham-ctl task unblock task_1 [--note <reason>]  (coordinator/owner; retry a dispatch block after fixing placement)")
	fmt.println("  ham-ctl task fetch task_1 facet:task_1:2:handoff")
	fmt.println("  ham-ctl task fetch task_1 src/main.odin@HEAD")
	fmt.println("  ham-ctl task readiness task_1   (why a task is not ready: each prerequisite's state, merge state and reason)")
	fmt.println("  ham-ctl task comment task_1 --body 'pushed fix' --notify inst_rev")
}

print_help_chat :: proc() {
	fmt.println("ham-ctl chat — read your inbox / send to the user or another agent")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  read [--limit N] [--since T] [--include-read] [--transcript]   Read messages.")
	fmt.println("      [--agent-instance-id <inst-id>]   Read another agent's inbox (same owner). Default: your own inbox.")
	fmt.println("  send --to <user|agent-instance-id> --body <t> | --stdin        Send a message.")
	fmt.println("      [--options <a,b> | --option <opt>] [--expected-answers <...>] [--choices <...>]")
	fmt.println("      [--actions <a,b> | --action <act>]")
	fmt.println("      [--questions-file <path.json>]  Version 1 grouped questions (user only; cannot combine with flat options).")
	fmt.println("      Question text and option labels are vault-encrypted; each question also accepts custom text.")
	fmt.println("      --to is REQUIRED: `user` for the bound user, or an agent-instance-id.")
	fmt.println("  set-title <title>                                              DEPRECATED: conversation titles are unused;")
	fmt.println("                                                                 use `task-chain set-title` (coordinator only).")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl chat read")
	fmt.println("  ham-ctl chat send --to user --body 'Done — ready for review.'")
	fmt.println("  ham-ctl chat send --to user --body 'Choose the release settings.' --questions-file questions.json")
	fmt.println(`  questions.json: {"version":1,"questions":[{"id":"target","text":"Where?","options":[{"id":"stage","label":"Staging"},{"id":"prod","label":"Production"}]}]}`)
	fmt.println("  selection_mode defaults to single; use multiple to select several options. IDs: 1-64 ASCII letters/digits/_/-. Max 12 questions, 12 options each.")
	fmt.println("  ham-ctl chat send --to inst_reviewer --body 'Can you LGTM inst_task_1?'")
}

print_help_artifact :: proc() {
	fmt.println("ham-ctl artifact — create / read / download artifacts")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--project <id>] [--agent-instance <id>] [--task <id>] [--chain <id>]")
	fmt.println("       [--kind <kind>] [--since <ts>] [--until <ts>] [--sort <field>]")
	fmt.println("       [--order <asc|desc>] [--limit <n>] [--cursor <c>] [--include-deleted]")
	fmt.println("  create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]")
	fmt.println("  show <artifact-id> [--with-content]")
	fmt.println("  content <artifact-id>                Print the raw artifact content.")
	fmt.println("  download <artifact-id> --dir <dir>   Write to a file (inferred extension).")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl artifact list --limit 10")
	fmt.println("  ham-ctl artifact list --kind markdown --sort created_at --order desc")
	fmt.println("  ham-ctl artifact create --name test-log --kind markdown --file /tmp/test.log")
	fmt.println("  ham-ctl artifact content art_123")
	fmt.println("  ham-ctl artifact download art_123 --dir /tmp")
}

print_help_memory :: proc() {
	fmt.println("ham-ctl memory — list, show, read content, or propose durable memories")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]")
	fmt.println("      [--status <s>] [--type <t>] [--limit <n>]")
	fmt.println("      List memories (metadata only, no bodies).")
	fmt.println("  show <memory-id>")
	fmt.println("      Show full memory details including body and evidence.")
	fmt.println("  content <memory-id>")
	fmt.println("      Print the raw memory body to stdout.")
	fmt.println("  propose --type <t> --title <t> [--description <t>] [--body <t>] [--evidence <t>]")
	fmt.println("      [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]")
	fmt.println("  Scope flags target LISTS: repeatable (--agent-ids a --agent-ids b) or comma-separated (--agent-ids a,b).")
	fmt.println("  An omitted dimension applies to all; agent defaults to the caller's own agent. Non-empty = must match one.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl memory list")
	fmt.println("  ham-ctl memory list --type fact --status active")
	fmt.println("  ham-ctl memory show mem_123")
	fmt.println("  ham-ctl memory content mem_123")
	fmt.println("  ham-ctl memory propose --type fact --title 'Test command' --body 'odin check src/hub'")
	fmt.println("  ham-ctl memory propose --type habit --title 'Reviewer checklist' --body '...' --template-ids tmpl_reviewer")
	fmt.println("  ham-ctl memory propose --type fact --title 'Two agents' --body '...' --agent-ids agt_a,agt_b")
	fmt.println("  ham-ctl memory propose --type fact --title 'Repeated' --body '...' --project-ids proj_1 --project-ids proj_2")
}

print_help_cards :: proc() {
	fmt.println("ham-ctl cards — Curator action cards")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--status <s>] [--scope <s>] [--provider <p>] [--project <id>] [--limit <n>]")
	fmt.println("                                      List cards matching filters.")
	fmt.println("  show    <card-id> [--json|--raw]    Show card detail (formatted or raw JSON).")
	fmt.println("  create  --title <title>             Create a new action card.")
	fmt.println("      [--rationale <t>] [--scope <project|global>] [--provider <p>]")
	fmt.println("      [--confidence <float>] [--project <id>] [--source-refs <json>]")
	fmt.println("      [--operations <json>] [--guard <json>]")
	fmt.println("  discard <card-id>                   Discard a card without executing operations.")
	fmt.println("  accept  <card-id>                   Accept card and atomically execute all operations.")
	fmt.println("")
	fmt.println("  (agent mode has no reject/snooze — those are hub/user mode only.)")
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
	fmt.println("  card may bundle several, and accepting executes them in order under your authority.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl cards list")
	fmt.println("  ham-ctl cards create --title \"Run tests\" --operations '[{\"op\":\"task.review\",\"label\":\"Approve task\",\"args\":{\"task_id\":\"task_1\"}}]'")
	fmt.println("  ham-ctl cards show crd_123")
	fmt.println("  ham-ctl cards accept crd_123")
	fmt.println("  ham-ctl cards discard crd_123")
}

// ---- lease (Task System v2) ------------------------------------------------
// The lease IS your task: `lease next` returns the lease you hold (with its
// context pack) or claims the next task for you inline; `lease heartbeat`
// extends the TTL (every ham-ctl call already heartbeats implicitly). submit /
// handoff / block end the attempt (taskv2_cmds.odin).
ctl_v2_lease :: proc(endpoint, token: string, tokens, args: []string) {
	action := pos(tokens, 0)
	switch action {
	case "next":
		fields := make([dynamic]string)
		if v := option_value(args, "--vcs-base", ""); v != "" do append(&fields, json_kv("vcs_base", v))
		// cwd lets the bridge find the repo for its vcs_base enrichment.
		append(&fields, ctl_agent_cwd_field())
		ctl_agent_call_task(endpoint, token, "agent.lease.next", json_object_from_slice(fields[:]), args)
	case "heartbeat":
		fields := make([dynamic]string)
		if v := option_value(args, "--lease", ""); v != "" do append(&fields, json_kv("lease_id", v))
		if v := option_value(args, "--note", ""); v != "" do append(&fields, json_kv("note", v))
		ctl_agent_call(endpoint, token, "agent.lease.heartbeat", json_object_from_slice(fields[:]))
	case "submit":
		ctl_v2_lease_submit(endpoint, token, args)
	case "handoff":
		ctl_v2_lease_handoff(endpoint, token, args)
	case "switch":
		ctl_v2_lease_switch(endpoint, token, args, pos(tokens, 1))
	case "block":
		ctl_v2_lease_block(endpoint, token, args)
	case:
		print_help_lease()
	}
}

print_help_lease :: proc() {
	fmt.println("ham-ctl lease — your task lease (Task System v2)")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  next                       Return the lease you hold (status=current) or claim the next task")
	fmt.println("                             for you (status=granted); status=none when nothing is available.")
	fmt.println("                             The response carries the task, the lease deadlines and the context pack.")
	fmt.println("  heartbeat [--note <text>]  Extend the lease TTL (15 min, never past the hard cap). Any ham-ctl")
	fmt.println("                             call already heartbeats implicitly; use --note to leave a progress note.")
	fmt.println("  submit --summary <s> [handoff flags] [--output-file <json>] [--artifacts-file <json>]")
	fmt.println("                             Finish the attempt: the task goes to review (or done when no review")
	fmt.println("                             roles). Commit first; report the checks you chose, the exact")
	fmt.println("                             commands and their outcomes in the summary. The old --verify,")
	fmt.println("                             --skip-verify, --skip-verify-reason and --auto flags are ignored")
	fmt.println("                             with a warning.")
	fmt.println("                             The bridge attaches your repo state (head, dirty, files).")
	fmt.println("  handoff --summary <s> [handoff flags]")
	fmt.println("                             Stop without finishing; the task returns to ready with your handoff")
	fmt.println("                             (next_steps, …) for whoever picks it up next.")
	fmt.println("  switch <task_id> --summary <s> [handoff flags]")
	fmt.println("                             Solo mode: hand the current task off (summary kept, attempt not")
	fmt.println("                             counted) and take <task_id> (must be ready) in one step; on 409")
	fmt.println("                             nothing changed and you still hold the current task.")
	fmt.println("  block --waiting-on <kind> --reason <text> [--ref <id>] [--summary <s>]")
	fmt.println("                             Park the task on something external (kind: user|task|…).")
	fmt.println("")
	fmt.println("  Handoff flags: --decision <text> and --dead-end <text> (repeat for each item) and --next-steps <s>,")
	fmt.println("  or --handoff-file <json> instead. Decisions and dead ends reach every task that waits for this one")
	fmt.println("  and the next attempt; record what you chose and what did not work.")
	fmt.println("")
	fmt.println("  Every verb takes [--lease <id>] (defaults to your current lease). handoff/output/artifacts files")
	fmt.println("  are JSON objects/arrays: handoff {summary?, decisions?, dead_ends?, next_steps?}; output = the")
	fmt.println("  brief's output contract; artifacts = {items:[{kind:file|url|preview_port, ref, label}]}.")
	fmt.println("  A 409 lease_lost means your lease expired: stop; you will be re-woken with a fresh pack.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl lease next")
	fmt.println("  ham-ctl lease heartbeat --note \"tests green, writing docs\"")
	fmt.println("  ham-ctl lease submit --summary \"implemented X; odin test src/ctl: 42/42 pass\" --artifacts-file artifacts.json")
	fmt.println("  ham-ctl lease submit --summary \"rotation done\" --decision \"sha256 for token hashes\" --dead-end \"bcrypt: too slow per request\"")
	fmt.println("  ham-ctl lease handoff --summary \"half done\" --next-steps \"wire the CLI flag; add tests\"")
	fmt.println("  ham-ctl lease switch task_123 --summary \"paused after the parser\" --next-steps \"finish the printer\"")
	fmt.println("  ham-ctl lease block --waiting-on user --reason \"need the staging credentials\"")
}
