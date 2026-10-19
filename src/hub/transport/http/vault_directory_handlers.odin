// HTTP handlers for the passwordless vault device directory
// (docs/plans/passwordless-vault.md §2 P2). Cookie (trusted-proxy) or user-token auth;
// every mutation except register/genesis/reset also needs the device request
// signature headers X-Heimdall-Device-{Id,Ts,Nonce,Sig}, verified by the service.
// register, genesis and reset are the unsigned entry points, so they accept ONLY an
// interactive browser session (Trusted_Proxy) — never a user token, which a script or
// a stolen ham-ctl credential could hold.
package http

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import events "odin_test:hub/service/events"
import push_service "odin_test:hub/service/push"
import vd "odin_test:hub/service/vault_directory"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

Vault_Directory_Handlers :: struct {
	auth:              ^auth_service.Auth_Service,
	vault:             ^vd.Service,
	device_auth:       ^device_auth.Device_Auth_Service, // rate limits + trusted-XFF resolution
	bridges:           ^bridge_service.Bridge_Service,   // bridge-token revocation on a bridge revoke
	event_bus:         ^events.User_Event_Bus,
	push:              ^push_service.Push_Service,
	public_app_origin: string,
}

VAULT_DEVICES_RESOURCE   :: "vault_devices"
VAULT_DIRECTORY_RESOURCE :: "vault_directory"

// ── Request plumbing ────────────────────────────────────────────────────────

@(private = "file")
require_vault_user :: proc(h: ^Vault_Directory_Handlers, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, resp := require_auth(h.auth, req)
	if !ok do return ctx, false, resp
	// A user principal only: never a bridge, enrollment or instance credential.
	if ctx.kind != .Trusted_Proxy && ctx.kind != .User_Token {
		return ctx, false, respond_error(domain.domain_error(.Forbidden, "vault directory requires a user session"), req.request_id)
	}
	return ctx, true, Response{}
}

// require_interactive_user admits only the interactive browser session (the
// authenticating proxy's cookie). Used by the unsigned entry points.
@(private = "file")
require_interactive_user :: proc(h: ^Vault_Directory_Handlers, req: Request) -> (contracts.Auth_Context, bool, Response) {
	ctx, ok, resp := require_auth(h.auth, req)
	if !ok do return ctx, false, resp
	if ctx.kind != .Trusted_Proxy {
		return ctx, false, respond_error(domain.domain_error(.Forbidden, "this vault action requires an interactive browser session"), req.request_id)
	}
	return ctx, true, Response{}
}

@(private = "file")
signed_request :: proc(req: Request) -> vd.Signed_Request {
	return vd.Signed_Request{
		method = req.method, path = req.path, body = req.body,
		device_id = header_value(req.headers, "X-Heimdall-Device-Id"),
		ts = header_value(req.headers, "X-Heimdall-Device-Ts"),
		nonce = header_value(req.headers, "X-Heimdall-Device-Nonce"),
		signature = header_value(req.headers, "X-Heimdall-Device-Sig"),
	}
}

@(private = "file")
client_ip :: proc(h: ^Vault_Directory_Handlers, req: Request) -> string {
	if h.device_auth == nil do return req.remote_addr
	return device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), h.device_auth.trusted_cidrs)
}

@(private = "file")
body_object :: proc(req: Request) -> (json.Object, bool) {
	v, ok := jsonx.parse_body(req.body, context.temp_allocator)
	if !ok do return nil, false
	o, is_obj := v.(json.Object)
	return o, is_obj
}

@(private = "file")
obj_str :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return string(s)
}

@(private = "file")
obj_i64 :: proc(o: json.Object, key: string) -> (i64, bool) {
	n, ok := o[key].(json.Integer)
	return i64(n), ok
}

@(private = "file")
obj_sig :: proc(o: json.Object, key: string) -> string {
	v, has := o[key]
	if !has do return ""
	s, _ := vault.signature_text_from_value(v, context.temp_allocator)
	return s
}

@(private = "file")
obj_wrap :: proc(o: json.Object, key: string) -> (vd.Wrap_Input, bool) {
	v, has := o[key]
	if !has do return {}, false
	w, sig, ok := vault.wrap_from_value(v, context.temp_allocator)
	return vd.Wrap_Input{wrap = w, signature = sig}, ok
}

@(private = "file")
bad_request :: proc(req: Request, msg: string) -> Response {
	return respond_error(domain.domain_error(.Validation_Failed, msg), req.request_id)
}

// ── JSON ────────────────────────────────────────────────────────────────────

@(private = "file")
w_str :: proc(b: ^strings.Builder, key, value: string, first := false) {
	if !first do strings.write_byte(b, ',')
	strings.write_byte(b, '"')
	strings.write_string(b, key)
	strings.write_string(b, `":"`)
	write_handler_json_string(b, value)
	strings.write_byte(b, '"')
}

@(private = "file")
w_raw :: proc(b: ^strings.Builder, key, raw: string) {
	strings.write_string(b, `,"`)
	strings.write_string(b, key)
	strings.write_string(b, `":`)
	strings.write_string(b, raw if raw != "" else "null")
}

write_vault_device_json :: proc(b: ^strings.Builder, d: domain.Vault_Device) {
	strings.write_byte(b, '{')
	w_str(b, "device_id", d.device_id, true)
	w_str(b, "kind", d.kind)
	w_str(b, "label", d.label)
	w_str(b, "fingerprint", d.fingerprint)
	w_str(b, "status", domain.vault_device_status_string(d.status))
	w_str(b, "sign_alg", d.sign_alg)
	w_str(b, "wrap_alg", d.wrap_alg)
	w_str(b, "sign_public_key", d.sign_public_key)
	w_str(b, "ecdh_public_key", d.ecdh_public_key)
	w_str(b, "bridge_id", d.bridge_id)
	w_str(b, "approved_by_device_id", d.approved_by_device_id)
	w_str(b, "approval_statement", d.approval_statement)
	w_raw(b, "approval_signature", d.approval_signature)
	w_str(b, "revoked_by_device_id", d.revoked_by_device_id)
	w_str(b, "revocation_statement", d.revocation_statement)
	w_raw(b, "revocation_signature", d.revocation_signature)
	w_str(b, "created_at", d.created_at)
	w_str(b, "approved_at", d.approved_at)
	w_str(b, "revoked_at", d.revoked_at)
	w_str(b, "last_seen_at", d.last_seen_at)
	strings.write_byte(b, '}')
}

// Odin's fmt treats '{' specially, so JSON is assembled by concatenation.
@(private = "file")
vd_itoa :: proc(v: i64) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], v, 10), context.temp_allocator)
}

@(private = "file")
version_json :: proc(version: i64) -> string {
	return strings.concatenate({`{"directory_version":`, vd_itoa(version), "}"}, context.temp_allocator)
}

@(private = "file")
publish :: proc(h: ^Vault_Directory_Handlers, user_id, device_id, change: string) {
	if h.event_bus == nil do return
	events.publish_resource_changed(h.event_bus, user_id, VAULT_DEVICES_RESOURCE, device_id, change, "{}")
}

// announce_directory tells every session (WS resource_changed on "vault_directory",
// resource id = the user id) and every push-subscribed device about a directory-level
// event: "genesis", "reset_scheduled", "reset_cancelled", "reset_executed".
vault_announce_directory :: proc(event_bus: ^events.User_Event_Bus, push: ^push_service.Push_Service, public_app_origin, user_id, change, due_at: string) {
	if event_bus != nil do events.publish_resource_changed(event_bus, user_id, VAULT_DIRECTORY_RESOURCE, user_id, change, "{}")
	if push == nil do return
	push_event := "created" if change == "genesis" else change
	content := push_service.build_vault_directory_notification(push_event, due_at)
	defer push_service.free_notification_content(content)
	payload := push_service.build_push_payload_json(content, public_app_origin)
	defer delete(payload)
	push_service.send_to_user_async(push, domain.User_ID(user_id), payload)
}

@(private = "file")
write_reset_json :: proc(b: ^strings.Builder, r: domain.Vault_Reset, has: bool) {
	if !has {
		strings.write_string(b, "null")
		return
	}
	strings.write_byte(b, '{')
	w_str(b, "requested_at", r.requested_at, true)
	w_str(b, "due_at", r.due_at)
	strings.write_byte(b, '}')
}

// ── GET /api/v1/vault/directory ─────────────────────────────────────────────
// Everything a client (and, relayed by its approver, a bridge) needs to verify the
// chain: the pinned root key, the self-signed genesis, every device with its
// approval/revocation statements, and every epoch statement. Updates last_seen_at
// when a (valid) device signature is attached; an invalid one is refused.
vault_directory_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	sreq := signed_request(req)
	if vd.has_signature_headers(sreq) {
		signer, err := vd.verify_request(h.vault, auth.user_id, sreq, .Self)
		if err.code != .None do return respond_error(err, req.request_id)
		vd.touch_last_seen(h.vault, auth.user_id, signer.device_id)
	}
	view, err := vd.get_directory(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	reset, has_reset, rerr := vd.get_reset(h.vault, auth.user_id)
	if rerr.code != .None do return respond_error(rerr, req.request_id)
	b := strings.builder_make(context.temp_allocator)
	d := view.directory
	strings.write_string(&b, `{"configured":true,"version":`)
	strings.write_string(&b, vd_itoa(d.version))
	strings.write_string(&b, `,"current_epoch":`)
	strings.write_string(&b, vd_itoa(d.current_epoch))
	w_str(&b, "root_device_id", d.root_device_id)
	w_str(&b, "root_sign_public_key", view.root_sign_public_key)
	w_str(&b, "root_sign_alg", view.root_sign_alg)
	// A scheduled owner reset ({requested_at, due_at}) or null.
	strings.write_string(&b, `,"reset":`)
	write_reset_json(&b, reset, has_reset)
	strings.write_string(&b, `,"genesis":{`)
	w_str(&b, "statement", d.genesis_statement, true)
	w_raw(&b, "signature", d.genesis_signature)
	strings.write_string(&b, `},"devices":[`)
	for dev, i in view.devices {
		if i > 0 do strings.write_byte(&b, ',')
		write_vault_device_json(&b, dev)
	}
	strings.write_string(&b, `],"epochs":[`)
	for e, i in view.epochs {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"epoch":`)
		strings.write_string(&b, vd_itoa(e.epoch))
		w_str(&b, "statement", e.statement)
		w_raw(&b, "signature", e.signature)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// ── POST /api/v1/vault/directory/genesis ────────────────────────────────────
// {genesis_statement, signature, epoch_statement, epoch_signature, wrap}. Interactive
// browser session only; announced to every session and device of the account.
vault_genesis_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	o, parsed := body_object(req)
	if !parsed do return bad_request(req, "body must be a JSON object")
	wrap, w_ok := obj_wrap(o, "wrap")
	if !w_ok do return bad_request(req, "wrap is missing or malformed")
	dev, err := vd.genesis(h.vault, vd.Genesis_Input{
		user_id = auth.user_id,
		genesis_statement = obj_str(o, "genesis_statement"), genesis_signature = obj_sig(o, "signature"),
		epoch_statement = obj_str(o, "epoch_statement"), epoch_signature = obj_sig(o, "epoch_signature"),
		wrap = wrap,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, dev.device_id, "approved")
	vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "genesis", "")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"directory_version":1,"current_epoch":1,"device":`)
	write_vault_device_json(&b, dev)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// ── POST /api/v1/vault/devices/register ─────────────────────────────────────
// {statement, proof_signature}: a self-signed `register` statement. Idempotent per
// key; user_code/code_expires_at only in the response that issued the code. Rate-limited per IP. The push notification never carries the code. Interactive
// browser session only.
vault_register_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	if h.device_auth != nil && !device_auth.rate_check(h.device_auth, "vault-register:", client_ip(h, req)) {
		return respond_error(domain.domain_error(.Rate_Limited, "too many device registrations from this IP"), req.request_id)
	}
	o, parsed := body_object(req)
	if !parsed do return bad_request(req, "body must be a JSON object")
	res, err := vd.register(h.vault, auth.user_id, obj_str(o, "statement"), obj_sig(o, "proof_signature"))
	if err.code != .None do return respond_error(err, req.request_id)
	dev := res.device
	if res.newly_pending {
		publish(h, auth.user_id, dev.device_id, "pending")
		if h.push != nil {
			content := push_service.build_vault_device_pending_notification(dev.fingerprint)
			defer push_service.free_notification_content(content)
			payload := push_service.build_push_payload_json(content, h.public_app_origin)
			defer delete(payload)
			push_service.send_to_user_async(h.push, domain.User_ID(auth.user_id), payload)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	w_str(&b, "device_id", dev.device_id, true)
	w_str(&b, "fingerprint", dev.fingerprint)
	w_str(&b, "status", domain.vault_device_status_string(dev.status))
	// The code is returned only by the call that issued it (insert or refresh of an
	// expired code). A repeat registration of the same key gets no code: whoever
	// holds a session cannot read back another tab's or device's pending code.
	if res.newly_pending {
		w_str(&b, "user_code", dev.user_code)
		w_str(&b, "code_expires_at", dev.code_expires_at)
	}
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201 if res.newly_pending else 200)
}

// ── GET /api/v1/vault/devices/self ──────────────────────────────────────────
// Signed by the device itself (pending, approved or revoked). {status,
// directory_version, wrap?}. The resource_changed "approved" event is the nudge.
vault_self_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, err := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Self)
	if err.code != .None do return respond_error(err, req.request_id)
	view, verr := vd.get_self(h.vault, auth.user_id, signer)
	if verr.code != .None do return respond_error(verr, req.request_id)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	w_str(&b, "device_id", signer.device_id, true)
	w_str(&b, "status", domain.vault_device_status_string(signer.status))
	strings.write_string(&b, `,"directory_version":`)
	strings.write_string(&b, vd_itoa(view.directory_version))
	if view.has_wrap {
		strings.write_string(&b, `,"wrap":`)
		strings.write_string(&b, view.wrap.wrap_json)
	}
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// device id is segment 5 of /api/v1/vault/devices/{id}[/action].
@(private = "file")
device_id_from_path :: proc(req: Request) -> string {
	return path_part(req.path, 5)
}

// ── POST /api/v1/vault/devices/{id}/approve ─────────────────────────────────
// {user_code, expected_version, statement, signature, wrap}
vault_approve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	o, parsed := body_object(req)
	if !parsed do return bad_request(req, "body must be a JSON object")
	version, v_ok := obj_i64(o, "expected_version")
	if !v_ok do return bad_request(req, "expected_version is required")
	wrap, _ := obj_wrap(o, "wrap") // required for wrap-receiving kinds; checked by the service
	device_id := device_id_from_path(req)
	new_version, err := vd.approve(h.vault, vd.Approve_Input{
		user_id = auth.user_id, device_id = device_id, user_code = obj_str(o, "user_code"),
		expected_version = version, statement = obj_str(o, "statement"), signature = obj_sig(o, "signature"),
		wrap = wrap, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, device_id, "approved")
	return respond_success(version_json(new_version), req.request_id, auth_ctx_server_time(req))
}

// ── POST /api/v1/vault/devices/{id}/deny ────────────────────────────────────
// Signed by an approved approver device; removes a pending device. Body ignored
// (but signed). {} on success; 404 when there is no such pending device.
vault_deny_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	_, serr := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	device_id := device_id_from_path(req)
	if err := vd.deny(h.vault, auth.user_id, device_id); err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, device_id, "denied")
	return respond_success(`{}`, req.request_id, auth_ctx_server_time(req))
}

// ── POST /api/v1/vault/devices/{id}/revoke ──────────────────────────────────
// {expected_version, revoke_statement, signature, epoch_statement, epoch_signature, wraps:[…]}
vault_revoke_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	o, parsed := body_object(req)
	if !parsed do return bad_request(req, "body must be a JSON object")
	version, v_ok := obj_i64(o, "expected_version")
	if !v_ok do return bad_request(req, "expected_version is required")
	arr, is_arr := o["wraps"].(json.Array)
	if !is_arr do return bad_request(req, "wraps must be an array")
	wraps := make([]vd.Wrap_Input, len(arr), context.temp_allocator)
	for v, i in arr {
		w, sig, w_ok := vault.wrap_from_value(v, context.temp_allocator)
		if !w_ok do return bad_request(req, "a wrap is malformed")
		wraps[i] = vd.Wrap_Input{wrap = w, signature = sig}
	}
	plan, err := vd.revoke_prepare(h.vault, vd.Revoke_Input{
		user_id = auth.user_id, device_id = device_id_from_path(req), expected_version = version,
		revoke_statement = obj_str(o, "revoke_statement"), signature = obj_sig(o, "signature"),
		epoch_statement = obj_str(o, "epoch_statement"), epoch_signature = obj_sig(o, "epoch_signature"),
		wraps = wraps, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	// A revoked bridge loses its credentials too, and FIRST: the tokens are revoked
	// (idempotent) before the directory revoke is committed, so any failure leaves the
	// safe state and fails the request. Skipped only when another approved identity
	// still maps to the same bridge (the hub never lets that happen; defense in depth).
	if target := plan.target; target.bridge_id != "" {
		other, oerr := vd.other_approved_for_bridge(h.vault, auth.user_id, target.bridge_id, target.device_id)
		if oerr.code != .None do return respond_error(oerr, req.request_id)
		if !other {
			if rerr := vault_revoke_bridge_credentials(h.bridges, auth, target.bridge_id); rerr.code != .None do return respond_error(rerr, req.request_id)
		}
	}
	res, cerr := vd.revoke_commit(h.vault, plan)
	if cerr.code != .None do return respond_error(cerr, req.request_id)
	publish(h, auth.user_id, res.target.device_id, "revoked")
	return respond_success(strings.concatenate({`{"directory_version":`, vd_itoa(res.version), `,"bridge_credentials_revoked":`, "true" if res.target.bridge_id != "" else "false", "}"}, context.temp_allocator), req.request_id, auth_ctx_server_time(req))
}

// vault_revoke_bridge_credentials kills every credential of bridge_id: an enrolled
// bridge is revoked (all token families, live socket closed), a still-pending
// enrollment is rolled back. A bridge row that no longer exists has nothing left to
// revoke. Any other failure is returned so the caller fails closed.
vault_revoke_bridge_credentials :: proc(bridges: ^bridge_service.Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> domain.Domain_Error {
	if bridges == nil do return domain.domain_error(.Internal_Error, "bridge service is not configured")
	b, found, err := bridge_service.get_bridge_for_enrollment(bridges, auth, bridge_id)
	if !found {
		if err.code == .Not_Found do return domain.Domain_Error{}
		return err
	}
	if domain.bridge_is_pending(b) {
		_, _, cerr := bridge_service.cancel_pending_enrollment(bridges, bridge_id)
		return cerr
	}
	if b.status == .Revoked do return domain.Domain_Error{}
	_, ok, rerr := bridge_service.revoke_bridge(bridges, auth, bridge_id)
	if !ok do return rerr if rerr.code != .None else domain.domain_error(.Internal_Error, "bridge credentials could not be revoked")
	return domain.Domain_Error{}
}

// ── POST /api/v1/vault/directory/reset ──────────────────────────────────────
// Schedules destruction of the whole directory RESET_DELAY_SECONDS (72 h) from now
// (see vd.schedule_reset). Interactive browser session only; body ignored. Returns
// {reset:{requested_at,due_at}} — 201 when this call scheduled it, 200 when one was
// already scheduled (the due time never moves). Announced (WS + push) on scheduling.
vault_reset_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	reset, newly, err := vd.schedule_reset(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if newly do vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "reset_scheduled", reset.due_at)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"reset":`)
	write_reset_json(&b, reset, true)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201 if newly else 200)
}

// ── POST /api/v1/vault/directory/reset/cancel ───────────────────────────────
// Signed by an approved approver device. {cancelled:bool}; idempotent.
vault_reset_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	_, serr := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	cancelled, err := vd.cancel_reset(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if cancelled do vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "reset_cancelled", "")
	return respond_success(`{"cancelled":true}` if cancelled else `{"cancelled":false}`, req.request_id, auth_ctx_server_time(req))
}
