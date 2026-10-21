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
//	sealed = "HMVS" | 0x02 | nonce[12] | AES-256-GCM_KEK(secret) | tag[16]
//	         AAD = "HMVS" | 0x02 | <slot name> | ":" | bridge_id
//
// written 0600 to ~/.config/heimdall/bridges/<bridge_id>/vault_keyring.sealed (the
// binary HKR2 keyring) or identity_key.sealed (the identity scalar). The file
// alone is useless off the device: the KEK needs the Keystore key. Once unwrapped,
// the keyring is served from keystore_common's mlock'd in-memory cache, so only
// the first read after a restart pays the Termux:API round trip.
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
import vault "odin_test:lib/vault"
import os_random "odin_test:lib/os_random"

KEYSTORE_ANDROID_TOOL          :: "termux-keystore"
KEYSTORE_ANDROID_ALIAS_PREFIX  :: "heimdall-bridge-"
KEYSTORE_ANDROID_LABEL_PREFIX  :: "heimdall-vault-kek:"
KEYSTORE_ANDROID_KEK_SALT      :: "heimdall-bridge/vault-kek/v1"
KEYSTORE_ANDROID_SIGN_ALG      :: "SHA256withRSA"
KEYSTORE_ANDROID_SIG_LEN       :: 256 // RSA-2048
KEYSTORE_ANDROID_KEYRING_FILE  :: "vault_keyring.sealed"
KEYSTORE_ANDROID_IDENTITY_FILE :: "identity_key.sealed"
KEYSTORE_ANDROID_FLOOR_FILE    :: "epoch_floor.sealed"
KEYSTORE_ANDROID_IDENTITY_PREVIOUS_FILE :: "identity_key.previous.sealed"
KEYSTORE_ANDROID_FLOOR_PREVIOUS_FILE    :: "epoch_floor.previous.sealed"
KEYSTORE_ANDROID_SEALED_MAGIC  :: "HMVS"
KEYSTORE_ANDROID_SEALED_VER    :: u8(2)
KEYSTORE_ANDROID_HEADER_LEN    :: len(KEYSTORE_ANDROID_SEALED_MAGIC) + 1
KEYSTORE_ANDROID_MAX_SECRET    :: vault.KEYRING_MAX_BYTES
KEYSTORE_ANDROID_OVERHEAD      :: KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE + aes.GCM_TAG_SIZE
// Termux:API round-trips through an Android app; the first call after boot can
// take seconds, and with the app missing the tool may never return.
KEYSTORE_ANDROID_TOOL_TIMEOUT  :: 30 * time.Second

// keystore_os_write_secret's error code on this backend.
KEYSTORE_ERR_ANDROID_TOOL  :: -3 // termux-keystore missing, failed, or returned a bad signature
KEYSTORE_ERR_ANDROID_WRITE :: -4 // the sealed file could not be written

// Test builds select this backend per test thread (keystore_android_test_force)
// rather than from the environment, so a keystore test running concurrently on
// another thread keeps the @u backend.
// Read only in test builds.
@(thread_local)
keystore_android_test_force: bool

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

// Temp-allocated path of bridge_id's sealed file for slot.
keystore_android_sealed_path :: proc(slot: Keystore_Slot, bridge_id: string) -> (path: string, ok: bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	dir := bridge_vault_bridge_dir(bridge_id, context.temp_allocator) or_return
	name: string
	switch slot {
	case .Keyring:     name = KEYSTORE_ANDROID_KEYRING_FILE
	case .Identity:    name = KEYSTORE_ANDROID_IDENTITY_FILE
	case .Epoch_Floor: name = KEYSTORE_ANDROID_FLOOR_FILE
	case .Identity_Previous:    name = KEYSTORE_ANDROID_IDENTITY_PREVIOUS_FILE
	case .Epoch_Floor_Previous: name = KEYSTORE_ANDROID_FLOOR_PREVIOUS_FILE
	}
	return strings.concatenate({dir, name}, context.temp_allocator), true
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
keystore_android_aad :: proc(slot: Keystore_Slot, bridge_id: string) -> []u8 {
	header := [KEYSTORE_ANDROID_HEADER_LEN]u8{'H', 'M', 'V', 'S', KEYSTORE_ANDROID_SEALED_VER}
	slot_name: string
	switch slot {
	case .Keyring:     slot_name = "keyring:"
	case .Identity:    slot_name = "identity:"
	case .Epoch_Floor: slot_name = "epoch_floor:"
	case .Identity_Previous:    slot_name = "identity_previous:"
	case .Epoch_Floor_Previous: slot_name = "epoch_floor_previous:"
	}
	return transmute([]u8)strings.concatenate({string(header[:]), slot_name, bridge_id}, context.temp_allocator)
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

// Keystore_Android_List_Entry is one element of `termux-keystore list` output.
Keystore_Android_List_Entry :: struct {
	alias: Maybe(string),
}

keystore_android_alias_in_list :: proc(list_json: []u8, alias: string) -> (present: bool, known: bool) {
	entries: []Keystore_Android_List_Entry
	if json.unmarshal(list_json, &entries, json.Specification.JSON, context.temp_allocator) != nil do return false, false
	for entry in entries {
		name, has := entry.alias.?
		if !has do return false, false
		if name == alias do return true, true
	}
	return false, true
}

// Seals data under bridge_id's Keystore-derived KEK. The first store finds no
// alias and no sealed file, so it generates the Keystore key; see the file header
// for when a later store may regenerate it. Returns 0 or a KEYSTORE_ERR_ANDROID_*.
keystore_android_write_secret :: proc(slot: Keystore_Slot, bridge_id: string, data: []byte) -> int {
	if len(data) == 0 || len(data) > KEYSTORE_ANDROID_MAX_SECRET do return -1
	path, path_ok := keystore_android_sealed_path(slot, bridge_id)
	if !path_ok do return KEYSTORE_ERR_BAD_BRIDGE_ID
	alias, _ := keystore_android_alias(bridge_id)

	sync.mutex_lock(&keystore_android_mu)
	defer sync.mutex_unlock(&keystore_android_mu)

	kek: [32]u8
	defer mem.zero_explicit(&kek, size_of(kek))
	if derived, sign_err := keystore_android_derive_kek(bridge_id, kek[:]); !derived {
		existing := false
		for other_slot in Keystore_Slot {
			if other, ok := keystore_android_sealed_path(other_slot, bridge_id); ok && os.exists(other) do existing = true
		}
		if existing {
			present, known := keystore_android_alias_listed(alias)
			if !known || present {
				fmt.eprintfln(
					"ERROR: the Android Keystore could not sign with %s (%s), and regenerating it would make the existing sealed files unopenable. Nothing was persisted; check Termux:API.",
					alias,
					sign_err,
				)
				return KEYSTORE_ERR_ANDROID_TOOL
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
			blog_error(.keystore_unavailable, blog_sym(.reason, .android_keystore))
			fmt.eprintfln(
				"ERROR: Android Keystore unavailable, so nothing was persisted (%s). Install the Termux:API app and `pkg install termux-api`.",
				why,
			)
			return KEYSTORE_ERR_ANDROID_TOOL
		}
	}

	// Determinism: a restarted bridge re-derives the KEK from a fresh signature,
	// so a second signature must give the same KEK before anything is written.
	kek_check: [32]u8
	defer mem.zero_explicit(&kek_check, size_of(kek_check))
	if derived, why := keystore_android_derive_kek(bridge_id, kek_check[:]); !derived {
		fmt.eprintfln("ERROR: the Android Keystore failed on the verification signature (%s); nothing was persisted.", why)
		return KEYSTORE_ERR_ANDROID_TOOL
	}
	if crypto.compare_constant_time(kek[:], kek_check[:]) != 1 {
		fmt.eprintfln("ERROR: the Android Keystore signature for %s is not deterministic; nothing was persisted.", alias)
		return KEYSTORE_ERR_ANDROID_TOOL
	}

	sealed := make([]u8, KEYSTORE_ANDROID_OVERHEAD + len(data), context.temp_allocator)
	defer mem.zero_explicit(raw_data(sealed), len(sealed))
	copy(sealed, KEYSTORE_ANDROID_SEALED_MAGIC)
	sealed[len(KEYSTORE_ANDROID_SEALED_MAGIC)] = KEYSTORE_ANDROID_SEALED_VER
	nonce := sealed[KEYSTORE_ANDROID_HEADER_LEN:][:aes.GCM_IV_SIZE]
	ct := sealed[KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE:][:len(data)]
	tag := sealed[len(sealed) - aes.GCM_TAG_SIZE:]
	if !os_random.fill(nonce) {
		fmt.eprintln("ERROR: the OS random source failed; nothing was persisted.")
		return KEYSTORE_ERR_ANDROID_WRITE
	}

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, kek[:])
	aes.seal_gcm(&gcm, ct, tag, nonce, keystore_android_aad(slot, bridge_id), data)
	aes.reset_gcm(&gcm)

	if write_ok, why := keystore_android_write_file(path, sealed); !write_ok {
		fmt.eprintfln("ERROR: could not write the sealed file %s (%s); nothing was persisted.", path, why)
		return KEYSTORE_ERR_ANDROID_WRITE
	}
	// Reopen what landed on disk, exactly as a restarted bridge will.
	check := make([]u8, len(data), context.temp_allocator)
	defer mem.zero_explicit(raw_data(check), len(check))
	n, read_ok := keystore_android_unwrap_file_locked(slot, bridge_id, check, kek_check[:])
	if !read_ok || n != len(data) || crypto.compare_constant_time(check[:n], data) != 1 {
		_ = os.remove(path)
		fmt.eprintfln("ERROR: the sealed file %s did not read back; removed it. Nothing was persisted.", path)
		return KEYSTORE_ERR_ANDROID_WRITE
	}
	return 0
}

@(private = "file")
keystore_android_mu: sync.Mutex

// Opens a sealed file's bytes with kek into dst. Never logs.
@(private = "file")
keystore_android_open_sealed :: proc(slot: Keystore_Slot, bridge_id: string, data: []u8, kek: []u8, dst: []u8) -> (n: int, ok: bool) {
	if len(data) <= KEYSTORE_ANDROID_OVERHEAD || len(data) > KEYSTORE_ANDROID_OVERHEAD + KEYSTORE_ANDROID_MAX_SECRET do return 0, false
	if string(data[:len(KEYSTORE_ANDROID_SEALED_MAGIC)]) != KEYSTORE_ANDROID_SEALED_MAGIC do return 0, false
	if data[len(KEYSTORE_ANDROID_SEALED_MAGIC)] != KEYSTORE_ANDROID_SEALED_VER do return 0, false
	size := len(data) - KEYSTORE_ANDROID_OVERHEAD
	if size > len(dst) do return 0, false
	nonce := data[KEYSTORE_ANDROID_HEADER_LEN:][:aes.GCM_IV_SIZE]
	ct := data[KEYSTORE_ANDROID_HEADER_LEN + aes.GCM_IV_SIZE:][:size]
	tag := data[len(data) - aes.GCM_TAG_SIZE:]
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, kek)
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, dst[:size], nonce, keystore_android_aad(slot, bridge_id), ct, tag) do return 0, false
	return size, true
}

// Caller holds keystore_android_mu. A nil kek_in derives the KEK through the Keystore.
@(private = "file")
keystore_android_unwrap_file_locked :: proc(slot: Keystore_Slot, bridge_id: string, dst: []u8, kek_in: []u8 = nil) -> (n: int, ok: bool) {
	path := keystore_android_sealed_path(slot, bridge_id) or_return
	if !os.exists(path) do return 0, false
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return 0, false
	defer delete(data)
	kek: [32]u8
	defer mem.zero_explicit(&kek, size_of(kek))
	if kek_in != nil {
		copy(kek[:], kek_in)
	} else if derived, why := keystore_android_derive_kek(bridge_id, kek[:]); !derived {
		blog_warn(.vault_unseal_failed, blog_sym(.reason, .android_keystore))
		fmt.eprintfln("WARN: could not unwrap %s via the Android Keystore (%s); the bridge stays locked.", path, why)
		return 0, false
	}
	n, ok = keystore_android_open_sealed(slot, bridge_id, data, kek[:], dst)
	if !ok {
		blog_warn(.vault_unseal_failed, blog_sym(.reason, .android_keystore), blog_sym(.stage, .verify))
		fmt.eprintfln("WARN: %s does not open with this device's Keystore key; the bridge stays locked.", path)
	}
	return
}

// No sealed file is .Not_Found; a file that exists but does not open (a bad
// header, the tool unavailable, a different Keystore key) is .Error.
keystore_android_read_secret_status :: proc(slot: Keystore_Slot, bridge_id: string, dst: []byte) -> (n: int, status: Keystore_Read_Status) {
	path, path_ok := keystore_android_sealed_path(slot, bridge_id)
	if !path_ok do return 0, .Error
	sync.mutex_lock(&keystore_android_mu)
	defer sync.mutex_unlock(&keystore_android_mu)
	if !os.exists(path) do return 0, .Not_Found
	got, ok := keystore_android_unwrap_file_locked(slot, bridge_id, dst)
	if !ok do return 0, .Error
	return got, .Found
}

// Deletes the slot's sealed file. The Keystore key stays, so the next store reuses
// it. Returns true when no sealed file remains.
keystore_android_delete_secret :: proc(slot: Keystore_Slot, bridge_id: string) -> bool {
	path := keystore_android_sealed_path(slot, bridge_id) or_return
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
