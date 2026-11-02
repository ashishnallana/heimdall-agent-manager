package http

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// Loopback harness for the transfer pre-body gate: drives the REAL server loop
// (handle_client + gate) over a real socket so slot holding, socket timeouts and
// body deadlines are exercised as in production.

@(private = "file")
Loopback_Server :: struct {
	router: ^Router,
	config: Server_Config,
	socket: net.TCP_Socket,
	source: net.Endpoint,
}

@(private = "file")
loopback_server_thread :: proc(data: rawptr) {
	s := (^Loopback_Server)(data)
	handle_client(s.socket, s.source, s.router, s.config)
}

// transfer_loopback sends `head`, then each of `parts` (sleeping `gap` before each),
// and NEVER closes its send side: the server must answer on its own (auth failure,
// idle timeout or body deadline). Returns the raw response and the time from the
// head being sent to the server closing the connection.
transfer_loopback :: proc(t: ^testing.T, h: ^MCP_Transfer_Handlers, gate: Pre_Body_Gate, head: string, parts: []string, gap: time.Duration) -> (string, time.Duration) {
	router := new_router()
	defer router_free(&router)
	mcp_transfer_register_routes(&router, h)
	g := gate
	g.ctx = h
	g.admit = mcp_transfer_pre_body
	g.release = mcp_transfer_pre_body_release
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	_ = net.set_option(client, .Receive_Timeout, 10 * time.Second)
	server_socket, source, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	state := Loopback_Server{router = &router, config = Server_Config{pre_body = &g}, socket = server_socket, source = source}
	worker := thread.create_and_start_with_data(rawptr(&state), loopback_server_thread)
	start := time.tick_now()
	_, _ = net.send_tcp(client, transmute([]byte)head)
	for part in parts {
		if gap > 0 do time.sleep(gap)
		_, _ = net.send_tcp(client, transmute([]byte)part)
	}
	out := strings.builder_make(context.temp_allocator)
	buf: [4096]byte
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n <= 0 do break
		strings.write_bytes(&out, buf[:n])
	}
	elapsed := time.tick_since(start)
	thread.join(worker); thread.destroy(worker)
	net.close(client)
	return strings.to_string(out), elapsed
}
