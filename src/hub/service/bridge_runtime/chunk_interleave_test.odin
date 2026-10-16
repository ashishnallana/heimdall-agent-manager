package bridge_runtime

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "odin_test:contracts"
import project_service "odin_test:hub/service/project"

// Interleave_Peer plays a bridge whose link stalls: while `paused` it reads nothing, so
// the hub's writes back up in the kernel; once resumed it records every text frame.
@(private = "file")
Interleave_Peer :: struct {
	socket: net.TCP_Socket,
	paused: bool, // atomic
	done:   bool, // atomic
	mu:     sync.Mutex,
	frames: [dynamic]string,
}

@(private = "file")
interleave_peer_run :: proc(data: rawptr) {
	p := (^Interleave_Peer)(data)
	raw := make([dynamic]byte)
	defer delete(raw)
	buf: [65536]byte
	for !sync.atomic_load(&p.done) {
		if sync.atomic_load(&p.paused) {
			time.sleep(time.Millisecond)
			continue
		}
		n, err := net.recv_tcp(p.socket, buf[:])
		if err != nil || n == 0 do break
		append(&raw, ..buf[:n])
		// Split complete unmasked text frames (7- or 16-bit length) off the front.
		consumed := 0
		for len(raw) - consumed >= 2 {
			rest := raw[consumed:]
			length := int(rest[1] & 0x7f)
			header := 2
			if length == 126 {
				if len(rest) < 4 do break
				length = int(rest[2]) << 8 | int(rest[3])
				header = 4
			}
			if len(rest) < header + length do break
			payload := string(rest[header:header + length])
			sync.lock(&p.mu)
			// Binary frames (pty_wire keystrokes) are tagged so the test can find them.
			append(&p.frames, strings.concatenate({"BIN:", payload}) if rest[0] & 0x0f == 0x2 else strings.clone(payload))
			sync.unlock(&p.mu)
			consumed += header + length
		}
		remove_range(&raw, 0, consumed)
	}
}

@(private = "file")
Interleave_Send :: struct {
	registry:   ^project_service.Bridge_Runtime_Registry,
	connection: ^project_service.Bridge_Runtime_Connection,
	text:       string,
	result:     Command_Write_Result,
	small_sent: bool,
	binary:     bool, // the small writer is a binary keystroke frame, not a JSON command
}

// REQ-ERR-PROTO-C: while a large chunked command is stuck behind a stalled link, a small
// command (ack, stop, pong) gets onto the wire between its chunks as soon as the link
// moves, instead of waiting behind the whole sequence.
@(test)
runtime_small_command_interleaves_between_chunks :: proc(t: ^testing.T) {
	interleave_run(t, binary = false)
}

// REQ-ERR-PROTO-C + REQ-PTY-NET-3: a binary keystroke frame (send_runtime_binary) is a
// single-frame writer too, so typing stays live while a large file write is in flight.
@(test)
runtime_binary_keystroke_interleaves_between_chunks :: proc(t: ^testing.T) {
	interleave_run(t, binary = true)
}

@(private = "file")
interleave_run :: proc(t: ^testing.T, binary: bool) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	bound, _ := net.bound_endpoint(listener)
	peer_socket, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	hub_socket, _, _ := net.accept_tcp(listener)
	defer { net.close(peer_socket); net.close(hub_socket); net.close(listener) }
	_ = net.set_option(peer_socket, .Receive_Timeout, 2 * time.Second)

	hello, hello_ok, _ := runtime_accept_hello(registry, "brg_interleave", PROTOCOL_VERSION, "")
	if !testing.expect(t, hello_ok, "hello accepted") do return
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_interleave", hub_socket, hello.generation)
	connection := project_service.bridge_runtime_connection_acquire(registry, "brg_interleave", hello.generation)
	if !testing.expect(t, connection != nil) do return
	defer project_service.bridge_runtime_connection_release(registry, connection)

	peer := Interleave_Peer{socket = peer_socket, paused = true}
	defer {
		for f in peer.frames do delete(f)
		delete(peer.frames)
	}
	peer_thread := thread.create_and_start_with_data(rawptr(&peer), interleave_peer_run)

	// ~2,500 chunks: far more than loopback buffers hold, so with the peer paused the
	// sequence blocks part-way through.
	big := strings.concatenate({`{"type":"fs_write_file","command_id":"cmd_big","content":"`, strings.repeat("a", 15 * 1024 * 1024, context.temp_allocator), `"}`})
	defer delete(big)
	expected_chunks := 0
	{
		frames := hub_command_chunk_frames(big, contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES)
		expected_chunks = len(frames)
		for f in frames do delete(f)
		delete(frames)
	}
	send := Interleave_Send{registry = registry, connection = connection, text = big, binary = binary}
	big_thread := thread.create_and_start_with_data(rawptr(&send), proc(data: rawptr) {
		s := (^Interleave_Send)(data)
		s.result = write_ws_command_on_connection(s.connection, s.text)
	})
	time.sleep(300 * time.Millisecond) // the big send is now blocked in the kernel

	small_thread := thread.create_and_start_with_data(rawptr(&send), proc(data: rawptr) {
		s := (^Interleave_Send)(data)
		if s.binary {
			frame := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT, contracts.pty_wire_flags(false, false), "sh_keys", transmute([]byte)string("ls\n"), context.temp_allocator)
			s.small_sent, _ = send_runtime_binary(rawptr(s.registry), "brg_interleave", frame)
		} else {
			s.small_sent, _ = send_runtime_command(rawptr(s.registry), project_service.Runtime_Command{
				bridge_id = "brg_interleave", command_id = "cmd_small", body_json = `{"type":"stop_agent","command_id":"cmd_small"}`,
			})
		}
	})
	waited := time.tick_now()
	for sync.atomic_load(&connection.writer_waiters) == 0 && time.tick_since(waited) < 2 * time.Second do time.sleep(time.Millisecond)
	// The small writer registered as a priority waiter, so the chunk loop yields to it.
	// (writer_mutex alone may or may not hand over; the waiter count is the guarantee.)
	testing.expect(t, sync.atomic_load(&connection.writer_waiters) > 0, "the small writer waits via bridge_runtime_connection_lock_writer")
	sync.atomic_store(&peer.paused, false)

	thread.join(small_thread)
	thread.destroy(small_thread)
	thread.join(big_thread)
	thread.destroy(big_thread)
	testing.expect(t, send.small_sent, "the small command was sent")
	testing.expect_value(t, send.result, Command_Write_Result.Ok)

	drain_started := time.tick_now()
	for time.tick_since(drain_started) < 20 * time.Second {
		sync.lock(&peer.mu)
		n := len(peer.frames)
		sync.unlock(&peer.mu)
		if n >= expected_chunks + 1 do break
		time.sleep(5 * time.Millisecond)
	}
	sync.atomic_store(&peer.done, true)
	_ = net.shutdown(net.Any_Socket(peer_socket), .Receive)
	thread.join(peer_thread)
	thread.destroy(peer_thread)

	small_index, last_chunk_index, chunks := -1, -1, 0
	for f, i in peer.frames {
		if hub_command_frame_is_chunk(f) {
			chunks += 1
			last_chunk_index = i
		} else if strings.has_prefix(f, "BIN:") || strings.contains(f, "cmd_small") {
			small_index = i
		}
	}
	testing.expect_value(t, chunks, expected_chunks)
	testing.expect(t, small_index >= 0, "the small command reached the bridge")
	testing.expectf(t, small_index >= 0 && small_index < last_chunk_index - 100, "the small command went out between chunks (frame %d), not after the sequence (last chunk at frame %d)", small_index, last_chunk_index)
}

// REQ-ERR-PROTO-C: the yield to small writers is bounded, so a writer count that never
// drops to zero (a steady stream of small frames) cannot starve a chunked command.
@(test)
runtime_chunked_command_is_not_starved_by_waiting_writers :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	bound, _ := net.bound_endpoint(listener)
	peer_socket, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	hub_socket, _, _ := net.accept_tcp(listener)
	defer { net.close(peer_socket); net.close(hub_socket); net.close(listener) }

	hello, hello_ok, _ := runtime_accept_hello(registry, "brg_starve", PROTOCOL_VERSION, "")
	if !testing.expect(t, hello_ok, "hello accepted") do return
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_starve", hub_socket, hello.generation)
	connection := project_service.bridge_runtime_connection_acquire(registry, "brg_starve", hello.generation)
	if !testing.expect(t, connection != nil) do return
	defer project_service.bridge_runtime_connection_release(registry, connection)

	peer := Interleave_Peer{socket = peer_socket}
	defer {
		for f in peer.frames do delete(f)
		delete(peer.frames)
	}
	peer_thread := thread.create_and_start_with_data(rawptr(&peer), interleave_peer_run)

	// Pretend a small writer is always waiting.
	sync.atomic_add(&connection.writer_waiters, 1)
	big := strings.concatenate({`{"type":"fs_write_file","command_id":"cmd_big","content":"`, strings.repeat("a", 60_000, context.temp_allocator), `"}`})
	defer delete(big)
	started := time.tick_now()
	result := write_ws_command_on_connection(connection, big)
	elapsed := time.tick_since(started)
	sync.atomic_sub(&connection.writer_waiters, 1)
	testing.expect_value(t, result, Command_Write_Result.Ok)
	// ~11 chunks, each deferring at most CHUNK_YIELD_MAX.
	testing.expectf(t, elapsed < 2 * time.Second, "chunked send finished despite a permanent waiter (%v)", elapsed)

	sync.atomic_store(&peer.done, true)
	_ = net.shutdown(net.Any_Socket(peer_socket), .Receive)
	thread.join(peer_thread)
	thread.destroy(peer_thread)
}

// REQ-ERR-PROTO-C (C1): a bridge that stops reading cannot block a hub writer forever.
// Every frame goes through ws.send_socket_bytes, whose WRITE_DEADLINE (5s) caps one
// frame's write, so once the kernel buffers fill the next write fails within that
// bound and the socket is shut down. (set_command_socket's Send_Timeout is a backstop;
// send_socket_bytes sets its own short SO_SNDTIMEO per call.)
@(test)
runtime_stalled_bridge_write_fails_within_send_timeout :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	bound, _ := net.bound_endpoint(listener)
	peer_socket, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port}) // never read
	hub_socket, _, _ := net.accept_tcp(listener)
	defer { net.close(peer_socket); net.close(hub_socket); net.close(listener) }

	hello, hello_ok, _ := runtime_accept_hello(registry, "brg_stall", PROTOCOL_VERSION, "")
	if !testing.expect(t, hello_ok, "hello accepted") do return
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_stall", hub_socket, hello.generation)
	// Without a live connection every send fails at once, which would pass vacuously.
	if !testing.expect(t, project_service.bridge_runtime_registry_has_live(registry, "brg_stall"), "the stalled bridge is connected") do return

	body := strings.concatenate({`{"type":"fs_write_file","command_id":"cmd_fill","content":"`, strings.repeat("a", 5000, context.temp_allocator), `"}`})
	defer delete(body)
	started := time.tick_now()
	slowest: time.Duration
	failed := false
	for time.tick_since(started) < 30 * time.Second {
		one := time.tick_now()
		sent, _ := send_runtime_command(rawptr(registry), project_service.Runtime_Command{bridge_id = "brg_stall", command_id = "cmd_fill", body_json = body})
		slowest = max(slowest, time.tick_since(one))
		if !sent {
			failed = true
			break
		}
	}
	testing.expect(t, failed, "writes to a bridge that stopped reading eventually fail")
	testing.expectf(t, slowest < 8 * time.Second, "no single write blocked past the 5s send timeout (slowest %v)", slowest)
}
