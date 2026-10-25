package http

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"

// Phase 3: users authenticate only with OIDC. HTTP-level tests sign a user in by
// minting a Hub browser session in an in-memory session store (the in-process
// equivalent of a completed OIDC login) and sending its cookie.

// http_test_enable_sessions wires an in-memory session store on `auth` once.
// The store lives on the untracked heap for the rest of the test process.
http_test_enable_sessions :: proc(auth: ^auth_service.Auth_Service) {
	if auth.sessions == nil do _ = auth_service.use_memory_sessions(auth)
	auth.web.enabled = true
}

// http_test_session_headers mints a session without a testing.T (for helpers
// that have none); returns nil when minting fails.
http_test_session_headers :: proc(auth: ^auth_service.Auth_Service, user_id: string) -> []contracts.HTTP_Header {
	http_test_enable_sessions(auth)
	context.allocator = context.temp_allocator
	raw, ok := auth_service.mint_session(auth, user_id)
	if !ok do return nil
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = auth_service.session_cookie_request_header(raw)
	return headers
}

// http_test_login returns request headers that authenticate as `user_id`
// (provisioned on first use). All memory is on the test's temp allocator.
http_test_login :: proc(t: ^testing.T, auth: ^auth_service.Auth_Service, user_id: string) -> []contracts.HTTP_Header {
	http_test_enable_sessions(auth)
	headers := make([]contracts.HTTP_Header, 1, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		raw, ok := auth_service.mint_session(auth, user_id)
		testing.expectf(t, ok, "mint a session for %s", user_id)
		headers[0] = auth_service.session_cookie_request_header(raw)
	}
	return headers
}

// http_test_login_cookie returns just the `Cookie` header value for `user_id`.
http_test_login_cookie :: proc(t: ^testing.T, auth: ^auth_service.Auth_Service, user_id: string) -> contracts.HTTP_Header {
	return http_test_login(t, auth, user_id)[0]
}

// http_test_preview_headers signs `user_id` in on the dedicated preview origin:
// a Hub session, a handoff ticket for `shell_session_id`, redeemed into the
// __Host-heimdall_preview cookie. Returns the preview-origin Cookie header.
http_test_preview_headers :: proc(t: ^testing.T, auth: ^auth_service.Auth_Service, user_id, shell_session_id: string) -> []contracts.HTTP_Header {
	session := http_test_login(t, auth, user_id)
	headers := make([]contracts.HTTP_Header, 1, context.temp_allocator)
	{
		context.allocator = context.temp_allocator
		principal, ok, err := auth_service.resolve_auth(auth, auth_service.Auth_Request{headers = session})
		testing.expectf(t, ok, "session principal for %s: %s", user_id, err.message)
		return_to := strings.concatenate({"/p/", shell_session_id, "/"})
		bind := "test-preview-bind-0123456789abcdef"
		ticket, mint_err := auth_service.preview_ticket_mint(auth, principal, shell_session_id, return_to, auth_service.sha256_hex(bind))
		testing.expectf(t, mint_err.code == .None, "mint preview ticket: %s", mint_err.message)
		raw, _, _, stage, redeemed := auth_service.preview_ticket_redeem(auth, ticket, bind)
		testing.expectf(t, redeemed, "redeem preview ticket: %s", stage)
		headers[0] = contracts.HTTP_Header{"Cookie", strings.concatenate({auth_service.PREVIEW_COOKIE, "=", raw})}
	}
	return headers
}
