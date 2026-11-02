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

bridge_provider_extension_install_progress_json :: proc(command_id, provider, stage: string, progress_percent: int, message: string, profile_id: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_extension_install_progress\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"provider\":\"")
	bridge_runtime_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"profile_id\":\""); bridge_runtime_write_json_string(&b,profile_effective_id(provider,profile_id))
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

bridge_provider_extension_install_send_progress :: proc(conn: ^ws.Connection, command_id, provider, stage: string, progress_percent: int, message: string, profile_id: string = "") -> bool {
	frame := bridge_provider_extension_install_progress_json(command_id, provider, stage, progress_percent, message,profile_id)
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

Bridge_Extension_Frame_Sink :: struct {
	profile_id: string,
	conn:       ^ws.Connection,
	command_id: string,
	provider:   string,
}

@(private = "file")
bridge_extension_frame_progress :: proc(data: rawptr, stage: string, pct: int, message: string) {
	s := (^Bridge_Extension_Frame_Sink)(data)
	_ = bridge_provider_extension_install_send_progress(s.conn, s.command_id, s.provider, stage, pct, message,s.profile_id)
}

@(private = "file")
bridge_extension_frame_report :: proc(data: rawptr, results: []Bridge_Provider_Path) {
	s := (^Bridge_Extension_Frame_Sink)(data)
	report := bridge_provider_discovery_report_json(s.command_id, results)
	defer delete(report)
	if s.conn != nil do _ = bridge_hub_send(s.conn, report)
}

// bridge_hub_handle_extension_install_command installs or repairs one
// provider's extension for the Hub. Only `provider` is read from the frame:
// the extension bundle and the provider binary are resolved locally, so a Hub
// frame can never make the Bridge execute a path it names (F12).
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
		bridge_extension_install_fail(conn, command_id, "", "missing_provider", "missing provider parameter")
		return
	}
	if !bridge_extension_provider_supported(prov) {
		bridge_extension_install_fail(conn, command_id, prov, "unsupported_provider",
			fmt.tprintf("unsupported provider %q (supported: antigravity, claude, codex)", prov))
		return
	}

	profile_id := extract_json_string(text,"profile_id",""); defer delete(profile_id)
	canonical := bridge_extension_canonical_provider(prov)
	pp, profile_error := profile_lookup(canonical,profile_id)
	if profile_error != .None {
		bridge_extension_install_fail(conn,command_id,prov,profile_error_code(profile_error),"provider profile cannot be used",profile_id)
		return
	}
	pp_ref: ^Provider_Profile = &pp if profile_id != "" || profile_runtime_configured(&pp) else nil
	// action=uninstall shares this frame (and its per-provider ordering key).
	action := extract_json_string(text, "action", "")
	defer delete(action)
	if action == "uninstall" {
		bridge_hub_handle_extension_uninstall(conn, command_id, prov,pp_ref)
		return
	}

	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "installing", 10, "Resolving provider extension assets...",profile_id)
	// A provider profile registers from this profile's own copy, which no other profile prunes.
	ext_path := bridge_get_profile_extension_path(canonical) if pp_ref != nil else bridge_extension_bundle_resolver(canonical)
	defer delete(ext_path)
	if ext_path == "" || !bridge_os_dir_exists(ext_path) {
		bridge_extension_install_fail(conn, command_id, prov, "extension_not_found",
			fmt.tprintf("bundled extension directory not found for provider %q", prov),profile_id)
		return
	}
	bin_path, has_bin := bridge_extension_resolve_profile_binary(canonical,pp_ref)
	defer if has_bin do delete(bin_path)
	if !has_bin || bin_path == "" {
		bridge_extension_install_fail(conn, command_id, prov, "binary_not_found", fmt.tprintf("provider binary not found for %q", prov),profile_id)
		return
	}

	// Stay below the dispatcher's sixty-second cap.
	sink_data := Bridge_Extension_Frame_Sink{conn = conn, command_id = command_id, provider = prov,profile_id = pp.profile_id}
	sink := Bridge_Extension_Sink{data = &sink_data, progress = bridge_extension_frame_progress, report = bridge_extension_frame_report,profile = pp_ref}
	if pp_ref != nil {
		env_ok: bool
		sink.env,env_ok = profile_child_env(pp_ref)
		if !env_ok { bridge_extension_install_fail(conn,command_id,prov,"environment_unavailable","cannot read child environment",profile_id); return }
	}
	result := bridge_extension_ensure(canonical, ext_path, bin_path, time.time_add(time.now(), BRIDGE_EXTENSION_PROVIDER_TIMEOUT), sink)
	if !result.ok {
		bridge_extension_install_fail(conn, command_id, prov, result.code, profile_redact_text(result.message,pp_ref),profile_id)
		return
	}
	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "succeeded", 100, profile_redact_text(result.message,pp_ref),profile_id)
	if command_id != "" {
		final := bridge_command_result_json(command_id, "succeeded", "installed")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		if conn != nil do _ = bridge_hub_send(conn, final)
	}
}

bridge_hub_handle_extension_uninstall :: proc(conn: ^ws.Connection, command_id, prov: string, pp: ^Provider_Profile = nil) {
	profile_id := pp.profile_id if pp != nil else prov
	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "uninstalling", 10, "Resolving the provider CLI...",profile_id)
	canonical := bridge_extension_canonical_provider(prov)
	bin_path, has_bin := bridge_extension_resolve_profile_binary(canonical,pp)
	defer if has_bin do delete(bin_path)
	if !has_bin || bin_path == "" {
		bridge_extension_install_fail(conn, command_id, prov, "binary_not_found", fmt.tprintf("provider binary not found for %q", prov),profile_id)
		return
	}
	sink_data := Bridge_Extension_Frame_Sink{conn = conn, command_id = command_id, provider = prov,profile_id = pp.profile_id if pp != nil else prov}
	sink := Bridge_Extension_Sink{data = &sink_data, progress = bridge_extension_frame_progress, report = bridge_extension_frame_report,profile = pp}
	if pp != nil {
		env_ok: bool
		sink.env,env_ok = profile_child_env(pp)
		if !env_ok { bridge_extension_install_fail(conn,command_id,prov,"environment_unavailable","cannot read child environment",profile_id); return }
	}
	result := bridge_extension_remove(canonical, bin_path, time.time_add(time.now(), BRIDGE_EXTENSION_PROVIDER_TIMEOUT), sink)
	if !result.ok {
		bridge_extension_install_fail(conn, command_id, prov, result.code, profile_redact_text(result.message,pp),profile_id)
		return
	}
	_ = bridge_provider_extension_install_send_progress(conn, command_id, prov, "succeeded", 100, profile_redact_text(result.message,pp),profile_id)
	if command_id != "" {
		final := bridge_command_result_json(command_id, "succeeded", "uninstalled")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		if conn != nil do _ = bridge_hub_send(conn, final)
	}
}

bridge_extension_install_fail :: proc(conn: ^ws.Connection, command_id, provider, code, message: string, profile_id: string = "") {
	_ = bridge_provider_extension_install_send_progress(conn, command_id, provider, "failed", 0, message,profile_id)
	if command_id == "" do return
	final := bridge_command_failed_json(command_id, bridge_cause_wire_error(code, message), "failed")
	defer delete(final)
	bridge_runtime_cache_command(command_id, final)
	if conn != nil do _ = bridge_hub_send(conn, final)
}

bridge_extension_install_step :: proc(argv: []string, deadline: time.Time, env: []string = nil) -> (output, error_message: string, ok: bool) {
	remaining := time.diff(time.now(), deadline)
	if remaining <= 0 do return "", "extension installation timed out", false
	stdout, stderr: string
	exit_code: int
	ran,timed_out: bool
	if env == nil {
		stdout,stderr,exit_code,ran,timed_out = bridge_extension_install_runner(argv,min(remaining,25*time.Second))
	} else {
		stdout,stderr,exit_code,ran,timed_out = bridge_process_run_capture_status_env(argv,min(remaining,25*time.Second),env)
	}
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

bridge_extension_resolve_profile_binary :: proc(provider: string, pp: ^Provider_Profile) -> (string,bool) {
	if pp == nil do return bridge_extension_binary_resolver(provider)
	env,ok := profile_child_env(pp)
	if !ok do return "",false
	binary := pp.config.binary_path
	if binary == "" {
		catalog,found := bridge_provider_catalog_profile(provider)
		if !found || len(catalog.command) == 0 do return "",false
		binary = catalog.command[0]
	}
	path := profile_resolve_binary(binary,env)
	return path,path != ""
}
