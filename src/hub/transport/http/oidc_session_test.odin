#+private file
package http

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:math/big"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import users "odin_test:hub/service/user"

// Browser login (phase 2): the provider is faked in-process. The token endpoint
// mints ID tokens with a TEST-ONLY RSA key (testdata/oidc_rs256_signing.json)
// whose public half is served as the JWKS.

SESSION_TEST_ISSUER :: "https://auth.example.test/application/o/heimdall-native/"
SESSION_TEST_CLIENT :: "heimdall-web"
SESSION_TEST_BASE_S :: i64(1_792_404_000) // 2026-10-19T10:00:00Z

Session_Signing_Key :: struct {
	kid, n, e, d: string,
}

Session_Fixture :: struct {
	conn:           sqlite.Conn,
	user_impl:      sqlite.User_Repo_SQLite,
	user_repo:      iface.User_Repository,
	session_impl:   sqlite.Session_Repo_SQLite,
	session_repo:   iface.Session_Repository,
	users:          users.User_Service,
	auth:           auth_service.Auth_Service,
	handlers:       User_Handlers,
	clock:          platform.Clock,
	now:            string,
	key:            Session_Signing_Key,
	jwks:           string,
	// What the fake token endpoint mints next.
	mint_nonce:     string,
	mint_aud:       string,
	mint_iss:       string,
	mint_sub:       string,
	mint_exp_delta: i64,
	exchange_fail:  bool,
	exchanges:      int,
	last_form:      string,
	last_basic:     string,
	challenge:      string,
}

session_test_clock :: proc(ctx: rawptr) -> string {return (^string)(ctx)^}

session_b64url :: proc(data: []byte) -> string {return auth_service.base64url_encode(data)}

// RSASSA-PKCS1-v1_5 / SHA-256 signing with the test key (tests only).
session_rs256_sign :: proc(key: Session_Signing_Key, message: string) -> string {
	n, _ := auth_service.oidc_decode(key.n)
	d, _ := auth_service.oidc_decode(key.d)
	digest: [32]byte
	hash: sha2.Context_256
	sha2.init_256(&hash); sha2.update(&hash, transmute([]byte)message); sha2.final(&hash, digest[:])
	prefix := []byte{0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20}
	em := make([]byte, len(n), context.temp_allocator)
	em[0], em[1] = 0, 1
	start := len(em) - len(prefix) - 32
	for i in 2 ..< start - 1 do em[i] = 0xff
	em[start - 1] = 0
	copy(em[start:], prefix)
	copy(em[start + len(prefix):], digest[:])
	m, exp, modulus, s: big.Int
	defer big.destroy(&m, &exp, &modulus, &s)
	_ = big.int_from_bytes_big(&m, em)
	_ = big.int_from_bytes_big(&exp, d)
	_ = big.int_from_bytes_big(&modulus, n)
	_ = big.internal_int_power_modulo(&s, &m, &exp, &modulus)
	out := make([]byte, len(n), context.temp_allocator)
	_ = big.int_to_bytes_big(&s, out)
	return session_b64url(out)
}

session_mint_id_token :: proc(f: ^Session_Fixture) -> string {
	header := fmt.tprintf(`{{"alg":"RS256","kid":"%s"}}`, f.key.kid)
	now_s := SESSION_TEST_BASE_S
	if ms, ok := platform.rfc3339_to_unix_ms(f.now); ok do now_s = ms / 1000
	claims := fmt.tprintf(
		`{{"iss":"%s","sub":"%s","aud":"%s","exp":%d,"iat":%d,"nonce":"%s","preferred_username":"alice","name":"Alice","email":"alice@example.test"}}`,
		f.mint_iss, f.mint_sub, f.mint_aud, now_s + f.mint_exp_delta, now_s, f.mint_nonce,
	)
	signing_input := strings.concatenate({session_b64url(transmute([]byte)header), ".", session_b64url(transmute([]byte)claims)}, context.temp_allocator)
	return strings.concatenate({signing_input, ".", session_rs256_sign(f.key, signing_input)}, context.temp_allocator)
}

session_test_fetch :: proc(ctx: rawptr, url, token: string) -> (string, bool) {
	f := (^Session_Fixture)(ctx)
	if strings.has_suffix(url, "/jwks/") do return f.jwks, token == ""
	return "", false
}

session_test_exchange :: proc(ctx: rawptr, url, form, basic: string) -> (string, bool) {
	f := (^Session_Fixture)(ctx)
	f.exchanges += 1
	f.last_form = strings.clone(form, context.temp_allocator)
	f.last_basic = strings.clone(basic, context.temp_allocator)
	if f.exchange_fail do return "", false
	// PKCE: the verifier sent here must hash to the challenge from /login.
	verifier := query_value(form, "code_verifier")
	if f.challenge != "" && auth_service.pkce_challenge_s256(verifier) != f.challenge do return "", false
	if query_value(form, "code") != "the-code" do return "", false
	return fmt.tprintf(`{{"id_token":"%s","token_type":"Bearer"}}`, session_mint_id_token(f)), true
}

session_fixture :: proc(t: ^testing.T, claim_existing := false, link := true) -> ^Session_Fixture {
	f := new(Session_Fixture, context.temp_allocator)
	conn, ok, _ := sqlite.open(":memory:")
	testing.expect(t, ok)
	f.conn = conn
	migrated, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, migrated)
	f.user_repo = sqlite.new_user_repository(&f.user_impl, &f.conn)
	f.session_repo = sqlite.new_session_repository(&f.session_impl, &f.conn)
	f.now = "2026-10-19T10:00:00Z"
	f.clock = platform.Clock{now = session_test_clock, ctx = &f.now}
	f.users = users.new_user_service_basic(&f.user_repo, &f.clock, nil)
	_, saved, _ := iface.user_save(&f.user_repo, domain.User{user_id = "alice", name = "alice", status = .Active, created_at = f.now, updated_at = f.now})
	testing.expect(t, saved)
	if link {
		linked, _ := sqlite.user_link_external_sqlite(&f.conn, "alice", SESSION_TEST_ISSUER, "subject-1", f.now)
		testing.expect(t, linked)
	}
	testing.expect(t, json.unmarshal_string(#load("../../service/auth/testdata/oidc_rs256_signing.json"), &f.key, .JSON, context.temp_allocator) == nil)
	f.jwks = fmt.tprintf(`{{"keys":[{{"kty":"RSA","kid":"%s","alg":"RS256","use":"sig","n":"%s","e":"%s"}}]}}`, f.key.kid, f.key.n, f.key.e)
	f.mint_aud, f.mint_iss, f.mint_sub, f.mint_exp_delta = SESSION_TEST_CLIENT, SESSION_TEST_ISSUER, "subject-1", 300
	f.auth = auth_service.Auth_Service{
		oidc_mode = true,
		users = &f.users,
		clock = &f.clock,
		sessions = &f.session_repo,
		oidc = auth_service.OIDC_Config{
			issuer = SESSION_TEST_ISSUER,
			audience = "heimdall-api",
			scope = "heimdall.api",
			userinfo_url = "https://auth.example.test/application/o/userinfo/",
			jwks_url = "https://auth.example.test/application/o/heimdall-native/jwks/",
			claim_existing_users = claim_existing,
			fetch = session_test_fetch,
			fetch_ctx = f,
		},
		web = auth_service.Web_Login_Config{
			enabled = true,
			authorize_url = "https://auth.example.test/application/o/authorize/",
			token_url = "https://auth.example.test/application/o/token/",
			end_session_url = "https://auth.example.test/application/o/heimdall-native/end-session/",
			client_id = SESSION_TEST_CLIENT,
			redirect_uri = "https://hub.example.test/api/v1/auth/callback",
			ui_origin = "https://hub.example.test",
			session_ttl_ms = 7 * 24 * 3_600_000,
			session_idle_ms = 24 * 3_600_000,
			exchange = session_test_exchange,
			exchange_ctx = f,
		},
	}
	f.handlers = User_Handlers{auth = &f.auth}
	return f
}

session_close :: proc(f: ^Session_Fixture) {
	auth_service.oidc_free(&f.auth)
	sqlite.close(&f.conn)
}

session_header :: proc(resp: Response, name: string, nth := 0) -> string {
	seen := 0
	for h in resp.headers {
		if !strings.equal_fold(h.name, name) do continue
		if seen == nth do return h.value
		seen += 1
	}
	return ""
}

// session_cookie_from extracts NAME=VALUE from a Set-Cookie header value.
session_cookie_pair :: proc(set_cookie: string) -> string {
	if semi := strings.index_byte(set_cookie, ';'); semi >= 0 do return set_cookie[:semi]
	return set_cookie
}

session_get :: proc(path, query: string, cookies: ..string) -> Request {
	headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	if len(cookies) > 0 do append(&headers, contracts.HTTP_Header{"Cookie", strings.join(cookies, "; ", context.temp_allocator)})
	append(&headers, contracts.HTTP_Header{"User-Agent", "session-test"})
	return Request{method = "GET", path = path, query = query, request_id = "session-test", remote_addr = "203.0.113.9", headers = headers[:]}
}

Session_Login :: struct {
	state, nonce, login_cookie: string,
}

// session_begin runs /login and primes the fake provider with its nonce/challenge.
session_begin :: proc(t: ^testing.T, f: ^Session_Fixture, return_to := "%2F%23%2Fchains") -> Session_Login {
	resp := auth_login_handler(&f.handlers, session_get("/api/v1/auth/login", strings.concatenate({"return_to=", return_to}, context.temp_allocator)))
	testing.expect_value(t, resp.status, 302)
	location := session_header(resp, "Location")
	testing.expect(t, strings.has_prefix(location, f.auth.web.authorize_url), location)
	query := location[strings.index_byte(location, '?') + 1:]
	testing.expect_value(t, query_value(query, "response_type"), "code")
	testing.expect_value(t, query_value(query, "client_id"), SESSION_TEST_CLIENT)
	testing.expect_value(t, query_value(query, "redirect_uri"), f.auth.web.redirect_uri)
	testing.expect_value(t, query_value(query, "code_challenge_method"), "S256")
	testing.expect_value(t, query_value(query, "scope"), "openid profile email")
	login := Session_Login{state = query_value(query, "state"), nonce = query_value(query, "nonce")}
	f.challenge = query_value(query, "code_challenge")
	f.mint_nonce = login.nonce
	cookie := session_header(resp, "Set-Cookie")
	for attr in ([]string{"__Host-heimdall_login=", "Path=/", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age=600"}) do testing.expect(t, strings.contains(cookie, attr), attr)
	login.login_cookie = session_cookie_pair(cookie)
	testing.expect_value(t, login.login_cookie, strings.concatenate({"__Host-heimdall_login=", login.state}, context.temp_allocator))
	return login
}

session_callback :: proc(f: ^Session_Fixture, state, code: string, cookies: ..string) -> Response {
	query := fmt.tprintf("code=%s&state=%s", code, state)
	return auth_callback_handler(&f.handlers, session_get("/api/v1/auth/callback", query, ..cookies))
}

@(test)
test_session_login_me_logout_roundtrip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t)
	defer session_close(f)
	login := session_begin(t, f)
	resp := session_callback(f, login.state, "the-code", login.login_cookie)
	testing.expect_value(t, resp.status, 302)
	testing.expect_value(t, session_header(resp, "Location"), "/#/chains")
	set_session := session_header(resp, "Set-Cookie", 0)
	for attr in ([]string{"__Host-heimdall_session=", "Path=/", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age=604800"}) do testing.expect(t, strings.contains(set_session, attr), attr)
	testing.expect(t, strings.contains(session_header(resp, "Set-Cookie", 1), "__Host-heimdall_login=; "), "login cookie cleared")
	testing.expect(t, strings.contains(f.last_form, "grant_type=authorization_code"))
	testing.expect(t, strings.contains(f.last_form, "client_id=heimdall-web"))
	testing.expect_value(t, f.last_basic, "") // public client: no secret configured
	session_cookie := session_cookie_pair(set_session)
	raw := session_cookie[len("__Host-heimdall_session="):]
	// Only the hash is stored.
	_, by_raw, _ := f.session_repo.get_session(f.session_repo.ctx, raw)
	testing.expect(t, !by_raw, "raw session id is never a key")

	me := me_handler(&f.handlers, session_get("/api/v1/me", "", session_cookie))
	testing.expect_value(t, me.status, 200)
	testing.expect(t, strings.contains(me.body, `"user_id":"alice"`), me.body)
	principal, ok, _ := require_auth(&f.auth, session_get("/api/v1/me", "", session_cookie))
	testing.expect(t, ok && principal.kind == .Session && principal.session_id != "" && principal.expires_ms > 0)
	testing.expect(t, contracts.is_user_auth(principal) && contracts.is_interactive_browser_auth(principal))
	guard := stream_auth_guard_make(&f.auth, principal)
	testing.expect(t, stream_auth_still_valid(&guard), "stream valid while the session lives")

	// Session users get user WebSocket tickets that carry the session identity.
	ticket_resp := issue_user_ws_ticket_handler(&f.handlers, Request{method = "POST", path = "/api/v1/me/ws-ticket", request_id = "t", headers = session_get("", "", session_cookie).headers})
	testing.expect_value(t, ticket_resp.status, 200)
	ticket := json_string(ticket_resp.body, "ticket")
	if ticket == "" {
		// respond_success wraps data; extract from the envelope.
		start := strings.index(ticket_resp.body, "uwst_")
		if start >= 0 do ticket = ticket_resp.body[start:start + strings.index_byte(ticket_resp.body[start:], '"')]
	}
	from_ticket, ticket_ok := user_ws_ticket_store_consume(&f.handlers.ws_tickets, ticket)
	testing.expect(t, ticket_ok && from_ticket.kind == .Session && from_ticket.session_id == principal.session_id, ticket)
	user_ws_ticket_store_free(&f.handlers.ws_tickets)

	out := auth_logout_handler(&f.handlers, Request{method = "POST", path = "/api/v1/auth/logout", request_id = "l", headers = session_get("", "", session_cookie).headers})
	testing.expect_value(t, out.status, 200)
	testing.expect(t, strings.contains(out.body, "end-session/?post_logout_redirect_uri=https%3A%2F%2Fhub.example.test%2F&id_token_hint="), out.body)
	testing.expect(t, strings.contains(session_header(out, "Set-Cookie"), "__Host-heimdall_session=; ") && strings.contains(session_header(out, "Set-Cookie"), "Max-Age=0"))
	after := me_handler(&f.handlers, session_get("/api/v1/me", "", session_cookie))
	testing.expect_value(t, after.status, 401)
	// Long-lived streams opened by the session end after logout.
	f.now = "2026-10-19T10:00:31Z"
	testing.expect(t, !stream_auth_still_valid(&guard), "stream revoked after logout")
	testing.expect(t, !auth_service.live_user_authorized(&f.auth, principal))
}

@(test)
test_session_callback_rejections :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t)
	defer session_close(f)
	expect_error :: proc(t: ^testing.T, resp: Response, why: string) {
		testing.expect_value(t, resp.status, 302)
		testing.expect(t, session_header(resp, "Location") == AUTH_ERROR_REDIRECT, why)
		for h in resp.headers do testing.expect(t, !strings.has_prefix(h.value, "__Host-heimdall_session=") || strings.contains(h.value, "Max-Age=0"), why)
	}
	// Unknown state.
	expect_error(t, session_callback(f, "unknown-state", "the-code", "__Host-heimdall_login=unknown-state"), "unknown state")
	// Missing / mismatched login cookie: rejected AND the state is consumed.
	login := session_begin(t, f)
	expect_error(t, session_callback(f, login.state, "the-code"), "missing login cookie")
	expect_error(t, session_callback(f, login.state, "the-code", login.login_cookie), "state was consumed by the failed attempt")
	login = session_begin(t, f)
	expect_error(t, session_callback(f, login.state, "the-code", "__Host-heimdall_login=other"), "mismatched login cookie")
	// Replay of a successful state.
	login = session_begin(t, f)
	ok_resp := session_callback(f, login.state, "the-code", login.login_cookie)
	testing.expect_value(t, session_header(ok_resp, "Location"), "/#/chains")
	expect_error(t, session_callback(f, login.state, "the-code", login.login_cookie), "replayed state")
	// Wrong nonce, audience, issuer, expired ID token.
	cases := [?]string{"nonce", "aud", "iss", "expired", "exchange", "code"}
	for name in cases {
		login = session_begin(t, f)
		code := "the-code"
		switch name {
		case "nonce": f.mint_nonce = "not-the-nonce"
		case "aud": f.mint_aud = "heimdall-api"
		case "iss": f.mint_iss = "https://evil.example/"
		case "expired": f.mint_exp_delta = -61
		case "exchange": f.exchange_fail = true
		case "code": code = "wrong-code"
		}
		expect_error(t, session_callback(f, login.state, code, login.login_cookie), name)
		f.mint_aud, f.mint_iss, f.mint_exp_delta, f.exchange_fail = SESSION_TEST_CLIENT, SESSION_TEST_ISSUER, 300, false
	}
	// Expired login state (10 min TTL).
	login = session_begin(t, f)
	f.now = "2026-10-19T10:10:01Z"
	expect_error(t, session_callback(f, login.state, "the-code", login.login_cookie), "expired login state")
	f.now = "2026-10-19T10:00:00Z"
	// Provider error parameter: state consumed, generic error.
	login = session_begin(t, f)
	err_resp := auth_callback_handler(&f.handlers, session_get("/api/v1/auth/callback", fmt.tprintf("error=access_denied&error_description=%%3Cscript%%3E&state=%s", login.state), login.login_cookie))
	expect_error(t, err_resp, "provider error")
	expect_error(t, session_callback(f, login.state, "the-code", login.login_cookie), "state consumed by provider error")
}

@(test)
test_session_identity_policy_redirects_forbidden :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t, claim_existing = false, link = false)
	defer session_close(f)
	login := session_begin(t, f)
	resp := session_callback(f, login.state, "the-code", login.login_cookie)
	testing.expect_value(t, resp.status, 302)
	testing.expect_value(t, session_header(resp, "Location"), AUTH_FORBIDDEN_REDIRECT)
	// Opt-in claim links the existing user on first browser login.
	f.auth.oidc.claim_existing_users = true
	login = session_begin(t, f)
	resp = session_callback(f, login.state, "the-code", login.login_cookie)
	testing.expect_value(t, session_header(resp, "Location"), "/#/chains")
}

@(test)
test_session_return_to_is_same_origin_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t)
	defer session_close(f)
	bad := [?]string{"%2F%2Fevil.example", "%2F%5Cevil.example", "https%3A%2F%2Fevil.example", "evil.example", "%2F%252F%252Fevil.example",
		"%2F%2F%2Fevil", "%2F%255Cevil", "javascript%3Aalert(1)", "%2Fa%0D%0ASet-Cookie%3Ax", "%2F%25%32%46%25%32%46evil"}
	for value in bad {
		resp := auth_login_handler(&f.handlers, session_get("/api/v1/auth/login", strings.concatenate({"return_to=", value}, context.temp_allocator)))
		testing.expect(t, resp.status == 400, value)
	}
	for value in ([]string{"", "%2F", "%2F%23%2Fchains%3Fx%3D1", "%2Fsettings%2Fbilling"}) {
		resp := auth_login_handler(&f.handlers, session_get("/api/v1/auth/login", strings.concatenate({"return_to=", value}, context.temp_allocator)))
		testing.expect(t, resp.status == 302, value)
	}
}

@(test)
test_session_expiry_touch_and_purge :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t)
	defer session_close(f)
	login := session_begin(t, f)
	resp := session_callback(f, login.state, "the-code", login.login_cookie)
	cookie := session_cookie_pair(session_header(resp, "Set-Cookie", 0))
	hash := auth_service.sha256_hex(cookie[len("__Host-heimdall_session="):])
	row, _, _ := f.session_repo.get_session(f.session_repo.ctx, hash)
	created := row.last_seen_at_ms
	// Within a minute: no write.
	f.now = "2026-10-19T10:00:59Z"
	_, ok, _ := require_auth(&f.auth, session_get("/api/v1/me", "", cookie))
	testing.expect(t, ok)
	row, _, _ = f.session_repo.get_session(f.session_repo.ctx, hash)
	testing.expect_value(t, row.last_seen_at_ms, created)
	// After a minute: last_seen and the idle expiry move forward.
	f.now = "2026-10-19T10:01:00Z"
	_, ok, _ = require_auth(&f.auth, session_get("/api/v1/me", "", cookie))
	row, _, _ = f.session_repo.get_session(f.session_repo.ctx, hash)
	testing.expect(t, ok && row.last_seen_at_ms == created + 60_000)
	testing.expect_value(t, row.idle_expires_at_ms, created + 60_000 + 24 * 3_600_000)
	// Idle expiry (24 h without use) ends the session.
	f.now = "2026-10-20T10:01:00Z"
	_, idle_ok, _ := require_auth(&f.auth, session_get("/api/v1/me", "", cookie))
	testing.expect(t, !idle_ok, "idle-expired session rejected")
	// Purge removes the expired session, stale login states and v2 nonces.
	_ = session_begin(t, f) // a login state created now, expiring in 10 min
	testing.expect(t, sqlite.exec(&f.conn, "INSERT INTO vault_request_nonces VALUES ('alice','device','old-nonce',1);"))
	f.now = "2026-10-20T10:20:00Z"
	removed, purge_err := auth_service.purge_expired_auth_rows(&f.auth)
	testing.expect(t, purge_err.code == .None && removed == 3, fmt.tprintf("removed %d", removed))
	_, exists, _ := f.session_repo.get_session(f.session_repo.ctx, hash)
	testing.expect(t, !exists)
	// Absolute expiry: a session used continuously still ends after the TTL.
	f.now = "2026-10-19T10:00:00Z"
	login = session_begin(t, f)
	resp = session_callback(f, login.state, "the-code", login.login_cookie)
	cookie = session_cookie_pair(session_header(resp, "Set-Cookie", 0))
	hours := [?]string{"2026-10-20T09:00:00Z", "2026-10-21T08:00:00Z", "2026-10-22T07:00:00Z", "2026-10-23T06:00:00Z", "2026-10-24T05:00:00Z", "2026-10-25T04:00:00Z", "2026-10-26T03:00:00Z"}
	for h in hours {
		f.now = h
		_, alive, _ := require_auth(&f.auth, session_get("/api/v1/me", "", cookie))
		testing.expect(t, alive, h)
	}
	f.now = "2026-10-26T10:00:00Z"
	_, absolute_ok, _ := require_auth(&f.auth, session_get("/api/v1/me", "", cookie))
	testing.expect(t, !absolute_ok, "absolute expiry")
}

@(test)
test_session_csrf_websocket_and_preview_isolation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ui :: "https://hub.example.test"
	cookie := contracts.HTTP_Header{"Cookie", "__Host-heimdall_session=abc"}
	cross := []contracts.HTTP_Header{cookie, {"Origin", "https://evil.example"}}
	allowed, _ := csrf_decide("POST", cross, ui, false)
	testing.expect(t, !allowed, "cross-origin POST with the session cookie")
	same_site := []contracts.HTTP_Header{cookie, {"Sec-Fetch-Site", "same-site"}}
	allowed, _ = csrf_decide("POST", same_site, ui, false)
	testing.expect(t, !allowed, "same-site (sibling origin, e.g. preview) POST")
	no_meta := []contracts.HTTP_Header{cookie}
	allowed, _ = csrf_decide("POST", no_meta, ui, false)
	testing.expect(t, !allowed, "cookie POST without browser metadata")
	same := []contracts.HTTP_Header{cookie, {"Origin", ui}}
	allowed, _ = csrf_decide("POST", same, ui, false)
	testing.expect(t, allowed, "same-origin POST")
	allowed, _ = csrf_decide("GET", cross, ui, false)
	testing.expect(t, allowed, "safe method")
	allowed, _ = csrf_decide("GET", cross, ui, true)
	testing.expect(t, !allowed, "cookie WebSocket upgrade from another origin")
	allowed, _ = csrf_decide("GET", no_meta, ui, true)
	testing.expect(t, !allowed, "cookie WebSocket upgrade without Origin")
	allowed, _ = csrf_decide("GET", same, ui, true)
	testing.expect(t, allowed, "same-origin WebSocket upgrade")
	// Preview upstreams never receive Hub session/login cookies.
	filtered := _preview_filter_cookie_header("app=1; __Host-heimdall_session=s; __Host-heimdall_login=l; authentik_session=x; theme=dark")
	testing.expect_value(t, filtered, "app=1; theme=dark")
}

@(test)
test_session_cookie_parsing_and_kind_helpers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	one := []contracts.HTTP_Header{{"Cookie", "a=1; __Host-heimdall_session=xyz; b=2"}}
	v, ok := auth_service.cookie_value(one, auth_service.SESSION_COOKIE)
	testing.expect(t, ok && v == "xyz")
	// Duplicate names are ambiguous and never authenticate.
	dup := []contracts.HTTP_Header{{"Cookie", "__Host-heimdall_session=a"}, {"Cookie", "__Host-heimdall_session=b"}}
	_, ok = auth_service.cookie_value(dup, auth_service.SESSION_COOKIE)
	testing.expect(t, !ok)
	for kind in contracts.Auth_Kind {
		ctx := contracts.Auth_Context{kind = kind}
		user := kind == .Session || kind == .OIDC || kind == .User_Token || kind == .Trusted_Proxy
		testing.expect(t, contracts.is_user_auth(ctx) == user)
		testing.expect(t, contracts.is_interactive_browser_auth(ctx) == (kind == .Session || kind == .Trusted_Proxy))
	}
	// OIDC bearer streams are bounded by the token expiry.
	f := session_fixture(t)
	defer session_close(f)
	bearer := contracts.Auth_Context{kind = .OIDC, user_id = "alice", expires_ms = (SESSION_TEST_BASE_S + 60) * 1000}
	guard := stream_auth_guard_make(&f.auth, bearer)
	testing.expect(t, stream_auth_still_valid(&guard))
	f.now = "2026-10-19T10:01:00Z"
	testing.expect(t, !stream_auth_still_valid(&guard), "bearer stream ends at token expiry")
}

@(test)
test_session_confidential_client_and_auth_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := session_fixture(t)
	defer session_close(f)
	f.auth.web.client_secret = "s3cr3t:with/specials"
	login := session_begin(t, f)
	resp := session_callback(f, login.state, "the-code", login.login_cookie)
	testing.expect_value(t, session_header(resp, "Location"), "/#/chains")
	// HTTP Basic with form-encoded id and secret (RFC 6749 §2.3.1).
	testing.expect_value(t, f.last_basic, "Basic aGVpbWRhbGwtd2ViOnMzY3IzdCUzQXdpdGglMkZzcGVjaWFscw==")
	cfg := auth_config_handler(&f.handlers, session_get("/api/v1/auth/config", ""))
	testing.expect(t, strings.contains(cfg.body, `"mode":"oidc"`) && strings.contains(cfg.body, `"login_url":"/api/v1/auth/login"`) && strings.contains(cfg.body, `"logout":"POST /api/v1/auth/logout"`), cfg.body)
	f.auth.web.enabled = false
	off := auth_login_handler(&f.handlers, session_get("/api/v1/auth/login", ""))
	testing.expect_value(t, off.status, 404)
}
