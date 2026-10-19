// HTTP handlers for the device-authorization flow (ELDA-1 / ELDA-2).
//
// Public: POST /api/v1/device/authorize (no auth — the device is not yet
// authenticated).
//
// Public redirect: GET /api/v1/device/add — the path-form entry the bridge
// prints, folded into the UI hash route (see device_add_redirect_handler).
//
// Trusted-proxy-authenticated (ELDA-2/HBR-5): GET /api/v1/device (HTML page),
// POST /api/v1/device/verify, POST /api/v1/device/approve. These refuse with
// 401 when the request did not arrive through the trusted proxy.

package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import push_service "odin_test:hub/service/push"
import domain "odin_test:hub/domain"
import jsonx "odin_test:lib/jsonx"
import vd "odin_test:hub/service/vault_directory"
import "core:encoding/json"
import vault "odin_test:lib/vault"

Device_Auth_Handlers :: struct {
	service: ^device_auth.Device_Auth_Service,
	auth:    ^auth_service.Auth_Service,
	// REQ-IMPL-5 (Part A item 6): the post-approval notification. Optional —
	// nil, or a Push_Service with no VAPID keypair, simply means no push is
	// sent. It must never be able to fail the approval it is reporting, so
	// every use of it is guarded and non-blocking.
	push:              ^push_service.Push_Service,
	public_app_origin: string,
	// --ui-origin. Prefixes the /api/v1/device/add redirect target; empty means
	// a relative Location (UI served by the Hub itself).
	ui_origin:         string,
	// Passwordless vault: /device/verify also resolves a browser's 12-symbol
	// pending-device code against the session user's directory.
	vault:             ^vd.Service,
}

// device_authorize_handler is the public POST /api/v1/device/authorize endpoint.
device_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	input := device_auth.Authorize_Input{
		client = json_string(req.body, "client"),
		device_label = json_string(req.body, "device_label"),
		os = json_string(req.body, "os"),
		app_version = json_string(req.body, "app_version"),
		// REQ-IMPL-2 bridge-enrollment extensions. bridge_key_fingerprint is read
		// only so the service can CROSS-CHECK it against its own derivation and
		// surface a mismatch; the stored fingerprint is always the Hub's own
		// (device_auth/bridge_grant.odin).
		bridge_public_key = json_string(req.body, "bridge_public_key"),
		bridge_key_fingerprint = json_string(req.body, "bridge_key_fingerprint"),
		os_user = json_string(req.body, "os_user"),
		code_challenge = json_string(req.body, "code_challenge"),
		code_challenge_method = json_string(req.body, "code_challenge_method"),
	}
	xff := header_value(req.headers, "X-Forwarded-For")
	result, ok, err := device_auth.authorize(handlers.service, input, req.remote_addr, xff)
	device_auth_record("authorize", device_auth_error_result(err) if !ok else "ok")
	if !ok do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"device_code\":\"")
	write_handler_json_string(&data, result.device_code)
	strings.write_string(&data, "\",\"user_code\":\"")
	write_handler_json_string(&data, result.user_code)
	strings.write_string(&data, "\",\"verification_uri\":\"")
	write_handler_json_string(&data, result.verification_uri)
	strings.write_string(&data, fmt.tprintf("\",\"interval\":%d", result.interval))
	strings.write_string(&data, fmt.tprintf(",\"expires_in\":%d", result.expires_in))
	// Advisory echo of the Hub's fingerprint (design §2.2 step 5); omitted
	// entirely for a non-bridge grant so the ELDA response shape is unchanged.
	if result.bridge_key_fingerprint != "" {
		strings.write_string(&data, ",\"bridge_key_fingerprint\":\"")
		write_handler_json_string(&data, result.bridge_key_fingerprint)
		strings.write_string(&data, "\"")
	}
	strings.write_string(&data, "}")
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}

// device_page_handler serves the self-contained HTML confirm page (ELDA-2/AC1).
// Trusted-proxy-authenticated: the browser reaches it through the trusted proxy
// (outpost/dev-proxy), so the identity headers are present. 401 otherwise.
device_page_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	_, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	return Response{status = 200, content_type = "text/html; charset=utf-8", body = device_auth.DEVICE_PAGE_HTML}
}

// DEVICE_ADD_UI_ROUTE is the UI hash route of the bridge-enrollment approval page.
DEVICE_ADD_UI_ROUTE :: "/#/device/add"

// device_add_redirect_handler is GET /api/v1/device/add, the URL `ham-bridge
// enroll` prints and opens. It exists because the approval page lives behind a
// hash route: a forward-auth login round trip (`rd=<scheme://host/path?query>`)
// preserves path and query but the browser never sends the `#` fragment, so a
// `/#/device/add?code=…` link landed on Home after login. The path form
// survives the round trip and this 302 restores the hash route.
//
// No auth here: it only redirects, and the page it targets authenticates
// itself. The code is re-derived by normalize_user_code and only that canonical
// XXXX-XXXX form is written into Location — an absent or invalid code is
// dropped, never echoed, so the header cannot carry injected bytes.
device_add_redirect_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	headers := make([]contracts.HTTP_Header, 1)
	// query_value returns either a slice of the query or a fresh decode, so it
	// cannot be freed uniformly: keep it on the temp allocator.
	raw_code: string
	{
		context.allocator = context.temp_allocator
		raw_code = query_value(req.query, "code")
	}
	headers[0] = contracts.HTTP_Header{name = "Location", value = device_add_redirect_location(handlers.ui_origin, raw_code)}
	return Response{status = 302, content_type = "text/plain; charset=utf-8", body = "", headers = headers}
}

// device_add_redirect_location builds the 302 target for device_add_redirect_handler.
device_add_redirect_location :: proc(ui_origin, raw_code: string, allocator := context.temp_allocator) -> string {
	base := strings.trim_right(ui_origin, "/")
	code, ok := device_auth.normalize_user_code(raw_code, context.temp_allocator)
	if !ok {
		// A pending browser device's 12-symbol code (passwordless vault).
		code, ok = domain.normalize_vault_device_code(raw_code, context.temp_allocator)
	}
	if !ok do return strings.concatenate({base, DEVICE_ADD_UI_ROUTE}, allocator)
	return strings.concatenate({base, DEVICE_ADD_UI_ROUTE, "?code=", code}, allocator)
}

// device_verify_handler shows the requesting device's info for the given
// user_code (ELDA-2/AC3). Trusted-proxy-authenticated. Unknown/expired code ->
// generic 404 "invalid or expired code" (no enumeration); terminal -> 410.
device_verify_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	raw_code := json_string(req.body, "user_code")
	// The code's LENGTH routes it: 12 symbols is a pending browser device, 8 is a
	// bridge grant. A code is never tried against the other namespace, so a browser
	// code cannot resolve as a bridge grant or vice versa.
	if _, is_vault_code := domain.normalize_vault_device_code(raw_code, context.temp_allocator); is_vault_code {
		return vault_device_verify(handlers, req, auth_ctx, raw_code, request_ip)
	}
	info, vok, err := device_auth.verify_with_ip(handlers.service, raw_code, request_ip)
	device_auth_record("verify", device_auth_error_result(err) if !vok else "ok")
	if !vok do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"device_label\":\"")
	write_handler_json_string(&data, info.device_label)
	strings.write_string(&data, "\",\"os\":\"")
	write_handler_json_string(&data, info.os)
	strings.write_string(&data, "\",\"app_version\":\"")
	write_handler_json_string(&data, info.app_version)
	strings.write_string(&data, "\",\"client\":\"")
	write_handler_json_string(&data, info.client)
	strings.write_string(&data, "\",\"request_ip\":\"")
	write_handler_json_string(&data, info.request_ip)
	strings.write_string(&data, fmt.tprintf("\",\"requested_at\":%d", info.requested_at))
	// REQ-IMPL-2 / design §5.4.4: hand the browser the Hub's copy of the bridge
	// key and the hub-computed fingerprint so the approval page can compare them
	// against the key it read from the link fragment. Both are public values.
	//
	// PROVENANCE IS PART OF THE WIRE FORMAT, not a convention the UI has to look
	// up (REQ-ENROLL-14). Every field here is nested under either
	// `hub_observed` — derived by the Hub, safe to present as fact — or
	// `host_asserted` — supplied by the machine being enrolled, attacker-
	// controlled, and to be rendered as a claim. REQ-IMPL-5's approval screen
	// must visually separate the two, and it can only do that if the payload
	// does. `bridge_public_key` sits in BOTH, deliberately and under different
	// names: the machine asserted it, and the Hub now vouches for having stored
	// that exact value — which is what makes the fragment cross-check meaningful.
	strings.write_string(&data, ",\"kind\":\"bridge\"")
	// The persistent identity key the approver signs into the vault directory, and
	// its hub-computed fingerprint (compare it with the one `ham-bridge enroll` prints).
	strings.write_string(&data, ",\"bridge_identity_public_key\":\"")
	write_handler_json_string(&data, info.bridge_identity_public_key)
	strings.write_string(&data, "\",\"bridge_identity_fingerprint\":\"")
	write_handler_json_string(&data, info.bridge_identity_fingerprint)
	strings.write_string(&data, "\"")
	strings.write_string(&data, ",\"is_bridge_enrollment\":")
	strings.write_string(&data, "true" if info.is_bridge_enrollment else "false")
	strings.write_string(&data, ",\"hub_observed\":{\"bridge_key_fingerprint\":\"")
	write_handler_json_string(&data, info.bridge_key_fingerprint)
	strings.write_string(&data, "\",\"bridge_public_key_on_record\":\"")
	write_handler_json_string(&data, info.bridge_public_key)
	strings.write_string(&data, "\",\"fingerprint_algorithm\":\"sha256-64/hex-quads\",\"request_ip\":\"")
	write_handler_json_string(&data, info.request_ip)
	// server_time belongs in hub_observed because the Hub MEASURED it, with the
	// same clock reading that decided this grant had not expired. The approval
	// screen previously showed the browser's own `Date.now()` under the
	// "verified by Heimdall" heading, which made a false provenance claim and
	// left the request-staleness check dependent on operator clock skew. Same
	// units as requested_at, so the screen can subtract them.
	strings.write_string(&data, fmt.tprintf("\",\"server_time\":%d", info.server_time))
	strings.write_string(&data, "},\"host_asserted\":{\"bridge_public_key\":\"")
	write_handler_json_string(&data, info.bridge_public_key)
	strings.write_string(&data, "\",\"os_user\":\"")
	write_handler_json_string(&data, info.os_user)
	strings.write_string(&data, "\",\"device_label\":\"")
	write_handler_json_string(&data, info.device_label)
	strings.write_string(&data, "\",\"os\":\"")
	write_handler_json_string(&data, info.os)
	strings.write_string(&data, "\",\"app_version\":\"")
	write_handler_json_string(&data, info.app_version)
	strings.write_string(&data, "\"},\"bridge_public_key\":\"")
	write_handler_json_string(&data, info.bridge_public_key)
	strings.write_string(&data, "\",\"bridge_key_fingerprint\":\"")
	write_handler_json_string(&data, info.bridge_key_fingerprint)
	strings.write_string(&data, "\",\"os_user\":\"")
	write_handler_json_string(&data, info.os_user)
	strings.write_string(&data, "\"}")
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}

// device_approve_handler records the user's terminal decision (ELDA-2/AC4/AC5/
// AC6). Trusted-proxy-authenticated. owner_user_id is bound from Auth_Context
// ONLY — any client-supplied owner field in the body is ignored (ELDA-6).
device_approve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	input := device_auth.Approve_Input{
		user_code = json_string(req.body, "user_code"),
		// approve defaults to false; body must explicitly send true to approve.
		approve = json_bool(req.body, "approve"),
		// Optional "attach to an existing bridge" choice from the approval page.
		// Empty means mint a new bridge (unchanged default). Ownership of
		// target_bridge_id is re-checked downstream against the Auth_Context
		// owner, never trusted from this body alone.
		target_bridge_id = json_string(req.body, "target_bridge_id"),
		// Optional operator-chosen label for a newly minted bridge. It is ignored
		// nowhere: the service rejects combining it with target_bridge_id.
		new_bridge_label = json_string(req.body, "new_bridge_label"),
		vault_approval = parse_vault_approval(req.body),
	}
	// ELDA-6: owner comes from Auth_Context, NEVER from the body. We deliberately
	// do NOT read owner_user_id/user from req.body.
	approver_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	approver_ua := header_value(req.headers, "User-Agent")
	// REQ-IMPL-5 (Part A item 6): read the grant BEFORE deciding, because
	// approve() makes it terminal and the notification needs to know whether
	// this was a bridge enrollment and what fingerprint the Hub derived. This
	// is the Hub's own verify path, so it reveals nothing the approver cannot
	// already see, and a failure here must not block the decision.
	pre_info, pre_ok, _ := device_auth.verify(handlers.service, input.user_code)
	aok, err := device_auth.approve(
		handlers.service, input, auth_ctx.user_id, approver_ip, approver_ua, auth_ctx.name)
	// A recorded rejection is a successful call whose outcome is "denied".
	device_auth_record("approve", device_auth_error_result(err) if !aok else ("ok" if input.approve else "denied"))
	if !aok do return respond_error(err, req.request_id)
	// Enrolling a machine is the most consequential approval an owner can give,
	// and it happens in one tab that may then be closed. Tell their other
	// devices, so an approval obtained by phishing is discoverable rather than
	// silent. Approval only: a REJECTION leaves nothing to discover.
	//
	// The payload deliberately carries NO host-asserted text — see
	// build_enrollment_approval_notification for why a hostname must not reach
	// an OS-rendered notification.
	if input.approve && pre_ok && pre_info.is_bridge_enrollment && handlers.push != nil {
		content := push_service.build_enrollment_approval_notification(pre_info.bridge_key_fingerprint)
		defer push_service.free_notification_content(content)
		payload := push_service.build_push_payload_json(content, handlers.public_app_origin)
		defer delete(payload)
		push_service.send_to_user_async(handlers.push, domain.User_ID(auth_ctx.user_id), payload)
	}
	// REQ-IMPL-5: hand the approving browser the `brg_` this grant was minted
	// against, so it can deliver the vault key to that specific bridge over the
	// bridge_unseal relay. Until this moment there is no bridge to address — the
	// minter creates the id during approve(), and the poll path hands it to the
	// BRIDGE, not to the browser.
	//
	// It is nested under `hub_observed` because the Hub minted it and the machine
	// did not assert it (REQ-ENROLL-14's provenance split is part of the wire
	// format, not a UI convention). Absent for a non-bridge grant and for a
	// rejection, so the ELDA response shape is unchanged and `{}` still means
	// "decision recorded, nothing to address".
	if input.approve {
		if bridge_id, has_bridge := device_auth.approved_bridge_id(handlers.service, input.user_code); has_bridge {
			data := strings.builder_make()
			strings.write_string(&data, "{\"hub_observed\":{\"bridge_id\":\"")
			write_handler_json_string(&data, bridge_id)
			// REQ-EA-6: the bridge is not enrolled until its vault key is delivered.
			// Every bridge grant is minted pending (wiring.odin), so this is constant;
			// it is on the wire so the page need not infer it from the hub version.
			strings.write_string(&data, "\",\"enrollment_pending\":true}}")
			return respond_success(strings.to_string(data), req.request_id, "", 200)
		}
	}
	return respond_success("{}", req.request_id, "", 200)
}

// device_token_handler is the public POST /api/v1/device/token poll endpoint
// (ELDA-3). No auth. Returns the device-poll lifecycle: pending (incl. unknown
// device_code, anti-enumeration), approved (+access_token, single-use), denied,
// expired, or slow_down (429 + Retry-After). Per-IP rate-limited.
device_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	device_code := json_string(req.body, "device_code")
	// REQ-IMPL-2: the PKCE proof (RFC 7636 §4.5). Absent for the ELDA poll,
	// required for any grant that carries a challenge.
	code_verifier := json_string(req.body, "code_verifier")
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	result, err := device_auth.poll(handlers.service, device_code, request_ip, code_verifier)
	device_auth_record("poll", device_auth_poll_result(result.status, err))
	if err.code == .Rate_Limited {
		// slow_down: 429. The body carries status=slow_down so the device backs off.
		retry_after := handlers.service.store.config.interval
		if retry_after <= 0 do retry_after = 5
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "Retry-After", value = fmt.tprintf("%d", retry_after)}
		return Response{
			status = 429,
			content_type = "application/json",
			body = contracts.api_success_json(strings.concatenate({"{\"status\":\"slow_down\",\"interval\":", fmt.tprintf("%d", retry_after), "}"}), contracts.api_meta(req.request_id, "")),
			headers = headers,
		}
	}
	// A PKCE failure is an authentication failure, not a poll state: return the
	// domain error (401) rather than a 200 with a status field, so a bridge with
	// the wrong verifier cannot mistake it for "keep polling".
	if result.status == .Invalid_Grant do return respond_error(err, req.request_id)
	data := strings.builder_make()
	#partial switch result.status {
	case .Approved:
		strings.write_string(&data, "{\"status\":\"approved\",\"access_token\":\"")
		write_handler_json_string(&data, result.access_token)
		strings.write_string(&data, "\",\"token_id\":\"")
		write_handler_json_string(&data, result.token_id)
		// bridge_id is present only for a bridge grant; the ELDA response shape
		// is unchanged.
		if result.bridge_id != "" {
			strings.write_string(&data, "\",\"bridge_id\":\"")
			write_handler_json_string(&data, result.bridge_id)
			strings.write_string(&data, "\",\"approver_username\":\"")
			write_handler_json_string(&data, result.approver_username)
			strings.write_string(&data, "\",\"owner_user_id\":\"")
			write_handler_json_string(&data, result.owner_user_id)
		}
		// REQ-IMPL-3: the refresh half, present only for a bridge grant whose
		// credential expires. Omitted entirely otherwise, so the ELDA response
		// shape is unchanged and a client that sees no refresh_token knows not to
		// schedule a refresh rather than having to interpret an empty string.
		if result.refresh_token != "" {
			strings.write_string(&data, "\",\"refresh_token\":\"")
			write_handler_json_string(&data, result.refresh_token)
			strings.write_string(&data, fmt.tprintf("\",\"refresh_expires_in\":%d", result.refresh_expires_in))
			strings.write_string(&data, fmt.tprintf(",\"expires_in\":%d", result.expires_in))
		} else {
			strings.write_string(&data, fmt.tprintf("\",\"expires_in\":%d", result.expires_in))
		}
		if result.bridge_id != "" {
			strings.write_string(&data, ",\"vault_delivery_expected\":")
			strings.write_string(&data, "true" if result.vault_delivery_expected else "false")
			// REQ-EA: every vault-delivery grant is minted PENDING (wiring.odin's minter
			// refuses an owner without a vault), so the two flags coincide. A bridge that
			// sees this writes nothing until the key is delivered and the hub commits.
			strings.write_string(&data, ",\"enrollment_pending\":")
			strings.write_string(&data, "true" if result.vault_delivery_expected else "false")
		}
		strings.write_string(&data, "}")
	case .Denied:
		strings.write_string(&data, "{\"status\":\"denied\"}")
	case .Expired:
		strings.write_string(&data, "{\"status\":\"expired\"}")
	case .Slow_Down:
		strings.write_string(&data, "{\"status\":\"slow_down\"}")
	case: // .Pending (covers unknown device_code too — anti-enumeration)
		strings.write_string(&data, "{\"status\":\"pending\"}")
	}
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}
// json_bool extracts a boolean field from a JSON body (default false).
json_bool :: proc(body, key: string) -> bool {
	return jsonx.extract_bool(body, key, fallback = false)
}

// json_bool_literal requires the field to be present AND be a JSON boolean literal (true or false).
json_bool_literal :: proc(body, key: string) -> (value: bool, ok: bool) {
	return jsonx.extract_bool_literal(body, key)
}

// parse_vault_approval reads the optional `vault_approval:{expected_version,
// statement, signature}` of POST /device/approve. Required for a bridge grant (the
// minter refuses without it); ignored for a user-token grant.
parse_vault_approval :: proc(body: string) -> device_auth.Vault_Approval {
	v, ok := jsonx.parse_body(body, context.temp_allocator)
	if !ok do return {}
	root, is_obj := v.(json.Object)
	if !is_obj do return {}
	va, has := root["vault_approval"].(json.Object)
	if !has do return {}
	out := device_auth.Vault_Approval{present = true}
	if n, n_ok := va["expected_version"].(json.Integer); n_ok do out.expected_version = i64(n)
	if s, s_ok := va["statement"].(json.String); s_ok do out.statement = string(s)
	if sig_v, sig_has := va["signature"]; sig_has {
		out.signature, _ = vault.signature_text_from_value(sig_v, context.temp_allocator)
	}
	return out
}

// vault_device_verify answers /device/verify for a pending BROWSER device code.
// Rate-limited with the same per-IP verify budget as bridge codes, and scoped to
// the session user's own directory: another account's code is "invalid or expired".
vault_device_verify :: proc(handlers: ^Device_Auth_Handlers, req: Request, auth_ctx: contracts.Auth_Context, raw_code, request_ip: string) -> Response {
	if !device_auth.rate_check(handlers.service, "", request_ip) {
		device_auth_record("verify", "rate_limited")
		return respond_error(domain.domain_error(.Rate_Limited, "too many device verification attempts from this IP"), req.request_id)
	}
	if handlers.vault == nil do return respond_error(vd.GENERIC_CODE_ERROR(), req.request_id)
	dev, err := vd.resolve_pending_code(handlers.vault, auth_ctx.user_id, raw_code)
	device_auth_record("verify", device_auth_error_result(err) if err.code != .None else "ok")
	if err.code != .None do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"kind\":\"browser\",\"device_id\":\"")
	write_handler_json_string(&data, dev.device_id)
	strings.write_string(&data, "\",\"device_kind\":\"")
	write_handler_json_string(&data, dev.kind)
	strings.write_string(&data, "\",\"fingerprint\":\"")
	write_handler_json_string(&data, dev.fingerprint)
	strings.write_string(&data, "\",\"label\":\"")
	write_handler_json_string(&data, dev.label)
	strings.write_string(&data, "\",\"sign_public_key\":\"")
	write_handler_json_string(&data, dev.sign_public_key)
	strings.write_string(&data, "\",\"ecdh_public_key\":\"")
	write_handler_json_string(&data, dev.ecdh_public_key)
	strings.write_string(&data, "\",\"sign_alg\":\"")
	write_handler_json_string(&data, dev.sign_alg)
	strings.write_string(&data, "\",\"wrap_alg\":\"")
	write_handler_json_string(&data, dev.wrap_alg)
	strings.write_string(&data, "\",\"created_at\":\"")
	write_handler_json_string(&data, dev.created_at)
	strings.write_string(&data, "\",\"code_expires_at\":\"")
	write_handler_json_string(&data, dev.code_expires_at)
	strings.write_string(&data, "\"}")
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}
