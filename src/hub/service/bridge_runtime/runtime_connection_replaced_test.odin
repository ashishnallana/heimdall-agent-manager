package bridge_runtime

import "core:net"
import "core:testing"
import "core:time"
import project_service "odin_test:hub/service/project"

REPLACED_FAREWELL_TEST :: `{"type":"connection_replaced","protocol_version":1,"payload":{"reason":"newer_bridge_connection"}}`

// replaced_test_socket_pair returns a connected (peer, hub) loopback pair; the peer
// plays the bridge process, the hub end is what the registry writes to.
replaced_test_socket_pair :: proc(t: ^testing.T, listener: net.TCP_Socket, port: int) -> (peer, hub: net.TCP_Socket) {
	peer, _ = net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	hub, _, _ = net.accept_tcp(listener)
	_ = net.set_option(peer, .Receive_Timeout, 300 * time.Millisecond)
	return
}

// replaced_test_read_text_frames drains the peer until EOF or the receive timeout
// and splits the bytes into unmasked server text frames (all short: 7-bit length).
// framing_ok is false on any byte that is not a well-formed short text frame.
replaced_test_read_text_frames :: proc(peer: net.TCP_Socket, out: ^[dynamic]string) -> (eof: bool, framing_ok: bool) {
	raw := make([dynamic]byte, context.temp_allocator)
	buf: [512]byte
	for {
		n, err := net.recv_tcp(peer, buf[:])
		if err != nil do break // timeout: the hub left the socket open
		if n == 0 { eof = true; break }
		append(&raw, ..buf[:n])
	}
	i := 0
	for i < len(raw) {
		if i + 2 > len(raw) || raw[i] != 0x81 || raw[i + 1] >= 126 do return eof, false
		n := int(raw[i + 1])
		if i + 2 + n > len(raw) do return eof, false
		append(out, string(raw[i + 2:i + 2 + n]))
		i += 2 + n
	}
	return eof, true
}

// REQ-9: a newer hello for the same bridge identity must tell the superseded bridge
// why it is being dropped. The notice used to be addressed by bridge_id, which by
// then resolves to the NEW connection, so it never reached the old peer at all.
@(test)
runtime_replaced_connection_receives_exactly_one_notice_before_close :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	old_peer, old_hub := replaced_test_socket_pair(t, listener, bound.port)
	new_peer, new_hub := replaced_test_socket_pair(t, listener, bound.port)
	defer { net.close(old_peer); net.close(old_hub); net.close(new_peer); net.close(new_hub) }

	old_hello, old_ok, _ := runtime_accept_hello(registry, "brg_dup", 1, "", "", REPLACED_FAREWELL_TEST)
	if !testing.expect(t, old_ok) do return
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_dup", old_hub, old_hello.generation)
	// The old reader still holds its lease, as bridge_ws_handle_connection does.
	old_conn := project_service.bridge_runtime_connection_acquire(registry, "brg_dup", old_hello.generation)
	if !testing.expect(t, old_conn != nil) do return
	defer project_service.bridge_runtime_connection_release(registry, old_conn)

	new_hello, new_ok, _ := runtime_accept_hello(registry, "brg_dup", 1, "", "", REPLACED_FAREWELL_TEST)
	if !testing.expect(t, new_ok && new_hello.replaced_existing) do return
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_dup", new_hub, new_hello.generation)

	// The reader observing the generation flip afterwards must not send a second one.
	testing.expect(t, !project_service.bridge_runtime_connection_send_farewell(old_conn, REPLACED_FAREWELL_TEST), "the notice is once-only per connection")

	frames := make([dynamic]string, context.temp_allocator)
	eof, framing_ok := replaced_test_read_text_frames(old_peer, &frames)
	testing.expect(t, framing_ok, "old peer stream is whole text frames")
	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 do testing.expect_value(t, frames[0], REPLACED_FAREWELL_TEST)
	testing.expect(t, eof, "the superseded socket is shut down after the notice")

	clear(&frames)
	new_eof, _ := replaced_test_read_text_frames(new_peer, &frames)
	testing.expect_value(t, len(frames), 0) // nothing from the stale path reaches the new socket
	testing.expect(t, !new_eof, "the replacement connection stays open")
	project_service.bridge_runtime_registry_mark_offline(registry, "brg_dup", new_hello.generation)
}

// The reader-side path (bridge_ws_process_frame sees the generation flip before the
// retirement ran) and the retirement path race; whichever writes first wins and the
// other is a no-op. An ordinary disconnect (mark_offline) says nothing.
@(test)
runtime_connection_farewell_is_once_only_and_absent_on_plain_disconnect :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, listen_err == nil) do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	a_peer, a_hub := replaced_test_socket_pair(t, listener, bound.port)
	b_peer, b_hub := replaced_test_socket_pair(t, listener, bound.port)
	defer { net.close(a_peer); net.close(a_hub); net.close(b_peer); net.close(b_hub) }

	a_hello, _, _ := runtime_accept_hello(registry, "brg_a", 1, "", "", REPLACED_FAREWELL_TEST)
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_a", a_hub, a_hello.generation)
	a := project_service.bridge_runtime_connection_acquire(registry, "brg_a", a_hello.generation)
	if !testing.expect(t, a != nil) do return
	testing.expect(t, project_service.bridge_runtime_connection_send_farewell(a, REPLACED_FAREWELL_TEST), "first notice is written")
	testing.expect(t, !project_service.bridge_runtime_connection_send_farewell(a, REPLACED_FAREWELL_TEST), "second notice is suppressed")
	// A later replacement must not repeat it either.
	_, _, _ = runtime_accept_hello(registry, "brg_a", 1, "", "", REPLACED_FAREWELL_TEST)
	project_service.bridge_runtime_connection_release(registry, a)
	frames := make([dynamic]string, context.temp_allocator)
	_, framing_ok := replaced_test_read_text_frames(a_peer, &frames)
	testing.expect(t, framing_ok)
	testing.expect_value(t, len(frames), 1)
	project_service.bridge_runtime_registry_mark_offline(registry, "brg_a", 0)

	b_hello, _, _ := runtime_accept_hello(registry, "brg_b", 1, "", "", REPLACED_FAREWELL_TEST)
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_b", b_hub, b_hello.generation)
	project_service.bridge_runtime_registry_mark_offline(registry, "brg_b", b_hello.generation)
	clear(&frames)
	b_eof, _ := replaced_test_read_text_frames(b_peer, &frames)
	testing.expect_value(t, len(frames), 0)
	testing.expect(t, b_eof, "a plain disconnect still closes the socket")
	testing.expect(t, !project_service.bridge_runtime_connection_send_farewell(nil, REPLACED_FAREWELL_TEST), "nil connection is a safe no-op")
}
