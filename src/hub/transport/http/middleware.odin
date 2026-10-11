package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"

require_auth :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	return ctx, true, Response{}
}

require_trusted_proxy_auth :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_trusted_proxy_auth(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	return ctx, true, Response{}
}

csrf_origin_equal :: proc(left, right: string) -> bool {
	return strings.equal_fold(strings.trim_right(strings.trim_space(left), "/"), strings.trim_right(strings.trim_space(right), "/"))
}

csrf_decide :: proc(method: string, headers: []contracts.HTTP_Header, ui_origin: string, is_upgrade: bool) -> (bool, string) {
	if ui_origin == "" do return true, ""
	cookie := header_value(headers, "Cookie")
	origin := header_value(headers, "Origin")
	if is_upgrade && cookie != "" {
		if origin == "" do return false, "WebSocket requests with cookies require Origin"
		if !csrf_origin_equal(origin, ui_origin) do return false, "WebSocket Origin does not match the UI origin"
	}
	if !is_upgrade && (strings.equal_fold(method, "GET") || strings.equal_fold(method, "HEAD") || strings.equal_fold(method, "OPTIONS")) {
		return true, ""
	}
	sec_fetch_site := header_value(headers, "Sec-Fetch-Site")
	if sec_fetch_site != "" {
		if strings.equal_fold(sec_fetch_site, "same-origin") do return true, ""
		if !is_upgrade && strings.equal_fold(sec_fetch_site, "none") && strings.equal_fold(header_value(headers, "Sec-Fetch-Mode"), "navigate") {
			return true, ""
		}
		return false, "Sec-Fetch-Site is not same-origin"
	}
	if origin != "" {
		if csrf_origin_equal(origin, ui_origin) do return true, ""
		return false, "Origin does not match the UI origin"
	}
	if cookie == "" do return true, ""
	return false, "requests with cookies require same-origin browser metadata"
}

reject_query_or_body_token :: proc(req: Request) -> (bool, Response) {
	if auth_service.token_in_query_or_body(req.query, req.body) {
		return true, respond_error(domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header"), req.request_id)
	}
	return false, Response{}
}

require_auth_any :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth_any(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok {
		// Checkpoint 1: a BARE bridge token was REJECTED on a shared endpoint.
		//
		// This checkpoint used to fire on ACCEPTANCE — `ctx.kind == .Bridge_Token`
		// could only arise from the monitor bare-token allowance in
		// resolve_auth_any, so its presence was the signal. REQ-IMPL-6 deleted that
		// allowance, so the acceptance can no longer happen and the old test would
		// have become permanently dead. The audit signal is kept and MOVED TO THE
		// REJECTION, which is the event an operator now needs: it says a bridge
		// presented a bare credential where an instance assertion is required.
		//
		// Logged here rather than in resolve_auth_any because only the transport
		// layer has method/path/request_id; Auth_Request does not carry them.
		//
		// The condition re-reads the header rather than keying off the error: the
		// rejection comes back as a generic domain error, and matching on its
		// message would break the moment that string is reworded.
		if bare_bridge_bearer_without_instance(auth, req) {
			auth_service.log_bridge_auth_denied("bare_token_shared_endpoint", req.method, req.path, "", "", "", req.request_id)
		}
		return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	}
	return ctx, true, Response{}
}

// bare_bridge_bearer_without_instance reports whether this request presented a
// bridge credential as a bare bearer token with NO instance assertion — the
// shape require_auth_any refuses on a shared endpoint.
//
// It deliberately does NOT verify the credential: the point is to audit the
// attempt, and a rejected request has no authenticated identity to log. That is
// also why the emitted line carries no bridge_id or user_id — claiming one from
// an unverified token would put attacker-controlled text in the audit log.
bare_bridge_bearer_without_instance :: proc(auth: ^auth_service.Auth_Service, req: Request) -> bool {
	token, token_ok := bearer_token(req)
	if !token_ok || !auth_service.is_bridge_bearer(token) do return false
	relay_token := header_value(req.headers, "X-Heimdall-Instance-Token")
	if strings.has_prefix(relay_token, "hit_") && len(relay_token) > len("hit_") do return false
	return auth_service.extract_body_instance_id(req.body) == ""
}

require_auth_or_bridge_token :: proc(auth: ^auth_service.Auth_Service, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, err := auth_service.resolve_auth_or_bridge_token(auth, auth_service.Auth_Request{
		remote_addr = req.remote_addr,
		query = req.query,
		body = req.body,
		headers = req.headers,
	})
	if !ok do return contracts.Auth_Context{}, false, respond_error(err, req.request_id)
	return ctx, true, Response{}
}
