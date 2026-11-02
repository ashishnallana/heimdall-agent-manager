// HTTP handlers for the device-authorization flow (ELDA-1 / ELDA-2).
//
// Public: POST /api/v1/device/authorize (no auth — the device is not yet
// authenticated).
//
// Public redirect: GET /api/v1/device/add — the path-form entry the bridge
// prints, folded into the UI hash route (see device_add_redirect_handler).
//
// User-authenticated (Hub session cookie, or OIDC bearer for native clients):
// GET /api/v1/device (HTML page), POST /api/v1/device/verify, POST
// /api/v1/device/approve. Unauthenticated requests get 401 (the HTML page
// redirects a browser to the OIDC login instead).
//
// JSON: requests are decoded into typed structs and responses are typed structs
// encoded with json.marshal (vault_decode / vault_respond).

package http

import "core:encoding/json"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import device_auth "odin_test:hub/service/device_auth"
import push_service "odin_test:hub/service/push"
import domain "odin_test:hub/domain"
import jsonx "odin_test:lib/jsonx"
import vd "odin_test:hub/service/vault_directory"
import events "odin_test:hub/service/events"
import vault "odin_test:lib/vault"
import "core:fmt"
import "core:slice"
import "core:strings"

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
	// Passwordless vault: /device/verify also resolves a pending browser of the
	// session user by its pairing lookup.
	vault:             ^vd.Service,
	event_bus:         ^events.User_Event_Bus,
	// --pairing-hub-origins (canonical): other hub addresses this deployment answers
	// on. Served with the pair salts; the approver accepts a declared pairing origin
	// only if it is its own API origin or one of these.
	pairing_hub_origins: []string,
	// REQ-BE-2/3: the approver's bridges, for the "reuse an existing bridge" choice
	// on a bridge grant's verify (reusable_bridges + the checked previous_bridge_id
	// hint). Optional: nil serves an empty list and no hint, so approval always
	// registers a new bridge unless the client names a target itself.
	bridges:           ^bridge_service.Bridge_Service,
}

// ── POST /api/v1/device/authorize ───────────────────────────────────────────

@(private = "file")
Authorize_Request :: struct {
	client:                     string,
	device_label:               string,
	os:                         string,
	app_version:                string,
	// REQ-IMPL-2 bridge-enrollment extensions. bridge_key_fingerprint is read only so
	// the service can CROSS-CHECK it against its own derivation; the stored
	// fingerprint is always the Hub's own (device_auth/bridge_grant.odin).
	bridge_public_key:          string,
	bridge_key_fingerprint:     string,
	os_user:                    string,
	code_challenge:             string,
	code_challenge_method:      string,
	// Passwordless vault: the bridge's persistent identity key and its proof of
	// possession (signature object; see vault.bridge_enroll_proof_canonical).
	bridge_identity_public_key: string,
	bridge_identity_proof:      json.Value,
	// Hub-blind pairing (bridge grants): derived by the bridge from a code the hub never sees.
	pair_lookup:                string,
	pair_key_mac:               string,
	// The public, per-request salt of the pairing stretch (vault.Pair_Context), and
	// the canonical hub origin the bridge bound into it (declared; the approver derives with it).
	pair_salt:                  string,
	pair_hub_origin:            string,
	// REQ-BE-2: optional, untrusted hint naming the bridge this machine was before.
	previous_bridge_id:         string,
}

Device_Authorize_Wire :: struct {
	device_code:               string,
	// A bridge grant has no hub-known code (its operator types the bridge's own
	// secret pairing code): user_code is present only for a user-token grant.
	user_code:                 string `json:"user_code,omitempty"`,
	verification_uri:          string,
	// The UI's approval route. Links NEVER carry a code: whoever opens a link with
	// the pairing code would approve on the code's strength alone.
	verification_uri_complete: string `json:"verification_uri_complete,omitempty"`,
	interval:                  int,
	expires_in:                int,
	// Advisory echo of the Hub's fingerprint (design §2.2 step 5); omitted for a
	// non-bridge grant so the ELDA response shape is unchanged.
	bridge_key_fingerprint:    string `json:"bridge_key_fingerprint,omitempty"`,
	// The grant store's lifetime id, echoed on every poll: a different value there
	// means the hub restarted and this device_code is gone (REQ-ENR-12).
	grant_epoch:               string `json:"grant_epoch,omitempty"`,
}

// device_grant_epoch renders the grant store's epoch for the wire.
device_grant_epoch :: proc(handlers: ^Device_Auth_Handlers) -> string {
	return fmt.tprintf("%d", handlers.service.store.epoch)
}

device_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	body: Authorize_Request
	if !vault_decode(req, &body) do return respond_error(domain.domain_error(.Validation_Failed, "body must be a JSON object"), req.request_id)
	input := device_auth.Authorize_Input{
		client = body.client, device_label = body.device_label, os = body.os, app_version = body.app_version,
		bridge_public_key = body.bridge_public_key, bridge_key_fingerprint = body.bridge_key_fingerprint,
		os_user = body.os_user, code_challenge = body.code_challenge, code_challenge_method = body.code_challenge_method,
		bridge_identity_public_key = body.bridge_identity_public_key,
		bridge_identity_proof = vault_sig_text(body.bridge_identity_proof),
		pair_lookup = body.pair_lookup, pair_key_mac = body.pair_key_mac, pair_salt = body.pair_salt,
		pair_hub_origin = body.pair_hub_origin,
		previous_bridge_id = body.previous_bridge_id,
	}
	xff := header_value(req.headers, "X-Forwarded-For")
	result, ok, err := device_auth.authorize(handlers.service, input, req.remote_addr, xff)
	device_auth_record("authorize", device_auth_error_result(err) if !ok else "ok")
	if !ok do return respond_error(err, req.request_id)
	out := Device_Authorize_Wire{
		device_code = result.device_code, user_code = result.user_code,
		verification_uri = result.verification_uri,
		interval = result.interval, expires_in = result.expires_in,
		bridge_key_fingerprint = result.bridge_key_fingerprint,
		grant_epoch = device_grant_epoch(handlers),
	}
	if handlers.ui_origin != "" do out.verification_uri_complete = device_add_redirect_location(handlers.ui_origin)
	return vault_respond(out, req)
}

// device_page_handler serves the self-contained HTML confirm page (ELDA-2/AC1).
// It needs a signed-in user (the Hub session cookie); a browser without one is
// sent through the OIDC login and back.
device_page_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	_, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok {
		if strings.contains(header_value(req.headers, "Accept"), "text/html") do return redirect_response("/api/v1/auth/login?return_to=%2Fapi%2Fv1%2Fdevice")
		return auth_resp
	}
	return Response{status = 200, content_type = "text/html; charset=utf-8", body = device_auth.DEVICE_PAGE_HTML}
}

// DEVICE_ADD_UI_ROUTE is the UI hash route of the device approval page.
DEVICE_ADD_UI_ROUTE :: "/#/device/add"

// device_add_redirect_handler is GET /api/v1/device/add, the URL `ham-bridge
// enroll` prints and opens. It exists because the approval page lives behind a
// hash route: a forward-auth login round trip (`rd=<scheme://host/path?query>`)
// preserves path and query but the browser never sends the `#` fragment, so a
// `/#/device/add` link landed on Home after login. The path form survives the
// round trip and this 302 restores the hash route.
//
// No auth here: it only redirects, and the page it targets authenticates
// itself. The query is ignored entirely: an approval link never carries a code
// (hub-blind pairing, plan §1 "Pairing" — the operator types the code the new
// device shows), so nothing from the request reaches the Location header.
device_add_redirect_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	headers := make([]contracts.HTTP_Header, 1)
	headers[0] = contracts.HTTP_Header{name = "Location", value = device_add_redirect_location(handlers.ui_origin)}
	return Response{status = 302, content_type = "text/plain; charset=utf-8", body = "", headers = headers}
}

// device_add_redirect_location builds the 302 target for device_add_redirect_handler.
device_add_redirect_location :: proc(ui_origin: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({strings.trim_right(ui_origin, "/"), DEVICE_ADD_UI_ROUTE}, allocator)
}

// ── POST /api/v1/device/verify ──────────────────────────────────────────────
// Hub-blind pairing (plan §1 "Pairing"): browsers and bridges are resolved by the
// pair_lookup the APPROVER derived from the code it was given; the hub never sees
// the code. A pending browser of the session user is tried first, then a bridge
// grant. `user_code` is only the Electron (user-token grant) code. Unknown/expired
// -> generic 404 "invalid or expired code" (no enumeration); terminal -> 410.

@(private = "file")
Verify_Request :: struct {
	pair_lookup:  string,
	// Pairing stretch: the approver derives one lookup per candidate pair_salt
	// (/device/pair-salts) and may send them together (at most PAIR_CANDIDATES_MAX);
	// the first that resolves answers, and its pair_salt tells the approver which.
	pair_lookups: []string,
	user_code:    string,
}

Device_Verify_Hub_Observed :: struct {
	bridge_key_fingerprint:      string,
	bridge_public_key_on_record: string,
	fingerprint_algorithm:       string,
	request_ip:                  string,
	// The Hub MEASURED it, with the same clock reading that decided this grant had
	// not expired. Same units as requested_at.
	server_time:                 i64,
}

Device_Verify_Host_Asserted :: struct {
	bridge_public_key: string,
	os_user:           string,
	device_label:      string,
	os:                string,
	app_version:       string,
}

// Device_Verify_Grant_Wire: the requesting machine's info. PROVENANCE IS PART OF THE
// WIRE FORMAT (REQ-ENROLL-14): `hub_observed` is derived by the Hub, `host_asserted`
// is supplied by the machine being enrolled and must be rendered as a claim.
Device_Verify_Grant_Wire :: struct {
	device_label:                string,
	os:                          string,
	app_version:                 string,
	client:                      string,
	request_ip:                  string,
	requested_at:                i64,
	kind:                        string,
	// The persistent identity key the approver signs into the vault directory, and
	// its hub-computed fingerprint.
	bridge_identity_public_key:  string,
	bridge_identity_fingerprint: string,
	// Hub-blind pairing: the approver recomputes pair_key_mac over
	// identity|ecdh|challenge with the code the operator typed, proving the hub
	// served the bridge's real keys.
	pair_key_mac:                string,
	code_challenge:              string,
	// The pairing-stretch salt and declared hub origin the approver derived the lookup
	// with (it re-checks both).
	pair_salt:                   string,
	pair_hub_origin:             string,
	is_bridge_enrollment:        bool,
	hub_observed:                Device_Verify_Hub_Observed,
	host_asserted:               Device_Verify_Host_Asserted,
	bridge_public_key:           string,
	bridge_key_fingerprint:      string,
	os_user:                     string,
	// REQ-BE-2: the machine's previous_bridge_id hint, served ONLY when it names a
	// bridge in reusable_bridges (owned by the approving user, not revoked, not
	// pending); "" otherwise -- including when it names another user's bridge, which
	// must be indistinguishable from naming none. Checked, so the UI may preselect it,
	// but it is still a machine claim: the approver confirms the choice.
	previous_bridge_id:          string,
	// REQ-BE-3: the approver's bridges an approval may attach to (target_bridge_id),
	// most recently seen first. Always an array for a bridge grant ([] when none).
	reusable_bridges:            []Device_Reusable_Bridge_Wire,
}

// Device_Reusable_Bridge_Wire is one attach candidate. last_seen is RFC 3339.
Device_Reusable_Bridge_Wire :: struct {
	bridge_id:        string,
	label:            string,
	machine_hostname: string,
	status:           string, // "online" | "offline" (revoked bridges are never listed)
	last_seen:        string,
}

// device_reusable_bridges lists the approver's bridges an attach may target, and the
// hint if it names one of them. Same rules as rotate_bridge_for_device_grant's
// re-check (owned, not revoked, not pending), so the page never offers a target the
// approval would refuse. Any lookup failure degrades to "no reuse offered".
@(private = "file")
device_reusable_bridges :: proc(handlers: ^Device_Auth_Handlers, auth_ctx: contracts.Auth_Context, hint: string) -> (list: []Device_Reusable_Bridge_Wire, previous: string) {
	out := make([dynamic]Device_Reusable_Bridge_Wire, 0, 4, context.temp_allocator)
	if handlers.bridges == nil do return out[:], ""
	bridges, err := bridge_service.list_bridges(handlers.bridges, auth_ctx)
	if err.code != .None do return out[:], ""
	for b in bridges {
		if b.status == .Revoked || domain.bridge_is_pending(b) do continue
		if string(b.owner_user_id) != auth_ctx.user_id do continue // defense in depth; list_bridges is owner-scoped
		append(&out, Device_Reusable_Bridge_Wire{
			bridge_id = b.bridge_id, label = b.label, machine_hostname = b.machine_hostname,
			status = domain.bridge_status_string(b.status), last_seen = b.last_seen_at,
		})
		if hint != "" && b.bridge_id == hint do previous = b.bridge_id
	}
	slice.sort_by(out[:], proc(a, b: Device_Reusable_Bridge_Wire) -> bool { return a.last_seen > b.last_seen })
	return out[:], previous
}

// Device_Verify_Browser_Wire: a pending BROWSER of the session user. It carries the
// self-signed register statement and pair_key_mac: the approver verifies the MAC with
// the code it was given before trusting any key here.
Device_Verify_Browser_Wire :: struct {
	kind:               string,
	device_id:          string,
	device_kind:        string,
	fingerprint:        string,
	label:              string,
	sign_public_key:    string,
	ecdh_public_key:    string,
	sign_alg:           string,
	wrap_alg:           string,
	created_at:         string,
	code_expires_at:    string,
	register_statement: string,
	pair_key_mac:       string,
	pair_salt:          string,
	pair_hub_origin:    string,
}

device_verify_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	body: Verify_Request
	if !vault_decode(req, &body) do return respond_error(device_auth.GENERIC_UNKNOWN_CODE_ERROR(), req.request_id)
	info: device_auth.Device_Info
	lookups := body.pair_lookups
	if len(lookups) == 0 && body.pair_lookup != "" do lookups = []string{body.pair_lookup}
	if len(lookups) > 0 {
		// A user principal only: a bridge, enrollment or instance credential carries a
		// user id too, but must never resolve (and so learn the keys of) a pending device.
		if !contracts.is_user_auth(auth_ctx) {
			return respond_error(domain.domain_error(.Forbidden, "resolving a pairing code requires a user session"), req.request_id)
		}
		if !device_auth.rate_check(handlers.service, "", request_ip) {
			device_auth_record("verify", "rate_limited")
			return respond_error(domain.domain_error(.Rate_Limited, "too many device verification attempts from this IP"), req.request_id)
		}
		if len(lookups) > PAIR_CANDIDATES_MAX do return respond_error(device_auth.GENERIC_UNKNOWN_CODE_ERROR(), req.request_id)
		for lookup in lookups do if !vault.valid_pair_hex(lookup) do return respond_error(device_auth.GENERIC_UNKNOWN_CODE_ERROR(), req.request_id)
		err := device_auth.GENERIC_UNKNOWN_CODE_ERROR()
		found := false
		for lookup in lookups {
			if handlers.vault != nil {
				if dev, derr := vd.resolve_pending_lookup(handlers.vault, auth_ctx.user_id, lookup); derr.code == .None {
					device_auth_record("verify", "ok")
					return vault_respond(Device_Verify_Browser_Wire{
						kind = "browser", device_id = dev.device_id, device_kind = dev.kind,
						fingerprint = dev.fingerprint, label = dev.label,
						sign_public_key = dev.sign_public_key, ecdh_public_key = dev.ecdh_public_key,
						sign_alg = dev.sign_alg, wrap_alg = dev.wrap_alg,
						created_at = dev.created_at, code_expires_at = dev.code_expires_at,
						register_statement = dev.register_statement, pair_key_mac = dev.pair_key_mac, pair_salt = dev.pair_salt, pair_hub_origin = dev.pair_hub_origin,
					}, req)
				} else if derr.code != .Not_Found {
					return respond_error(derr, req.request_id)
				}
			}
			vinfo, vok, verr := device_auth.verify(handlers.service, lookup)
			if vok && !vinfo.is_bridge_enrollment do vok, verr = false, device_auth.GENERIC_UNKNOWN_CODE_ERROR()
			if vok {
				info, found = vinfo, true
				break
			}
			if verr.code != .Not_Found {
				err = verr
				break
			}
		}
		device_auth_record("verify", device_auth_error_result(err) if !found else "ok")
		if !found do return respond_error(err, req.request_id)
	} else {
		vinfo, vok, err := device_auth.verify_with_ip(handlers.service, body.user_code, request_ip)
		// A bridge grant resolves only by its pairing lookup, never as a user code.
		if vok && vinfo.is_bridge_enrollment do vok, err = false, device_auth.GENERIC_UNKNOWN_CODE_ERROR()
		device_auth_record("verify", device_auth_error_result(err) if !vok else "ok")
		if !vok do return respond_error(err, req.request_id)
		info = vinfo
	}
	reusable: []Device_Reusable_Bridge_Wire
	previous_bridge_id := ""
	if info.is_bridge_enrollment do reusable, previous_bridge_id = device_reusable_bridges(handlers, auth_ctx, info.previous_bridge_id)
	return vault_respond(Device_Verify_Grant_Wire{
		device_label = info.device_label, os = info.os, app_version = info.app_version,
		client = info.client, request_ip = info.request_ip, requested_at = info.requested_at,
		kind = "bridge",
		bridge_identity_public_key = info.bridge_identity_public_key,
		bridge_identity_fingerprint = info.bridge_identity_fingerprint,
		pair_key_mac = info.pair_key_mac, code_challenge = info.code_challenge, pair_salt = info.pair_salt,
		pair_hub_origin = info.pair_hub_origin,
		is_bridge_enrollment = info.is_bridge_enrollment,
		hub_observed = {
			bridge_key_fingerprint = info.bridge_key_fingerprint,
			bridge_public_key_on_record = info.bridge_public_key,
			fingerprint_algorithm = "sha256-64/hex-quads",
			request_ip = info.request_ip,
			server_time = info.server_time,
		},
		host_asserted = {
			bridge_public_key = info.bridge_public_key, os_user = info.os_user,
			device_label = info.device_label, os = info.os, app_version = info.app_version,
		},
		bridge_public_key = info.bridge_public_key,
		bridge_key_fingerprint = info.bridge_key_fingerprint,
		os_user = info.os_user,
		previous_bridge_id = previous_bridge_id,
		reusable_bridges = reusable,
	}, req)
}

// ── POST /api/v1/device/pair-salts ──────────────────────────────────────────
// Pairing stretch (plan §1 "Pairing"): the lookup is derived from the typed code AND
// the request's public pair_salt, so an approver first fetches the salts of the
// requests it could be approving: the session user's live pending browsers, then live
// pending bridge grants (no owner before approval), newest first, at most
// PAIR_CANDIDATES_MAX in all. It tries each with the code and resolves the matching
// one through /device/verify. User session only; rate-limited per IP.
//
// Each candidate carries pair_hub_origin: the canonical hub origin the NEW device
// declared it bound into its stretch (a bridge enrolled with `-Hub https://hub.x`
// while the approving UI calls its API on its own origin). The approver derives with
// the declared origin, never its page origin, and ACCEPTS it only if it is the
// approver's own API origin or one of `pairing_hub_origins` (this hub's configured
// aliases, served here). That keeps relay protection: a device tricked into
// enrolling against https://evil.example (a transparent relay to this hub) declares
// that origin and is refused, so the relay never sees an approved PKCE exchange.
// The alias list is honest-hub configuration; a hostile hub gains nothing from
// lying in it (it could mint bridge tokens itself), and altering a declared origin
// only makes the derived lookup / key_mac miss (refusal); the code is still required.

PAIR_CANDIDATES_MAX :: 8

Device_Pair_Candidate_Wire :: struct {
	kind:            string, // "browser" | "bridge"
	pair_salt:       string,
	pair_hub_origin: string,
}

Device_Pair_Salts_Wire :: struct {
	candidates:          []Device_Pair_Candidate_Wire,
	// Canonical hub origins (besides the approver's own API origin) a declared
	// pairing origin may name (--pairing-hub-origins).
	pairing_hub_origins: []string,
}

device_pair_salts_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	// Like a lookup: a bridge, enrollment or instance credential never lists pending requests.
	if !contracts.is_user_auth(auth_ctx) {
		return respond_error(domain.domain_error(.Forbidden, "listing pairing requests requires a user session"), req.request_id)
	}
	request_ip := device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), handlers.service.trusted_cidrs)
	if !device_auth.rate_check(handlers.service, "pair-salts:", request_ip) {
		return respond_error(domain.domain_error(.Rate_Limited, "too many pairing lookups from this IP"), req.request_id)
	}
	out := make([dynamic]Device_Pair_Candidate_Wire, 0, PAIR_CANDIDATES_MAX, context.temp_allocator)
	if handlers.vault != nil {
		pairs, err := vd.pending_pair_salts(handlers.vault, auth_ctx.user_id, PAIR_CANDIDATES_MAX)
		if err.code != .None do return respond_error(err, req.request_id)
		for p in pairs do append(&out, Device_Pair_Candidate_Wire{kind = "browser", pair_salt = p.pair_salt, pair_hub_origin = p.pair_hub_origin})
	}
	for p in device_auth.pending_bridge_pair_salts(handlers.service, PAIR_CANDIDATES_MAX - len(out)) {
		append(&out, Device_Pair_Candidate_Wire{kind = "bridge", pair_salt = p.pair_salt, pair_hub_origin = p.pair_hub_origin})
	}
	origins := handlers.pairing_hub_origins if handlers.pairing_hub_origins != nil else []string{}
	return vault_respond(Device_Pair_Salts_Wire{candidates = out[:], pairing_hub_origins = origins}, req)
}

// ── POST /api/v1/device/approve ─────────────────────────────────────────────
// Records the user's terminal decision (ELDA-2/AC4/AC5/AC6). Trusted-proxy-
// authenticated. owner_user_id is bound from Auth_Context ONLY — any client-supplied
// owner field in the body is ignored (ELDA-6).

@(private = "file")
Vault_Approval_Request :: struct {
	expected_version: json.Value,
	statement:        string,
	signature:        json.Value,
}

@(private = "file")
Approve_Grant_Request :: struct {
	// A bridge grant is addressed by its pairing lookup (plan §1 "Pairing"); only a
	// user-token grant still has a hub-issued user_code.
	pair_lookup:      string,
	user_code:        string,
	// Defaults to false; the body must explicitly send true to approve.
	approve:          bool,
	// Optional "attach to an existing bridge" choice; ownership is re-checked
	// downstream against the Auth_Context owner.
	target_bridge_id: string,
	new_bridge_label: string,
	// Optional "register new and sunset this bridge" choice; revoked atomically with
	// the new bridge's creation and re-checked downstream like target_bridge_id.
	sunset_bridge_id: string,
	// Required for a bridge grant (the minter refuses without it).
	vault_approval:   Maybe(Vault_Approval_Request),
}

Device_Approve_Hub_Observed :: struct {
	bridge_id:          string,
	// REQ-EA-6: the bridge is not enrolled until its vault key is delivered.
	enrollment_pending: bool,
}

Device_Approve_Wire :: struct {
	hub_observed: Maybe(Device_Approve_Hub_Observed) `json:"hub_observed,omitempty"`,
}

device_approve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(handlers.auth, req)
	if !ok do return auth_resp
	body: Approve_Grant_Request
	if !vault_decode(req, &body) do return respond_error(domain.domain_error(.Validation_Failed, "body must be a JSON object"), req.request_id)
	grant_key := body.pair_lookup if body.pair_lookup != "" else body.user_code
	input := device_auth.Approve_Input{
		user_code = grant_key, approve = body.approve,
		target_bridge_id = body.target_bridge_id, new_bridge_label = body.new_bridge_label,
		sunset_bridge_id = body.sunset_bridge_id,
	}
	if va, has := body.vault_approval.?; has {
		input.vault_approval = device_auth.Vault_Approval{present = true, statement = va.statement, signature = vault_sig_text(va.signature)}
		if n, n_ok := va.expected_version.(json.Integer); n_ok do input.vault_approval.expected_version = i64(n)
	}
	approver_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	approver_ua := header_value(req.headers, "User-Agent")
	// REQ-IMPL-5 (Part A item 6): read the grant BEFORE deciding, because approve()
	// makes it terminal and the notification needs to know whether this was a bridge
	// enrollment and what fingerprint the Hub derived.
	pre_info, pre_ok, _ := device_auth.verify(handlers.service, input.user_code)
	aok, err := device_auth.approve(
		handlers.service, input, auth_ctx.user_id, approver_ip, approver_ua, auth_ctx.name)
	// A recorded rejection is a successful call whose outcome is "denied".
	device_auth_record("approve", device_auth_error_result(err) if !aok else ("ok" if input.approve else "denied"))
	if !aok do return respond_error(err, req.request_id)
	// Enrolling a machine is the most consequential approval an owner can give: tell
	// their other devices, so an approval obtained by phishing is discoverable. The
	// payload carries NO host-asserted text.
	if input.approve && pre_ok && pre_info.is_bridge_enrollment && handlers.push != nil {
		content := push_service.build_enrollment_approval_notification(pre_info.bridge_key_fingerprint)
		defer push_service.free_notification_content(content)
		payload := push_service.build_push_payload_json(content, handlers.public_app_origin)
		defer delete(payload)
		push_service.send_to_user_async(handlers.push, domain.User_ID(auth_ctx.user_id), payload)
	}
	// REQ-IMPL-5: hand the approving browser the HUB-MINTED `brg_` this grant was
	// approved into, so it can deliver the vault key to that bridge. Absent for a
	// non-bridge grant and for a rejection (`{}`).
	out: Device_Approve_Wire
	if input.approve {
		if bridge_id, has_bridge := device_auth.approved_bridge_id(handlers.service, input.user_code); has_bridge {
			// The bridge's vault directory entry was committed with the approval; the
			// event names the directory DEVICE id, like every other vault_devices event.
			if handlers.event_bus != nil {
				if identity_key, has_key := device_auth.approved_bridge_identity_key(handlers.service, input.user_code); has_key {
					if device_id, id_ok := vault.device_id_from_sign_pub(identity_key, context.temp_allocator); id_ok {
						events.publish_resource_changed(handlers.event_bus, auth_ctx.user_id, VAULT_DEVICES_RESOURCE, device_id, "approved", "{}")
					}
				}
			}
			// Every bridge grant is minted pending (wiring.odin), so this is constant.
			out.hub_observed = Device_Approve_Hub_Observed{bridge_id = bridge_id, enrollment_pending = true}
		}
	}
	return vault_respond(out, req)
}

// ── POST /api/v1/device/token ───────────────────────────────────────────────
// The public poll endpoint (ELDA-3). No auth. Returns the device-poll lifecycle:
// pending (incl. unknown device_code, anti-enumeration), approved (+access_token,
// single-use), denied, expired, or slow_down (429 + Retry-After). Per-IP rate-limited.

@(private = "file")
Token_Request :: struct {
	device_code:   string,
	// REQ-IMPL-2: the PKCE proof (RFC 7636 §4.5). Absent for the ELDA poll,
	// required for any grant that carries a challenge.
	code_verifier: string,
}

Device_Token_Wire :: struct {
	status:                  string,
	interval:                Maybe(int) `json:"interval,omitempty"`,
	access_token:            string `json:"access_token,omitempty"`,
	token_id:                string `json:"token_id,omitempty"`,
	// Bridge grants only.
	bridge_id:               string `json:"bridge_id,omitempty"`,
	approver_username:       Maybe(string) `json:"approver_username,omitempty"`,
	owner_user_id:           Maybe(string) `json:"owner_user_id,omitempty"`,
	// REQ-IMPL-3: the refresh half, present only for an expiring credential.
	refresh_token:           string `json:"refresh_token,omitempty"`,
	refresh_expires_in:      Maybe(int) `json:"refresh_expires_in,omitempty"`,
	expires_in:              Maybe(int) `json:"expires_in,omitempty"`,
	vault_delivery_expected: Maybe(bool) `json:"vault_delivery_expected,omitempty"`,
	// REQ-EA: every vault-delivery grant is minted PENDING; a bridge that sees this
	// writes nothing until the key is delivered and the hub commits.
	enrollment_pending:      Maybe(bool) `json:"enrollment_pending,omitempty"`,
	// See Device_Authorize_Wire.grant_epoch.
	grant_epoch:             string `json:"grant_epoch,omitempty"`,
}

device_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	body: Token_Request
	_ = vault_decode(req, &body) // a malformed body polls as an unknown device_code (pending)
	request_ip := device_auth.resolve_client_ip(
		req.remote_addr, header_value(req.headers, "X-Forwarded-For"),
		handlers.service.trusted_cidrs)
	result, err := device_auth.poll(handlers.service, body.device_code, request_ip, body.code_verifier)
	device_auth_record("poll", device_auth_poll_result(result.status, err))
	if err.code == .Rate_Limited {
		// slow_down: 429. The body carries status=slow_down so the device backs off.
		retry_after := handlers.service.store.config.interval
		if retry_after <= 0 do retry_after = 5
		headers := make([]contracts.HTTP_Header, 1)
		headers[0] = contracts.HTTP_Header{name = "Retry-After", value = fmt.tprintf("%d", retry_after)}
		data, merr := json.marshal(Device_Token_Wire{status = "slow_down", interval = retry_after}, allocator = context.temp_allocator)
		if merr != nil do return respond_error(domain.domain_error(.Internal_Error, "could not encode the response"), req.request_id)
		return Response{
			status = 429,
			content_type = "application/json",
			body = contracts.api_success_json(string(data), contracts.api_meta(req.request_id, "")),
			headers = headers,
		}
	}
	// A PKCE failure is an authentication failure, not a poll state: return the
	// domain error (401) rather than a 200 with a status field, so a bridge with
	// the wrong verifier cannot mistake it for "keep polling".
	if result.status == .Invalid_Grant do return respond_error(err, req.request_id)
	out: Device_Token_Wire
	#partial switch result.status {
	case .Approved:
		out = Device_Token_Wire{status = "approved", access_token = result.access_token, token_id = result.token_id, expires_in = result.expires_in}
		if result.bridge_id != "" {
			out.bridge_id = result.bridge_id
			out.approver_username = result.approver_username
			out.owner_user_id = result.owner_user_id
			out.vault_delivery_expected = result.vault_delivery_expected
			out.enrollment_pending = result.vault_delivery_expected
		}
		if result.refresh_token != "" {
			out.refresh_token = result.refresh_token
			out.refresh_expires_in = result.refresh_expires_in
		}
	case .Denied:
		out.status = "denied"
	case .Expired:
		out.status = "expired"
	case .Slow_Down:
		out.status = "slow_down"
	case: // .Pending (covers unknown device_code too — anti-enumeration)
		out.status = "pending"
	}
	out.grant_epoch = device_grant_epoch(handlers)
	return vault_respond(out, req)
}

// json_bool extracts a boolean field from a JSON body (default false).
json_bool :: proc(body, key: string) -> bool {
	return jsonx.extract_bool(body, key, fallback = false)
}

// json_bool_literal requires the field to be present AND be a JSON boolean literal (true or false).
json_bool_literal :: proc(body, key: string) -> (value: bool, ok: bool) {
	return jsonx.extract_bool_literal(body, key)
}
