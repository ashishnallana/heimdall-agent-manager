#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"

// Exercise the real launch entry point against a minimal acknowledged PTY host.
// A duplicate wake must stop at List: no token rotation, bootstrap or Spawn.
@(test)
startup_wake_duplicate_preserves_child_and_stale_or_stopped_is_denied :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	id := "startup_wake_bridge"
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = "startup-wake-token", instance_token = "hit_startup_wake_bridge", role = .Agent, run_count = 4}
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
	append(&bridge_local_token_records, rec)
	sync.mutex_unlock(&bridge_local_token_mutex)
	path := fmt.tprintf("/tmp/ham-startup-wake-%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 4) == .OK) do return
	Server :: struct { listener: posix.FD, pings, lists, unexpected: int }
	server := Server{listener = listener}
	worker := thread.create_and_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for _ in 0..<4 {
			pfd := posix.pollfd{fd = s.listener, events = {.IN}}
			if posix.poll(&pfd, 1, 3000) <= 0 do return
			fd := posix.accept(s.listener, nil, nil)
			if fd < 0 do return
			request, ok := pty_host_read_frame(fd)
			if !ok || len(request) == 0 { posix.close(fd); return }
			payload := make([dynamic]byte)
			switch request[0] {
			case PTY_HOST_T_PING:
				s.pings += 1
				append(&payload, PTY_HOST_T_PONG)
			case PTY_HOST_T_LIST:
				s.lists += 1
				append(&payload, PTY_HOST_T_AGENTLIST)
				pty_host_put_u16(&payload, 1)
				pty_host_put_str(&payload, "startup_wake_bridge")
				pty_host_put_str(&payload, "/fake/provider")
				pty_host_put_i32(&payload, 123)
				append(&payload, 1, 0) // alive, no exit code
				pty_host_put_u16(&payload, 24); pty_host_put_u16(&payload, 80)
				pty_host_put_u64(&payload, 1000); pty_host_put_u64(&payload, 1000)
				append(&payload, 0) // no display name
			case:
				s.unexpected += 1
				append(&payload, PTY_HOST_T_ERROR)
				pty_host_put_str(&payload, "startup_wake_bridge")
				pty_host_put_str(&payload, "unexpected operation")
			}
			reply := pty_host_frame(payload[:])
			_ = pty_host_send_all(fd, reply)
			delete(request); delete(payload); delete(reply)
			posix.close(fd)
		}
	})
	defer thread.destroy(worker)
	sync.mutex_lock(&pty_host_daemon_lock)
	old_socket, old_started := pty_host_daemon_socket, pty_host_daemon_started
	pty_host_daemon_socket, pty_host_daemon_started = path, true
	sync.mutex_unlock(&pty_host_daemon_lock)
	defer {
		sync.mutex_lock(&pty_host_daemon_lock)
		pty_host_daemon_socket, pty_host_daemon_started = old_socket, old_started
		sync.mutex_unlock(&pty_host_daemon_lock)
	}
	command := bridge_wake_launch_command_json("wake", id, "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "", "", run_count = 4)
	defer delete(command)
	for _ in 0..<2 {
		ok, detail, _ := bridge_runtime_launch_agent("wake", command)
		testing.expect(t, ok, detail)
	}
	thread.join(worker)
	testing.expect_value(t, server.pings, 2)
	testing.expect_value(t, server.lists, 2)
	testing.expect_value(t, server.unexpected, 0)
	sync.mutex_lock(&bridge_local_token_mutex)
	testing.expect_value(t, len(bridge_local_token_records), 1)
	testing.expect_value(t, bridge_local_token_records[0].token_hash, rec.token_hash)
	testing.expect_value(t, bridge_local_token_records[0].invalidated_at_unix_ms, 0)
	sync.mutex_unlock(&bridge_local_token_mutex)
	old := bridge_wake_launch_command_json("old", id, "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "", "", run_count = 3)
	defer delete(old)
	ok, detail, _ := bridge_runtime_launch_agent("old", old)
	testing.expect(t, !ok && strings.contains(detail, "superseded"), "delayed old wake cannot replace child")
	bridge_runtime_mark_stop_intent(id)
	ok, detail, _ = bridge_runtime_launch_agent("wake", command)
	testing.expect(t, !ok && strings.contains(detail, "stopped"), "same generation cannot undo stop")
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_records[0].invalidated_at_unix_ms = 1
	sync.mutex_unlock(&bridge_local_token_mutex)
	bridge_runtime_clear_stop_intent(id)
	testing.expect_value(t, bridge_agent_instance_run_count(id), 4)
	ok, detail, _ = bridge_runtime_launch_agent("wake", command)
	testing.expect(t, !ok && strings.contains(detail, "revoked"), "persisted revocation fences retry after bridge restart")
}
