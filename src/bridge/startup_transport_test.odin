#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"

@(test)
startup_transport_requires_matching_host_receipt :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/ham_startup_transport_%d.sock", os.get_pid())
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
	Server :: struct { listener: posix.FD, frames: [4][]byte }
	server := Server{listener = listener}
	defer for frame in server.frames do delete(frame, runtime.heap_allocator())
	worker := thread.create_and_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for i in 0..<4 {
			client := posix.accept(s.listener, nil, nil)
			if client < 0 do return
			frame, ok := pty_host_read_frame(client)
			if ok do s.frames[i] = frame
			// Attempt 0 loses its ack; later requests carry exactly the same bytes.
			if i > 0 {
				payload := make([dynamic]byte)
				if i == 3 {
					append(&payload, PTY_HOST_T_ERROR)
					pty_host_put_str(&payload, "inst_wire")
					pty_host_put_str(&payload, "stale launch")
				} else {
					append(&payload, PTY_HOST_T_STARTUP_INPUT_DONE)
					pty_host_put_str(&payload, "inst_wire")
					pty_host_put_i32(&payload, 42)
					pty_host_put_str(&payload, "launch" if i == 1 else "other-launch")
				}
				reply := pty_host_frame(payload[:])
				_ = pty_host_send_all(client, reply)
				delete(reply); delete(payload)
			}
			posix.close(client)
		}
	})
	defer thread.destroy(worker)
	text := strings.concatenate({BRIDGE_STARTUP_INSTRUCTION, "\r"})
	defer delete(text)
	testing.expect(t, !bridge_startup_deliver_socket(path, "inst_wire", 42, "launch", text), "missing ack remains retryable")
	testing.expect(t, bridge_startup_deliver_socket(path, "inst_wire", 42, "launch", text), "matching host receipt confirms PTY write")
	testing.expect(t, !bridge_startup_deliver_socket(path, "inst_wire", 42, "launch", text), "wrong launch receipt is refused")
	testing.expect(t, !bridge_startup_deliver_socket(path, "inst_wire", 42, "launch", text), "host write error is retryable")
	thread.join(worker)
	for frame in server.frames {
		if !testing.expect(t, len(frame) > 0) do continue
		testing.expect_value(t, frame[0], u8(0x3A))
		off := 1
		instance, iok := pty_host_get_str(frame, &off)
		defer delete(instance)
		pid, pok := pty_host_get_i32(frame, &off)
		key, kok := pty_host_get_str(frame, &off)
		defer delete(key)
		testing.expect(t, iok && pok && kok)
		testing.expect_value(t, instance, "inst_wire")
		testing.expect_value(t, pid, i32(42))
		testing.expect_value(t, key, "launch")
		testing.expect_value(t, string(frame[off:]), text)
	}
}

@(test)
startup_launch_query_rejects_missing_unsupported_and_mismatched_replies :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/ham_startup_launch_query_%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 4) == .OK) do return
	Server :: struct { listener: posix.FD }
	server := Server{listener = listener}
	worker := thread.create_and_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for i in 0..<6 {
			fd := posix.accept(s.listener, nil, nil)
			if fd < 0 do return
			request, ok := pty_host_read_frame(fd)
			if !ok { posix.close(fd); return }
			if i > 0 {
				payload := make([dynamic]byte)
				if i == 1 {
					append(&payload, PTY_HOST_T_ERROR)
					pty_host_put_str(&payload, "inst_query")
					pty_host_put_str(&payload, "unknown control tag")
				} else {
					append(&payload, PTY_HOST_T_STARTUP_LAUNCH_REPLY)
					pty_host_put_str(&payload, "other-instance" if i == 3 else "inst_query")
					pty_host_put_i32(&payload, 0 if i == 4 else 42)
					pty_host_put_str(&payload, "wrong-key" if i == 2 else "launch")
				}
				reply := pty_host_frame(payload[:])
				_ = pty_host_send_all(fd, reply)
				delete(payload); delete(reply)
			}
			delete(request); posix.close(fd)
		}
	})
	defer thread.destroy(worker)
	for _ in 0..<4 {
		pid, ok := bridge_pty_host_startup_launch(path, "inst_query", "launch")
		testing.expect(t, !ok && pid == 0, "missing/old-host/wrong-identity receipt stays retryable")
	}
	pid, ok := bridge_pty_host_startup_launch(path, "inst_query", "launch")
	testing.expect(t, ok && pid == 0, "acknowledged mismatch permits a fresh launch")
	pid, ok = bridge_pty_host_startup_launch(path, "inst_query", "launch")
	testing.expect(t, ok && pid == 42, "only matching child receipt confirms a launch")
	thread.join(worker)
}
