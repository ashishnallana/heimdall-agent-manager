#+private file
package http

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import users "odin_test:hub/service/user"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

OIDC_HTTP_Fixture :: struct {
	auth:        auth_service.Auth_Service,
	users:       users.User_Service,
	users_repo:  iface.User_Repository,
	vault:       vd.Service,
	vault_repo:  iface.Vault_Directory_Repository,
	clock:       platform.Clock,
	priv:        ecdsa.Private_Key,
	device:      domain.Vault_Device,
	token, jwks: string,
	next:        int,
}
oidc_http_clock :: proc(_: rawptr) -> string {return "2026-10-19T10:00:00Z"}
oidc_http_identity :: proc(
	_: rawptr,
	issuer, subject, username, display, email, now: string,
	provision: bool,
) -> (
	domain.User,
	bool,
	domain.Domain_Error,
) {
	if subject != "subject-1" do return {}, false, domain.domain_error(.Unauthenticated, "unknown subject")
	return domain.User{user_id = "alice", name = "alice", status = .Active}, true, {}
}
oidc_http_fetch :: proc(ctx: rawptr, url, token: string) -> (string, bool) {
	f := (^OIDC_HTTP_Fixture)(ctx)
	if strings.has_suffix(url, "/jwks/") do return f.jwks, token == ""
	return `{"sub":"subject-1","preferred_username":"alice"}`, token == f.token
}
oidc_http_devices :: proc(
	ctx: rawptr,
	user: string,
) -> (
	[]domain.Vault_Device,
	domain.Domain_Error,
) {
	f := (^OIDC_HTTP_Fixture)(ctx)
	if user != "alice" do return nil, {}
	out := make([]domain.Vault_Device, 1, context.temp_allocator)
	out[0] = f.device
	return out, {}
}
oidc_http_fixture :: proc(t: ^testing.T) -> ^OIDC_HTTP_Fixture {
	f := new(OIDC_HTTP_Fixture, context.temp_allocator)
	data: struct {
		jwks:   string,
		tokens: map[string]string,
	}
	testing.expect(
		t,
		json.unmarshal_string(
			#load("../../service/auth/testdata/oidc_rs256.json"),
			&data,
			.JSON,
			context.temp_allocator,
		) ==
		nil,
	)
	f.token, f.jwks = data.tokens["valid"], data.jwks
	f.clock = platform.Clock {
		now = oidc_http_clock,
	}
	f.users_repo = iface.User_Repository {
		resolve_external = oidc_http_identity,
	}
	f.users = users.new_user_service_basic(&f.users_repo, &f.clock, nil)
	f.vault_repo = iface.Vault_Directory_Repository {
		ctx          = f,
		list_devices = oidc_http_devices,
	}
	f.vault = vd.new_service(&f.vault_repo, &f.clock)
	f.auth = auth_service.Auth_Service {
		oidc_mode = true,
		users = &f.users,
		clock = &f.clock,
		vault = &f.vault,
		oidc = auth_service.OIDC_Config {
			issuer = "https://auth.mundus.in/application/o/heimdall-native/",
			audience = "heimdall-api",
			scope = "heimdall.api",
			userinfo_url = "https://auth.mundus.in/application/o/userinfo/",
			jwks_url = "https://auth.mundus.in/application/o/heimdall-native/jwks/",
			fetch = oidc_http_fetch,
			fetch_ctx = f,
		},
	}
	scalar: [32]byte
	scalar[31] = 1
	testing.expect(t, ecdsa.private_key_set_bytes(&f.priv, .SECP256R1, scalar[:]))
	pub: ecdsa.Public_Key
	defer ecdsa.public_key_clear(&pub)
	ecdsa.public_key_set_priv(&pub, &f.priv)
	raw: [65]byte
	ecdsa.public_key_bytes(&pub, raw[:])
	public_key := vault.hex_encode_lower(raw[:], context.temp_allocator)
	id, _ := vault.device_id_from_sign_pub(public_key, context.temp_allocator)
	f.device = domain.Vault_Device {
		device_id       = id,
		user_id         = "alice",
		kind            = "browser",
		status          = .Approved,
		sign_alg        = vault.SIGN_ALG_ECDSA_P256_SHA256,
		sign_public_key = public_key,
	}
	return f
}
oidc_http_close :: proc(f: ^OIDC_HTTP_Fixture) {
	auth_service.oidc_free(&f.auth)
	vd.service_free(&f.vault)
	ecdsa.private_key_clear(&f.priv)
}
oidc_http_request :: proc(f: ^OIDC_HTTP_Fixture, method, path: string) -> Request {
	headers := make([]contracts.HTTP_Header, 1, context.temp_allocator)
	headers[0] = contracts.HTTP_Header {
		"Authorization",
		strings.concatenate({"Bearer ", f.token}, context.temp_allocator),
	}
	return Request{method = method, path = path, request_id = "oidc-test", headers = headers}
}
oidc_http_sign :: proc(f: ^OIDC_HTTP_Fixture, request: Request) -> Request {
	req := request
	f.next += 1
	nonce := fmt.tprintf("00000000-0000-4000-8000-%012d", f.next)
	msg := vd.request_v2_canonical(
		req.method,
		request_signature_target(req),
		"alice",
		"1792404000000",
		nonce,
		req.body,
		context.temp_allocator,
	)
	sig, _ := vault.sign_p256(&f.priv, transmute([]byte)msg)
	text, _ := vault.signature_object(&sig, context.temp_allocator)
	headers := make([]contracts.HTTP_Header, 6, context.temp_allocator)
	headers[0] = req.headers[0]
	headers[1] = contracts.HTTP_Header{"X-Heimdall-Device-Sig-Version", "2"}
	headers[2] = contracts.HTTP_Header{"X-Heimdall-Device-Id", f.device.device_id}
	headers[3] = contracts.HTTP_Header{"X-Heimdall-Device-Ts", "1792404000000"}
	headers[4] = contracts.HTTP_Header{"X-Heimdall-Device-Nonce", nonce}
	headers[5] = contracts.HTTP_Header{"X-Heimdall-Device-Sig", text}
	req.headers = headers
	return req
}

@(test)
test_oidc_http_bootstrap_and_signed_me :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_http_fixture(t)
	defer oidc_http_close(f)
	handlers := User_Handlers {
		auth = &f.auth,
	}
	bearer := oidc_http_request(f, "GET", "/api/v1/me")
	testing.expect_value(t, me_handler(&handlers, bearer).status, 200)
	signed := oidc_http_sign(f, bearer)
	testing.expect_value(t, me_handler(&handlers, signed).status, 200)
	testing.expect_value(t, me_handler(&handlers, signed).status, 401) // read replay
	for path in ([]string {
			"/api/v1/agents",
			"/api/v1/me/",
			"/api/v1/me/tokens",
			"/api/v1/vault/devices/self",
			"/api/v1/vault/directory/genesis",
		}) {
		_, ok, _ := require_auth(&f.auth, oidc_http_request(f, "GET", path))
		testing.expect(t, !ok, path)
	}
	for path in ([]string{"/api/v1/vault/directory/genesis", "/api/v1/vault/devices/register"}) {
		_, ok, _ := require_auth(&f.auth, oidc_http_request(f, "POST", path))
		testing.expect(t, ok, path)
	}
	for _ in 0 ..< 3 {
		request := oidc_http_sign(f, oidc_http_request(f, "GET", "/api/v1/agents"))
		_, ok, _ := require_auth_any(&f.auth, request)
		testing.expect(t, ok)
	}
	_, unsigned_any, _ := require_auth_any(&f.auth, oidc_http_request(f, "GET", "/api/v1/agents"))
	_, unsigned_bridge_shared, _ := require_auth_or_bridge_token(
		&f.auth,
		oidc_http_request(f, "GET", "/api/v1/agents"),
	)
	_, unsigned_proxy, _ := require_trusted_proxy_auth(
		&f.auth,
		oidc_http_request(f, "GET", "/api/v1/agents"),
	)
	testing.expect(t, !unsigned_any && !unsigned_bridge_shared && !unsigned_proxy)
	ws := oidc_http_request(f, "GET", "/api/v1/user-ws")
	_, unsigned_ws, _ := user_ws_authenticate(&handlers, ws)
	testing.expect(t, !unsigned_ws)
	_, signed_ws, _ := user_ws_authenticate(&handlers, oidc_http_sign(f, ws))
	testing.expect(t, signed_ws)
	ws.query = "ticket=old-ticket"
	_, ticket_ws, _ := user_ws_authenticate(&handlers, ws)
	testing.expect(t, !ticket_ws)
	testing.expect_value(
		t,
		issue_user_ws_ticket_handler(
			&handlers,
			oidc_http_sign(f, oidc_http_request(f, "POST", "/api/v1/user-ws-ticket")),
		).status,
		403,
	)
}

@(test)
test_oidc_http_exact_target_and_pending_self :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_http_fixture(t)
	defer oidc_http_close(f)
	for status in ([]domain.Vault_Device_Status{.Pending, .Approved, .Revoked}) {
		f.device.status = status
		_, self_ok, _ := require_auth(
			&f.auth,
			oidc_http_sign(f, oidc_http_request(f, "GET", "/api/v1/vault/devices/self")),
		)
		testing.expect(t, self_ok)
		_, protected_ok, _ := require_auth(
			&f.auth,
			oidc_http_sign(f, oidc_http_request(f, "GET", "/api/v1/me")),
		)
		testing.expect(t, protected_ok == (status == .Approved))
	}
	f.device.status = .Approved
	request := oidc_http_request(f, "POST", "/api/v1/agents")
	request.query = "q=%2f&x=a%20b"
	request.body = `{"a":1}`
	signed := oidc_http_sign(f, request)
	signed.query = "x=a%20b&q=%2f"
	_, reordered, _ := require_auth(&f.auth, signed)
	testing.expect(t, !reordered)
	signed.query = request.query
	_, correct, _ := require_auth(&f.auth, signed)
	testing.expect(t, correct)
	request.raw_target = "/api/v1/agents?"
	signed = oidc_http_sign(f, request)
	signed.raw_target = "/api/v1/agents"
	_, empty_query_mutated, _ := require_auth(&f.auth, signed)
	testing.expect(t, !empty_query_mutated)
	signed.raw_target = request.raw_target
	_, empty_query_valid, _ := require_auth(&f.auth, signed)
	testing.expect(t, empty_query_valid)
}

@(test)
test_oidc_http_directory_known_proofs_and_vault_signer_reuse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_http_fixture(t)
	defer oidc_http_close(f)
	unsigned := oidc_http_request(f, "GET", "/api/v1/vault/directory")
	_, bootstrap, _ := require_auth(&f.auth, unsigned)
	testing.expect(t, bootstrap)
	request := oidc_http_sign(f, unsigned)
	request.headers[5].value = "bad-signature"
	_, invalid_known, _ := require_auth(&f.auth, request)
	testing.expect(t, !invalid_known)
	request.headers[2].value = strings.repeat("a", 64, context.temp_allocator)
	_, new_device, _ := require_auth(&f.auth, request)
	testing.expect(t, new_device)
	request = oidc_http_sign(f, oidc_http_request(f, "POST", "/api/v1/vault/devices/x/approve"))
	principal, valid, _ := require_auth(&f.auth, request)
	testing.expect(t, valid)
	handlers := Vault_Directory_Handlers {
		auth  = &f.auth,
		vault = &f.vault,
	}
	device, err := vault_request_signer(&handlers, principal, request, .Approver)
	testing.expect(t, err.code == .None && device.device_id == f.device.device_id)
	// A raw header alone cannot impersonate the middleware's verified principal.
	_, unsigned_err := vault_request_signer(
		&handlers,
		contracts.Auth_Context{kind = .OIDC, user_id = "alice"},
		request,
		.Approver,
	)
	testing.expect_value(t, unsigned_err.code, domain.Error_Code.Unauthenticated)
	duplicate := oidc_http_sign(f, oidc_http_request(f, "GET", "/api/v1/me"))
	headers := make([]contracts.HTTP_Header, 7, context.temp_allocator)
	copy(headers, duplicate.headers)
	headers[6] = duplicate.headers[2]
	duplicate.headers = headers
	_, dup_ok, _ := require_auth(&f.auth, duplicate)
	testing.expect(t, !dup_ok)
}

// The merged context carries two independent identities. Proof verification adds
// the device identity without dropping another transport's credential identity.
@(test)
test_oidc_proof_preserves_independent_token_identity :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    f := oidc_http_fixture(t)
    defer oidc_http_close(f)
    req := oidc_http_sign(f, oidc_http_request(f, "GET", "/api/v1/agents"))
    principal := contracts.Auth_Context{kind = .OIDC, user_id = "alice", user_token_id = "credential-sentinel"}
    verified, ok, _ := oidc_device_gate(&f.auth, principal, req)
    testing.expect(t, ok)
    testing.expect_value(t, verified.device_id, f.device.device_id)
    testing.expect_value(t, verified.user_token_id, principal.user_token_id)
    _, replay_ok, _ := oidc_device_gate(&f.auth, principal, req)
    testing.expect(t, !replay_ok, "retaining token identity must not bypass replay rejection")
    // Device headers alone never populate a verified identity on bearer auth.
    principal.kind = .User_Token
    bearer, bearer_ok, _ := oidc_device_gate(&f.auth, principal, req)
    testing.expect(t, bearer_ok)
    testing.expect_value(t, bearer.device_id, "")
    testing.expect_value(t, bearer.user_token_id, principal.user_token_id)
}
