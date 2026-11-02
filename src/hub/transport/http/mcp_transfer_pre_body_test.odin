package http

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import mcp "odin_test:hub/service/mcp"

// Pre-body admission (design §7) over a real socket: the client sends ONLY the
// request head, never the body. A refusal must arrive without the server waiting
// for body bytes (the receive timeout would trip otherwise), and an admitted
// request's data-path slot is returned after the response.

@(private = "file")
Pre_Body_Test_State :: struct {
	router: ^Router,
	config: Server_Config,
	socket: net.TCP_Socket,
	source: net.Endpoint,
}

@(private = "file")
pre_body_test_thread :: proc(data: rawptr) {
	s := (^Pre_Body_Test_State)(data)
	handle_client(s.socket, s.source, s.router, s.config)
}

@(private = "file")
pre_body_exchange :: proc(t: ^testing.T, router: ^Router, config: Server_Config, request: string) -> string {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
	server_socket, source, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	state := Pre_Body_Test_State{router = router, config = config, socket = server_socket, source = source}
	worker := thread.create_and_start_with_data(rawptr(&state), pre_body_test_thread)
	_, _ = net.send_tcp(client, transmute([]byte)request)
	buf: [4096]byte
	n, _ := net.recv_tcp(client, buf[:])
	// Closing the client ends a server that is (wrongly) still waiting for the body.
	net.close(client)
	thread.join(worker); thread.destroy(worker)
	return strings.clone(string(buf[:max(n, 0)]), context.temp_allocator)
}

@(test)
test_transfer_pre_body_admission_before_body_read :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	svc := mcp.Transfer_Service{}
	h := MCP_Transfer_Handlers{svc = &svc}
	router := new_router()
	defer router_free(&router)
	mcp_transfer_register_routes(&router, &h)
	gate := Pre_Body_Gate{ctx = &h, admit = mcp_transfer_pre_body, release = mcp_transfer_pre_body_release}
	config := Server_Config{pre_body = &gate}
	ct := MCP_TRANSFERS_PATH + "/xfr_a/ciphertext"
	head :: proc(method, path: string, length: int) -> string {
		return fmt.tprintf("%s %s HTTP/1.1\r\nHost: hub.example\r\nContent-Length: %d\r\n\r\n", method, path, length)
	}

	// Declared PUT above the armored 15 MiB bound -> 413 with no body read.
	r := pre_body_exchange(t, &router, config, head("PUT", ct, TRANSFER_PUT_MAX_BYTES + 1))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 413"), "oversized PUT: %q", r)
	testing.expect(t, strings.contains(r, "body_too_large"))
	// PATCH above 8 MiB and seal JSON above 64 KiB likewise.
	r = pre_body_exchange(t, &router, config, head("PATCH", ct, TRANSFER_PATCH_MAX_BYTES + 1))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 413"), "oversized PATCH: %q", r)
	r = pre_body_exchange(t, &router, config, head("POST", MCP_TRANSFERS_PATH + "/xfr_a/seal", TRANSFER_JSON_MAX_BYTES + 1))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 413"), "oversized seal: %q", r)
	// Any route: a declared length above the shared reader cap is refused up front.
	r = pre_body_exchange(t, &router, config, head("POST", "/api/v1/artifacts", MAX_HTTP_REQUEST_BYTES + 1))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 413"), "over reader cap: %q", r)
	testing.expect_value(t, sync.atomic_load(&svc.data_path_in_flight), i64(0))

	// Global data-path slots full -> 503 + Retry-After before the body is read.
	svc.data_path_max = 1
	testing.expect(t, mcp.transfer_data_path_acquire(&svc))
	r = pre_body_exchange(t, &router, config, head("PATCH", ct, 1024))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 503") && strings.contains(r, "Retry-After: 2"), "full slots: %q", r)
	testing.expect_value(t, sync.atomic_load(&svc.data_path_in_flight), i64(1))
	mcp.transfer_data_path_release(&svc)

	// Admitted: the slot is taken before the body, the handler does not take a
	// second one, and it is returned after the (401, no bearer) response.
	r = pre_body_exchange(t, &router, config, strings.concatenate({head("PATCH", ct, 4), "abcd"}))
	testing.expectf(t, strings.has_prefix(r, "HTTP/1.1 401"), "admitted PATCH: %q", r)
	testing.expect_value(t, sync.atomic_load(&svc.data_path_in_flight), i64(0))
}
