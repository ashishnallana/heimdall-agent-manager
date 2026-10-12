#+build linux
package main

// Android (Termux) persistence for the unsealed vault key. Termux is Linux
// userland, so this file is compiled into every Linux build and selected at run
// time (keystore_android_selected); the @u keyring backend in keystore_linux.odin
// stays the desktop path. Termux ships no keyutils and app processes are
// seccomp-blocked from the kernel keyring, so this backend never probes it.
//
// Each bridge owns a non-exportable RSA-2048 key in the Android Keystore under
// the alias "heimdall-bridge-<bridge_id>" (via Termux:API `termux-keystore`).
// RSA PKCS#1 v1.5 signatures are deterministic, so signing the fixed label
// "heimdall-vault-kek:<bridge_id>" always yields the same bytes:
//
//	KEK    = HKDF-SHA256(ikm = signature, salt = "heimdall-bridge/vault-kek/v1", info = "heimdall-vault-kek:<bridge_id>")
//	sealed = "HMVS" | 0x01 | nonce[12] | AES-256-GCM_KEK(key_hex[64]) | tag[16]
//	         AAD = "HMVS" | 0x01 | bridge_id
//
// written 0600 to ~/.config/heimdall/bridges/<bridge_id>/vault_key.sealed. The
// file alone is useless off the device: the KEK needs the Keystore key. Once
// unwrapped, the key is served from the process's mlock'd in-memory buffer (the
// hot path), so only the first read after a restart pays the Termux:API round trip.
//
// A store signs twice and refuses (writing nothing) unless both signatures give
// the same KEK, then reopens the file it wrote: a device whose Keystore does not
// sign deterministically, or a write that does not read back, fails the unseal
// instead of leaving a bridge that starts locked after its next restart.
//
// A store generates the Keystore key only when there is no sealed file yet, or
// when `termux-keystore list` confirms the alias is gone (e.g. Termux:API was
// reinstalled). Any other sign failure leaves the alias alone: regenerating it
// would make an existing sealed file permanently unopenable.
//
// FAILS CLOSED. A missing tool, a non-zero exit, a timeout or a signature of the
// wrong size makes a store fail (nothing persisted, nothing kept in memory) and a
// read report "not found", so the bridge starts locked. There is no plaintext
// fallback. The label goes to the tool on stdin, never argv; the signature, KEK
// and key are never logged and every buffer holding them is zeroed.

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"

KEYSTORE_ANDROID_TOOL          :: "termux-keystore"
KEYSTORE_ANDROID_ALIAS_PREFIX  :: "heimdall-bridge-"
KEYSTORE_ANDROID_LABEL_PREFIX  :: "heimdall-vault-kek:"
KEYSTORE_ANDROID_KEK_SALT      :: "heimdall-bridge/vault-kek/v1"
KEYSTORE_ANDROID_SIGN_ALG      :: "SHA256withRSA"
KEYSTORE_ANDROID_SIG_LEN       :: 256 // RSA-2048
KEYSTORE_ANDROID_SEALED_NAME   :: "vault_key.sealed"
KEYSTORE_ANDROID_SEALED_MAGIC  :: "HMVS"
KEYSTORE_ANDROID_SEALED_VER    :: u8(1)
KEYSTORE_ANDROID_HEADER_LEN    :: len(KEYSTORE_ANDROID_SEALED_MAGIC) + 1
KEYSTORE_ANDROID_KEY_HEX_LEN   :: 64
KEYSTORE_ANDROID_SEALED_LEN    :: KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE + KEYSTORE_ANDROID_KEY_HEX_LEN + aes.GCM_TAG_SIZE
// Termux:API round-trips through an Android app; the first call after boot can
// take seconds, and with the app missing the tool may never return.
KEYSTORE_ANDROID_TOOL_TIMEOUT  :: 30 * time.Second

// keystore_store_vault_key's err_code on this backend.
KEYSTORE_ERR_ANDROID_TOOL  :: -3 // termux-keystore missing, failed, or returned a bad signature
KEYSTORE_ERR_ANDROID_WRITE :: -4 // the sealed file could not be written

// Test builds select this backend per test thread (keystore_android_test_force)
// rather than from the environment, so a keystore test running concurrently on
// another thread keeps the @u backend.
// Read only in test builds.
@(thread_local)
keystore_android_test_force: bool

// The in-memory buffer is shared with the @u backend and is not keyed, so this
// backend records which bridge it holds the key for and serves it only to that
// bridge. The mutex also serialises unwraps, so concurrent first reads after a
// restart cost one Termux:API round trip, not one each.
@(private = "file")
keystore_android_mem_mu: sync.Mutex
@(private = "file")
keystore_android_mem_owner_buf: [128]u8
@(private = "file")
keystore_android_mem_owner_len: int

// Caller holds keystore_android_mem_mu.
@(private = "file")
keystore_android_mem_remember :: proc(bridge_id, key_hex: string) -> bool {
	keystore_android_mem_owner_len = 0
	if len(bridge_id) > len(keystore_android_mem_owner_buf) do return false
	if !keystore_store_in_memory_vault_key(key_hex) do return false
	copy(keystore_android_mem_owner_buf[:], bridge_id)
	keystore_android_mem_owner_len = len(bridge_id)
	return true
}

// keystore_android_env_says_termux: TERMUX_VERSION is set (termux-exec exports it
// to every Termux process) or $PREFIX lives in the Termux app's data directory.
keystore_android_env_says_termux :: proc(termux_version, prefix: string) -> bool {
	return contracts.termux_env_detected(termux_version, prefix)
}

keystore_android_selected :: proc() -> bool {
	when ODIN_TEST {
		return keystore_android_test_force
	} else {
		termux_version, _ := os.lookup_env("TERMUX_VERSION", context.temp_allocator)
		prefix, _ := os.lookup_env("PREFIX", context.temp_allocator)
		return keystore_android_env_says_termux(termux_version, prefix)
	}
}

// Temp-allocated. ok is false for an id that cannot name a key (keystore_bridge_id_ok).
keystore_android_alias :: proc(bridge_id: string) -> (alias: string, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	return strings.concatenate({KEYSTORE_ANDROID_ALIAS_PREFIX, bridge_id}, context.temp_allocator), true
}

// Temp-allocated path of bridge_id's sealed key file.
keystore_android_sealed_path :: proc(bridge_id: string) -> (path: string, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	dir := bridge_vault_bridge_dir(bridge_id, context.temp_allocator) or_return
	return strings.concatenate({dir, KEYSTORE_ANDROID_SEALED_NAME}, context.temp_allocator), true
}

// Runs `termux-keystore <args>` with stdin_data on stdin (no shell). stdout is
// returned in a buffer the caller must zero and delete; stderr (tool diagnostics,
// never secrets) is temp-allocated for error messages.
@(private = "file")
keystore_android_run_tool :: proc(args: []string, stdin_data: []u8) -> (stdout: [dynamic]u8, stderr: string, ok: bool) {
	argv := make([]string, len(args) + 1, context.temp_allocator)
	argv[0] = KEYSTORE_ANDROID_TOOL
	copy(argv[1:], args)

	stdin_r, stdin_w, in_err := os.pipe()
	if in_err != nil do return nil, "could not create a pipe", false
	defer os.close(stdin_r)
	// The label is a few dozen bytes, far below the pipe buffer: write it all and
	// close, so the tool reads it and then sees EOF.
	if len(stdin_data) > 0 {
		if n, werr := os.write(stdin_w, stdin_data); werr != nil || n != len(stdin_data) {
			os.close(stdin_w)
			return nil, "could not write the tool's stdin", false
		}
	}
	os.close(stdin_w)

	stdout_r, stdout_w, out_err := os.pipe()
	if out_err != nil do return nil, "could not create a pipe", false
	defer os.close(stdout_r)
	stderr_r, stderr_w, err_err := os.pipe()
	if err_err != nil {
		os.close(stdout_w)
		return nil, "could not create a pipe", false
	}
	defer os.close(stderr_r)

	process, start_err := os.process_start(os.Process_Desc{command = argv, stdin = stdin_r, stdout = stdout_w, stderr = stderr_w})
	os.close(stdout_w)
	os.close(stderr_w)
	if start_err != nil {
		return nil, fmt.tprintf("%s is not installed or not on PATH (%v)", KEYSTORE_ANDROID_TOOL, start_err), false
	}

	stdout = make([dynamic]u8, 0, 512)
	err_bytes := make([dynamic]u8, 0, 512, context.temp_allocator)
	deadline := time.time_add(time.now(), KEYSTORE_ANDROID_TOOL_TIMEOUT)
	state: os.Process_State
	for {
		out_read, _ := bridge_process_drain_pipe(stdout_r, &stdout)
		err_read, _ := bridge_process_drain_pipe(stderr_r, &err_bytes)
		if current, wait_err := os.process_wait(process, 0); wait_err == nil {
			state = current
			break
		}
		if time.diff(time.now(), deadline) <= 0 {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process, 500 * time.Millisecond)
			return stdout, fmt.tprintf("%s timed out after %v (is the Termux:API app installed?)", KEYSTORE_ANDROID_TOOL, KEYSTORE_ANDROID_TOOL_TIMEOUT), false
		}
		if !out_read && !err_read do time.sleep(5 * time.Millisecond)
	}
	for {
		out_read, _ := bridge_process_drain_pipe(stdout_r, &stdout)
		err_read, _ := bridge_process_drain_pipe(stderr_r, &err_bytes)
		if !out_read && !err_read do break
	}
	stderr = strings.trim_space(string(err_bytes[:]))
	if !state.exited || !state.success {
		return stdout, fmt.tprintf("%s %s exited with status %d: %s", KEYSTORE_ANDROID_TOOL, args[0], state.exit_code, stderr), false
	}
	return stdout, stderr, true
}

@(private = "file")
keystore_android_free_secret :: proc(buf: ^[dynamic]u8) {
	if cap(buf^) > 0 do mem.zero_explicit(raw_data(buf^), cap(buf^))
	delete(buf^)
	buf^ = nil
}

// keystore_android_signature_bytes accepts the raw RSA-2048 signature, or the
// same 256 bytes base64-encoded; whitespace is ignored, since Android's
// Base64.DEFAULT wraps lines at 76 columns. Anything else fails closed. dst must
// hold KEYSTORE_ANDROID_SIG_LEN bytes.
keystore_android_signature_bytes :: proc(stdout: []u8, dst: []u8) -> bool {
	if len(dst) != KEYSTORE_ANDROID_SIG_LEN do return false
	if len(stdout) == KEYSTORE_ANDROID_SIG_LEN {
		copy(dst, stdout)
		return true
	}
	// The base64 text is itself the secret, so the compacted copy is zeroed too.
	compact: [2 * KEYSTORE_ANDROID_SIG_LEN]u8
	defer mem.zero_explicit(&compact, size_of(compact))
	n := 0
	for c in stdout {
		switch c {
		case ' ', '\t', '\r', '\n':
			continue
		}
		if n == len(compact) do return false
		compact[n] = c
		n += 1
	}
	if n == 0 do return false
	decoded, dec_err := base64.decode(string(compact[:n]))
	if dec_err != nil do return false
	defer {
		mem.zero_explicit(raw_data(decoded), len(decoded))
		delete(decoded)
	}
	if len(decoded) != KEYSTORE_ANDROID_SIG_LEN do return false
	copy(dst, decoded)
	return true
}

// Signs bridge_id's label with its Keystore key and derives the KEK into kek.
// why is a temp-allocated reason on failure (never contains key material).
@(private = "file")
keystore_android_derive_kek :: proc(bridge_id: string, kek: []u8) -> (ok: bool, why: string) {
	alias, alias_ok := keystore_android_alias(bridge_id)
	if !alias_ok do return false, "bridge id cannot name a Keystore key"
	label := strings.concatenate({KEYSTORE_ANDROID_LABEL_PREFIX, bridge_id}, context.temp_allocator)

	out, stderr, run_ok := keystore_android_run_tool({"sign", alias, KEYSTORE_ANDROID_SIGN_ALG}, transmute([]u8)label)
	defer keystore_android_free_secret(&out)
	if !run_ok do return false, stderr

	sig: [KEYSTORE_ANDROID_SIG_LEN]u8
	defer mem.zero_explicit(&sig, size_of(sig))
	if !keystore_android_signature_bytes(out[:], sig[:]) {
		return false, fmt.tprintf("%s sign returned %d bytes, not a %d-byte RSA-2048 signature (raw or base64)", KEYSTORE_ANDROID_TOOL, len(out), KEYSTORE_ANDROID_SIG_LEN)
	}
	hkdf.extract_and_expand(.SHA256, transmute([]u8)string(KEYSTORE_ANDROID_KEK_SALT), sig[:], transmute([]u8)label, kek)
	return true, ""
}

@(private = "file")
keystore_android_aad :: proc(bridge_id: string) -> []u8 {
	b := make([]u8, KEYSTORE_ANDROID_HEADER_LEN + len(bridge_id), context.temp_allocator)
	copy(b, KEYSTORE_ANDROID_SEALED_MAGIC)
	b[len(KEYSTORE_ANDROID_SEALED_MAGIC)] = KEYSTORE_ANDROID_SEALED_VER
	copy(b[KEYSTORE_ANDROID_HEADER_LEN:], bridge_id)
	return b
}

// Writes data to path with mode 0600 via a temp file + rename, so a crash never
// leaves a truncated sealed file behind.
@(private = "file")
keystore_android_write_file :: proc(path: string, data: []u8) -> (ok: bool, reason: string) {
	dir := path[:max(strings.last_index_byte(path, '/'), 0)]
	if mk_err := bridge_make_directory_all(dir); mk_err != nil && !os.exists(dir) {
		return false, fmt.tprintf("mkdir %s: %v", dir, mk_err)
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.remove(tmp)
	f, open_err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
	if open_err != nil do return false, fmt.tprintf("open %s: %v", tmp, open_err)
	n, write_err := os.write(f, data)
	sync_err := os.sync(f)
	os.close(f)
	if write_err != nil || n != len(data) || sync_err != nil {
		_ = os.remove(tmp)
		return false, fmt.tprintf("write/fsync %s: write=%v n=%d/%d sync=%v", tmp, write_err, n, len(data), sync_err)
	}
	if rn_err := os.rename(tmp, path); rn_err != nil {
		_ = os.remove(tmp)
		return false, fmt.tprintf("rename %s -> %s: %v", tmp, path, rn_err)
	}
	return true, ""
}

// keystore_android_alias_listed asks `termux-keystore list` whether alias
// exists. known is false when the tool fails or its output is not the expected
// JSON array of {"alias": …} objects; callers must then assume it exists.
keystore_android_alias_listed :: proc(alias: string) -> (present: bool, known: bool) {
	out, _, ok := keystore_android_run_tool({"list"}, nil)
	defer keystore_android_free_secret(&out)
	if !ok do return false, false
	return keystore_android_alias_in_list(out[:], alias)
}

keystore_android_alias_in_list :: proc(list_json: []u8, alias: string) -> (present: bool, known: bool) {
	value, err := json.parse(list_json, allocator = context.temp_allocator)
	if err != nil do return false, false
	entries, is_array := value.(json.Array)
	if !is_array do return false, false
	for entry in entries {
		obj, is_obj := entry.(json.Object)
		if !is_obj do return false, false
		name, is_str := obj["alias"].(json.String)
		if !is_str do return false, false
		if name == alias do return true, true
	}
	return false, true
}

// Seals key_hex under bridge_id's Keystore-derived KEK. The first store finds no
// alias and no sealed file, so it generates the Keystore key; see the file
// header for when a later store may regenerate it.
keystore_android_store_vault_key :: proc(bridge_id: string, key_hex: string) -> (ok: bool, err_code: int) {
	if !bridge_is_valid_hex_key(key_hex) || len(key_hex) != KEYSTORE_ANDROID_KEY_HEX_LEN do return false, -1
	path, path_ok := keystore_android_sealed_path(bridge_id)
	if !path_ok do return false, KEYSTORE_ERR_BAD_BRIDGE_ID
	alias, _ := keystore_android_alias(bridge_id)

	sync.mutex_lock(&keystore_android_mem_mu)
	defer sync.mutex_unlock(&keystore_android_mem_mu)

	kek: [32]u8
	defer mem.zero_explicit(&kek, size_of(kek))
	if derived, sign_err := keystore_android_derive_kek(bridge_id, kek[:]); !derived {
		if os.exists(path) {
			present, known := keystore_android_alias_listed(alias)
			if !known || present {
				fmt.eprintfln(
					"ERROR: the Android Keystore could not sign with %s (%s), and regenerating it would make the existing sealed vault key unopenable. The vault key was NOT persisted; check Termux:API and unseal again from Settings → Bridges → Unseal.",
					alias,
					sign_err,
				)
				return false, KEYSTORE_ERR_ANDROID_TOOL
			}
		}
		out, gen_err, gen_ok := keystore_android_run_tool({"generate", alias, "-a", "RSA", "-s", "2048"}, nil)
		keystore_android_free_secret(&out)
		why := gen_err
		if gen_ok {
			derived, why = keystore_android_derive_kek(bridge_id, kek[:])
			gen_ok = derived
		}
		if !gen_ok {
			fmt.eprintfln(
				"ERROR: Android Keystore unavailable, so the vault key was NOT persisted (%s). Install the Termux:API app and `pkg install termux-api`, then unseal from Settings → Bridges → Unseal.",
				why,
			)
			return false, KEYSTORE_ERR_ANDROID_TOOL
		}
	}

	// Determinism: a restarted bridge re-derives the KEK from a fresh signature,
	// so a second signature must give the same KEK before anything is written.
	kek_check: [32]u8
	defer mem.zero_explicit(&kek_check, size_of(kek_check))
	if derived, why := keystore_android_derive_kek(bridge_id, kek_check[:]); !derived {
		fmt.eprintfln("ERROR: the Android Keystore failed on the verification signature (%s); the vault key was NOT persisted.", why)
		return false, KEYSTORE_ERR_ANDROID_TOOL
	}
	if crypto.compare_constant_time(kek[:], kek_check[:]) != 1 {
		fmt.eprintfln(
			"ERROR: the Android Keystore signature for %s is not deterministic, so a restarted bridge could not unwrap the vault key. The vault key was NOT persisted.",
			alias,
		)
		return false, KEYSTORE_ERR_ANDROID_TOOL
	}

	sealed: [KEYSTORE_ANDROID_SEALED_LEN]u8
	copy(sealed[:], keystore_android_aad(bridge_id)[:KEYSTORE_ANDROID_HEADER_LEN])
	nonce := sealed[KEYSTORE_ANDROID_HEADER_LEN:][:aes.GCM_IV_SIZE]
	ct := sealed[KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE:][:KEYSTORE_ANDROID_KEY_HEX_LEN]
	tag := sealed[KEYSTORE_ANDROID_SEALED_LEN - aes.GCM_TAG_SIZE:]
	crypto.rand_bytes(nonce)

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, kek[:])
	aes.seal_gcm(&gcm, ct, tag, nonce, keystore_android_aad(bridge_id), transmute([]u8)key_hex)
	aes.reset_gcm(&gcm)

	if write_ok, why := keystore_android_write_file(path, sealed[:]); !write_ok {
		fmt.eprintfln("ERROR: could not write the sealed vault key %s (%s); the vault key was NOT persisted.", path, why)
		return false, KEYSTORE_ERR_ANDROID_WRITE
	}
	// Reopen what landed on disk, exactly as a restarted bridge will.
	if !keystore_android_file_holds_key(bridge_id, path, kek_check[:], key_hex) {
		_ = os.remove(path)
		fmt.eprintfln("ERROR: the sealed vault key %s did not read back; removed it. The vault key was NOT persisted.", path)
		return false, KEYSTORE_ERR_ANDROID_WRITE
	}
	if !keystore_android_mem_remember(bridge_id, key_hex) {
		fmt.eprintln("WARN: the vault key was sealed to disk but could not be kept in locked memory; it will be unwrapped from the sealed file on the next read.")
		return false, -1
	}
	return true, 0
}

// keystore_android_open_sealed checks data's header and opens it with kek into
// plain (KEYSTORE_ANDROID_KEY_HEX_LEN bytes). Never logs.
@(private = "file")
keystore_android_open_sealed :: proc(bridge_id: string, data: []u8, kek: []u8, plain: []u8) -> bool {
	if len(data) != KEYSTORE_ANDROID_SEALED_LEN do return false
	if string(data[:len(KEYSTORE_ANDROID_SEALED_MAGIC)]) != KEYSTORE_ANDROID_SEALED_MAGIC do return false
	if data[len(KEYSTORE_ANDROID_SEALED_MAGIC)] != KEYSTORE_ANDROID_SEALED_VER do return false
	nonce := data[KEYSTORE_ANDROID_HEADER_LEN:][:aes.GCM_IV_SIZE]
	ct := data[KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE:][:KEYSTORE_ANDROID_KEY_HEX_LEN]
	tag := data[KEYSTORE_ANDROID_SEALED_LEN - aes.GCM_TAG_SIZE:]
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, kek)
	defer aes.reset_gcm(&gcm)
	return aes.open_gcm(&gcm, plain, nonce, keystore_android_aad(bridge_id), ct, tag)
}

// Whether the file at path opens with kek to exactly key_hex.
@(private = "file")
keystore_android_file_holds_key :: proc(bridge_id, path: string, kek: []u8, key_hex: string) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return false
	defer delete(data)
	plain: [KEYSTORE_ANDROID_KEY_HEX_LEN]u8
	defer mem.zero_explicit(&plain, size_of(plain))
	if !keystore_android_open_sealed(bridge_id, data, kek, plain[:]) do return false
	return crypto.compare_constant_time(plain[:], transmute([]u8)key_hex) == 1
}

// Returns bridge_id's key from memory when this process already holds it, else
// unwraps the sealed file (keystore_android_read_sealed_file) and keeps the key
// in memory. Any failure is "not found", so the bridge reports locked.
keystore_android_read_vault_key :: proc(bridge_id: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	sync.mutex_lock(&keystore_android_mem_mu)
	defer sync.mutex_unlock(&keystore_android_mem_mu)
	if string(keystore_android_mem_owner_buf[:keystore_android_mem_owner_len]) == bridge_id {
		if cached, hit := keystore_read_in_memory_vault_key(allocator); hit do return cached, true
	}
	key_hex = keystore_android_unwrap_file(bridge_id, allocator) or_return
	_ = keystore_android_mem_remember(bridge_id, key_hex)
	return key_hex, true
}

// keystore_android_read_sealed_file unwraps bridge_id's sealed file through the
// Keystore, ignoring and never filling the in-memory cache: it answers "would a
// restarted bridge find this key?" (the enrollment read-back). Any failure — no
// file, a bad header, the tool unavailable, a different Keystore key — is "not
// found".
keystore_android_read_sealed_file :: proc(bridge_id: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	sync.mutex_lock(&keystore_android_mem_mu)
	defer sync.mutex_unlock(&keystore_android_mem_mu)
	return keystore_android_unwrap_file(bridge_id, allocator)
}

// Caller holds keystore_android_mem_mu.
@(private = "file")
keystore_android_unwrap_file :: proc(bridge_id: string, allocator: mem.Allocator) -> (key_hex: string, ok: bool) {
	path := keystore_android_sealed_path(bridge_id) or_return
	if !os.exists(path) do return "", false
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return "", false
	defer delete(data)
	if len(data) != KEYSTORE_ANDROID_SEALED_LEN || string(data[:len(KEYSTORE_ANDROID_SEALED_MAGIC)]) != KEYSTORE_ANDROID_SEALED_MAGIC || data[len(KEYSTORE_ANDROID_SEALED_MAGIC)] != KEYSTORE_ANDROID_SEALED_VER {
		fmt.eprintfln("WARN: %s is not a version-%d sealed vault key; the bridge stays locked. Unseal from Settings → Bridges → Unseal.", path, KEYSTORE_ANDROID_SEALED_VER)
		return "", false
	}

	kek: [32]u8
	defer mem.zero_explicit(&kek, size_of(kek))
	if derived, why := keystore_android_derive_kek(bridge_id, kek[:]); !derived {
		fmt.eprintfln("WARN: could not unwrap the sealed vault key via the Android Keystore (%s); the bridge stays locked. Unseal from Settings → Bridges → Unseal.", why)
		return "", false
	}
	plain: [KEYSTORE_ANDROID_KEY_HEX_LEN]u8
	defer mem.zero_explicit(&plain, size_of(plain))
	if !keystore_android_open_sealed(bridge_id, data, kek[:], plain[:]) {
		fmt.eprintln("WARN: the sealed vault key does not open with this device's Keystore key; the bridge stays locked. Unseal from Settings → Bridges → Unseal.")
		return "", false
	}
	candidate := string(plain[:])
	if !bridge_is_valid_hex_key(candidate) do return "", false
	return strings.clone(candidate, allocator), true
}

keystore_android_persisted_vault_item_present :: proc(bridge_id: string) -> bool {
	path := keystore_android_sealed_path(bridge_id) or_return
	return os.exists(path)
}

// Deletes bridge_id's sealed file and wipes the in-memory key. The Keystore key
// stays, so the next unseal reuses it. Returns true when no sealed file remains.
keystore_android_unlink_vault_key :: proc(bridge_id: string) -> bool {
	sync.mutex_lock(&keystore_android_mem_mu)
	keystore_wipe_in_memory_vault_key()
	keystore_android_mem_owner_len = 0
	sync.mutex_unlock(&keystore_android_mem_mu)
	path := keystore_android_sealed_path(bridge_id) or_return
	if !os.exists(path) do return true
	return os.remove(path) == nil
}

// vault.reset: also deletes bridge_id's Keystore key. Best effort; a key that
// is already gone counts as deleted.
keystore_android_delete_keystore_key :: proc(bridge_id: string) -> bool {
	alias := keystore_android_alias(bridge_id) or_return
	out, why, ok := keystore_android_run_tool({"delete", alias}, nil)
	keystore_android_free_secret(&out)
	if !ok do fmt.eprintfln("WARN: could not delete Android Keystore key %s (%s).", alias, why)
	return ok
}
