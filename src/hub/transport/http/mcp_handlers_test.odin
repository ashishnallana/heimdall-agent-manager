package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import users "odin_test:hub/service/user"

MCP_Test_Fixture :: struct {
	conn: sqlite.Conn,
	user_impl: sqlite.User_Repo_SQLite,
	user_repo: iface.User_Repository,
	users: users.User_Service,
	auth: auth.Auth_Service,
	clock: platform.Clock,
}
mcp_test_now :: proc(ctx: rawptr) -> string {return "2026-10-31T07:00:00Z"}
mcp_test_fixture :: proc(t: ^testing.T) -> ^MCP_Test_Fixture {
	f := new(MCP_Test_Fixture, context.temp_allocator)
	conn, ok, _ := sqlite.open(":memory:")
	testing.expect(t, ok); f.conn = conn
	migrated, _ := sqlite.run_migrations(&f.conn); testing.expect(t, migrated)
	f.user_repo = sqlite.new_user_repository(&f.user_impl, &f.conn)
	f.clock = {now = mcp_test_now}
	f.users = users.new_user_service_basic(&f.user_repo, &f.clock, nil)
	_, saved, _ := iface.user_save(&f.user_repo, domain.User{user_id = "alice", name = "alice", status = .Active, created_at = mcp_test_now(nil), updated_at = mcp_test_now(nil)})
	testing.expect(t, saved)
	f.auth = {users = &f.users, clock = &f.clock}
	http_test_enable_sessions(&f.auth)
	return f
}

@(test)
test_mcp_probe_metadata_routes_are_exact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	h := MCP_Spike_Handlers{origin = "https://hub.example.test"}
	r := new_router(); defer router_free(&r)
	router_add(&r, "GET", MCP_SPIKE_METADATA, &h, mcp_spike_metadata_handler)
	resp := router_dispatch(&r, {method = "GET", path = MCP_SPIKE_METADATA})
	testing.expect_value(t, resp.status, 200)
	data: struct {resource: string, authorization_servers: []string}
	testing.expect(t, json.unmarshal_string(resp.body, &data, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, data.resource, "https://hub.example.test/api/v1/mcp-spike")
	for path in ([]string{"/.well-known/oauth-protected-resource/other", "/.well-known/other", "/policy"}) {
		testing.expect_value(t, router_dispatch(&r, {method = "GET", path = path}).status, 404)
	}
	testing.expect_value(t, router_dispatch(&r, {method = "POST", path = MCP_SPIKE_METADATA}).status, 404)
	r2 := new_router(); defer router_free(&r2)
	testing.expect_value(t, router_dispatch(&r2, {method = "GET", path = MCP_SPIKE_METADATA}).status, 404)
}
@(test)
test_mcp_probe_login_resume_and_oauth_exchange :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := mcp_test_fixture(t)
	defer sqlite.close(&f.conn)
	s: mcp.Store; mcp.init(&s); defer mcp.free(&s)
	h := MCP_Spike_Handlers{auth = &f.auth, store = &s, origin = "https://hub.example.test"}
	client, _ := mcp.register(&s, "https://client.example/callback")
	verifier := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
	query := strings.concatenate({"response_type=code&client_id=", client, "&redirect_uri=https%3A%2F%2Fclient.example%2Fcallback&code_challenge_method=S256&code_challenge=", auth.pkce_challenge_s256(verifier), "&resource=https%3A%2F%2Fhub.example.test%2Fapi%2Fv1%2Fmcp-spike&state=client-state"})
	begin := mcp_spike_authorize_handler(&h, {method = "GET", query = query})
	testing.expect_value(t, begin.status, 302)
	login_location := header_value(begin.headers, "Location")
	testing.expect(t, strings.has_prefix(login_location, "/api/v1/auth/login?return_to="))
	return_to := query_value(login_location[len("/api/v1/auth/login?"):], "return_to")
	_, safe := auth.safe_return_to(return_to)
	testing.expect(t, safe)
	resume_query := return_to[strings.index_byte(return_to, '?') + 1:]
	ready := mcp_spike_authorize_handler(&h, {method = "GET", query = resume_query, headers = http_test_login(t, &f.auth, "alice")})
	testing.expect_value(t, ready.status, 302)
	callback := header_value(ready.headers, "Location")
	testing.expect(t, strings.has_prefix(callback, "https://client.example/callback?"))
	callback_query := callback[strings.index_byte(callback, '?') + 1:]
	testing.expect_value(t, query_value(callback_query, "state"), "client-state")
	code := query_value(callback_query, "code")
	form := strings.concatenate({"grant_type=authorization_code&client_id=", client, "&code=", code, "&redirect_uri=https%3A%2F%2Fclient.example%2Fcallback&code_verifier=", verifier, "&resource=https%3A%2F%2Fhub.example.test%2Fapi%2Fv1%2Fmcp-spike"})
	req := Request{method = "POST", body = form, headers = []contracts.HTTP_Header{{"Content-Type", "application/x-www-form-urlencoded"}}}
	token_reply := mcp_spike_token_handler(&h, req)
	testing.expect_value(t, token_reply.status, 200)
	testing.expect_value(t, header_value(token_reply.headers, "Cache-Control"), "no-store")
	tokens: mcp.Tokens
	testing.expect(t, json.unmarshal_string(token_reply.body, &tokens, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, tokens.token_type, "Bearer")
	testing.expect_value(t, mcp_spike_token_handler(&h, req).status, 400)
	probe := Request{method = "POST", body = `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe"}}`, headers = []contracts.HTTP_Header{{"Content-Type", "application/json"}, {"Authorization", strings.concatenate({"Bearer ", tokens.access_token})}}}
	testing.expect_value(t, mcp_spike_handler(&h, probe).status, 200)
	initialize := probe
	initialize.body = `{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18"}}`
	init_reply := mcp_spike_handler(&h, initialize)
	testing.expect_value(t, init_reply.status, 200)
	testing.expect(t, strings.contains(init_reply.body, "2025-06-18"))
	initialize.method = "GET"
	testing.expect_value(t, mcp_spike_handler(&h, initialize).status, 405)
	refresh_form := strings.concatenate({"grant_type=refresh_token&client_id=", client, "&refresh_token=", tokens.refresh_token, "&resource=https%3A%2F%2Fhub.example.test%2Fapi%2Fv1%2Fmcp-spike"})
	req.body = refresh_form
	testing.expect_value(t, mcp_spike_token_handler(&h, req).status, 200)
	testing.expect_value(t, mcp_spike_token_handler(&h, req).status, 400)
	probe.headers = []contracts.HTTP_Header{{"Content-Type", "application/json"}, {"Authorization", strings.concatenate({"Bearer ", tokens.refresh_token})}}
	testing.expect_value(t, mcp_spike_handler(&h, probe).status, 401)
}
@(test)
test_mcp_probe_unauthenticated_and_parameter_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := mcp_test_fixture(t)
	defer sqlite.close(&f.conn)
	s: mcp.Store; mcp.init(&s); defer mcp.free(&s)
	h := MCP_Spike_Handlers{auth = &f.auth, store = &s, origin = "https://hub.example.test"}
	resp := mcp_spike_handler(&h, {method = "POST"})
	testing.expect_value(t, resp.status, 401)
	testing.expect(t, strings.contains(header_value(resp.headers, "WWW-Authenticate"), MCP_SPIKE_METADATA))
	testing.expect_value(t, mcp_spike_handler(&h, {method = "POST", headers = []contracts.HTTP_Header{{"Origin", "https://evil.example"}}}).status, 403)
	for form in ([]string{"client_id=a&client_id=b", "%63lient_id=a", "client_id=a&broken", "=x"}) do testing.expect(t, !mcp_form_unique(form))
	testing.expect(t, mcp_form_unique("client_id=a&code_verifier=b"))
	testing.expect_value(t, mcp_spike_authorize_handler(&h, {query = "client_id=a&client_id=b"}).status, 400)
}
