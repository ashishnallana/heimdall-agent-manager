package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"

// Disabled by default. This transport exposes only synthetic U0 probe results.
// It cannot call chain, content, vault or agent services.
MCP_Spike_Handlers :: struct {
	auth: ^auth.Auth_Service,
	store: ^mcp.Store,
	origin: string,
	// Standalone synthetic probe: resolve the existing Hub cookie through its
	// owner-authenticated /me endpoint. Never accepts a caller-supplied identity.
	resolve_user: proc(ctx: rawptr, req: Request) -> (contracts.Auth_Context, bool),
	resolve_ctx: rawptr,
}
MCP_SPIKE_PATH :: "/api/v1/mcp-spike"
MCP_SPIKE_OAUTH :: "/api/v1/mcp-spike/oauth"
MCP_SPIKE_METADATA :: "/.well-known/oauth-protected-resource/api/v1/mcp-spike"

mcp_spike_register_routes :: proc(router: ^Router, h: ^MCP_Spike_Handlers) {
	ctx := rawptr(h)
	for path in ([]string{MCP_SPIKE_METADATA, "/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"}) do router_add(router, "GET", path, ctx, mcp_spike_metadata_handler)
	router_add(router, "GET", "/api/v1/mcp-spike/oauth/authorize", ctx, mcp_spike_authorize_handler)
	router_add(router, "POST", "/api/v1/mcp-spike/oauth/register", ctx, mcp_spike_register_handler)
	router_add(router, "POST", "/api/v1/mcp-spike/oauth/token", ctx, mcp_spike_token_handler)
	router_add(router, "ANY", MCP_SPIKE_PATH, ctx, mcp_spike_handler)
}

mcp_discovery_path :: proc(path: string) -> bool {
	return path == MCP_SPIKE_METADATA || path == "/.well-known/oauth-protected-resource/api/v1/mcp" || path == "/.well-known/oauth-protected-resource" || path == "/.well-known/oauth-authorization-server"
}
mcp_json :: proc(value: $T, status := 200) -> Response {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil do return plain_response(500, "response encoding failed")
	headers := make([]contracts.HTTP_Header, 2, context.temp_allocator)
	headers[0] = {"Cache-Control", "no-store"}
	headers[1] = {"Pragma", "no-cache"}
	return {status = status, content_type = "application/json", body = string(data), headers = headers}
}
mcp_oauth_error :: proc(code: string, status := 400) -> Response {
	return mcp_json(struct {error: string}{code}, status)
}
mcp_spike_metadata_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Spike_Handlers)(ctx)
	if req.path == "/.well-known/oauth-authorization-server" {
		return mcp_json(struct {
			issuer, authorization_endpoint, token_endpoint, registration_endpoint: string,
			response_types_supported, grant_types_supported, code_challenge_methods_supported, token_endpoint_auth_methods_supported, scopes_supported: []string,
		}{h.origin, strings.concatenate({h.origin, MCP_SPIKE_OAUTH, "/authorize"}), strings.concatenate({h.origin, MCP_SPIKE_OAUTH, "/token"}), strings.concatenate({h.origin, MCP_SPIKE_OAUTH, "/register"}), []string{"code"}, []string{"authorization_code", "refresh_token"}, []string{"S256"}, []string{"none"}, []string{mcp.SCOPE}})
	}
	return mcp_json(struct {resource: string, authorization_servers, scopes_supported, bearer_methods_supported: []string}{strings.concatenate({h.origin, MCP_SPIKE_PATH}), []string{h.origin}, []string{mcp.SCOPE}, []string{"header"}})
}
mcp_spike_register_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Spike_Handlers)(ctx)
	if len(req.body) > 8192 || !strings.has_prefix(header_value(req.headers, "Content-Type"), "application/json") do return mcp_oauth_error("invalid_client_metadata")
	input: struct {redirect_uris: []string, token_endpoint_auth_method: string, grant_types, response_types: []string}
	if json.unmarshal(transmute([]byte)req.body, &input, .JSON, context.temp_allocator) != nil || len(input.redirect_uris) != 1 do return mcp_oauth_error("invalid_redirect_uri")
	if input.token_endpoint_auth_method != "" && input.token_endpoint_auth_method != "none" do return mcp_oauth_error("invalid_client_metadata")
	for grant in input.grant_types do if grant != "authorization_code" && grant != "refresh_token" do return mcp_oauth_error("invalid_client_metadata")
	for response in input.response_types do if response != "code" do return mcp_oauth_error("invalid_client_metadata")
	id, ok := mcp.register(h.store, input.redirect_uris[0])
	if !ok do return mcp_oauth_error("invalid_client_metadata")
	return mcp_json(struct {client_id: string, redirect_uris: []string, token_endpoint_auth_method: string, grant_types, response_types: []string}{id, input.redirect_uris, "none", []string{"authorization_code", "refresh_token"}, []string{"code"}}, 201)
}
// Reject duplicate parameters, including percent-encoded names; downstream reads
// use canonical literal names. No ambiguous first-value/last-value OAuth binding.
mcp_form_unique :: proc(form: string, max_bytes:=8192) -> bool {
	if len(form) > max_bytes do return false
	seen := make(map[string]bool, context.temp_allocator)
	for part in strings.split(form, "&", context.temp_allocator) {
		eq := strings.index_byte(part, '=')
		if eq <= 0 do return false
		key := part[:eq]
		for c in key do if !((c >= 'a' && c <= 'z') || c == '_') do return false
		if seen[key] do return false
		seen[key] = true
	}
	return true
}
mcp_spike_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Spike_Handlers)(ctx)
	if !mcp_form_unique(req.query) do return mcp_oauth_error("invalid_request")
	now, clock_ok := auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable", 503)
	query := req.query
	resume := query_value(query, "request")
	if resume != "" {
		form, found := mcp.pending_read(h.store, resume, now)
		if !found do return mcp_oauth_error("invalid_request")
		query = form
	}
	client := query_value(query, "client_id")
	redirect := query_value(query, "redirect_uri")
	challenge := query_value(query, "code_challenge")
	state := query_value(query, "state")
	resource := strings.concatenate({h.origin, MCP_SPIKE_PATH})
	scope := query_value(query, "scope")
	if !mcp.binding_ok(h.store, client, redirect) || !mcp.challenge_ok(challenge) || len(state) > 1024 || query_value(query, "response_type") != "code" || query_value(query, "code_challenge_method") != "S256" || query_value(query, "resource") != resource || (scope != "" && scope != mcp.SCOPE) do return mcp_oauth_error("invalid_request")
	// This is existing provider login and cookie resolution, not acceptance of a
	// provider bearer as an MCP credential. Probe grants disclose no user data.
	principal: contracts.Auth_Context
	ok: bool
	if h.resolve_user != nil {
		principal, ok = h.resolve_user(h.resolve_ctx, req)
	} else {
		principal, ok, _ = require_auth(h.auth, req)
	}
	if !ok {
		if resume == "" {
			ticket, made := mcp.pending_begin(h.store, query, now)
			if !made do return mcp_oauth_error("temporarily_unavailable", 503)
			resume = ticket
		}
		return_to := strings.concatenate({MCP_SPIKE_OAUTH, "/authorize?request=", resume})
		return redirect_response(strings.concatenate({"/api/v1/auth/login?return_to=", auth.form_encode(return_to)}))
	}
	if principal.kind != .Session do return mcp_oauth_error("access_denied", 403)
	if resume != "" {
		_, consumed := mcp.pending_read(h.store, resume, now, true)
		if !consumed do return mcp_oauth_error("invalid_request")
	}
	code, made := mcp.authorize(h.store, principal.user_id, client, redirect, challenge, now)
	if !made do return mcp_oauth_error("temporarily_unavailable", 503)
	separator := "&" if strings.contains(redirect, "?") else "?"
	return redirect_response(strings.concatenate({redirect, separator, "code=", auth.form_encode(code), "&state=", auth.form_encode(state)}))
}
mcp_spike_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Spike_Handlers)(ctx)
	if !strings.has_prefix(header_value(req.headers, "Content-Type"), "application/x-www-form-urlencoded") || !mcp_form_unique(req.body) do return mcp_oauth_error("invalid_request")
	if header_value(req.headers, "Authorization") != "" do return mcp_oauth_error("invalid_client", 401)
	if query_value(req.body, "resource") != strings.concatenate({h.origin, MCP_SPIKE_PATH}) do return mcp_oauth_error("invalid_target")
	now, clock_ok := auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable", 503)
	tokens: mcp.Tokens
	ok: bool
	switch query_value(req.body, "grant_type") {
	case "authorization_code":
		tokens, ok = mcp.exchange(h.store, query_value(req.body, "code"), query_value(req.body, "client_id"), query_value(req.body, "redirect_uri"), query_value(req.body, "code_verifier"), now)
	case "refresh_token":
		tokens, ok = mcp.refresh(h.store, query_value(req.body, "refresh_token"), query_value(req.body, "client_id"), now)
	case: return mcp_oauth_error("unsupported_grant_type")
	}
	if !ok do return mcp_oauth_error("invalid_grant")
	// Fixed operation names only. Never log credentials, bindings or bodies.
	fmt.println("mcp_probe token_issued", query_value(req.body, "grant_type"))
	return mcp_json(tokens)
}
mcp_spike_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Spike_Handlers)(ctx)
	if origin := header_value(req.headers, "Origin"); origin != "" && origin != h.origin do return mcp_oauth_error("access_denied", 403)
	now, clock_ok := auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable", 503)
	bearer := header_value(req.headers, "Authorization")
	if !strings.has_prefix(bearer, "Bearer ") || !mcp.validate(h.store, strings.trim_prefix(bearer, "Bearer "), now) {
		resp := mcp_oauth_error("invalid_token", 401)
		append_headers := make([]contracts.HTTP_Header, len(resp.headers) + 1, context.temp_allocator)
		copy(append_headers, resp.headers)
		append_headers[len(resp.headers)] = {"WWW-Authenticate", strings.concatenate({"Bearer resource_metadata=\"", h.origin, MCP_SPIKE_METADATA, "\", scope=\"", mcp.SCOPE, "\""})}
		resp.headers = append_headers
		return resp
	}
	if req.method == "GET" do return plain_response(405, "SSE not offered", {"Allow", "POST"})
	if req.method != "POST" do return plain_response(405, "method not allowed", {"Allow", "POST, GET"})
	if len(req.body) > 8192 || !strings.has_prefix(header_value(req.headers, "Content-Type"), "application/json") do return mcp_oauth_error("invalid_request")
	rpc: struct {jsonrpc: string, id: json.Value, method: string, params: struct {name: string, protocolVersion: string}}
	if json.unmarshal(transmute([]byte)req.body, &rpc, .JSON, context.temp_allocator) != nil || rpc.jsonrpc != "2.0" do return mcp_oauth_error("invalid_request")
	if rpc.id == nil {
		if rpc.method == "notifications/initialized" || rpc.method == "notifications/cancelled" do return plain_response(202, "")
		return mcp_oauth_error("invalid_request")
	}
	switch rpc.method {
	case "initialize":
		version := "2025-11-25"
		if rpc.params.protocolVersion == "2025-03-26" || rpc.params.protocolVersion == "2025-06-18" do version = rpc.params.protocolVersion
		return mcp_json(struct {jsonrpc: string, id: json.Value, result: struct {protocolVersion: string, capabilities: struct {tools: struct {}}, serverInfo: struct {name, version: string}, instructions: string}}{"2.0", rpc.id, {version, {{}}, {"ninjy-oauth-probe", "0.1.0"}, "Synthetic OAuth interoperability probe only. No vault or chain access."}})
	case "ping":
		return mcp_json(struct {jsonrpc: string, id: json.Value, result: struct {}}{"2.0", rpc.id, {}})
	case "tools/list":
		return mcp_json(struct {jsonrpc: string, id: json.Value, result: struct {tools: []struct {name, description: string, inputSchema: struct {type: string, properties: struct {}}}}}{"2.0", rpc.id, {[]struct {name, description: string, inputSchema: struct {type: string, properties: struct {}}}{{"probe", "Confirm OAuth connectivity with synthetic data only", {"object", {}}}}}})
	case "tools/call":
		if rpc.params.name == "probe" {
			fmt.println("mcp_probe tool_called probe")
			return mcp_json(struct {jsonrpc: string, id: json.Value, result: struct {content: []struct {type, text: string}, isError: bool}}{"2.0", rpc.id, {[]struct {type, text: string}{{"text", fmt.tprintf("Ninjy OAuth probe connected. Synthetic data only; no vault access. Server time: %d", now)}}, false}})
		}
	}
	return mcp_json(struct {jsonrpc: string, id: json.Value, error: struct {code: int, message: string}}{"2.0", rpc.id, {-32601, "Method or tool not found"}})
}
