// HTTP handlers for the passwordless vault device directory
// (docs/plans/passwordless-vault.md §2 P2). Cookie (trusted-proxy) or user-token auth;
// every mutation except register/genesis also needs the device request signature
// headers X-Heimdall-Device-{Id,Ts,Nonce,Sig}, verified by the service.
package http

import "core:encoding/json"
import "core:fmt"
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

VAULT_DEVICES_RESOURCE :: "vault_devices"

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

@(private = "file")
version_json :: proc(version: i64) -> string {
	return fmt.tprintf(`{"directory_version":%d}`, version)
}

@(private = "file")
publish :: proc(h: ^Vault_Directory_Handlers, user_id, device_id, change: string) {
	if h.event_bus == nil do return
	events.publish_resource_changed(h.event_bus, user_id, VAULT_DEVICES_RESOURCE, device_id, change, "{}")
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
	b := strings.builder_make(context.temp_allocator)
	d := view.directory
	strings.write_string(&b, fmt.tprintf(`{"configured":true,"version":%d,"current_epoch":%d`, d.version, d.current_epoch))
	w_str(&b, "root_device_id", d.root_device_id)
	w_str(&b, "root_sign_public_key", view.root_sign_public_key)
	w_str(&b, "root_sign_alg", view.root_sign_alg)
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
		strings.write_string(&b, fmt.tprintf(`{"epoch":%d`, e.epoch))
		w_str(&b, "statement", e.statement)
		w_raw(&b, "signature", e.signature)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// ── POST /api/v1/vault/directory/genesis ────────────────────────────────────
// {genesis_statement, signature, epoch_statement, epoch_signature, wrap}
vault_genesis_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
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
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"directory_version":1,"current_epoch":1,"device":`)
	write_vault_device_json(&b, dev)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// ── POST /api/v1/vault/devices/register ─────────────────────────────────────
// {statement, proof_signature}: a self-signed `register` statement. Idempotent per
// key. Rate-limited per IP. The push notification never carries the code.
vault_register_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
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
	if dev.status == .Pending {
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
	strings.write_string(&b, fmt.tprintf(`,"directory_version":%d`, view.directory_version))
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
	res, err := vd.revoke(h.vault, vd.Revoke_Input{
		user_id = auth.user_id, device_id = device_id_from_path(req), expected_version = version,
		revoke_statement = obj_str(o, "revoke_statement"), signature = obj_sig(o, "signature"),
		epoch_statement = obj_str(o, "epoch_statement"), epoch_signature = obj_sig(o, "epoch_signature"),
		wraps = wraps, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	// A revoked bridge loses its credentials too (existing bridge revoke: tokens + live socket).
	// The directory change is already committed; a failure here is reported, not hidden.
	bridge_revoked := true
	if res.target.kind == "bridge" && res.target.bridge_id != "" && h.bridges != nil {
		_, bridge_revoked, _ = bridge_service.revoke_bridge(h.bridges, auth, res.target.bridge_id)
	}
	publish(h, auth.user_id, res.target.device_id, "revoked")
	return respond_success(fmt.tprintf(`{"directory_version":%d,"bridge_credentials_revoked":%s}`, res.version, "true" if bridge_revoked else "false"), req.request_id, auth_ctx_server_time(req))
}

// ── PATCH /api/v1/vault/devices/{id} ────────────────────────────────────────
// {expected_version, label}; device-signed.
vault_patch_device_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	_, serr := vd.verify_request(h.vault, auth.user_id, signed_request(req), .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	o, parsed := body_object(req)
	if !parsed do return bad_request(req, "body must be a JSON object")
	version, v_ok := obj_i64(o, "expected_version")
	if !v_ok do return bad_request(req, "expected_version is required")
	device_id := device_id_from_path(req)
	new_version, err := vd.relabel(h.vault, auth.user_id, device_id, version, obj_str(o, "label"))
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, device_id, "updated")
	return respond_success(version_json(new_version), req.request_id, auth_ctx_server_time(req))
}
