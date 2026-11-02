package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import cfg_lib "odin_test:lib/config"
import agent_runtime "odin_test:lib/agent_runtime"
import jsonx "odin_test:lib/jsonx"

// Bridge_Provider_Profile is a read-only projection of the Hub-owned catalog.
// command receives the Bridge-owned absolute executable path only at launch.
Bridge_Provider_Profile :: struct {
	name: string,
	command: []string,
	base_args: []string,
	yolo_flags: []string,
	ask_flags: []string,
	prompt_flags: []string,
	starter_prompt: string,
	extension: Bridge_Catalog_Extension,
	extension_expected: bool,
	prompt_delivery: string,
	prompt_tmux_delay_ms: int,
	prompt_tmux_enter: bool,
	skill_dir: string,
	bootstrap_file_name: string,
	model_flag: string,
	extra_args: []string, // provider profile args, or the default Codex profile's own-extension overrides; never from the catalog
	startup_detection: cfg_lib.Startup_Detection_Config,
	activity_detection: cfg_lib.Activity_Detection_Config,
}

// There is no mutable provider store or default provider. This entry point now
// initializes only the two caches with explicit owners.
bridge_provider_store_init :: proc() {
	bridge_provider_catalog_init()
	bridge_provider_paths_init()
}

bridge_expand_home :: proc(path: string) -> string {
	if strings.has_prefix(path, "~/") {
		home := cfg_lib.home_dir()
		defer delete(home)
		if home != "" do return strings.concatenate({home, path[1:]})
	}
	return path
}

// Exact lookup only. Empty or unknown names never select a default provider.
bridge_provider_by_name_or_default :: proc(name: string) -> (Bridge_Provider_Profile, bool) {
	return bridge_provider_catalog_profile(strings.trim_space(name))
}

bridge_provider_default_skill_dir :: proc(provider: string) -> string {
	if profile, ok := bridge_provider_catalog_profile(strings.trim_space(provider)); ok do return profile.skill_dir
	return ""
}

bridge_provider_write_startup_json :: proc(b: ^strings.Builder, sd: cfg_lib.Startup_Detection_Config) {
	strings.write_string(b, "{\"enabled\":"); strings.write_string(b, "true" if sd.enabled else "false")
	strings.write_string(b, ",\"startup_probe_seconds\":"); strings.write_string(b, fmt.tprintf("%d", sd.startup_probe_seconds))
	strings.write_string(b, ",\"capture_interval_ms\":"); strings.write_string(b, fmt.tprintf("%d", sd.capture_interval_ms))
	strings.write_string(b, ",\"blocked_patterns\":"); bridge_provider_write_string_array_json(b, sd.blocked_patterns)
	strings.write_string(b, ",\"auto_enter_patterns\":"); bridge_provider_write_string_array_json(b, sd.auto_enter_patterns)
	strings.write_string(b, ",\"auto_enter_pre_keys\":"); bridge_provider_write_string_array_json(b, sd.auto_enter_pre_keys)
	strings.write_string(b, ",\"startup_unknown_is_blocked\":"); strings.write_string(b, "true" if sd.startup_unknown_is_blocked else "false")
	strings.write_string(b, ",\"sanitized_reason_mapping\":"); bridge_provider_write_string_array_json(b, sd.sanitized_reason_mapping)
	strings.write_string(b, "}")
}

bridge_provider_write_string_array_json :: proc(b: ^strings.Builder, values: []string) {
	strings.write_byte(b, '[')
	for value, i in values {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		json_write_string(b, value)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

// Shared JSON helpers. These decode Bridge command/bootstrap frames; they no
// longer represent a user-editable provider document.
bridge_provider_json_extract_string :: proc(body, key, fallback: string) -> string {
	value, ok := bridge_provider_json_extract_string_set(body, key)
	if !ok do return fallback
	return value
}

bridge_provider_json_extract_string_set :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_string_found(body, key, false, allocator)
}

bridge_provider_json_extract_int :: proc(body, key: string) -> (int, bool) {
	return jsonx.extract_int_found(body, key)
}

bridge_provider_json_extract_object :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_object(body, key, false, allocator)
}

bridge_provider_json_extract_array :: proc(body, key: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_array(body, key, false, allocator)
}

bridge_provider_json_extract_string_array :: proc(body, key: string, allocator := context.allocator) -> ([]string, bool) {
	if !jsonx.has_key(body, key) do return nil, false
	values := jsonx.extract_string_array(body, key, false, allocator)
	return values[:], true
}

bridge_provider_json_parse_string_array :: proc(array: string, allocator := context.allocator) -> []string {
	values := jsonx.decode_string_array(array, allocator)
	return values[:]
}

bridge_provider_json_top_level_objects :: proc(array: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	parsed, err := json.parse_string(array, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	if err != .None do return out[:]
	items, is_array := parsed.(json.Array)
	if !is_array do return out[:]
	for item in items {
		if _, is_object := item.(json.Object); is_object {
			bytes, marshal_err := json.marshal(item, json.Marshal_Options{}, allocator)
			if marshal_err == nil do append(&out, string(bytes))
		}
	}
	return out[:]
}

bridge_agent_runtime_profile :: proc(profile: Bridge_Provider_Profile) -> agent_runtime.Agent_Profile {
	return agent_runtime.Agent_Profile{
		command = profile.command,
		base_args = profile.base_args,
		yolo_flags = profile.yolo_flags,
		ask_flags = profile.ask_flags,
		prompt_flags = profile.prompt_flags,
		starter_prompt = profile.starter_prompt,
		extension_expected = profile.extension_expected,
		prompt_delivery = profile.prompt_delivery,
		prompt_tmux_delay_ms = profile.prompt_tmux_delay_ms,
		prompt_tmux_enter = profile.prompt_tmux_enter,
		model_flag = profile.model_flag,
		extra_args = profile.extra_args,
		startup_detection = profile.startup_detection,
		activity_detection = profile.activity_detection,
	}
}

bridge_runtime_agent_argv_for_profile :: proc(profile: Bridge_Provider_Profile, model, agent_token, agent_instance_id: string, permission_mode := agent_runtime.PERMISSION_MODE_YOLO) -> []string {
	if strings.trim_space(model) == "" do return nil
	return agent_runtime.build_agent_command(bridge_agent_runtime_profile(profile), model, bridge_config.daemon_url, agent_token, agent_instance_id, permission_mode)
}

bridge_runtime_shell_command_for_profile :: proc(profile: Bridge_Provider_Profile, model, agent_token, agent_instance_id: string) -> string {
	argv := bridge_runtime_agent_argv_for_profile(profile, model, agent_token, agent_instance_id)
	defer if argv != nil do delete(argv)
	return bridge_shell_join(argv)
}

bridge_shell_join :: proc(argv: []string) -> string {
	b := strings.builder_make()
	for arg, i in argv {
		if i > 0 do strings.write_byte(&b, ' ')
		bridge_shell_write_quoted(&b, arg)
	}
	return strings.to_string(b)
}

bridge_shell_write_quoted :: proc(b: ^strings.Builder, arg: string) {
	strings.write_byte(b, '\'')
	for ch in arg {
		if ch == '\'' do strings.write_string(b, "'\\''")
		else do strings.write_rune(b, ch)
	}
	strings.write_byte(b, '\'')
}

bridge_provider_startup_log :: proc() {
	bridge_provider_catalog_init()
	bridge_provider_paths_init()
	catalog_count := 0
	present_count := 0
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot != nil do catalog_count = len(bridge_provider_catalog_snapshot.providers)
	sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
	for path in bridge_provider_paths {
		if path.state == "present" do present_count += 1
	}
	sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)
	fmt.printfln("bridge providers: catalog=%d present=%d", catalog_count, present_count)
}
