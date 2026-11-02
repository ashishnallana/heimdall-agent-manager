package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import cfg_lib "odin_test:lib/config"

// bridge_get_bundled_extensions_dir resolves the base directory containing bundled extensions.
// It checks in priority order:
// 1. $HEIMDALL_BRIDGE_DATA_DIR/extensions (or $BRIDGE_DATA_DIR/extensions)
// 2. bridge_config.data_dir/extensions
// 3. Executable-relative share directory (<exe_parent>/share/heimdall/extensions, etc.)
// 4. Standard installation share directories (~/.local/share/heimdall/extensions, /usr/share/heimdall/extensions)
// 5. Development/source checkout relative directory (extensions/, ../extensions/)
bridge_get_bundled_extensions_dir :: proc(allocator := context.allocator) -> string {
	candidates := bridge_bundled_extension_base_candidates(context.temp_allocator)
	for base in candidates {
		if base != "" && bridge_os_dir_exists(base) {
			return bridge_clean_abs_path(base, allocator)
		}
	}
	return strings.clone("", allocator)
}

// bridge_get_bundled_extension_path resolves the directory of a specific bundled extension.
// When provider is empty, it returns the base bundled extensions directory.
// When provider is specified (e.g. "antigravity", "claude", "codex"), it returns the valid directory
// path for that provider's extension, or an empty string if not found.
bridge_get_bundled_extension_path :: proc(provider: string = "", allocator := context.allocator) -> string {
	prov := strings.trim_space(provider)
	if prov == "" {
		return bridge_get_bundled_extensions_dir(allocator)
	}

	candidates := bridge_bundled_extension_base_candidates(context.temp_allocator)
	for base in candidates {
		if base == "" do continue

		// Direct provider check if base itself matches provider
		if strings.has_suffix(strings.trim_right(base, "/\\"), prov) && bridge_os_dir_exists(base) {
			return bridge_clean_abs_path(base, allocator)
		}

		variants := bridge_provider_directory_variants(prov, context.temp_allocator)
		for variant in variants {
			candidate_path := path_join({base, variant}, context.temp_allocator)
			if bridge_os_dir_exists(candidate_path) {
				return bridge_clean_abs_path(candidate_path, allocator)
			}
		}
	}

	return strings.clone("", allocator)
}

@(private="file")
path_join :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	res, _ := filepath.join(elems, allocator)
	return res
}

@(private="file")
expand_home_temp :: proc(path: string, allocator := context.temp_allocator) -> string {
	if strings.has_prefix(path, "~/") {
		home := cfg_lib.home_dir()
		defer delete(home)
		if home != "" do return strings.concatenate({home, path[1:]}, allocator)
	}
	return path
}

@(private="file")
bridge_provider_directory_variants :: proc(provider: string, allocator := context.allocator) -> []string {
	variants := make([dynamic]string, allocator)
	append(&variants, provider)
	if provider == "claude" {
		append(&variants, "claude-code")
	} else if provider == "claude-code" {
		append(&variants, "claude")
	}
	return variants[:]
}

// bridge_get_profile_extension_path resolves a provider's extension for a
// per-account provider profile: this profile's own <data_dir>/extensions copy,
// else the general resolver. A provider profile's config dir belongs to this
// profile alone, and the own copy keeps one path across updates, whereas any
// profile's update may prune an older shared release.
bridge_get_profile_extension_path :: proc(provider: string, allocator := context.allocator) -> string {
	prov := strings.trim_space(provider)
	if data_dir := strings.trim_space(bridge_config.data_dir); data_dir != "" && prov != "" {
		base := path_join({expand_home_temp(data_dir, context.temp_allocator), "extensions"}, context.temp_allocator)
		for variant in bridge_provider_directory_variants(prov, context.temp_allocator) {
			candidate_path := path_join({base, variant}, context.temp_allocator)
			if bridge_os_dir_exists(candidate_path) do return bridge_clean_abs_path(candidate_path, allocator)
		}
	}
	return bridge_extension_bundle_resolver(provider, allocator)
}

@(private="file")
bridge_bundled_extension_base_candidates :: proc(allocator := context.allocator) -> []string {
	candidates := make([dynamic]string, allocator)

	// 1. $HEIMDALL_BRIDGE_DATA_DIR / $BRIDGE_DATA_DIR
	if env_dir := strings.trim_space(os.get_env("HEIMDALL_BRIDGE_DATA_DIR", context.temp_allocator)); env_dir != "" {
		expanded := expand_home_temp(env_dir, allocator)
		append(&candidates, path_join({expanded, "extensions"}, allocator))
		if strings.has_suffix(strings.trim_right(expanded, "/\\"), "extensions") {
			append(&candidates, strings.clone(expanded, allocator))
		}
	}
	if env_dir := strings.trim_space(os.get_env("BRIDGE_DATA_DIR", context.temp_allocator)); env_dir != "" {
		expanded := expand_home_temp(env_dir, allocator)
		append(&candidates, path_join({expanded, "extensions"}, allocator))
		if strings.has_suffix(strings.trim_right(expanded, "/\\"), "extensions") {
			append(&candidates, strings.clone(expanded, allocator))
		}
	}

	// 2. bridge_config.data_dir: the newest shared release every profile of this
	// OS user registers from, then the profile's own copy.
	if data_dir := strings.trim_space(bridge_config.data_dir); data_dir != "" {
		expanded := expand_home_temp(data_dir, allocator)
		if shared := bridge_extensions_newest_shared(bridge_extensions_shared_root(expanded)); shared != "" {
			append(&candidates, strings.clone(shared, allocator))
		}
		append(&candidates, path_join({expanded, "extensions"}, allocator))
	}

	// 3. Executable-relative share directory. args[0] is a bare name when the
	// bridge was started through PATH, so prefer the resolved executable.
	exe, _ := os.get_executable_path(context.temp_allocator)
	if exe == "" && len(os.args) > 0 do exe = os.args[0]
	if exe != "" {
		slash := max(strings.last_index_byte(exe, '/'), strings.last_index_byte(exe, '\\'))
		exe_dir := exe[:slash] if slash > 0 else "."
		slash_parent := max(strings.last_index_byte(exe_dir, '/'), strings.last_index_byte(exe_dir, '\\'))
		exe_parent := exe_dir[:slash_parent] if slash_parent > 0 else ""

		if exe_parent != "" {
			append(&candidates, path_join({exe_parent, "share", "heimdall", "extensions"}, allocator))
			append(&candidates, path_join({exe_parent, "share", "extensions"}, allocator))
			append(&candidates, path_join({exe_parent, "extensions"}, allocator))
		}
		append(&candidates, path_join({exe_dir, "extensions"}, allocator))
		append(&candidates, path_join({exe_dir, "share", "heimdall", "extensions"}, allocator))
		append(&candidates, path_join({exe_dir, "share", "extensions"}, allocator))
	}

	// 4. Standard installation directories (F11). An installed bridge runs with
	// --data-dir <profile data dir>, so step 2 normally finds the copy
	// `ham-bridge setup` / `extensions sync` put there; these are the shared
	// per-OS roots for bridges started by hand.
	user_local := expand_home_temp("~/.local/share/heimdall", allocator)
	append(&candidates, path_join({user_local, "extensions"}, allocator))
	append(&candidates, path_join({user_local, "share", "extensions"}, allocator))
	when ODIN_OS == .Darwin {
		append(&candidates, expand_home_temp("~/Library/Application Support/heimdall/extensions", allocator))
	}
	when ODIN_OS == .Windows {
		if local := strings.trim_space(os.get_env("LOCALAPPDATA", context.temp_allocator)); local != "" {
			append(&candidates, path_join({local, "heimdall", "extensions"}, allocator))
		}
	}
	when ODIN_OS != .Windows {
		append(&candidates, strings.clone("/usr/local/share/heimdall/extensions", allocator))
		append(&candidates, strings.clone("/usr/share/heimdall/extensions", allocator))
	}

	// 5. Working directory / source checkout fallbacks
	append(&candidates, strings.clone("extensions", allocator))
	append(&candidates, strings.clone("../extensions", allocator))
	append(&candidates, strings.clone("../../extensions", allocator))

	return candidates[:]
}

@(private="file")
bridge_clean_abs_path :: proc(p: string, allocator := context.allocator) -> string {
	if p == "" do return strings.clone("", allocator)
	abs_path, err := filepath.abs(p, context.temp_allocator)
	base := abs_path if err == nil else p
	cleaned, cerr := filepath.clean(base, context.temp_allocator)
	res := cleaned if cerr == nil else base
	return strings.clone(res, allocator)
}
