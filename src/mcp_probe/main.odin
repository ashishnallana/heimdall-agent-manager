package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import http "odin_test:hub/transport/http"
import httpc "odin_test:lib/httpc"

// This process knows no provider secret and has no database or vault access.
// Its only authority is a browser's existing Hub session, checked by /me.
Session_Checker :: struct {
	hub: httpc.Url,
	// Test-only injection. Production uses httpc.send with the fixed loopback URL.
	fetch: proc(req: httpc.Request) -> (httpc.Response, httpc.Error),
}
resolve_session :: proc(ctx: rawptr, req: http.Request) -> (contracts.Auth_Context, bool) {
	checker := (^Session_Checker)(ctx)
	raw, found := auth.cookie_value(req.headers, auth.SESSION_COOKIE)
	if !found || raw == "" || len(raw) > 2048 do return {}, false
	// Copy only the named Hub session cookie, never arbitrary Cookie or bearer
	// headers. The destination is fixed loopback; redirects are not followed.
	upstream := httpc.Request{
		method = .GET, url = checker.hub, path = {"api", "v1", "me"},
		headers = {{"Cookie", strings.concatenate({auth.SESSION_COOKIE, "=", raw}, context.temp_allocator)}},
		timeout_ms = 3000, connect_timeout_ms = 1000, max_response_bytes = 8192,
	}
	resp: httpc.Response
	err: httpc.Error
	if checker.fetch != nil {
		resp, err = checker.fetch(upstream)
	} else {
		resp, err = httpc.send(upstream)
	}
	defer httpc.response_destroy(&resp)
	if err != .None || resp.status != 200 do return {}, false
	body: struct {data: struct {user_id: string}}
	if json.unmarshal(resp.body, &body, .JSON, context.temp_allocator) != nil || body.data.user_id == "" do return {}, false
	return contracts.Auth_Context{kind = .Session, user_id = strings.clone(body.data.user_id, context.temp_allocator)}, true
}

main :: proc() {
	origin := ""
	port := 8120
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--origin" && i + 1 < len(os.args) {
			origin = os.args[i + 1]; i += 1
		} else if arg == "--port" && i + 1 < len(os.args) {
			p, ok := strconv.parse_int(os.args[i + 1]); i += 1
			if !ok || p < 1024 || p > 65535 {fmt.eprintln("invalid probe port"); os.exit(2)}
			port = int(p)
		} else {fmt.eprintln("usage: ham-mcp-probe --origin https://HOST [--port 8120]"); os.exit(2)}
	}
	// Explicit host-only HTTPS origin, never inferred from Host/forwarded headers.
	if !strings.has_prefix(origin, "https://") || len(origin) <= 8 || strings.contains_any(origin[8:], "/?#@\\ \r\n\t") {fmt.eprintln("probe requires HTTPS origin without path"); os.exit(2)}
	_, origin_err := httpc.parse_url(origin)
	if origin_err != .None {fmt.eprintln("invalid probe origin"); os.exit(2)}
	hub, err := httpc.parse_url("http://127.0.0.1:8113")
	if err != .None {fmt.eprintln("cannot initialize HTTP client"); os.exit(1)}
	checker := Session_Checker{hub = hub}
	clock := platform.real_clock()
	clock_auth := auth.Auth_Service{clock = &clock}
	store: mcp.Store; mcp.init(&store); defer mcp.free(&store)
	handlers := http.MCP_Spike_Handlers{auth = &clock_auth, store = &store, origin = origin, resolve_user = resolve_session, resolve_ctx = &checker}
	router := http.new_router(); defer http.router_free(&router)
	http.mcp_spike_register_routes(&router, &handlers)
	fmt.println("Synthetic MCP OAuth probe; no vault access; upstream identity check on loopback Hub")
	if !http.serve(&router, {bind_host = "127.0.0.1", port = port, ui_origin = origin}) do os.exit(1)
}
