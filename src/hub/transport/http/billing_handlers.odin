package http

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import billing "odin_test:hub/service/billing"

Billing_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	billing: ^billing.Service,
	ui_origin: string,
}

billing_require_user :: proc(handlers: ^Billing_Handlers, req: Request, mutation: bool) -> (contracts.Auth_Context, bool, Response) {
	auth, ok, resp := require_auth(handlers.auth, req)
	if !ok do return {}, false, resp
	if !contracts.is_user_auth(auth) do return {}, false, respond_error(domain.domain_error(.Forbidden, "account billing requires user authentication"), req.request_id)
	if mutation {
		// JSON-only mutations cannot be submitted by cross-site HTML forms.
		content_type := strings.trim_space(strings.split(header_value(req.headers, "Content-Type"), ";")[0])
		if content_type != "application/json" do return {}, false, respond_error(domain.domain_error(.Validation_Failed, "billing requests require application/json"), req.request_id)
		origin := header_value(req.headers, "Origin")
		if contracts.is_interactive_browser_auth(auth) && (header_value(req.headers, "Sec-Fetch-Site") == "cross-site" || (origin != "" && origin != handlers.ui_origin)) do return {}, false, respond_error(domain.domain_error(.Forbidden, "billing request origin is not allowed"), req.request_id)
	}
	return auth, true, {}
}

billing_respond :: proc(value: any, req: Request) -> Response {
	bytes, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil do return respond_error(domain.domain_error(.Internal_Error, "could not encode billing response"), req.request_id)
	return respond_success(string(bytes), req.request_id, auth_ctx_server_time(req))
}

account_billing_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Billing_Handlers)(ctx)
	auth, ok, resp := billing_require_user(handlers, req, false)
	if !ok do return resp
	view, err := billing.account_view(handlers.billing, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	return billing_respond(view, req)
}

account_checkout_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Billing_Handlers)(ctx)
	auth, ok, resp := billing_require_user(handlers, req, true)
	if !ok do return resp
	input: struct {offer_id: string}
	if len(req.body) > 4096 || json.unmarshal_string(req.body, &input, .JSON, context.temp_allocator) != nil do return respond_error(domain.domain_error(.Validation_Failed, "invalid checkout request"), req.request_id)
	result, err := billing.start_checkout(handlers.billing, auth.user_id, input.offer_id)
	if err.code != .None do return respond_error(err, req.request_id)
	return billing_respond(result, req)
}

account_portal_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Billing_Handlers)(ctx)
	auth, ok, resp := billing_require_user(handlers, req, true)
	if !ok do return resp
	result, err := billing.create_portal(handlers.billing, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	return billing_respond(result, req)
}

paddle_webhook_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Billing_Handlers)(ctx)
	// No Authentik session: Paddle-Signature is the authentication for this route.
	err := billing.receive_webhook(handlers.billing, header_value(req.headers, "Paddle-Signature"), req.body)
	if err.code != .None do return respond_error(err, req.request_id)
	return respond_success("{\"received\":true}", req.request_id, auth_ctx_server_time(req))
}
