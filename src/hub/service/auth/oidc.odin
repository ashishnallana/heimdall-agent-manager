package auth

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:math/big"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import users "odin_test:hub/service/user"
import http_client "odin_test:lib/http_client"
import vault "odin_test:lib/vault"

// Bearer validation settings, all from Hub configuration (no provider is
// hard-coded). `audience` is the API audience a native access token must carry
// and `scope` the API scope it must grant; both are mandatory.
OIDC_Config :: struct {
	issuer, audience, scope, userinfo_url, jwks_url: string,
	// Opt-in: let an unlinked subject claim the existing user whose name equals
	// its preferred_username. Off by default; operators link with
	// `ham-hub users link-oidc` instead.
	claim_existing_users: bool,
	// Injectable transport for deterministic tests; production always uses TLS.
	fetch:                                    proc(
		ctx: rawptr,
		url, token: string,
	) -> (
		string,
		bool,
	),
	fetch_ctx:                                rawptr,
}
OIDC_Identity :: struct {
	sub, preferred_username, name, email: string,
}
OIDC_Cache_Entry :: struct {
	identity: OIDC_Identity,
	until_ms: i64,
	expires_ms: i64, // token exp + leeway: bounds long-lived streams
}
OIDC_State :: struct {
	mutex:   sync.Mutex,
	entries: map[string]OIDC_Cache_Entry,
	// Parsed JWKS shared by every request. Signatures are verified against it
	// BEFORE any network call, so forged tokens never reach the provider.
	jwks_mutex:        sync.Mutex,
	jwks_keys:         []OIDC_JWK, // heap-owned
	jwks_fetched_ms:   i64, // 0: never fetched successfully
	jwks_attempt_ms:   i64, // last refresh attempt (success or failure)
	jwks_attempted:    bool,
	jwks_refreshing:   bool, // single-flight: concurrent misses never wait or refetch
	// Outbound provider requests in flight (JWKS + UserInfo). Excess fails fast.
	inflight:          int,
}
OIDC_CACHE_LIMIT :: 1024
// A fresh JWKS is refreshed after this age (when a refresh is allowed). Stale
// keys stay usable while a refresh is suppressed or failing, up to the hard age.
OIDC_JWKS_TTL_MS :: 10 * 60_000
OIDC_JWKS_MAX_AGE_MS :: 60 * 60_000
// At most one JWKS refresh attempt per window, whatever triggers it (TTL or an
// unknown `kid`). A suppressed refresh rejects without any network call.
OIDC_JWKS_REFRESH_INTERVAL_MS :: 60_000
OIDC_MAX_INFLIGHT_FETCHES :: 8
// Clock leeway for exp / nbf / iat.
OIDC_CLOCK_LEEWAY_SECONDS :: 60

oidc_failure :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Unauthenticated, "invalid OIDC access token")
}

oidc_log_rejected :: proc(stage: string) {
	fmt.printfln("ham-hub oidc_rejected stage=%s", stage)
}

oidc_http_get :: proc(url, token: string) -> (string, bool) {
	if !strings.has_prefix(url, "https://") do return "", false
	fmt.printfln("ham-hub oidc_http_request method=GET target=%s authorization=%t", url, token != "")
	headers := make([dynamic]http_client.Header, context.temp_allocator)
	if token != "" do append(&headers, http_client.Header{"Authorization", strings.concatenate({"Bearer ", token}, context.temp_allocator)})
	request_path := "/" if strings.has_suffix(url, "/") else ""
	res, ok := http_client.request_with_headers_timeout(
		"GET",
		url,
		request_path,
		"",
		headers[:],
		5000,
		omit_default_port = true,
	)
	if !ok {
		fmt.printfln("ham-hub oidc_http_rejected reason=request_failed")
		return "", false
	}
	fmt.printfln("ham-hub oidc_http_response status=%d bytes=%d", res.status, len(res.body))
	if res.status != 200 {
		fmt.printfln("ham-hub oidc_http_rejected reason=http_status status=%d", res.status)
		return "", false
	}
	if len(res.body) > 1_048_576 {
		fmt.printfln("ham-hub oidc_http_rejected reason=body_too_large")
		return "", false
	}
	return res.body, true
}
// oidc_fetch bounds concurrent outbound provider requests: past the limit it
// fails closed immediately instead of queueing behind a slow provider.
oidc_fetch :: proc(config: OIDC_Config, state: ^OIDC_State, url, token: string) -> (string, bool) {
	if sync.atomic_add(&state.inflight, 1) >= OIDC_MAX_INFLIGHT_FETCHES {
		sync.atomic_sub(&state.inflight, 1)
		fmt.printfln("ham-hub oidc_http_rejected reason=too_many_inflight")
		return "", false
	}
	defer sync.atomic_sub(&state.inflight, 1)
	if config.fetch != nil do return config.fetch(config.fetch_ctx, url, token)
	return oidc_http_get(url, token)
}
// Strict unpadded base64url: rejects alternate spellings and nonzero pad bits.
oidc_decode :: proc(s: string) -> ([]byte, bool) {
	if len(s) == 0 || len(s) % 4 == 1 do return nil, false
	out := make([dynamic]byte, 0, len(s) * 3 / 4 + 1, context.temp_allocator)
	acc: u32; bits: uint
	for c in transmute([]byte)s {
		v: u32
		switch c {
		case 'A' ..= 'Z':
			v = u32(c - 'A')
		case 'a' ..= 'z':
			v = u32(c - 'a') + 26
		case '0' ..= '9':
			v = u32(c - '0') + 52
		case '-':
			v = 62
		case '_':
			v = 63
		case:
			return nil, false
		}
		acc = (acc << 6) | v; bits += 6
		if bits >= 8 {bits -= 8; append(&out, byte(acc >> bits)); acc &= (1 << bits) - 1}
	}
	if acc != 0 do return nil, false
	return out[:], true
}
// RFC 8017 RSASSA-PKCS1-v1_5 verification with the SHA-256 DigestInfo.
// Only public-key arithmetic runs here; every byte of the encoded message is checked.
oidc_rs256_verify :: proc(n64, e64: string, message, signature: []byte) -> bool {
	n, nok := oidc_decode(n64); e, eok := oidc_decode(e64)
	if !nok || !eok || len(n) < 256 || len(n) > 512 || n[0] < 128 || n[len(n) - 1] & 1 == 0 || len(e) > 4 || len(signature) != len(n) do return false
	exponent: u64
	for b in e do exponent = (exponent << 8) | u64(b)
	if exponent < 3 || exponent & 1 == 0 do return false
	modulus, exp, sig, recovered: big.Int
	defer big.destroy(&modulus, &exp, &sig, &recovered)
	if big.int_from_bytes_big(&modulus, n) != nil || big.int_from_bytes_big(&exp, e) != nil || big.int_from_bytes_big(&sig, signature) != nil do return false
	comparison, compare_err := big.cmp(&sig, &modulus)
	if compare_err != nil || comparison >= 0 do return false
	if big.internal_int_power_modulo(&recovered, &sig, &exp, &modulus) != nil do return false
	encoded := make([]byte, len(n), context.temp_allocator)
	if big.int_to_bytes_big(&recovered, encoded) != nil do return false
	prefix := []byte {
		0x30,
		0x31,
		0x30,
		0x0d,
		0x06,
		0x09,
		0x60,
		0x86,
		0x48,
		0x01,
		0x65,
		0x03,
		0x04,
		0x02,
		0x01,
		0x05,
		0x00,
		0x04,
		0x20,
	}
	start := len(encoded) - len(prefix) - 32
	if start < 11 || encoded[0] != 0 || encoded[1] != 1 || encoded[start - 1] != 0 do return false
	for i in 2 ..< start - 1 {if encoded[i] != 255 do return false}
	for b, i in prefix {if encoded[start + i] != b do return false}
	digest: [32]byte; hash: sha2.Context_256
	sha2.init_256(&hash); sha2.update(&hash, message); sha2.final(&hash, digest[:])
	for b, i in digest {if encoded[len(encoded) - 32 + i] != b do return false}
	return true
}
OIDC_JWK :: struct {
	kty, kid, alg, use, n, e: string,
}
OIDC_JWKS :: struct {
	keys: []OIDC_JWK,
}
OIDC_JWT_Header :: struct {
	alg, kid: string,
	crit:     []string,
}
OIDC_Claims :: struct {
	iss, sub, scope: string,
	exp:             i64,
	nbf:             i64,
	iat:             i64,
	aud:             json.Value,
}
oidc_has_audience :: proc(v: json.Value, audience: string) -> bool {
	#partial switch a in v {
	case string:
		return a == audience
	case json.Array:
		for item in a {if value, ok := item.(string); ok && value == audience do return true}
	case:
		return false
	}
	return false
}
oidc_jwks_free :: proc(keys: []OIDC_JWK) {
	a := runtime.heap_allocator()
	for key in keys {
		delete(key.kty, a); delete(key.kid, a); delete(key.alg, a); delete(key.use, a); delete(key.n, a); delete(key.e, a)
	}
	delete(keys, a)
}

OIDC_Key_Lookup :: enum {
	Found,
	Unknown_Kid,
	Ambiguous, // more than one key with this kid
	Unavailable, // no usable key set
}

// oidc_jwks_lookup copies the single key for `kid` into the request's temp
// allocator, so a concurrent refresh can replace the shared set safely.
@(private = "file")
oidc_jwks_lookup :: proc(state: ^OIDC_State, kid: string, now_ms: i64) -> (OIDC_JWK, OIDC_Key_Lookup, bool) {
	sync.mutex_lock(&state.jwks_mutex)
	defer sync.mutex_unlock(&state.jwks_mutex)
	if state.jwks_fetched_ms == 0 || now_ms - state.jwks_fetched_ms >= OIDC_JWKS_MAX_AGE_MS do return {}, .Unavailable, true
	stale := now_ms - state.jwks_fetched_ms >= OIDC_JWKS_TTL_MS
	matches := 0
	found: OIDC_JWK
	for key in state.jwks_keys {
		if key.kid != kid do continue
		matches += 1
		found = key
	}
	if matches > 1 do return {}, .Ambiguous, stale
	if matches == 0 do return {}, .Unknown_Kid, stale
	t := context.temp_allocator
	return OIDC_JWK{strings.clone(found.kty, t), strings.clone(found.kid, t), strings.clone(found.alg, t), strings.clone(found.use, t), strings.clone(found.n, t), strings.clone(found.e, t)}, .Found, stale
}

// oidc_jwks_refresh performs at most one JWKS fetch per refresh window across
// all requests (single-flight). Returns false without any network call when a
// refresh is already in flight or was attempted within the window.
@(private = "file")
oidc_jwks_refresh :: proc(config: OIDC_Config, state: ^OIDC_State, now_ms: i64) -> bool {
	sync.mutex_lock(&state.jwks_mutex)
	if state.jwks_refreshing || (state.jwks_attempted && now_ms - state.jwks_attempt_ms < OIDC_JWKS_REFRESH_INTERVAL_MS) {
		sync.mutex_unlock(&state.jwks_mutex)
		return false
	}
	state.jwks_refreshing = true
	state.jwks_attempted = true
	state.jwks_attempt_ms = now_ms
	sync.mutex_unlock(&state.jwks_mutex)

	jwks_text, fetched := oidc_fetch(config, state, config.jwks_url, "")
	parsed: OIDC_JWKS
	ok := fetched && json.unmarshal_string(jwks_text, &parsed, .JSON, context.temp_allocator) == nil
	if !fetched do oidc_log_rejected("jwks_transport")
	else if !ok do oidc_log_rejected("jwks_decode")

	sync.mutex_lock(&state.jwks_mutex)
	defer sync.mutex_unlock(&state.jwks_mutex)
	state.jwks_refreshing = false
	if !ok do return false
	a := runtime.heap_allocator()
	keys := make([]OIDC_JWK, len(parsed.keys), a)
	for key, i in parsed.keys {
		keys[i] = OIDC_JWK{strings.clone(key.kty, a), strings.clone(key.kid, a), strings.clone(key.alg, a), strings.clone(key.use, a), strings.clone(key.n, a), strings.clone(key.e, a)}
	}
	oidc_jwks_free(state.jwks_keys)
	state.jwks_keys = keys
	state.jwks_fetched_ms = now_ms
	fmt.printfln("ham-hub oidc_jwks_refreshed keys=%d", len(keys))
	return true
}

// oidc_resolve_key returns the verification key for `kid`, refreshing the shared
// JWKS only when it is missing/stale or the kid is unknown, and only as often as
// the refresh window allows. A suppressed or failed refresh never retries inline.
@(private = "file")
oidc_resolve_key :: proc(config: OIDC_Config, state: ^OIDC_State, kid: string, now_ms: i64) -> (OIDC_JWK, string, bool) {
	key, lookup, stale := oidc_jwks_lookup(state, kid, now_ms)
	if lookup == .Ambiguous do return {}, "signature", false
	if lookup == .Found && !stale do return key, "", true
	refreshed := oidc_jwks_refresh(config, state, now_ms)
	if !refreshed {
		// Stale-but-present keys keep working while a refresh is suppressed/failing.
		if lookup == .Found do return key, "", true
		return {}, "jwks_unavailable" if lookup == .Unavailable else "unknown_kid", false
	}
	key, lookup, _ = oidc_jwks_lookup(state, kid, now_ms)
	if lookup != .Found do return {}, "signature", false
	return key, "", true
}

// oidc_jwt_verify_signature checks an RS256 JWS against the shared JWKS before any
// network call; only a missing/stale set or an unknown kid may trigger a
// (rate-limited, single-flight) JWKS fetch.
oidc_jwt_verify_signature :: proc(config: OIDC_Config, state: ^OIDC_State, token: string, parts: []string, kid: string, sig: []byte, now_ms: i64) -> (string, bool) {
	key, key_stage, key_ok := oidc_resolve_key(config, state, kid, now_ms)
	if !key_ok do return key_stage, false
	if key.kty != "RSA" || (key.alg != "" && key.alg != "RS256") || (key.use != "" && key.use != "sig") do return "signature", false
	message := token[:len(parts[0]) + 1 + len(parts[1])]
	if !oidc_rs256_verify(key.n, key.e, transmute([]byte)message, sig) do return "signature", false
	return "", true
}

OIDC_ID_Token_Claims :: struct {
	iss, sub, azp, nonce:            string,
	preferred_username, name, email: string,
	exp, nbf, iat:                   i64,
	aud:                             json.Value,
}

// oidc_validate_id_token validates an ID token from the authorization-code
// exchange: RS256 via the shared JWKS cache, `iss == issuer`, `aud` contains the
// web client id (with `azp == client id` when several audiences are present),
// exp/nbf/iat with leeway, and `nonce` equal to the login's nonce. The identity
// comes from the ID token's own claims (no UserInfo call).
oidc_validate_id_token :: proc(
	config: OIDC_Config,
	state: ^OIDC_State,
	client_id, expected_nonce, token: string,
	now_ms: i64,
) -> (
	OIDC_Identity,
	string,
	bool,
) {
	if config.issuer == "" || config.jwks_url == "" || client_id == "" || expected_nonce == "" do return {}, "config", false
	if len(token) > 32768 do return {}, "token_length", false
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 do return {}, "token_segments", false
	h, hok := oidc_decode(parts[0])
	c, cok := oidc_decode(parts[1])
	sig, sok := oidc_decode(parts[2])
	if !hok || !cok || !sok do return {}, "token_encoding", false
	header: OIDC_JWT_Header
	claims: OIDC_ID_Token_Claims
	if json.unmarshal(h, &header, .JSON, context.temp_allocator) != nil || json.unmarshal(c, &claims, .JSON, context.temp_allocator) != nil do return {}, "token_json", false
	if header.alg != "RS256" || header.kid == "" || len(header.crit) != 0 do return {}, "header", false
	now_s := now_ms / 1000
	if claims.iss != config.issuer || claims.sub == "" || claims.exp + OIDC_CLOCK_LEEWAY_SECONDS <= now_s || claims.exp > 9_000_000_000 || claims.nbf > now_s + OIDC_CLOCK_LEEWAY_SECONDS || claims.iat > now_s + OIDC_CLOCK_LEEWAY_SECONDS || claims.iat == 0 do return {}, "claims", false
	if !oidc_has_audience(claims.aud, client_id) do return {}, "audience", false
	if audiences, many := claims.aud.(json.Array); many && len(audiences) > 1 && claims.azp != client_id do return {}, "audience", false
	if claims.azp != "" && claims.azp != client_id do return {}, "audience", false
	if !oidc_constant_time_equal(claims.nonce, expected_nonce) do return {}, "nonce", false
	if sig_stage, sig_ok := oidc_jwt_verify_signature(config, state, token, parts, header.kid, sig, now_ms); !sig_ok do return {}, sig_stage, false
	return OIDC_Identity{sub = claims.sub, preferred_username = claims.preferred_username, name = claims.name, email = claims.email}, "", true
}

oidc_constant_time_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	diff: byte
	for i in 0 ..< len(a) do diff |= a[i] ~ b[i]
	return diff == 0
}

oidc_validate_token_with_stage :: proc(
	config: OIDC_Config,
	token: string,
	now_ms: i64,
	shared_state: ^OIDC_State = nil,
) -> (
	OIDC_Identity,
	i64,
	string,
	bool,
) {
	// Without shared state (tests, one-off checks) a private, empty JWKS cache is used.
	local_state: OIDC_State
	state := shared_state
	if state == nil do state = &local_state
	defer if shared_state == nil do oidc_jwks_free(local_state.jwks_keys)
	if config.issuer == "" || config.audience == "" || config.scope == "" || config.jwks_url == "" || config.userinfo_url == "" do return {}, 0, "config", false
	if len(token) > 32768 do return {}, 0, "token_length", false
	parts := strings.split(token, ".", context.temp_allocator)
	if len(parts) != 3 do return {}, 0, "token_segments", false
	h, hok := oidc_decode(
		parts[0],
	); c, cok := oidc_decode(parts[1]); sig, sok := oidc_decode(parts[2])
	if !hok || !cok || !sok do return {}, 0, "token_encoding", false
	header: OIDC_JWT_Header; claims: OIDC_Claims
	if json.unmarshal(h, &header, .JSON, context.temp_allocator) != nil || json.unmarshal(c, &claims, .JSON, context.temp_allocator) != nil do return {}, 0, "token_json", false
	now_s := now_ms / 1000
	if header.alg != "RS256" || header.kid == "" || len(header.crit) != 0 || claims.iss != config.issuer || claims.sub == "" || claims.exp + OIDC_CLOCK_LEEWAY_SECONDS <= now_s || claims.exp > 9_000_000_000 || claims.nbf > now_s + OIDC_CLOCK_LEEWAY_SECONDS || claims.iat > now_s + OIDC_CLOCK_LEEWAY_SECONDS || !oidc_has_audience(claims.aud, config.audience) do return {}, 0, "claims", false
	scope_ok := false
	for scope in strings.split(
		claims.scope,
		" ",
		context.temp_allocator,
	) {if scope == config.scope do scope_ok = true}
	if !scope_ok do return {}, 0, "scope", false
	if sig_stage, sig_ok := oidc_jwt_verify_signature(config, state, token, parts, header.kid, sig, now_ms); !sig_ok do return {}, 0, sig_stage, false
	// UserInfo only after the signature verifies.
	info_text, info_ok := oidc_fetch(config, state, config.userinfo_url, token)
	info: OIDC_Identity
	if !info_ok do return {}, 0, "userinfo_transport", false
	if json.unmarshal_string(info_text, &info, .JSON, context.temp_allocator) != nil do return {}, 0, "userinfo_decode", false
	if info.sub == "" do return {}, 0, "userinfo_subject_missing", false
	if info.sub != claims.sub do return {}, 0, "userinfo_subject_mismatch", false
	return info, (claims.exp + OIDC_CLOCK_LEEWAY_SECONDS) * 1000, "", true
}

oidc_validate_token :: proc(
	config: OIDC_Config,
	token: string,
	now_ms: i64,
	shared_state: ^OIDC_State = nil,
) -> (OIDC_Identity, i64, bool) {
	identity, expires, _, ok := oidc_validate_token_with_stage(config, token, now_ms, shared_state)
	return identity, expires, ok
}

oidc_free_entry :: proc(key: string, e: OIDC_Cache_Entry) {
	a := runtime.heap_allocator()
	delete(
		key,
		a,
	); delete(e.identity.sub, a); delete(e.identity.preferred_username, a); delete(e.identity.name, a); delete(e.identity.email, a)
}
oidc_clone_identity :: proc(
	identity: OIDC_Identity,
	allocator: runtime.Allocator,
) -> OIDC_Identity {
	return OIDC_Identity {
		strings.clone(identity.sub, allocator),
		strings.clone(identity.preferred_username, allocator),
		strings.clone(identity.name, allocator),
		strings.clone(identity.email, allocator),
	}
}
oidc_cache_get :: proc(state: ^OIDC_State, key: string, now: i64) -> (OIDC_Cache_Entry, bool) {
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	expired := make([dynamic]string, context.temp_allocator)
	for k, entry in state.entries {if now >= entry.until_ms do append(&expired, k)}
	for k in expired {
		stored_key, entry := delete_key(&state.entries, k)
		oidc_free_entry(stored_key, entry)
	}
	entry, found := state.entries[key]
	// Request-owned copies remain valid when a different request expires the cache.
	if found do entry.identity = oidc_clone_identity(entry.identity, context.temp_allocator)
	return entry, found
}
oidc_cache_put :: proc(state: ^OIDC_State, key: string, entry: OIDC_Cache_Entry) {
	sync.mutex_lock(&state.mutex)
	defer sync.mutex_unlock(&state.mutex)
	if state.entries == nil do state.entries = make(map[string]OIDC_Cache_Entry, runtime.heap_allocator())
	if _, exists := state.entries[key]; exists do return
	if len(state.entries) >= OIDC_CACHE_LIMIT do return
	a := runtime.heap_allocator()
	state.entries[strings.clone(key, a)] = OIDC_Cache_Entry {
		oidc_clone_identity(entry.identity, a),
		entry.until_ms,
		entry.expires_ms,
	}
}
oidc_free :: proc(service: ^Auth_Service) {
	sync.mutex_lock(&service.oidc_state.mutex)
	defer sync.mutex_unlock(&service.oidc_state.mutex)
	for k, e in service.oidc_state.entries do oidc_free_entry(k, e)
	delete(service.oidc_state.entries)
	service.oidc_state.entries = nil
	sync.mutex_lock(&service.oidc_state.jwks_mutex)
	defer sync.mutex_unlock(&service.oidc_state.jwks_mutex)
	oidc_jwks_free(service.oidc_state.jwks_keys)
	service.oidc_state.jwks_keys = nil
	service.oidc_state.jwks_fetched_ms = 0
}
resolve_oidc_auth :: proc(
	service: ^Auth_Service,
	req: Auth_Request,
) -> (
	contracts.Auth_Context,
	bool,
	domain.Domain_Error,
) {
	if service == nil || service.users == nil || service.users.users == nil || service.users.users.resolve_external == nil do return {}, false, oidc_failure()
	authz := header_value(req.headers, "Authorization")
	authorization_count := 0
	for header in req.headers {if strings.equal_fold(header.name, "Authorization") do authorization_count += 1}
	if authorization_count != 1 do return {}, false, oidc_failure()
	if !strings.has_prefix(authz, "Bearer ") || token_in_query_or_body(req.query, req.body) do return {}, false, oidc_failure()
	token := authz[len("Bearer "):]
	// No proxy assertion is ever used to authenticate an OIDC request.
	if strings.has_prefix(token, "hut_") || strings.contains_any(token, " \r\n\t") do return {}, false, oidc_failure()
	now, now_ok := platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
	if !now_ok do return {}, false, oidc_failure()
	hash: sha2.Context_256; digest: [32]byte
	sha2.init_256(&hash); sha2.update(&hash, transmute([]byte)token); sha2.final(&hash, digest[:])
	token_hash := vault.hex_encode_lower(digest[:], context.temp_allocator)
	entry, cached := oidc_cache_get(&service.oidc_state, token_hash, now)
	if !cached {
		identity, expires, rejected_stage, ok := oidc_validate_token_with_stage(service.oidc, token, now, &service.oidc_state)
		if !ok {
			oidc_log_rejected(rejected_stage)
			return {}, false, oidc_failure()
		}
		after_fetch, clock_ok := platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
		if !clock_ok || after_fetch >= expires {
			oidc_log_rejected("expired_after_fetch")
			return {}, false, oidc_failure()
		}
		entry = OIDC_Cache_Entry {
			identity = identity,
			until_ms = min(now + 30_000, expires),
			expires_ms = expires,
		}
		oidc_cache_put(&service.oidc_state, token_hash, entry)
	}
	user, ok, err := oidc_resolve_identity(service, entry.identity)
	if !ok do return {}, false, err
	users.ensure_canonical_resources(service.users, user.user_id)
	return contracts.Auth_Context {
		kind = .OIDC,
		user_id = string(user.user_id),
		name = user.name,
		display_name = user.display_name,
		email = user.email,
		expires_ms = entry.expires_ms,
	}, true, {}
}

// oidc_resolve_identity maps a validated OIDC identity (bearer or ID token) to a
// Hub user under the configured link/claim/provision policy.
oidc_resolve_identity :: proc(service: ^Auth_Service, identity: OIDC_Identity) -> (domain.User, bool, domain.Domain_Error) {
	if service == nil || service.users == nil || service.users.users == nil || service.users.users.resolve_external == nil do return {}, false, oidc_failure()
	username := strings.trim_space(identity.preferred_username)
	// Refuse lossy normalization which could silently claim another username.
	normalized := users.normalize_user_id(username)
	if username != "" && (normalized == "" || !strings.equal_fold(username, normalized)) do normalized = ""
	repo := service.users.users
	user, ok, err := repo.resolve_external(
		repo.ctx,
		service.oidc.issuer,
		identity.sub,
		normalized,
		identity.name,
		identity.email,
		platform.clock_now(service.clock),
		service.config.auto_provision_users,
		service.oidc.claim_existing_users,
	)
	if !ok {
		oidc_log_rejected("identity_resolution")
		return {}, false, err
	}
	return user, true, {}
}
