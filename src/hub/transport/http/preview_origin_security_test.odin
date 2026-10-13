package http

import "base:runtime"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth_service "odin_test:hub/service/auth"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

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
}

@(private = "file")
Preview_Owner_Repo_State :: struct {
	foreign_session: domain.Shell_Session,
	get_calls: int,
}

@(private = "file")
preview_owner_repo_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	state := (^Preview_Owner_Repo_State)(ctx)
	state.get_calls += 1
	// This fake deliberately models the repository's owner-scoped contract: the
	// record exists, but is invisible to a different authenticated owner.
	if state.foreign_session.session_id == session_id && state.foreign_session.owner_user_id == owner_user_id {
		return state.foreign_session, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
preview_owner_user_get :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	return domain.User{
		user_id = user_id,
		name = string(user_id),
		display_name = string(user_id),
		status = .Active,
	}, true, domain.Domain_Error{}
}

@(private = "file")
preview_owner_sink_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	count := (^int)(ctx)
	count^ += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
preview_owner_handler_response :: proc(t: ^testing.T, h: ^Shell_Session_Stream_Handlers, session_id: string) -> string {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	defer net.close(client)
	server_socket, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	defer net.close(server_socket)
	path := strings.concatenate({"/p/", session_id, "/"}, context.temp_allocator)
	shell_session_preview_proxy_handler(rawptr(h), Request{
		method = "GET",
		path = path,
		request_id = "req_owner_isolation",
		remote_addr = "127.0.0.1:4444",
		headers = []contracts.HTTP_Header{{name = "X-authentik-username", value = "owner"}},
	}, server_socket)
	buf: [4096]byte
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:n]))
}

@(test)
test_preview_origin_foreign_and_missing_sessions_are_identical_404_without_tunnel_open :: proc(t: ^testing.T) {
	repo_state := Preview_Owner_Repo_State{foreign_session = domain.Shell_Session{
		session_id = "foreign", owner_user_id = "someone-else", bridge_id = "brg_foreign",
		status = domain.Shell_Session_Status_Running, server_port = 3000,
	}}
	shell_repo := iface.Shell_Session_Repository{ctx = rawptr(&repo_state), get = preview_owner_repo_get}
	user_repo := iface.User_Repository{get_by_id = preview_owner_user_get}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	cidrs := []string{"127.0.0.1/32"}
	auth := auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{
		username_header = "X-authentik-username",
		trusted_proxy_cidrs = cidrs,
	}, &users)
	tunnel_open_count := 0
	h := Shell_Session_Stream_Handlers{
		auth = &auth,
		shell_repo = &shell_repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx = rawptr(&tunnel_open_count),
			send_runtime_command = preview_owner_sink_send,
		},
		preview_origin = "https://preview.example",
	}
	foreign_response := preview_owner_handler_response(t, &h, "foreign")
	defer delete(foreign_response)
	missing := preview_owner_handler_response(t, &h, "missing")
	defer delete(missing)
	testing.expect(t, strings.has_prefix(foreign_response, "HTTP/1.1 404"))
	testing.expect_value(t, foreign_response, missing)
	testing.expect_value(t, repo_state.get_calls, 2)
	testing.expect_value(t, tunnel_open_count, 0)
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
