#+build linux
package main

// T7: the Android/Termux keystore backend, exercised on a Linux host through a
// FAKE `termux-keystore` (sh + openssl) on PATH. Every test runs inside
// bridge_vault_test_sandbox_open (temp HOME), uses the `brg_test_` ids
// (keystore_test_bridge_ids) and selects the backend only on its own thread
// (keystore_android_test_force), so no test reaches a real bridge's key, file or
// @u entry. Locks: bridge_test_config_mutex (HOME/PATH are process-global), then
// keystore_test_mutex (the in-memory key buffer is shared).

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"

// The shim keeps one RSA-2048 PEM per alias in its own directory. `mode` in that
// directory picks the sign output: raw (default), base64, short (a truncated
// signature), fail (exit 1 with the key present) or flip (alternates between the
// alias's key and a second key: valid signatures that are not deterministic). `listmode` broken makes
// `list` print non-JSON. Every invocation's argv is appended to argv.log so tests
// can count calls and prove the label never travels on the command line.
@(private = "file")
KEYSTORE_ANDROID_SHIM :: `#!/bin/sh
d="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$d/argv.log"
cmd="$1"; alias="$2"
pem="$d/keys/$alias.pem"
case "$cmd" in
generate)
	mkdir -p "$d/keys"
	openssl genrsa -out "$pem" 2048 2>/dev/null || exit 1 ;;
sign)
	[ "$3" = "SHA256withRSA" ] || { echo "unsupported algorithm $3" >&2; exit 2; }
	[ -f "$pem" ] || { echo "no key with alias $alias" >&2; exit 1; }
	mode="$(cat "$d/mode" 2>/dev/null || echo raw)"
	case "$mode" in
	base64) openssl dgst -sha256 -sign "$pem" | base64 -w 76; echo ;;
	short) openssl dgst -sha256 -sign "$pem" | head -c 128 ;;
	fail) echo "keystore busy" >&2; exit 1 ;;
	flip)
		n="$(cat "$d/flipcount" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$d/flipcount"
		if [ $((n % 2)) = 1 ]; then
			[ -f "$d/alt.pem" ] || openssl genrsa -out "$d/alt.pem" 2048 2>/dev/null
			openssl dgst -sha256 -sign "$d/alt.pem"
		else
			openssl dgst -sha256 -sign "$pem"
		fi ;;
	*) openssl dgst -sha256 -sign "$pem" ;;
	esac ;;
delete)
	rm -f "$pem" ;;
list)
	if [ "$(cat "$d/listmode" 2>/dev/null)" = broken ]; then echo "Termux:API error"; exit 0; fi
	sep=""; printf '['
	for k in "$d"/keys/*.pem; do
		[ -f "$k" ] || continue
		a="$(basename "$k" .pem)"
		printf '%s{"alias": "%s", "algorithm": "RSA", "size": 2048}' "$sep" "$a"; sep=", "
	done
	printf ']\n' ;;
*)
	echo "usage" >&2; exit 2 ;;
esac
`

@(private = "file")
Android_Fixture :: struct {
	sb:             Bridge_Vault_Test_Sandbox,
	shim_dir:       string,
	prev_path:      string,
	had_path:       bool,
	path_set:       bool,
	prev_daemon_id: string,
	id_a, id_b:     string,
}

// Opens the sandbox, selects the android backend on this thread and, with
// install_shim, puts the fake termux-keystore first on PATH. Caller holds both
// mutexes and must call fixture_close on every path.
@(private = "file")
fixture_open :: proc(t: ^testing.T, label: string, install_shim: bool) -> (f: Android_Fixture, ok: bool) {
	f.id_a, f.id_b = keystore_test_bridge_ids()
	f.prev_daemon_id = keystore_test_set_daemon_id(f.id_a)
	f.sb, ok = bridge_vault_test_sandbox_open(t, label)
	if !ok do return
	keystore_android_test_force = true
	keystore_wipe_in_memory_vault_key()

	f.shim_dir = fmt.aprintf("%s/shim", f.sb.dir)
	if !install_shim do return f, true
	if os.make_directory_all(f.shim_dir) != nil {
		testing.expect(t, false, "shim dir created")
		return f, false
	}
	shim_path := fmt.tprintf("%s/%s", f.shim_dir, KEYSTORE_ANDROID_TOOL)
	if os.write_entire_file(shim_path, KEYSTORE_ANDROID_SHIM, {.Read_User, .Write_User, .Execute_User}) != nil {
		testing.expect(t, false, "shim written")
		return f, false
	}
	f.prev_path, f.had_path = os.lookup_env("PATH", context.allocator)
	f.path_set = true
	if os.set_env("PATH", fmt.tprintf("%s:%s", f.shim_dir, f.prev_path)) != nil {
		testing.expect(t, false, "PATH redirected to the shim")
		return f, false
	}
	return f, true
}

@(private = "file")
fixture_close :: proc(f: ^Android_Fixture) {
	keystore_wipe_in_memory_vault_key()
	keystore_android_test_force = false
	if f.path_set {
		if f.had_path { _ = os.set_env("PATH", f.prev_path); delete(f.prev_path) } else { os.unset_env("PATH") }
	}
	delete(f.shim_dir)
	bridge_vault_test_sandbox_close(&f.sb)
	bridge_config.daemon_id = f.prev_daemon_id
}

@(private = "file")
shim_set_mode :: proc(f: ^Android_Fixture, mode: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/mode", f.shim_dir), mode)
}

@(private = "file")
shim_set_listmode :: proc(f: ^Android_Fixture, mode: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/listmode", f.shim_dir), mode)
}

// How many times the shim has been run with subcommand cmd so far.
@(private = "file")
shim_calls :: proc(f: ^Android_Fixture, cmd: string) -> int {
	log, err := os.read_entire_file(fmt.tprintf("%s/argv.log", f.shim_dir), context.allocator)
	if err != nil do return 0
	defer delete(log)
	n := 0
	rest := string(log)
	for line in strings.split_lines_iterator(&rest) {
		if line == cmd || strings.has_prefix(line, fmt.tprintf("%s ", cmd)) do n += 1
	}
	return n
}

@(private = "file")
shim_has_key :: proc(f: ^Android_Fixture, bridge_id: string) -> bool {
	return os.exists(fmt.tprintf("%s/keys/%s%s.pem", f.shim_dir, KEYSTORE_ANDROID_ALIAS_PREFIX, bridge_id))
}

@(private = "file")
expect_read :: proc(t: ^testing.T, bridge_id, want: string, loc := #caller_location) {
	got, ok := keystore_read_keyring_vault_key(bridge_id)
	defer delete(got)
	testing.expect(t, ok, "sealed key reads back", loc = loc)
	testing.expect_value(t, got, want, loc = loc)
}

@(test)
test_keystore_android_env_selection :: proc(t: ^testing.T) {
	testing.expect(t, keystore_android_env_says_termux("0.118.1", ""), "TERMUX_VERSION selects android")
	testing.expect(t, keystore_android_env_says_termux("", "/data/data/com.termux/files/usr"), "Termux $PREFIX selects android")
	testing.expect(t, !keystore_android_env_says_termux("", ""), "plain Linux keeps the keyring backend")
	testing.expect(t, !keystore_android_env_says_termux("  ", "/usr"), "blank TERMUX_VERSION and a desktop $PREFIX keep the keyring backend")
	testing.expect(t, !keystore_android_env_says_termux("", "/data/data/com.termuxevil/files/usr"), "a look-alike package dir is not Termux")
}

@(test)
test_keystore_android_store_read_purge_round_trip :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-roundtrip", true)
	defer fixture_close(&f)
	if !ok do return

	stored, code := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "store succeeds through the shim")
	testing.expect_value(t, code, 0)
	testing.expect(t, shim_has_key(&f, f.id_a), "first store generated the per-bridge Keystore key")

	path, _ := keystore_android_sealed_path(f.id_a)
	testing.expect(t, strings.has_prefix(path, f.sb.dir), "sealed file lives in the sandbox HOME")
	testing.expect(t, strings.has_suffix(path, fmt.tprintf("/.config/heimdall/bridges/%s/vault_key.sealed", f.id_a)), "sealed file path is per bridge")
	fi, stat_err := os.stat(path, context.allocator)
	testing.expect(t, stat_err == nil, "sealed file exists")
	testing.expect_value(t, fi.mode & os.Permissions_All, os.Permissions{.Read_User, .Write_User})
	os.file_info_delete(fi, context.allocator)
	data, _ := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, len(data), KEYSTORE_ANDROID_SEALED_LEN)
	testing.expect(t, strings.has_prefix(string(data), KEYSTORE_ANDROID_SEALED_MAGIC), "versioned header")
	testing.expect(t, !strings.contains(string(data), KEYSTORE_SEC_TEST_KEY_1[:16]), "no plaintext key material on disk")
	delete(data)
	testing.expect(t, keystore_persisted_vault_item_present(f.id_a), "sealed file counts as a persisted item")

	// A restarted process has only the sealed file: read must go through the Keystore.
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)

	// A second store reuses the existing Keystore key (no regeneration).
	argv_log, _ := os.read_entire_file(fmt.tprintf("%s/argv.log", f.shim_dir), context.allocator)
	gens_before := strings.count(string(argv_log), "generate ")
	delete(argv_log)
	stored, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, stored, "re-store succeeds")
	argv_log, _ = os.read_entire_file(fmt.tprintf("%s/argv.log", f.shim_dir), context.allocator)
	testing.expect_value(t, strings.count(string(argv_log), "generate "), gens_before)
	testing.expect(t, !strings.contains(string(argv_log), KEYSTORE_ANDROID_LABEL_PREFIX), "the label never travels on argv")
	delete(argv_log)
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_2)

	keystore_lock_and_purge(f.id_a)
	testing.expect(t, !os.exists(path), "lock deletes the sealed file")
	testing.expect(t, !keystore_persisted_vault_item_present(f.id_a), "nothing persisted after lock")
	_, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !mem_ok, "lock wipes the in-memory key")
	_, read_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !read_ok, "nothing to read after lock")
	testing.expect(t, shim_has_key(&f, f.id_a), "lock keeps the Keystore key for the next unseal")
}

@(test)
test_keystore_android_base64_signature_accepted :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-b64", true)
	defer fixture_close(&f)
	if !ok do return

	shim_set_mode(&f, "base64")
	stored, _ := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "store accepts a base64 signature")
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)

	// raw and base64 carry the same signature, so they derive the same KEK.
	shim_set_mode(&f, "raw")
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	keystore_lock_and_purge(f.id_a)
}

@(test)
test_keystore_android_bad_signature_fails_closed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-badsig", true)
	defer fixture_close(&f)
	if !ok do return

	// Wrong length: store refuses and persists nothing.
	shim_set_mode(&f, "short")
	stored, code := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, !stored, "a truncated signature fails the store")
	testing.expect_value(t, code, KEYSTORE_ERR_ANDROID_TOOL)
	testing.expect(t, !keystore_persisted_vault_item_present(f.id_a), "no sealed file after a failed store")
	_, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !mem_ok, "a failed store keeps nothing in memory either")

	// Different Keystore key (wrong signature): the sealed file no longer opens.
	shim_set_mode(&f, "raw")
	stored, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "store succeeds once signatures are well formed")
	keystore_wipe_in_memory_vault_key()
	alias, _ := keystore_android_alias(f.id_a)
	_ = os.remove(fmt.tprintf("%s/keys/%s.pem", f.shim_dir, alias))
	testing.expect(t, keystore_android_test_run_generate(alias), "Keystore key regenerated")
	_, read_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !read_ok, "a different Keystore key reads as not found")
	testing.expect(t, keystore_persisted_vault_item_present(f.id_a), "the sealed file still marks the vault configured (reports locked)")

	// Short signature on read: also not found.
	shim_set_mode(&f, "short")
	_, read_ok = keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !read_ok, "a truncated signature on read is not found")
	keystore_lock_and_purge(f.id_a)
}

// Regenerates alias's key through the shim, as the device would after a
// Keystore wipe.
@(private = "file")
keystore_android_test_run_generate :: proc(alias: string) -> bool {
	stdout, stderr, ok, _ := bridge_process_run_capture({KEYSTORE_ANDROID_TOOL, "generate", alias, "-a", "RSA", "-s", "2048"}, KEYSTORE_ANDROID_TOOL_TIMEOUT)
	delete(stdout)
	delete(stderr)
	return ok
}

@(test)
test_keystore_android_missing_tool_fails_closed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-notool", false)
	defer fixture_close(&f)
	if !ok do return

	// This host has no termux-keystore; without the shim the backend must refuse.
	if keystore_android_test_run_generate("heimdall-bridge-probe") {
		testing.expect(t, false, "a real termux-keystore is on PATH; this test needs it absent")
		return
	}
	stored, code := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, !stored, "store fails closed without termux-keystore")
	testing.expect_value(t, code, KEYSTORE_ERR_ANDROID_TOOL)
	path, _ := keystore_android_sealed_path(f.id_a)
	testing.expect(t, !os.exists(path), "no sealed file written")
	plain := fmt.tprintf("%s/.config/heimdall/bridges/%s/vault_key", f.sb.dir, f.id_a)
	testing.expect(t, !os.exists(plain), "no plaintext fallback file")
	_, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !mem_ok, "no in-memory fallback")
	_, read_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !read_ok, "read reports not found")

	// The android backend never touched @u: with the keyring backend back on this
	// thread, the id has no keyring entry either.
	keystore_android_test_force = false
	_, ring_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !ring_ok, "nothing was stored in the kernel keyring")
}

@(test)
test_keystore_android_per_bridge_isolation_and_reset :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-isolation", true)
	defer fixture_close(&f)
	if !ok do return

	ok_a, _ := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	ok_b, _ := keystore_store_vault_key(f.id_b, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, ok_a && ok_b, "both bridges store")
	testing.expect(t, shim_has_key(&f, f.id_a) && shim_has_key(&f, f.id_b), "one Keystore alias per bridge")
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	expect_read(t, f.id_b, KEYSTORE_SEC_TEST_KEY_2)

	// A's sealed file copied over B's does not open as B (AAD + per-bridge KEK).
	path_a, _ := keystore_android_sealed_path(f.id_a)
	path_b, _ := keystore_android_sealed_path(f.id_b)
	path_a = strings.clone(path_a)
	path_b = strings.clone(path_b)
	defer { delete(path_a); delete(path_b) }
	saved_b, _ := os.read_entire_file(path_b, context.allocator)
	defer delete(saved_b)
	_ = os.copy_file(path_b, path_a)
	keystore_wipe_in_memory_vault_key() // as after a restart: only the file is left
	swapped, swapped_ok := keystore_read_keyring_vault_key(f.id_b)
	delete(swapped)
	testing.expect(t, !swapped_ok, "another bridge's sealed file does not open")
	_ = os.write_entire_file(path_b, saved_b, {.Read_User, .Write_User})
	expect_read(t, f.id_b, KEYSTORE_SEC_TEST_KEY_2)

	// Locking A leaves B untouched.
	keystore_lock_and_purge(f.id_a)
	testing.expect(t, !os.exists(path_a), "A's sealed file removed")
	expect_read(t, f.id_b, KEYSTORE_SEC_TEST_KEY_2)

	// vault.reset on A also deletes A's Keystore key, never B's.
	ok_a, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, ok_a, "A re-stores")
	bridge_config.daemon_id = f.id_a
	saved_flag := bridge_workspace_vault_configured
	defer bridge_workspace_vault_configured = saved_flag
	testing.expect(t, bridge_vault_reset(), "vault.reset succeeds")
	testing.expect(t, !shim_has_key(&f, f.id_a), "reset deleted A's Keystore key")
	testing.expect(t, !os.exists(path_a), "reset removed A's sealed file")
	testing.expect(t, shim_has_key(&f, f.id_b), "B's Keystore key survives")
	expect_read(t, f.id_b, KEYSTORE_SEC_TEST_KEY_2)
	keystore_lock_and_purge(f.id_b)
}

@(test)
test_keystore_android_refuses_non_test_ids :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-ids", true)
	defer fixture_close(&f)
	if !ok do return

	for id in ([]string{"brg_18dd7fe24b7074ab", "local-daemon", "", "../brg_test_x"}) {
		stored, code := keystore_store_vault_key(id, KEYSTORE_SEC_TEST_KEY_1)
		testing.expect(t, !stored, fmt.tprintf("id %q stores nothing", id))
		testing.expect_value(t, code, KEYSTORE_ERR_BAD_BRIDGE_ID)
		_, alias_ok := keystore_android_alias(id)
		testing.expect(t, !alias_ok, fmt.tprintf("id %q names no Keystore alias", id))
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/argv.log", f.shim_dir)), "termux-keystore was never invoked")
}

@(test)
test_bridge_enroll_restart_argv_runit :: proc(t: ^testing.T) {
	runit := bridge_enroll_restart_argv("/data/data/com.termux/files/usr/var/service/ham-bridge")
	testing.expect_value(t, strings.join(runit, " ", context.temp_allocator), "sv restart /data/data/com.termux/files/usr/var/service/ham-bridge")
	systemd := bridge_enroll_restart_argv("")
	testing.expect_value(t, strings.join(systemd, " ", context.temp_allocator), "systemctl --user restart heimdall-bridge")

	// The runit branch is taken only when $PREFIX/var/service/ham-bridge exists,
	// and then with that absolute path (no reliance on SVDIR).
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	prefix := fmt.tprintf("/tmp/heimdall-t7-prefix-%d", int(posix.getpid()))
	defer _ = os.remove_all(prefix)
	prev, had := os.lookup_env("PREFIX", context.allocator)
	defer {
		if had { _ = os.set_env("PREFIX", prev); delete(prev) } else { os.unset_env("PREFIX") }
	}
	_ = os.set_env("PREFIX", prefix)
	dir, ok := bridge_enroll_runit_service_dir()
	testing.expect(t, !ok && dir == "", "no service dir: systemd branch")
	_ = os.make_directory_all(fmt.tprintf("%s/var/service/ham-bridge", prefix))
	dir, ok = bridge_enroll_runit_service_dir()
	testing.expect(t, ok, "service dir found")
	testing.expect_value(t, dir, fmt.tprintf("%s/var/service/ham-bridge", prefix))
}

@(test)
test_keystore_android_read_hot_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-hot", true)
	defer fixture_close(&f)
	if !ok do return

	stored, _ := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "store succeeds")

	// Right after the store the key is already in memory: no Keystore call.
	signs := shim_calls(&f, "sign")
	got, hit := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, hit && got == KEYSTORE_SEC_TEST_KEY_1, "read after store")
	delete(got)
	testing.expect_value(t, shim_calls(&f, "sign"), signs)

	// A restarted process has only the file: the first read unwraps once...
	keystore_wipe_in_memory_vault_key()
	got, hit = keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, hit && got == KEYSTORE_SEC_TEST_KEY_1, "first read after restart unwraps")
	delete(got)
	testing.expect_value(t, shim_calls(&f, "sign"), signs + 1)
	// ...and every later read is served from memory.
	for _ in 0 ..< 3 {
		got, hit = keystore_read_keyring_vault_key(f.id_a)
		testing.expect(t, hit && got == KEYSTORE_SEC_TEST_KEY_1, "hot read")
		delete(got)
	}
	testing.expect_value(t, shim_calls(&f, "sign"), signs + 1)

	// The cached key belongs to A only: B (nothing stored) is not served A's key.
	_, b_hit := keystore_read_keyring_vault_key(f.id_b)
	testing.expect(t, !b_hit, "another bridge id is never served the cached key")

	// Lock: neither memory nor the file yields the key any more.
	keystore_lock_and_purge(f.id_a)
	_, hit = keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !hit, "no key after lock")
}

@(test)
test_keystore_android_store_never_regenerates_a_live_alias :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-nogen", true)
	defer fixture_close(&f)
	if !ok do return

	stored, _ := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "initial store")
	alias, _ := keystore_android_alias(f.id_a)
	pem_path := fmt.tprintf("%s/keys/%s.pem", f.shim_dir, alias)
	pem_before, _ := os.read_entire_file(pem_path, context.allocator)
	defer delete(pem_before)
	path, _ := keystore_android_sealed_path(f.id_a)
	sealed_before, _ := os.read_entire_file(path, context.allocator)
	defer delete(sealed_before)
	gens := shim_calls(&f, "generate")

	// A sealed file exists and the alias is listed: a failing or malformed sign
	// fails the store and leaves both the alias and the file intact.
	for mode in ([]string{"fail", "short"}) {
		shim_set_mode(&f, mode)
		stored, code := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_2)
		testing.expect(t, !stored, fmt.tprintf("sign %s with a live alias fails the store", mode))
		testing.expect_value(t, code, KEYSTORE_ERR_ANDROID_TOOL)
	}
	// An unreadable `list` counts as "alias may exist": also no regeneration.
	shim_set_listmode(&f, "broken")
	shim_set_mode(&f, "fail")
	stored, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, !stored, "unknown alias state fails closed")
	testing.expect_value(t, shim_calls(&f, "generate"), gens)
	pem_after, _ := os.read_entire_file(pem_path, context.allocator)
	defer delete(pem_after)
	testing.expect(t, string(pem_after) == string(pem_before), "the Keystore key was not replaced")
	sealed_after, _ := os.read_entire_file(path, context.allocator)
	defer delete(sealed_after)
	testing.expect(t, string(sealed_after) == string(sealed_before), "the sealed file was not touched")
	shim_set_mode(&f, "raw")
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)

	// The alias is confirmed gone (e.g. Termux:API reinstalled): the store
	// regenerates it and the bridge can be unsealed again.
	shim_set_listmode(&f, "ok")
	_ = os.remove(pem_path)
	stored, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, stored, "a missing alias is regenerated")
	testing.expect_value(t, shim_calls(&f, "generate"), gens + 1)
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_2)
	keystore_lock_and_purge(f.id_a)
}

@(test)
test_keystore_android_alias_in_list :: proc(t: ^testing.T) {
	list := `[{"alias": "heimdall-bridge-brg_test_1", "algorithm": "RSA", "size": 2048}, {"alias": "other"}]`
	present, known := keystore_android_alias_in_list(transmute([]u8)string(list), "heimdall-bridge-brg_test_1")
	testing.expect(t, present && known, "listed alias found")
	present, known = keystore_android_alias_in_list(transmute([]u8)string(list), "heimdall-bridge-brg_test_2")
	testing.expect(t, !present && known, "unlisted alias known absent")
	present, known = keystore_android_alias_in_list(transmute([]u8)string("[]"), "x")
	testing.expect(t, !present && known, "empty keystore")
	for bad in ([]string{"", "Termux:API error", `{"alias": "x"}`, `[{"name": "x"}]`, `["x"]`}) {
		_, known = keystore_android_alias_in_list(transmute([]u8)bad, "x")
		testing.expect(t, !known, fmt.tprintf("%q is not a usable list", bad))
	}
}

@(test)
test_keystore_android_signature_bytes :: proc(t: ^testing.T) {
	raw: [KEYSTORE_ANDROID_SIG_LEN]u8
	for i in 0 ..< len(raw) do raw[i] = u8(i * 7 + 3)
	dst: [KEYSTORE_ANDROID_SIG_LEN]u8

	testing.expect(t, keystore_android_signature_bytes(raw[:], dst[:]), "raw 256 bytes accepted")
	testing.expect(t, dst == raw, "raw copied verbatim")

	encoded, _ := base64.encode(raw[:])
	defer delete(encoded)
	wrapped := strings.builder_make()
	defer strings.builder_destroy(&wrapped)
	for i := 0; i < len(encoded); i += 76 {
		strings.write_string(&wrapped, encoded[i:min(i + 76, len(encoded))])
		strings.write_byte(&wrapped, '\n')
	}
	dst = {}
	testing.expect(t, keystore_android_signature_bytes(transmute([]u8)strings.to_string(wrapped), dst[:]), "76-column base64 accepted")
	testing.expect(t, dst == raw, "base64 decodes to the same signature")

	testing.expect(t, !keystore_android_signature_bytes(raw[:128], dst[:]), "short raw rejected")
	short_b64, _ := base64.encode(raw[:128])
	defer delete(short_b64)
	testing.expect(t, !keystore_android_signature_bytes(transmute([]u8)short_b64, dst[:]), "base64 of the wrong length rejected")
	testing.expect(t, !keystore_android_signature_bytes(transmute([]u8)string("not base64 at all!"), dst[:]), "garbage rejected")
	testing.expect(t, !keystore_android_signature_bytes(nil, dst[:]), "empty output rejected")
}

@(test)
test_keystore_android_store_rejects_nondeterministic_signature :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-flip", true)
	defer fixture_close(&f)
	if !ok do return
	path, _ := keystore_android_sealed_path(f.id_a)
	path = strings.clone(path)
	defer delete(path)

	// First unseal on a device whose signatures differ call to call: refused,
	// nothing written, nothing kept in memory.
	shim_set_mode(&f, "flip")
	stored, code := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, !stored, "non-deterministic signatures fail the store")
	testing.expect_value(t, code, KEYSTORE_ERR_ANDROID_TOOL)
	testing.expect(t, !os.exists(path), "no sealed file is left behind")
	_, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !mem_ok, "nothing kept in memory")
	_, read_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, !read_ok, "read reports not found")

	// A good sealed file survives a later non-deterministic store untouched.
	shim_set_mode(&f, "raw")
	stored, _ = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "deterministic store succeeds")
	before, _ := os.read_entire_file(path, context.allocator)
	defer delete(before)
	shim_set_mode(&f, "flip")
	stored, code = keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, !stored, "non-deterministic re-store fails")
	testing.expect_value(t, code, KEYSTORE_ERR_ANDROID_TOOL)
	after, _ := os.read_entire_file(path, context.allocator)
	defer delete(after)
	testing.expect(t, string(after) == string(before), "the existing sealed file was not touched")
	shim_set_mode(&f, "raw")
	keystore_wipe_in_memory_vault_key()
	expect_read(t, f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	keystore_lock_and_purge(f.id_a)
}

@(test)
test_keystore_android_enroll_readback_uses_sealed_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f, ok := fixture_open(t, "android-readback", true)
	defer fixture_close(&f)
	if !ok do return

	stored, _ := keystore_store_vault_key(f.id_a, KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, stored, "store succeeds")

	// The read-back goes to the Keystore and the file, not the memory cache.
	signs := shim_calls(&f, "sign")
	testing.expect(t, bridge_enroll_vault_key_persisted(f.id_a), "a good sealed file reads back")
	testing.expect_value(t, shim_calls(&f, "sign"), signs + 1)

	// Corrupt the file after the store: the cached key still serves this process,
	// but the read-back reports that a restarted bridge would start locked.
	path, _ := keystore_android_sealed_path(f.id_a)
	data, _ := os.read_entire_file(path, context.allocator)
	data[len(data) - 1] ~= 0xff
	_ = os.write_entire_file(path, data, {.Read_User, .Write_User})
	delete(data)
	cached, cached_ok := keystore_read_keyring_vault_key(f.id_a)
	testing.expect(t, cached_ok && cached == KEYSTORE_SEC_TEST_KEY_1, "this process still has the key in memory")
	delete(cached)
	testing.expect(t, !bridge_enroll_vault_key_persisted(f.id_a), "a corrupted sealed file fails the read-back")

	// No file at all: also not persisted.
	_ = os.remove(path)
	testing.expect(t, !bridge_enroll_vault_key_persisted(f.id_a), "a missing sealed file fails the read-back")
	keystore_lock_and_purge(f.id_a)
}
