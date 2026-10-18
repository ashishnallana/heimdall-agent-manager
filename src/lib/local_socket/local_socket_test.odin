package local_socket

import "core:fmt"
import "core:net"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
pair_round_trips_both_ways :: proc(t: ^testing.T) {
	a, b, ok := pair()
	testing.expect(t, ok, "pair")
	if !ok do return
	defer close(a)
	defer close(b)
	testing.expect_value(t, send(a, transmute([]byte)string("ping")), 4)
	buf: [16]byte
	testing.expect_value(t, recv(b, buf[:]), 4)
	testing.expect_value(t, string(buf[:4]), "ping")
	testing.expect_value(t, send(b, transmute([]byte)string("pong")), 4)
	testing.expect_value(t, recv(a, buf[:]), 4)
	testing.expect_value(t, string(buf[:4]), "pong")
}

@(test)
listen_dial_accept_over_a_path :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/ls-test-%d.sock", tmp, os.get_pid())
	listener, lok := listen(path)
	testing.expect(t, lok, "listen")
	if !lok do return
	defer {
		close(listener)
		remove_path(path)
	}
	client, cok := dial(path)
	testing.expect(t, cok, "dial")
	if !cok do return
	defer close(client)
	server, aok := accept(listener)
	testing.expect(t, aok, "accept")
	if !aok do return
	defer close(server)
	testing.expect_value(t, send(client, transmute([]byte)string("hello\n")), 6)
	buf: [16]byte
	testing.expect_value(t, recv(server, buf[:]), 6)
	// Peer close reads as end of stream, not an error.
	close(client)
	client = INVALID_SOCKET
	n, err := recv_ex(server, buf[:])
	testing.expect_value(t, n, 0)
	testing.expect_value(t, err, Error.None)
}

@(test)
recv_timeout_is_would_block_not_close :: proc(t: ^testing.T) {
	a, b, ok := pair()
	testing.expect(t, ok, "pair")
	if !ok do return
	defer close(a)
	defer close(b)
	testing.expect(t, set_recv_timeout(b, 100 * time.Millisecond), "set timeout")
	buf: [8]byte
	started := time.tick_now()
	n, err := recv_ex(b, buf[:])
	testing.expect_value(t, n, -1)
	testing.expect_value(t, err, Error.Would_Block)
	testing.expect(t, time.tick_since(started) < 2 * time.Second, "timeout honoured")
	// Still usable afterwards.
	testing.expect_value(t, send(a, transmute([]byte)string("x")), 1)
	n2, err2 := recv_ex(b, buf[:])
	testing.expect_value(t, n2, 1)
	testing.expect_value(t, err2, Error.None)
}

Wake_Ctx :: struct {
	s:      Socket,
	result: int,
	done:   bool,
}

@(test)
shutdown_read_wakes_a_blocked_reader :: proc(t: ^testing.T) {
	a, b, ok := pair()
	testing.expect(t, ok, "pair")
	if !ok do return
	defer close(a)
	defer close(b)
	ctx := Wake_Ctx{s = b, result = 99}
	reader := thread.create_and_start_with_poly_data(&ctx, proc(c: ^Wake_Ctx) {
		buf: [8]byte
		c.result = recv(c.s, buf[:])
		c.done = true
	})
	time.sleep(100 * time.Millisecond)
	testing.expect(t, !ctx.done, "reader is parked in recv")
	testing.expect(t, shutdown(b, .Read), "shutdown")
	deadline := time.tick_now()
	for !ctx.done && time.tick_since(deadline) < 3 * time.Second do time.sleep(5 * time.Millisecond)
	testing.expect(t, ctx.done, "shutdown(.Read) must wake the reader")
	testing.expect(t, ctx.result <= 0, "the woken recv reports no data")
	thread.join(reader)
	thread.destroy(reader)
}

@(test)
poll_readable_reports_data :: proc(t: ^testing.T) {
	a, b, ok := pair()
	testing.expect(t, ok, "pair")
	if !ok do return
	defer close(a)
	defer close(b)
	ready, pok := poll_readable(b, 0)
	testing.expect(t, pok && !ready, "idle socket is not readable")
	_ = send(a, transmute([]byte)string("z"))
	ready, pok = poll_readable(b, 1000)
	testing.expect(t, pok && ready, "socket with data is readable")
}

// The bridge wakes accepted TCP readers through the same call (handle cast to
// Socket), so the wake must hold for TCP too.
@(test)
shutdown_read_wakes_a_blocked_tcp_reader :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	client, derr := net.dial_tcp(bound)
	testing.expect(t, derr == nil, "dial")
	if derr != nil do return
	defer net.close(client)
	server, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil, "accept")
	if aerr != nil do return
	defer net.close(server)

	ctx := Wake_Ctx{s = Socket(server), result = 99}
	reader := thread.create_and_start_with_poly_data(&ctx, proc(c: ^Wake_Ctx) {
		buf: [8]byte
		c.result = recv(c.s, buf[:])
		c.done = true
	})
	time.sleep(100 * time.Millisecond)
	testing.expect(t, !ctx.done, "reader is parked in recv")
	testing.expect(t, shutdown(Socket(server), .Read), "shutdown")
	deadline := time.tick_now()
	for !ctx.done && time.tick_since(deadline) < 3 * time.Second do time.sleep(5 * time.Millisecond)
	testing.expect(t, ctx.done, "shutdown(.Read) must wake a TCP reader")
	if ctx.done {
		thread.join(reader)
		thread.destroy(reader)
	}
}
