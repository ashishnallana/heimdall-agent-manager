package main

// REQ-VAULT-HARDEN-6: Comprehensive security and regression tests for
// bridge unseal lifecycle, anti-replay, clock skew, target verification,
// tamper detection, and unencrypted self-hosted pass-through.

import "base:runtime"
import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import cfg_lib "odin_test:lib/config"
// ── Vault key sandbox (iss_18db4d8f4b153b62) ─────────────────────────────────
//
// What used to be here, and why it was removed. These tests isolated themselves
// by RENAMING the operator's real key — `~/.config/heimdall/vault_key` ->
// `vault_key.sec_test_bak` — and renaming it back from a `defer`. `defer` runs
// only on a normal unwind, so a panic, assertion abort, timeout, SIGKILL or CI
// cancellation stranded the credential. On 2026-10-04 at 10:35:47 that happened:
// every `vault:v1:` field in the Hub became unreadable and only a human operator
// could recover it. The failure was also STICKY rather than transient — the next
// run saw `had_file == false` (the key was already gone), concluded there was
// nothing to restore, and abandoned the stale backup. The suite could not
// self-heal.
//
// The fix is not a hardened teardown. Teardown hardening — signal handlers,
// atexit hooks — narrows the window but keeps a real credential inside the blast
// radius and cannot survive SIGKILL at all. Instead the real path is never
// reachable in the first place: the sandbox redirects the home directory the key
// path is built from, so the worst a crashed test can damage is a temp dir.
//
// BOTH variables must be redirected, because the helper and the code under test
// resolve `~/` through DIFFERENT functions:
//
//   - `bridge_expand_home` (provider_store.odin:342-349) reads HOME only;
//   - `cfg_lib.expand_home` (src/lib/config/config.odin), which the per-bridge
//     vault_configured marker path resolves through (the bridge no longer reads
//     the legacy key file at all, REQ-T5-1), prefers HEIMDALL_HOME and only falls
//     back to HOME.
//
// Redirecting HOME alone therefore leaves the real key reachable whenever
// HEIMDALL_HOME is set in the environment. It is unset on the current host, which
// makes a HOME-only sandbox look sufficient when it is not. Setting both closes
// that gap by construction.
//
// THREAD SAFETY: `os.set_env` mutates the whole process, so this sandbox isolates
// only while it is the only one open. Every call site therefore holds
// `bridge_test_config_mutex` OUTERMOST — before `keystore_test_mutex` — which is
// the same lock the ~29 other env-mutating tests take and the same ordering
// established for HEIMDALL_VAULT_KEY in iss_18db48473fc5cb6d. No second, disjoint
// lock is introduced: two disjoint locks exclude nobody. The temp dir is also
// unique per open, so two sandboxes can never collide even if that discipline is
// broken later. Model for the set-and-restore shape: src/ctl/vault_test.odin:17-141.
//
// Package-visible, not file-private, because vault_decrypt_test.odin uses it too —
// the same cross-file sharing the test mutexes already rely on (keystore_test_mutex
// is declared in vault_decrypt_test.odin and taken here).
Bridge_Vault_Test_Sandbox :: struct {
	dir:               string,

	// Capture PRESENCE, not just value: restoring an absent variable as "" would
	// turn "unset" into "set but empty" for every sibling test that follows.
	prev_home:         string,
	had_home:          bool,
	prev_hd_home:      string,
	had_hd_home:       bool,

	// `redirected` gates the env restore: a sandbox that failed BEFORE capturing
	// the previous values must not "restore" them, or it would unset the real
	// HOME. `closed` makes close() idempotent, because a failing open() closes
	// what it already built and the caller's `defer` then closes it again.
	redirected:        bool,
	closed:            bool,
}

bridge_vault_test_sandbox_counter: int

// Fails the test if a `vault_key.sec_test_bak` left behind by the pre-fix code is
// still sitting in the operator's real config dir. The sandbox below never creates
// such a file, so one can only be a stranded credential from a run that died
// before its `defer` — exactly the state the old helper silently ignored and then
// made permanent. Reported, never touched: restoring it is an operator decision,
// because the live `vault_key` beside it may since have been legitimately replaced.
bridge_vault_test_report_stale_backup :: proc(t: ^testing.T) {
	// `bridge_expand_home` returns its INPUT unchanged when HOME is empty or unset,
	// so the result is only heap-allocated when expansion actually happened. Freeing
	// it unconditionally frees a string literal -> `free(): invalid pointer`. This
	// runs BEFORE the redirect below, so HOME here is whatever the environment
	// happens to hold. Guarded exactly as bridge_shell_session.odin:1032 and
	// shell_reconcile.odin:174 do for the same hazard.
	bak_rel := "~/.config/heimdall/vault_key.sec_test_bak"
	bak := bridge_expand_home(bak_rel)
	defer if raw_data(bak) != raw_data(bak_rel) do delete(bak)
	if os.exists(bak) {
		testing.expect(
			t,
			false,
			fmt.tprintf(
				"stale %s found: a previous suite run died before restoring the operator's vault key. "+
				"Do NOT delete it — it may be the only copy. Have an operator verify "+
				"`ham-ctl vault status` reports configured:true and then remove or restore it by hand.",
				bak,
			),
		)
	}
}

// Redirects the vault key path into a fresh temp dir. ALWAYS pair with
// `defer bridge_vault_test_sandbox_close(&sb)` so the redirect is undone on the
// assertion-failure path too — a leaked redirect would silently corrupt every
// sibling test that runs after it.
//
// FAILS CLOSED. Returns `ok = false` if the redirect could not be established or
// did not take effect, having already torn itself back down. Callers MUST bail:
//
//	sb, ok := bridge_vault_test_sandbox_open(t, "label")
//	defer bridge_vault_test_sandbox_close(&sb)
//	if !ok do return
//
// This is not defensive decoration. `testing.expect` logs and RETURNS rather than
// aborting, so an earlier version that merely reported the mismatch went on to run
// the test body against the operator's real key path — and
// `test_bridge_read_vault_key_from_disk` opens that path `O_TRUNC`. Failing open
// here would have been strictly worse than the pre-fix code it replaced, which at
// least left a recoverable `.sec_test_bak`.
bridge_vault_test_sandbox_open :: proc(t: ^testing.T, label: string) -> (sb: Bridge_Vault_Test_Sandbox, ok: bool) {
	// Check the REAL config dir before the redirect makes it unreachable.
	bridge_vault_test_report_stale_backup(t)

	// pid-qualified and atomically counted: unique even across concurrent opens.
	n := sync.atomic_add(&bridge_vault_test_sandbox_counter, 1)
	sb.dir = fmt.aprintf("/tmp/heimdall-bridge-vault-test-%s-%d-%d", label, int(posix.getpid()), n)

	// Nothing is redirected yet, so these two failures return WITHOUT closing:
	// close() would see `redirected == false` and skip the env restore anyway, but
	// returning directly keeps the "no env touched, nothing to undo" path obvious.
	if derr := os.make_directory_all(sb.dir); derr != nil {
		testing.expect(
			t,
			false,
			fmt.tprintf("sandbox dir %s could not be created (%v) — refusing to run", sb.dir, derr),
		)
		return sb, false
	}

	// Pre-create the config dir the key file lives in, so a test that READS before
	// anything writes behaves the same as one that writes first.
	cfg_dir := fmt.aprintf("%s/.config/heimdall", sb.dir)
	defer delete(cfg_dir)
	if derr := os.make_directory_all(cfg_dir); derr != nil {
		testing.expect(
			t,
			false,
			fmt.tprintf("sandbox config dir %s could not be created (%v) — refusing to run", cfg_dir, derr),
		)
		return sb, false
	}

	sb.prev_home, sb.had_home = os.lookup_env("HOME", context.allocator)
	sb.prev_hd_home, sb.had_hd_home = os.lookup_env("HEIMDALL_HOME", context.allocator)

	// Past this line the process environment is mutated, so EVERY failure path
	// below must go through close() to put it back.
	sb.redirected = true

	// A failed `setenv` is precisely how this fails open: the resolvers would keep
	// returning the operator's real path while the test believed it was sandboxed.
	// Never discard these.
	home_err := os.set_env("HOME", sb.dir)
	hd_home_err := os.set_env("HEIMDALL_HOME", sb.dir)
	if home_err != nil || hd_home_err != nil {
		testing.expect(
			t,
			false,
			fmt.tprintf(
				"could not redirect HOME/HEIMDALL_HOME into %s (HOME=%v HEIMDALL_HOME=%v) — refusing to run",
				sb.dir,
				home_err,
				hd_home_err,
			),
		)
		bridge_vault_test_sandbox_close(&sb)
		return sb, false
	}

	// The sandbox is only real if the path actually landed inside it. Both
	// resolvers are checked, since the two differ in precedence and a regression in
	// either one would silently re-expose the operator's key.
	key_rel := "~/.config/heimdall/vault_key"
	bridge_path := bridge_expand_home(key_rel)
	defer if raw_data(bridge_path) != raw_data(key_rel) do delete(bridge_path)
	cfg_path := cfg_lib.expand_home(key_rel)
	defer if raw_data(cfg_path) != raw_data(key_rel) do delete(cfg_path)
	if !strings.has_prefix(bridge_path, sb.dir) || !strings.has_prefix(cfg_path, sb.dir) {
		// `testing.expect` LOGS AND RETURNS — it does not abort (core/testing:110-119).
		// Reporting the mismatch and falling through to `return sb` would run the
		// test body with the operator's real key path live, and
		// `test_bridge_read_vault_key_from_disk` would then O_TRUNC it. Tear the
		// sandbox down and make the caller bail instead.
		testing.expect(
			t,
			false,
			fmt.tprintf(
				"vault key path must resolve inside the sandbox %s, got bridge_expand_home=%s cfg_lib.expand_home=%s — refusing to run",
				sb.dir,
				bridge_path,
				cfg_path,
			),
		)
		bridge_vault_test_sandbox_close(&sb)
		return sb, false
	}
	return sb, true
}

// Restores both variables to exactly the state they were in — re-set if they were
// present, unset if they were absent — then removes the temp dir.
bridge_vault_test_sandbox_close :: proc(sb: ^Bridge_Vault_Test_Sandbox) {
	// Idempotent: a failing open() closes what it already built, and the caller's
	// `defer bridge_vault_test_sandbox_close(&sb)` then closes it a second time.
	// Without this guard that second call would double-free the captured values.
	if sb.closed do return
	sb.closed = true

	// Only restore if we actually got as far as capturing the previous values.
	// Otherwise `had_home == false` would be read as "HOME was absent" and we
	// would UNSET the operator's real HOME on a failure path.
	if sb.redirected {
		if sb.had_home {
			_ = os.set_env("HOME", sb.prev_home)
		} else {
			os.unset_env("HOME")
		}
		delete(sb.prev_home)
		sb.prev_home = ""

		if sb.had_hd_home {
			_ = os.set_env("HEIMDALL_HOME", sb.prev_hd_home)
		} else {
			os.unset_env("HEIMDALL_HOME")
		}
		delete(sb.prev_hd_home)
		sb.prev_hd_home = ""

		sb.redirected = false
	}

	if sb.dir != "" {
		// Surfaced, not swallowed: a sandbox that silently fails to clean up is how
		// /tmp accumulates one directory per test per run without anyone noticing.
		if rerr := os.remove_all(sb.dir); rerr != nil {
			fmt.eprintfln("WARN: sandbox temp dir %s was not removed: %v", sb.dir, rerr)
		}
		delete(sb.dir)
		sb.dir = ""
	}
}

@(private = "file")
create_sec_test_envelope :: proc(
	bridge_id: string,
	bridge_pub_hex: string,
	vault_key_hex: string,
	timestamp: i64,
	nonce: string,
	tamper_aad: bool = false,
) -> string {
	client_priv: ecdh.Private_Key
	_ = ecdh.private_key_generate(&client_priv, .SECP256R1)
	defer ecdh.private_key_clear(&client_priv)

	client_pub: ecdh.Public_Key
	ecdh.public_key_set_priv(&client_pub, &client_priv)
	client_pub_bytes: [P256_POINT_SIZE]byte
	ecdh.public_key_bytes(&client_pub, client_pub_bytes[:])
	client_pub_hex_bytes, _ := hex.encode(client_pub_bytes[:], context.temp_allocator)
	client_pub_hex := string(client_pub_hex_bytes)

	bridge_pub_bytes, _ := hex.decode(transmute([]byte)bridge_pub_hex, context.temp_allocator)
	bridge_pub: ecdh.Public_Key
	_ = ecdh.public_key_set_bytes(&bridge_pub, .SECP256R1, bridge_pub_bytes)

	shared_secret: [P256_COORD_SIZE]byte
	_ = ecdh.ecdh(&client_priv, &bridge_pub, shared_secret[:])
	defer crypto.zero_explicit(&shared_secret, size_of(shared_secret))

	salt: [32]byte
	info := "heimdall-bridge-unseal-v1"
	aes_key: [32]byte
	defer crypto.zero_explicit(&aes_key, size_of(aes_key))
	hkdf.extract_and_expand(.SHA256, salt[:], shared_secret[:], transmute([]byte)info, aes_key[:])

	iv: [12]byte
	crypto.rand_bytes(iv[:])
	iv_hex_bytes, _ := hex.encode(iv[:], context.temp_allocator)

	aad := fmt.tprintf("%s:%d:%s", bridge_id, timestamp, nonce)
	if tamper_aad {
		aad = fmt.tprintf("%s:%d:%s_tampered", bridge_id, timestamp, nonce)
	}

	plaintext := transmute([]byte)vault_key_hex
	ciphertext := make([]byte, len(plaintext), context.temp_allocator)
	tag: [16]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, aes_key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ciphertext, tag[:], iv[:], transmute([]byte)aad, plaintext)

	ct_hex_bytes, _ := hex.encode(ciphertext, context.temp_allocator)
	tag_hex_bytes, _ := hex.encode(tag[:], context.temp_allocator)

	return fmt.aprintf(
		`{{"type":"bridge_unseal","command_id":"cmd_sec_test","bridge_id":"%s","timestamp":%d,"nonce":"%s","client_public_key":"%s","iv":"%s","tag":"%s","ciphertext":"%s"}}`,
		bridge_id, timestamp, nonce, client_pub_hex, string(iv_hex_bytes), string(tag_hex_bytes), string(ct_hex_bytes),
	)
}

@(test)
test_security_unseal_transitions_locked_to_unlocked :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "lifecycle")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	bridge_workspace_vault_configured = true
	defer { bridge_workspace_vault_configured = false }

	// bridge_vault_status / bridge_read_vault_key resolve the running bridge's own key.
	own_id, _ := keystore_test_bridge_ids()
	prev_daemon_id := keystore_test_set_daemon_id(own_id)
	defer bridge_config.daemon_id = prev_daemon_id

	bridge_vault_lock()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	// A successful unseal persists the key under bridge_id: test-only (REQ-T5-4).
	bridge_id, _ := keystore_test_bridge_ids()
	defer keystore_lock_and_purge(bridge_id)
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "nonce_sec_lifecycle_1")
	defer delete(payload)

	// Unseal call
	ok, err_msg := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok, fmt.tprintf("unseal must succeed: %s", err_msg))

	// Status transitions from Locked to Unlocked
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)
	testing.expect_value(t, bridge_vault_status_string(), "unlocked")

	// Decrypted key must match stored key
	stored_key, read_ok := bridge_read_vault_key()
	testing.expect(t, read_ok, "bridge_read_vault_key must succeed after unseal")
	defer if read_ok do delete(stored_key)
	testing.expect_value(t, stored_key, test_key)
}

@(test)
test_security_anti_replay_duplicate_nonce_rejected :: proc(t: ^testing.T) {
	// The vault sandbox mutates HOME / HEIMDALL_HOME, which are PROCESS-GLOBALS.
	// keystore_test_mutex alone does not serialise this test against the ~29
	// env-mutating tests that hold bridge_test_config_mutex instead - two disjoint
	// locks exclude nobody (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "replay")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	// A successful unseal persists the key under bridge_id: test-only (REQ-T5-4).
	bridge_id, _ := keystore_test_bridge_ids()
	defer keystore_lock_and_purge(bridge_id)
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_duplicate_nonce_xyz")
	defer delete(payload)

	// First attempt succeeds
	ok1, err1 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok1, fmt.tprintf("first unseal must succeed: %s", err1))

	// Replay attempt with same nonce must be rejected
	ok2, err2 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms + 150)
	testing.expect(t, !ok2, "replayed unseal payload with duplicate nonce must be rejected")
	testing.expect(t, strings.contains(err2, "replay rejected"), "error must cite replay rejection")
}

@(test)
test_security_clock_skew_validation_rejects_stale_and_future :: proc(t: ^testing.T) {
	// The vault sandbox mutates HOME / HEIMDALL_HOME, which are PROCESS-GLOBALS.
	// keystore_test_mutex alone does not serialise this test against the ~29
	// env-mutating tests that hold bridge_test_config_mutex instead - two disjoint
	// locks exclude nobody (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "skew")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	// A successful unseal persists the key under bridge_id: test-only (REQ-T5-4).
	bridge_id, _ := keystore_test_bridge_ids()
	defer keystore_lock_and_purge(bridge_id)
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. Expired in past (> 30s)
	past_ts := now_ms - 35_000
	payload_past := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, past_ts, "sec_skew_past_nonce")
	defer delete(payload_past)
	ok_past, err_past := bridge_unseal_decrypt_and_verify(payload_past, bridge_id, now_ms)
	testing.expect(t, !ok_past, "past clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_past, "clock skew"), "error must cite clock skew")

	// 2. Future skew (> 30s)
	future_ts := now_ms + 35_000
	payload_future := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, future_ts, "sec_skew_future_nonce")
	defer delete(payload_future)
	ok_future, err_future := bridge_unseal_decrypt_and_verify(payload_future, bridge_id, now_ms)
	testing.expect(t, !ok_future, "future clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_future, "clock skew"), "error must cite clock skew")

	// 3. Valid timestamp within 30s window (e.g. 5s in past)
	valid_ts := now_ms - 5_000
	payload_valid := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, valid_ts, "sec_skew_valid_nonce")
	defer delete(payload_valid)
	ok_valid, err_valid := bridge_unseal_decrypt_and_verify(payload_valid, bridge_id, now_ms)
	testing.expect(t, ok_valid, fmt.tprintf("timestamp within 30s must be accepted: %s", err_valid))
}

@(test)
test_security_wrong_destination_mismatched_bridge_id_rejected :: proc(t: ^testing.T) {
	// The vault sandbox mutates HOME / HEIMDALL_HOME, which are PROCESS-GLOBALS.
	// keystore_test_mutex alone does not serialise this test against the ~29
	// env-mutating tests that hold bridge_test_config_mutex instead - two disjoint
	// locks exclude nobody (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "dest")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// Envelope created specifically for target bridge "brg_target_alpha"
	payload_dest := create_sec_test_envelope("brg_target_alpha", bridge_pub_hex, test_key, now_ms, "sec_dest_nonce")
	defer delete(payload_dest)

	// Delivered to mismatched bridge "brg_target_beta"
	ok, err := bridge_unseal_decrypt_and_verify(payload_dest, "brg_target_beta", now_ms)
	testing.expect(t, !ok, "payload with mismatched bridge destination must be rejected")
	testing.expect(t, strings.contains(err, "cross-bridge replay rejected"), "error must cite cross-bridge destination mismatch")
}

@(test)
test_security_tampering_timestamp_or_ciphertext_tag_failure :: proc(t: ^testing.T) {
	// The vault sandbox mutates HOME / HEIMDALL_HOME, which are PROCESS-GLOBALS.
	// keystore_test_mutex alone does not serialise this test against the ~29
	// env-mutating tests that hold bridge_test_config_mutex instead - two disjoint
	// locks exclude nobody (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "tamper")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	// A successful unseal persists the key under bridge_id: test-only (REQ-T5-4).
	bridge_id, _ := keystore_test_bridge_ids()
	defer keystore_lock_and_purge(bridge_id)
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. AAD tampering (tampered AAD at creation time)
	payload_aad_tamper := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_aad_unique_nonce", true)
	defer delete(payload_aad_tamper)
	ok_aad, err_aad := bridge_unseal_decrypt_and_verify(payload_aad_tamper, bridge_id, now_ms)
	testing.expect(t, !ok_aad, "tampered AAD must fail AEAD tag verification")
	testing.expect(t, strings.contains(err_aad, "AEAD tag verification failed"), "must cite AEAD tag failure")

	// 2. Wire timestamp mutation tampering (mutating wire timestamp causes computed AAD to mismatch encrypted AAD)
	payload_valid_ts := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_ts_unique_nonce")
	defer delete(payload_valid_ts)
	mutated_ts_payload, _ := strings.replace(payload_valid_ts, fmt.tprintf(`"timestamp":%d`, now_ms), fmt.tprintf(`"timestamp":%d`, now_ms + 1000), 1)
	defer delete(mutated_ts_payload)
	ok_ts, err_ts := bridge_unseal_decrypt_and_verify(mutated_ts_payload, bridge_id, now_ms)
	testing.expect(t, !ok_ts, "mutated wire timestamp must cause AEAD tag mismatch")
	testing.expect(t, strings.contains(err_ts, "AEAD tag verification failed"), "must cite AEAD tag failure on mutated timestamp")

	// 3. Ciphertext corruption tampering
	payload_valid_ct := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_ct_unique_nonce")
	defer delete(payload_valid_ct)
	corrupted_ct_payload, _ := strings.replace(payload_valid_ct, `"ciphertext":"`, `"ciphertext":"0000`, 1)
	defer delete(corrupted_ct_payload)
	ok_ct, err_ct := bridge_unseal_decrypt_and_verify(corrupted_ct_payload, bridge_id, now_ms)
	testing.expect(t, !ok_ct, "corrupted ciphertext must fail AEAD tag verification")
	testing.expect(t, strings.contains(err_ct, "AEAD tag verification failed"), "must cite AEAD tag failure on corrupted ciphertext")
}

@(test)
test_security_self_hosted_unconfigured_executes_unencrypted_without_errors :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "selfhosted")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	bridge_vault_lock()
	defer bridge_vault_lock()

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	// Unconfigured self-hosted workspace
	bridge_workspace_vault_configured = false
	defer { bridge_workspace_vault_configured = false }

	// 1. Vault status must report Disabled
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
	testing.expect_value(t, bridge_vault_status_string(), "disabled")

	// 2. Filesystem operations run unencrypted without errors or blocking
	test_filename := "heimdall_selfhosted_test_file.txt"
	test_content := "Plaintext Unencrypted Content for Self-Hosted Mode"
	tmp_dir := "/tmp"

	write_res := bridge_fs_write_file(test_filename, test_content, tmp_dir)
	testing.expect(t, write_res.ok, "fs_write_file must succeed when vault is Disabled")

	read_res := bridge_fs_read_file(test_filename, tmp_dir, 0, 100)
	testing.expect(t, read_res.ok, "fs_read_file must succeed when vault is Disabled")
	testing.expect_value(t, read_res.content, test_content)
	testing.expect(t, !strings.has_prefix(read_res.content, VAULT_ARMOR_PREFIX), "content must NOT be vault-armored")
	defer delete(read_res.content)

	// Clean up created test file
	full_path := fmt.tprintf("%s/%s", tmp_dir, test_filename)
	_ = os.remove(full_path)

	// 3. Shell streaming emits unarmored base64 without delay or locked banner
	stream_data := transmute([]byte)string("echo Hello Self-Hosted World\n")
	bridge_pty_stream_emit_frame(nil, "sh_selfhosted_disabled_01", stream_data)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect(t, len(frames) > 0, "stream frame must be emitted")
	if len(frames) > 0 {
		first_frame := frames[0]
		testing.expect(t, !strings.contains(first_frame, "Vault locked"), "must not emit locked warning banner")
		testing.expect(t, !strings.contains(first_frame, VAULT_ARMOR_PREFIX), "must not emit vault:v1: armored data")
		testing.expect(t, strings.contains(first_frame, `"data_b64":"`), "must emit plaintext data_b64 frame")
	}
}

// Package-visible so other suites (vault_configured_marker_test.odin) can drive
// the real hub `bridge_unseal` frame instead of duplicating the sealing code.
test_create_unseal_envelope :: proc(
	bridge_id: string,
	bridge_pub_hex: string,
	vault_key_hex: string,
	timestamp: i64,
	nonce: string,
	tamper_aad: bool = false,
) -> string {
	return create_sec_test_envelope(bridge_id, bridge_pub_hex, vault_key_hex, timestamp, nonce, tamper_aad)
}

@(test)
test_unseal_protocol_sliding_nonce_cache :: proc(t: ^testing.T) {
	cache: Unseal_Nonce_Cache
	unseal_nonce_cache_clear(&cache)

	now: i64 = 1_000_000

	// Insert nonce 1
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now), "first insert of nonce_1 must succeed")
	// Replay nonce 1
	testing.expect(t, !unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now + 1000), "replay of nonce_1 must fail")

	// Insert nonce 2
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_2", now + 2000), "insert of nonce_2 must succeed")

	// Nonce 1 after TTL (> 60s) can be re-inserted because old entry expired
	testing.expect(t, unseal_nonce_cache_check_and_insert(&cache, "nonce_1", now + UNSEAL_NONCE_TTL_MS + 1000), "nonce_1 after TTL expiry should succeed")

	unseal_nonce_cache_clear(&cache)
}
