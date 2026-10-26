package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import httpc "odin_test:lib/httpc"
import vault "odin_test:lib/vault"

ctl_issue_request_local :: proc(transport: Ctl_Transport, req: Ctl_Request) -> (string, bool) {
	return ctl_transport_fetch(transport, req, CTL_USER_TRANSPORT_REQUIRED, CTL_AGENT_TRANSPORT_REQUIRED)
}

ctl_decrypt_issues_json :: ctl_decrypt_json_string


ctl_decrypt_vault_json :: proc(raw_json: string, keyring: ^vault.Vault_Keyring, key_configured: bool, allocator := context.allocator) -> string {
	return ctl_decrypt_issues_json(raw_json, keyring, key_configured, allocator)
}

ctl_issue_request_and_decrypt :: proc(transport: Ctl_Transport, req: Ctl_Request, args: []string = nil) {
	resp_str, ok := ctl_issue_request_local(transport, req)
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

ctl_issue_request :: proc(transport: Ctl_Transport, req: Ctl_Request) {
	ctl_issue_request_and_decrypt(transport, req, nil)
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
		query := ctl_query_make()
		ctl_query_add(&query, "status", option_value(args, "--status", ""))
		ctl_query_add(&query, "scope_type", option_value(args, "--scope", option_value(args, "--scope-type", "")))
		ctl_query_add(&query, "target_id", option_value(args, "--target-id", option_value(args, "--target", "")))
		ctl_query_add(&query, "chain_id", option_value(args, "--chain-id", option_value(args, "--chain", "")))
		ctl_query_add(&query, "query", option_value(args, "--query", option_value(args, "-q", "")))
		ctl_query_add(&query, "voter_id", option_value(args, "--voter-id", option_value(args, "--voter", "")))
		ctl_query_add(&query, "limit", option_value(args, "--limit", ""))
		ctl_query_add(&query, "offset", option_value(args, "--offset", ""))
		ctl_issue_request_and_decrypt(transport, {method = .GET, path = ctl_api("issues"), query = query[:]}, args)
		return
	}

	if action == "show" || action == "get" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue show <issue-id> [--voter-id <id>]"}`)
			return
		}
		query := ctl_query_make()
		ctl_query_add(&query, "voter_id", option_value(args, "--voter-id", option_value(args, "--voter", "")))
		ctl_issue_request_and_decrypt(transport, {method = .GET, path = ctl_api("issues", issue_id), query = query[:]}, args)
		return
	}

	if action == "create" {
		title := option_value(args, "--title", pos(cmd, idx + 1))
		if title == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue create --title <title> [--description <desc>] [--scope <scope>] [--target-id <id>] [--chain <id>] [--created-by <id>]"}`)
			return
		}
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring := ctl_vault_keyring_for_write(args)
		title = ctl_seal_or_exit(title, keyring)
		if desc != "" {
			desc = ctl_seal_or_exit(desc, keyring)
		}

		body := Ctl_Issue_Body{
			title       = title,
			description = desc,
			scope_type  = option_value(args, "--scope", option_value(args, "--scope-type", "")),
			target_id   = option_value(args, "--target-id", option_value(args, "--target", "")),
			chain_id    = option_value(args, "--chain-id", option_value(args, "--chain", "")),
			created_by  = option_value(args, "--created-by", ""),
		}
		ctl_issue_request_and_decrypt(transport, {method = .POST, path = ctl_api("issues"), body = httpc.json_body(body)}, args)
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

		keyring := ctl_vault_keyring_for_write(args)
		if t != "" {
			t = ctl_seal_or_exit(t, keyring)
		}
		if desc != "" {
			desc = ctl_seal_or_exit(desc, keyring)
		}

		body := Ctl_Issue_Body{
			title       = t,
			description = desc,
			status      = option_value(args, "--status", ""),
			scope_type  = option_value(args, "--scope", option_value(args, "--scope-type", "")),
			target_id   = option_value(args, "--target-id", option_value(args, "--target", "")),
			chain_id    = option_value(args, "--chain-id", option_value(args, "--chain", "")),
		}
		ctl_issue_request_and_decrypt(transport, {method = .PATCH, path = ctl_api("issues", issue_id), body = httpc.json_body(body)}, args)
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
			ctl_issue_request_and_decrypt(transport, {method = .GET, path = ctl_api("issues", issue_id, "comments")}, args)
			return
		}
		if body == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue comment <issue-id> --body <body> [--author-id <id>] [--author-name <name>]"}`)
			return
		}

		keyring := ctl_vault_keyring_for_write(args)
		body = ctl_seal_or_exit(body, keyring)

		comment := Ctl_Issue_Comment_Body{
			body        = body,
			author_id   = option_value(args, "--author-id", option_value(args, "--author", "")),
			author_name = option_value(args, "--author-name", ""),
		}
		ctl_issue_request_and_decrypt(transport, {method = .POST, path = ctl_api("issues", issue_id, "comments"), body = httpc.json_body(comment)}, args)
		return
	}

	if action == "vote" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue vote <issue-id> [--voter-id <id>] [--voter-name <name>]"}`)
			return
		}
		vote := Ctl_Issue_Vote_Body{
			voter_id   = option_value(args, "--voter-id", option_value(args, "--voter", "")),
			voter_name = option_value(args, "--voter-name", ""),
		}
		ctl_issue_request(transport, {method = .POST, path = ctl_api("issues", issue_id, "vote"), body = httpc.json_body(vote)})
		return
	}

	if action == "unvote" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue unvote <issue-id> [--voter-id <id>]"}`)
			return
		}
		vote := Ctl_Issue_Vote_Body{voter_id = option_value(args, "--voter-id", option_value(args, "--voter", ""))}
		ctl_issue_request(transport, {method = .DELETE, path = ctl_api("issues", issue_id, "vote"), body = httpc.json_body(vote)})
		return
	}

	if action == "delete" || action == "remove" {
		issue_id := pos(cmd, idx + 1)
		if issue_id == "" do issue_id = option_value(args, "--issue-id", option_value(args, "--issue", option_value(args, "--id", "")))
		if issue_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl issue delete <issue-id>"}`)
			return
		}
		ctl_issue_request(transport, {method = .DELETE, path = ctl_api("issues", issue_id)})
		return
	}

	fmt.println(ctl_error_json(fmt.tprintf("unknown issue action '%s'", action)))
}

// Ctl_Issue_Body: issue create (title required) and update (only fields passed).
Ctl_Issue_Body :: struct {
	title:       string `json:"title,omitempty"`,
	description: string `json:"description,omitempty"`,
	status:      string `json:"status,omitempty"`,
	scope_type:  string `json:"scope_type,omitempty"`,
	target_id:   string `json:"target_id,omitempty"`,
	chain_id:    string `json:"chain_id,omitempty"`,
	created_by:  string `json:"created_by,omitempty"`,
}

Ctl_Issue_Comment_Body :: struct {
	body:        string `json:"body"`,
	author_id:   string `json:"author_id,omitempty"`,
	author_name: string `json:"author_name,omitempty"`,
}

Ctl_Issue_Vote_Body :: struct {
	voter_id:   string `json:"voter_id,omitempty"`,
	voter_name: string `json:"voter_name,omitempty"`,
}
