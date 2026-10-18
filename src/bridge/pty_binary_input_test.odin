#+build !windows
package main

// REQ-PTY-NET-3 — ack-less binary pty input on the bridge.
//
// A hub->bridge BINARY frame (pty_wire INPUT session frame) is decrypted under the same
// vault gate as the JSON command, delivered to the pty-host in order, and produces NO
// command_result: it carries no command_id, so the result cache is untouched and nothing
// is written back to the hub for it.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"

@(private = "file")
Binary_Input_Mock :: struct {
	listener_fd: posix.FD,
	received:    [dynamic]byte,
	frames:      int,
}

@(private = "file")
_binary_input_mock_run :: proc(raw: rawptr) {
	ctx := (^Binary_Input_Mock)(raw)
	// Every delivery is "ping (liveness probe) then one input connection"; answer the
	// pings, record the inputs, in arrival order.
	for {
		c := posix.accept(ctx.listener_fd, nil, nil)
		if c < 0 do return
		if frame, ok := pty_host_read_frame(c); ok {
			if len(frame) > 0 && frame[0] == PTY_HOST_T_PING {
				pong := [5]byte{0, 0, 0, 1, PTY_HOST_T_PONG}
				_ = pty_host_send_all(c, pong[:])
			} else {
				for b in frame do append(&ctx.received, b)
				ctx.frames += 1
			}
			delete(frame)
		}
		_ = posix.close(c)
	}
}

@(test)
test_binary_pty_input_is_delivered_in_order_without_a_command_result :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer { if had_key { _ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEYRING") } }
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_ENC_VAULT_KEY))

	sock_path := fmt.tprintf("%s/.cache/heimdall-tests/bin-input-%d.sock", os.get_env("HOME", context.temp_allocator), os.get_pid())
	cpath := strings.clone_to_cstring(sock_path, context.temp_allocator)
	_ = posix.unlink(cpath)
	defer _ = posix.unlink(cpath)
	lfd := posix.socket(.UNIX, .STREAM)
	if lfd < 0 { testing.expect(t, false, "unix socket created"); return }
	defer _ = posix.close(lfd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0 ..< len(sock_path) do addr.sun_path[i] = c.char(sock_path[i])
	testing.expect(t, posix.bind(lfd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK, "bind succeeded")
	testing.expect(t, posix.listen(lfd, 8) == .OK, "listen succeeded")

	sync.mutex_lock(&pty_host_daemon_lock)
	prev_sock := pty_host_daemon_socket
	prev_started := pty_host_daemon_started
	pty_host_daemon_socket = sock_path
	pty_host_daemon_started = true
	sync.mutex_unlock(&pty_host_daemon_lock)
	defer {
		sync.mutex_lock(&pty_host_daemon_lock)
		pty_host_daemon_socket = prev_sock
		pty_host_daemon_started = prev_started
		sync.mutex_unlock(&pty_host_daemon_lock)
	}

	mock := Binary_Input_Mock{listener_fd = lfd, received = make([dynamic]byte, runtime.heap_allocator())}
	defer delete(mock.received)
	srv := thread.create_and_start_with_data(&mock, _binary_input_mock_run)

	// Three keystroke chunks, encrypted the way the browser does it (random nonce each).
	chunks := []string{"ls ", "-la", "\n"}
	for chunk, i in chunks {
		sealed, ok := test_pty_input_payload(chunk, TEST_ENC_VAULT_KEY, 1, "sh_bin_input")
		testing.expect(t, ok)
		frame := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT, contracts.pty_wire_flags(false, true), "sh_bin_input", sealed, context.temp_allocator)
		bridge_hub_handle_binary_frame(nil, frame)
	}
	// Plaintext on an UNLOCKED vault is refused (same gate as the JSON command) and never
	// reaches the pty.
	plain := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT, 0, "sh_bin_input", transmute([]byte)string("rm -rf /\n"), context.temp_allocator)
	bridge_hub_handle_binary_frame(nil, plain)
	// Garbage is dropped without touching anything.
	bridge_hub_handle_binary_frame(nil, []byte{0x02, 0x00})

	_ = posix.shutdown(lfd, .RDWR)
	thread.join(srv)
	thread.destroy(srv)

	testing.expect_value(t, mock.frames, 3)
	got := string(mock.received[:])
	i_ls, i_la, i_nl := strings.index(got, "ls "), strings.index(got, "-la"), strings.index(got, "\n")
	testing.expect(t, i_ls >= 0 && i_la > i_ls && i_nl > i_la, fmt.tprintf("pty received the decrypted keystrokes in order, got %q", got))
	testing.expect(t, !strings.contains(string(mock.received[:]), "rm -rf"), "plaintext on an unlocked vault never reaches the pty")
	// No command_result anywhere: the cache saw nothing for this input.
	_, cached := bridge_runtime_cached_command("")
	testing.expect(t, !cached, "an empty command id is never cached")
}
