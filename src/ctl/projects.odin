package main

import "core:fmt"
import "core:os"
import "core:strings"

ctl_projects_request_and_decrypt :: proc(transport: Ctl_Transport, method, path, body_json: string, args: []string = nil) {
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
		ctl_projects_request_and_decrypt(transport, "GET", "/api/v1/projects", "", args)
		return
	}

	if action == "show" || action == "get" {
		project_id := pos(cmd, idx + 1)
		if project_id == "" do project_id = option_value(args, "--project-id", option_value(args, "--project", option_value(args, "--id", "")))
		if project_id == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl projects show <project-id> | --project-id <id>"}`)
			return
		}
		ctl_projects_request_and_decrypt(transport, "GET", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), "", args)
		return
	}

	if action == "create" {
		name := option_value(args, "--name", pos(cmd, idx + 1))
		if name == "" {
			fmt.println(`{"ok":false,"message":"usage: ham-ctl projects create --name <name> [--description <text>] [--slug <slug>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"}`)
			return
		}
		desc := option_value(args, "--description", option_value(args, "--desc", ""))

		keyring, key_ok := ctl_vault_keyring_for_write(args, transport)
		if key_ok {
			if !is_vault_armored(name) {
				name = ctl_seal_or_exit(name, keyring)
			}
			if desc != "" && !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
		}

		fields := make([dynamic]string)
		defer delete(fields)
		append(&fields, json_kv("name", name))
		if slug := option_value(args, "--slug", ""); slug != "" do append(&fields, json_kv("slug", slug))
		if desc != "" do append(&fields, json_kv("description", desc))
		if repo := option_value(args, "--repo-url", option_value(args, "--repo", "")); repo != "" do append(&fields, json_kv("repo_url", repo))
		if vcs := option_value(args, "--vcs-kind", ""); vcs != "" do append(&fields, json_kv("vcs_kind", vcs))
		if path := option_value(args, "--default-path", option_value(args, "--path", "")); path != "" do append(&fields, json_kv("default_path", path))

		ctl_projects_request_and_decrypt(transport, "POST", "/api/v1/projects", json_object_from_slice(fields[:]), args)
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

		keyring, key_ok := ctl_vault_keyring_for_write(args, transport)
		if key_ok {
			if name != "" && !is_vault_armored(name) {
				name = ctl_seal_or_exit(name, keyring)
			}
			if desc != "" && !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
		}

		fields := make([dynamic]string)
		defer delete(fields)
		if name != "" do append(&fields, json_kv("name", name))
		if desc != "" do append(&fields, json_kv("description", desc))
		if slug := option_value(args, "--slug", ""); slug != "" do append(&fields, json_kv("slug", slug))
		if repo := option_value(args, "--repo-url", option_value(args, "--repo", "")); repo != "" do append(&fields, json_kv("repo_url", repo))
		if vcs := option_value(args, "--vcs-kind", ""); vcs != "" do append(&fields, json_kv("vcs_kind", vcs))
		if path := option_value(args, "--default-path", option_value(args, "--path", "")); path != "" do append(&fields, json_kv("default_path", path))

		ctl_projects_request_and_decrypt(transport, "PATCH", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), json_object_from_slice(fields[:]), args)
		return
	}

	fmt.println("usage: ham-ctl projects <list|create|show|update>")
}
