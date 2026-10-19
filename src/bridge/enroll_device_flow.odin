// Bridge-side browser-approval enrollment: the RFC 8628 device grant with PKCE
// and a short, manually entered user code (REQ-IMPL-4, REQ-ENROLL-2/3/4/10).
//
// WHAT THE OPERATOR TYPES, AND WHY THAT IS THE WHOLE INPUT:
//
//	ham-bridge enroll --hub https://hub.mundus.in
//
// One hostname. No enrollment token and no client-side UI hostname guess. The
// bridge talks to `--hub`; the Hub's authorize response supplies the browser
// origin in its RFC-aligned `verification_uri` field.
//
// ===== THE THREE PROPERTIES THIS FILE EXISTS TO HOLD =====
//
//  1. THE APPROVAL URL CARRIES NO PER-REQUEST DATA. It is safe to type, bookmark,
//     or open on another device. The operator types the secret PAIRING CODE printed
//     here (hub-blind pairing, plan §1 "Pairing"): the hub only ever sees a lookup and
//     a MAC derived from it. The approving browser checks that MAC over this
//     process's identity + ECDH keys (so a substituting Hub is caught without any
//     fingerprint comparison), and the first unseal must carry the approver's
//     pair_mac under the same code before this bridge pins the account root.
//
//  2. POLLING IS THE ONLY COMPLETION CHANNEL. The bridge redeems approval over
//     its server-authenticated Hub connection with the device_code and PKCE
//     verifier. There is no loopback listener or browser-to-bridge callback.
//
//  3. THE ECDH KEY IS ENCRYPTION-ONLY AND EPHEMERAL. bridge_unseal_init's P-256
//     keypair agrees the vault keyring and does nothing else, and it is NOT
//     persisted: ephemerality is what makes every archived approval link and every
//     captured unseal ciphertext permanently undecryptable after a restart
//     (§5.4.6). The durable identity is a SECOND, separate ECDSA key
//     (unseal_protocol.odin): generated here, sent as bridge_identity_public_key,
//     persisted under the bridge id once it exists, and used only to sign each
//     boot's ephemeral key.
package main

import os_random "odin_test:lib/os_random"
import "core:crypto"
import "core:crypto/hash"
import base64 "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:encoding/json"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"
import vault "odin_test:lib/vault"

// ===== Endpoints, all derived from the one UI origin (REQ-ENROLL-10) =====
//
// These are the routes that EXIST (see the hub's route table): settled 1 reused
// the existing device grant rather than standing up the `/api/v1/bridge-device/*`
// family design §9.3 names, so the design's paths are stale and these are not.
BRIDGE_ENROLL_AUTHORIZE_PATH :: "/api/v1/device/authorize"
BRIDGE_ENROLL_TOKEN_PATH :: "/api/v1/device/token"
// Path-form entry to the approval page. The Hub 302s it to the UI hash route
// `/#/device/add[?code=…]` (GET /api/v1/device/add). A path, not the hash route
// itself, because a forward-auth login round trip (`rd=<url>`) keeps path and
// query but drops the `#` fragment, so a hash link landed on Home after login.
// The UI uses the Hub's stored bridge key only after the operator confirms its
// fingerprint against this terminal.
BRIDGE_ENROLL_PAGE_PATH :: "/api/v1/device/add"
BRIDGE_ENROLL_REFRESH_PATH :: "/api/v1/device/bridge-refresh"

// 32 bytes for the PKCE verifier (RFC 7636 §4.1 permits 43-128 chars; 32 raw
// bytes is 43 base64url chars, the minimum, and 256 bits of entropy).
BRIDGE_ENROLL_SECRET_BYTES :: 32

// Hard ceiling on the ceremony, independent of what the Hub reports, so a Hub
// that returns a nonsense `expires_in` cannot park the process forever.
BRIDGE_ENROLL_MAX_WAIT_SECONDS :: 900
BRIDGE_ENROLL_DEFAULT_INTERVAL_SECONDS :: 5
BRIDGE_ENROLL_VAULT_WAIT_SECONDS :: 45

// ===== Proactive refresh (design §7.5) =====
//
// REFRESH AT 80% OF THE ACCESS TOKEN'S LIFETIME, NOT ON A 401. A 401 means the
// credential is already dead: in-flight work has failed by the time it arrives.
// 80% of an hour leaves a twelve-minute margin for a transient network failure
// and several backoff retries before anything breaks.
//
// THE JITTER IS NOT COSMETIC. Without it a fleet enrolled by one script refreshes
// in lockstep forever, turning a routine renewal into a synchronised stampede
// against one endpoint — and, worse, into a synchronised fleet-wide outage if that
// endpoint is briefly down. +/-5% of an hour spreads a thousand bridges over six
// minutes.
BRIDGE_REFRESH_AT_PERCENT :: 80
BRIDGE_REFRESH_JITTER_PERCENT :: 5
BRIDGE_REFRESH_MIN_DELAY_SECONDS :: 30
// Transport backoff, replacing the flat retry design §7.5 calls out: a revoked or
// unreachable fleet retrying twice a second is a self-inflicted DoS.
BRIDGE_REFRESH_BACKOFF_START_SECONDS :: 5
BRIDGE_REFRESH_BACKOFF_MAX_SECONDS :: 300

// bridge_refresh_backoff_seconds is the shared bridge backoff (retry_policy.odin)
// on the refresh schedule: 5s, 10s, 20s, ... capped at 300s, no jitter.
bridge_refresh_backoff_seconds :: proc(failures: int) -> int {
	policy := Bridge_Backoff_Policy{base_ms = BRIDGE_REFRESH_BACKOFF_START_SECONDS * 1000, max_ms = BRIDGE_REFRESH_BACKOFF_MAX_SECONDS * 1000}
	return int(bridge_backoff_delay_ms(policy, failures) / 1000)
}

// Bridge_Machine_Descriptor is what the approval screen renders (REQ-IMPL-5) and
// what the Hub stores as the bridge's `machine_hostname` / `machine_os` /
// `os_user` / version.
//
// EVERY FIELD IS HOST-ASSERTED AND THEREFORE ATTACKER-CONTROLLED. The Hub labels
// it as such on the wire (`host_asserted` in the verify payload) and the approval
// page must render it as a claim, never as fact. This struct's job is only to
// make the claim TRUE for an honest bridge — which it previously was not: the
// enroll body shipped a literal `"hostname":"ham-bridge"`, so every machine in a
// fleet presented the operator with the same constant and there was nothing to
// recognise or refuse. REQ-IMPL-5's screen is pointless without this.
Bridge_Machine_Descriptor :: struct {
	hostname:       string,
	os:             string,
	os_version:     string,
	arch:           string,
	os_user:        string,
	bridge_version: string,
}

// Bridge_Enroll_Credential is what an approved poll or a refresh hands back.
// expires_in / refresh_expires_in are DURATIONS IN SECONDS, never timestamps:
// REQ-IMPL-3 chose durations precisely so a headless box with a wrong clock still
// refreshes correctly, and the bridge honours that by scheduling off a monotonic
// timer and never comparing its wall clock against a Hub value.
Bridge_Enroll_Credential :: struct {
	approver_username: string,
	// The approving account (hub-reported). Pinned with the identity key as this
	// bridge's enrolled owner: only that user's keyring is ever accepted.
	owner_user_id:      string,
	bridge_id:          string,
	access_token:       string,
	refresh_token:      string,
	expires_in:         int,
	refresh_expires_in: int,
	vault_delivery_expected: bool,
	// REQ-EA-4: the hub holds this credential PENDING until the vault key is
	// delivered; see enroll_atomic.odin. False from a hub that predates it.
	enrollment_pending: bool,
}

// ===== Base64url: used for PKCE =====
//
// ONE ENCODING CARRIES THE PUBLIC KEY EVERYWHERE: the 130-char lowercase hex that
// `bridge_get_public_key_hex` emits. It is what the Hub validates `bridge_public_key`
// as, and what the UI's unseal path already parses — `prepareUnsealPayload` tests
// `/^[0-9a-fA-F]{130}$/` FIRST and only falls back to standard base64
// (`src/ui/utils/vaultBridgeUnseal.ts`), so a hex fragment takes the hex branch and
// passes its strict `length !== 65 || [0] !== 0x04` guard unchanged.
//
// Design §5.4.2 specified base64url of the 65 raw bytes for the fragment (~43 chars
// shorter) and the coordinator OVERRODE it. Do not restore that: base64url matches
// NEITHER the UI's hex branch nor its standard-base64 fallback (`-`/`_` vs `+`/`/`),
// so it would fall through, decode to garbage and fail on length — at the VAULT
// UNLOCK, after enrollment had already reported success. Hex is URL-safe, needs no
// percent-encoding in a fragment, and the fingerprint is computed over the decoded
// bytes either way, so both encodings agree on every comparison.
//
// base64url is the encoding for the PKCE verifier/challenge (RFC 7636 §4.2).
//
// Compressed points were evaluated and rejected (§5.4.2): the UI hard-rejects
// anything but 65 bytes and WebCrypto's `raw` import IS the uncompressed format.
bridge_base64url_unpadded :: proc(data: []byte, allocator := context.allocator) -> string {
	padded, _ := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	trimmed := strings.trim_right(padded, "=")
	if len(trimmed) == len(padded) do return padded
	out := strings.clone(trimmed, allocator)
	delete(padded, allocator)
	return out
}

// bridge_enroll_entropy fills dst from the OS CSPRNG (/dev/urandom; BCryptGenRandom
// on Windows) and FAILS CLOSED.
//
// It goes through os_random, with an explicit ok, rather than calling
// crypto.rand_bytes, for one reason: this is the call that must be PROVABLY
// unable to degrade. The PKCE verifier is the secret the redemption proof rests
// on, and a silent fallback to anything weaker is the exact
// failure class settled 7 and 8 exist to forbid on the Hub side. A short read is
// a failure, not a partial success.
bridge_enroll_entropy :: proc(dst: []byte) -> bool {
	if len(dst) == 0 do return false
	if !os_random.fill(dst) {
		fmt.eprintln("enroll: the OS secure random source is unavailable or returned short; refusing to generate a weaker secret")
		return false
	}
	return true
}

// bridge_enroll_random_token returns BRIDGE_ENROLL_SECRET_BYTES of entropy as
// unpadded base64url — the PKCE verifier charset (RFC 7636 §4.1) and a fine
// `state` nonce.
bridge_enroll_random_token :: proc(allocator := context.allocator) -> (string, bool) {
	raw: [BRIDGE_ENROLL_SECRET_BYTES]byte
	if !bridge_enroll_entropy(raw[:]) do return "", false
	return bridge_base64url_unpadded(raw[:], allocator), true
}

// bridge_pkce_challenge derives the S256 challenge: BASE64URL(SHA256(verifier)),
// unpadded (RFC 7636 §4.2). `plain` is never produced and the Hub rejects it.
bridge_pkce_challenge :: proc(verifier: string, allocator := context.allocator) -> string {
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, verifier, digest[:])
	return bridge_base64url_unpadded(digest[:], allocator)
}

// bridge_enroll_fingerprint mirrors the Hub's derivation exactly — SHA-256 over
// the DECODED 65-byte point, truncated to the leading 64 bits, four space-
// separated hex quads. The bridge computes its own copy from its own key and
// prints it; the page shows the Hub's. A human comparing them is what makes a key
// substitution visible on the no-fragment path (design §2.2 step 5, §5.4.4).
//
// Hashing the decoded point rather than its hex text is what lets the bridge
// and the browser arrive at the same fingerprint from the same hex.
bridge_enroll_fingerprint :: proc(public_key_hex: string, allocator := context.allocator) -> (string, bool) {
	if len(public_key_hex) != P256_POINT_SIZE * 2 do return "", false
	raw, ok := hex.decode(transmute([]byte)(public_key_hex), context.temp_allocator)
	if !ok || len(raw) != P256_POINT_SIZE do return "", false
	if raw[0] != P256_UNCOMPRESSED_PREFIX do return "", false
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, raw, digest[:])
	HEX_DIGITS :: "0123456789abcdef"
	digits := HEX_DIGITS
	out := strings.builder_make(allocator)
	for i in 0 ..< 8 {
		if i > 0 && i % 2 == 0 do strings.write_byte(&out, ' ')
		b := digest[i]
		strings.write_byte(&out, digits[b >> 4 & 0x0f])
		strings.write_byte(&out, digits[b & 0x0f])
	}
	return strings.to_string(out), true
}

// bridge_enroll_hub_url normalises and validates the single `--hub` input: an
// http:// or https:// base URL, any host and port, with an optional path prefix (a
// hub behind a reverse proxy), never a query or fragment, no trailing slash in the
// result. Reusing bridge_hub_url_supported's rules keeps one definition of "a base
// URL this bridge will talk to"; the http client resolves every API path under the
// prefix.
bridge_enroll_hub_url :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	trimmed := strings.trim_right(strings.trim_space(raw), "/")
	if !bridge_hub_url_supported(trimmed) do return "", false
	return strings.clone(trimmed, allocator), true
}

// bridge_enroll_approval_url composes the stable page the operator may open on
// any signed-in device. It intentionally contains no user code or cryptographic
// material; the terminal prints those separately for manual entry/comparison.
bridge_enroll_approval_url :: proc(ui_origin: string, allocator := context.allocator) -> string {
	return strings.concatenate({ui_origin, BRIDGE_ENROLL_PAGE_PATH}, allocator)
}

// ===== The machine descriptor =====

// bridge_enroll_hostname resolves the real hostname, in order: gethostname(2),
// then /proc/sys/kernel/hostname, then $HOSTNAME. Returns "" when all three fail
// — and the caller REFUSES TO ENROLL rather than substituting a constant, which
// is the defect this replaces.
bridge_enroll_hostname :: proc(allocator := context.allocator) -> string {
	if name := bridge_os_hostname(allocator); name != "" do return name
	if data, err := os.read_entire_file("/proc/sys/kernel/hostname", context.temp_allocator); err == nil {
		name := strings.trim_space(string(data))
		if name != "" do return strings.clone(name, allocator)
	}
	if env, found := os.lookup_env("HOSTNAME", context.temp_allocator); found {
		name := strings.trim_space(env)
		if name != "" do return strings.clone(name, allocator)
	}
	return ""
}

// bridge_enroll_os_user resolves the OS user from the passwd database for the
// real uid, falling back to $USER then $LOGNAME. getpwuid is tried FIRST because
// the environment is operator-settable and this value is shown to a human who is
// about to grant the account access.
bridge_enroll_os_user :: proc(allocator := context.allocator) -> string {
	if name := bridge_os_user_name(allocator); name != "" do return name
	for key in ([?]string{"USER", "LOGNAME"}) {
		if env, found := os.lookup_env(key, context.temp_allocator); found {
			name := strings.trim_space(env)
			if name != "" do return strings.clone(name, allocator)
		}
	}
	return ""
}

// bridge_enroll_machine_descriptor gathers the real values. `os`/`arch` come from
// the compile-time targets (they describe the binary that will run, which is what
// the operator is approving); `os_version` comes from uname(2).
bridge_enroll_machine_descriptor :: proc(allocator := context.allocator) -> Bridge_Machine_Descriptor {
	d := Bridge_Machine_Descriptor{
		hostname       = bridge_enroll_hostname(allocator),
		os             = strings.clone(fmt.tprintf("%v", ODIN_OS), allocator),
		arch           = strings.clone(fmt.tprintf("%v", ODIN_ARCH), allocator),
		os_user        = bridge_enroll_os_user(allocator),
		bridge_version = strings.clone(contracts.APP_VERSION, allocator),
	}
	d.os_version = bridge_os_release(allocator)
	if d.os_version == "" do d.os_version = strings.clone("", allocator)
	return d
}

// bridge_enroll_descriptor_usable rejects a descriptor that would reproduce the
// defect: an empty hostname, or the old hardcoded literal. Enrollment fails loudly
// instead of presenting the operator with a value that identifies nothing.
bridge_enroll_descriptor_usable :: proc(d: Bridge_Machine_Descriptor) -> bool {
	host := strings.trim_space(d.hostname)
	if host == "" do return false
	if host == "ham-bridge" do return false
	return true
}

// Bridge_Authorize_Request is the /device/authorize body (typed; json.marshal).
//
// `device_label` IS the hostname: the Hub maps the grant's device_label straight
// into the bridge row's `machine_hostname` and initial label, so this field is
// where the real hostname has to land. `bridge_key_fingerprint` is deliberately
// NOT sent — the Hub computes its own from the key and rejects a disagreeing body
// value (settled 9), so sending one buys nothing and invites a 400.
Bridge_Authorize_Request :: struct {
	client:                     string,
	device_label:               string,
	os:                         string,
	app_version:                string,
	os_user:                    string,
	bridge_public_key:          string,
	bridge_identity_public_key: string `json:"bridge_identity_public_key,omitempty"`,
	bridge_identity_proof:      Maybe(vault.Signature_Wire) `json:"bridge_identity_proof,omitempty"`,
	code_challenge:             string,
	code_challenge_method:      string,
	// Hub-blind pairing: derived from the pairing code this process prints.
	pair_lookup:                string `json:"pair_lookup,omitempty"`,
	pair_key_mac:               string `json:"pair_key_mac,omitempty"`,
	// Public salt of the pairing stretch (vault.Pair_Context), random per enrollment.
	pair_salt:                  string `json:"pair_salt,omitempty"`,
}

// bridge_enroll_authorize_body builds the /device/authorize request body.
bridge_enroll_authorize_body :: proc(
	d: Bridge_Machine_Descriptor,
	public_key_hex, code_challenge: string,
	identity_public_key_hex: string = "",
	identity_proof_json: string = "",
	pair_lookup: string = "",
	pair_key_mac: string = "",
	pair_salt: string = "",
	allocator := context.allocator,
) -> string {
	body := Bridge_Authorize_Request{
		client = "ham-bridge", device_label = d.hostname, os = bridge_enroll_os_display(d),
		app_version = d.bridge_version, os_user = d.os_user, bridge_public_key = public_key_hex,
		bridge_identity_public_key = identity_public_key_hex,
		code_challenge = code_challenge, code_challenge_method = "S256",
		pair_lookup = pair_lookup, pair_key_mac = pair_key_mac, pair_salt = pair_salt,
	}
	if identity_proof_json != "" {
		if sw, ok := vault.signature_wire_from_text(identity_proof_json, context.temp_allocator); ok do body.bridge_identity_proof = sw
	}
	data, err := json.marshal(body, allocator = allocator)
	if err != nil do return ""
	return string(data)
}

// Bridge_Authorize_Response is the API envelope of a /device/authorize answer.
Bridge_Authorize_Response :: struct {
	data: struct {
		device_code:            string,
		verification_uri:       string,
		interval:               int,
		expires_in:             int,
		bridge_key_fingerprint: string,
	},
}
// bridge_enroll_os_display renders "linux 6.18.49 amd64" for the approval screen,
// omitting whichever parts are unknown rather than printing empty separators.
bridge_enroll_os_display :: proc(d: Bridge_Machine_Descriptor, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, 0, 3, allocator)
	if strings.trim_space(d.os) != "" do append(&parts, d.os)
	if strings.trim_space(d.os_version) != "" do append(&parts, d.os_version)
	if strings.trim_space(d.arch) != "" do append(&parts, d.arch)
	return strings.join(parts[:], " ", allocator)
}

// Enrollment completion uses Hub polling only; there is no browser callback.

Bridge_Enroll_Poll_Status :: enum {
	Pending,
	Approved,
	Denied,
	Expired,
	Slow_Down,
	// Fatal covers a rejection that retrying cannot fix — a PKCE failure (401), or
	// a response the bridge cannot parse. It is kept DISTINCT from Pending on
	// purpose: the Hub answers an unknown device_code with `pending` for anti-
	// enumeration reasons, so "keep polling" must never be the fallback for an
	// authentication failure or the bridge would spin until expiry on a hard error.
	Fatal,
}

// bridge_enroll_poll_once performs one POST /device/token.
//
// THE VERIFIER IS REVEALED ONLY HERE, over TLS, directly to the Hub (RFC 7636
// §4.5). Up to this point only its SHA-256 has been on the wire, which is what
// makes a device_code scraped from a log, a proxy or a shoulder-surf unredeemable
// by anyone but the process that started the flow (design §3.6).
bridge_enroll_poll_once :: proc(
	api_base, device_code, code_verifier: string,
	allocator := context.allocator,
) -> (Bridge_Enroll_Poll_Status, Bridge_Enroll_Credential, int) {
	body, body_ok := vault.wire_encode(Bridge_Token_Request{device_code = device_code, code_verifier = code_verifier}, context.temp_allocator)
	if !body_ok do return .Fatal, Bridge_Enroll_Credential{}, 0
	resp, ok := http.request_with_headers_timeout(
		"POST", api_base, BRIDGE_ENROLL_TOKEN_PATH, body, nil, http.DEFAULT_TIMEOUT_MS)
	if !ok {
		// Transport failure is NOT fatal and NOT pending-forever: the caller treats
		// it as a retryable tick, because a flapping tunnel during a 15-minute
		// ceremony is ordinary.
		return .Pending, Bridge_Enroll_Credential{}, 0
	}
	if resp.status == 429 {
		return .Slow_Down, Bridge_Enroll_Credential{}, bridge_token_response_decode(resp.body).interval
	}
	if resp.status == 401 {
		fmt.eprintln("enroll FAILED: the Hub rejected this bridge's PKCE proof (401). The device code cannot be redeemed by this process.")
		blog_error(.enroll_failed, blog_sym(.stage, .token), blog_int(.hub_status, 401))
		return .Fatal, Bridge_Enroll_Credential{}, 0
	}
	if resp.status != 200 {
		fmt.eprintfln("enroll: unexpected HTTP %d from the token endpoint — %s", resp.status, resp.body)
		blog_error(.enroll_failed, blog_sym(.stage, .token), blog_int(.hub_status, i64(resp.status)))
		return .Fatal, Bridge_Enroll_Credential{}, 0
	}
	switch bridge_token_response_decode(resp.body).status {
	case "approved":
		return .Approved, bridge_enroll_credential_from_json(resp.body, allocator), 0
	case "denied":
		return .Denied, Bridge_Enroll_Credential{}, 0
	case "expired":
		return .Expired, Bridge_Enroll_Credential{}, 0
	case "slow_down":
		return .Slow_Down, Bridge_Enroll_Credential{}, 0
	case "pending":
		return .Pending, Bridge_Enroll_Credential{}, 0
	}
	fmt.eprintfln("enroll: unrecognised poll status in the Hub's response — %s", resp.body)
	return .Fatal, Bridge_Enroll_Credential{}, 0
}

// Bridge_Token_Request is the /device/token body (typed; json.marshal).
Bridge_Token_Request :: struct {
	device_code:   string,
	code_verifier: string,
}

// Bridge_Token_Data is a /device/token or /device/refresh answer: the poll status
// and, once approved, the credential. Absent members decode as zero values.
Bridge_Token_Data :: struct {
	status:                  string,
	interval:                int,
	approver_username:       string,
	owner_user_id:           string,
	bridge_id:               string,
	access_token:            string,
	refresh_token:           string,
	expires_in:              int,
	refresh_expires_in:      int,
	vault_delivery_expected: bool,
	enrollment_pending:      bool,
}

// bridge_token_response_decode reads a token answer inside the API envelope
// ({"data":{...}}) or bare. Anything that does not decode is the zero value, which
// callers treat as unrecognised / unusable. Temp-allocated.
bridge_token_response_decode :: proc(body: string) -> Bridge_Token_Data {
	envelope: struct {
		data: Maybe(Bridge_Token_Data),
	}
	if vault.wire_decode(body, &envelope) {
		if data, has := envelope.data.?; has do return data
	}
	flat: Bridge_Token_Data
	if !vault.wire_decode(body, &flat) do return {}
	return flat
}

bridge_enroll_credential_from_json :: proc(body: string, allocator := context.allocator) -> Bridge_Enroll_Credential {
	d := bridge_token_response_decode(body)
	return Bridge_Enroll_Credential{
		approver_username = strings.clone(d.approver_username, allocator),
		owner_user_id      = strings.clone(d.owner_user_id, allocator),
		bridge_id          = strings.clone(d.bridge_id, allocator),
		access_token       = strings.clone(d.access_token, allocator),
		refresh_token      = strings.clone(d.refresh_token, allocator),
		expires_in         = d.expires_in,
		refresh_expires_in = d.refresh_expires_in,
		vault_delivery_expected = d.vault_delivery_expected,
		enrollment_pending = d.enrollment_pending,
	}
}

// bridge_enroll_credential_usable is the client-side half of audit finding F4.
//
// F4 is that an EMPTY bridge token makes the loopback authorizer return true for
// every caller, and an enrolling bridge is empty by definition. The fix at this
// layer is to make it impossible to FINISH enrollment holding nothing: a
// credential must carry a prefix this bridge recognises, a `.` separator, and a
// non-empty id AND a non-empty secret — the same four rejections the Hub's
// split_credential performs, applied before anything is written to disk or handed
// to the runtime. A bridge that cannot satisfy this exits non-zero with its old
// state untouched, rather than persisting a blank that silently authorises
// everything.
bridge_enroll_credential_usable :: proc(token: string) -> bool {
	trimmed := strings.trim_space(token)
	if trimmed == "" do return false
	prefix_ok := false
	for p in ([?]string{"hba_", "hbr_", "hbf_"}) {
		if strings.has_prefix(trimmed, p) do prefix_ok = true
	}
	if !prefix_ok do return false
	dot := strings.index_byte(trimmed, '.')
	if dot <= 0 do return false
	// The id half must be more than the bare prefix, and the secret half must exist.
	id_half := trimmed[:dot]
	secret_half := trimmed[dot + 1:]
	if len(id_half) <= len("hba_") do return false
	if strings.trim_space(secret_half) == "" do return false
	return true
}

// ===== At-rest storage (design §7.6, audit F2) =====

// bridge_enroll_refresh_file_for places the refresh token BESIDE the access token
// rather than in it. Two files, not one: a refresh rotation rewrites only its own
// file, so a crash mid-rotation cannot truncate the access token the running
// bridge is still using.
bridge_enroll_refresh_file_for :: proc(access_path: string, allocator := context.allocator) -> string {
	return strings.concatenate({strings.trim_space(access_path), ".refresh"}, allocator)
}

// bridge_write_secret_file writes a credential at 0600, ATOMICALLY.
//
// Atomic because a refresh rewrites this file while the bridge is running: a
// truncated token after a power cut would strand the machine exactly as surely as
// a lost one. Write to a sibling temp file, chmod it BEFORE the rename (so the
// file is never briefly readable at the umask's default), then rename over the
// target — rename within a directory is atomic, so a reader sees the old content
// or the new one and never a partial line.
//
// The parent directory is created 0700: a 0600 file inside a 0755 directory still
// leaks its existence and name to every local user.
//
// DO NOT "UPGRADE" THIS TO THE KERNEL KEYRING. Design §7.6 prefers the keyring and
// this deliberately does not follow it, because `KEY_SPEC_USER_KEYRING` (`@u`) does
// NOT survive a reboot: a keyring-only store would turn every reboot into a
// re-enrollment, contradicting this task's "reconnects across a restart"
// requirement. It also buys little against the threat that matters, since `@u` is
// readable by any process of the same user (§3.2). A keyring copy may be added
// ALONGSIDE these files; it must never replace them.
bridge_write_secret_file :: proc(path, value: string) -> bool {
	target := strings.trim_space(path)
	if target == "" do return false
	if strings.trim_space(value) == "" {
		// Refuse to write a blank credential. See bridge_enroll_credential_usable:
		// a blank is the F4 failure, and "the write succeeded" would be a lie that
		// strands the operator with an authorise-everything loopback.
		fmt.eprintln("refusing to write an empty credential to", target)
		return false
	}
	if slash := strings.last_index_byte(target, '/'); slash > 0 {
		dir := target[:slash]
		_ = bridge_make_directory_all(dir)
		_ = os.chmod(dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	}
	tmp := strings.concatenate({target, ".tmp"}, context.temp_allocator)
	content := strings.concatenate({strings.trim_space(value), "\n"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, transmute([]byte)content, os.Permissions{.Read_User, .Write_User}); err != nil {
		fmt.eprintln("failed to write credential file", tmp)
		blog_error(.token_persist_failed, blog_sym(.stage, .write))
		return false
	}
	if chmod_err := os.chmod(tmp, os.Permissions{.Read_User, .Write_User}); chmod_err != nil {
		_ = os.remove(tmp)
		fmt.eprintln("failed to restrict credential file mode", tmp)
		blog_error(.token_persist_failed, blog_sym(.stage, .chmod))
		return false
	}
	if rename_err := os.rename(tmp, target); rename_err != nil {
		_ = os.remove(tmp)
		fmt.eprintln("failed to install credential file", target)
		blog_error(.token_persist_failed, blog_sym(.stage, .rename))
		return false
	}
	return true
}

// bridge_enroll_persist writes the credential pair and updates config.toml with
// the NON-SECRET half only.
//
// THE CREDENTIAL IS NEVER WRITTEN TO config.toml — that is audit F2, closed by
// removing the path rather than patching it. config.toml is operator-edited,
// copied between machines, pasted into issues and frequently committed to version
// control; a long-lived credential in it is a credential in all of those places.
// The old enroll path wrote `[daemon] bridge_token` whenever no token file was
// given. This path has no such branch: it passes an empty token to
// bridge_write_enrolled_config, which writes only daemon_url and daemon_id.
bridge_enroll_persist :: proc(cred: Bridge_Enroll_Credential, access_path, config_path, hub_url: string) -> bool {
	if !bridge_enroll_credential_usable(cred.access_token) {
		fmt.eprintln("enroll FAILED: the Hub returned an access token this bridge will not accept (empty, unprefixed, or missing its secret half); nothing was written")
		return false
	}
	if !bridge_write_credential_file(access_path, hub_url, cred.bridge_id, cred.access_token) do return false
	if strings.trim_space(cred.refresh_token) != "" {
		if !bridge_enroll_credential_usable(cred.refresh_token) {
			fmt.eprintln("enroll FAILED: the Hub returned a malformed refresh token; nothing further was written")
			return false
		}
		refresh_path := bridge_enroll_refresh_file_for(access_path, context.temp_allocator)
		if !bridge_write_secret_file(refresh_path, cred.refresh_token) do return false
	}
	if strings.trim_space(config_path) != "" {
		// Empty token argument on purpose — see the header above.
		if !bridge_write_enrolled_config(config_path, hub_url, "", cred.bridge_id) {
			fmt.eprintln("warning: credentials were saved, but config.toml could not be updated; pass --hub/--bridge-token-file when starting ham-bridge")
			blog_warn(.config_write_failed, blog_sym(.stage, .config))
		}
	}
	return true
}

// ===== Proactive refresh (design §7.4-7.5) =====

// bridge_refresh_delay_seconds returns how long to wait before refreshing an
// access token that lives `expires_in` seconds: BRIDGE_REFRESH_AT_PERCENT of the
// lifetime, offset by up to +/-BRIDGE_REFRESH_JITTER_PERCENT, derived from one
// entropy byte.
//
// Pure and parameterised by the jitter byte so a test can pin the band exactly
// rather than sampling a random one and hoping.
//
// `expires_in <= 0` returns 0, which the caller reads as "this credential does not
// expire, schedule nothing" — the shape a pre-REQ-IMPL-3 `hbr_` bridge is in. It
// must not be confused with "refresh immediately".
bridge_refresh_delay_seconds :: proc(expires_in: int, jitter_byte: u8) -> int {
	if expires_in <= 0 do return 0
	base := expires_in * BRIDGE_REFRESH_AT_PERCENT / 100
	span := expires_in * BRIDGE_REFRESH_JITTER_PERCENT / 100
	offset := 0
	if span > 0 do offset = (int(jitter_byte) * 2 * span) / 255 - span
	delay := base + offset
	if delay < BRIDGE_REFRESH_MIN_DELAY_SECONDS do delay = BRIDGE_REFRESH_MIN_DELAY_SECONDS
	// Never schedule past expiry: on an absurdly short lifetime the floor above
	// could otherwise land after the token is already dead.
	if delay > expires_in do delay = expires_in
	return delay
}

Bridge_Refresh_Outcome :: enum {
	Rotated,
	// Retryable: the Hub could not be reached, or answered something transient.
	// Back off and try again — the access token is still valid for a while, which
	// is the entire point of refreshing at 80%.
	Retry,
	// Revoked: the Hub returned 401 invalid_grant. Expired, unknown, already-used
	// and revoked are ONE error by design (§7.4), because the correct response to
	// all four is identical: stop, wipe, require re-enrollment, DO NOT LOOP.
	Revoked,
}

// bridge_credential_refresh_once exchanges the refresh token for a new pair.
//
// The refresh token is the AUTHENTICATION, in the Authorization header. It is
// never put in the query string or the body — the Hub rejects that outright, and a
// credential in a URL lands in every access log and proxy cache on the path.
bridge_credential_refresh_once :: proc(
	api_base, refresh_token: string,
	allocator := context.allocator,
) -> (Bridge_Enroll_Credential, Bridge_Refresh_Outcome) {
	headers := [?]http.Header{
		{name = "Authorization", value = strings.concatenate({"Bearer ", refresh_token}, context.temp_allocator)},
	}
	resp, ok := http.request_with_headers_timeout(
		"POST", api_base, BRIDGE_ENROLL_REFRESH_PATH, "{}", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return Bridge_Enroll_Credential{}, .Retry
	if resp.status == 401 do return Bridge_Enroll_Credential{}, .Revoked
	if resp.status != 200 do return Bridge_Enroll_Credential{}, .Retry
	cred := bridge_enroll_credential_from_json(resp.body, allocator)
	if !bridge_enroll_credential_usable(cred.access_token) do return Bridge_Enroll_Credential{}, .Retry
	return cred, .Rotated
}

// g_bridge_credential_file is where the running bridge's access token lives, so
// the refresh worker can rewrite it. Empty means "started from --bridge-token or
// config.toml with no file": there is then nowhere durable to put a rotated
// credential, so the worker declines to rotate rather than rotating into memory
// only and stranding the bridge at the next restart.
g_bridge_credential_file: string
g_bridge_credential_mu: sync.Mutex

// bridge_credential_refresh_start schedules proactive refresh for a bridge whose
// credential expires. Called at startup, after the config is resolved.
//
// It returns immediately and does nothing at all unless BOTH a refresh token and a
// credential file path are present — an `hbr_`-era bridge (non-expiring, no
// refresh half) is left exactly as it was, which is what keeps REQ-IMPL-6's
// not-yet-deleted legacy path working.
bridge_credential_refresh_start :: proc(credential_file: string) {
	path := strings.trim_space(credential_file)
	if path == "" do return
	refresh_path := bridge_enroll_refresh_file_for(path)
	refresh_token, has_refresh := bridge_read_token_file(refresh_path)
	if !has_refresh do return
	if !bridge_enroll_credential_usable(refresh_token) {
		fmt.println("bridge credential refresh disabled: the stored refresh token is malformed; re-enrollment is required")
		return
	}
	g_bridge_credential_file = strings.clone(path)
	thread.run(bridge_credential_refresh_worker)
}

// bridge_credential_refresh_worker is the renewal loop.
//
// It schedules off time.sleep of a computed DURATION and never compares a Hub
// timestamp against the local wall clock, because REQ-IMPL-3 deliberately returns
// durations so a box with bad time still renews correctly.
bridge_credential_refresh_worker :: proc() {
	failures := 0
	// The first delay uses the access token's own remaining lifetime, which the
	// bridge does not know across a restart — so it refreshes once promptly and
	// then settles onto the 80% schedule from the Hub's reported durations. A
	// restart is rare; an unnecessary rotation is cheap and self-correcting.
	delay := BRIDGE_REFRESH_MIN_DELAY_SECONDS
	for {
		time.sleep(time.Duration(delay) * time.Second)
		api_base := bridge_config.daemon_url
		refresh_path := bridge_enroll_refresh_file_for(g_bridge_credential_file, context.temp_allocator)
		stored, has_stored := bridge_read_token_file(refresh_path)
		if !has_stored {
			fmt.println("bridge credential refresh: no refresh token on disk; stopping (re-enrollment required)")
			return
		}
		cred, outcome := bridge_credential_refresh_once(api_base, stored)
		switch outcome {
		case .Rotated:
			// Write the NEW refresh token before adopting the new access token: if the
			// process dies between the two, the next start reads a refresh token the
			// Hub still honours. The reverse order can leave a bridge holding an
			// access token whose refresh half is the spent generation, which
			// REQ-IMPL-3 treats as theft and answers by revoking the whole family.
			if strings.trim_space(cred.refresh_token) != "" {
				if !bridge_write_secret_file(refresh_path, cred.refresh_token) {
					fmt.println("bridge credential refresh: could not persist the rotated refresh token; retrying")
					failures += 1
					delay = bridge_refresh_backoff_seconds(failures)
					continue
				}
			}
			if !bridge_write_credential_file(g_bridge_credential_file, api_base, strings.trim_space(bridge_config.daemon_id), cred.access_token) {
				fmt.println("bridge credential refresh: could not persist the rotated access token; retrying")
				failures += 1
				delay = bridge_refresh_backoff_seconds(failures)
				continue
			}
			// The WS worker re-reads bridge_config.bridge_token on every reconnect, so
			// updating it here is enough for the next reconnect to present the fresh
			// credential. The live socket keeps running on the old one until it drops,
			// which is correct: the Hub accepted it when it was presented.
			sync.mutex_lock(&g_bridge_credential_mu)
			bridge_config.bridge_token = strings.clone(strings.trim_space(cred.access_token))
			sync.mutex_unlock(&g_bridge_credential_mu)
			failures = 0
			jitter: [1]byte
			if !bridge_enroll_entropy(jitter[:]) do jitter[0] = 128
			delay = bridge_refresh_delay_seconds(cred.expires_in, jitter[0])
			if delay <= 0 do return // non-expiring credential: nothing left to schedule
			fmt.printfln("bridge credential refreshed; next refresh in %ds", delay)
		case .Revoked:
			// DO NOT LOOP. Wipe both halves so nothing retries with a dead credential
			// and so a stolen copy on this disk stops being useful, say so loudly, and
			// stop. Re-enrollment is a human at a browser, by design.
			_ = os.remove(refresh_path)
			_ = os.remove(g_bridge_credential_file)
			sync.mutex_lock(&g_bridge_credential_mu)
			bridge_config.bridge_token = ""
			sync.mutex_unlock(&g_bridge_credential_mu)
			fmt.eprintln("bridge credential REVOKED by the hub (invalid_grant): both tokens were wiped. RE-ENROLLMENT REQUIRED — run: ham-bridge enroll --hub <url>")
			blog_error(.hub_rejected, blog_sym(.stage, .token), blog_sym(.reason, .revoked))
			return
		case .Retry:
			failures += 1
			delay = bridge_refresh_backoff_seconds(failures)
			fmt.printfln("bridge credential refresh failed (transport or transient); retrying in %ds", delay)
		}
	}
}

// bridge_enroll_run_browser_opener passes the URL as an argv element, never
// through a shell. Besides avoiding quoting/injection problems, this lets the
// operator copy the already-printed stable URL if no desktop opener is present.
bridge_enroll_run_browser_opener :: proc(opener, url: string) -> bool {
	process, start_err := os.process_start(os.Process_Desc{command = []string{opener, url}})
	if start_err != nil do return false
	// Desktop openers normally exit immediately, but some xdg-open backends wait
	// for the browser process. Enrollment must never wait for the browser to
	// close before it starts polling, so give the launcher a short head start and
	// then reap it. A browser it already spawned remains independent.
	state, _ := os.process_wait(process, 1 * time.Second)
	if state.exited do return state.success
	_ = os.process_kill(process)
	_, _ = os.process_wait(process)
	return true
}

// Try the platform's conventional opener first, then the other common name.
// A missing command or a desktop-session failure is deliberately non-fatal:
// enrollment keeps polling and the terminal still shows the phone-friendly URL.
bridge_enroll_try_open_approval_url :: proc(url: string) -> bool {
	when ODIN_OS == .Darwin {
		if bridge_enroll_run_browser_opener("open", url) do return true
		return bridge_enroll_run_browser_opener("xdg-open", url)
	} else when ODIN_OS == .Windows {
		// rundll32 hands the URL to the default browser and exits at once.
		process, start_err := os.process_start(os.Process_Desc{command = []string{"rundll32", "url.dll,FileProtocolHandler", url}})
		if start_err != nil do return false
		_, _ = os.process_wait(process, 1 * time.Second)
		return true
	} else {
		if bridge_enroll_run_browser_opener("xdg-open", url) do return true
		return bridge_enroll_run_browser_opener("open", url)
	}
}

// BRIDGE_ENROLL_RUNIT_SERVICE is the termux-services (runit) service name; its
// run directory is $PREFIX/var/service/ham-bridge.
BRIDGE_ENROLL_RUNIT_SERVICE :: "ham-bridge"

// bridge_enroll_runit_service_dir: Termux has no systemd, so a bridge there is
// supervised by termux-services. Returns the service directory (temp-allocated)
// when it exists; `sv` takes it as an absolute path, so the restart does not
// depend on SVDIR, which only Termux login shells export.
bridge_enroll_runit_service_dir :: proc() -> (dir: string, ok: bool) {
	prefix, found := os.lookup_env("PREFIX", context.temp_allocator)
	if !found || prefix == "" do return "", false
	dir = strings.concatenate({prefix, "/var/service/", BRIDGE_ENROLL_RUNIT_SERVICE}, context.temp_allocator)
	if !os.is_dir(dir) do return "", false
	return dir, true
}

// bridge_enroll_restart_argv is the command that restarts the registered service
// (temp-allocated), or nil where none is supported. runit_dir is non-empty only
// for a Termux runit service.
bridge_enroll_restart_argv :: proc(runit_dir: string) -> []string {
	when ODIN_OS == .Linux {
		if runit_dir != "" {
			argv := make([]string, 3, context.temp_allocator)
			argv[0], argv[1], argv[2] = "sv", "restart", runit_dir
			return argv
		}
		argv := make([]string, 4, context.temp_allocator)
		argv[0], argv[1], argv[2], argv[3] = "systemctl", "--user", "restart", "heimdall-bridge"
		return argv
	} else when ODIN_OS == .Darwin {
		argv := make([]string, 4, context.temp_allocator)
		argv[0], argv[1], argv[2] = "launchctl", "kickstart", "-k"
		argv[3] = fmt.tprintf("gui/%d/works.earendil.heimdall-bridge", bridge_os_uid())
		return argv
	} else {
		return nil
	}
}

// bridge_enroll_start_command is the command line that starts this bridge with the
// credential enrollment just wrote: this executable plus the --config and
// --bridge-token-file the enroll was given (temp-allocated).
bridge_enroll_start_command :: proc(args: []string) -> string {
	exe := os.args[0] if len(os.args) > 0 else "ham-bridge"
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, bridge_enroll_shell_quote(exe))
	for flag in ([?]string{"--config", "--bridge-token-file"}) {
		if v := strings.trim_space(option_value(args, flag, "")); v != "" {
			append(&parts, flag, bridge_enroll_shell_quote(v))
		}
	}
	return strings.join(parts[:], " ", context.temp_allocator)
}

// bridge_enroll_shell_quote double-quotes a printed argument that contains a space
// (display only; nothing is executed from it).
bridge_enroll_shell_quote :: proc(s: string) -> string {
	if !strings.contains_any(s, " \t") do return s
	return strings.concatenate({"\"", s, "\""}, context.temp_allocator)
}

// bridge_enroll_restart_service hands the persisted credential to the already
// registered service. It invokes no shell. Where no service manager is supported
// (Windows) enrollment is still complete: it prints the command that starts the
// bridge and reports ok with restarted=false.
bridge_enroll_restart_service :: proc(args: []string) -> (ok: bool, restarted: bool) {
	runit_dir, _ := bridge_enroll_runit_service_dir() // "" unless the service dir exists
	argv := bridge_enroll_restart_argv(runit_dir)
	if argv == nil {
		fmt.println("  no registered bridge service is restarted automatically on this platform; start the bridge with:")
		fmt.printfln("    %s", bridge_enroll_start_command(args))
		return true, false
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = argv}, context.allocator)
	defer if len(stdout) > 0 do delete(stdout)
	defer if len(stderr) > 0 do delete(stderr)
	if err != nil || !state.success {
		fmt.eprintln("bridge enroll: enrollment SUCCEEDED and the credential (and the delivered vault key) are saved, but the registered service could not be restarted.")
		fmt.eprintfln("  command: %s (exit %d, err %v)", strings.join(argv, " ", context.temp_allocator), state.exit_code, err)
		if out := strings.trim_space(string(stdout)); out != "" do fmt.eprintfln("  stdout: %s", out)
		if se := strings.trim_space(string(stderr)); se != "" do fmt.eprintfln("  stderr: %s", se)
		fmt.eprintfln("  Start it manually with: %s — then check its log; the vault key stays persisted, no re-enrollment needed.", strings.join(argv, " ", context.temp_allocator))
		bridge_enroll_service_start_failed = true
		return false, false
	}
	return true, true
}

// Set when enrollment itself completed (credential and, if delivered, the
// vault key are persisted) and only the service restart failed. main maps it
// to exit code 3 so an installer can distinguish "enrolled, service down" from
// "not enrolled" instead of telling the operator to re-enroll.
bridge_enroll_service_start_failed: bool

// bridge_enroll_vault_key_persisted reports whether a restarted bridge would find
// bridge_id's vault key in the OS store. Under Termux the key is also cached in
// this process's memory, so the check unwraps the sealed FILE through the
// Keystore and bypasses that cache.
bridge_enroll_vault_key_persisted :: proc(bridge_id: string) -> bool {
	kr, persisted := keystore_read_persisted_vault_keyring(bridge_id)
	vault.keyring_wipe(&kr)
	if !persisted do return false
	// The restarted service must also find the identity that signs its unseal key.
	rec: Bridge_Identity_Record
	defer mem.zero_explicit(&rec, size_of(rec))
	return keystore_read_identity(bridge_id, &rec) == .Found
}

// Bring up only the Hub WebSocket, not either bridge-local listener. This can
// coexist with the idle service while the browser relays the encrypted key to
// the ephemeral enrollment keypair held by this process.
bridge_enroll_wait_for_vault_delivery :: proc(args: []string, bridge_id: string) -> bool {
	bridge_enrollment_unseal_reset()
	// REQ-T2-3: this process exits right after the restart below, so it must not be
	// the one that tells the hub the vault is unlocked. See bridge_hub_vault_status_for_report.
	bridge_hub_set_enroll_only_runtime(true)
	bridge_config = bridge_config_from_args(args)
	if strings.trim_space(bridge_config.bridge_token) == "" || bridge_config.daemon_id != bridge_id {
		fmt.eprintln("bridge enroll FAILED: the saved credential could not be loaded for vault delivery")
		return false
	}
	bridge_runtime_init()
	bridge_hub_runtime_start()
	fmt.printfln("  waiting up to %ds for encrypted vault delivery…", BRIDGE_ENROLL_VAULT_WAIT_SECONDS)
	for _ in 0..<BRIDGE_ENROLL_VAULT_WAIT_SECONDS * 10 {
		if bridge_enrollment_unseal_was_received() {
			// The restarted service is a NEW process: it is unsealed only if it can
			// read the key back from the OS store, so prove that before restarting.
			when ODIN_OS == .Linux || ODIN_OS == .Darwin {
				if !bridge_enroll_vault_key_persisted(bridge_id) {
					when ODIN_OS == .Linux {
						if keystore_android_selected() {
							fmt.eprintln("bridge enroll FAILED: the vault key was decrypted but could not be sealed with the Android Keystore (termux-keystore).")
						} else {
							fmt.eprintln("bridge enroll FAILED: the vault key was decrypted but could not be persisted in the Linux user keyring.")
						}
					} else {
						fmt.eprintln("bridge enroll FAILED: the vault key was decrypted but could not be persisted in the macOS login keychain.")
					}
					fmt.eprintln("  The service was not restarted because it would start locked.")
					return false
				}
			}
			return true
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.eprintln("bridge enroll FAILED: enrolled, but the vault key was not delivered before the handoff deadline.")
	fmt.eprintln("  Unlock the bridge later from Settings → User Vault, then start the registered service.")
	return false
}

// bridge_enroll_print_account_fingerprint shows the account root this bridge pinned at
// its first unseal (plan §1 "Bridge keyring authentication"). The pin was verified with
// the pairing code (the approver's pair_mac); the fingerprint is printed for reference.
bridge_enroll_print_account_fingerprint :: proc(bridge_id: string) {
	fp := bridge_account_fingerprint(bridge_id)
	if fp == "" {
		fmt.println("  account         (no account root pinned yet)")
		return
	}
	fmt.printfln("  account         fingerprint %s", fp)
	fmt.println("                  (verified with the pairing code; Settings → Devices shows the same value)")
}

// ===== The command: `ham-bridge enroll --hub <origin>` =====

// bridge_enroll_device_command runs the whole ceremony. Steps are numbered to the
// design's §2.2 so the two can be read side by side.
bridge_enroll_device_command :: proc(args: []string) -> bool {
	// REQ-EA-4: resolve a previous enrollment a crash left staged before starting anew.
	_ = bridge_enroll_atomic_recover(args)
	// Step 0 — the single input.
	// Exactly the hub given on the command line: never a default, an environment
	// value or an existing config's hub.
	hub_raw := option_value(args, "--hub", "")
	api_base, origin_ok := bridge_enroll_hub_url(hub_raw)
	if !origin_ok {
		fmt.eprintln("ham-bridge enroll --hub requires the Hub API base URL, e.g. --hub https://hub.mundus.in or --hub http://10.0.0.5:8080/heimdall (no query or fragment)")
		return false
	}
	// Bind this process's vault state to that hub (multi-bridge isolation): every
	// keystore item it writes is scoped to (hub, bridge id).
	if !bridge_keystore_set_hub(api_base) {
		fmt.eprintfln("ham-bridge enroll: %s is not a usable hub URL", api_base)
		return false
	}
	// A config that already belongs to an enrolled bridge of another hub is never
	// repointed: that would break the other bridge.
	if other, conflict := bridge_enroll_config_conflict(cfg_lib.config_path_from_args(args), api_base); conflict {
		fmt.eprintfln("ham-bridge enroll REFUSED: config %s belongs to a bridge enrolled with %s.", cfg_lib.config_path_from_args(args), other)
		fmt.eprintln("  To run a second bridge for another hub on this machine, give it its own --config and --bridge-token-file.")
		return false
	}
	// Nor is a credential file of another hub or bridge overwritten: the other bridge
	// would then present this bridge's token to its own hub. The default path is per
	// bridge; only an explicit --bridge-token-file / HAM_BRIDGE_TOKEN_FILE can collide.
	replacing_bridge_id := bridge_enroll_config_bridge_id(cfg_lib.config_path_from_args(args))
	if explicit_token_file := bridge_enroll_token_file_from_args(args, "", "", context.temp_allocator); explicit_token_file != "" {
		if reason, conflict := bridge_enroll_token_file_conflict(explicit_token_file, api_base, replacing_bridge_id); conflict {
			fmt.eprintfln("ham-bridge enroll REFUSED: credential file %s is not this bridge's: %s.", explicit_token_file, reason)
			fmt.eprintln("  Give this bridge its own --bridge-token-file, or omit it (the default credential path is per bridge).")
			return false
		}
	}

	// Step 2a — the machine descriptor. Gathered BEFORE anything is sent, because
	// an unusable one aborts the ceremony rather than enrolling a machine the
	// approving human cannot identify.
	descriptor := bridge_enroll_machine_descriptor()
	if !bridge_enroll_descriptor_usable(descriptor) {
		fmt.eprintln("ham-bridge enroll: could not determine this machine's hostname (tried gethostname, /proc/sys/kernel/hostname, $HOSTNAME).")
		fmt.eprintln("  Refusing to enroll with a placeholder: the approval screen would then identify nothing, and every machine would look alike.")
		return false
	}

	// Step 2b — the ephemeral ECDH key. Encryption only, never persisted (§5.4.6).
	bridge_unseal_init()
	public_key_hex := bridge_get_public_key_hex()
	if public_key_hex == "" {
		fmt.eprintln("ham-bridge enroll: the OS random source failed; cannot create this bridge's keys")
		return false
	}
	// Step 2b' — the persistent identity key, generated now and persisted under the
	// bridge id once the hub assigns one. Fail closed on entropy.
	identity_hex, identity_ok := bridge_unseal_identity_generate_for_enrollment()
	if !identity_ok {
		fmt.eprintln("ham-bridge enroll: the OS random source failed; cannot create this bridge's identity key")
		return false
	}
	fingerprint, fp_ok := bridge_enroll_fingerprint(public_key_hex, context.temp_allocator)
	if !fp_ok {
		fmt.eprintln("ham-bridge enroll: this bridge's ephemeral ECDH key is not a well-formed uncompressed P-256 point; cannot continue")
		return false
	}

	// Step 2c — PKCE, fail-closed on entropy.
	code_verifier, verifier_ok := bridge_enroll_random_token()
	if !verifier_ok do return false
	code_challenge := bridge_pkce_challenge(code_verifier)
	// Proof that this host holds the identity key, bound to this ECDH key and challenge.
	identity_proof, proof_ok := bridge_unseal_identity_enrollment_proof(public_key_hex, code_challenge)
	if !proof_ok {
		fmt.eprintln("ham-bridge enroll: could not sign the identity proof of possession; cannot continue")
		return false
	}

	// Step 3 — the secret pairing code (hub-blind pairing, plan §1 "Pairing"). Only
	// values derived from it leave this process; its MAC keys stay in memory until the
	// first unseal pins the account root (or this command ends).
	pair_code, code_ok := vault.pair_code_generate(context.temp_allocator)
	if !code_ok {
		fmt.eprintln("ham-bridge enroll: the OS random source failed; cannot create a pairing code")
		return false
	}
	defer mem.zero_explicit(raw_data(pair_code), len(pair_code))
	// The pairing stretch binds the code to this hub origin and a fresh public salt (a
	// bridge does not know its account before approval, so no user id).
	pair_salt, salt_ok := vault.pair_salt_generate(context.temp_allocator)
	pair_origin, pair_origin_ok := bridge_hub_pair_origin(api_base, context.temp_allocator)
	if !salt_ok || !pair_origin_ok {
		fmt.eprintln("ham-bridge enroll: could not create the pairing salt for this hub (OS random source or hub URL); cannot continue")
		return false
	}
	pair_keys, keys_ok := vault.pair_keys_derive(pair_code, vault.Pair_Context{kind = "bridge", hub_origin = pair_origin, pair_salt = pair_salt})
	defer vault.pair_keys_wipe(&pair_keys)
	pair_payload, payload_ok := vault.pair_bridge_payload(identity_hex, public_key_hex, code_challenge, context.temp_allocator)
	pair_key_mac, mac_ok := vault.pair_key_mac_hex(&pair_keys, "bridge", pair_payload, context.temp_allocator)
	if !keys_ok || !payload_ok || !mac_ok {
		fmt.eprintln("ham-bridge enroll: could not derive the pairing values; cannot continue")
		return false
	}
	bridge_pairing_arm(&pair_keys)
	defer bridge_pairing_disarm()

	// Step 4 — the anonymous device-authorization request.
	body := bridge_enroll_authorize_body(descriptor, public_key_hex, code_challenge, identity_hex, identity_proof, vault.pair_lookup_hex(&pair_keys, context.temp_allocator), pair_key_mac, pair_salt, context.temp_allocator)
	if body == "" {
		fmt.eprintln("ham-bridge enroll: could not encode the authorize request")
		return false
	}
	fmt.printfln("bridge enroll: POST %s%s (no token — host=%s user=%s)",
		api_base, BRIDGE_ENROLL_AUTHORIZE_PATH, descriptor.hostname, descriptor.os_user)
	resp, sent := http.request_with_headers_timeout(
		"POST", api_base, BRIDGE_ENROLL_AUTHORIZE_PATH, body, nil, http.DEFAULT_TIMEOUT_MS)
	if !sent {
		fmt.eprintfln("bridge enroll FAILED: could not reach %s — check the URL and that the proxy is up (transport error, no HTTP response)", api_base)
		blog_error(.enroll_failed, blog_sym(.stage, .authorize), blog_sym(.reason, .transport))
		return false
	}
	if resp.status != 200 {
		fmt.eprintfln("bridge enroll FAILED: hub returned HTTP %d — %s", resp.status, resp.body)
		blog_error(.enroll_failed, blog_sym(.stage, .authorize), blog_int(.hub_status, i64(resp.status)))
		if resp.status == 404 do fmt.eprintln("  hint: --hub must point at the Hub API origin.")
		return false
	}
	authorized: Bridge_Authorize_Response
	if json.unmarshal_string(resp.body, &authorized, json.Specification.JSON, context.temp_allocator) != nil || authorized.data.device_code == "" {
		fmt.eprintfln("bridge enroll FAILED: the hub's authorize response carried no device_code — %s", resp.body)
		return false
	}
	device_code := authorized.data.device_code
	hub_fingerprint := authorized.data.bridge_key_fingerprint
	interval := authorized.data.interval
	expires_in := authorized.data.expires_in
	if interval <= 0 do interval = BRIDGE_ENROLL_DEFAULT_INTERVAL_SECONDS
	if expires_in <= 0 || expires_in > BRIDGE_ENROLL_MAX_WAIT_SECONDS do expires_in = BRIDGE_ENROLL_MAX_WAIT_SECONDS
	// Captured for diagnostics only (REQ-DIAG-1): an "expired" report with no
	// times attached is unfalsifiable, so every time-related failure below states
	// the wall clock, how long this process waited, and the deadline it expected.
	authorized_at_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	deadline_ms := authorized_at_ms + i64(expires_in) * 1000

	// The Hub echoes its own fingerprint advisorily. The bridge trusts ITS OWN, and
	// a disagreement is reported rather than resolved: the Hub computes this from
	// the key it received, so a mismatch means the key in transit is not the key
	// this process holds.
	if hub_fingerprint != "" && hub_fingerprint != fingerprint {
		fmt.eprintln("bridge enroll WARNING: the hub reports a DIFFERENT key fingerprint than this machine computed.")
		fmt.eprintfln("  this machine: %s", fingerprint)
		fmt.eprintfln("  hub says:     %s", hub_fingerprint)
		fmt.eprintln("  A mismatch is what a key substitution looks like; the approving browser will refuse it.")
	}
	ui_origin, ui_ok := bridge_enroll_hub_url(authorized.data.verification_uri, context.temp_allocator)
	if !ui_ok {
		fmt.eprintln("bridge enroll FAILED: Hub is not configured with --ui-origin; cannot build an approval link")
		return false
	}

	// Step 6 — print a stable, code-free URL and the pairing code. The code is typed
	// once on an approved device; a link never carries it.
	approval_url := bridge_enroll_approval_url(ui_origin, context.temp_allocator)
	identity_fp, _ := bridge_enroll_fingerprint(identity_hex, context.temp_allocator)
	fmt.println("")
	fmt.println("Enroll this machine")
	fmt.println("  On a device that already uses Heimdall, open:")
	fmt.println("")
	fmt.printfln("  %s", approval_url)
	fmt.println("")
	fmt.println("  and type this pairing code once:")
	fmt.println("")
	fmt.printfln("      %s", pair_code)
	fmt.println("")
	fmt.println("  The code is a secret: type it only on your own device. It expires shortly.")
	fmt.printfln("  It is bound to the hub %s: approve from a browser using that hub address.", pair_origin)
	fmt.printfln("  (bridge identity fingerprint, shown on the approval page: %s)", identity_fp)
	fmt.println("  This process retrieves its credential directly from the Hub using PKCE-protected polling.")
	fmt.println("")
	if !has_flag(args, "--headless") {
		if bridge_enroll_try_open_approval_url(approval_url) {
			fmt.println("Opened the approval page in your browser.")
		} else {
			fmt.println("Could not open a browser automatically; use the link shown above.")
		}
	}	fmt.printfln("Waiting for approval (expires in %dm%02ds)…", expires_in / 60, expires_in % 60)

	// Steps 7-11 — poll until a terminal answer. Polling is the only completion
	// channel; credentials never pass through the approving browser.
	waited := 0
	for waited < expires_in {
		sleep_for := min(interval, expires_in - waited)
		time.sleep(time.Duration(sleep_for) * time.Second)
		waited += sleep_for
		status, cred, retry_after := bridge_enroll_poll_once(api_base, device_code, code_verifier)
		switch status {
		case .Approved:
			token_file := bridge_enroll_token_file_from_args(args, api_base, cred.bridge_id)
			if reason, conflict := bridge_enroll_token_file_conflict(token_file, api_base, replacing_bridge_id); conflict {
				fmt.eprintfln("bridge enroll FAILED: credential file %s is not this bridge's: %s. Nothing was written; enroll again with its own --bridge-token-file.", token_file, reason)
				return false
			}
			if strings.trim_space(token_file) == "" {
				fmt.eprintln("bridge enroll FAILED: nowhere to store the credential — pass --bridge-token-file <path> (HOME is unset, so there is no default).")
				fmt.eprintln("  The approval succeeded; re-run with --bridge-token-file and approve again.")
				return false
			}
			config_path := cfg_lib.config_path_from_args(args)
			// Pin the identity and the enrolled owner under the new bridge id before
			// anything else: the unseal that follows is checked against both.
			if !bridge_unseal_identity_commit_enrollment(cred.bridge_id, cred.owner_user_id) {
				if cred.owner_user_id == "" {
					fmt.eprintln("bridge enroll FAILED: the hub did not report the approving account (owner_user_id); this bridge cannot pin its owner. Upgrade the hub and enroll again.")
				} else {
					fmt.eprintln("bridge enroll FAILED: this bridge's identity key could not be persisted. Nothing else was written.")
				}
				return false
			}
			if cred.enrollment_pending {
				// REQ-EA-4: write nothing until the vault key is delivered and the hub
				// commits; enroll_atomic.odin owns the whole sequence.
				if !bridge_enroll_atomic_run(args, cred, token_file, config_path, api_base) do return false
				restart_ok, restarted := bridge_enroll_restart_service(args)
				if !restart_ok do return false
				if restarted do fmt.println("  registered bridge service restarted with the new credential")
				return true
			}
			if !bridge_enroll_persist(cred, token_file, config_path, api_base) {
				_ = keystore_delete_identity_key(cred.bridge_id)
				bridge_unseal_forget_identity()
				return false
			}
			fmt.println("")
			fmt.printfln("bridge enroll SUCCESS: enrolled as bridge_id=%s", cred.bridge_id)
			if cred.approver_username != "" {
				fmt.printfln("  approved by     {}", cred.approver_username)
			} else {
				fmt.println("  approved by     username unavailable (older Hub)")
			}
			fmt.printfln("  credential      %s (0600)", token_file)
			if strings.trim_space(cred.refresh_token) != "" {
				fmt.printfln("  refresh token   %s (0600), access token expires in %ds and is refreshed proactively", bridge_enroll_refresh_file_for(token_file, context.temp_allocator), cred.expires_in)
			}
			fmt.println("  nothing secret was written to config.toml (audit F2)")
			if cred.vault_delivery_expected {
				if !bridge_enroll_wait_for_vault_delivery(args, cred.bridge_id) {
					keystore_lock_and_purge(cred.bridge_id)
					_ = keystore_delete_identity_key(cred.bridge_id)
					return false
				}
				bridge_enroll_print_account_fingerprint(cred.bridge_id)
			}
			restart_ok, restarted := bridge_enroll_restart_service(args)
			if !restart_ok {
				// The key (when delivered) was verified persisted above; a restart
				// failure is an operational problem, not a reason to destroy it.
				return false
			}
			if restarted do fmt.println("  registered bridge service restarted with the new credential")
			return true
		case .Denied:
			fmt.eprintln("bridge enroll FAILED: the request was denied in the browser. Nothing was written.")
			blog_error(.enroll_failed, blog_sym(.stage, .poll), blog_sym(.reason, .denied))
			return false
		case .Expired:
			now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
			fmt.eprintln("bridge enroll FAILED: the enrollment request expired before it was approved. Run the command again.")
			blog_error(.enroll_failed, blog_sym(.stage, .poll), blog_sym(.reason, .expired))
			fmt.eprintfln("  this process started waiting at %s and was told the request would expire at %s",
				action_scheduler_format_rfc3339_utc(authorized_at_ms), action_scheduler_format_rfc3339_utc(deadline_ms))
			fmt.eprintfln("  the Hub reported Expired at %s -- %ds after this process started waiting, against a %ds budget (waited=%ds)",
				action_scheduler_format_rfc3339_utc(now_ms), (now_ms - authorized_at_ms) / 1000, expires_in, waited)
			return false
		case .Fatal:
			return false
		case .Slow_Down:
			if retry_after > interval do interval = retry_after
			else do interval += BRIDGE_ENROLL_DEFAULT_INTERVAL_SECONDS
			fmt.printfln("enroll: hub asked us to slow down; polling every %ds", interval)
		case .Pending:
			// Nothing to do: wait out the next interval.
		}
	}
	timeout_now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	fmt.eprintln("bridge enroll FAILED: timed out waiting for approval. Nothing was written.")
	blog_error(.enroll_failed, blog_sym(.stage, .poll), blog_sym(.reason, .timeout))
	fmt.eprintfln("  this process started waiting at %s with a %ds budget (deadline %s) and gave up at %s (waited=%ds)",
		action_scheduler_format_rfc3339_utc(authorized_at_ms), expires_in, action_scheduler_format_rfc3339_utc(deadline_ms),
		action_scheduler_format_rfc3339_utc(timeout_now_ms), waited)
	return false
}

// bridge_enroll_token_file_from_args resolves where the credential goes, in the
// same order the running bridge resolves it (flag, then environment, then the
// per-(hub, bridge) default), so enroll and start agree without the operator
// repeating themselves. Returns "" when there is no default to fall back on (no
// HOME, or hub_url / bridge_id unknown yet), and the caller then refuses to enroll
// rather than guessing a path the bridge will not read at startup.
bridge_enroll_token_file_from_args :: proc(args: []string, hub_url, bridge_id: string, allocator := context.allocator) -> string {
	if explicit := option_value(args, "--bridge-token-file", ""); strings.trim_space(explicit) != "" {
		return strings.clone(strings.trim_space(explicit), allocator)
	}
	if env, found := os.lookup_env("HAM_BRIDGE_TOKEN_FILE", context.temp_allocator); found {
		if strings.trim_space(env) != "" do return strings.clone(strings.trim_space(env), allocator)
	}
	// Default under the operator's own config directory, so `enroll --hub <url>` needs
	// no second flag. Deliberately NOT a system path like /var/lib: enrollment is
	// run by a person, and a default only root can write would make the common case
	// fail at the last step, after the human has already approved in the browser.
	if hub_url == "" || bridge_id == "" do return ""
	return bridge_enroll_default_credential_path(hub_url, bridge_id, allocator)
}

// bridge_hello_hostname is the hostname the runtime WS hello reports, resolved
// once per process and cached.
//
// It exists so the hello and the enrollment descriptor cannot disagree: they are
// the same value from the same resolver, which is the whole point — the hub
// persists whichever one arrived last, so two sources would mean the displayed
// hostname depends on timing.
// THE CACHE IS A FIXED BUFFER, NOT A CLONED STRING, AND THAT IS THE WHOLE POINT.
//
// The first version stored `bridge_enroll_hostname()`'s clone in a global `string`.
// That clone comes from whatever `context.allocator` happened to be current at the
// FIRST call, while the global outlives every such scope — so under Odin's test
// runner, where each test runs on a rollback-stack allocator that is `free_all`'d
// when the test ends, the global pointed into memory handed to the next test and
// came back as another test's bytes (observed: "dawnstar" read back as "CDEFGHIJ",
// the same 8 bytes rewritten in place). A process-lifetime value must not hold a
// pointer into a scoped allocator, and the fix is to own the bytes outright rather
// than to pick a better allocator — `unseal_protocol.odin` keeps its public-key hex
// in a fixed global buffer for exactly this reason.
//
// 256 bytes is four times Linux's HOST_NAME_MAX. A name that somehow does not fit
// is stored as EMPTY rather than truncated: the hub's `if hostname != ""` guard
// then leaves the stored hostname alone, whereas a truncated name would overwrite a
// correct row with a wrong value — the failure this task exists to prevent.
g_bridge_hello_hostname_buf: [256]byte
g_bridge_hello_hostname_len: int
g_bridge_hello_hostname_once: sync.Once

bridge_hello_hostname :: proc() -> string {
	sync.once_do(&g_bridge_hello_hostname_once, proc() {
		// Resolved into the temp allocator and copied out immediately, so nothing
		// scoped outlives this block.
		resolved := bridge_enroll_hostname(context.temp_allocator)
		if len(resolved) > 0 && len(resolved) <= len(g_bridge_hello_hostname_buf) {
			copy(g_bridge_hello_hostname_buf[:len(resolved)], resolved)
			g_bridge_hello_hostname_len = len(resolved)
		}
	})
	return string(g_bridge_hello_hostname_buf[:g_bridge_hello_hostname_len])
}

// bridge_enrolled_but_tokenless reports the one startup state audit finding F4
// makes dangerous: a bridge that HAS been enrolled but holds no credential.
//
// WHY THIS IS A REFUSAL AND NOT A WARNING. `bridge_loopback_authorized` returns
// true unconditionally when the configured token is blank, so a tokenless bridge
// serves its loopback API — health, project-path validation — to any local caller
// with no authentication at all. It also cannot reach the hub, so it does nothing
// useful while doing that. Starting is strictly worse than exiting.
//
// THE PREDICATE IS NARROW ON PURPOSE (coordinator ruling on Q4). It fires only
// when the config carries a `brg_` daemon_id — i.e. the bridge has completed an
// enrollment at some point — and no credential could be resolved from any source.
// A dev bridge with the default `local-daemon` id and no token is UNAFFECTED and
// still starts, which is what keeps this from breaking the `dev-stack.sh`
// harnesses. The global fail-closed flip of the authorizer belongs to REQ-IMPL-6,
// which deletes the static-token path and can change the default without
// stranding anyone.
bridge_enrolled_but_tokenless :: proc(daemon_id, bridge_token: string) -> bool {
	if strings.trim_space(bridge_token) != "" do return false
	return strings.has_prefix(strings.trim_space(daemon_id), "brg_")
}

// bridge_refuse_tokenless_start prints the operator's way out and reports whether
// the bridge must not continue.
bridge_refuse_tokenless_start :: proc(cfg: Bridge_Config) -> bool {
	if !bridge_enrolled_but_tokenless(cfg.daemon_id, cfg.bridge_token) do return false
	fmt.eprintfln("ham-bridge REFUSING TO START: this bridge is enrolled as %s but no credential could be read.", strings.trim_space(cfg.daemon_id))
	fmt.eprintln("  An enrolled bridge with no credential cannot reach the hub, and would serve its loopback API")
	fmt.eprintln("  WITHOUT AUTHENTICATION while doing so (audit F4), so it exits instead of starting.")
	fmt.eprintln("  Fix one of these:")
	fmt.eprintln("    - pass --bridge-token-file <path> (or set HAM_BRIDGE_TOKEN_FILE) if the credential is elsewhere")
	if path := bridge_enroll_default_credential_path(cfg.daemon_url, strings.trim_space(cfg.daemon_id), context.temp_allocator); path != "" {
		fmt.eprintfln("    - check the default location: %s", path)
	}
	fmt.eprintln("    - re-enroll: ham-bridge enroll --hub <url>")
	return true
}

// ===== Hub binding at runtime (multi-bridge isolation) =====

// bridge_bind_runtime_hub binds this process's vault state to the hub its config
// (or --hub/--daemon-url) names, takes the instance locks, and refuses to start an
// ENROLLED bridge whose identity record is not stored for exactly that hub: the
// configured hub differs from the one it was enrolled with, the identity was lost,
// or another instance already runs on the same config or scope. Returns false when
// the process must exit.
bridge_bind_runtime_hub :: proc(cfg: Bridge_Config, config_path: string) -> bool {
	enrolled := keystore_bridge_id_is_enrolled(strings.trim_space(cfg.daemon_id))
	if !bridge_keystore_set_hub(cfg.daemon_url) {
		if !enrolled do return true // nothing persisted to protect
		fmt.eprintfln("ham-bridge REFUSING TO START: the configured hub %q is not a usable http(s) URL.", cfg.daemon_url)
		return false
	}
	if config_path != "" && os.exists(config_path) && !bridge_instance_lock(strings.concatenate({config_path, ".lock"}, context.temp_allocator)) {
		fmt.eprintfln("ham-bridge REFUSING TO START: another ham-bridge instance is running with config %s. Each bridge needs its own --config/--bridge-token-file.", config_path)
		return false
	}
	if !enrolled do return true
	bridge_id := strings.trim_space(cfg.daemon_id)
	rec: Bridge_Identity_Record
	status := keystore_read_identity(bridge_id, &rec)
	crypto.zero_explicit(&rec, size_of(rec))
	if status != .Found {
		fmt.eprintfln("ham-bridge REFUSING TO START: this machine holds no readable enrollment of %s for hub %s.", bridge_id, bridge_keystore_hub())
		fmt.eprintln("  Either the configured hub differs from the hub this bridge was enrolled with (a bridge is bound to")
		fmt.eprintln("  exactly one hub), or its identity record is missing or unreadable.")
		fmt.eprintln("  Fix the hub in the config / --hub, or re-enroll: ham-bridge enroll --hub <url>")
		return false
	}
	// The credential file must be this bridge's (owner header): a file shared with, or
	// overwritten by, another bridge would send another hub's token here.
	if cfg.credential_file != "" && !bridge_credential_file_belongs_to(cfg.credential_file, bridge_keystore_hub(), bridge_id) {
		hub, id, owner := bridge_credential_file_owner(cfg.credential_file)
		if owner == .Owned {
			fmt.eprintfln("ham-bridge REFUSING TO START: credential file %s belongs to bridge %s of hub %s, not to %s of %s.", cfg.credential_file, id, hub, bridge_id, bridge_keystore_hub())
		} else {
			fmt.eprintfln("ham-bridge REFUSING TO START: credential file %s does not record which bridge and hub it belongs to.", cfg.credential_file)
		}
		fmt.eprintln("  Each bridge needs its own credential file; re-enroll: ham-bridge enroll --hub <url>")
		return false
	}
	if name, scoped := keystore_scope_name(bridge_id); scoped {
		if dir, dir_ok := bridge_vault_bridge_dir(name, context.temp_allocator); dir_ok {
			_ = bridge_make_directory_all(dir)
			if !bridge_instance_lock(strings.concatenate({dir, "instance.lock"}, context.temp_allocator)) {
				fmt.eprintfln("ham-bridge REFUSING TO START: another ham-bridge instance already runs as %s for this hub.", bridge_id)
				return false
			}
		}
	}
	return true
}

// bridge_enroll_config_conflict reports a config that already belongs to an
// enrolled bridge of ANOTHER hub: enrolling into it would repoint (and break) that
// bridge, so `ham-bridge enroll` refuses and asks for a separate config.
bridge_enroll_config_conflict :: proc(config_path, api_base: string) -> (other_hub: string, conflict: bool) {
	if strings.trim_space(config_path) == "" do return "", false
	loaded, ok := cfg_lib.load(config_path)
	if !ok do return "", false
	if !keystore_bridge_id_is_enrolled(strings.trim_space(loaded.config.daemon.daemon_id)) do return "", false
	existing, e_ok := bridge_hub_canonical_base(loaded.config.wrapper.daemon_url, context.temp_allocator)
	wanted, w_ok := bridge_hub_canonical_base(api_base, context.temp_allocator)
	if !e_ok || !w_ok do return loaded.config.wrapper.daemon_url, true
	return existing, existing != wanted
}