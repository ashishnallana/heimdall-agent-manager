package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"
import vault "odin_test:lib/vault"

ctl_issue_request_local :: proc(transport: Ctl_Transport, method, path, body_json: string) -> (string, bool) {
	if transport.kind == .User {
		if transport.user_base_url == "" || transport.user_token == "" {
			return `{"ok":false,"message":"user transport requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`, false
		}
		full_path := hub_url_path_prefix_join(transport.user_base_url, path)
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", transport.user_token})}}
		response, ok := http.request_with_headers_timeout(method, transport.user_base_url, full_path, body_json, headers[:], http.DEFAULT_TIMEOUT_MS)
		if !ok do return `{"ok":false,"message":"Hub request failed"}`, false
		return response.body, true
	}

	if transport.kind == .Agent {
		if transport.agent_endpoint == "" || transport.agent_token == "" {
			return `{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`, false
		}
		params := json_object(
			json_kv("http_method", method),
			json_kv("path", path),
			json_kv("body", body_json),
		)
		return ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.rest.request", params)
	}
	return "", false
}

ctl_decrypt_issues_json :: ctl_decrypt_json_string


ctl_decrypt_vault_json :: proc(raw_json: string, keyring: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) -> string {
	return ctl_decrypt_issues_json(raw_json, keyring, key_configured, allocator)
}

ctl_issue_request_and_decrypt :: proc(transport: Ctl_Transport, method, path, body_json: string, args: []string = nil) {
	resp_str, ok := ctl_issue_request_local(transport, method, path, body_json)
	if !ok {
		if resp_str != "" {
			fmt.println(resp_str)
		}
		return
	}

	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)
	decrypted_json := ctl_decrypt_issues_json(resp_str, keyring, key_ok)
	defer delete(decrypted_json)
	fmt.println(decrypted_json)
}

ctl_issue_request :: proc(transport: Ctl_Transport, method, path, body_json: string) {
	ctl_issue_request_and_decrypt(transport, method, path, body_json, nil)
}


print_issues_help :: proc() {
	fmt.println("ham-ctl issue — manage issues, bugs, and blockers")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  ham-ctl issue list [--status <new|fixed|obsolete>] [--scope <global|project|agent_id|bridge_id>]")
	fmt.println("                     [--target-id <id>] [--chain <id>] [--query <text>] [--voter-id <id>]")
	fmt.println("                     [--limit <limit>] [--offset <offset>]")
	fmt.println("  ham-ctl issue show <issue-id> [--voter-id <id>]")
	fmt.println("  ham-ctl issue create --title <title> [--description <desc>] [--scope <scope>]")
	fmt.println("                       [--target-id <id>] [--chain <id>] [--created-by <id>]")
	fmt.println("  ham-ctl issue update <issue-id> [--title <title>] [--description <desc>]")
	fmt.println("                       [--status <new|fixed|obsolete>] [--scope <scope>]")
	fmt.println("                       [--target-id <id>] [--chain <id>]")
	fmt.println("  ham-ctl issue comment <issue-id> --body <body> [--author-id <id>] [--author-name <name>]")
	fmt.println("  ham-ctl issue vote <issue-id> [--voter-id <id>] [--voter-name <name>]")
	fmt.println("  ham-ctl issue unvote <issue-id> [--voter-id <id>]")
	fmt.println("  ham-ctl issue delete <issue-id>")
}

ctl_issues_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "issues" || cmd[0] == "issue") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_issues_help()
		return
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	if action == "" || action == "list" {
		query := make([dynamic]string)
		defer delete(query)
		if s := option_value(args, "--status", ""); s != "" do append(&query, fmt.tprintf("status=%s", s))
		if sc := option_value(args, "--scope", option_value(args, "--scope-type", "")); sc != "" do append(&query, fmt.tprintf("scope_type=%s", sc))
		if t := option_value(args, "--target-id", option_value(args, "--target", "")); t != "" do append(&query, fmt.tprintf("target_id=%s", t))
		if cid := option_value(args, "--chain-id", option_value(args, "--chain", "")); cid != "" do append(&query, fmt.tprintf("chain_id=%s", cid))
		if q := option_value(args, "--query", option_value(args, "-q", "")); q != "" do append(&query, fmt.tprintf("query=%s", q))
		if vid := option_value(args, "--voter-id", option_value(args, "--voter", "")); vid != "" do append(&query, fmt.tprintf("voter_id=%s", vid))
		if l := option_value(args, "--limit", ""); l != "" do append(&query, fmt.tprintf("limit=%s", l))
		if off := option_value(args, "--offset", ""); off != "" do append(&query, fmt.tprintf("offset=%s", off))

		path := "/api/v1/issues"
		if len(query) > 0 {
			path = fmt.tprintf("/api/v1/issues?%s", strings.join(query[:], "&"))
		}
		ctl_issue_request_and_decrypt(transport, "GET", path, "", args)
		return
	}

	if action == "show" || action == "get" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue show <issue-id> [--voter-id <id>]"}`)
			return
		}
		path := fmt.tprintf("/api/v1/issues/%s", safe_path_part(issue_id))
		if vid := option_value(args, "--voter-id", option_value(args, "--voter", "")); vid != "" {
			path = fmt.tprintf("/api/v1/issues/%s?voter_id=%s", safe_path_part(issue_id), vid)
		}
		ctl_issue_request_and_decrypt(transport, "GET", path, "", args)
		return
	}

	if action == "create" {
		title := option_value(args, "--title", pos(cmd, idx + 1))
		if title == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue create --title <title> [--description <desc>] [--scope <scope>] [--target-id <id>] [--chain <id>] [--created-by <id>]"}`)
			return
		}
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring, key_ok := ctl_vault_keyring_for_write(args, transport)
		if key_ok {
			title = ctl_seal_or_exit(title, keyring)
			if desc != "" {
				desc = ctl_seal_or_exit(desc, keyring)
			}
		}

		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("title", title))
		if desc != "" do append(&fields, json_kv("description", desc))
		if sc := option_value(args, "--scope", option_value(args, "--scope-type", "")); sc != "" do append(&fields, json_kv("scope_type", sc))
		if t := option_value(args, "--target-id", option_value(args, "--target", "")); t != "" do append(&fields, json_kv("target_id", t))
		if cid := option_value(args, "--chain-id", option_value(args, "--chain", "")); cid != "" do append(&fields, json_kv("chain_id", cid))
		if cb := option_value(args, "--created-by", ""); cb != "" do append(&fields, json_kv("created_by", cb))
		ctl_issue_request_and_decrypt(transport, "POST", "/api/v1/issues", json_object_from_slice(fields[:]), args)
		return
	}

	if action == "update" || action == "patch" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue update <issue-id> [--title <title>] [--description <desc>] [--status <new|fixed|obsolete>] [--scope <scope>] [--target-id <id>] [--chain <id>]"}`)
			return
		}
		t := option_value(args, "--title", "")
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring, key_ok := ctl_vault_keyring_for_write(args, transport)
		if key_ok {
			if t != "" {
				t = ctl_seal_or_exit(t, keyring)
			}
			if desc != "" {
				desc = ctl_seal_or_exit(desc, keyring)
			}
		}

		fields := make([dynamic]string)
		defer delete(fields)
		if t != "" do append(&fields, json_kv("title", t))
		if desc != "" do append(&fields, json_kv("description", desc))
		if s := option_value(args, "--status", ""); s != "" do append(&fields, json_kv("status", s))
		if sc := option_value(args, "--scope", option_value(args, "--scope-type", "")); sc != "" do append(&fields, json_kv("scope_type", sc))
		if tid := option_value(args, "--target-id", option_value(args, "--target", "")); tid != "" do append(&fields, json_kv("target_id", tid))
		if cid := option_value(args, "--chain-id", option_value(args, "--chain", "")); cid != "" do append(&fields, json_kv("chain_id", cid))
		ctl_issue_request_and_decrypt(transport, "PATCH", fmt.tprintf("/api/v1/issues/%s", safe_path_part(issue_id)), json_object_from_slice(fields[:]), args)
		return
	}

	if action == "comment" || action == "comments" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue comment <issue-id> --body <body> [--stdin] [--author-id <id>] [--author-name <name>]"}`)
			return
		}
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") {
			data, err := os.read_entire_file("/dev/stdin", context.allocator)
			if err == nil do body = string(data)
		}
		if body == "" && (action == "comments" || pos(cmd, idx + 2) == "list") {
			ctl_issue_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/issues/%s/comments", safe_path_part(issue_id)), "", args)
			return
		}
		if body == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue comment <issue-id> --body <body> [--author-id <id>] [--author-name <name>]"}`)
			return
		}

		keyring, key_ok := ctl_vault_keyring_for_write(args, transport)
		if key_ok {
			body = ctl_seal_or_exit(body, keyring)
		}

		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("body", body))
		if aid := option_value(args, "--author-id", option_value(args, "--author", "")); aid != "" do append(&fields, json_kv("author_id", aid))
		if aname := option_value(args, "--author-name", ""); aname != "" do append(&fields, json_kv("author_name", aname))
		ctl_issue_request_and_decrypt(transport, "POST", fmt.tprintf("/api/v1/issues/%s/comments", safe_path_part(issue_id)), json_object_from_slice(fields[:]), args)
		return
	}

	if action == "vote" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue vote <issue-id> [--voter-id <id>] [--voter-name <name>]"}`)
			return
		}
		fields := make([dynamic]string)
		defer delete(fields)
		if vid := option_value(args, "--voter-id", option_value(args, "--voter", "")); vid != "" do append(&fields, json_kv("voter_id", vid))
		if vname := option_value(args, "--voter-name", ""); vname != "" do append(&fields, json_kv("voter_name", vname))
		ctl_issue_request(transport, "POST", fmt.tprintf("/api/v1/issues/%s/vote", safe_path_part(issue_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "unvote" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue unvote <issue-id> [--voter-id <id>]"}`)
			return
		}
		fields := make([dynamic]string)
		defer delete(fields)
		if vid := option_value(args, "--voter-id", option_value(args, "--voter", "")); vid != "" do append(&fields, json_kv("voter_id", vid))
		ctl_issue_request(transport, "DELETE", fmt.tprintf("/api/v1/issues/%s/vote", safe_path_part(issue_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "delete" || action == "remove" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue delete <issue-id>"}`)
			return
		}
		ctl_issue_request(transport, "DELETE", fmt.tprintf("/api/v1/issues/%s", safe_path_part(issue_id)), "")
		return
	}

	fmt.printfln(`{"ok":false,"message":"unknown issue action '%s'"}`, action)
}
