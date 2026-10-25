#+private file
package auth

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import users "odin_test:hub/service/user"

OIDC_Test_Data :: struct {
	jwks:   string,
	tokens: map[string]string,
}
OIDC_Test_Fetch :: struct {
	data:                  OIDC_Test_Data,
	info:                  string,
	calls, userinfo_calls: int,
	fail:                  bool,
}
oidc_test_fetch :: proc(ctx: rawptr, url, token: string) -> (string, bool) {
	f := (^OIDC_Test_Fetch)(ctx)
	f.calls += 1
	if f.fail do return "", false
	if strings.has_suffix(url, "/jwks/") {
		if token != "" do return "", false // JWT bearer must never be sent to JWKS.
		return f.data.jwks, true
	}
	f.userinfo_calls += 1
	if token == "" do return "", false
	return f.info, true
}
oidc_test_config :: proc(t: ^testing.T, f: ^OIDC_Test_Fetch) -> OIDC_Config {
	testing.expect(
		t,
		json.unmarshal_string(
			#load("testdata/oidc_rs256.json"),
			&f.data,
			.JSON,
			context.temp_allocator,
		) ==
		nil,
	)
	f.info = `{"sub":"subject-1","preferred_username":"alice","name":"Alice","email":"shared@example.test"}`
	return OIDC_Config {
		issuer = "https://auth.mundus.in/application/o/heimdall-native/",
		audience = "heimdall-api",
		scope = "heimdall.api",
		userinfo_url = "https://auth.mundus.in/application/o/userinfo/",
		jwks_url = "https://auth.mundus.in/application/o/heimdall-native/jwks/",
		fetch = oidc_test_fetch,
		fetch_ctx = f,
	}
}

@(test)
test_oidc_rs256_claims_and_userinfo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: OIDC_Test_Fetch
	config := oidc_test_config(t, &f)
	for name, token in f.data.tokens {
		_, _, ok := oidc_validate_token(config, token, 1_792_404_000_000)
		expected := name == "valid" || name == "short" || name == "audience_string"
		testing.expect(t, ok == expected, name)
	}
	// Correct claims without the private key are insufficient.
	token := f.data.tokens["valid"]
	parts := strings.split(token, ".", context.temp_allocator)
	changed := "B" if parts[2][0] == 'A' else "A"
	bad := strings.concatenate(
		{parts[0], ".", parts[1], ".", changed, parts[2][1:]},
		context.temp_allocator,
	)
	_, _, forged := oidc_validate_token(config, bad, 1_792_404_000_000)
	testing.expect(t, !forged)
	f.info = `{"sub":"other-subject","preferred_username":"alice"}`
	_, _, mismatch := oidc_validate_token(config, token, 1_792_404_000_000)
	testing.expect(t, !mismatch)
	f.info = `{"preferred_username":"alice"}`
	_, _, missing := oidc_validate_token(config, token, 1_792_404_000_000)
	testing.expect(t, !missing)
	f.fail = true
	_, _, offline := oidc_validate_token(config, token, 1_792_404_000_000)
	testing.expect(t, !offline)
}

@(test)
test_oidc_rejects_ambiguous_jwks_and_base64 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: OIDC_Test_Fetch
	config := oidc_test_config(t, &f)
	data: OIDC_JWKS
	testing.expect(
		t,
		json.unmarshal_string(f.data.jwks, &data, .JSON, context.temp_allocator) == nil,
	)
	doubled := OIDC_JWKS {
		keys = make([]OIDC_JWK, 2, context.temp_allocator),
	}
	doubled.keys[0], doubled.keys[1] = data.keys[0], data.keys[0]
	raw, _ := json.marshal(doubled, allocator = context.temp_allocator)
	f.data.jwks = string(raw)
	_, _, duplicate := oidc_validate_token(config, f.data.tokens["valid"], 1_792_404_000_000)
	testing.expect(t, !duplicate)
	for value in ([]string{"A", "AB", "AA=", "++//", "AA\n"}) {
		_, ok := oidc_decode(value)
		testing.expect(t, !ok, value)
	}
}

OIDC_Test_Repo :: struct {
	conn:  sqlite.Conn,
	impl:  sqlite.User_Repo_SQLite,
	repo:  iface.User_Repository,
	now:   string,
	clock: platform.Clock,
	users: users.User_Service,
	auth:  Auth_Service,
	fetch: OIDC_Test_Fetch,
	trusted_cidrs: [1]string,
}
oidc_test_clock :: proc(ctx: rawptr) -> string {return (^string)(ctx)^}
oidc_test_repo :: proc(t: ^testing.T) -> ^OIDC_Test_Repo {
	f := new(OIDC_Test_Repo, context.temp_allocator)
	conn, ok, _ := sqlite.open(":memory:")
	testing.expect(t, ok)
	f.conn = conn
	migrated, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, migrated)
	f.repo = sqlite.new_user_repository(&f.impl, &f.conn)
	f.now = "2026-10-19T10:00:00Z"
	f.clock = platform.Clock {
		ctx = &f.now,
		now = oidc_test_clock,
	}
	f.users = users.new_user_service_basic(&f.repo, &f.clock, nil)
	f.trusted_cidrs[0] = "127.0.0.1/32"
	f.auth = new_auth_service_with_tokens(
		Trusted_Proxy_Config {
			username_header = "X-authentik-username",
			trusted_proxy_cidrs = f.trusted_cidrs[:],
			auto_provision_users = true,
		},
		&f.users,
		&f.repo,
		&f.clock,
		nil,
	)
	f.auth.oidc_mode = true
	f.auth.oidc = oidc_test_config(t, &f.fetch)
	return f
}
oidc_test_close :: proc(f: ^OIDC_Test_Repo) {
	oidc_free(&f.auth)
	sqlite.close(&f.conn)
}

@(test)
test_oidc_cache_is_bounded_and_does_not_extend_ttl :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	service: Auth_Service
	defer oidc_free(&service)
	state := &service.oidc_state
	identity := OIDC_Identity {
		sub                = "stable-subject",
		preferred_username = "alice",
	}
	oidc_cache_put(state, "first", OIDC_Cache_Entry{identity, 30000})
	oidc_cache_put(state, "first", OIDC_Cache_Entry{identity, 60000})
	for i in 0 ..< OIDC_CACHE_LIMIT do oidc_cache_put(state, fmt.tprintf("token-hash-%d", i), OIDC_Cache_Entry{identity, 30000})
	testing.expect_value(t, len(state.entries), OIDC_CACHE_LIMIT)
	entry, cached := oidc_cache_get(state, "first", 29999)
	testing.expect(t, cached)
	testing.expect_value(t, entry.until_ms, i64(30000))
	_, expired := oidc_cache_get(state, "first", 30000)
	testing.expect(t, !expired)
	testing.expect_value(t, len(state.entries), 0)
	testing.expect_value(t, entry.identity.sub, "stable-subject")
}
oidc_test_request :: proc(token: string) -> Auth_Request {
	headers := make([]contracts.HTTP_Header, 2, context.temp_allocator)
	headers[0] = contracts.HTTP_Header {
		"Authorization",
		strings.concatenate({"Bearer ", token}, context.temp_allocator),
	}
	headers[1] = contracts.HTTP_Header{"X-authentik-username", "mallory"}
	return Auth_Request{remote_addr = "127.0.0.1", headers = headers}
}

@(test)
test_oidc_cache_and_expiry_and_spoofing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_test_repo(t)
	defer oidc_test_close(f)
	req := oidc_test_request(f.fetch.data.tokens["valid"])
	for _ in 0 ..< 2 {
		principal, ok, _ := resolve_auth(&f.auth, req)
		testing.expect(t, ok)
		testing.expect_value(t, principal.user_id, "alice")
		testing.expect_value(t, principal.kind, contracts.Auth_Kind.OIDC)
	}
	testing.expect_value(t, f.fetch.userinfo_calls, 1)
	testing.expect_value(t, len(f.auth.oidc_state.entries), 1)
	// The cache contains token hashes only, never bearer material.
	for key in f.auth.oidc_state.entries do testing.expect_value(t, len(key), 64)
	f.now = "2026-10-19T10:00:29Z"
	f.fetch.fail = true
	_, cached, _ := resolve_auth(&f.auth, req)
	testing.expect(t, cached)
	f.now = "2026-10-19T10:00:30Z"
	_, stale, _ := resolve_auth(&f.auth, req)
	testing.expect(t, !stale)
	f.fetch.fail = false
	f.now = "2026-10-19T10:00:00Z"
	short_req := oidc_test_request(f.fetch.data.tokens["short"])
	_, short_ok, _ := resolve_auth(&f.auth, short_req)
	testing.expect(t, short_ok)
	f.now = "2026-10-19T10:00:10Z"
	_, expired, _ := resolve_auth(&f.auth, short_req)
	testing.expect(t, !expired)
	for token in ([]string{"hut_stolen", "", "garbage"}) {
		_, ok, _ := resolve_auth(&f.auth, oidc_test_request(token))
		testing.expect(t, !ok)
	}
	headers := []contracts.HTTP_Header{{"X-authentik-username", "alice"}}
	proxy_principal, proxy, _ := resolve_auth(
		&f.auth,
		Auth_Request{remote_addr = "127.0.0.1", headers = headers},
	)
	testing.expect(t, proxy)
	testing.expect_value(t, proxy_principal.kind, contracts.Auth_Kind.Trusted_Proxy)
	testing.expect_value(t, proxy_principal.user_id, "alice")
	_, untrusted_proxy, _ := resolve_auth(&f.auth, Auth_Request{remote_addr = "10.0.0.1", headers = headers})
	testing.expect(t, !untrusted_proxy)
	empty_auth_headers := []contracts.HTTP_Header {
		{"Authorization", ""},
		{"X-authentik-username", "alice"},
	}
	_, empty_auth_ok, _ := resolve_auth(
		&f.auth,
		Auth_Request{remote_addr = "127.0.0.1", headers = empty_auth_headers},
	)
	testing.expect(t, !empty_auth_ok)
	req.query = "access_token=stolen"
	_, query, _ := resolve_auth(&f.auth, req)
	testing.expect(t, !query)
	_, issued, _ := issue_user_api_token(
		&f.auth,
		Issue_User_API_Token_Input{owner_user_id = "alice"},
	)
	testing.expect(t, !issued)
	_, _, device_issued, _ := issue_device_authorization_token(&f.auth, "alice", "script")
	testing.expect(t, !device_issued)
	duplicate := oidc_test_request(f.fetch.data.tokens["valid"])
	repeated := make([]contracts.HTTP_Header, 3, context.temp_allocator)
	copy(repeated, duplicate.headers)
	repeated[2] = repeated[0]
	duplicate.headers = repeated
	_, dup_ok, _ := resolve_auth(&f.auth, duplicate)
	testing.expect(t, !dup_ok)
}

@(test)
test_oidc_persistent_identity_linking_and_collisions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_test_repo(t)
	defer oidc_test_close(f)
	_, saved, _ := iface.user_save(
		&f.repo,
		domain.User {
			user_id = "retained-id",
			name = "alice",
			status = .Active,
			email = "shared@example.test",
			created_at = f.now,
			updated_at = f.now,
		},
	)
	testing.expect(t, saved)
	issuer := f.auth.oidc.issuer
	user, linked, _ := f.repo.resolve_external(
		f.repo.ctx,
		issuer,
		"subject-1",
		"alice",
		"Alice",
		"shared@example.test",
		f.now,
		true,
	)
	testing.expect(t, linked)
	testing.expect_value(t, user.user_id, domain.User_ID("retained-id"))
	renamed, stable, _ := f.repo.resolve_external(
		f.repo.ctx,
		issuer,
		"subject-1",
		"renamed",
		"New Name",
		"new@example.test",
		f.now,
		true,
	)
	testing.expect(t, stable)
	testing.expect_value(t, renamed.user_id, user.user_id)
	_, collision, err := f.repo.resolve_external(
		f.repo.ctx,
		issuer,
		"subject-2",
		"alice",
		"",
		"",
		f.now,
		true,
	)
	testing.expect(t, !collision)
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	// Same email does not merge distinct identities.
	other, provisioned, _ := f.repo.resolve_external(
		f.repo.ctx,
		issuer,
		"subject-2",
		"bob",
		"Bob",
		"shared@example.test",
		f.now,
		true,
	)
	testing.expect(t, provisioned)
	testing.expect_value(t, other.user_id, domain.User_ID("bob"))
	_, disabled, _ := f.repo.resolve_external(
		f.repo.ctx,
		issuer,
		"subject-3",
		"carol",
		"",
		"",
		f.now,
		false,
	)
	testing.expect(t, !disabled)
	_, absent, _ := iface.user_get_by_id(&f.repo, "carol")
	testing.expect(t, !absent)
	_, issuer_collision, _ := f.repo.resolve_external(
		f.repo.ctx,
		"https://other-issuer/",
		"subject-1",
		"alice",
		"",
		"",
		f.now,
		true,
	)
	testing.expect(t, !issuer_collision)
	// A new repository instance reuses the durable link after a username change.
	impl: sqlite.User_Repo_SQLite
	repo := sqlite.new_user_repository(&impl, &f.conn)
	persisted, exists, _ := repo.resolve_external(
		repo.ctx,
		issuer,
		"subject-1",
		"",
		"",
		"",
		f.now,
		false,
	)
	testing.expect(t, exists)
	testing.expect_value(t, persisted.user_id, user.user_id)
}

// Bearer validation fails closed when the API audience or scope is unset: an
// empty required scope must never match an empty element of a token's scope.
@(test)
test_oidc_config_requires_audience_and_scope :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: OIDC_Test_Fetch
	config := oidc_test_config(t, &f)
	token := f.data.tokens["valid"]
	_, _, ok := oidc_validate_token(config, token, 1_792_404_000_000)
	testing.expect(t, ok, "configured scope and audience accept the fixture")
	no_scope := config
	no_scope.scope = ""
	_, _, stage, scope_ok := oidc_validate_token_with_stage(no_scope, token, 1_792_404_000_000)
	testing.expect(t, !scope_ok && stage == "config", "empty scope rejected")
	no_aud := config
	no_aud.audience = ""
	_, _, aud_ok := oidc_validate_token(no_aud, token, 1_792_404_000_000)
	testing.expect(t, !aud_ok, "empty audience rejected")
	other_scope := config
	other_scope.scope = "other.api"
	_, _, other_ok := oidc_validate_token(other_scope, token, 1_792_404_000_000)
	testing.expect(t, !other_ok, "configured scope is enforced")
	testing.expect_value(t, f.calls, 2) // only the two accepted shapes reached JWKS
}

oidc_bridge_request :: proc(authorization: string, instance_token := "") -> Auth_Request {
	headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	append(&headers, contracts.HTTP_Header{"Authorization", authorization})
	if instance_token != "" do append(&headers, contracts.HTTP_Header{"X-Heimdall-Instance-Token", instance_token})
	return Auth_Request{remote_addr = "127.0.0.1", headers = headers[:]}
}

// With an issuer configured every Authorization header on a user route is an
// OIDC bearer, but bridge credentials keep their explicit rejection and the
// bridge/instance resolvers still own their credentials (never sent to OIDC).
@(test)
test_oidc_mode_keeps_bridge_and_instance_credential_routing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := oidc_test_repo(t)
	defer oidc_test_close(f)
	for token in ([]string{"Bearer hba_access", "Bearer hbr_legacy", "Bearer hbf_refresh"}) {
		_, ok, err := resolve_auth(&f.auth, oidc_bridge_request(token))
		testing.expect(t, !ok && err.code == .Forbidden && err.message == "bridge token cannot call user APIs", token)
	}
	_, hut_ok, hut_err := resolve_auth(&f.auth, oidc_bridge_request("Bearer hut_user_token"))
	testing.expect(t, !hut_ok && hut_err.code == .Unauthenticated, "Hub user tokens are not accepted in OIDC mode")
	// Bare bridge bearer on a shared endpoint: same 403 as without OIDC.
	_, any_ok, any_err := resolve_auth_any(&f.auth, oidc_bridge_request("Bearer hba_access"))
	testing.expect(t, !any_ok && any_err.code == .Forbidden && strings.contains(any_err.message, "bare bridge token"), "bare bridge token on shared endpoint")
	// Instance relays and bridge endpoints reach the bridge resolvers (here
	// unwired, so they report the bridge service rather than an OIDC failure).
	_, inst_ok, inst_err := resolve_auth_any(&f.auth, oidc_bridge_request("Bearer hba_access", "hit_inst_1~sig"))
	testing.expect(t, !inst_ok && inst_err.message == "bridge auth service is not configured", "instance relay uses the bridge resolver")
	_, bridge_ok, bridge_err := resolve_auth_or_bridge_token(&f.auth, oidc_bridge_request("Bearer hba_access"))
	testing.expect(t, !bridge_ok && bridge_err.message == "bridge auth service is not configured", "bridge endpoint uses the bridge resolver")
	testing.expect_value(t, f.fetch.calls, 0) // no bridge credential was ever sent to the provider
}
