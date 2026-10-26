package auth

import "core:crypto/hmac"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "base:runtime"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"
import httpc "odin_test:lib/httpc"
import os_random "odin_test:lib/os_random"
import chacha20poly1305 "core:crypto/chacha20poly1305"
import vault "odin_test:lib/vault"

// Browser login (docs/plans/oidc-only-auth.md, "Browser session flow"): the Hub
// is an OIDC client of the SAME provider/issuer as the native app, using the
// authorization code flow with PKCE (S256), state and nonce. Tokens never reach
// the browser; the browser holds only an opaque, server-side session id.

SESSION_COOKIE :: "__Host-heimdall_session"
LOGIN_COOKIE :: "__Host-heimdall_login"
LOGIN_STATE_TTL_MS :: 10 * 60_000
// last_seen / idle expiry is written at most this often per session.
SESSION_TOUCH_INTERVAL_MS :: 60_000
DEFAULT_SESSION_TTL_HOURS :: 7 * 24
DEFAULT_SESSION_IDLE_HOURS :: 24
// Upper bound on a single return_to path.
RETURN_TO_MAX_BYTES :: 2048
// Unauthenticated GET /api/v1/auth/login creates a row; bound it per client IP
// and globally so it cannot be used to fill the database.
LOGIN_STARTS_PER_IP_PER_WINDOW :: 20
LOGIN_RATE_WINDOW_MS :: 60_000
// Consumed login states remembered (by hash, until their expiry) so a sealed
// login cookie is single use. Bounded; the oldest entries are evicted.
LOGIN_CONSUMED_MAX :: 16384
LOGIN_SEAL_AAD :: "heimdall-login-v1"

// Pending logins are NOT stored server-side: state, nonce, PKCE verifier,
// return_to and expiry travel in the __Host-heimdall_login cookie, sealed with
// XChaCha20-Poly1305 under a per-process random key. An unauthenticated
// /auth/login therefore creates no row; a Hub restart invalidates in-flight
// logins (the user simply signs in again).
Login_Seal :: struct {
	mutex:    sync.Mutex,
	key:      [chacha20poly1305.KEY_SIZE]byte,
	ready:    bool,
	consumed: map[string]i64, // sha256(state) -> expires_ms
}

Login_Payload :: struct {
	s, n, v, r: string,
	e:          i64,
}

@(private = "file")
login_seal_key :: proc(seal: ^Login_Seal) -> ([chacha20poly1305.KEY_SIZE]byte, bool) {
	sync.mutex_lock(&seal.mutex)
	defer sync.mutex_unlock(&seal.mutex)
	if !seal.ready {
		if !os_random.fill(seal.key[:]) do return {}, false
		seal.ready = true
	}
	return seal.key, true
}

// hub_process_key is the per-process random root secret. It is never used
// directly: every purpose derives its own sub-key with hub_subkey.
hub_process_key :: proc(service: ^Auth_Service) -> ([chacha20poly1305.KEY_SIZE]byte, bool) {
	return login_seal_key(&service.login_seal)
}

HUB_SUBKEY_LOGIN_SEAL :: "heimdall-login-seal-v1"
HUB_SUBKEY_PREVIEW_BIND :: "heimdall-preview-bind-v1"

// hub_subkey derives a purpose-specific key: HMAC-SHA256(process key, label).
hub_subkey :: proc(service: ^Auth_Service, label: string) -> ([32]byte, bool) {
	root, ok := hub_process_key(service)
	if !ok do return {}, false
	out: [32]byte
	hmac.sum(.SHA256, out[:], transmute([]byte)label, root[:])
	return out, true
}

// login_cookie_seal returns base64url(nonce || ciphertext || tag).
login_cookie_seal :: proc(service: ^Auth_Service, payload: Login_Payload) -> (string, bool) {
	key, key_ok := hub_subkey(service, HUB_SUBKEY_LOGIN_SEAL)
	if !key_ok do return "", false
	plain, merr := json.marshal(payload, allocator = context.temp_allocator)
	if merr != nil do return "", false
	out := make([]byte, chacha20poly1305.XIV_SIZE + len(plain) + chacha20poly1305.TAG_SIZE, context.temp_allocator)
	iv := out[:chacha20poly1305.XIV_SIZE]
	if !os_random.fill(iv) do return "", false
	ct := out[chacha20poly1305.XIV_SIZE:chacha20poly1305.XIV_SIZE + len(plain)]
	tag := out[chacha20poly1305.XIV_SIZE + len(plain):]
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	chacha20poly1305.seal(&ctx, ct, tag, iv, transmute([]byte)string(LOGIN_SEAL_AAD), plain)
	return base64url_encode(out), true
}

login_cookie_open :: proc(service: ^Auth_Service, sealed: string) -> (Login_Payload, bool) {
	if sealed == "" || len(sealed) > 4096 do return {}, false
	raw, decoded := oidc_decode(sealed)
	if !decoded || len(raw) < chacha20poly1305.XIV_SIZE + chacha20poly1305.TAG_SIZE + 2 do return {}, false
	key, key_ok := hub_subkey(service, HUB_SUBKEY_LOGIN_SEAL)
	if !key_ok do return {}, false
	iv := raw[:chacha20poly1305.XIV_SIZE]
	ct := raw[chacha20poly1305.XIV_SIZE:len(raw) - chacha20poly1305.TAG_SIZE]
	tag := raw[len(raw) - chacha20poly1305.TAG_SIZE:]
	plain := make([]byte, len(ct), context.temp_allocator)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init_xchacha(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	if !chacha20poly1305.open(&ctx, plain, iv, transmute([]byte)string(LOGIN_SEAL_AAD), ct, tag) do return {}, false
	payload: Login_Payload
	if json.unmarshal(plain, &payload, .JSON, context.temp_allocator) != nil do return {}, false
	return payload, true
}

// login_state_consume marks a state used. False if it was already consumed.
login_state_consume :: proc(seal: ^Login_Seal, state: string, expires_ms, now_ms: i64) -> bool {
	sync.mutex_lock(&seal.mutex)
	defer sync.mutex_unlock(&seal.mutex)
	a := runtime.heap_allocator()
	if seal.consumed == nil do seal.consumed = make(map[string]i64, a)
	hash := sha256_hex(state)
	if _, used := seal.consumed[hash]; used do return false
	if len(seal.consumed) >= LOGIN_CONSUMED_MAX {
		dead := make([dynamic]string, context.temp_allocator)
		for k, e in seal.consumed do if e <= now_ms do append(&dead, k)
		for k in dead {key, _ := delete_key(&seal.consumed, k); delete(key, a)}
		for len(seal.consumed) >= LOGIN_CONSUMED_MAX {
			oldest_key := ""
			oldest := max(i64)
			for k, e in seal.consumed do if e < oldest {oldest = e; oldest_key = k}
			key, _ := delete_key(&seal.consumed, oldest_key)
			delete(key, a)
		}
	}
	seal.consumed[strings.clone(hash, a)] = expires_ms
	return true
}

login_seal_free :: proc(seal: ^Login_Seal) {
	sync.mutex_lock(&seal.mutex)
	defer sync.mutex_unlock(&seal.mutex)
	for k in seal.consumed do delete(k, runtime.heap_allocator())
	delete(seal.consumed)
	seal.consumed = nil
}

Login_Rate_Window :: struct {
	start_ms: i64,
	count: int,
}

Login_Rate_Limiter :: struct {
	mutex: sync.Mutex,
	windows: map[string]Login_Rate_Window,
}

// login_rate_allow counts one login start for `client_ip` (fixed window).
login_rate_allow :: proc(limiter: ^Login_Rate_Limiter, client_ip: string, now_ms: i64) -> bool {
	sync.mutex_lock(&limiter.mutex)
	defer sync.mutex_unlock(&limiter.mutex)
	a := runtime.heap_allocator()
	if limiter.windows == nil do limiter.windows = make(map[string]Login_Rate_Window, a)
	if len(limiter.windows) >= 4096 {
		stale := make([dynamic]string, context.temp_allocator)
		for k, w in limiter.windows do if now_ms - w.start_ms >= LOGIN_RATE_WINDOW_MS do append(&stale, k)
		for k in stale {
			key, _ := delete_key(&limiter.windows, k)
			delete(key, a)
		}
		// Still full (a burst of distinct clients): evict the oldest windows
		// rather than refusing everyone.
		for len(limiter.windows) >= 4096 {
			oldest_key := ""
			oldest := max(i64)
			for k, w in limiter.windows do if w.start_ms < oldest {oldest = w.start_ms; oldest_key = k}
			key, _ := delete_key(&limiter.windows, oldest_key)
			delete(key, a)
		}
	}
	key := client_ip if client_ip != "" else "unknown"
	w, found := limiter.windows[key]
	if !found || now_ms - w.start_ms >= LOGIN_RATE_WINDOW_MS {
		if !found do key = strings.clone(key, a)
		limiter.windows[key] = Login_Rate_Window{start_ms = now_ms, count = 1}
		return true
	}
	if w.count >= LOGIN_STARTS_PER_IP_PER_WINDOW do return false
	w.count += 1
	limiter.windows[key] = w
	return true
}

login_rate_limiter_free :: proc(limiter: ^Login_Rate_Limiter) {
	sync.mutex_lock(&limiter.mutex)
	defer sync.mutex_unlock(&limiter.mutex)
	for k in limiter.windows do delete(k, runtime.heap_allocator())
	delete(limiter.windows)
	limiter.windows = nil
}

Web_Login_Config :: struct {
	enabled: bool,
	authorize_url, token_url, end_session_url: string,
	client_id: string,
	client_secret: string, // optional; empty = public client (PKCE only). Never logged.
	redirect_uri: string,
	ui_origin: string,
	session_ttl_ms, session_idle_ms: i64,
	// Injectable token-endpoint transport for deterministic tests. Returns the
	// body of a 200 response; production uses https only and never echoes errors.
	// `form` is the token request; `basic_authorization` the Authorization header
	// value ("" for a public client).
	exchange: proc(ctx: rawptr, url: string, form: []httpc.Form_Field, basic_authorization: string) -> (string, bool),
	exchange_ctx: rawptr,
}

// Login_Failure classifies a callback failure for the redirect the user sees.
Login_Failure :: enum {
	None,
	Failed, // any protocol/validation failure: /?auth_error=1
	Forbidden, // identity policy refused (unlinked / not provisioned / disabled)
}

web_login_enabled :: proc(service: ^Auth_Service) -> bool {
	return service != nil && service.web.enabled && service.sessions != nil
}

now_unix_ms :: proc(service: ^Auth_Service) -> (i64, bool) {
	if service == nil do return 0, false
	if service.clock == nil {
		clock := platform.real_clock()
		return platform.rfc3339_to_unix_ms(platform.clock_now(&clock))
	}
	return platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
}

// random_token returns `n` bytes from the OS CSPRNG as unpadded base64url.
random_token :: proc(n := 32, allocator := context.temp_allocator) -> (string, bool) {
	buf := make([]byte, n, context.temp_allocator)
	if !os_random.fill(buf) do return "", false
	return base64url_encode(buf, allocator), true
}

base64url_encode :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	b := strings.builder_make(allocator)
	acc: u32
	bits: uint
	for v in data {
		acc = (acc << 8) | u32(v)
		bits += 8
		for bits >= 6 {
			bits -= 6
			strings.write_byte(&b, alphabet[(acc >> bits) & 63])
		}
		acc &= (1 << bits) - 1
	}
	if bits > 0 do strings.write_byte(&b, alphabet[(acc << (6 - bits)) & 63])
	return strings.to_string(b)
}

sha256_hex :: proc(value: string) -> string {
	hash: sha2.Context_256
	digest: [32]byte
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)value)
	sha2.final(&hash, digest[:])
	return vault.hex_encode_lower(digest[:], context.temp_allocator)
}

pkce_challenge_s256 :: proc(verifier: string) -> string {
	hash: sha2.Context_256
	digest: [32]byte
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)verifier)
	sha2.final(&hash, digest[:])
	return base64url_encode(digest[:])
}

// form_encode percent-encodes everything except RFC 3986 unreserved characters.
form_encode :: proc(value: string, allocator := context.temp_allocator) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(allocator)
	for i in 0 ..< len(value) {
		c := value[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
		}
	}
	return strings.to_string(b)
}

// cookie_value returns the value of cookie `name` across all Cookie headers.
// A name that appears more than once is treated as absent: ambiguous cookies
// (e.g. one injected by a sibling origin) never authenticate.
cookie_value :: proc(headers: []contracts.HTTP_Header, name: string) -> (string, bool) {
	value := ""
	count := 0
	for h in headers {
		if !ascii_equal_fold(h.name, "Cookie") do continue
		rest := h.value
		for len(rest) > 0 {
			part := rest
			if semi := strings.index_byte(rest, ';'); semi >= 0 {
				part = rest[:semi]
				rest = rest[semi + 1:]
			} else {
				rest = ""
			}
			part = strings.trim_space(part)
			eq := strings.index_byte(part, '=')
			if eq < 0 do continue
			if part[:eq] == name {
				count += 1
				value = part[eq + 1:]
			}
		}
	}
	if count != 1 || value == "" do return "", false
	return value, true
}

// safe_return_to accepts only a same-origin relative path: a single leading
// '/', no scheme or authority (`//`, `/\`), no backslashes or control bytes, and
// the same rules after percent-decoding (twice), so encoded variants such as
// `/%2F%2Fevil.example` or `/%5Cevil` cannot become an off-site redirect.
safe_return_to :: proc(value: string) -> (string, bool) {
	if value == "" do return "/", true
	if len(value) > RETURN_TO_MAX_BYTES do return "", false
	candidate := value
	for _ in 0 ..< 3 {
		if !return_to_shape_ok(candidate) do return "", false
		if strings.index_byte(candidate, '%') < 0 do break
		decoded, ok := percent_decode_strict(candidate)
		if !ok do return "", false
		candidate = decoded
	}
	// Anything still percent-encoded after the last pass is too deeply nested to
	// be a real path: refuse rather than guess what a later decoder will see.
	if !return_to_shape_ok(candidate) || strings.index_byte(candidate, '%') >= 0 do return "", false
	return value, true
}

@(private = "file")
return_to_shape_ok :: proc(value: string) -> bool {
	if len(value) == 0 || value[0] != '/' do return false
	if len(value) > 1 && (value[1] == '/' || value[1] == '\\') do return false
	for i in 0 ..< len(value) {
		c := value[i]
		if c < 0x20 || c == 0x7f || c == '\\' do return false
	}
	// A scheme can only appear before the first '/', '?' or '#'; the leading '/'
	// already rules it out, but reject an embedded authority marker regardless.
	if strings.contains(value, "://") do return false
	return true
}

@(private = "file")
percent_decode_strict :: proc(value: string) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(value) {
		c := value[i]
		if c != '%' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if i + 2 >= len(value) do return "", false
		hi, hi_ok := hex_nibble(value[i + 1])
		lo, lo_ok := hex_nibble(value[i + 2])
		if !hi_ok || !lo_ok do return "", false
		strings.write_byte(&b, hi << 4 | lo)
		i += 3
	}
	return strings.to_string(b), true
}

@(private = "file")
hex_nibble :: proc(c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

// web_login_begin creates a single-use login state (state, nonce, PKCE verifier)
// and returns the provider authorization URL plus the state (for the login cookie).
// web_login_begin starts a sign-in: it returns the provider authorization URL
// and the sealed login cookie value (no server-side row is created).
web_login_begin :: proc(service: ^Auth_Service, return_to: string, client_ip := "") -> (redirect_url: string, login_cookie: string, ok: bool, err: domain.Domain_Error) {
	if !web_login_enabled(service) do return "", "", false, domain.domain_error(.Not_Found, "browser login is not configured")
	target, target_ok := safe_return_to(return_to)
	if !target_ok do return "", "", false, domain.domain_error(.Validation_Failed, "return_to must be a same-origin relative path")
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", "", false, domain.domain_error(.Internal_Error, "clock unavailable")
	if !login_rate_allow(&service.login_limiter, client_ip, now) do return "", "", false, domain.domain_error(.Rate_Limited, "too many sign-in attempts; retry shortly")
	state_value, s_ok := random_token(32)
	nonce, n_ok := random_token(32)
	verifier, v_ok := random_token(48) // 64 base64url chars (RFC 7636: 43..128)
	if !s_ok || !n_ok || !v_ok do return "", "", false, domain.domain_error(.Internal_Error, "random source unavailable")
	sealed, sealed_ok := login_cookie_seal(service, Login_Payload{s = state_value, n = nonce, v = verifier, r = target, e = now + LOGIN_STATE_TTL_MS})
	if !sealed_ok do return "", "", false, domain.domain_error(.Internal_Error, "could not seal the login state")
	authorize, auth_err := httpc.parse_url(service.web.authorize_url)
	if auth_err != .None do return "", "", false, domain.domain_error(.Internal_Error, "browser login authorize_url is not a valid URL")
	url, url_err := httpc.build_url(authorize, nil, {
		{"response_type", "code"},
		{"client_id", service.web.client_id},
		{"redirect_uri", service.web.redirect_uri},
		{"scope", "openid profile email"},
		{"state", state_value},
		{"nonce", nonce},
		{"code_challenge", pkce_challenge_s256(verifier)},
		{"code_challenge_method", "S256"},
	}, context.temp_allocator)
	if url_err != .None do return "", "", false, domain.domain_error(.Internal_Error, "could not build the authorization URL")
	return url, sealed, true, {}
}

// web_login_abort consumes the login state of a callback that will not complete
// (the provider returned an error), so the same state can never be used later.
web_login_abort :: proc(service: ^Auth_Service, query_state, login_cookie: string) {
	if !web_login_enabled(service) do return
	login, opened := login_cookie_open(service, login_cookie)
	if !opened || query_state == "" || !oidc_constant_time_equal(login.s, query_state) do return
	now, _ := now_unix_ms(service)
	_ = login_state_consume(&service.login_seal, login.s, login.e, now)
}

OIDC_Token_Response :: struct {
	id_token: string,
	token_type: string,
}

// oidc_exchange_code posts the authorization code to the token endpoint through
// the bounded outbound path. Only a 200 body is returned; provider error bodies
// are never echoed or logged.
@(private = "file")
oidc_exchange_code :: proc(service: ^Auth_Service, form: []httpc.Form_Field, basic: string) -> (string, bool) {
	state := &service.oidc_state
	if !oidc_outbound_acquire(state) do return "", false
	defer oidc_outbound_release(state)
	url := service.web.token_url
	if service.web.exchange != nil do return service.web.exchange(service.web.exchange_ctx, url, form, basic)
	if !oidc_endpoint_allowed(url, service.oidc.allow_insecure_localhost) do return "", false
	endpoint, url_err := httpc.parse_url(url)
	if url_err != .None {
		fmt.printfln("ham-hub oidc_http_rejected reason=invalid_url target=token")
		return "", false
	}
	headers: [2]httpc.Header
	headers[0] = httpc.accept_json()
	n_headers := 1
	if basic != "" {
		headers[1] = httpc.Header{name = "Authorization", value = basic}
		n_headers = 2
	}
	res, err := httpc.send({
		method = .POST, url = endpoint, headers = headers[:n_headers], body = httpc.form_body(form),
		timeout_ms = 5000, max_response_bytes = OIDC_MAX_RESPONSE_BYTES,
	}, context.temp_allocator)
	if err != .None {
		fmt.printfln("ham-hub oidc_http_rejected reason=request_failed target=token error=%s", httpc.error_string(err))
		return "", false
	}
	if res.status != 200 {
		fmt.printfln("ham-hub oidc_http_rejected reason=http_status status=%d target=token", res.status)
		return "", false
	}
	return httpc.text(res), true
}

// web_login_complete finishes the authorization-code flow. The login state is
// consumed (deleted) before anything else, so it is single use even on failure.
// On success returns the raw session id (for the cookie only) and return_to.
web_login_complete :: proc(
	service: ^Auth_Service,
	query_state, login_cookie, code, user_agent: string,
) -> (
	session_id: string,
	return_to: string,
	failure: Login_Failure,
	stage: string,
) {
	if !web_login_enabled(service) do return "", "", .Failed, "disabled"
	if query_state == "" || len(query_state) > 512 do return "", "", .Failed, "state_missing"
	repo := service.sessions
	// The login state lives only in this browser's sealed cookie; the query state
	// must equal it (login CSRF), and it is consumed before anything else so a
	// replayed callback can never be used again.
	sealed, opened := login_cookie_open(service, login_cookie)
	if !opened do return "", "", .Failed, "state_cookie_invalid"
	if !oidc_constant_time_equal(sealed.s, query_state) do return "", "", .Failed, "state_cookie_mismatch"
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", "", .Failed, "clock"
	if sealed.e <= now do return "", "", .Failed, "state_expired"
	if !login_state_consume(&service.login_seal, sealed.s, sealed.e, now) do return "", "", .Failed, "state_replayed"
	if code == "" || len(code) > 4096 do return "", "", .Failed, "code_missing"
	login := iface.OIDC_Login_State{nonce = sealed.n, code_verifier = sealed.v, return_to = sealed.r, expires_at_ms = sealed.e}

	form := make([]httpc.Form_Field, 5, context.temp_allocator)
	form[0] = {"grant_type", "authorization_code"}
	form[1] = {"code", code}
	form[2] = {"redirect_uri", service.web.redirect_uri}
	form[3] = {"code_verifier", login.code_verifier}
	form[4] = {"client_id", service.web.client_id}
	basic := ""
	if service.web.client_secret != "" {
		// client_secret_basic (RFC 6749 §2.3.1): id and secret form-encoded, then base64.
		auth, auth_err := httpc.oauth_client_basic(service.web.client_id, service.web.client_secret)
		if auth_err != .None do return "", "", .Failed, "client_secret"
		basic = auth.value
	}
	body, exchanged := oidc_exchange_code(service, form, basic)
	if !exchanged do return "", "", .Failed, "token_exchange"
	tokens: OIDC_Token_Response
	if json.unmarshal_string(body, &tokens, .JSON, context.temp_allocator) != nil || tokens.id_token == "" do return "", "", .Failed, "token_response"

	identity, id_stage, id_ok := oidc_validate_id_token(service.oidc, &service.oidc_state, service.web.client_id, login.nonce, tokens.id_token, now)
	if !id_ok do return "", "", .Failed, strings.concatenate({"id_token_", id_stage}, context.temp_allocator)
	user, user_ok, user_err := oidc_resolve_identity(service, identity)
	if !user_ok {
		if user_err.code == .Forbidden || user_err.code == .Conflict do return "", "", .Forbidden, "identity_policy"
		return "", "", .Failed, "identity"
	}
	user_service.ensure_canonical_resources(service.users, user.user_id)

	raw, raw_ok := random_token(32)
	if !raw_ok do return "", "", .Failed, "random"
	ttl := service.web.session_ttl_ms
	idle := service.web.session_idle_ms
	if ttl <= 0 do ttl = DEFAULT_SESSION_TTL_HOURS * 3_600_000
	if idle <= 0 do idle = DEFAULT_SESSION_IDLE_HOURS * 3_600_000
	ua := user_agent
	if len(ua) > 256 do ua = ua[:256]
	create_err := repo.create_session(repo.ctx, iface.User_Session{
		session_id_hash = sha256_hex(raw),
		user_id = string(user.user_id),
		created_at_ms = now,
		last_seen_at_ms = now,
		expires_at_ms = now + ttl,
		idle_expires_at_ms = min(now + idle, now + ttl),
		id_token = tokens.id_token,
		user_agent = ua,
	})
	if create_err.code != .None do return "", "", .Failed, "session_store"
	fmt.printfln("ham-hub oidc_login_succeeded user_id=%s", string(user.user_id))
	return raw, login.return_to, .None, ""
}

session_unauthenticated :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Unauthenticated, "session is invalid or expired; sign in again")
}

// session_lookup_live returns the session row if it exists and neither its
// absolute nor idle expiry has passed.
session_lookup_live :: proc(service: ^Auth_Service, session_hash: string, now: i64) -> (iface.User_Session, bool) {
	if !web_login_enabled(service) || session_hash == "" do return {}, false
	repo := service.sessions
	row, found, err := repo.get_session(repo.ctx, session_hash)
	if err.code != .None || !found do return {}, false
	if row.expires_at_ms <= now || row.idle_expires_at_ms <= now do return {}, false
	return row, true
}

// resolve_session_auth authenticates the __Host-heimdall_session cookie.
resolve_session_auth :: proc(service: ^Auth_Service, raw_session: string) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if !web_login_enabled(service) do return {}, false, session_unauthenticated()
	if len(raw_session) < 32 || len(raw_session) > 128 do return {}, false, session_unauthenticated()
	now, now_ok := now_unix_ms(service)
	if !now_ok do return {}, false, domain.domain_error(.Internal_Error, "clock unavailable")
	hash := sha256_hex(raw_session)
	row, live := session_lookup_live(service, hash, now)
	if !live do return {}, false, session_unauthenticated()
	user, found, user_err := user_service.get_user(service.users, domain.User_ID(row.user_id))
	if !found || user_err.code != .None || user.status != .Active do return {}, false, session_unauthenticated()
	if now - row.last_seen_at_ms >= SESSION_TOUCH_INTERVAL_MS {
		idle := service.web.session_idle_ms
		if idle <= 0 do idle = DEFAULT_SESSION_IDLE_HOURS * 3_600_000
		repo := service.sessions
		_ = repo.touch_session(repo.ctx, hash, now, now + idle)
	}
	return contracts.Auth_Context{
		kind = .Session,
		user_id = string(user.user_id),
		name = user.name,
		display_name = user.display_name,
		email = user.email,
		session_id = hash,
		expires_ms = row.expires_at_ms,
	}, true, {}
}

// web_logout deletes the request's session (if any) and returns where the
// browser should go next: the provider end-session URL (with id_token_hint and
// post_logout_redirect_uri) when configured, else the legacy logout URL or "/".
web_logout :: proc(service: ^Auth_Service, headers: []contracts.HTTP_Header) -> string {
	id_token := ""
	if web_login_enabled(service) {
		if raw, present := cookie_value(headers, SESSION_COOKIE); present {
			repo := service.sessions
			hash := sha256_hex(raw)
			row, found, _ := repo.delete_session(repo.ctx, hash)
			if found do id_token = row.id_token
			preview_end_for_parent(service, hash)
		}
	}
	if service != nil && service.web.end_session_url != "" {
		sep := "&" if strings.contains(service.web.end_session_url, "?") else "?"
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, service.web.end_session_url)
		strings.write_string(&b, sep)
		strings.write_string(&b, "post_logout_redirect_uri=")
		strings.write_string(&b, form_encode(strings.concatenate({strings.trim_right(service.web.ui_origin, "/"), "/"}, context.temp_allocator)))
		if id_token != "" {
			strings.write_string(&b, "&id_token_hint=")
			strings.write_string(&b, id_token)
		}
		return strings.to_string(b)
	}
	return "/"
}

// session_cookie_header builds the Set-Cookie value for a new session.
session_cookie_header :: proc(raw_session: string, max_age_seconds: i64) -> string {
	return fmt.tprintf("%s=%s; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d", SESSION_COOKIE, raw_session, max_age_seconds)
}

login_cookie_header :: proc(sealed: string) -> string {
	return fmt.tprintf("%s=%s; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d", LOGIN_COOKIE, sealed, LOGIN_STATE_TTL_MS / 1000)
}

expired_cookie_header :: proc(name: string) -> string {
	return fmt.tprintf("%s=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0", name)
}

// purge_expired_auth_rows drops expired sessions, login states and v2 nonces.
purge_expired_auth_rows :: proc(service: ^Auth_Service) -> (int, domain.Domain_Error) {
	if service == nil || service.sessions == nil do return 0, {}
	now, ok := now_unix_ms(service)
	if !ok do return 0, domain.domain_error(.Internal_Error, "clock unavailable")
	repo := service.sessions
	return repo.purge_expired(repo.ctx, now)
}
