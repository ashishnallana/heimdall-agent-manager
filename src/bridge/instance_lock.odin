package main

import "core:crypto/hash"
import "core:os"
import "core:strings"
import cfg_lib "odin_test:lib/config"
import vault "odin_test:lib/vault"

// ===== Instance locks =====
//
// One running bridge (or enrollment) per config file and per (hub, bridge id) scope.
// The lock files live in their own directory, ~/.config/heimdall/locks/, which no
// keystore purge, enrollment rollback or scope cleanup touches, so a held lock is
// never unlinked under its holder (which would let a second instance lock a new file
// of the same name). A config lock is keyed by the CANONICAL absolute path of the
// config (realpath / GetFinalPathNameByHandleW), so "config.toml", "./config.toml",
// an absolute spelling or a symlink to it all take the same lock.

BRIDGE_LOCKS_DIR :: "~/.config/heimdall/locks/"

// bridge_canonical_file_path is the canonical absolute path of `path`. The file
// need not exist; its directory must (it is created, as enrollment would). Temp-allocated.
bridge_canonical_file_path :: proc(path: string) -> (string, bool) {
	p := strings.trim_space(path)
	if p == "" do return "", false
	if os.exists(p) do return bridge_os_real_path(p)
	slash := max(strings.last_index_byte(p, '/'), strings.last_index_byte(p, '\\'))
	dir, base := ".", p
	if slash >= 0 {
		dir, base = p[:slash], p[slash + 1:]
		if dir == "" do dir = "/"
	}
	if base == "" || base == "." || base == ".." do return "", false
	_ = bridge_make_directory_all(dir)
	real_dir, ok := bridge_os_real_path(dir)
	if !ok do return "", false
	when ODIN_OS == .Windows do base = strings.to_lower(base, context.temp_allocator)
	return strings.concatenate({strings.trim_right(real_dir, "/"), "/", base}, context.temp_allocator), true
}

// bridge_named_lock_path is the lock file for (kind, key) in the locks directory.
@(private = "file")
bridge_named_lock_path :: proc(kind, key: string) -> (string, bool) {
	dir := cfg_lib.expand_home(BRIDGE_LOCKS_DIR)
	defer delete(dir)
	if strings.has_prefix(dir, "~") do return "", false
	_ = bridge_make_directory_all(dir)
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, strings.concatenate({"heimdall-bridge-lock/v1|", kind, "|", key}, context.temp_allocator), digest[:])
	return strings.concatenate({dir, kind, "-", vault.hex_encode_lower(digest[:16], context.temp_allocator), ".lock"}, context.temp_allocator), true
}

// bridge_config_lock locks the canonical config path. Returns the lock file path
// (for bridge_instance_unlock) and false when another instance holds it or the path
// cannot be resolved (fail closed).
bridge_config_lock :: proc(config_path: string) -> (lock_path: string, ok: bool) {
	canonical, c_ok := bridge_canonical_file_path(config_path)
	if !c_ok do return "", false
	lock_path, ok = bridge_named_lock_path("config", canonical)
	if !ok do return "", false
	return lock_path, bridge_instance_lock(lock_path)
}

// bridge_scope_lock locks a (hub, bridge id) scope (keystore_scope_name).
bridge_scope_lock :: proc(scope_name: string) -> bool {
	lock_path, ok := bridge_named_lock_path("scope", scope_name)
	return ok && bridge_instance_lock(lock_path)
}
