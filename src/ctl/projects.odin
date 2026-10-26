package main

import "core:fmt"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"

ctl_projects_request_and_decrypt :: proc(transport: Ctl_Transport, req: Ctl_Request, args: []string = nil) {
	resp_str, ok := ctl_tasks_request_local(transport, req)
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

print_projects_help :: proc() {
	fmt.println("ham-ctl projects — manage projects")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  ham-ctl projects [list]")
	fmt.println("  ham-ctl projects show <project-id> | --project-id <id>")
	fmt.println("  ham-ctl projects create --name <name> [--description <text>] [--slug <slug>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]")
	fmt.println("  ham-ctl projects update <project-id> | --project-id <id> [--name <name>] [--description <text>] [--slug <slug>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]")
}

ctl_projects_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "projects" || cmd[0] == "project") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_projects_help()
		return
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	if action == "" || action == "list" {
		ctl_projects_request_and_decrypt(transport, {method = .GET, path = ctl_api("projects")}, args)
		return
	}

	if action == "show" || action == "get" {
		project_id := pos(cmd, idx + 1)
		if project_id == "" do project_id = option_value(args, "--project-id", option_value(args, "--project", option_value(args, "--id", "")))
		if project_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl projects show <project-id> | --project-id <id>"}`)
			return
		}
		ctl_projects_request_and_decrypt(transport, {method = .GET, path = ctl_api("projects", project_id)}, args)
		return
	}

	if action == "create" {
		name := option_value(args, "--name", pos(cmd, idx + 1))
		if name == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl projects create --name <name> [--description <text>] [--slug <slug>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"}`)
			return
		}
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring := ctl_vault_keyring_for_write(args)
		if !is_vault_armored(name) {
			name = ctl_seal_or_exit(name, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}

		body := ctl_project_body(args)
		body.name = name
		body.description = desc
		ctl_projects_request_and_decrypt(transport, {method = .POST, path = ctl_api("projects"), body = httpc.json_body(body)}, args)
		return
	}

	if action == "update" || action == "patch" {
		project_id := pos(cmd, idx + 1)
		if project_id == "" do project_id = option_value(args, "--project-id", option_value(args, "--project", option_value(args, "--id", "")))
		if project_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl projects update <project-id> | --project-id <id> [--name <name>] [--description <text>] [--slug <slug>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"}`)
			return
		}

		name := option_value(args, "--name", "")
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring := ctl_vault_keyring_for_write(args)
		if name != "" && !is_vault_armored(name) {
			name = ctl_seal_or_exit(name, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}

		body := ctl_project_body(args)
		body.name = name
		body.description = desc
		ctl_projects_request_and_decrypt(transport, {method = .PATCH, path = ctl_api("projects", project_id), body = httpc.json_body(body)}, args)
		return
	}

	fmt.println("usage: ham-ctl projects <list|create|show|update>")
}

// Ctl_Project_Body: `projects create|update`; only the fields passed are sent
// (create always has a name).
Ctl_Project_Body :: struct {
	name:         string `json:"name,omitempty"`,
	slug:         string `json:"slug,omitempty"`,
	description:  string `json:"description,omitempty"`,
	repo_url:     string `json:"repo_url,omitempty"`,
	vcs_kind:     string `json:"vcs_kind,omitempty"`,
	default_path: string `json:"default_path,omitempty"`,
}

ctl_project_body :: proc(args: []string) -> Ctl_Project_Body {
	return {
		slug         = option_value(args, "--slug", ""),
		repo_url     = option_value(args, "--repo-url", option_value(args, "--repo", "")),
		vcs_kind     = option_value(args, "--vcs-kind", ""),
		default_path = option_value(args, "--default-path", option_value(args, "--path", "")),
	}
}
