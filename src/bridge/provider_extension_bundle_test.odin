package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_bridge_get_bundled_extension_path_default :: proc(t: ^testing.T) {
	path := bridge_get_bundled_extension_path("antigravity", context.allocator)
	defer delete(path)
	testing.expect(t, len(path) > 0, "path should not be empty")
	testing.expect(t, bridge_os_dir_exists(path), "path should be a valid directory")
	testing.expect(t, strings.has_suffix(path, "antigravity"), "path should end with antigravity")

	claude_path := bridge_get_bundled_extension_path("claude", context.allocator)
	defer delete(claude_path)
	testing.expect(t, len(claude_path) > 0, "claude path should not be empty")
	testing.expect(t, bridge_os_dir_exists(claude_path), "claude path should be a valid directory")

	codex_path := bridge_get_bundled_extension_path("codex", context.allocator)
	defer delete(codex_path)
	testing.expect(t, len(codex_path) > 0, "codex path should not be empty")
	testing.expect(t, bridge_os_dir_exists(codex_path), "codex path should be a valid directory")

	base_path := bridge_get_bundled_extension_path("", context.allocator)
	defer delete(base_path)
	testing.expect(t, len(base_path) > 0, "base extensions dir should not be empty")
	testing.expect(t, bridge_os_dir_exists(base_path), "base extensions dir should exist")
}

@(test)
test_bridge_get_bundled_extension_path_env_override :: proc(t: ^testing.T) {
	root := bridge_scratch_root(context.temp_allocator)
	test_dir := fmt.aprintf("%s/test_bridge_ext_%d", root, time.to_unix_nanoseconds(time.now()))
	defer {
		_ = os.remove_all(test_dir)
		delete(test_dir)
	}
	custom_antigravity, _ := filepath.join({test_dir, "extensions", "antigravity"}, context.temp_allocator)
	testing.expect(t, bridge_make_directory_all(custom_antigravity) == nil, "mkdir custom antigravity")

	saved_env, has_env := os.lookup_env("HEIMDALL_BRIDGE_DATA_DIR", context.allocator)
	defer {
		if has_env {
			_ = os.set_env("HEIMDALL_BRIDGE_DATA_DIR", saved_env)
			delete(saved_env)
		} else {
			_ = os.unset_env("HEIMDALL_BRIDGE_DATA_DIR")
		}
	}

	_ = os.set_env("HEIMDALL_BRIDGE_DATA_DIR", test_dir)
	resolved := bridge_get_bundled_extension_path("antigravity", context.allocator)
	defer delete(resolved)

	testing.expect(t, len(resolved) > 0, "resolved path should not be empty")
	testing.expect(t, bridge_os_dir_exists(resolved), "resolved path must be a valid directory")
	testing.expect(t, strings.contains(resolved, test_dir), "resolved path should point to custom env directory")
	testing.expect(t, strings.has_suffix(resolved, "antigravity"), "resolved path should end with antigravity")
}

@(test)
test_bridge_get_bundled_extension_path_nonexistent :: proc(t: ^testing.T) {
	path := bridge_get_bundled_extension_path("nonexistent_provider_xyz_123", context.allocator)
	defer delete(path)
	testing.expect_value(t, path, "")
}

@(test)
test_bridge_get_bundled_extensions_dir :: proc(t: ^testing.T) {
	dir := bridge_get_bundled_extensions_dir(context.allocator)
	defer delete(dir)
	testing.expect(t, len(dir) > 0, "extensions dir should not be empty")
	testing.expect(t, bridge_os_dir_exists(dir), "extensions dir must exist")
}
