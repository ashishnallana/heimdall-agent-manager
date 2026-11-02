package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

profile_effective_id :: proc(provider, id: string) -> string {
	return id if id != "" else provider
}

profile_env_value :: proc(env: []string, name: string) -> string {
	for entry in env {
		eq := strings.index_byte(entry, '=')
		if eq >= 0 && profile_env_name_equal(entry[:eq], name) do return entry[eq + 1:]
	}
	return ""
}

profile_child_env :: proc(p: ^Provider_Profile) -> (env: []string, ok: bool) {
	base, err := os.environ(context.temp_allocator)
	if err != nil do return nil, false
	return profile_apply_env_plan(base, profile_env_plan(p)), true
}

// Resolve binaries against the child's PATH, without changing process-global env.
profile_resolve_binary :: proc(binary: string, env: []string) -> string {
	if strings.contains_any(binary, "/\\") {
		if bridge_provider_path_executable(binary) do return strings.clone(binary)
		return ""
	}
	separator := ":"
	when ODIN_OS == .Windows {separator = ";"}
	for dir in strings.split(profile_env_value(env, "PATH"), separator, context.temp_allocator) {
		if dir == "" do continue
		for name in bridge_os_executable_names(binary) {
			path, _ := filepath.join({dir, name}, context.temp_allocator)
			if bridge_provider_path_executable(path) {
				absolute, err := os.get_absolute_path(path, context.temp_allocator)
				if err == nil do return strings.clone(absolute)
			}
		}
	}
	return ""
}

profile_runtime_configured :: proc(p: ^Provider_Profile) -> bool {
	c := &p.config
	return(
		p.profile_id != p.provider ||
		len(p.environment) > 0 ||
		c.binary_path != "" ||
		c.config_dir != "" ||
		c.home_path != "" ||
		c.shadow_home_path != "" ||
		c.launch_args != "" ||
		len(c.custom_models) > 0 ||
		c.auth_method != "" ||
		c.api_key != "" ||
		c.gcp_project != "" ||
		c.gcp_location != "" \
	)
}

profile_join :: proc(a, b: string) -> string {
	path, _ := filepath.join({a, b}, context.temp_allocator)
	return path
}

PROFILE_CODEX_SHARED_DIRS := [?]string {
	"sessions",
	"archived_sessions",
	"sqlite",
	"shell_snapshots",
	"worktrees",
	"skills",
	"plugins",
	"cache",
	"logs",
	"mcp-oauth-locks",
	"thread-writer-locks",
}
PROFILE_CODEX_PRIVATE := [?]string{"auth.json", "auth.lock", "models_cache.json"}
PROFILE_CODEX_LOCAL := [?]string{"log", "memories", "tmp", ".DS_Store"}

profile_codex_shared_link :: proc(shared, shadow, name: string) -> bool {
	context.allocator = context.temp_allocator
	target, link := profile_join(shared, name), profile_join(shadow, name)
	info, err := os.lstat(link, context.temp_allocator)
	if err == nil {
		if info.type == .Symlink {
			existing, rerr := os.read_link(link, context.temp_allocator)
			if rerr != nil do return false
			if !filepath.is_abs(existing) do existing = profile_join(shadow, existing)
			existing = profile_normalize_path(existing)
			if profile_env_name_equal(existing, target) do return true
			if os.remove(link) != nil do return false
		} else {
			// t3code only replaces these local locks guarding shared state.
			if name != "mcp-oauth-locks" && name != "thread-writer-locks" && name != ".sqlite-maintenance.lock" do return false
			if name == "thread-writer-locks" {
				entries, rerr := os.read_directory_by_path(link, -1, context.temp_allocator)
				if rerr != nil do return false
				for entry in entries {
					if strings.has_suffix(entry.name, ".lock") && entry.name != ".coordination.lock" do return true
				}
			}
			if info.type == .Directory {
				if os.remove_all(link) != nil do return false
			} else if os.remove(link) != nil {return false}
		}
	} else if err != .Not_Exist {return false}
	return os.symlink(target, link) == nil
}

// Codex auth overlay follows t3code CodexHomeLayout: private auth never links;
// shared runtime dirs/files link into home_path, shadow-local files stay local.
profile_prepare_runtime :: proc(p: ^Provider_Profile) -> Profile_Error {
	context.allocator = context.temp_allocator
	if p.provider != "codex" || p.config.shadow_home_path == "" do return .None
	shared := p.config.home_path
	if shared == "" do shared = profile_normalize_path("~/.codex")
	shadow := p.config.shadow_home_path
	// Canonicalize existing parents as well, so aliases cannot share auth.
	shared = bridge_fs_canonicalize_existing(shared)
	shadow = bridge_fs_canonicalize_existing(shadow)
	shared_cmp, shadow_cmp := shared, shadow
	when ODIN_OS == .Windows {
		shared_cmp, _ = strings.replace_all(
			strings.to_lower(shared, context.temp_allocator),
			"\\",
			"/",
			context.temp_allocator,
		)
		shadow_cmp, _ = strings.replace_all(
			strings.to_lower(shadow, context.temp_allocator),
			"\\",
			"/",
			context.temp_allocator,
		)
	}
	if shared_cmp == shadow_cmp ||
	   strings.has_prefix(
		   shadow_cmp,
		   strings.concatenate({shared_cmp, "/"}, context.temp_allocator),
	   ) ||
	   strings.has_prefix(
		   shared_cmp,
		   strings.concatenate({shadow_cmp, "/"}, context.temp_allocator),
	   ) {return .Shadow_Home_Invalid}
	for dir in ([]string{shared, shadow}) {
		if err := bridge_make_directory_all(dir); err != nil && !os.is_dir(dir) do return .Shadow_Home_Invalid
	}
	when ODIN_OS != .Windows {
		if os.chmod(shadow, {.Read_User, .Write_User, .Execute_User}) != nil do return .Shadow_Home_Invalid
	}
	// Refuse a pre-existing auth symlink before changing anything else.
	if auth, err := os.lstat(profile_join(shadow, "auth.json"), context.temp_allocator);
	   err == nil {
		if auth.type == .Symlink do return .Shadow_Home_Invalid
	} else if err != .Not_Exist {return .Shadow_Home_Invalid}
	for dir in PROFILE_CODEX_SHARED_DIRS {
		path := profile_join(shared, dir)
		if err := bridge_make_directory_all(path); err != nil && !os.is_dir(path) do return .Shadow_Home_Invalid
	}
	// Remove legacy shared auth.lock/models_cache links, preserving local files.
	for name in PROFILE_CODEX_PRIVATE {
		if name == "auth.json" do continue
		path := profile_join(shadow, name)
		if info, err := os.lstat(path, context.temp_allocator); err == nil {
			if info.type == .Symlink && os.remove(path) != nil do return .Shadow_Home_Invalid
		} else if err != .Not_Exist {return .Shadow_Home_Invalid}
	}
	entries, err := os.read_directory_by_path(shared, -1, context.temp_allocator)
	if err != nil do return .Shadow_Home_Invalid
	for entry in entries {
		if slice.contains(PROFILE_CODEX_PRIVATE[:], entry.name) || slice.contains(PROFILE_CODEX_LOCAL[:], entry.name) do continue
		if !profile_codex_shared_link(shared, shadow, entry.name) do return .Shadow_Home_Invalid
	}
	return .None
}

profile_has_model :: proc(p: ^Provider_Profile, provider, model: string) -> bool {
	if slice.contains(p.config.custom_models, model) do return true
	observed := bridge_models_get(provider, profile_id = p.profile_id)
	defer bridge_models_destroy(&observed)
	if observed.has_snapshot {
		for m in observed.models do if m.model_id == model do return true
		return false
	}
	// A new custom profile may use catalog seeds, but must not borrow the
	// default profile's account-specific discovered snapshot.
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return false
	for entry in bridge_provider_catalog_snapshot.providers {
		if entry.provider != provider || entry.state != "active" do continue
		for m in entry.models do if m.model_id == model && m.state == "active" do return true
	}
	return false
}

// Provider diagnostics can echo credentials. Only known secret values are
// redacted; non-sensitive config and environment retain their normal text.
profile_redact_text :: proc(text: string, p: ^Provider_Profile) -> string {
	if p == nil do return text
	out := text
	for e in p.environment {
		if e.sensitive && e.value != "" {
			out, _ = strings.replace_all(out, e.value, "[redacted]", context.temp_allocator)
		}
	}
	if p.config.api_key != "" do out, _ = strings.replace_all(out, p.config.api_key, "[redacted]", context.temp_allocator)
	return out
}

profile_provider_name :: proc(profile_id: string) -> string {
	profiles, err := profile_list(context.temp_allocator)
	if err != .None do return ""
	for p in profiles do if p.profile_id == profile_id do return p.provider
	if profile_catalog_has(profile_id) do return profile_id
	return ""
}
