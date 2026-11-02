// HTTP handlers for the passwordless vault device directory
// (docs/plans/passwordless-vault.md §2 P2). Hub session or OIDC bearer auth;
// OIDC requests pass the central v2 gate before reaching these handlers, which
// reuse the verified signer without consuming the same nonce a second time.
// every mutation except register/genesis/reset also needs the device request
// signature headers X-Heimdall-Device-{Id,Ts,Nonce,Sig}, verified by the service.
// register, genesis and reset are the unsigned entry points, so they accept ONLY an
// interactive browser session (the Hub session cookie) or the native app's OIDC
// bearer with its verified v2 device proof.
//
// JSON: requests are decoded into typed structs (json.unmarshal) and responses are
// typed structs encoded with json.marshal. The signed/hashed canonical forms
// (statements, wrap canonical JSON, signature objects) are carried as values, never
// rebuilt here (lib/vault owns their encoders).
package http

import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import events "odin_test:hub/service/events"
import push_service "odin_test:hub/service/push"
import vd "odin_test:hub/service/vault_directory"
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
	if !contracts.is_user_auth(ctx) {
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
	// The native app (OIDC bearer + verified v2 device proof) keeps this path.
	if !contracts.is_interactive_browser_auth(ctx) && ctx.kind != .OIDC {
		return ctx, false, respond_error(domain.domain_error(.Forbidden, "this vault action requires an interactive browser session"), req.request_id)
	}
	return ctx, true, Response{}
}

signed_request :: proc(req: Request) -> vd.Signed_Request {
	version := header_value(req.headers, "X-Heimdall-Device-Sig-Version")
	target := req.path
	if version == "2" do target = request_signature_target(req)
	return vd.Signed_Request{
		method = req.method, path = target, body = req.body,
		version = version,
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

// vault_decode unmarshals the request body (strict JSON) into a typed request.
vault_decode :: proc(req: Request, out: ^$T) -> bool {
	return json.unmarshal_string(req.body, out, json.Specification.JSON, context.temp_allocator) == nil
}

// vault_respond marshals a typed response into the API success envelope.
vault_respond :: proc(value: any, req: Request, status := 200) -> Response {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil do return respond_error(domain.domain_error(.Internal_Error, "could not encode the response"), req.request_id)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req), status)
}

// sig_text turns a signature (object or its canonical text) into canonical text; ""
// when malformed (the service then rejects it).
vault_sig_text :: proc(v: json.Value) -> string {
	if v == nil do return ""
	s, _ := vault.signature_text_from_value(v, context.temp_allocator)
	return s
}

@(private = "file")
wrap_input :: proc(v: json.Value) -> (vd.Wrap_Input, bool) {
	if v == nil do return {}, false
	w, sig, ok := vault.wrap_from_value(v, context.temp_allocator)
	return vd.Wrap_Input{wrap = w, signature = sig}, ok
}

@(private = "file")
wrap_inputs :: proc(vs: []json.Value) -> ([]vd.Wrap_Input, bool) {
	out := make([]vd.Wrap_Input, len(vs), context.temp_allocator)
	for v, i in vs {
		w, ok := wrap_input(v)
		if !ok do return nil, false
		out[i] = w
	}
	return out, true
}

// version_of reads a JSON integer (expected_version must be one).
@(private = "file")
version_of :: proc(v: json.Value) -> (i64, bool) {
	n, ok := v.(json.Integer)
	return i64(n), ok
}

@(private = "file")
bad_request :: proc(req: Request, msg: string) -> Response {
	return respond_error(domain.domain_error(.Validation_Failed, msg), req.request_id)
}

// ── Wire types ──────────────────────────────────────────────────────────────

Vault_Device_Wire :: struct {
	device_id:             string,
	kind:                  string,
	label:                 string,
	fingerprint:           string,
	status:                string,
	sign_alg:              string,
	wrap_alg:              string,
	sign_public_key:       string,
	ecdh_public_key:       string,
	bridge_id:             string,
	approved_by_device_id: string,
	approval_statement:    string,
	approval_signature:    Maybe(vault.Signature_Wire),
	revoked_by_device_id:  string,
	revocation_statement:  string,
	revocation_signature:  Maybe(vault.Signature_Wire),
	created_at:            string,
	approved_at:           string,
	revoked_at:            string,
	last_seen_at:          string,
	retired_at:            string,
	// Recovery credentials only: the sealed recovery key blob (opaque to the hub; it
	// opens only with the 12 recovery words). Served to the session user so a new
	// browser can restore with the words.
	recovery_blob:         string,
}

@(private = "file")
sig_wire :: proc(text: string) -> Maybe(vault.Signature_Wire) {
	if text == "" do return nil
	w, ok := vault.signature_wire_from_text(text, context.temp_allocator)
	if !ok do return nil
	return w
}

vault_device_wire :: proc(d: domain.Vault_Device) -> Vault_Device_Wire {
	return Vault_Device_Wire{
		device_id = d.device_id, kind = d.kind, label = d.label, fingerprint = d.fingerprint,
		status = domain.vault_device_status_string(d.status),
		sign_alg = d.sign_alg, wrap_alg = d.wrap_alg,
		sign_public_key = d.sign_public_key, ecdh_public_key = d.ecdh_public_key,
		bridge_id = d.bridge_id, approved_by_device_id = d.approved_by_device_id,
		approval_statement = d.approval_statement, approval_signature = sig_wire(d.approval_signature),
		revoked_by_device_id = d.revoked_by_device_id, revocation_statement = d.revocation_statement,
		revocation_signature = sig_wire(d.revocation_signature),
		created_at = d.created_at, approved_at = d.approved_at, revoked_at = d.revoked_at,
		last_seen_at = d.last_seen_at, retired_at = d.retired_at,
		recovery_blob = d.recovery_blob if d.kind == "recovery" else "",
	}
}

Vault_Reset_Wire :: struct {
	requested_at: string,
	due_at:       string,
}

Vault_Log_Wire :: struct {
	seq:       i64,
	statement: string,
	signature: Maybe(vault.Signature_Wire),
}

Vault_Directory_Wire :: struct {
	configured:           bool,
	version:              i64,
	current_epoch:        i64,
	root_device_id:       string,
	root_sign_public_key: string,
	root_sign_alg:        string,
	head_hash:            string,
	// Hub retirement hints: clients verify and sign a real revoke (vd.Directory_View).
	retired_hints:        []string,
	// A scheduled owner reset or null.
	reset:                Maybe(Vault_Reset_Wire),
	// The signed directory log, seq 1..version: the only thing clients trust.
	log:                  []Vault_Log_Wire,
	// Device rows: display metadata (labels, bridge ids, last seen) and pending devices.
	devices:              []Vault_Device_Wire,
}

Vault_Version_Wire :: struct {
	directory_version: i64,
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

// ── GET /api/v1/vault/directory ─────────────────────────────────────────────
// Everything a client (and, relayed by its approver, a bridge) needs to verify the
// chain. A valid device signature refreshes approximate presence (coalesced by
// the repository within one hour); authorization never uses this timestamp.
vault_directory_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	sreq := signed_request(req)
	// The directory is readable by the session user alone; a device signature on
	// this read only refreshes that device's last_seen. A signer the hub does not
	// know (a browser whose directory was reset, or one that has not registered
	// yet) still gets the directory -- or the not-configured 404 -- so it can
	// recover, instead of a 403 that strands it.
	if auth.kind != .OIDC && vd.has_signature_headers(sreq) {
		signer, err := vd.verify_request(h.vault, auth.user_id, sreq, .Self)
		if err.code == .None do vd.touch_last_seen(h.vault, auth.user_id, signer.device_id)
	}
	view, err := vd.get_directory(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	reset, has_reset, rerr := vd.get_reset(h.vault, auth.user_id)
	if rerr.code != .None do return respond_error(rerr, req.request_id)
	d := view.directory
	out := Vault_Directory_Wire{
		configured = true, version = d.version, current_epoch = d.current_epoch,
		root_device_id = d.root_device_id, root_sign_public_key = view.root_sign_public_key,
		root_sign_alg = view.root_sign_alg, head_hash = d.head_hash,
		retired_hints = view.retired_hints if view.retired_hints != nil else []string{},
		log = make([]Vault_Log_Wire, len(view.log), context.temp_allocator),
		devices = make([]Vault_Device_Wire, len(view.devices), context.temp_allocator),
	}
	if has_reset do out.reset = Vault_Reset_Wire{requested_at = reset.requested_at, due_at = reset.due_at}
	for e, i in view.log do out.log[i] = Vault_Log_Wire{seq = e.seq, statement = e.statement, signature = sig_wire(e.signature)}
	for dev, i in view.devices do out.devices[i] = vault_device_wire(dev)
	return vault_respond(out, req)
}

// ── POST /api/v1/vault/directory/genesis ────────────────────────────────────
// {genesis_statement (log seq 1, introduces epoch 1), signature, wrap}. Interactive
// browser session only; announced to every session and device of the account.

@(private = "file")
Genesis_Request :: struct {
	genesis_statement: string,
	signature:         json.Value,
	wrap:              json.Value,
}

Vault_Genesis_Wire :: struct {
	directory_version: i64,
	current_epoch:     i64,
	device:            Vault_Device_Wire,
}

vault_genesis_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	body: Genesis_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	wrap, w_ok := wrap_input(body.wrap)
	if !w_ok do return bad_request(req, "wrap is missing or malformed")
	dev, err := vd.genesis(h.vault, vd.Genesis_Input{
		user_id = auth.user_id,
		genesis_statement = body.genesis_statement, genesis_signature = vault_sig_text(body.signature),
		wrap = wrap,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, dev.device_id, "approved")
	vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "genesis", "")
	return vault_respond(Vault_Genesis_Wire{directory_version = 1, current_epoch = 1, device = vault_device_wire(dev)}, req, 201)
}

// ── POST /api/v1/vault/devices/register ─────────────────────────────────────
// {statement, proof_signature, pair_lookup, pair_key_mac, pair_salt, pair_hub_origin}: a self-signed `register`
// statement plus the pairing values the device derived from its own code (plan §1
// "Pairing"; the code never reaches the hub). Idempotent per key; a live request is
// re-paired only by a newer register statement. Rate-limited per IP. Interactive
// browser session only.

@(private = "file")
Register_Request :: struct {
	statement:       string,
	proof_signature: json.Value,
	pair_lookup:     string,
	pair_key_mac:    string,
	pair_salt:       string,
	// The canonical hub origin the device bound into its pairing stretch (declared,
	// public; the approver derives with it).
	pair_hub_origin: string,
}

Vault_Register_Wire :: struct {
	device_id:       string,
	fingerprint:     string,
	status:          string,
	// How long the pending request lives (the hub never knows the code).
	code_expires_at: string `json:"code_expires_at,omitempty"`,
}

vault_register_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	if h.device_auth != nil && !device_auth.rate_check(h.device_auth, "vault-register:", client_ip(h, req)) {
		return respond_error(domain.domain_error(.Rate_Limited, "too many device registrations from this IP"), req.request_id)
	}
	body: Register_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	res, err := vd.register(h.vault, auth.user_id, body.statement, vault_sig_text(body.proof_signature), body.pair_lookup, body.pair_key_mac, body.pair_salt, body.pair_hub_origin)
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
	out := Vault_Register_Wire{device_id = dev.device_id, fingerprint = dev.fingerprint, status = domain.vault_device_status_string(dev.status)}
	if dev.status == .Pending do out.code_expires_at = dev.code_expires_at
	return vault_respond(out, req, 201 if res.newly_pending else 200)
}

// ── GET /api/v1/vault/devices/self ──────────────────────────────────────────
// Signed by the device itself (pending, approved or revoked). {status,
// directory_version, wrap?, pair_mac?}. The resource_changed "approved" event is the nudge.

Vault_Self_Wire :: struct {
	device_id:         string,
	status:            string,
	directory_version: i64,
	wrap:              Maybe(vault.Wrap_Wire) `json:"wrap,omitempty"`,
	// The approver's pair_mac over this device's approval (plan §1 "Pairing"): the
	// new device verifies it with its own code before pinning the account root.
	pair_mac:          string `json:"pair_mac,omitempty"`,
}

vault_self_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, err := vault_request_signer(h, auth, req, .Self)
	if err.code != .None do return respond_error(err, req.request_id)
	view, verr := vd.get_self(h.vault, auth.user_id, signer)
	if verr.code != .None do return respond_error(verr, req.request_id)
	out := Vault_Self_Wire{device_id = signer.device_id, status = domain.vault_device_status_string(signer.status), directory_version = view.directory_version}
	if view.has_wrap {
		w, w_ok := vault.wrap_wire_from_signed_json(view.wrap.wrap_json, context.temp_allocator)
		if !w_ok do return respond_error(domain.domain_error(.Internal_Error, "the stored wrap is malformed"), req.request_id)
		out.wrap = w
	}
	if signer.status == .Approved do out.pair_mac = signer.pair_mac
	return vault_respond(out, req)
}

// device id is segment 5 of /api/v1/vault/devices/{id}[/action].
@(private = "file")
device_id_from_path :: proc(req: Request) -> string {
	return path_part(req.path, 5)
}

// ── POST /api/v1/vault/devices/{id}/approve ─────────────────────────────────

@(private = "file")
Approve_Request :: struct {
	pair_lookup:      string,
	pair_mac:         string,
	expected_version: json.Value,
	statement:        string,
	signature:        json.Value,
	wrap:             json.Value,
}

vault_approve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	body: Approve_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	version, v_ok := version_of(body.expected_version)
	if !v_ok do return bad_request(req, "expected_version is required")
	wrap, _ := wrap_input(body.wrap) // required for wrap-receiving kinds; checked by the service
	device_id := device_id_from_path(req)
	new_version, err := vd.approve(h.vault, vd.Approve_Input{
		user_id = auth.user_id, device_id = device_id, pair_lookup = body.pair_lookup, pair_mac = body.pair_mac,
		expected_version = version, statement = body.statement, signature = vault_sig_text(body.signature),
		wrap = wrap, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, device_id, "approved")
	return vault_respond(Vault_Version_Wire{directory_version = new_version}, req)
}

// ── POST /api/v1/vault/devices/recovery ─────────────────────────────────────
// Signed by an approved approver: adds a recovery credential (signed approve op,
// its wrap, the sealed blob). Plan P4.

@(private = "file")
Recovery_Request :: struct {
	expected_version: json.Value,
	statement:        string,
	signature:        json.Value,
	wrap:             json.Value,
	recovery_blob:    string,
}

Vault_Recovery_Wire :: struct {
	directory_version: i64,
	device_id:         string,
}

vault_recovery_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	body: Recovery_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	version, v_ok := version_of(body.expected_version)
	if !v_ok do return bad_request(req, "expected_version is required")
	wrap, w_ok := wrap_input(body.wrap)
	if !w_ok do return bad_request(req, "wrap is required")
	new_version, dev, err := vd.add_recovery(h.vault, vd.Recovery_Input{
		user_id = auth.user_id, expected_version = version, statement = body.statement,
		signature = vault_sig_text(body.signature), wrap = wrap, recovery_blob = body.recovery_blob, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, dev.device_id, "approved")
	return vault_respond(Vault_Recovery_Wire{directory_version = new_version, device_id = dev.device_id}, req, 201)
}

// ── POST /api/v1/vault/devices/{id}/deny ────────────────────────────────────
// Signed by an approved approver device; removes a pending device. Body ignored
// (but signed). {} on success; 404 when there is no such pending device.

@(private = "file")
Empty_Wire :: struct {}

vault_deny_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	_, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	device_id := device_id_from_path(req)
	if err := vd.deny(h.vault, auth.user_id, device_id); err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, device_id, "denied")
	return vault_respond(Empty_Wire{}, req)
}

// ── POST /api/v1/vault/devices/{id}/revoke ──────────────────────────────────
// {expected_version, revoke_statement (one log op: revokes + introduces epoch current+1), signature, wraps:[…]}

@(private = "file")
Revoke_Request :: struct {
	expected_version: json.Value,
	revoke_statement: string,
	signature:        json.Value,
	wraps:            json.Value,
}

Vault_Revoke_Wire :: struct {
	directory_version:          i64,
	bridge_credentials_revoked: bool,
}

vault_revoke_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	body: Revoke_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	version, v_ok := version_of(body.expected_version)
	if !v_ok do return bad_request(req, "expected_version is required")
	arr, is_arr := body.wraps.(json.Array)
	if !is_arr do return bad_request(req, "wraps must be an array")
	wraps, w_ok := wrap_inputs(arr[:])
	if !w_ok do return bad_request(req, "a wrap is malformed")
	plan, err := vd.revoke_prepare(h.vault, vd.Revoke_Input{
		user_id = auth.user_id, device_id = device_id_from_path(req), expected_version = version,
		revoke_statement = body.revoke_statement, signature = vault_sig_text(body.signature),
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
	return vault_respond(Vault_Revoke_Wire{directory_version = res.version, bridge_credentials_revoked = res.target.bridge_id != ""}, req)
}

// ── POST /api/v1/vault/directory/rotate ──────────────────────────────────────
// {expected_version, statement (a `rotate` log op), signature, wraps:[…]}. Approver-signed.
// Advances to epoch current+1 without revoking anything (explicit user rotation).

@(private = "file")
Rotate_Request :: struct {
	expected_version: json.Value,
	statement:        string,
	signature:        json.Value,
	wraps:            json.Value,
}

vault_rotate_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	signer, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	body: Rotate_Request
	if !vault_decode(req, &body) do return bad_request(req, "body must be a JSON object")
	version, v_ok := version_of(body.expected_version)
	if !v_ok do return bad_request(req, "expected_version is required")
	arr, is_arr := body.wraps.(json.Array)
	if !is_arr do return bad_request(req, "wraps must be an array")
	wraps, w_ok := wrap_inputs(arr[:])
	if !w_ok do return bad_request(req, "a wrap is malformed")
	new_version, err := vd.rotate(h.vault, vd.Rotate_Input{
		user_id = auth.user_id, expected_version = version,
		statement = body.statement, signature = vault_sig_text(body.signature),
		wraps = wraps, signer = signer,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	publish(h, auth.user_id, signer.device_id, "rotated")
	return vault_respond(Vault_Version_Wire{directory_version = new_version}, req)
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
		// .Keep_Revoked: this is a credential kill, so a bridge the pending enrollment
		// sunset stays revoked rather than coming back to life.
		_, _, cerr := bridge_service.cancel_pending_enrollment(bridges, bridge_id, .Keep_Revoked)
		return cerr
	}
	// A sunset bridge is already Revoked but still has rollback authority.
	// Explicit vault revocation must invalidate that receipt even at the same clock tick.
	_, ok, rerr := bridge_service.revoke_bridge(bridges, auth, bridge_id)
	if !ok do return rerr if rerr.code != .None else domain.domain_error(.Internal_Error, "bridge credentials could not be revoked")
	return domain.Domain_Error{}
}

// ── POST /api/v1/vault/directory/reset ──────────────────────────────────────
// Schedules destruction of the whole directory RESET_DELAY_SECONDS (72 h) from now
// (see vd.schedule_reset). Interactive browser session only; body ignored. Returns
// {reset:{requested_at,due_at}} — 201 when this call scheduled it, 200 when one was
// already scheduled (the due time never moves). Announced (WS + push) on scheduling.

Vault_Reset_Response_Wire :: struct {
	reset: Vault_Reset_Wire,
}

vault_reset_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_interactive_user(h, req)
	if !ok do return resp
	reset, newly, err := vd.schedule_reset(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if newly do vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "reset_scheduled", reset.due_at)
	return vault_respond(Vault_Reset_Response_Wire{reset = {requested_at = reset.requested_at, due_at = reset.due_at}}, req, 201 if newly else 200)
}

// ── POST /api/v1/vault/directory/reset/cancel ───────────────────────────────
// Signed by an approved approver device. {cancelled:bool}; idempotent.

Vault_Reset_Cancel_Wire :: struct {
	cancelled: bool,
}

vault_reset_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Vault_Directory_Handlers)(ctx)
	auth, ok, resp := require_vault_user(h, req)
	if !ok do return resp
	_, serr := vault_request_signer(h, auth, req, .Approver)
	if serr.code != .None do return respond_error(serr, req.request_id)
	cancelled, err := vd.cancel_reset(h.vault, auth.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if cancelled do vault_announce_directory(h.event_bus, h.push, h.public_app_origin, auth.user_id, "reset_cancelled", "")
	return vault_respond(Vault_Reset_Cancel_Wire{cancelled = cancelled}, req)
}
