package main

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import auth "odin_test:hub/service/auth"
import http "odin_test:hub/transport/http"
import httpc "odin_test:lib/httpc"

probe_test_fetch :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	if len(req.headers) != 1 || req.headers[0].name != "Cookie" || req.headers[0].value != strings.concatenate({auth.SESSION_COOKIE, "=good"}, context.temp_allocator) || req.method != .GET || req.max_redirects != 0 || req.timeout_ms != 3000 || len(req.path) != 3 || req.path[0] != "api" || req.path[1] != "v1" || req.path[2] != "me" do return {}, .Invalid_Header
	data := strings.clone(`{"data":{"user_id":"alice"}}`, context.temp_allocator)
	return {status = 200, body = transmute([]byte)data, _allocator = context.temp_allocator}, .None
}
probe_test_denied :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	return {status = 401}, .None
}
@(test)
test_probe_sidecar_checks_only_hub_session_cookie :: proc(t: ^testing.T) {
	checker := Session_Checker{fetch = probe_test_fetch}
	req := http.Request{headers = []contracts.HTTP_Header{{"Cookie", strings.concatenate({auth.SESSION_COOKIE, "=good; unrelated=secret"}, context.temp_allocator)}, {"Authorization", "Bearer must-not-forward"}, {"X-authentik-username", "attacker"}}}
	principal, ok := resolve_session(&checker, req)
	testing.expect(t, ok)
	testing.expect_value(t, principal.user_id, "alice")
	testing.expect_value(t, principal.kind, contracts.Auth_Kind.Session)
	req.headers = []contracts.HTTP_Header{{"Authorization", "Bearer must-not-authenticate"}, {"X-authentik-username", "attacker"}}
	_, ok = resolve_session(&checker, req)
	testing.expect(t, !ok)
	checker.fetch = probe_test_denied
	req.headers = []contracts.HTTP_Header{{"Cookie", strings.concatenate({auth.SESSION_COOKIE, "=good"}, context.temp_allocator)}}
	_, ok = resolve_session(&checker, req)
	testing.expect(t, !ok)
}
