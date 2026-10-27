package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Bridge_Extension_Install_Runner :: proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool)

bridge_extension_install_runner: Bridge_Extension_Install_Runner = bridge_process_run_capture_status

Bridge_Provider_Discover_Proc :: proc(filter: []string) -> [dynamic]Bridge_Provider_Path

bridge_extension_discover: Bridge_Provider_Discover_Proc = bridge_provider_discover_execute

Bridge_Extension_Required_Version_Proc :: proc(provider: string) -> string

// The Hub catalog's minimum extension version for a provider ("" when unknown).
bridge_extension_required_version: Bridge_Extension_Required_Version_Proc = bridge_extension_catalog_required_version

bridge_extension_catalog_required_version :: proc(provider: string) -> string {
	profile, ok := bridge_provider_catalog_profile(provider)
	if !ok do return ""
	return strings.trim_space(profile.extension.min_version)
}

// Claude Code resolves plugins only through registered marketplaces. Older
// releases reject `plugin install --marketplace` and `-y`, so installation
// registers the bundled marketplace first and then installs by plugin id.
BRIDGE_CLAUDE_PLUGIN_ID :: "heimdall@heimdall"
BRIDGE_CODEX_PLUGIN_ID :: "heimdall@heimdall-codex"

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
		argv := make([]string, 4, allocator)
		argv[0] = binary_path
		argv[1] = "plugin"
		argv[2] = "install"
		argv[3] = BRIDGE_CLAUDE_PLUGIN_ID
		return argv
	}
	if prov == "codex" {
		argv := make([]string, 4, allocator)
		argv[0] = binary_path
		argv[1] = "plugin"
		argv[2] = "add"
		argv[3] = BRIDGE_CODEX_PLUGIN_ID
		return argv
	}

	argv := make([]string, 4, allocator)
	argv[0] = binary_path
	argv[1] = "plugin"
	argv[2] = "install"
	argv[3] = extension_path
	return argv
}

bridge_codex_resolve_marketplace_root :: proc(ext_path: string, allocator := context.temp_allocator) -> (string, bool) {
	mp1, _ := filepath.join({ext_path, ".agents", "plugins", "marketplace.json"}, context.temp_allocator)
	if os.exists(mp1) do return strings.clone(ext_path, allocator), true

	parent := filepath.dir(ext_path)
	mp2, _ := filepath.join({parent, ".agents", "plugins", "marketplace.json"}, context.temp_allocator)
	if os.exists(mp2) do return strings.clone(parent, allocator), true


	return "", false
}

// bridge_claude_resolve_marketplace_root finds the directory holding
// .claude-plugin/marketplace.json: the extension itself or its parent.
bridge_claude_resolve_marketplace_root :: proc(ext_path: string, allocator := context.temp_allocator) -> (string, bool) {
	own, _ := filepath.join({ext_path, ".claude-plugin", "marketplace.json"}, context.temp_allocator)
	if os.exists(own) do return strings.clone(ext_path, allocator), true

	parent := filepath.dir(ext_path)
	shared, _ := filepath.join({parent, ".claude-plugin", "marketplace.json"}, context.temp_allocator)
	if os.exists(shared) do return strings.clone(parent, allocator), true

	return "", false
}

bridge_provider_extension_read_manifest_version :: proc(ext_path, provider: string, allocator := context.temp_allocator) -> string {
	variant := provider
	manifest := "plugin.json"
	switch provider {
	case "claude", "claude-code": variant = "claude-code"; manifest = ".claude-plugin/plugin.json"
	case "codex": manifest = ".codex-plugin/plugin.json"
	}
	candidates := make([dynamic]string, context.temp_allocator)
	direct, _ := filepath.join({ext_path, manifest}, context.temp_allocator)
	nested, _ := filepath.join({ext_path, variant, manifest}, context.temp_allocator)
	append(&candidates, direct, nested)

	for cand in candidates {
		if os.exists(cand) {
			if data, read_err := os.read_entire_file(cand, context.temp_allocator); read_err == nil {
				if parsed, err := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); err == nil {
					if obj, is_obj := parsed.(json.Object); is_obj {
						if v, ok_v := obj["version"].(json.String); ok_v {
							return strings.clone(string(v), allocator)
						}
					}
				}
			}
		}
	}
	return ""
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
	prov := strings.trim_space(provider)
	if prov == "" {
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

	if prov != "antigravity" && prov != "claude" && prov != "claude-code" && prov != "codex" {
		msg := fmt.tprintf("unsupported provider %q (supported: antigravity, claude, codex)", prov)
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "failed", 0, msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("unsupported_provider", msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 10, "Resolving provider extension assets...")

	custom_ext := extract_json_string(text, "extension_path", "")
	ext_path := custom_ext if custom_ext != "" else bridge_get_bundled_extension_path(prov)
	defer {
		delete(custom_ext)
		if custom_ext == "" do delete(ext_path)
	}

	if ext_path == "" || !bridge_os_dir_exists(ext_path) {
		msg := fmt.tprintf("bundled extension directory not found for provider %q", prov)
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "failed", 0, msg)
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
		resolved, ok := bridge_provider_resolve_path("claude" if prov == "claude-code" else prov)
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
		msg := fmt.tprintf("provider binary not found for %q", prov)
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "failed", 0, msg)
		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_cause_wire_error("binary_not_found", msg), "failed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	// Reserve eight seconds for a fresh discovery. All installer calls share the
	// remaining budget, keeping the total below the dispatcher's sixty-second cap.
	deadline := time.time_add(time.now(), 55 * time.Second)
	install_deadline := time.time_add(deadline, -8 * time.Second)
	bundled_version := bridge_provider_extension_read_manifest_version(ext_path, prov)
	canonical_provider := "claude" if prov == "claude-code" else prov
	required_version := bridge_extension_required_version(canonical_provider)
	// Verification needs the newer of the bundled manifest and the catalog
	// minimum; discovery reports "outdated" below the latter.
	expected_version := bundled_version
	if required_version != "" && bundled_version != "" && bridge_provider_extension_version_compare(required_version, bundled_version) > 0 {
		expected_version = required_version
	}

	// REQ-MB-5: provider plugin registration is per OS user, so another Bridge
	// under the same account may already have registered its own copy. Installing
	// would re-point the marketplace at this Bridge's bundle; leave an equal or
	// newer registration alone and only upgrade an older or unusable one.
	if installed_version, current := bridge_extension_install_current(conn, command_id, canonical_provider, expected_version); current {
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "succeeded", 100,
			fmt.tprintf("Provider extension %s is already installed (bundled %s); registration left unchanged", installed_version, expected_version))
		if command_id != "" {
			final := bridge_command_result_json(command_id, "succeeded", "installed")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	// Installing a bundle older than the catalog minimum cannot satisfy
	// verification and would only re-point the registration at stale assets.
	if required_version != "" && bundled_version != "" && bridge_provider_extension_version_compare(bundled_version, required_version) < 0 {
		bridge_extension_install_fail(conn, command_id, prov, "bundled_extension_outdated",
			fmt.tprintf("bundled %s extension at %s is version %q, but Heimdall requires %q or newer; update this Bridge to a release that bundles extension %s, then retry",
				prov, ext_path, bundled_version, required_version, required_version))
		return
	}

	if prov == "claude" || prov == "claude-code" {
		mp_root, has_mp := bridge_claude_resolve_marketplace_root(ext_path)
		if !has_mp {
			bridge_extension_install_fail(conn, command_id, prov, "missing_marketplace",
				fmt.tprintf("missing Claude marketplace metadata (.claude-plugin/marketplace.json) for extension directory: %s", ext_path))
			return
		}
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 25, "Registering Claude local plugin marketplace...")
		_, message, registered := bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", mp_root}, install_deadline)
		if !registered {
			bridge_extension_install_fail(conn, command_id, prov, "marketplace_add_failed", message)
			return
		}
	}

	if prov == "codex" {
		mp_root, has_mp := bridge_codex_resolve_marketplace_root(ext_path)
		if !has_mp {
			bridge_extension_install_fail(conn, command_id, prov, "missing_marketplace",
				fmt.tprintf("missing Codex marketplace metadata for extension directory: %s", ext_path))
			return
		}
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 25, "Registering Codex local plugin marketplace...")
		_, message, registered := bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", mp_root}, install_deadline)
		if !registered {
			bridge_extension_install_fail(conn, command_id, prov, "marketplace_add_failed", message)
			return
		}
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 50, "Executing provider extension installation...")
	argv := bridge_provider_extension_build_install_args(prov, bin_path, ext_path)
	output, install_error, installed := bridge_extension_install_step(argv, install_deadline)
	if !installed {
		bridge_extension_install_fail(conn, command_id, prov, "install_failed", install_error)
		return
	}
	if (prov == "claude" || prov == "claude-code") && strings.contains(strings.to_lower(output, context.temp_allocator), "already installed") {
		_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 65, "Updating existing Claude extension...")
		_, message, updated := bridge_extension_install_step({bin_path, "plugin", "update", BRIDGE_CLAUDE_PLUGIN_ID}, install_deadline)
		if !updated {
			bridge_extension_install_fail(conn, command_id, prov, "update_failed", message)
			return
		}
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 80, "Verifying installed extension status...")
	// Discovery evaluates the catalog minimum too. Compare against the manifest
	// as well, since a newer bundle may arrive before the catalog is refreshed.
	results := bridge_extension_discover({canonical_provider})
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	report := bridge_provider_discovery_report_json(command_id, results)
	defer delete(report)
	if conn != nil do _ = bridge_hub_send(conn, report)

	verified := false
	actual_state := "absent"
	actual_version := ""
	for r in results {
		if r.provider != canonical_provider && !(canonical_provider == "claude" && r.provider == "claude-code") do continue
		actual_state = r.extension_state
		actual_version = r.extension_version
		verified = r.state == "present" && r.extension_state == "present" &&
			expected_version != "" && actual_version != "" &&
			bridge_provider_extension_version_compare(actual_version, expected_version) >= 0
		break
	}
	if time.diff(time.now(), deadline) <= 0 {
		bridge_extension_install_fail(conn, command_id, prov, "timed_out", "extension installation timed out during status verification")
		return
	}
	if !verified {
		bridge_extension_install_fail(conn, command_id, prov, "verify_failed",
			fmt.tprintf("extension installation verification failed: state is %q, version is %q (required %q or newer, bundled %q)",
				actual_state, actual_version, expected_version, bundled_version))
		return
	}
	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "succeeded", 100, "Provider extension installed successfully")
	if command_id != "" {
		final := bridge_command_result_json(command_id, "succeeded", "installed")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		if conn != nil do _ = bridge_hub_send(conn, final)
	}
}

// bridge_extension_install_current reports whether the provider already has a
// usable extension at expected_version or newer. When it does, the discovery
// report is sent so the Hub sees the version that stays installed. An unknown
// bundled or installed version is never treated as current.
bridge_extension_install_current :: proc(conn: ^ws.Connection, command_id, canonical_provider, expected_version: string) -> (installed_version: string, current: bool) {
	if expected_version == "" do return "", false
	results := bridge_extension_discover({canonical_provider})
	defer {
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
	}
	for r in results {
		if r.provider != canonical_provider && !(canonical_provider == "claude" && r.provider == "claude-code") do continue
		current = r.state == "present" && r.extension_state == "present" && r.extension_version != "" &&
			bridge_provider_extension_version_compare(r.extension_version, expected_version) >= 0
		if current do installed_version = strings.clone(r.extension_version, context.temp_allocator)
		break
	}
	if current {
		report := bridge_provider_discovery_report_json(command_id, results)
		defer delete(report)
		if conn != nil do _ = bridge_hub_send(conn, report)
	}
	return
}

bridge_extension_install_fail :: proc(conn: ^ws.Connection, command_id, provider, code, message: string) {
	_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "failed", 0, message)
	if command_id == "" do return
	final := bridge_command_failed_json(command_id, bridge_cause_wire_error(code, message), "failed")
	defer delete(final)
	bridge_runtime_cache_command(command_id, final)
	if conn != nil do _ = bridge_hub_send(conn, final)
}

bridge_extension_install_step :: proc(argv: []string, deadline: time.Time) -> (output, error_message: string, ok: bool) {
	remaining := time.diff(time.now(), deadline)
	if remaining <= 0 do return "", "extension installation timed out", false
	stdout, stderr, exit_code, ran, timed_out := bridge_extension_install_runner(argv, min(remaining, 25 * time.Second))
	defer { delete(stdout); delete(stderr) }
	if !ran {
		message := strings.trim_space(stderr)
		if message == "" do message = strings.trim_space(stdout)
		if timed_out do message = "extension installation timed out"
		if message == "" do message = fmt.tprintf("installer process exited with code %d", exit_code)
		return "", strings.clone(message, context.temp_allocator), false
	}
	return strings.concatenate({stdout, "\n", stderr}, context.temp_allocator), "", true
}
