package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"

// Browser login routes (docs/plans/oidc-only-auth.md, "Browser session flow").
// All are public. Cookies use the __Host- prefix (Secure, Path=/, no Domain) so
// no sibling origin -- including the preview origin -- can set or read them.

AUTH_ERROR_REDIRECT :: "/?auth_error=1"
AUTH_FORBIDDEN_REDIRECT :: "/?auth_error=forbidden"

// plain_response builds a text/plain response whose headers live in the request's
// temp allocator (safe to return).
plain_response :: proc(status: int, body: string, headers: ..contracts.HTTP_Header) -> Response {
	out := make([]contracts.HTTP_Header, len(headers), context.temp_allocator)
	copy(out, headers)
	return Response{status = status, content_type = "text/plain", body = body, headers = out}
}

redirect_response :: proc(location: string, cookies: ..string) -> Response {
	headers := make([]contracts.HTTP_Header, 2 + len(cookies), context.temp_allocator)
	headers[0] = {"Location", location}
	headers[1] = {"Cache-Control", "no-store"}
	for cookie, i in cookies do headers[2 + i] = {"Set-Cookie", cookie}
	return Response{status = 302, content_type = "text/plain", body = "", headers = headers}
}

// GET /api/v1/auth/login?return_to=<same-origin path>
auth_login_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	if !auth_service.web_login_enabled(handlers.auth) do return respond_error(domain.domain_error(.Not_Found, "browser login is not configured"), req.request_id)
	client_ip := device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), handlers.forwarded_for_cidrs)
	url, sealed, ok, err := auth_service.web_login_begin(handlers.auth, query_value(req.query, "return_to"), client_ip)
	if !ok {
		if err.code == .Validation_Failed || err.code == .Rate_Limited do return respond_error(err, req.request_id)
		fmt.printfln("ham-hub oidc_login_rejected stage=begin")
		return redirect_response(AUTH_ERROR_REDIRECT)
	}
	return redirect_response(url, auth_service.login_cookie_header(sealed))
}

// GET /api/v1/auth/callback?code=...&state=...
auth_callback_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	if !auth_service.web_login_enabled(handlers.auth) do return respond_error(domain.domain_error(.Not_Found, "browser login is not configured"), req.request_id)
	clear_login := auth_service.expired_cookie_header(auth_service.LOGIN_COOKIE)
	query_state := query_value(req.query, "state")
	login_cookie, _ := auth_service.cookie_value(req.headers, auth_service.LOGIN_COOKIE)
	if query_value(req.query, "error") != "" {
		// The provider refused (user cancelled, consent denied, ...). Consume the
		// state so it cannot be used later; never echo the provider's text.
		auth_service.web_login_abort(handlers.auth, query_state, login_cookie)
		fmt.printfln("ham-hub oidc_login_rejected stage=provider_error")
		return redirect_response(AUTH_ERROR_REDIRECT, clear_login)
	}
	raw_session, return_to, failure, stage := auth_service.web_login_complete(handlers.auth, query_state, login_cookie, query_value(req.query, "code"), header_value(req.headers, "User-Agent"))
	switch failure {
	case .None:
	case .Forbidden:
		fmt.printfln("ham-hub oidc_login_rejected stage=%s", stage)
		return redirect_response(AUTH_FORBIDDEN_REDIRECT, clear_login)
	case .Failed:
		fmt.printfln("ham-hub oidc_login_rejected stage=%s", stage)
		return redirect_response(AUTH_ERROR_REDIRECT, clear_login)
	}
	ttl := handlers.auth.web.session_ttl_ms
	if ttl <= 0 do ttl = auth_service.DEFAULT_SESSION_TTL_HOURS * 3_600_000
	return redirect_response(return_to, auth_service.session_cookie_header(raw_session, ttl / 1000), clear_login)
}

// POST /api/v1/auth/logout. Cross-site POSTs are refused by csrf_decide before
// dispatch. Always succeeds: the cookie is expired whether or not it was valid.
auth_logout_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^User_Handlers)(ctx)
	logout_url := auth_service.web_logout(handlers.auth, req.headers)
	resp := respond_success_typed(Auth_Logout_Reply{logout_url = logout_url}, req.request_id, auth_ctx_server_time(req))
	headers := make([]contracts.HTTP_Header, len(resp.headers) + 2, context.temp_allocator)
	copy(headers, resp.headers)
	headers[len(resp.headers)] = {"Set-Cookie", auth_service.expired_cookie_header(auth_service.SESSION_COOKIE)}
	headers[len(resp.headers) + 1] = {"Cache-Control", "no-store"}
	resp.headers = headers
	return resp
}

// Stream_Auth_Guard re-validates a long-lived stream's principal: a Session is
// checked against the session store (logout or expiry ends the stream), an OIDC
// bearer against its token expiry. Checks are
// throttled; non-user principals (agents, bridges) are not re-checked here.
STREAM_AUTH_RECHECK_MS :: 30_000

Stream_Auth_Guard :: struct {
	auth: ^auth_service.Auth_Service,
	principal: contracts.Auth_Context,
	next_check_ms: i64,
}

stream_auth_guard_make :: proc(auth: ^auth_service.Auth_Service, principal: contracts.Auth_Context) -> Stream_Auth_Guard {
	return Stream_Auth_Guard{auth = auth, principal = principal}
}

// stream_auth_still_valid returns false once the principal must be disconnected.
stream_auth_still_valid :: proc(guard: ^Stream_Auth_Guard) -> bool {
	if guard == nil || guard.auth == nil do return true
	if !contracts.is_user_auth(guard.principal) do return true
	now, ok := auth_service.now_unix_ms(guard.auth)
	if !ok do return true
	// A hard bound (session absolute expiry / token exp) is enforced on every call.
	if guard.principal.expires_ms > 0 && now >= guard.principal.expires_ms do return false
	if now < guard.next_check_ms do return true
	guard.next_check_ms = now + STREAM_AUTH_RECHECK_MS
	return auth_service.live_user_authorized(guard.auth, guard.principal)
}
