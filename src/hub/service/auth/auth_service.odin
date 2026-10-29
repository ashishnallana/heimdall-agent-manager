package auth

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import vd "odin_test:hub/service/vault_directory"
import user_service "odin_test:hub/service/user"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"

// Users authenticate only through OIDC: a bearer access token (native apps, with
// the v2 device proof) or the Hub's own browser session cookie. Hub-issued user
// tokens and trusted-proxy identity headers no longer exist.
Auth_Config :: struct {
	// Create a Hub user for an unknown OIDC subject (see oidc_resolve_identity).
	auto_provision_users: bool,
}

Auth_Service :: struct {
	oidc: OIDC_Config,
	oidc_state: OIDC_State,
	// Browser login + server-side sessions (nil sessions: cookie auth disabled).
	web: Web_Login_Config,
	sessions: ^iface.Session_Repository,
	login_limiter: Login_Rate_Limiter,
	// Sealing key + consumed-state set for the stateless login cookie.
	login_seal: Login_Seal,
	// Preview-origin handoff tickets and preview sessions (process memory).
	preview: Preview_Auth_Store,
	vault: ^vd.Service,
	config: Auth_Config,
	users: ^user_service.User_Service,
	bridges: ^bridge_service.Bridge_Service,
	agents: ^agent_service.Agent_Service,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
}

// BRIDGE-TOKEN AUTHORIZATION IS ALWAYS ENFORCED (REQ-ENROLL-15).
//
// There used to be a bridge-auth-mode enum here whose permissive value — the ZERO
// VALUE, and the shipped config default — turned four separate authorization checks
// into log-only no-ops. REQ-IMPL-6 deleted the enum and every branch. There is no
// mode, no config key, no flag and no env var: a bridge-token decision that should
// deny, denies.
//
// The old identifier is deliberately not spelled out anywhere in `src/`, so that
// grepping for it returns nothing and cannot resurrect a stale mental model; the
// mechanism is described instead. Git history has the name.
//
// WHAT SURVIVED, AND WHY. The audit logging did. Observability never required
// fail-open: the log line and the rejection are independent, so every former
// monitor checkpoint now LOGS THE DENIAL AND THEN DENIES. Deleting the log
// alongside the mode would have traded a security hole for a blind spot.
//
// The emitted event was renamed `bridge_auth_monitor` -> `bridge_auth_denied`,
// because the old name claimed the opposite of what the line now means: it used
// to record "enforcement WOULD have denied this, and we allowed it anyway", and
// it now records an actual rejection. Nothing outside this package and its tests
// matched on the old string. Runbook greps live in `scripts/dev-stack-usage.md`.

// bridge_auth_denied_hook, when non-nil, receives each audit event instead of
// the default stdout logger. Tests set it to capture and assert the emitted fields.
bridge_auth_denied_hook: proc(point, method, path, bridge_id, user_id, target, request_id: string)

// log_bridge_auth_denied emits a single greppable audit line for a bridge-token
// authorization decision that was REJECTED. `grep bridge_auth_denied` over the hub
// log enumerates exactly which bridge operations are being refused, which is what
// an operator needs when a bridge misbehaves or a credential is being probed.
log_bridge_auth_denied :: proc(point, method, path, bridge_id, user_id, target, request_id: string) {
	if bridge_auth_denied_hook != nil {
		bridge_auth_denied_hook(point, method, path, bridge_id, user_id, target, request_id)
		return
	}
	fmt.printfln(
		"ham-hub bridge_auth_denied point=%s method=%s path=%s bridge_id=%s user_id=%s target=%s request_id=%s",
		point, method, path, bridge_id, user_id, target, request_id,
	)
}

Auth_Request :: struct {
	remote_addr: string,
	query: string,
	body: string,
	headers: []contracts.HTTP_Header,
}

new_auth_service :: proc(config: Auth_Config, users: ^user_service.User_Service, clock: ^platform.Clock = nil, ids: ^platform.ID_Generator = nil) -> Auth_Service {
	return Auth_Service{config = config, users = users, clock = clock, ids = ids}
}

// The credential shapes a BRIDGE may present as a bearer token. The distinction
// between them is a security decision, not a naming detail (REQ-IMPL-3).
//
//   "hba_"  the expiring access token from the browser-approval flow. The ONLY
//           shape that authenticates.
//   "hbr_"  LEGACY, non-expiring. No longer minted and no longer accepted
//           (REQ-ENROLL-9). It is still RECOGNISED as a bridge credential so a
//           bridge carrying a pre-device-flow token is told to re-enroll rather
//           than getting a generic rejection; verify_bridge_token owns that
//           message. Recognising is not accepting.
//
// `hbf_` is deliberately ABSENT. A refresh token is not a bearer credential for
// anything: it is accepted at the refresh endpoint alone, and if it ever resolved
// here the 1-hour bound on the access token would be decorative.
BRIDGE_ACCESS_BEARER_PREFIX :: "hba_"
BRIDGE_LEGACY_BEARER_PREFIX :: "hbr_"

// is_bridge_bearer reports whether a token is a bridge credential at all.
//
// `is_legacy_bridge_bearer` used to sit beside it, singling out the non-expiring
// shape because it was the only one the deleted permissive bridge-auth mode would
// accept bare on a shared endpoint. That allowance is gone and nothing else ever
// needed the distinction, so the proc went with it.
is_bridge_bearer :: proc(token: string) -> bool {
	return strings.has_prefix(token, BRIDGE_LEGACY_BEARER_PREFIX) || strings.has_prefix(token, BRIDGE_ACCESS_BEARER_PREFIX)
}

resolve_bridge_instance_auth :: proc(service: ^Auth_Service, req: Auth_Request) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if service == nil || service.bridges == nil || service.agents == nil {
		return contracts.Auth_Context{}, false, domain.domain_error(.Internal_Error, "bridge auth service is not configured")
	}
	if token_in_query_or_body(req.query, req.body) {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header")
	}
	authz := header_value(req.headers, "Authorization")
	if authz == "" || !strings.has_prefix(authz, "Bearer ") {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bridge bearer token is required")
	}
	bridge_token := strings.trim_space(authz[len("Bearer "):])
	bridge_auth, bridge_ok, bridge_err := bridge_service.verify_bridge_token(service.bridges, bridge_token)
	if !bridge_ok do return contracts.Auth_Context{}, false, bridge_err

	instance_id := ""
	relay_token := header_value(req.headers, "X-Heimdall-Instance-Token")
	if relay_token != "" && strings.has_prefix(relay_token, "hit_") {
		instance_id = agent_service.instance_id_from_assertion(relay_token)
	}
	if instance_id == "" {
		instance_id = extract_body_instance_id(req.body)
	}
	if instance_id == "" {
		return contracts.Auth_Context{}, false, domain.domain_error(.Validation_Failed, "agent_instance_id is required")
	}

	inst, inst_ok, inst_err := agent_service.get_instance(service.agents, bridge_auth, instance_id)
	if !inst_ok do return contracts.Auth_Context{}, false, inst_err
	if inst.bridge_id != bridge_auth.bridge_id {
		return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "bridge cannot act for an instance it does not own")
	}

	if inst.launch_epoch != "" && relay_token == "" do return {}, false, domain.domain_error(.Forbidden, "launch assertion is required for this instance")
	if relay_token != "" {
		expected_relay_token := agent_service.instance_assertion_token(inst)
		defer delete(expected_relay_token)
		if relay_token != expected_relay_token {
			return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "bridge instance assertion token is invalid")
		}
	}

	return contracts.Auth_Context{
		kind = .Instance_Token,
		user_id = string(inst.owner_user_id),
		agent_instance_id = inst.agent_instance_id,
		bridge_id = inst.bridge_id,
	}, true, domain.Domain_Error{}
}

resolve_auth_any :: proc(service: ^Auth_Service, req: Auth_Request) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	authz := header_value(req.headers, "Authorization")
	if authz != "" && strings.has_prefix(authz, "Bearer ") {
		token := strings.trim_space(authz[len("Bearer "):])
		if is_bridge_bearer(token) {
			// A bridge token that carries an instance assertion resolves via the
			// normal Instance_Token path. A BARE bridge token (no instance
			// assertion) on a shared endpoint is REJECTED, with no exception.
			//
			// REQ-IMPL-6 DELETED THE ONE EXCEPTION THERE USED TO BE. Under the old
			// permissive bridge-auth mode — which was the zero value AND the shipped
			// default — a bare LEGACY (`hbr_`) bridge token was accepted here as a
			// `Bridge_Token` on every `require_auth_any` endpoint, and merely logged.
			// It was scoped to `hbr_` because it existed to migrate that credential;
			// REQ-IMPL-3 pointedly refused to widen it to `hba_`, and REQ-IMPL-6
			// removes both the legacy credential and the allowance, so there is no
			// longer anything for it to migrate.
			//
			// The instance id is still derived HERE, even though
			// resolve_bridge_instance_auth re-derives it, and the reason is the
			// STATUS CODE rather than the decision.
			//
			// Both paths reject a bare bridge token; they disagree on why. Falling
			// through to resolve_bridge_instance_auth yields its "agent_instance_id
			// is required" — a Validation_Failed, so HTTP 400. But this is not a
			// malformed request, it is a credential being used somewhere it is not
			// allowed, which is 403. Simplifying this branch away silently turned
			// several existing 403 assertions into 400s; the distinction is load
			// bearing, so it is made explicitly.
			//
			// The denial is logged by require_auth_any (middleware.odin), which has
			// the method/path/request_id that Auth_Request does not carry.
			instance_id := ""
			relay_token := header_value(req.headers, "X-Heimdall-Instance-Token")
			if relay_token != "" && strings.has_prefix(relay_token, "hit_") {
				instance_id = agent_service.instance_id_from_assertion(relay_token)
			}
			if instance_id == "" {
				instance_id = extract_body_instance_id(req.body)
			}
			if instance_id == "" {
				// A LEGACY credential gets the re-enrollment instruction even here.
				//
				// Found by end-to-end testing, not by reading: an old bridge hitting a
				// SHARED endpoint was being told "a bare bridge token cannot call this
				// endpoint", because this branch short-circuits before
				// verify_bridge_token (which owns the re-enroll message) is ever
				// reached. Technically true and completely unhelpful — the operator's
				// actual problem is that the credential is dead, not that they chose
				// the wrong endpoint. REQ-ENROLL-9's requirement is that an old-style
				// credential names the fix, so it has to name it on every path an old
				// bridge can take, not only on the bridge endpoints.
				if strings.has_prefix(token, BRIDGE_LEGACY_BEARER_PREFIX) {
					return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, bridge_service.BRIDGE_LEGACY_CREDENTIAL_MESSAGE)
				}
				return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "a bare bridge token cannot call this endpoint; relay the call for one of your agent instances")
			}
			return resolve_bridge_instance_auth(service, req)
		}
	}
	return resolve_auth(service, req)
}

resolve_auth_or_bridge_token :: proc(service: ^Auth_Service, req: Auth_Request) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	authz := header_value(req.headers, "Authorization")
	if authz != "" && strings.has_prefix(authz, "Bearer ") {
		token := strings.trim_space(authz[len("Bearer "):])
		// Both bridge credential shapes, legacy and expiring: these endpoints are
		// bridge endpoints, so there is no transition-period question here — an
		// `hba_` must work exactly where an `hbr_` does.
		if is_bridge_bearer(token) {
			instance_id := ""
			relay_token := header_value(req.headers, "X-Heimdall-Instance-Token")
			if relay_token != "" && strings.has_prefix(relay_token, "hit_") {
				instance_id = agent_service.instance_id_from_assertion(relay_token)
			}
			if instance_id == "" {
				instance_id = extract_body_instance_id(req.body)
			}
			if instance_id != "" {
				return resolve_bridge_instance_auth(service, req)
			}
			if service == nil || service.bridges == nil {
				return contracts.Auth_Context{}, false, domain.domain_error(.Internal_Error, "bridge auth service is not configured")
			}
			if token_in_query_or_body(req.query, req.body) {
				return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header")
			}
			return bridge_service.verify_bridge_token(service.bridges, token)
		}
	}
	return resolve_auth(service, req)
}

Auth_Instance_Assertion_Body :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
}

extract_body_instance_id :: proc(body: string) -> string {
	if strings.trim_space(body) == "" do return ""
	payload: Auth_Instance_Assertion_Body
	err := json.unmarshal_string(body, &payload, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	if err != nil do return ""
	return payload.agent_instance_id
}

USER_TOKENS_REMOVED_MESSAGE :: "Ninjy user tokens are no longer supported; sign in with OIDC"

// resolve_auth authenticates a USER request: an OIDC bearer access token, else
// the Hub browser session cookie. Bridge and instance credentials are resolved
// by resolve_auth_any / resolve_auth_or_bridge_token before reaching here.
resolve_auth :: proc(service: ^Auth_Service, req: Auth_Request) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if service == nil || service.users == nil {
		return contracts.Auth_Context{}, false, domain.domain_error(.Internal_Error, "auth service is not configured")
	}
	if token_in_query_or_body(req.query, req.body) {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bearer tokens must use the Authorization header")
	}
	if header_present(req.headers, "Authorization") {
		authz := header_value(req.headers, "Authorization")
		if strings.has_prefix(authz, "Bearer ") {
			token := strings.trim_space(authz[len("Bearer "):])
			// Every bridge credential, INCLUDING the refresh token, is rejected on the
			// user-API path with the same error, so a bridge presenting the wrong half
			// of its pair learns which rule it broke.
			if is_bridge_bearer(token) || strings.has_prefix(token, "hbf_") do return contracts.Auth_Context{}, false, domain.domain_error(.Forbidden, "bridge token cannot call user APIs")
			if strings.has_prefix(token, "hut_") do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, USER_TOKENS_REMOVED_MESSAGE)
		}
		return resolve_oidc_auth(service, req)
	}
	if raw, present := cookie_value(req.headers, SESSION_COOKIE); present {
		return resolve_session_auth(service, raw)
	}
	return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "authentication required; sign in")
}

token_in_query_or_body :: proc(query, body: string) -> bool {
	if query_param_present(query, "token") || query_param_present(query, "access_token") || query_param_present(query, "agent_token") || query_param_present(query, "user_token") || query_param_present(query, "client_token") do return true
	if json_key_present(body, "token") || json_key_present(body, "access_token") || json_key_present(body, "agent_token") || json_key_present(body, "user_token") || json_key_present(body, "client_token") do return true
	return false
}

query_param_present :: proc(query, name: string) -> bool {
	if query == "" do return false
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		key := pair
		if eq >= 0 do key = pair[:eq]
		if key == name do return true
	}
	return false
}

json_key_present :: proc(body, key: string) -> bool {
	if body == "" do return false
	needle := strings.concatenate({"\"", key, "\""})
	defer delete(needle)
	return strings.contains(body, needle)
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

header_present :: proc(headers: []contracts.HTTP_Header, name: string) -> bool {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return true
	}
	return false
}

remote_addr_trusted :: proc(remote_addr: string, cidrs: []string) -> bool {
	ip := strip_port(remote_addr)
	if ip == "" do return false
	for cidr in cidrs {
		if cidr_matches(ip, strings.trim_space(cidr)) do return true
	}
	return false
}

strip_port :: proc(remote_addr: string) -> string {
	addr := strings.trim_space(remote_addr)
	if addr == "" do return ""
	colon := strings.last_index_byte(addr, ':')
	if colon > 0 && count_byte(addr, ':') == 1 {
		return addr[:colon]
	}
	return addr
}

count_byte :: proc(value: string, needle: byte) -> int {
	count := 0
	for ch in value {
		if ch == rune(needle) do count += 1
	}
	return count
}

cidr_matches :: proc(ip, cidr: string) -> bool {
	if cidr == "" do return false
	slash := strings.index_byte(cidr, '/')
	if slash < 0 do return ip == cidr
	base := cidr[:slash]
	prefix_len_i, ok := strconv.parse_int(cidr[slash + 1:])
	if !ok do return false
	prefix_len := int(prefix_len_i)
	ip_num, ip_ok := ipv4_to_u32(ip)
	base_num, base_ok := ipv4_to_u32(base)
	if !ip_ok || !base_ok || prefix_len < 0 || prefix_len > 32 do return false
	if prefix_len == 0 do return true
	mask := u32(0xffffffff) << u32(32 - prefix_len)
	return (ip_num & mask) == (base_num & mask)
}

ipv4_to_u32 :: proc(ip: string) -> (u32, bool) {
	parts := strings.split(ip, ".")
	defer delete(parts)
	if len(parts) != 4 do return 0, false
	result: u32 = 0
	for part in parts {
		value_i, ok := strconv.parse_int(part)
		if !ok || value_i < 0 || value_i > 255 do return 0, false
		result = (result << 8) | u32(value_i)
	}
	return result, true
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}

// live_user_authorized re-validates a long-lived stream's user principal: the
// user must still be active; a Session must still exist and be inside its
// absolute and idle expiry (logout deletes it); an OIDC bearer is bounded by the
// access token's expiry (plus leeway).
live_user_authorized :: proc(service: ^Auth_Service, auth: contracts.Auth_Context) -> bool {
	context.allocator = context.temp_allocator
	if service == nil || service.users == nil do return false
	user, found, err := user_service.get_user(service.users, domain.User_ID(auth.user_id))
	if !found || err.code != .None || user.status == .Disabled do return false
	now, now_ok := now_unix_ms(service)
	if !now_ok do return false
	#partial switch auth.kind {
	case .Session:
		_, live := session_lookup_live(service, auth.session_id, now)
		return live
	case .OIDC:
		return auth.expires_ms > 0 && now < auth.expires_ms
	}
	return false
}
