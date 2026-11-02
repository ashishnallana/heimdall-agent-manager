package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// REQ-EXT-DET-1: whether a provider's Heimdall extension is installed. The Hub
// catalog owns the descriptor; this file only runs `<binary> <detect_argv...>`
// and reads its inventory. Matching is data-driven (`id`, `enabled`, `version`,
// `errors`), with compatibility handling for Antigravity inventory formats.
Bridge_Catalog_Extension :: struct {
	// Empty selectors retain legacy flat-array id/version/enabled behavior.
	detect_collection: string `json:"detect_collection"`,
	detect_id_key: string `json:"detect_id_key"`,
	detect_version_key: string `json:"detect_version_key"`,
	detect_enabled_key: string `json:"detect_enabled_key"`,
	detect_argv:  []string `json:"detect_argv"`,
	plugin_id:    string `json:"plugin_id"`,
	min_version:  string `json:"min_version"`,
	install_hint: string `json:"install_hint"`,
	capabilities: []string `json:"capabilities"`,
	// Exact argv sequence selecting this extension's loader, followed by a
	// directory whose final components match load_path_suffix (when supplied).
	load_args: []string `json:"load_args"`,
	load_path_suffix: string `json:"load_path_suffix"`,
}

bridge_provider_extension_expected :: proc(profile: Bridge_Provider_Profile, discovery_state: string) -> bool {
	if discovery_state == "present" do return true
	ext := profile.extension
	if len(ext.load_args) == 0 do return false
	for i in 0..<len(profile.base_args) {
		if i + len(ext.load_args) > len(profile.base_args) do break
		matches := true
		for arg, j in ext.load_args {
			if profile.base_args[i + j] != arg { matches = false; break }
		}
		if !matches do continue
		if ext.load_path_suffix == "" do return true
		value_index := i + len(ext.load_args)
		if value_index >= len(profile.base_args) do continue
		path := strings.trim_right(profile.base_args[value_index], "/")
		suffix := strings.trim(ext.load_path_suffix, "/")
		if suffix != "" && (path == suffix || strings.has_suffix(path, strings.concatenate({"/", suffix}, context.temp_allocator))) do return true
	}
	return false
}

bridge_provider_launch_extension_expected :: proc(profile: Bridge_Provider_Profile, profile_id: string = "") -> bool {
	state := ""
	sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
	for p in bridge_provider_paths {
		if p.provider == profile.name && profile_effective_id(p.provider,p.profile_id) == profile_effective_id(profile.name,profile_id) { state = p.extension_state; break }
	}
	result := bridge_provider_extension_expected(profile, state)
	sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)
	return result
}

BRIDGE_PROVIDER_EXTENSION_TIMEOUT :: 5 * time.Second

// A catalog `"extension": null` unmarshals to the zero value: unsupported.
bridge_provider_extension_supported :: proc(ext: Bridge_Catalog_Extension) -> bool {
	return len(ext.detect_argv) > 0 && strings.trim_space(ext.plugin_id) != ""
}

// bridge_provider_extension_version_compare compares dotted numeric versions
// ("v1.2.10" > "1.2.9"); a pre-release/build suffix and missing parts count as 0.
bridge_provider_extension_version_compare :: proc(a, b: string) -> int {
	normalize :: proc(v: string) -> string {
		v := strings.trim_space(v)
		if strings.has_prefix(v, "v") || strings.has_prefix(v, "V") do v = v[1:]
		if cut := strings.index_any(v, "-+ "); cut >= 0 do v = v[:cut]
		return v
	}
	next_part :: proc(rest: ^string) -> int {
		if len(rest^) == 0 do return 0
		part := rest^
		if dot := strings.index_byte(part, '.'); dot >= 0 {
			rest^ = part[dot + 1:]
			part = part[:dot]
		} else {
			rest^ = ""
		}
		digits := 0
		for digits < len(part) && part[digits] >= '0' && part[digits] <= '9' do digits += 1
		value, _ := strconv.parse_int(part[:digits])
		return value
	}
	ra, rb := normalize(a), normalize(b)
	for len(ra) > 0 || len(rb) > 0 {
		pa, pb := next_part(&ra), next_part(&rb)
		if pa < pb do return -1
		if pa > pb do return 1
	}
	return 0
}

bridge_provider_extension_state_rank :: proc(state: string) -> int {
	switch state {
	case "present":  return 4
	case "outdated": return 3
	case "disabled": return 2
	case "error":    return 1
	}
	return 0
}

bridge_antigravity_plugin_enabled_state :: proc(plugin_id: string, paths: []string = nil) -> (enabled: bool, has_config: bool) {
	enabled = true
	candidates := make([dynamic]string, context.temp_allocator)
	if paths != nil {
		append(&candidates, ..paths)
	} else {
		if gemini_cfg := os.get_env("GEMINI_CONFIG_DIR", context.temp_allocator); gemini_cfg != "" {
			c1, _ := filepath.join({gemini_cfg, "config.json"}, context.temp_allocator)
			append(&candidates, c1)
			c2, _ := filepath.join({gemini_cfg, "config", "config.json"}, context.temp_allocator)
			append(&candidates, c2)
		}
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			c3, _ := filepath.join({home, ".gemini", "config", "config.json"}, context.temp_allocator)
			append(&candidates, c3)
			c4, _ := filepath.join({home, ".gemini", "config.json"}, context.temp_allocator)
			append(&candidates, c4)
		}
	}
	for cand in candidates {
		if os.exists(cand) {
			if data, read_err := os.read_entire_file(cand, context.temp_allocator); read_err == nil {
				if parsed, err := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); err == nil {
					if obj, is_obj := parsed.(json.Object); is_obj {
						if plugins_val, has_plugins := obj["plugins"].(json.Object); has_plugins {
							if plug_obj, has_plug := plugins_val[plugin_id].(json.Object); has_plug {
								if en_val, has_en := plug_obj["enabled"].(json.Boolean); has_en {
									return bool(en_val), true
								}
							}
						}
					}
				}
			}
		}
	}
	return true, false
}

bridge_provider_extension_installed_manifest_version :: proc(plugin_id: string, allocator := context.temp_allocator, paths: []string = nil) -> string {
	candidates := make([dynamic]string, context.temp_allocator)
	if paths != nil {
		append(&candidates, ..paths)
	} else {
		if gemini_cfg := os.get_env("GEMINI_CONFIG_DIR", context.temp_allocator); gemini_cfg != "" {
			c1, _ := filepath.join({gemini_cfg, "plugins", plugin_id, "plugin.json"}, context.temp_allocator)
			append(&candidates, c1)
			c2, _ := filepath.join({gemini_cfg, "config", "plugins", plugin_id, "plugin.json"}, context.temp_allocator)
			append(&candidates, c2)
		}
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			c3, _ := filepath.join({home, ".gemini", "config", "plugins", plugin_id, "plugin.json"}, context.temp_allocator)
			append(&candidates, c3)
			c4, _ := filepath.join({home, ".gemini", "plugins", plugin_id, "plugin.json"}, context.temp_allocator)
			append(&candidates, c4)
		}
	}
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

// bridge_provider_extension_evaluate turns detector output into a state and an
// owned version string. `ran` is false when the command failed, timed out, or was
// skipped by the circuit breaker. When a plugin is listed more than once (one
// entry per install scope), the most usable entry wins.
bridge_provider_extension_evaluate :: proc(ext: Bridge_Catalog_Extension, output: string, ran: bool, allocator := context.allocator, env: []string = nil) -> (state: string, version: string) {
	if !bridge_provider_extension_supported(ext) do return "unsupported", strings.clone("", allocator)
	if !ran do return "error", strings.clone("", allocator)
	// agy 1.2.16 emits this sentence instead of JSON for an empty inventory.
	// Normalize only surrounding whitespace (including the CLI newline); never
	// accept diagnostic prefixes/suffixes or another provider's output.
	if ext.plugin_id == "heimdall" && ext.detect_id_key == "name" &&
	   (ext.detect_collection == "installed" || ext.detect_collection == "imports") &&
	   strings.trim_space(output) == "No imported plugins." {
		return "absent", strings.clone("", allocator)
	}
	parsed, parse_err := json.parse_string(output, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_err != nil do return "error", strings.clone("", allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	collection := parsed
	using_antigravity_imports := false
	if ext.detect_collection != "" {
		object, is_object := parsed.(json.Object)
		if !is_object do return "error", strings.clone("", allocator)
		collection = object[ext.detect_collection]
		using_antigravity_imports = ext.plugin_id == "heimdall" && ext.detect_collection == "imports"
		if collection == nil && ext.plugin_id == "heimdall" {
			if ext.detect_collection == "installed" {
				if imports_val, has := object["imports"]; has {
					collection = imports_val
					using_antigravity_imports = true
				}
			} else if ext.detect_collection == "imports" {
				if inst_val, has := object["installed"]; has {
					collection = inst_val
					using_antigravity_imports = false
				}
			}
		}
	} else if object, is_object := parsed.(json.Object); is_object && ext.plugin_id == "heimdall" {
		if inst_val, has := object["installed"]; has {
			collection = inst_val
		} else if imports_val, has := object["imports"]; has {
			collection = imports_val
			using_antigravity_imports = true
		}
	}
	items, is_array := collection.(json.Array)
	if !is_array do return "error", strings.clone("", allocator)

	state = "absent"
	best_version := ""
	for item in items {
		object, is_object := item.(json.Object)
		if !is_object do continue
		id_key := ext.detect_id_key if ext.detect_id_key != "" else "id"
		version_key := ext.detect_version_key if ext.detect_version_key != "" else "version"
		enabled_key := ext.detect_enabled_key if ext.detect_enabled_key != "" else "enabled"
		id, _ := object[id_key].(json.String)
		if id != ext.plugin_id do continue
		entry_version_val, has_version := object[version_key].(json.String)
		entry_version := string(entry_version_val)
		if using_antigravity_imports && (!has_version || entry_version == "") {
			entry_version = bridge_provider_extension_installed_manifest_version(ext.plugin_id, context.temp_allocator,bridge_extension_gemini_paths(env,ext.plugin_id,true))
		}
		enabled := true
		if value, has := object[enabled_key].(json.Boolean); has {
			enabled = bool(value)
		} else if using_antigravity_imports {
			agy_enabled, _ := bridge_antigravity_plugin_enabled_state(ext.plugin_id,bridge_extension_gemini_paths(env,ext.plugin_id,false))
			enabled = agy_enabled
		}
		has_errors := false
		// A descriptor that requests explicit enabled evidence must receive it.
		if ext.detect_enabled_key != "" {
			_, has_enabled := object[enabled_key].(json.Boolean)
			if !has_enabled {
				// Imports records omit enabled; importedAt proves installation.
				// The configuration read above supplies the effective enabled flag.
				if imported_at, has_imported := object["importedAt"].(json.String); !has_imported || imported_at == "" || !using_antigravity_imports {
					has_errors = true
				}
			}
		}
		if ext.detect_version_key != "" && ext.min_version != "" {
			// Unknown or nonnumeric versions are not compatibility evidence.
			v := string(entry_version)
			if len(v) > 0 && (v[0] == 'v' || v[0] == 'V') do v = v[1:]
			if cut := strings.index_any(v, "-+"); cut >= 0 do v = v[:cut]
			if len(v) == 0 do has_errors = true
			previous_dot := true
			for ch in v {
				if ch == '.' {
					if previous_dot do has_errors = true
					previous_dot = true
				} else {
					if ch < '0' || ch > '9' do has_errors = true
					previous_dot = false
				}
			}
			if previous_dot do has_errors = true
		}
		#partial switch errors in object["errors"] {
		case json.Array:  has_errors = has_errors || len(errors) > 0
		case json.String: has_errors = has_errors || strings.trim_space(errors) != ""
		}
		entry_state := "present"
		if has_errors {
			entry_state = "error"
		} else if !enabled {
			entry_state = "disabled"
		} else if ext.min_version != "" && entry_version != "" && bridge_provider_extension_version_compare(entry_version, ext.min_version) < 0 {
			entry_state = "outdated"
		}
		if bridge_provider_extension_state_rank(entry_state) > bridge_provider_extension_state_rank(state) {
			state = entry_state
			best_version = entry_version
		}
	}
	return state, strings.clone(best_version, allocator)
}

// bridge_provider_extension_probe runs the detector after a present binary probe.
// It shares the --version circuit-breaker pattern under its own key so a hung
// `plugin list` cannot stall every later discovery.
bridge_provider_extension_probe :: proc(binary_path: string, ext: Bridge_Catalog_Extension, timeout: time.Duration, env: []string = nil, profile_id: string = "") -> (state: string, version: string) {
	if !bridge_provider_extension_supported(ext) do return bridge_provider_extension_evaluate(ext, "", false,env = env)
	if binary_path == "" do return "absent", strings.clone("")
	timeout := min(timeout, BRIDGE_PROVIDER_EXTENSION_TIMEOUT)
	if timeout <= 0 do return bridge_provider_extension_evaluate(ext, "", false,env = env)
	breaker_key := strings.concatenate({"provider-extension-probe:",profile_id,":", binary_path})
	defer delete(breaker_key)
	if !bridge_dependency_breaker_allow(breaker_key) do return bridge_provider_extension_evaluate(ext, "", false,env = env)
	argv := make([]string, len(ext.detect_argv) + 1)
	defer delete(argv)
	argv[0] = binary_path
	copy(argv[1:], ext.detect_argv)
	stdout, stderr, _, ok, _ := bridge_process_run_capture_status_env(argv, timeout,env)
	defer { delete(stdout); delete(stderr) }
	bridge_dependency_breaker_record(breaker_key, ok)
	return bridge_provider_extension_evaluate(ext, stdout, ok,env = env)
}

// With a supplied child environment, never fall back to process-global paths.
// An explicit GEMINI_CONFIG_DIR excludes the bridge HOME's other account.
bridge_extension_gemini_paths :: proc(env: []string, plugin_id: string, manifest: bool) -> []string {
	if env == nil do return nil
	root := profile_env_value(env,"GEMINI_CONFIG_DIR")
	if root == "" {
		home := profile_env_value(env,"HOME")
		when ODIN_OS == .Windows { if home == "" do home = profile_env_value(env,"USERPROFILE") }
		if home != "" do root = profile_join(home,".gemini")
	}
	if root == "" { out := make([]string,1,context.temp_allocator); return out }
	suffix := profile_join(profile_join("plugins",plugin_id),"plugin.json") if manifest else "config.json"
	out := make([]string,2,context.temp_allocator)
	out[0] = profile_join(root,suffix); out[1] = profile_join(profile_join(root,"config"),suffix)
	return out
}
