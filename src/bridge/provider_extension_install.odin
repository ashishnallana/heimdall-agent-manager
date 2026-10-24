package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Bridge_Extension_Install_Runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool)

bridge_extension_install_runner: Bridge_Extension_Install_Runner = bridge_process_run_capture_status

bridge_provider_extension_install_progress_json :: proc(command_id, provider, stage: string, progress_percent: int, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_extension_install_progress\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"provider\":\"")
	bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"stage\":\"")
	bridge_runtime_write_json_string(&b, stage)
	strings.write_string(&b, "\",\"progress_percent\":")
	strings.write_string(&b, fmt.tprintf("%d", progress_percent))
	strings.write_string(&b, ",\"message\":\"")
	bridge_runtime_write_json_string(&b, message)
	strings.write_string(&b, "\"")
	if stage == "failed" {
		strings.write_string(&b, ",\"error\":")
		contracts.write_wire_error(&b, bridge_cause_wire_error("install_failed", message))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_provider_extension_install_send_progress :: proc(conn: ^ws.Connection, command_id, provider, stage: string, progress_percent: int, message: string) -> bool {
	frame := bridge_provider_extension_install_progress_json(command_id, provider, stage, progress_percent, message)
	defer delete(frame)
	if conn == nil do return false
	return bridge_hub_send(conn, frame)
}

bridge_provider_extension_build_install_args :: proc(provider, binary_path, extension_path: string, allocator := context.temp_allocator) -> []string {
	prov := strings.trim_space(provider)
	if prov == "antigravity" {
		argv := make([]string, 4, allocator)
		argv[0] = binary_path
		argv[1] = "plugin"
		argv[2] = "install"
		argv[3] = extension_path
		return argv
	}
	if prov == "claude" || prov == "claude-code" {
		parent := filepath.dir(extension_path)
		marketplace_file, _ := filepath.join({parent, ".claude-plugin", "marketplace.json"}, allocator)
		if os.exists(marketplace_file) {
			argv := make([]string, 7, allocator)
			argv[0] = binary_path
			argv[1] = "plugin"
			argv[2] = "install"
			argv[3] = "--marketplace"
			argv[4] = parent
			argv[5] = "heimdall"
			argv[6] = "-y"
			return argv
		}
		argv := make([]string, 5, allocator)
		argv[0] = binary_path
		argv[1] = "plugin"
		argv[2] = "install"
		argv[3] = extension_path
		argv[4] = "-y"
		return argv
	}
	if prov == "codex" {
		argv := make([]string, 4, allocator)
		argv[0] = binary_path
		argv[1] = "plugin"
		argv[2] = "add"
		argv[3] = "heimdall@heimdall-codex"
		return argv
	}

	argv := make([]string, 4, allocator)
	argv[0] = binary_path
	argv[1] = "plugin"
	argv[2] = "install"
	argv[3] = extension_path
	return argv
}

bridge_hub_handle_extension_install_command :: proc(conn: ^ws.Connection, text: string) {
	fmt.println("bridge hub runtime command provider_extension_install")
	command_id := extract_json_string(text, "command_id", "")
	if command_id == "" {
		delete(command_id)
		command_id = extract_json_string(text, "request_id", "")
	}
	defer delete(command_id)

	if command_id != "" {
		if cached, ok := bridge_runtime_cached_command(command_id); ok {
			if conn != nil do _ = bridge_hub_send(conn, cached)
			return
		}
		accepted := bridge_command_result_json(command_id, "accepted", "")
		defer delete(accepted)
		bridge_runtime_cache_command(command_id, accepted)
		if conn != nil do _ = bridge_hub_send(conn, accepted)
	}

	provider := extract_json_string(text, "provider", "")
	defer delete(provider)
	if strings.trim_space(provider) == "" {
		msg := "missing provider parameter"
		_ = bridge_provider_extension_install_send_progress(conn, command_id, "", "failed", 0, msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("missing_provider", msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "installing", 10, "Resolving provider extension assets...")

	custom_ext := extract_json_string(text, "extension_path", "")
	ext_path := custom_ext if custom_ext != "" else bridge_get_bundled_extension_path(provider)
	defer {
		delete(custom_ext)
		if custom_ext == "" do delete(ext_path)
	}

	if ext_path == "" || !bridge_os_dir_exists(ext_path) {
		msg := fmt.tprintf("bundled extension directory not found for provider %q", provider)
		_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "failed", 0, msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("extension_not_found", msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	custom_bin := extract_json_string(text, "binary_path", "")
	bin_path := custom_bin
	bin_allocated := false
	if bin_path == "" {
		resolved, ok := bridge_provider_resolve_path(provider)
		if ok {
			bin_path = resolved
			bin_allocated = true
		}
	}
	defer {
		delete(custom_bin)
		if bin_allocated do delete(bin_path)
	}

	if bin_path == "" {
		msg := fmt.tprintf("provider binary not found for %q", provider)
		_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "failed", 0, msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("binary_not_found", msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "installing", 50, "Executing provider extension installation...")

	argv := bridge_provider_extension_build_install_args(provider, bin_path, ext_path, context.temp_allocator)
	stdout, stderr, exit_code, ok, timed_out := bridge_extension_install_runner(argv, 45 * time.Second)
	defer {
		delete(stdout)
		delete(stderr)
	}

	if !ok {
		err_msg := ""
		if len(stderr) > 0 {
			err_msg = stderr
		} else if len(stdout) > 0 {
			err_msg = stdout
		} else if timed_out {
			err_msg = "installation process timed out"
		} else {
			err_msg = fmt.tprintf("installation process exited with code %d", exit_code)
		}

		_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "failed", 0, err_msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("install_failed", err_msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "succeeded", 100, "Provider extension installed successfully")
	if command_id != "" {
		final := bridge_command_result_json(command_id, "succeeded", "installed")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		if conn != nil do _ = bridge_hub_send(conn, final)
	}

	// Automatically re-probe provider extension status upon completion
	filter := []string{provider}
	results := bridge_provider_discover(filter)
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	report := bridge_provider_discovery_report_json(command_id, results)
	defer delete(report)
	if conn != nil do _ = bridge_hub_send(conn, report)
}
