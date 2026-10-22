package main

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:time"

// REQ-EXT-DET-1: whether a provider's Heimdall extension is installed. The Hub
// catalog owns the descriptor; this file only runs `<binary> <detect_argv...>`
// and reads the JSON collection it prints. Matching is data-driven (`id`, `enabled`,
// `version`, `errors`), so no provider name appears here.
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

// bridge_provider_extension_evaluate turns detector output into a state and an
// owned version string. `ran` is false when the command failed, timed out, or was
// skipped by the circuit breaker. When a plugin is listed more than once (one
// entry per install scope), the most usable entry wins.
bridge_provider_extension_evaluate :: proc(ext: Bridge_Catalog_Extension, output: string, ran: bool, allocator := context.allocator) -> (state: string, version: string) {
	if !bridge_provider_extension_supported(ext) do return "unsupported", strings.clone("", allocator)
	if !ran do return "error", strings.clone("", allocator)
	parsed, parse_err := json.parse_string(output, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_err != nil do return "error", strings.clone("", allocator)
	defer json.destroy_value(parsed, context.temp_allocator)
	collection := parsed
	if ext.detect_collection != "" {
		object, is_object := parsed.(json.Object)
		if !is_object do return "error", strings.clone("", allocator)
		collection = object[ext.detect_collection]
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
		entry_version, _ := object[version_key].(json.String)
		enabled := true
		if value, has := object[enabled_key].(json.Boolean); has do enabled = bool(value)
		has_errors := false
		// A descriptor that requests explicit enabled evidence must receive it.
		if ext.detect_enabled_key != "" {
			_, has_enabled := object[enabled_key].(json.Boolean)
			if !has_enabled do has_errors = true
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
bridge_provider_extension_probe :: proc(binary_path: string, ext: Bridge_Catalog_Extension, timeout: time.Duration) -> (state: string, version: string) {
	if !bridge_provider_extension_supported(ext) do return bridge_provider_extension_evaluate(ext, "", false)
	if binary_path == "" do return "absent", strings.clone("")
	timeout := min(timeout, BRIDGE_PROVIDER_EXTENSION_TIMEOUT)
	if timeout <= 0 do return bridge_provider_extension_evaluate(ext, "", false)
	breaker_key := strings.concatenate({"provider-extension-probe:", binary_path})
	defer delete(breaker_key)
	if !bridge_dependency_breaker_allow(breaker_key) do return bridge_provider_extension_evaluate(ext, "", false)
	argv := make([]string, len(ext.detect_argv) + 1)
	defer delete(argv)
	argv[0] = binary_path
	copy(argv[1:], ext.detect_argv)
	stdout, stderr, ok, _ := bridge_process_run_capture(argv, timeout)
	defer { delete(stdout); delete(stderr) }
	bridge_dependency_breaker_record(breaker_key, ok)
	return bridge_provider_extension_evaluate(ext, stdout, ok)
}
