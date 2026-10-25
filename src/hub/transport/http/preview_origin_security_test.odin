package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
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
	preview_origin_handler(rawptr(h), Request{
		method = "GET",
		path = path,
		request_id = "req_owner_isolation",
		remote_addr = "127.0.0.1:4444",
		headers = http_test_preview_headers(t, h.auth, "owner", session_id),
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
	auth := auth_service.new_auth_service(auth_service.Auth_Config{}, &users)
	defer auth_service.oidc_free(&auth)
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
	// The Hub's own cookies (preview session, session, login) never reach the app.
	hub := _preview_filter_cookie_header("__Host-heimdall_preview=p; app=2; __Host-heimdall_session=s; __HOST-HEIMDALL_LOGIN=l")
	defer delete(hub)
	testing.expect_value(t, hub, "app=2")
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

@(test)
test_csrf_rejected_body_is_json :: proc(t: ^testing.T) {
	_, reason := csrf_decide("POST", csrf_headers({name="Cookie", value="sid=x"}, {name="Origin", value="https://evil.example"}), "https://hub.example", false)
	body := csrf_rejected_body(reason)
	testing.expect_value(t, body, `{"error":{"code":"csrf_rejected","message":"Origin does not match the UI origin"}}`)
	_, err := json.parse_string(body, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	escaped := csrf_rejected_body(`quote " and \\ backslash`)
	_, err = json.parse_string(escaped, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
}

@(private = "file")
preview_relay_response :: proc(t: ^testing.T, h: ^Shell_Session_Stream_Handlers, handler: proc(rawptr, Request, net.TCP_Socket), path: string) -> string {
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
	handler(rawptr(h), Request{
		method = "GET",
		path = path,
		request_id = "req_preview_transport",
		remote_addr = "127.0.0.1:4444",
		headers = http_test_login(t, h.auth, "owner"),
	}, server_socket)
	buf: [4096]byte
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:n]))
}

// The real preview_origin_handler (not a stub) behind the Host dispatch: no Hub API,
// SPA/static or legacy preview path is reachable on the preview host, and a hub
// route registered for the same path is never invoked.
@(test)
test_preview_origin_host_serves_no_hub_api_or_static_routes :: proc(t: ^testing.T) {
	hub_calls := 0
	router := new_router()
	defer router_free(&router)
	hub_paths := []string{"/api/v1/me", "/api/v1/vault/directory", "/", "/index.html", "/assets/app.js", "/healthz"}
	for path in hub_paths {
		router_add(&router, "GET", path, rawptr(&hub_calls), preview_dispatch_test_hub_handler)
	}
	h := Shell_Session_Stream_Handlers{preview_origin = "https://preview.example"}
	config := Server_Config{
		preview_origin = "https://preview.example",
		ui_origin = "https://hub.example",
		preview_ctx = rawptr(&h),
		preview_handler = preview_origin_handler,
	}
	requests := []string{
		"GET /api/v1/me HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /api/v1/vault/directory HTTP/1.1\r\nHost: preview.example:443\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /index.html HTTP/1.1\r\nHost: PREVIEW.example\r\n\r\n",
		"GET /assets/app.js HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /healthz HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /api/v1/preview/sh_1/ HTTP/1.1\r\nHost: preview.example\r\n\r\n",
		"GET /p/ HTTP/1.1\r\nHost: preview.example\r\n\r\n",
	}
	for request in requests {
		response := preview_dispatch_test_request(t, &router, config, request)
		testing.expect(t, strings.has_prefix(response, "HTTP/1.1 404"), request)
		testing.expect(t, !strings.contains(response, "hub-route"), request)
		delete(response)
	}
	testing.expect_value(t, hub_calls, 0)
}

@(test)
test_preview_legacy_route_fails_closed_with_dedicated_origin :: proc(t: ^testing.T) {
	repo_state := Preview_Owner_Repo_State{foreign_session = domain.Shell_Session{
		session_id = "sh_owned", owner_user_id = "owner", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Running, server_port = 3000,
	}}
	shell_repo := iface.Shell_Session_Repository{ctx = rawptr(&repo_state), get = preview_owner_repo_get}
	user_repo := iface.User_Repository{get_by_id = preview_owner_user_get}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service(auth_service.Auth_Config{}, &users)
	defer auth_service.oidc_free(&auth)
	tunnel_open_count := 0
	h := Shell_Session_Stream_Handlers{
		auth = &auth,
		shell_repo = &shell_repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx = rawptr(&tunnel_open_count),
			send_runtime_command = preview_owner_sink_send,
		},
		preview_origin = "https://preview.example",
		preview_legacy_path = false,
	}
	// Secure mode: the owner's own running session is still a 404 on the Hub origin,
	// decided before authentication, the session lookup or any tunnel_open.
	closed := preview_relay_response(t, &h, shell_session_preview_proxy_handler, "/api/v1/preview/sh_owned/")
	defer delete(closed)
	testing.expect(t, strings.has_prefix(closed, "HTTP/1.1 404"))
	testing.expect_value(t, repo_state.get_calls, 0)
	testing.expect_value(t, tunnel_open_count, 0)

	// A "/p/" path on the Hub-origin route is not the dedicated transport, even with
	// the legacy route explicitly enabled: path prefix alone confers no authority.
	h.preview_legacy_path = true
	spoofed := preview_relay_response(t, &h, shell_session_preview_proxy_handler, "/p/sh_owned/")
	defer delete(spoofed)
	testing.expect(t, strings.has_prefix(spoofed, "HTTP/1.1 404"))
	testing.expect_value(t, repo_state.get_calls, 0)
	testing.expect_value(t, tunnel_open_count, 0)

	// Explicit opt-in reopens the legacy route (it reaches the owner-scoped lookup).
	h.preview_origin = "https://preview.example"
	repo_state.foreign_session.owner_user_id = "someone-else"
	reopened := preview_relay_response(t, &h, shell_session_preview_proxy_handler, "/api/v1/preview/sh_owned/")
	defer delete(reopened)
	testing.expect(t, strings.has_prefix(reopened, "HTTP/1.1 404"))
	testing.expect_value(t, repo_state.get_calls, 1)
	testing.expect_value(t, tunnel_open_count, 0)
}

// --- Preview-origin sign-in (phase 3): __Host-heimdall_preview via a handoff ticket ---

@(private = "file")
Preview_Flow_Fixture :: struct {
	repo_state: Preview_Owner_Repo_State,
	shell_repo: iface.Shell_Session_Repository,
	user_repo:  iface.User_Repository,
	clock:      platform.Clock,
	now:        string,
	users:      user_service.User_Service,
	auth:       auth_service.Auth_Service,
	h:          Shell_Session_Stream_Handlers,
	// The test browser's (hub-minted) bind cookie for its default flow.
	bind_id, bind_value: string,
}

@(private = "file")
preview_flow_clock :: proc(ctx: rawptr) -> string {return (^string)(ctx)^}

@(private = "file")
preview_flow_fixture :: proc(t: ^testing.T) -> ^Preview_Flow_Fixture {
	f := new(Preview_Flow_Fixture, context.temp_allocator)
	f.repo_state = Preview_Owner_Repo_State{foreign_session = domain.Shell_Session{
		session_id = "sh_owned", owner_user_id = "owner", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Running, server_port = 3000,
	}}
	f.shell_repo = iface.Shell_Session_Repository{ctx = rawptr(&f.repo_state), get = preview_owner_repo_get}
	f.user_repo = iface.User_Repository{get_by_id = preview_owner_user_get}
	f.now = "2026-10-25T10:00:00Z"
	f.clock = platform.Clock{ctx = &f.now, now = preview_flow_clock}
	ids := http_test_id_generator()
	f.users = user_service.new_user_service_basic(&f.user_repo, &f.clock, &ids)
	f.auth = auth_service.new_auth_service(auth_service.Auth_Config{}, &f.users, &f.clock)
	http_test_enable_sessions(&f.auth)
	f.h = Shell_Session_Stream_Handlers{
		auth = &f.auth,
		shell_repo = &f.shell_repo,
		preview_origin = "https://preview.example",
		ui_origin = "https://hub.example",
	}
	f.bind_id, f.bind_value, _ = auth_service.preview_bind_new(&f.auth)
	return f
}

@(private = "file")
preview_flow_header :: proc(resp: Response, name: string) -> string {
	for h in resp.headers do if strings.equal_fold(h.name, name) do return h.value
	return ""
}

@(private = "file")
preview_flow_start :: proc(f: ^Preview_Flow_Fixture, query: string, headers: []contracts.HTTP_Header) -> Response {
	return preview_auth_start_handler(&f.h, Request{method = "GET", path = PREVIEW_AUTH_START_PATH, query = query, request_id = "req_preview_start", headers = headers})
}

PREVIEW_FLOW_FAKE_BIND :: "&bind=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&bind_id=AAAAAAAA"

@(private = "file")
preview_flow_bind_cookie :: proc(bind_id, value: string) -> contracts.HTTP_Header {
	return contracts.HTTP_Header{"Cookie", strings.concatenate({auth_service.preview_bind_cookie_name(bind_id), "=", value}, context.temp_allocator)}
}

// preview_flow_ticket runs the start route as `user` (bound to the test
// browser's bind secret) and returns the ticket.
@(private = "file")
preview_flow_ticket :: proc(t: ^testing.T, f: ^Preview_Flow_Fixture, user: string) -> (string, []contracts.HTTP_Header) {
	session := http_test_login(t, &f.auth, user)
	query := strings.concatenate({"session=sh_owned&return_to=%2Fp%2Fsh_owned%2Fapp%3Fx%3D1&bind=", auth_service.sha256_hex(f.bind_value), "&bind_id=", f.bind_id}, context.temp_allocator)
	resp := preview_flow_start(f, query, session)
	testing.expect_value(t, resp.status, 302)
	location := preview_flow_header(resp, "Location")
	prefix := "https://preview.example/__heimdall/preview-auth?ticket="
	testing.expect(t, strings.has_prefix(location, prefix), location)
	if !strings.has_prefix(location, prefix) do return "", session
	return location[len(prefix):], session
}

@(private = "file")
preview_flow_redeem :: proc(f: ^Preview_Flow_Fixture, ticket: string, with_bind := true, cookies: ..contracts.HTTP_Header) -> Response {
	headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	if with_bind do append(&headers, preview_flow_bind_cookie(f.bind_id, f.bind_value))
	append(&headers, ..cookies)
	return preview_auth_redeem(&f.h, Request{method = "GET", path = PREVIEW_AUTH_PATH, query = strings.concatenate({"ticket=", ticket}, context.temp_allocator), request_id = "req_preview_redeem", headers = headers[:]})
}

// preview_flow_new_bind returns a Set-Cookie of a per-flow bind cookie, if any.
@(private = "file")
preview_flow_new_bind :: proc(resp: Response) -> string {
	for h in resp.headers do if strings.equal_fold(h.name, "Set-Cookie") && strings.has_prefix(h.value, strings.concatenate({auth_service.PREVIEW_BIND_COOKIE, "_"}, context.temp_allocator)) do return h.value
	return ""
}

@(private = "file")
preview_flow_set_cookie :: proc(resp: Response, name: string) -> string {
	for h in resp.headers do if strings.equal_fold(h.name, "Set-Cookie") && strings.has_prefix(h.value, strings.concatenate({name, "="}, context.temp_allocator)) do return h.value
	return ""
}


// preview_flow_rebounced: a refused redeem that starts a fresh, correctly bound
// flow (302 to the start route with a new bind cookie) and creates NO preview session.
@(private = "file")
preview_flow_rebounced :: proc(t: ^testing.T, resp: Response, why: string) {
	testing.expectf(t, resp.status == 302, "%s: status %d", why, resp.status)
	testing.expectf(t, strings.has_prefix(preview_flow_header(resp, "Location"), "https://hub.example/api/v1/preview-auth/start?"), "%s: %s", why, preview_flow_header(resp, "Location"))
	testing.expectf(t, preview_flow_set_cookie(resp, auth_service.PREVIEW_COOKIE) == "", "%s: no preview session", why)
}

@(test)
test_preview_auth_start_requires_session_and_owned_target :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	// No Hub session: sign in first, then come back to exactly this start URL.
	anonymous := preview_flow_start(f, "session=sh_owned&return_to=%2Fp%2Fsh_owned%2F" + PREVIEW_FLOW_FAKE_BIND, nil)
	testing.expect_value(t, anonymous.status, 302)
	testing.expect_value(t, preview_flow_header(anonymous, "Location"), "/api/v1/auth/login?return_to=%2Fapi%2Fv1%2Fpreview-auth%2Fstart%3Fsession%3Dsh_owned%26return_to%3D%252Fp%252Fsh_owned%252F%26bind%3D0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef%26bind_id%3DAAAAAAAA")
	// A preview session the user does not own (owner-scoped lookup): 404, no ticket.
	intruder := http_test_login(t, &f.auth, "intruder")
	foreign_resp := preview_flow_start(f, "session=sh_owned&return_to=%2Fp%2Fsh_owned%2F" + PREVIEW_FLOW_FAKE_BIND, intruder)
	testing.expect_value(t, foreign_resp.status, 404)
	testing.expect_value(t, preview_flow_header(foreign_resp, "Location"), "")
	// return_to must stay inside /p/<sid>/.
	owner := http_test_login(t, &f.auth, "owner")
	for bad in ([]string{"%2Fp%2Fother%2F", "%2F%2Fevil.example%2Fp%2Fsh_owned%2F", "https%3A%2F%2Fevil.example%2F", "%2Fapi%2Fv1%2Fme"}) {
		resp := preview_flow_start(f, strings.concatenate({"session=sh_owned&return_to=", bad, PREVIEW_FLOW_FAKE_BIND}, context.temp_allocator), owner)
		testing.expect(t, resp.status == 400, bad)
	}
	// Default return_to is the preview root.
	ok := preview_flow_start(f, "session=sh_owned" + PREVIEW_FLOW_FAKE_BIND, owner)
	testing.expect_value(t, ok.status, 302)
	testing.expect(t, strings.has_prefix(preview_flow_header(ok, "Location"), "https://preview.example/__heimdall/preview-auth?ticket="))
	testing.expect_value(t, preview_flow_header(ok, "Referrer-Policy"), "no-referrer")
	// A bearer principal (no browser session) cannot mint preview tickets.
	_, bearer_err := auth_service.preview_ticket_mint(&f.auth, contracts.Auth_Context{kind = .OIDC, user_id = "owner"}, "sh_owned", "/p/sh_owned/", auth_service.sha256_hex(f.bind_value), f.bind_id)
	testing.expect_value(t, bearer_err.code, domain.Error_Code.Forbidden)
}

@(test)
test_preview_auth_ticket_single_use_expiry_and_cookie :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	ticket, _ := preview_flow_ticket(t, f, "owner")
	resp := preview_flow_redeem(f, ticket)
	testing.expect_value(t, resp.status, 302)
	testing.expect_value(t, preview_flow_header(resp, "Location"), "/p/sh_owned/app?x=1")
	cookie := preview_flow_set_cookie(resp, auth_service.PREVIEW_COOKIE)
	testing.expect(t, strings.contains(preview_flow_set_cookie(resp, auth_service.preview_bind_cookie_name(f.bind_id)), "Max-Age=0"), "this flow's bind cookie cleared on redeem")
	for attr in ([]string{"__Host-heimdall_preview=", "Path=/", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age="}) do testing.expect(t, strings.contains(cookie, attr), attr)
	testing.expect(t, !strings.contains(cookie, "Domain="), "host-only cookie")
	// Single use.
	again := preview_flow_redeem(f, ticket)
	testing.expect_value(t, again.status, 403)
	testing.expect_value(t, preview_flow_set_cookie(again, auth_service.PREVIEW_COOKIE), "")
	// Unknown ticket.
	testing.expect_value(t, preview_flow_redeem(f, "not-a-real-ticket-not-a-real-ticket").status, 403)
	// Expiry: tickets live 60 s.
	late, _ := preview_flow_ticket(t, f, "owner")
	f.now = "2026-10-25T10:01:01Z"
	preview_flow_rebounced(t, preview_flow_redeem(f, late), "expired ticket re-bounces")
	// Only GET is served on the sign-in path.
	post := preview_auth_redeem(&f.h, Request{method = "POST", path = PREVIEW_AUTH_PATH, query = "ticket=x", request_id = "r"})
	testing.expect_value(t, post.status, 404)
}

@(test)
test_preview_cookie_authenticates_and_dies_with_parent_session :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	ticket, session := preview_flow_ticket(t, f, "owner")
	resp := preview_flow_redeem(f, ticket)
	set_cookie := preview_flow_set_cookie(resp, auth_service.PREVIEW_COOKIE)
	pair := set_cookie[:strings.index_byte(set_cookie, ';')]
	preview_headers := []contracts.HTTP_Header{{"Cookie", pair}, {"Authorization", "Bearer app-owned-token"}}
	nav := Request{method = "GET", path = "/p/sh_owned/index.html", request_id = "r", headers = preview_headers}
	principal, ok, _ := preview_origin_auth(&f.h, nav)
	testing.expect(t, ok, "preview cookie authenticates")
	testing.expect_value(t, principal.user_id, "owner")
	testing.expect_value(t, principal.kind, contracts.Auth_Kind.Session)
	// The Hub session cookie alone is never accepted on the preview host:
	// a navigation bounces through the start route, anything else is 401.
	hub_only := Request{method = "GET", path = "/p/sh_owned/index.html", request_id = "r", headers = []contracts.HTTP_Header{session[0], {"Sec-Fetch-Mode", "navigate"}}}
	_, hub_ok, bounce := preview_origin_auth(&f.h, hub_only)
	testing.expect(t, !hub_ok)
	testing.expect_value(t, bounce.status, 302)
	bounce_location := preview_flow_header(bounce, "Location")
	testing.expect(t, strings.has_prefix(bounce_location, "https://hub.example/api/v1/preview-auth/start?session=sh_owned&return_to=%2Fp%2Fsh_owned%2Findex.html&bind="), bounce_location)
	testing.expect(t, strings.contains(bounce_location, "&bind_id=") && strings.has_suffix(bounce_location, "&hop=1"), bounce_location)
	testing.expect(t, strings.contains(preview_flow_new_bind(bounce), "HttpOnly"), "bounce binds the browser")
	xhr := Request{method = "GET", path = "/p/sh_owned/api", request_id = "r", headers = []contracts.HTTP_Header{session[0], {"Sec-Fetch-Mode", "cors"}}}
	_, xhr_ok, denied := preview_origin_auth(&f.h, xhr)
	testing.expect(t, !xhr_ok)
	testing.expect_value(t, denied.status, 401)
	// Bearer credentials are the app's, never Hub identity, on the preview host.
	bearer_only := Request{method = "GET", path = "/p/sh_owned/api", request_id = "r", headers = []contracts.HTTP_Header{{"Authorization", "Bearer app-owned-token"}}}
	_, bearer_ok, _ := preview_origin_auth(&f.h, bearer_only)
	testing.expect(t, !bearer_ok)
	// Logging out of the parent Hub session ends the preview session.
	_ = auth_service.web_logout(&f.auth, session)
	_, after_logout, _ := preview_origin_auth(&f.h, nav)
	testing.expect(t, !after_logout, "preview session dies with its parent")

	// Parent expiry (not just logout) is observed on the next re-check.
	ticket2, _ := preview_flow_ticket(t, f, "owner")
	resp2 := preview_flow_redeem(f, ticket2)
	cookie2 := preview_flow_set_cookie(resp2, auth_service.PREVIEW_COOKIE)
	nav.headers = []contracts.HTTP_Header{{"Cookie", cookie2[:strings.index_byte(cookie2, ';')]}}
	_, alive, _ := preview_origin_auth(&f.h, nav)
	testing.expect(t, alive)
	f.now = "2026-10-26T10:00:01Z" // past the parent's 24 h idle expiry
	_, expired, _ := preview_origin_auth(&f.h, nav)
	testing.expect(t, !expired, "preview session ends when the parent session expires")
}

// The real Host dispatch serves the sign-in path on the preview origin and never
// proxies it; the previewed app cannot shadow it.
@(test)
test_preview_origin_handler_serves_sign_in_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	ticket, _ := preview_flow_ticket(t, f, "owner")
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
	bind_header := []contracts.HTTP_Header{preview_flow_bind_cookie(f.bind_id, f.bind_value)}
	preview_origin_handler(rawptr(&f.h), Request{method = "GET", path = PREVIEW_AUTH_PATH, query = strings.concatenate({"ticket=", ticket}), request_id = "r", headers = bind_header}, server_socket)
	buf: [4096]byte
	n, _ := net.recv_tcp(client, buf[:])
	raw := string(buf[:n])
	testing.expect(t, strings.has_prefix(raw, "HTTP/1.1 302"), raw)
	testing.expect(t, strings.contains(raw, "Set-Cookie: __Host-heimdall_preview="), raw)
	testing.expect_value(t, f.repo_state.get_calls, 1) // only the start route's ownership check
}

// Review: a ticket is bound to the browser that started the sign-in, so a
// ticket minted for user A and planted in a victim's browser is useless there.
@(test)
test_preview_ticket_bound_to_starting_browser :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	ticket, _ := preview_flow_ticket(t, f, "owner")
	preview_flow_rebounced(t, preview_flow_redeem(f, ticket, false), "victim browser without the bind cookie")
	// A cookie of the right name and hash-matching value but not minted by the
	// hub (e.g. planted by a previewed app's script as a non-HttpOnly cookie) is
	// refused: its HMAC tag does not verify.
	dot := strings.last_index_byte(f.bind_value, '.')
	forged := strings.concatenate({f.bind_value[:dot], ".AAAAAAAAAAAAAAAAAAAAAA"}, context.temp_allocator)
	owner_session := http_test_login(t, &f.auth, "owner")
	planted_query := strings.concatenate({"session=sh_owned&return_to=%2Fp%2Fsh_owned%2F&bind=", auth_service.sha256_hex(forged), "&bind_id=", f.bind_id}, context.temp_allocator)
	planted_start := preview_flow_start(f, planted_query, owner_session)
	planted_location := preview_flow_header(planted_start, "Location")
	planted := planted_location[strings.index(planted_location, "ticket=") + len("ticket="):] if strings.contains(planted_location, "ticket=") else ""
	preview_flow_rebounced(t, preview_flow_redeem(f, planted, false, preview_flow_bind_cookie(f.bind_id, forged)), "forged bind cookie")
	testing.expect(t, !auth_service.preview_bind_value_ok(&f.auth, f.bind_id, forged))
	testing.expect(t, !auth_service.preview_bind_value_ok(&f.auth, "BBBBBBBB", f.bind_value), "a tag is bound to its flow id")
	testing.expect(t, auth_service.preview_bind_value_ok(&f.auth, f.bind_id, f.bind_value))
	good, _ := preview_flow_ticket(t, f, "owner")
	testing.expect_value(t, preview_flow_redeem(f, good).status, 302)

	// Direct link to start without a bind: bounce to the preview host to bind first.
	owner := http_test_login(t, &f.auth, "owner")
	unbound := preview_flow_start(f, "session=sh_owned&return_to=%2Fp%2Fsh_owned%2Fx", owner)
	testing.expect_value(t, unbound.status, 302)
	testing.expect_value(t, preview_flow_header(unbound, "Location"), "https://preview.example/__heimdall/preview-bind?session=sh_owned&return_to=%2Fp%2Fsh_owned%2Fx&hop=0")
	// The bind endpoint sets the bind cookie and returns to start with bind=sha256(cookie).
	bound := preview_auth_bind(&f.h, Request{method = "GET", path = PREVIEW_BIND_PATH, query = "session=sh_owned&return_to=%2Fp%2Fsh_owned%2Fx", request_id = "r"})
	testing.expect_value(t, bound.status, 302)
	bind_cookie := preview_flow_new_bind(bound)
	for attr in ([]string{"Path=/", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age=300"}) do testing.expect(t, strings.contains(bind_cookie, attr), attr)
	eq := strings.index_byte(bind_cookie, '=')
	new_bind_id := bind_cookie[len(auth_service.PREVIEW_BIND_COOKIE) + 1:eq]
	raw_bind := bind_cookie[eq + 1:strings.index_byte(bind_cookie, ';')]
	location := preview_flow_header(bound, "Location")
	testing.expect(t, strings.has_suffix(location, strings.concatenate({"&bind=", auth_service.sha256_hex(raw_bind), "&bind_id=", new_bind_id, "&hop=1"}, context.temp_allocator)), location)
	// ... and the full direct-link flow then completes in that browser.
	query := location[strings.index_byte(location, '?') + 1:]
	started := preview_flow_start(f, query, owner)
	ticket_location := preview_flow_header(started, "Location")
	prefix := "https://preview.example/__heimdall/preview-auth?ticket="
	testing.expect(t, strings.has_prefix(ticket_location, prefix), ticket_location)
	if strings.has_prefix(ticket_location, prefix) {
		redeemed := preview_flow_redeem(f, ticket_location[len(prefix):], false, preview_flow_bind_cookie(new_bind_id, raw_bind))
		testing.expect_value(t, redeemed.status, 302)
		testing.expect_value(t, preview_flow_header(redeemed, "Location"), "/p/sh_owned/x")
	}
	// The bind endpoint refuses targets outside the preview session.
	bad := preview_auth_bind(&f.h, Request{method = "GET", path = PREVIEW_BIND_PATH, query = "session=sh_owned&return_to=%2F%2Fevil.example", request_id = "r"})
	testing.expect_value(t, bad.status, 400)
}

// Concurrent previews each have their own bind cookie, so two interleaved
// sign-in flows in one browser both succeed.
@(test)
test_preview_interleaved_flows_both_succeed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	nav := Request{method = "GET", path = "/p/sh_owned/a", request_id = "r", headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}}}
	_, _, bounce_a := preview_origin_auth(&f.h, nav)
	nav.path = "/p/sh_owned/b"
	_, _, bounce_b := preview_origin_auth(&f.h, nav)
	pair_of :: proc(resp: Response) -> string {
		v := preview_flow_new_bind(resp)
		return v[:strings.index_byte(v, ';')]
	}
	a_pair, b_pair := pair_of(bounce_a), pair_of(bounce_b)
	testing.expect(t, a_pair[:strings.index_byte(a_pair, '=')] != b_pair[:strings.index_byte(b_pair, '=')], "distinct cookie names per flow")
	owner := http_test_login(t, &f.auth, "owner")
	start_ticket :: proc(t: ^testing.T, f: ^Preview_Flow_Fixture, bounce: Response, owner: []contracts.HTTP_Header) -> string {
		location := preview_flow_header(bounce, "Location")
		started := preview_flow_start(f, location[strings.index_byte(location, '?') + 1:], owner)
		ticket_location := preview_flow_header(started, "Location")
		prefix := "https://preview.example/__heimdall/preview-auth?ticket="
		testing.expect(t, strings.has_prefix(ticket_location, prefix), ticket_location)
		return ticket_location[len(prefix):] if strings.has_prefix(ticket_location, prefix) else ""
	}
	ticket_a := start_ticket(t, f, bounce_a, owner)
	ticket_b := start_ticket(t, f, bounce_b, owner)
	// The browser holds both bind cookies and redeems in the opposite order.
	both := contracts.HTTP_Header{"Cookie", strings.concatenate({a_pair, "; ", b_pair}, context.temp_allocator)}
	rb := preview_flow_redeem(f, ticket_b, false, both)
	testing.expect_value(t, rb.status, 302)
	testing.expect_value(t, preview_flow_header(rb, "Location"), "/p/sh_owned/b")
	ra := preview_flow_redeem(f, ticket_a, false, both)
	testing.expect_value(t, ra.status, 302)
	testing.expect_value(t, preview_flow_header(ra, "Location"), "/p/sh_owned/a")
}

// A browser that never keeps the preview cookie stops after a few bounces with
// a clear page; the hop counter never reaches the app.
@(test)
test_preview_bounce_hop_limit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	nav := Request{method = "GET", path = "/p/sh_owned/a", query = "x=1&__heimdall_hop=2", request_id = "r", headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}}}
	_, _, third := preview_origin_auth(&f.h, nav)
	testing.expect_value(t, third.status, 302)
	location := preview_flow_header(third, "Location")
	testing.expect(t, strings.contains(location, "return_to=%2Fp%2Fsh_owned%2Fa%3Fx%3D1&") && strings.has_suffix(location, "&hop=3"), location)
	nav.query = "x=1&__heimdall_hop=3"
	_, _, stop := preview_origin_auth(&f.h, nav)
	testing.expect_value(t, stop.status, 403)
	testing.expect(t, strings.contains(stop.body, "not keeping the preview cookie"), stop.body)
	testing.expect_value(t, preview_flow_new_bind(stop), "")
	rest, hop := preview_strip_hop("a=1&__heimdall_hop=2&b=2")
	testing.expect_value(t, rest, "a=1&b=2")
	testing.expect_value(t, hop, 2)
	rest, hop = preview_strip_hop("__heimdall_hop=1")
	testing.expect_value(t, rest, "")
	testing.expect_value(t, hop, 1)
}

// Review (a): the bind value carries its mint time under the MAC; a harvested
// value goes stale after the 300 s window, and the timestamp cannot be edited.
@(test)
test_preview_bind_value_expires_and_timestamp_is_authenticated :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	parts := strings.split(f.bind_value, ".")
	testing.expect_value(t, len(parts), 3)
	testing.expect(t, auth_service.preview_bind_value_ok(&f.auth, f.bind_id, f.bind_value))
	// Editing the timestamp breaks the tag.
	bumped := strings.concatenate({parts[0], ".", parts[1], "1", ".", parts[2]})
	testing.expect(t, !auth_service.preview_bind_value_ok(&f.auth, f.bind_id, bumped))
	// A ticket bound to a value redeemed after the window is refused.
	ticket, _ := preview_flow_ticket(t, f, "owner")
	f.now = "2026-10-25T10:00:59Z"
	fresh, _ := preview_flow_ticket(t, f, "owner")
	testing.expect_value(t, preview_flow_redeem(f, fresh).status, 302)
	f.now = "2026-10-25T10:05:01Z" // > 300 s after the bind value was minted
	testing.expect(t, !auth_service.preview_bind_value_ok(&f.auth, f.bind_id, f.bind_value))
	_ = ticket
	late_ticket, _ := preview_flow_ticket(t, f, "owner") // ticket itself is fresh
	preview_flow_rebounced(t, preview_flow_redeem(f, late_ticket), "stale bind value")
	// Distinct sub-keys: the bind tag key is not the login seal key.
	login_key, _ := auth_service.hub_subkey(&f.auth, auth_service.HUB_SUBKEY_LOGIN_SEAL)
	bind_key, _ := auth_service.hub_subkey(&f.auth, auth_service.HUB_SUBKEY_PREVIEW_BIND)
	root, _ := auth_service.hub_process_key(&f.auth)
	testing.expect(t, login_key != bind_key && login_key != root && bind_key != root)
}

// Cookie-bomb cap: beyond PREVIEW_MAX_BIND_COOKIES only the OLDEST bind cookies
// (by the mint time in their values) are expired.
@(test)
test_preview_bind_cookie_bomb_cap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	cookie_list :: proc(n: int) -> string {
		b := strings.builder_make(context.temp_allocator)
		for i in 0 ..< n {
			if i > 0 do strings.write_string(&b, "; ")
			// ids A0..; mint time grows with i (i == 0 is the oldest)
			strings.write_string(&b, fmt.tprintf("__Host-heimdall_preview_bind_ID%06d=r.%d.tag", i, 1792000000000 + i))
		}
		return strings.to_string(b)
	}
	expired_names :: proc(resp: Response) -> [dynamic]string {
		out := make([dynamic]string, context.temp_allocator)
		for h in resp.headers do if strings.equal_fold(h.name, "Set-Cookie") && strings.contains(h.value, "Max-Age=0") && strings.has_prefix(h.value, "__Host-heimdall_preview_bind_") do append(&out, h.value[:strings.index_byte(h.value, '=')])
		return out
	}
	nav := Request{method = "GET", path = "/p/sh_owned/a", request_id = "r", headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}, {"Cookie", cookie_list(auth_service.PREVIEW_MAX_BIND_COOKIES - 1)}}}
	_, _, under := preview_origin_auth(&f.h, nav)
	testing.expect_value(t, len(expired_names(under)), 0) // room for one more
	nav.headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}, {"Cookie", cookie_list(auth_service.PREVIEW_MAX_BIND_COOKIES + 2)}}
	_, _, over := preview_origin_auth(&f.h, nav)
	testing.expect_value(t, over.status, 302)
	gone := expired_names(over)
	testing.expect_value(t, len(gone), 3) // 18 existing + 1 new -> drop the 3 oldest
	if len(gone) == 3 {
		testing.expect_value(t, gone[0], "__Host-heimdall_preview_bind_ID000000")
		testing.expect_value(t, gone[1], "__Host-heimdall_preview_bind_ID000001")
		testing.expect_value(t, gone[2], "__Host-heimdall_preview_bind_ID000002")
	}
	testing.expect(t, strings.contains(preview_flow_new_bind_live(over), "Max-Age=300"), "a fresh bind cookie is still minted")
}

@(private = "file")
preview_flow_new_bind_live :: proc(resp: Response) -> string {
	for h in resp.headers do if strings.equal_fold(h.name, "Set-Cookie") && strings.has_prefix(h.value, "__Host-heimdall_preview_bind_") && !strings.contains(h.value, "Max-Age=0") do return h.value
	return ""
}

// Review (d): the normal path leaves the app's URL clean; the bounce count is
// kept in a short-lived hop cookie, and the URL counter appears from hop 2 on.
@(test)
test_preview_hop_counter_only_on_repeat_bounces :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	ticket, _ := preview_flow_ticket(t, f, "owner")
	first := preview_flow_redeem(f, ticket)
	testing.expect_value(t, preview_flow_header(first, "Location"), "/p/sh_owned/app?x=1")
	hop_cookie := preview_flow_set_cookie(first, auth_service.PREVIEW_HOP_COOKIE)
	testing.expect(t, strings.has_prefix(hop_cookie, "__Host-heimdall_preview_hop=1;") && strings.contains(hop_cookie, "Max-Age=30"), hop_cookie)
	// The browser dropped the preview cookie but kept the hop cookie: next bounce is hop 2.
	nav := Request{method = "GET", path = "/p/sh_owned/app", request_id = "r", headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}, {"Cookie", "__Host-heimdall_preview_hop=1"}}}
	_, _, second := preview_origin_auth(&f.h, nav)
	testing.expect(t, strings.has_suffix(preview_flow_header(second, "Location"), "&hop=2"), preview_flow_header(second, "Location"))
	// A hop-2 ticket returns with the URL counter.
	owner := http_test_login(t, &f.auth, "owner")
	query := strings.concatenate({"session=sh_owned&return_to=%2Fp%2Fsh_owned%2F&bind=", auth_service.sha256_hex(f.bind_value), "&bind_id=", f.bind_id, "&hop=2"})
	started := preview_flow_start(f, query, owner)
	loc := preview_flow_header(started, "Location")
	t2 := loc[strings.index(loc, "ticket=") + len("ticket="):] if strings.contains(loc, "ticket=") else ""
	again := preview_flow_redeem(f, t2)
	testing.expect_value(t, preview_flow_header(again, "Location"), "/p/sh_owned/?__heimdall_hop=2")
}

// After a hub restart every open preview pane bounces at once: six concurrent
// flows (plus stale bind cookies from before the restart) must all complete.
@(test)
test_preview_concurrent_bounces_after_restart_all_succeed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := preview_flow_fixture(t)
	defer auth_service.oidc_free(&f.auth)
	// Stale bind cookies minted by the previous process (unverifiable now).
	jar := make([dynamic]string, context.temp_allocator)
	append(&jar, "__Host-heimdall_preview_bind_OLDOLD01=r.1791999000000.oldtag", "__Host-heimdall_preview_bind_OLDOLD02=r.1791999000001.oldtag")
	jar_header :: proc(jar: [dynamic]string) -> contracts.HTTP_Header {
		return contracts.HTTP_Header{"Cookie", strings.join(jar[:], "; ", context.temp_allocator)}
	}
	apply :: proc(jar: ^[dynamic]string, resp: Response) {
		for h in resp.headers {
			if !strings.equal_fold(h.name, "Set-Cookie") do continue
			pair := h.value[:strings.index_byte(h.value, ';')]
			name := pair[:strings.index_byte(pair, '=')]
			for i := len(jar) - 1; i >= 0; i -= 1 do if strings.has_prefix(jar[i], strings.concatenate({name, "="}, context.temp_allocator)) do ordered_remove(jar, i)
			if !strings.contains(h.value, "Max-Age=0") do append(jar, pair)
		}
	}
	paths := [6]string{"/p/sh_owned/1", "/p/sh_owned/2", "/p/sh_owned/3", "/p/sh_owned/4", "/p/sh_owned/5", "/p/sh_owned/6"}
	bounces: [6]Response
	for p, i in paths {
		nav := Request{method = "GET", path = p, request_id = "r", headers = []contracts.HTTP_Header{{"Sec-Fetch-Mode", "navigate"}, jar_header(jar)}}
		_, _, bounces[i] = preview_origin_auth(&f.h, nav)
		testing.expect_value(t, bounces[i].status, 302)
		apply(&jar, bounces[i])
	}
	owner := http_test_login(t, &f.auth, "owner")
	prefix := "https://preview.example/__heimdall/preview-auth?ticket="
	tickets: [6]string
	for i in 0 ..< 6 {
		location := preview_flow_header(bounces[i], "Location")
		started := preview_flow_start(f, location[strings.index_byte(location, '?') + 1:], owner)
		tl := preview_flow_header(started, "Location")
		testing.expect(t, strings.has_prefix(tl, prefix), tl)
		if strings.has_prefix(tl, prefix) do tickets[i] = tl[len(prefix):]
	}
	for i := 5; i >= 0; i -= 1 { // redeem in reverse, all with the full jar
		resp := preview_flow_redeem(f, tickets[i], false, jar_header(jar))
		testing.expectf(t, resp.status == 302 && preview_flow_header(resp, "Location") == paths[i], "flow %d: %d %s", i, resp.status, preview_flow_header(resp, "Location"))
		testing.expectf(t, preview_flow_set_cookie(resp, auth_service.PREVIEW_COOKIE) != "", "flow %d got a preview session", i)
		apply(&jar, resp)
	}
}
