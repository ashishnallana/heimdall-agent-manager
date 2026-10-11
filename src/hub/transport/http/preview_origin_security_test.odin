package http

import "base:runtime"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"

@(private = "file")
Preview_Dispatch_Test_State :: struct {
	router: ^Router,
	config: Server_Config,
	socket: net.TCP_Socket,
	source: net.Endpoint,
}

@(private = "file")
preview_dispatch_test_thread :: proc(data: rawptr) {
	s := (^Preview_Dispatch_Test_State)(data)
	handle_client(s.socket, s.source, s.router, s.config)
}

@(private = "file")
preview_dispatch_test_preview_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	count := (^int)(ctx)
	count^ += 1
	write_http_response(client, Response{status = 404, content_type = "text/plain", body = "preview-only"})
}

@(private = "file")
preview_dispatch_test_hub_handler :: proc(ctx: rawptr, req: Request) -> Response {
	count := (^int)(ctx)
	count^ += 1
	return Response{status = 200, content_type = "text/plain", body = "hub-route"}
}

@(private = "file")
preview_dispatch_test_request :: proc(t: ^testing.T, router: ^Router, config: Server_Config, request: string) -> string {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	defer net.close(client)
	server_socket, source, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	state := Preview_Dispatch_Test_State{router = router, config = config, socket = server_socket, source = source}
	worker := thread.create_and_start_with_data(rawptr(&state), preview_dispatch_test_thread)
	defer { thread.join(worker); thread.destroy(worker) }
	_, _ = net.send_tcp(client, transmute([]byte)request)
	buf: [2048]byte
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:n]))
}

@(test)
test_preview_origin_host_matching :: proc(t: ^testing.T) {
	testing.expect(t, preview_origin_host_matches("preview.example", "https://preview.example"))
	testing.expect(t, preview_origin_host_matches("PREVIEW.EXAMPLE:443", "https://preview.example/"))
	testing.expect(t, !preview_origin_host_matches("preview.example:8443", "https://preview.example"))
	testing.expect(t, !preview_origin_host_matches("hub.example", "https://preview.example"))
}

@(test)
test_preview_origin_dispatch_precedes_all_hub_routing :: proc(t: ^testing.T) {
	preview_calls, hub_calls: int
	router := new_router()
	defer router_free(&router)
	router_add(&router, "GET", "/api/v1/me", rawptr(&hub_calls), preview_dispatch_test_hub_handler)
	config := Server_Config{
		preview_origin = "https://preview.example",
		ui_origin = "https://hub.example",
		preview_ctx = rawptr(&preview_calls),
		preview_handler = preview_dispatch_test_preview_handler,
	}
	preview_requests := []string{
		"GET /api/v1/me HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"OPTIONS /api/v1/me HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /api/v1/me HTTP/1.1\r\nHost: preview.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
	}
	for request in preview_requests {
		response := preview_dispatch_test_request(t, &router, config, request)
		testing.expect(t, strings.has_prefix(response, "HTTP/1.1 404"))
		testing.expect(t, strings.contains(response, "preview-only"))
		delete(response)
	}
	testing.expect_value(t, preview_calls, 3)
	testing.expect_value(t, hub_calls, 0)

	hub_response := preview_dispatch_test_request(t, &router, config, "GET /api/v1/me HTTP/1.1\r\nHost: hub.example\r\n\r\n")
	defer delete(hub_response)
	testing.expect(t, strings.has_prefix(hub_response, "HTTP/1.1 200"))
	testing.expect(t, strings.contains(hub_response, "hub-route"))
	testing.expect_value(t, hub_calls, 1)
}

@(test)
test_preview_origin_legacy_gate_and_owner_check :: proc(t: ^testing.T) {
	testing.expect(t, preview_legacy_path_allowed("", false))
	testing.expect(t, preview_legacy_path_allowed("https://preview.example", true))
	testing.expect(t, !preview_legacy_path_allowed("https://preview.example", false))
	testing.expect(t, preview_owner_allowed("user_a", "user_a"))
	testing.expect(t, !preview_owner_allowed("user_a", "user_b"))
}

@(test)
test_preview_origin_cookie_filter :: proc(t: ^testing.T) {
	actual := _preview_filter_cookie_header("app=1; authentik_proxy_x=secret; AUTHENTIK_SESSION=s; theme=dark")
	defer delete(actual)
	testing.expect_value(t, actual, "app=1; theme=dark")
}

@(test)
test_preview_origin_referrer_policy_default :: proc(t: ^testing.T) {
	added := _preview_filter_response_head("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "/p/ss_1", 5173, true)
	defer delete(added, runtime.heap_allocator())
	testing.expect(t, strings.contains(added, "Referrer-Policy: same-origin\r\n"))
	preserved := _preview_filter_response_head("HTTP/1.1 200 OK\r\nReferrer-Policy: no-referrer\r\n\r\n", "/p/ss_1", 5173, true)
	defer delete(preserved, runtime.heap_allocator())
	testing.expect(t, strings.contains(preserved, "Referrer-Policy: no-referrer\r\n"))
	testing.expect(t, !strings.contains(preserved, "Referrer-Policy: same-origin"))
}

@(private = "file")
csrf_headers :: proc(values: ..contracts.HTTP_Header) -> []contracts.HTTP_Header { return values[:] }

@(test)
test_csrf_decision_table :: proc(t: ^testing.T) {
	ui := "https://hub.example"
	allow, _ := csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="same-origin"}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="same-site"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="cross-site"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Origin", value="https://preview.example"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Origin", value=ui}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", nil, ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Cookie", value="sid=x"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Sec-Fetch-Site", value="cross-site"}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Cookie", value="sid=x"}, {name="Origin", value="https://preview.example"}), ui, true)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Cookie", value="sid=x"}, {name="Origin", value=ui}), ui, true)
	testing.expect(t, allow)
	allow, _ = csrf_decide("GET", nil, ui, true)
	testing.expect(t, allow)
}
