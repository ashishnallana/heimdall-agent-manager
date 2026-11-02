package mcp

// The envelope itself is a client-held bearer credential. NEVER persist it or
// its plaintext. Durable records contain only its hash and public bindings.
// This format is separate from vault content, device keys and U0 random probes.
import "core:crypto"
import "core:crypto/aes"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

CREDENTIAL_PREFIX :: "mcp1."
CREDENTIAL_DOMAIN :: "heimdall-mcp-credential-v1|"
RETRY_DOMAIN :: "heimdall-mcp-refresh-retry-v1"
CREDENTIAL_MAX :: 32768

// Envelope key ids allow explicit prior-key support during key rotation. Key
// material is injected by the deployment, never generated on process startup.
Envelope_Key :: struct {
	id: string,
	bytes: [32]byte,
}

// All strings are validated against the durable grant again before use. A
// successfully opened envelope alone never authorizes a business-service call.
Credential_Claims :: struct {
	kind, issuer, owner, vault_id, client, resource, scope: string,
	grant, family, recipient, jti: string,
	revision, issued_ms, expires_ms: i64,
	redirect, challenge: string,
	// Hex P-256 ECDH scalar for a newly created delegated recipient only.
	// Empty for device-routed mode. Never a device signing key or vault root.
	private_capability: string,
}

envelope_key_id_ok :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > 32 do return false
	for c in id do if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') do return false
	return true
}

credential_kind_ok :: proc(kind: string) -> bool {
	return kind == "code" || kind == "access" || kind == "refresh"
}

// The returned string uses the request allocator. The caller wipes it as soon
// as the response has been sent; request arenas are not a zeroization guarantee.
credential_seal :: proc(key: ^Envelope_Key, claims: Credential_Claims, random_source := os_random.DEFAULT_SOURCE) -> (string, bool) {
	if key == nil || !envelope_key_id_ok(key.id) || !credential_kind_ok(claims.kind) do return "", false
	plain, err := json.marshal(claims, allocator = context.temp_allocator)
	if err != nil do return "", false
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	aad := strings.concatenate({CREDENTIAL_DOMAIN, key.id}, context.temp_allocator)
	body, ok := credential_aead_seal(key.bytes[:], transmute([]byte)aad, plain, random_source)
	if !ok do return "", false
	return strings.concatenate({CREDENTIAL_PREFIX, key.id, ".", body}, context.temp_allocator), true
}

// Does not enforce expiry: authenticated consumed refresh credentials must still
// be recognized after their retry window to detect family-local replay. The
// service validates kind, issuer, expiry and every durable binding separately.
credential_open :: proc(keys: []Envelope_Key, raw, expected_kind: string) -> (Credential_Claims, bool) {
	if len(raw) > CREDENTIAL_MAX || !strings.has_prefix(raw, CREDENTIAL_PREFIX) || !credential_kind_ok(expected_kind) do return {}, false
	rest := raw[len(CREDENTIAL_PREFIX):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 || !envelope_key_id_ok(rest[:dot]) do return {}, false
	for &key in keys {
		if key.id != rest[:dot] do continue
		aad := strings.concatenate({CREDENTIAL_DOMAIN, key.id}, context.temp_allocator)
		plain, ok := credential_aead_open(key.bytes[:], transmute([]byte)aad, rest[dot+1:])
		if !ok do return {}, false
		defer crypto.zero_explicit(raw_data(plain), len(plain))
		claims: Credential_Claims
		// Use the request allocator for decoded string fields too. The caller is
		// responsible for wiping the private field before releasing the request.
		if json.unmarshal(plain, &claims, .JSON, context.temp_allocator) != nil || claims.kind != expected_kind {
			credential_claims_wipe(&claims)
			return {}, false
		}
		return claims, true
	}
	return {}, false
}

credential_aead_seal :: proc(key, aad, plain: []byte, random_source := os_random.DEFAULT_SOURCE) -> (string, bool) {
	if len(key) != 32 || len(plain) > CREDENTIAL_MAX/2 do return "", false
	payload := make([]byte, 28+len(plain), context.temp_allocator)
	defer crypto.zero_explicit(raw_data(payload), len(payload))
	if !os_random.fill(payload[:12], random_source) do return "", false
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, payload[28:], payload[12:28], payload[:12], aad, plain)
	encoded, err := base64.encode(payload, allocator = context.temp_allocator)
	return encoded, err == nil
}

credential_aead_open :: proc(key, aad: []byte, encoded: string) -> ([]byte, bool) {
	if len(key) != 32 || len(encoded) > CREDENTIAL_MAX do return nil, false
	payload, ok := vault.b64_decode_strict(encoded, context.temp_allocator)
	if !ok || len(payload) < 28 do return nil, false
	defer crypto.zero_explicit(raw_data(payload), len(payload))
	plain := make([]byte, len(payload)-28, context.temp_allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	if !aes.open_gcm(&gcm, plain, payload[:12], aad, payload[28:], payload[12:28]) {
		crypto.zero_explicit(raw_data(plain), len(plain))
		return nil, false
	}
	return plain, true
}

// All fields are public durable metadata. Fixed-order JSON is the unambiguous
// AAD encoding, including strings that contain URL delimiters or Unicode.
Retry_Binding :: struct {
	owner, client, resource, grant, family, parent_hash, child_hash: string,
	revision, deadline_ms: i64,
}

retry_key :: proc(raw_parent: string, salt: []byte, dst: []byte) -> bool {
	// A stored SHA256 hex digest (64 characters) must never be accepted here.
	if !strings.has_prefix(raw_parent, CREDENTIAL_PREFIX) || len(raw_parent) > CREDENTIAL_MAX || len(salt) != 32 || len(dst) != 32 do return false
	hkdf.extract_and_expand(.SHA256, salt, transmute([]byte)raw_parent, transmute([]byte)string(RETRY_DOMAIN), dst)
	return true
}

// The only persisted encrypted copy of a token response is this bounded capsule.
// It has NO wrapping under the deployment key: the raw parent credential must be
// presented to derive its key. Parent/child hashes and deadline are authenticated.
retry_seal :: proc(raw_parent: string, binding: Retry_Binding, response: []byte, random_source := os_random.DEFAULT_SOURCE) -> (string, bool) {
	salt: [32]byte
	if !os_random.fill(salt[:], random_source) do return "", false
	key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !retry_key(raw_parent, salt[:], key[:]) do return "", false
	aad, err := json.marshal(binding, allocator = context.temp_allocator)
	if err != nil do return "", false
	body, ok := credential_aead_seal(key[:], aad, response, random_source)
	if !ok do return "", false
	hex := vault.hex_encode_lower(salt[:], context.temp_allocator)
	return strings.concatenate({hex, ".", body}, context.temp_allocator), true
}

retry_open :: proc(raw_parent: string, binding: Retry_Binding, capsule: string) -> ([]byte, bool) {
	if len(capsule) < 66 || len(capsule) > CREDENTIAL_MAX || capsule[64] != '.' do return nil, false
	salt, key: [32]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if !vault.hex_decode_into(salt[:], capsule[:64]) || !retry_key(raw_parent, salt[:], key[:]) do return nil, false
	aad, err := json.marshal(binding, allocator = context.temp_allocator)
	if err != nil do return nil, false
	return credential_aead_open(key[:], aad, capsule[65:])
}

credential_claims_wipe :: proc(c: ^Credential_Claims) {
	if c == nil do return
	if c.private_capability != "" do crypto.zero_explicit(raw_data(c.private_capability), len(c.private_capability))
	c.private_capability = ""
}
