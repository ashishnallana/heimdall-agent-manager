package main

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import ws "odin_test:lib/ws"

// T9 (REQ-T9-1..3): a LOCKED bridge fails closed. Before the fix the shell_start gate
// was keyed on "a key is present", so a configured bridge with no key in hand was
// treated as never-configured and ran the hub-supplied plaintext cmd.
//
// Every test here runs inside bridge_vault_test_sandbox_open (temp HOME, so the
// vault_configured marker lands in /tmp) and points bridge_config.daemon_id at this
// process's keystore_test_bridge_ids() id, so no real bridge's keyring or marker is
// touched. Locked is produced the way a real restart produces it: the on-disk marker
// is present and the in-memory flag is cleared, so only the marker says "configured".

@(private = "file")
Vault_Gate_Fixture :: struct {
	sb:              Bridge_Vault_Test_Sandbox,
	prev_daemon_id:  string,
	prev_key:        string,
	had_key:         bool,
	prev_configured: string,
	had_configured:  bool,
	saved_flag:      bool,
	bridge_id:       string,
}

// Caller holds bridge_test_config_mutex then keystore_test_mutex (the order the
// vault_decrypt tests use) and must call fixture_close on every path.
@(private = "file")
fixture_open :: proc(t: ^testing.T, label: string, marker: bool, key: string) -> (f: Vault_Gate_Fixture, ok: bool) {
	id_a, _ := keystore_test_bridge_ids()
	f.bridge_id = id_a
	f.prev_daemon_id = keystore_test_set_daemon_id(id_a)
	keystore_lock_and_purge(id_a)
	f.saved_flag = bridge_workspace_vault_configured
	f.prev_key, f.had_key = os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	f.prev_configured, f.had_configured = os.lookup_env("HEIMDALL_VAULT_CONFIGURED", context.allocator)
	os.unset_env("HEIMDALL_VAULT_KEY")
	os.unset_env("HEIMDALL_VAULT_CONFIGURED")

	f.sb, ok = bridge_vault_test_sandbox_open(t, label)
	if !ok do return

	if marker {
		testing.expect(t, bridge_vault_set_configured(id_a, true), "marker written into the sandbox")
		path, _ := bridge_vault_configured_marker_path(id_a, context.temp_allocator)
		testing.expect(t, strings.has_prefix(path, f.sb.dir), "marker path is inside the sandbox")
		testing.expect(t, os.exists(path), "marker present on disk")
	}
	// Only the marker (or its absence) decides "configured" from here on.
	bridge_workspace_vault_configured = false
	if key != "" do _ = os.set_env("HEIMDALL_VAULT_KEY", key)
	return f, true
}

@(private = "file")
fixture_close :: proc(f: ^Vault_Gate_Fixture) {
	// Marker removal while HOME still points into the sandbox, then the sandbox
	// removal takes the rest.
	_ = bridge_vault_set_configured(f.bridge_id, false)
	bridge_vault_test_sandbox_close(&f.sb)
	bridge_workspace_vault_configured = f.saved_flag
	if f.had_key { _ = os.set_env("HEIMDALL_VAULT_KEY", f.prev_key); delete(f.prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEY") }
	if f.had_configured { _ = os.set_env("HEIMDALL_VAULT_CONFIGURED", f.prev_configured); delete(f.prev_configured) } else { os.unset_env("HEIMDALL_VAULT_CONFIGURED") }
	keystore_lock_and_purge(f.bridge_id)
	bridge_config.daemon_id = f.prev_daemon_id
}

@(private = "file")
fake_ws :: proc() -> (conn: ws.Connection, read_fd: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK do return {}, -1, false
	return ws.Connection{connected = true, socket = net.TCP_Socket(fds[1])}, fds[0], true
}

@(private = "file")
read_reply :: proc(fd: posix.FD) -> string {
	buf: [4096]byte
	n := posix.read(fd, &buf[0], len(buf))
	if n <= 0 do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private = "file")
run_shell_start :: proc(t: ^testing.T, cmd_json: string) -> string {
	conn, read_fd, ok := fake_ws()
	testing.expect(t, ok, "fake ws connection created")
	if !ok do return ""
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))
	bridge_hub_handle_shell_start(&conn, cmd_json)
	return read_reply(read_fd)
}

// (a) marker present + no key + plaintext cmd -> refused, nothing executed.
@(test)
test_t9_locked_shell_start_refuses_plaintext_cmd :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_a", true, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	canary := fmt.tprintf("%s/t9_pwned", f.sb.dir)
	reply := run_shell_start(t, fmt.tprintf(
		`{{"type":"shell_start","session_id":"sh_t9_a","command_id":"cmd_t9_a","kind":"run","cmd":"touch %s","cwd":"%s"}}`,
		canary, f.sb.dir,
	))
	testing.expect(t, strings.contains(reply, `"cause":"vault_locked"`), fmt.tprintf("must refuse with vault_locked, got %q", reply))
	testing.expect(t, strings.contains(reply, "unauthorized: vault locked"), "must carry the locked reason")
	testing.expect(t, !os.exists(canary), "the plaintext cmd must never run on a locked bridge")
}

// (b) marker present + no key + enc_spec -> vault_locked, not a fall-through to plaintext.
@(test)
test_t9_locked_shell_start_refuses_enc_spec :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_b", true, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	canary := fmt.tprintf("%s/t9_enc", f.sb.dir)
	spec := fmt.tprintf(`{{"cmd":"touch %s","cwd":"%s","timestamp":%d,"nonce":"n_t9_b"}}`, canary, f.sb.dir, bridge_now_unix_ms())
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(spec, TEST_ENC_VAULT_KEY)
	testing.expect(t, enc_ok, "enc_spec built")
	defer delete(armored)

	// A plaintext cmd rides alongside: whatever happens, it must not be what runs.
	reply := run_shell_start(t, fmt.tprintf(
		`{{"type":"shell_start","session_id":"sh_t9_b","command_id":"cmd_t9_b","kind":"run","cmd":"touch %s","cwd":"%s","enc_spec":"%s"}}`,
		canary, f.sb.dir, armored,
	))
	testing.expect(t, strings.contains(reply, `"cause":"vault_locked"`), fmt.tprintf("must refuse with vault_locked, got %q", reply))
	testing.expect(t, !os.exists(canary), "nothing executed")
}

// (c) marker absent + no key + plaintext -> Disabled lets plaintext through the vault
// gate. Proven daemon-free: the request carries a cwd that does not exist, so the
// first refusal AFTER the gate (REQ-SHELL-20's cwd check) is what answers. Reaching it
// at all means the vault gate passed the plaintext request on.
@(test)
test_t9_disabled_shell_start_allows_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_c", false, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)

	missing_cwd := fmt.tprintf("%s/does_not_exist", f.sb.dir)
	reply := run_shell_start(t, fmt.tprintf(
		`{{"type":"shell_start","session_id":"sh_t9_c","command_id":"cmd_t9_c","kind":"run","cmd":"echo ok","cwd":"%s"}}`,
		missing_cwd,
	))
	testing.expect(t, reply != "", "a reply was sent")
	testing.expect(t, !strings.contains(reply, "vault_locked"), fmt.tprintf("Disabled must not be treated as locked, got %q", reply))
	testing.expect(t, !strings.contains(reply, "invalid_vault_key"), fmt.tprintf("Disabled must not demand an enc_spec, got %q", reply))
	testing.expect(t, strings.contains(reply, "does_not_exist"), fmt.tprintf("the post-gate cwd refusal must be what answers, got %q", reply))
}

// (d) key present + no enc_spec -> refused (existing behaviour preserved), even with
// the marker present (Unlocked wins over the marker).
@(test)
test_t9_unlocked_shell_start_still_requires_enc_spec :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_d", true, TEST_ENC_VAULT_KEY)
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)

	canary := fmt.tprintf("%s/t9_unlocked", f.sb.dir)
	reply := run_shell_start(t, fmt.tprintf(
		`{{"type":"shell_start","session_id":"sh_t9_d","command_id":"cmd_t9_d","kind":"run","cmd":"touch %s","cwd":"%s"}}`,
		canary, f.sb.dir,
	))
	testing.expect(t, strings.contains(reply, `"cause":"invalid_vault_key"`), fmt.tprintf("must refuse with invalid_vault_key, got %q", reply))
	testing.expect(t, !os.exists(canary), "nothing executed")
}

// PTY input on a locked bridge is dropped whatever the payload claims: plaintext
// (is_encrypted=false) used to be the only shape the old gate refused for Locked,
// and an encrypted one cannot be decrypted. Both must fail.
@(test)
test_t9_locked_shell_pty_input_is_dropped :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_pty", true, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	// "echo hi\n" base64
	bridge_hub_handle_shell_pty_input(nil, `{"type":"shell_pty_input","command_id":"cmd_t9_pty_plain","shell_id":"sh_t9_pty","data_b64":"ZWNobyBoaQo=","is_encrypted":false}`)
	res, res_ok := bridge_runtime_cached_command("cmd_t9_pty_plain")
	testing.expect(t, res_ok, "result recorded")
	testing.expect(t, strings.contains(res, `"failed"`), fmt.tprintf("plaintext input must be dropped when locked, got %q", res))

	enc_b64, enc_ok := bridge_pty_stream_encrypt_chunk(transmute([]byte)string("echo hi\n"), [4]byte{9, 9, 9, 9}, 1, TEST_ENC_VAULT_KEY, context.temp_allocator)
	testing.expect(t, enc_ok, "chunk encrypted")
	bridge_hub_handle_shell_pty_input(nil, fmt.tprintf(`{{"type":"shell_pty_input","command_id":"cmd_t9_pty_enc","shell_id":"sh_t9_pty","data_b64":"%s","is_encrypted":true}}`, enc_b64))
	res2, res2_ok := bridge_runtime_cached_command("cmd_t9_pty_enc")
	testing.expect(t, res2_ok, "result recorded")
	testing.expect(t, strings.contains(res2, `"failed"`), fmt.tprintf("encrypted input must be dropped when locked, got %q", res2))
}

// shell_restart re-executes a stored cmd on the hub's say-so; a locked bridge refuses
// it before touching the daemon.
@(test)
test_t9_locked_shell_restart_is_refused :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t9_restart", true, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	canary := fmt.tprintf("%s/t9_restarted", f.sb.dir)
	map_heap := bridge_shell_session_map_allocator(&bridge_shell_session_map)
	sess := Bridge_Shell_Session{
		session_id = strings.clone("sh_t9_restart", map_heap),
		kind       = .Run,
		cmd        = strings.clone(fmt.tprintf("touch %s", canary), map_heap),
		cwd        = strings.clone(f.sb.dir, map_heap),
		bridge_id  = strings.clone(f.bridge_id, map_heap),
		status     = .Exited,
		shell_id   = strings.clone("sh_t9_restart", map_heap),
	}
	bridge_shell_session_register(&bridge_shell_session_map, &sess) // CONSUMES sess
	testing.expect(t, bridge_shell_session_exists(&bridge_shell_session_map, "sh_t9_restart"), "session registered, so a refusal is the vault gate and not 'unknown session'")

	conn, read_fd, ws_ok := fake_ws()
	testing.expect(t, ws_ok, "fake ws connection created")
	if !ws_ok do return
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))
	bridge_hub_handle_shell_restart(&conn, `{"type":"shell_restart","session_id":"sh_t9_restart","command_id":"cmd_t9_restart","run_seq":1}`)
	reply := read_reply(read_fd)
	testing.expect(t, strings.contains(reply, `"ok":false`), fmt.tprintf("restart must be refused when locked, got %q", reply))
	testing.expect(t, strings.contains(reply, `"cause":"vault_locked"`), fmt.tprintf("T10: restart refusal must name vault_locked, got %q", reply))
	testing.expect(t, !os.exists(canary), "the stored cmd must not be re-executed")
}

// ---------------------------------------------------------------------------
// T10 (REQ-T10-1/3): agent-pane input and the typed `vault_locked` signal.
// ---------------------------------------------------------------------------

// read_all drains whatever the handler wrote to the fake socket. The hub-send
// framing is a websocket frame per message, so frames are matched by substring.
@(private = "file")
read_all :: proc(fd: posix.FD) -> string {
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]byte
	for {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 50) <= 0 do break
		n := posix.read(fd, &buf[0], len(buf))
		if n <= 0 do break
		strings.write_string(&b, string(buf[:n]))
	}
	return strings.to_string(b)
}

// The legacy agent_pty_input type (plaintext `data`, no encrypted form) was accepted in
// every vault state. Locked must answer vault_locked, send the typed stream frame, and
// never deliver.
@(test)
test_t10_locked_agent_pty_input_is_refused_with_vault_locked :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t10_agent_locked", true, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	conn, read_fd, ws_ok := fake_ws()
	testing.expect(t, ws_ok, "fake ws connection created")
	if !ws_ok do return
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	bridge_hub_handle_agent_pty_input(&conn, `{"type":"agent_pty_input","command_id":"cmd_t10_agent_locked","agent_instance_id":"inst_t10","data":"rm -rf /\n"}`)
	res, res_ok := bridge_runtime_cached_command("cmd_t10_agent_locked")
	testing.expect(t, res_ok, "result recorded")
	testing.expect(t, strings.contains(res, `"status":"failed"`), fmt.tprintf("locked agent input must fail, got %q", res))
	testing.expect(t, strings.contains(res, `"cause":"vault_locked"`), fmt.tprintf("locked agent input must carry vault_locked, got %q", res))

	wire := read_all(read_fd)
	testing.expect(t, strings.contains(wire, `"type":"shell_pty_vault_locked"`), fmt.tprintf("typed stream frame sent, got %q", wire))
	testing.expect(t, strings.contains(wire, `"session_id":"inst_t10"`), "frame names the pane")
}

// Unlocked: the legacy type has no encrypted form, so plaintext is refused (encrypted
// input travels as shell_pty_input). Not vault_locked — the vault is open.
@(test)
test_t10_unlocked_agent_pty_input_refuses_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t10_agent_unlocked", true, TEST_ENC_VAULT_KEY)
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)

	bridge_hub_handle_agent_pty_input(nil, `{"type":"agent_pty_input","command_id":"cmd_t10_agent_unlocked","agent_instance_id":"inst_t10","data":"ls\n"}`)
	res, res_ok := bridge_runtime_cached_command("cmd_t10_agent_unlocked")
	testing.expect(t, res_ok, "result recorded")
	testing.expect(t, strings.contains(res, `"status":"failed"`), fmt.tprintf("plaintext on an unlocked vault must fail, got %q", res))
	testing.expect(t, !strings.contains(res, "vault_locked"), fmt.tprintf("an unlocked vault is not locked, got %q", res))
}

// Disabled: plaintext passes the gate. Daemon-free, so delivery itself fails — but with
// a plain "failed" and no vault error code, which is the proof the gate let it through.
@(test)
test_t10_disabled_agent_pty_input_passes_gate :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t10_agent_disabled", false, "")
	defer fixture_close(&f)
	if !ok do return
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)

	bridge_hub_handle_agent_pty_input(nil, `{"type":"agent_pty_input","command_id":"cmd_t10_agent_disabled","agent_instance_id":"inst_t10_none","data":"ls\n"}`)
	res, res_ok := bridge_runtime_cached_command("cmd_t10_agent_disabled")
	testing.expect(t, res_ok, "result recorded")
	testing.expect(t, !strings.contains(res, "vault_locked") && !strings.contains(res, "invalid_vault_key"), fmt.tprintf("Disabled must not be refused by the vault gate, got %q", res))
}

// shell_pty_input (the wire type the current hub uses for BOTH agent and shell panes)
// now names its locked refusal and emits the typed frame.
@(test)
test_t10_locked_shell_pty_input_carries_vault_locked :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t10_shell_locked", true, "")
	defer fixture_close(&f)
	if !ok do return

	conn, read_fd, ws_ok := fake_ws()
	testing.expect(t, ws_ok, "fake ws connection created")
	if !ws_ok do return
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	bridge_hub_handle_shell_pty_input(&conn, `{"type":"shell_pty_input","command_id":"cmd_t10_shell_locked","shell_id":"sh_t10","agent_instance_id":"sh_t10","data_b64":"ZWNobyBoaQo=","is_encrypted":false}`)
	res, res_ok := bridge_runtime_cached_command("cmd_t10_shell_locked")
	testing.expect(t, res_ok, "result recorded")
	testing.expect(t, strings.contains(res, `"cause":"vault_locked"`), fmt.tprintf("locked shell input must carry vault_locked, got %q", res))
	wire := read_all(read_fd)
	testing.expect(t, strings.contains(wire, `"type":"shell_pty_vault_locked"`), fmt.tprintf("typed stream frame sent, got %q", wire))
	testing.expect(t, strings.contains(wire, `"session_id":"sh_t10"`), "frame names the pane")
}

// In-stream: output on a locked bridge queues the scrollback banner AND the typed frame,
// once per lock (the existing latch), so a later chunk does not repeat either.
@(test)
test_t10_locked_emit_frame_queues_typed_vault_locked_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	f, ok := fixture_open(t, "t10_emit_locked", true, "")
	defer fixture_close(&f)
	if !ok do return

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	worker := Bridge_PTY_Stream_Worker{}
	sync.atomic_store(&worker.active, true)
	bridge_pty_stream_emit_frame(&worker, "sh_t10_emit", transmute([]byte)string("secret output\n"))
	bridge_pty_stream_emit_frame(&worker, "sh_t10_emit", transmute([]byte)string("more output\n"))

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for fr in frames do delete(fr, runtime.heap_allocator())
		delete(frames)
	}
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect(t, strings.contains(frames[0], `"type":"shell_pty_output"`), "banner first, for scrollback")
		testing.expect(t, strings.contains(frames[1], `"type":"shell_pty_vault_locked"`), fmt.tprintf("typed frame second, got %q", frames[1]))
		testing.expect(t, strings.contains(frames[1], `"cause":"vault_locked"`), "typed frame carries the code")
	}
}
