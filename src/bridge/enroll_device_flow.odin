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

import "base:runtime"

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
import httpc "odin_test:lib/httpc"
import bridgesvc "odin_test:lib/bridgesvc"
import vault "odin_test:lib/vault"

// ===== Endpoints, all derived from the one UI origin (REQ-ENROLL-10) =====
//
// These are the routes that EXIST (see the hub's route table): settled 1 reused
// the existing device grant rather than standing up the `/api/v1/bridge-device/*`
// family design §9.3 names, so the design's paths are stale and these are not.
BRIDGE_ENROLL_AUTHORIZE_PATH :: [?]string{"api", "v1", "device", "authorize"}
BRIDGE_ENROLL_TOKEN_PATH :: [?]string{"api", "v1", "device", "token"}
// Path-form entry to the approval page. The Hub 302s it to the UI hash route
// `/#/device/add[?code=…]` (GET /api/v1/device/add). A path, not the hash route
// itself, because a forward-auth login round trip (`rd=<url>`) keeps path and
// query but drops the `#` fragment, so a hash link landed on Home after login.
// The UI uses the Hub's stored bridge key only after the operator confirms its
// fingerprint against this terminal.
BRIDGE_ENROLL_PAGE_PATH :: "/api/v1/device/add"
BRIDGE_ENROLL_REFRESH_PATH :: [?]string{"api", "v1", "device", "bridge-refresh"}

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
	return strings.concatenate({strings.trim_right(ui_origin, "/"), BRIDGE_ENROLL_PAGE_PATH}, allocator)
}

// Validate the optional browser base as strictly as a canonical hub address,
// while preserving its spelling and path for the displayed approval link.
bridge_enroll_approval_base_url :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	base, ok := bridge_enroll_hub_url(raw, context.temp_allocator)
	if !ok do return "", false
	_, canonical := bridge_hub_canonical_base(base, context.temp_allocator)
	if !canonical do return "", false
	return strings.clone(base, allocator), true
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
	// Public salt of the pairing stretch (vault.Pair_Context), random per enrollment,
	// and the canonical hub origin this bridge bound into it (declared so an approver
	// whose UI is served on another origin derives with the same one).
	pair_salt:                  string `json:"pair_salt,omitempty"`,
	pair_hub_origin:            string `json:"pair_hub_origin,omitempty"`,
	// The bridge id this machine was enrolled as before, offered for reuse. An
	// UNTRUSTED hint: the hub shows it only to an approver who owns that bridge, and
	// the approver decides whether to reuse it or register a new bridge.
	previous_bridge_id:         string `json:"previous_bridge_id,omitempty"`,
}

// bridge_enroll_authorize_body builds the /device/authorize request body as JSON
// text (tests); the request itself sends bridge_enroll_authorize_request.
bridge_enroll_authorize_body :: proc(
	d: Bridge_Machine_Descriptor,
	public_key_hex, code_challenge: string,
	identity_public_key_hex: string = "",
	identity_proof_json: string = "",
	pair_lookup: string = "",
	pair_key_mac: string = "",
	pair_salt: string = "",
	pair_hub_origin: string = "",
	previous_bridge_id: string = "",
	allocator := context.allocator,
) -> string {
	body := bridge_enroll_authorize_request(d, public_key_hex, code_challenge, identity_public_key_hex, identity_proof_json, pair_lookup, pair_key_mac, pair_salt, pair_hub_origin, previous_bridge_id)
	data, err := json.marshal(body, allocator = allocator)
	if err != nil do return ""
	return string(data)
}

// bridge_enroll_authorize_request is the /device/authorize request value
// (marshalled by httpc.json_body). Strings are temp-allocated or borrowed.
bridge_enroll_authorize_request :: proc(
	d: Bridge_Machine_Descriptor,
	public_key_hex, code_challenge: string,
	identity_public_key_hex: string = "",
	identity_proof_json: string = "",
	pair_lookup: string = "",
	pair_key_mac: string = "",
	pair_salt: string = "",
	pair_hub_origin: string = "",
	previous_bridge_id: string = "",
) -> Bridge_Authorize_Request {
	body := Bridge_Authorize_Request{
		client = "ham-bridge", device_label = d.hostname, os = bridge_enroll_os_display(d),
		app_version = d.bridge_version, os_user = d.os_user, bridge_public_key = public_key_hex,
		bridge_identity_public_key = identity_public_key_hex,
		code_challenge = code_challenge, code_challenge_method = "S256",
		pair_lookup = pair_lookup, pair_key_mac = pair_key_mac, pair_salt = pair_salt, pair_hub_origin = pair_hub_origin,
		previous_bridge_id = previous_bridge_id,
	}
	if identity_proof_json != "" {
		if sw, ok := vault.signature_wire_from_text(identity_proof_json, context.temp_allocator); ok do body.bridge_identity_proof = sw
	}
	return body
}

// Bridge_Authorize_Response is the API envelope of a /device/authorize answer.
Bridge_Authorize_Response :: struct {
	data: struct {
		device_code:            string,
		verification_uri:       string,
		interval:               int,
		expires_in:             int,
		bridge_key_fingerprint: string,
		// The hub's grant-store lifetime id ("" from older hubs): see bridge_enroll_code_lost.
		grant_epoch:            string,
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
	// Code_Lost: the hub that answered is not the one that issued the device code
	// (its grant-store epoch changed: it restarted and grants live in memory).
	Code_Lost,
}

// How many times one `enroll` replaces a lost or expired device code with a new one
// before it gives up (REQ-ENR-12 self-heal, bounded).
BRIDGE_ENROLL_MAX_REISSUES :: 2

// bridge_enroll_code_lost: both epochs known and different. An older hub sends none,
// and then a lost code still polls "pending" until this process's own deadline.
bridge_enroll_code_lost :: proc(issued_epoch, polled_epoch: string) -> bool {
	issued, polled := strings.trim_space(issued_epoch), strings.trim_space(polled_epoch)
	return issued != "" && polled != "" && issued != polled
}

// bridge_enroll_progress_code emits the approval URL and pairing code as one JSON
// line under --json-progress, for a front end (Electron, installer) driving enroll:
// a reissued code (issue > 0) replaces the one it showed before.
bridge_enroll_progress_code :: proc(args: []string, approval_url, pair_code: string, issue: int) {
	if !has_flag(args, "--json-progress") do return
	line, err := json.marshal(struct {
		event:        string,
		approval_url: string,
		pairing_code: string,
		issue:        int,
	}{"enroll_code", approval_url, pair_code, issue}, allocator = context.temp_allocator)
	if err == nil do fmt.println(string(line))
}

// bridge_enroll_should_reissue decides whether a poll answer is recovered by asking
// for a new device code: only a code the hub lost or let expire unapproved (never a
// denial or a PKCE failure), and at most BRIDGE_ENROLL_MAX_REISSUES times.
bridge_enroll_should_reissue :: proc(status: Bridge_Enroll_Poll_Status, reissues_done: int) -> bool {
	if reissues_done >= BRIDGE_ENROLL_MAX_REISSUES do return false
	#partial switch status {
	case .Code_Lost, .Expired:
		return true
	}
	return false
}

// bridge_enroll_poll_once performs one POST /device/token.
//
// THE VERIFIER IS REVEALED ONLY HERE, over TLS, directly to the Hub (RFC 7636
// §4.5). Up to this point only its SHA-256 has been on the wire, which is what
// makes a device_code scraped from a log, a proxy or a shoulder-surf unredeemable
// by anyone but the process that started the flow (design §3.6).
bridge_enroll_poll_once :: proc(
	api_base, device_code, code_verifier: string,
	issued_epoch := "",
	allocator := context.allocator,
) -> (Bridge_Enroll_Poll_Status, Bridge_Enroll_Credential, int) {
	token_path := BRIDGE_ENROLL_TOKEN_PATH
	resp, http_err := bridge_hub_http_send_alloc({
		method = .POST, url = bridge_hub_url(api_base), path = token_path[:],
		body = httpc.json_body(Bridge_Token_Request{device_code = device_code, code_verifier = code_verifier}),
	})
	defer httpc.response_destroy(&resp)
	if http_err == .Invalid_Body || http_err == .Invalid_Url do return .Fatal, Bridge_Enroll_Credential{}, 0
	if http_err != .None {
		// Transport failure is NOT fatal and NOT pending-forever: the caller treats
		// it as a retryable tick, because a flapping tunnel during a 15-minute
		// ceremony is ordinary.
		return .Pending, Bridge_Enroll_Credential{}, 0
	}
	if resp.status == 429 {
		return .Slow_Down, Bridge_Enroll_Credential{}, bridge_token_response_decode(httpc.text(resp)).interval
	}
	if resp.status == 401 {
		fmt.eprintln("enroll FAILED: the Hub rejected this bridge's PKCE proof (401). The device code cannot be redeemed by this process.")
		blog_error(.enroll_failed, blog_sym(.stage, .token), blog_int(.hub_status, 401))
		return .Fatal, Bridge_Enroll_Credential{}, 0
	}
	if resp.status != 200 {
		fmt.eprintfln("enroll: unexpected HTTP %d from the token endpoint — %s", resp.status, httpc.text(resp))
		blog_error(.enroll_failed, blog_sym(.stage, .token), blog_int(.hub_status, i64(resp.status)))
		return .Fatal, Bridge_Enroll_Credential{}, 0
	}
	decoded := bridge_token_response_decode(httpc.text(resp))
	// Checked before the status: a restarted hub answers "pending" for the code it
	// lost (anti-enumeration), so the epoch is the only sign it is gone.
	if bridge_enroll_code_lost(issued_epoch, decoded.grant_epoch) do return .Code_Lost, Bridge_Enroll_Credential{}, 0
	switch decoded.status {
	case "approved":
		return .Approved, bridge_enroll_credential_from_json(httpc.text(resp), allocator), 0
	case "denied":
		return .Denied, Bridge_Enroll_Credential{}, 0
	case "expired":
		return .Expired, Bridge_Enroll_Credential{}, 0
	case "slow_down":
		return .Slow_Down, Bridge_Enroll_Credential{}, 0
	case "pending":
		return .Pending, Bridge_Enroll_Credential{}, 0
	}
	fmt.eprintfln("enroll: unrecognised poll status in the Hub's response — %s", httpc.text(resp))
	return .Fatal, Bridge_Enroll_Credential{}, 0
}

// Bridge_Token_Request is the /device/token body (typed; json.marshal).
Bridge_Token_Request :: struct {
	device_code:   string,
	code_verifier: string,
}

// Bridge_Token_Data is a /device/token or /device/refresh answer: the poll status
// and, once approved, the credential. Absent members decode as zero values.
// The token-reply shape and its decoder live in contracts, shared with the hub that
// marshals the reply (contracts/bridge_token_wire.odin).
Bridge_Token_Data :: contracts.Bridge_Token_Data

bridge_token_response_decode :: proc(body: string) -> Bridge_Token_Data {
	return contracts.bridge_token_response_decode(body)
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
    content := strings.concatenate({strings.trim_space(value), "\n"}, context.temp_allocator)
    return bridge_retry_atomic_write(target, transmute([]byte)content)
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
    cred, ok, err, _ := bridge_credential_refresh_typed(api_base, refresh_token, "", 10_000)
    if ok do return cred, .Rotated
    if err.code == .Unauthenticated do return {}, .Revoked
    return {}, .Retry
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
    delay := BRIDGE_REFRESH_MIN_DELAY_SECONDS
    for {
        time.sleep(time.Duration(delay)*time.Second)
        if sync.atomic_load(&bridge_hub_traffic_stopped) do return
        api_base := bridge_config.daemon_url
        bridge_id := strings.trim_space(bridge_config.daemon_id)
        key := fmt.aprintf("refresh:%s:%s", api_base, bridge_id)
        refresh_path := bridge_enroll_refresh_file_for(g_bridge_credential_file)
        pending_path := strings.concatenate({g_bridge_credential_file, ".pending-rotation-v1"})
        request_path := bridge_refresh_request_path(g_bridge_credential_file)
        recovery, valid := bridge_refresh_pending_load(pending_path, key, api_base, bridge_id)
        if !valid { fmt.eprintln("bridge credential recovery parked: invalid pending rotation record"); return }
        recovery.pending.version = 1
        recovery.pending.key = key; recovery.pending.api_base = api_base; recovery.pending.bridge_id = bridge_id
        if recovery.has_pair {
            completed := bridge_retry_status(key)
            if completed.state == .Succeeded && completed.first_ms == recovery.pending.first_ms {
                // Both credential files were durable before the success receipt.
                // A crash before pending-file cleanup needs adoption only, not
                // another attempt (which may already be the sixth).
                bridge_refresh_adopt(recovery.pending.credential)
                _ = os.remove(pending_path); _ = os.remove(request_path)
                delay = bridge_refresh_delay_seconds(recovery.pending.credential.expires_in, 128)
                delete(key); delete(refresh_path); delete(pending_path); delete(request_path)
                if delay <= 0 do return
                continue
            }
            if !bridge_retry_resume_pending_rotation(key, recovery.pending.first_ms) {
                fmt.eprintln("bridge credential recovery parked: pending pair has no resumable receipt"); return
            }
        } else {
            bridge_retry_reopen_success(key)
            // A receipt left terminal by a RETRIABLE failure (a lost reply, an
            // unreachable hub, a crash mid-request) gets a fresh bounded budget
            // here, at every start and after every pause below. It used to stay
            // terminal on disk and stop renewal at every restart, forever.
            bridge_retry_reopen_retriable(key)
        }
        for {
            if sync.atomic_load(&bridge_hub_traffic_stopped) do return
            now := bridge_runtime_now_ms()
            budget, reserved := bridge_retry_reserve(key, now)
            if !reserved {
                if bridge_operation_terminal(budget) {
                    if !recovery.has_pair && bridge_refresh_terminal_is_retriable(budget) {
                        bridge_refresh_pause(key, budget)
                        continue
                    }
                    fmt.eprintfln("bridge credential recovery stopped: state=%v attempts=%d code=%v class=%v", budget.state, budget.attempts, budget.code, budget.class)
                    return
                }
                time.sleep(time.Duration(max(1, min(budget.next_ms-now, budget.deadline_ms-now)))*time.Millisecond)
                continue
            }
            stored, has_stored := bridge_read_token_file(refresh_path)
            err := contracts.wire_error(.Unauthenticated)
            success := false
            if recovery.has_pair || (has_stored && bridge_enroll_credential_usable(stored)) {
                // The request id is durable BEFORE the first send and reused by
                // every retry of this rotation, across restarts, until the new pair
                // is committed. It is what lets the hub recognise a retry of a
                // rotation it already performed and answer it instead of treating
                // the re-presented refresh token as stolen.
                if !recovery.has_pair && recovery.request_id == "" {
                    request_id, request_ok := bridge_refresh_request_ensure(request_path, key, api_base, bridge_id)
                    if request_ok do recovery.request_id = request_id
                }
                if recovery.has_pair || recovery.request_id != "" {
                    success, err = bridge_refresh_recovery_step(&recovery, pending_path, g_bridge_credential_file, refresh_path, api_base, bridge_id, stored, budget, bridge_operation_timeout_ms(budget, now))
                } else {
                    // Nothing was sent: retrying is safe.
                    err = contracts.wire_error(.Internal_Error, "refresh_request_unpersisted")
                }
            }
            delete(stored)
            if sync.atomic_load(&bridge_hub_traffic_stopped) {
                // Preserve the existing final-refresh cleanup. Temporary sunset
                // and a late successful in-flight rotation retain their files.
                if err.code == .Unauthenticated {
                    bridge_refresh_apply_rejection(cfg_lib.config_path_from_args(os.args), api_base, bridge_id, g_bridge_credential_file, refresh_path, request_path, err)
                }
                return
            }
            // An unknown outcome is NOT parked. It is retried, with the same request
            // id, inside the hub's retry window (BRIDGE_REFRESH_RETRY_GRACE_SECONDS).
            finished := bridge_retry_finish(key, bridge_runtime_now_ms(), success, err, base_ms = 5000)
            if success {
                // Adoption is after both durable writes, so a reconnect cannot
                // expose a half-committed rotation. Failed parent sync budgets stay.
                bridge_refresh_adopt(recovery.pending.credential)
                _ = os.remove(pending_path); _ = os.remove(request_path)
                fmt.printfln("bridge credential refreshed (access token valid for %ds)", recovery.pending.credential.expires_in)
                jitter: [1]byte
                if !bridge_enroll_entropy(jitter[:]) do jitter[0] = 128
                delay = bridge_refresh_delay_seconds(recovery.pending.credential.expires_in, jitter[0])
                break
            }
            if recovery.unknown_outcome {
                fmt.eprintfln("bridge credential refresh outcome unknown (attempt %d, code=%v); retrying the same rotation", finished.attempts, err.code)
            }
            if bridge_operation_terminal(finished) {
                if !recovery.has_pair && bridge_refresh_terminal_is_retriable(finished) {
                    bridge_refresh_pause(key, finished)
                    continue
                }
                bridge_refresh_apply_rejection(cfg_lib.config_path_from_args(os.args), api_base, bridge_id, g_bridge_credential_file, refresh_path, request_path, err)
                fmt.eprintfln("bridge credential recovery stopped: state=%v attempts=%d code=%v class=%v", finished.state, finished.attempts, finished.code, finished.class)
                return
            }
        }
        delete(key); delete(refresh_path); delete(pending_path); delete(request_path)
        if delay <= 0 do return
    }
}

// BRIDGE_REFRESH_PAUSE_SECONDS is how long renewal rests after a bounded budget of
// retriable attempts runs out, before it starts a fresh budget. Renewal never stops
// for a retriable failure: an unreachable hub or a lost reply must not cost the
// machine its enrollment.
BRIDGE_REFRESH_PAUSE_SECONDS :: 60

// bridge_refresh_terminal_is_retriable reports whether a terminal renewal receipt
// ended for a reason that a later attempt can fix. Unauthenticated (the hub refused
// the refresh token) and a deliberate cancel are final; everything classed retriable,
// and a reservation a crash left without a recorded result, is not.
bridge_refresh_terminal_is_retriable :: proc(b: Bridge_Operation_Budget) -> bool {
    if b.state == .Succeeded || b.state == .Cancelled do return false
    if b.state != .Waiting_Repair && b.state != .Exhausted do return false
    return b.class == .retriable || b.code == .None
}

// bridge_refresh_pause rests, then reopens the receipt with a fresh bounded budget.
// Only for an exchange (no pair received yet): a received pair's local commit keeps
// the pending-rotation receipt rules (bridge_retry_resume_pending_rotation).
bridge_refresh_pause :: proc(key: string, b: Bridge_Operation_Budget) {
    fmt.eprintfln("bridge credential refresh paused: state=%v attempts=%d code=%v; retrying in %ds", b.state, b.attempts, b.code, BRIDGE_REFRESH_PAUSE_SECONDS)
    time.sleep(BRIDGE_REFRESH_PAUSE_SECONDS * time.Second)
    _ = bridge_retry_reopen_retriable(key)
}

// ===== Refresh request identity (pending-rotation retry) =====
//
// One rotation = one request id, generated and made durable before the first send,
// sent as BRIDGE_REFRESH_REQUEST_ID_HEADER on every attempt, removed only once the
// returned pair is committed. A separate file from the pending-pair record, so an
// older bridge binary (rollback) that does not know it simply ignores it instead of
// rejecting its pending-rotation record.
BRIDGE_REFRESH_REQUEST_ID_HEADER :: "X-Heimdall-Refresh-Request-Id"
Bridge_Refresh_Request :: struct {
    version: int,
    key, api_base, bridge_id, request_id: string,
}
bridge_refresh_request_path :: proc(credential_file: string, allocator := context.allocator) -> string {
    return strings.concatenate({strings.trim_space(credential_file), ".refresh-request-v1"}, allocator)
}
// bridge_refresh_request_ensure returns this rotation's request id, creating and
// persisting one if none is recorded for (key, hub, bridge). Heap-allocated.
bridge_refresh_request_ensure :: proc(path, key, api_base, bridge_id: string) -> (string, bool) {
    if bytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        rec: Bridge_Refresh_Request
        if json.unmarshal(bytes, &rec, allocator = context.temp_allocator) == nil && rec.version == 1 && rec.key == key &&
           rec.api_base == api_base && rec.bridge_id == bridge_id && bridge_refresh_request_id_valid(rec.request_id) {
            return strings.clone(rec.request_id, runtime.heap_allocator()), true
        }
    }
    raw: [16]byte
    if !bridge_enroll_entropy(raw[:]) do return "", false
    id := strings.concatenate({"rrq_", string(hex.encode(raw[:], context.temp_allocator))}, runtime.heap_allocator())
    rec := Bridge_Refresh_Request{version = 1, key = key, api_base = api_base, bridge_id = bridge_id, request_id = id}
    data, merr := json.marshal(rec, allocator = context.temp_allocator)
    if merr != nil || !bridge_retry_atomic_write(path, data) { delete(id, runtime.heap_allocator()); return "", false }
    return id, true
}
bridge_refresh_request_id_valid :: proc(id: string) -> bool {
    if len(id) < 32 || len(id) > 128 do return false
    for c in transmute([]byte)id {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') do return false
    }
    return true
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
// registered service of THIS profile (bridgesvc: systemd --user, launchd, Scheduled
// Task or runit, named from the profile rather than a fixed name). It invokes no
// shell. Where no service is registered enrollment is still complete: it prints the
// command that starts the bridge and reports ok with restarted=false.
bridge_enroll_restart_service :: proc(args: []string) -> (ok: bool, restarted: bool) {
	host := bridge_service_host()
	name, installed := bridge_enroll_service_for(host, args)
	if !installed {
		fmt.println("  no registered bridge service was found for this enrollment; start the bridge with:")
		fmt.printfln("    %s", bridge_enroll_start_command(args))
		return true, false
	}
	l := bridgesvc.layout_for(host, name)
	argv := bridgesvc.service_argv(host, l, .Restart)
	ok_run, out := bridge_service_action(host, name, .Restart)
	if !ok_run {
		cmd := strings.join(argv, " ", context.temp_allocator)
		fmt.eprintln("bridge enroll: enrollment SUCCEEDED and the credential (and the delivered vault key) are saved, but the registered service could not be restarted.")
		fmt.eprintfln("  command: %s", cmd)
		if out != "" do fmt.eprintfln("  output: %s", out)
		fmt.eprintfln("  Start it manually with: ham-bridge service restart --service %s — then check its log; the vault key stays persisted, no re-enrollment needed.", name)
		bridge_enroll_service_start_failed = true
		g_bridge_enroll_service_restarted = true // a second start attempt would fail the same way
		return false, false
	}
	g_bridge_enroll_service_restarted = true
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
bridge_enroll_wait_for_vault_delivery :: proc(args: []string, bridge_id: string) -> (ok: bool, timed_out: bool) {
	bridge_enrollment_unseal_reset()
	// REQ-T2-3: this process exits right after the restart below, so it must not be
	// the one that tells the hub the vault is unlocked. See bridge_hub_vault_status_for_report.
	bridge_hub_set_enroll_only_runtime(true)
	bridge_config = bridge_config_from_args(args)
	credential_snapshot_963 := bridge_credential_snapshot()
	defer delete(credential_snapshot_963)
	if strings.trim_space(credential_snapshot_963) == "" || bridge_config.daemon_id != bridge_id {
		fmt.eprintln("bridge enroll FAILED: the saved credential could not be loaded for vault delivery")
		return false, false
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
					return false, false
				}
			}
			return true, false
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.eprintln("bridge enroll FAILED: enrolled, but the vault key was not delivered before the handoff deadline.")
	fmt.eprintln("  This bridge can only pin your account with the key delivery its pairing code allowed, so it can")
	fmt.eprintln("  never be unlocked later. Enroll again (new code) with the command below, and revoke this")
	fmt.eprintln("  bridge in Settings → Devices: it reports itself there as \"never received keys\".")
	return false, true
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

// ===== Reusing the previous bridge identity =====

BRIDGE_ENROLL_REUSE_FLAG :: "--reuse-bridge"
BRIDGE_ENROLL_NEW_FLAG :: "--new-bridge"
// The hub accepts a previous_bridge_id shaped brg_[A-Za-z0-9_-]{1,60} and refuses
// anything else with a 400, so the bridge never sends one it would refuse.
BRIDGE_ENROLL_HINT_MAX_SUFFIX :: 60

// bridge_enroll_hint_shape_ok mirrors the hub's previous_bridge_id shape check.
bridge_enroll_hint_shape_ok :: proc(id: string) -> bool {
	if !strings.has_prefix(id, KEYSTORE_BRIDGE_ID_PREFIX) do return false
	rest := id[len(KEYSTORE_BRIDGE_ID_PREFIX):]
	if len(rest) < 1 || len(rest) > BRIDGE_ENROLL_HINT_MAX_SUFFIX do return false
	for c in transmute([]byte)rest {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// bridge_enroll_reuse_hint resolves which previous bridge id `enroll` offers the
// approver for reuse: --reuse-bridge <id> when given, none with --new-bridge, else
// the id this config is enrolled as (config_bridge_id, "" for a first enrollment).
// The two flags are mutually exclusive. err is set (and ok false) for a usage error.
bridge_enroll_reuse_hint :: proc(args: []string, config_bridge_id: string) -> (hint: string, err: string, ok: bool) {
	wants_new := has_flag(args, BRIDGE_ENROLL_NEW_FLAG)
	if has_flag(args, BRIDGE_ENROLL_REUSE_FLAG) {
		if wants_new do return "", "--reuse-bridge and --new-bridge are mutually exclusive", false
		explicit := strings.trim_space(option_value(args, BRIDGE_ENROLL_REUSE_FLAG, ""))
		if !bridge_enroll_hint_shape_ok(explicit) {
			return "", "--reuse-bridge needs a bridge id (brg_…), as shown under Settings → Bridges", false
		}
		return explicit, "", true
	}
	if wants_new do return "", "", true
	id := strings.trim_space(config_bridge_id)
	if !bridge_enroll_hint_shape_ok(id) do return "", "", true
	return id, "", true
}

// bridge_enroll_result_line is the one-line outcome: whether the approver reused
// the offered id (a re-enrollment) or registered a new bridge. Temp-allocated.
bridge_enroll_result_line :: proc(reuse_hint, bridge_id: string, replacement := false) -> string {
	if replacement || (reuse_hint != "" && bridge_id == reuse_hint) {
		return strings.concatenate({"Re-enrolled existing bridge ", bridge_id}, context.temp_allocator)
	}
	return strings.concatenate({"Registered new bridge ", bridge_id}, context.temp_allocator)
}

// ===== The command: `ham-bridge enroll --hub <origin>` =====

// bridge_enroll_device_command runs the whole ceremony. Steps are numbered to the
// design's §2.2 so the two can be read side by side.
bridge_enroll_device_command :: proc(args: []string) -> bool {
	// F2: the profile's own running service holds the config lock; stop it for the
	// ceremony and start it again if the enrollment does not get to restart it.
	ok, _ := bridge_enroll_with_own_service(bridge_enroll_live_service_ops(args), args, bridge_enroll_device_command_run)
	return ok
}

// Set once bridge_enroll_restart_service handed the new credential to the service.
g_bridge_enroll_service_restarted: bool

bridge_enroll_device_command_run :: proc(args: []string) -> bool {
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
	// A preview UI may have a path prefix absent from the Hub's CSRF origin.
	// This browser-only override never changes API or pairing identity.
	approval_base := option_value(args, "--approval-base-url", "")
	if approval_base != "" {
		validated, valid := bridge_enroll_approval_base_url(approval_base, context.temp_allocator)
		if !valid {
			fmt.eprintln("ham-bridge enroll --approval-base-url requires an http(s) browser base URL without credentials, query or fragment")
			return false
		}
		approval_base = validated
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
	// One enrollment or running bridge per config: the config is locked for the whole
	// ceremony and released only to restart the registered service.
	enroll_config_lock, config_locked := bridge_enroll_config_lock_retry(cfg_lib.config_path_from_args(args), 10_000)
	if !config_locked {
		fmt.eprintfln("ham-bridge enroll REFUSED: another ham-bridge instance (a running bridge or enrollment) uses config %s.", cfg_lib.config_path_from_args(args))
		fmt.eprintln("  It is not this profile's registered service (that one is stopped automatically); stop it, or use another --config.")
		return false
	}
	defer bridge_instance_unlock(enroll_config_lock)
	// A re-enrollment of this config's bridge that a crash left unresolved is undone
	// first (reenroll_identity.odin): its previous identity comes back.
	bridge_reenroll_recover(cfg_lib.config_path_from_args(args))
	replacing_bridge_id := bridge_enroll_config_bridge_id(cfg_lib.config_path_from_args(args))
	reuse_hint, hint_err, hint_ok := bridge_enroll_reuse_hint(args, replacing_bridge_id)
	if !hint_ok {
		fmt.eprintfln("ham-bridge enroll: %s", hint_err)
		return false
	}
	if explicit_token_file := bridge_enroll_token_file_from_args(args, "", "", context.temp_allocator); explicit_token_file != "" {
		if reason, conflict := bridge_enroll_token_file_conflict(explicit_token_file, api_base, replacing_bridge_id, reuse_hint); conflict {
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

	// REQ-ENR-12: a device code the hub lost (it restarted: grants live in its memory)
	// or that expired unapproved is replaced by a fresh one, a bounded number of times,
	// instead of failing the ceremony. Each round re-runs steps 2c-11 with a new PKCE
	// pair and pairing code; the identity key above is kept.
	reissues := 0
	for {
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
		// The code (and so the armed pairing keys and this whole wait) lives at most
		// PAIR_CODE_TTL_SECONDS from now, whatever expires_in the hub reports.
		pair_deadline_ms := bridge_now_unix_ms() + i64(vault.PAIR_CODE_TTL_SECONDS) * 1000
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
		bridge_pairing_arm(&pair_keys, pair_deadline_ms)
		defer bridge_pairing_disarm()

		// Step 4 — the anonymous device-authorization request.
		authorize_req := bridge_enroll_authorize_request(descriptor, public_key_hex, code_challenge, identity_hex, identity_proof, vault.pair_lookup_hex(&pair_keys, context.temp_allocator), pair_key_mac, pair_salt, pair_origin, reuse_hint)
		authorize_body := httpc.json_body(authorize_req)
		if authorize_body.(httpc.Json_Body).failed {
			fmt.eprintln("ham-bridge enroll: could not encode the authorize request")
			return false
		}
		hub := bridge_hub_url(api_base)
		authorize_path := BRIDGE_ENROLL_AUTHORIZE_PATH
		authorize_url, _ := httpc.build_url(hub, authorize_path[:], allocator = context.temp_allocator)
		fmt.printfln("bridge enroll: POST %s (no token — host=%s user=%s)",
			authorize_url, descriptor.hostname, descriptor.os_user)
		if reuse_hint != "" {
			fmt.printfln("  asking to reuse bridge %s (%s); the approver chooses to reuse it or register a new bridge",
				reuse_hint, "--reuse-bridge" if has_flag(args, BRIDGE_ENROLL_REUSE_FLAG) else "this config's previous enrollment")
		} else if has_flag(args, BRIDGE_ENROLL_NEW_FLAG) {
			fmt.println("  registering a new bridge (--new-bridge): no previous bridge id is offered for reuse")
		}
		resp, authorize_err := bridge_hub_http_send_alloc({method = .POST, url = hub, path = authorize_path[:], body = authorize_body})
		defer httpc.response_destroy(&resp)
		if authorize_err != .None {
			fmt.eprintfln("bridge enroll FAILED: could not reach %s — check the URL and that the proxy is up (%s: %s)", api_base, httpc.error_string(authorize_err), resp.detail)
			blog_error(.enroll_failed, blog_sym(.stage, .authorize), blog_sym(.reason, .transport))
			return false
		}
		if resp.status != 200 {
			fmt.eprintfln("bridge enroll FAILED: hub returned HTTP %d — %s", resp.status, httpc.text(resp))
			blog_error(.enroll_failed, blog_sym(.stage, .authorize), blog_int(.hub_status, i64(resp.status)))
			if resp.status == 404 do fmt.eprintln("  hint: --hub must point at the Hub API origin.")
			return false
		}
		authorized: Bridge_Authorize_Response
		if json.unmarshal(resp.body, &authorized, json.Specification.JSON, context.temp_allocator) != nil || authorized.data.device_code == "" {
			fmt.eprintfln("bridge enroll FAILED: the hub's authorize response carried no device_code — %s", httpc.text(resp))
			return false
		}
		device_code := authorized.data.device_code
		hub_fingerprint := authorized.data.bridge_key_fingerprint
		interval := authorized.data.interval
		expires_in := authorized.data.expires_in
		if interval <= 0 do interval = BRIDGE_ENROLL_DEFAULT_INTERVAL_SECONDS
		if expires_in <= 0 || expires_in > BRIDGE_ENROLL_MAX_WAIT_SECONDS do expires_in = BRIDGE_ENROLL_MAX_WAIT_SECONDS
		if code_left := int((pair_deadline_ms - bridge_now_unix_ms()) / 1000); expires_in > code_left do expires_in = max(code_left, 0)
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
		approval_url := bridge_enroll_approval_url(approval_base if approval_base != "" else ui_origin, context.temp_allocator)
		identity_fp, _ := bridge_enroll_fingerprint(identity_hex, context.temp_allocator)
		fmt.println("")
		fmt.println("Enroll this machine")
		fmt.println("  On a device that already uses Ninjy, open:")
		fmt.println("")
		fmt.printfln("  %s", approval_url)
		fmt.println("")
		fmt.println("  and type this pairing code once:")
		fmt.println("")
		fmt.printfln("      %s", pair_code)
		fmt.println("")
		fmt.println("  The code is a secret: type it only on your own device. It expires shortly.")
		fmt.printfln("  It is bound to the hub %s: approve on that hub's UI; the hub must list this", pair_origin)
		fmt.println("  address as one of its pairing origins (its own API address, or --pairing-hub-origins).")
		fmt.printfln("  (bridge identity fingerprint, shown on the approval page: %s)", identity_fp)
		fmt.println("  This process retrieves its credential directly from the Hub using PKCE-protected polling.")
		fmt.println("")
		bridge_enroll_progress_code(args, approval_url, pair_code, reissues)
		// The approval page is the same URL for a reissued code: open it only once.
		if !has_flag(args, "--headless") && reissues == 0 {
			if bridge_enroll_try_open_approval_url(approval_url) {
				fmt.println("Opened the approval page in your browser.")
			} else {
				fmt.println("Could not open a browser automatically; use the link shown above.")
			}
		}
		fmt.printfln("Waiting for approval (expires in %dm%02ds)…", expires_in / 60, expires_in % 60)

		// Steps 7-11 — poll until a terminal answer. Polling is the only completion
		// channel; credentials never pass through the approving browser.
		waited := 0
		reissue := false
		poll: for waited < expires_in {
			sleep_for := min(interval, expires_in - waited)
			time.sleep(time.Duration(sleep_for) * time.Second)
			waited += sleep_for
			status, cred, retry_after := bridge_enroll_poll_once(api_base, device_code, code_verifier, authorized.data.grant_epoch)
			if bridge_enroll_should_reissue(status, reissues) {
				reissue = true
				break poll
			}
			switch status {
			case .Approved:
				token_file := bridge_enroll_token_file_from_args(args, api_base, cred.bridge_id)
				// REQ-ENROLL-REPLACE: the approving user may choose an existing bridge
				// even after a reinstall lost its config/reuse hint. Back up that
				// scope's identity before replacing it on every platform.
				existing_identity: Bridge_Identity_Record
				existing_status := keystore_read_identity(cred.bridge_id, &existing_identity)
				crypto.zero_explicit(&existing_identity, size_of(existing_identity))
				reenroll := existing_status != .Not_Found || (reuse_hint != "" && cred.bridge_id == reuse_hint)
				fmt.println("")
				if reenroll {
					fmt.printfln("Approved: re-enrolling existing bridge %s", cred.bridge_id)
				} else if reuse_hint != "" {
					fmt.printfln("Approved: the approver registered a NEW bridge %s instead of reusing %s (that bridge is left as it is)", cred.bridge_id, reuse_hint)
				} else {
					fmt.printfln("Approved: registering new bridge %s", cred.bridge_id)
				}
				// Checked before the account decision below, so a refusal here leaves the
				// previous account's bridge untouched.
				if reason, conflict := bridge_enroll_token_file_conflict(token_file, api_base, replacing_bridge_id, cred.bridge_id if reenroll else ""); conflict {
					fmt.eprintfln("bridge enroll FAILED: credential file %s is not this bridge's: %s. Nothing was written; enroll again with its own --bridge-token-file.", token_file, reason)
					_, _ = bridge_self_revoke(api_base, cred.access_token)
					return false
				}
				if strings.trim_space(token_file) == "" {
					fmt.eprintln("bridge enroll FAILED: nowhere to store the credential — pass --bridge-token-file <path> (HOME is unset, so there is no default).")
					fmt.eprintln("  The approval succeeded; re-run with --bridge-token-file and approve again.")
					return false
				}
				// F1: a machine enrolled by ANOTHER account is replaced only when confirmed.
				account_ok, _ := bridge_enroll_resolve_account(args, api_base, cfg_lib.config_path_from_args(args), replacing_bridge_id, cred)
				if !account_ok do return false
				config_path := cfg_lib.config_path_from_args(args)
				// Hold the approved scope until restart, including IDs selected only in the UI.
				scope_lock_path := ""
				defer if scope_lock_path != "" do bridge_instance_unlock(scope_lock_path)
				if name, scoped := keystore_scope_name(cred.bridge_id); scoped {
					scope_locked: bool
					scope_lock_path, scope_locked = bridge_scope_lock(name)
					if !scope_locked {
						fmt.eprintfln("bridge enroll FAILED: another ham-bridge instance runs as %s on this machine; stop it and enroll again. Nothing was written.", cred.bridge_id)
						return false
					}
				}
				if !bridge_enroll_commit_identity(config_path, api_base, cred.bridge_id, token_file, cred.owner_user_id) {
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
					// A vault-key timeout here rolls everything back (F7): the previous
					// credential, if any, stays usable and a plain re-run retries.
					if !bridge_enroll_atomic_run(args, cred, token_file, config_path, api_base) do return false
					if bridge_enroll_atomic_state() == .Committed do fmt.println(bridge_enroll_result_line(reuse_hint, cred.bridge_id, reenroll))
					bridge_reenroll_clear(config_path)
					if !bridge_hub_pause_clear_enrolled(config_path) do return false
					bridge_instance_unlock(enroll_config_lock) // the restarted service takes it
					bridge_instance_unlock_scope(cred.bridge_id)
					restart_ok, restarted := bridge_enroll_restart_service(args)
					if !restart_ok do return false
					if restarted do fmt.println("  registered bridge service restarted with the new credential")
					return true
				}
				if !bridge_enroll_persist(cred, token_file, config_path, api_base) {
					bridge_enroll_discard_identity(config_path, cred.bridge_id)
					bridge_unseal_forget_identity()
					return false
				}
				// Without atomic enrollment (an older hub) the persist IS the commit.
				_ = bridge_reenroll_resolve(config_path, cred.bridge_id, true)
				fmt.println("")
				fmt.printfln("bridge enroll SUCCESS: enrolled as bridge_id=%s", cred.bridge_id)
				fmt.println(bridge_enroll_result_line(reuse_hint, cred.bridge_id, reenroll))
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
					if delivered, timed_out := bridge_enroll_wait_for_vault_delivery(args, cred.bridge_id); !delivered {
						// The identity is kept: the started service reports itself "unpaired"
						// (bridge_hub_vault_status_for_report) so the UI can show and revoke it.
						keystore_lock_and_purge(cred.bridge_id)
						// F7: this bridge can never be unlocked; the profile parks as
						// needs_reenrollment with the retry command instead of running locked.
						if timed_out do bridge_enroll_mark_vault_key_timeout(config_path, api_base, cred.bridge_id)
						return false
					}
					bridge_enroll_print_account_fingerprint(cred.bridge_id)
				}
				// Every successful enrollment clears a needs-reenrollment marker before the
				// service restarts: one naming a reused bridge id would park it for good.
				bridge_reenroll_clear(config_path)
				if !bridge_hub_pause_clear_enrolled(config_path) do return false
				bridge_instance_unlock(enroll_config_lock) // the restarted service takes it
				bridge_instance_unlock_scope(cred.bridge_id)
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
			case .Code_Lost:
				fmt.eprintfln("bridge enroll FAILED: the hub restarted and lost this enrollment request %d times. Nothing was written; run the command again.", reissues + 1)
				blog_error(.enroll_failed, blog_sym(.stage, .poll), blog_sym(.reason, .expired))
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
		if reissue {
			reissues += 1
			fmt.println("")
			fmt.printfln("bridge enroll: the hub no longer knows this request (it restarted, or the request expired unapproved); requesting a new pairing code (%d/%d)", reissues, BRIDGE_ENROLL_MAX_REISSUES)
			continue
		}
		timeout_now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
		fmt.eprintln("bridge enroll FAILED: timed out waiting for approval. Nothing was written.")
		blog_error(.enroll_failed, blog_sym(.stage, .poll), blog_sym(.reason, .timeout))
		fmt.eprintfln("  this process started waiting at %s with a %ds budget (deadline %s) and gave up at %s (waited=%ds)",
			action_scheduler_format_rfc3339_utc(authorized_at_ms), expires_in, action_scheduler_format_rfc3339_utc(deadline_ms),
			action_scheduler_format_rfc3339_utc(timeout_now_ms), waited)
		return false
	}
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
	if _, locked := bridge_config_lock(config_path); config_path != "" && !locked {
		fmt.eprintfln("ham-bridge REFUSING TO START: another ham-bridge instance is running with config %s. Each bridge needs its own --config/--bridge-token-file.", config_path)
		return false
	}
	// Under the config lock: undo a re-enrollment a crash left before its ack.
	if config_path != "" do bridge_reenroll_recover(config_path)
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
	if name, scoped := keystore_scope_name(bridge_id); scoped && !bridge_scope_lock_ok(name) {
		fmt.eprintfln("ham-bridge REFUSING TO START: another ham-bridge instance already runs as %s for this hub.", bridge_id)
		return false
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
// Return owned credential bytes while holding the writer's mutex. Callers may
// use the snapshot across I/O without racing rotation or revocation.
bridge_credential_snapshot :: proc(allocator := context.allocator) -> string {
    sync.mutex_lock(&g_bridge_credential_mu)
    defer sync.mutex_unlock(&g_bridge_credential_mu)
    return strings.clone(bridge_config.bridge_token, allocator)
}

bridge_credential_refresh_typed :: proc(api_base, refresh_token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    headers := make([dynamic]httpc.Header, 0, 2, context.temp_allocator)
    append(&headers, httpc.bearer(refresh_token))
    if request_id != "" do append(&headers, httpc.Header{name = BRIDGE_REFRESH_REQUEST_ID_HEADER, value = request_id})
    refresh_path := BRIDGE_ENROLL_REFRESH_PATH
    // One cumulative deadline over DNS, connect, TLS, send and every read; a
    // spent budget fails without I/O (may_have_sent false).
    resp, http_err := bridge_hub_http_send_alloc({
        method = .POST, url = bridge_hub_url(api_base), path = refresh_path[:], headers = headers[:],
        body = httpc.json_body(struct{}{}), timeout_ms = bridge_deadline_ms(timeout_ms),
    })
    defer httpc.response_destroy(&resp)
    cred, ok, err, unknown := bridge_refresh_response_classify(resp, http_err == .None, api_base)
    if err.code == .Unauthenticated do bridge_hub_stop_traffic(true)
    return cred, ok, err, unknown
}
// bridge_refresh_response_classify -> (credential, ok, error, unknown_outcome).
// unknown_outcome is true when the hub may have rotated the refresh token: a
// transport failure after request bytes may have left (httpc may_have_sent), a
// retriable status that cannot be proved a pre-rotation refusal, or a 200 whose
// reply is unusable.
bridge_refresh_response_classify :: proc(resp: httpc.Response, ok: bool, api_base: string) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    err := bridge_operation_http_error(resp, ok)
    if !ok do return {}, false, err, resp.may_have_sent
    if resp.status != 200 {
        // Retain typed code/class, while independently fencing a POST that
        // cannot be proved to have been refused before token rotation.
        uncertain := err.class == .retriable && !bridge_http_attempt_retriable(.POST, resp, true)
        return {}, false, err, uncertain
    }
    // A 200 means the hub ROTATED: the presented refresh token is spent. A reply
    // this bridge cannot use is therefore a protocol failure with an unknown
    // outcome, never a timeout. Say so, with what is safe to log (the length and
    // the decoder's complaint, never a token), and let the request-id retry
    // recover the rotation.
    data, decode_problem := contracts.bridge_token_response_decode_checked(httpc.text(resp))
    if decode_problem == "" && (!bridge_enroll_credential_usable(data.access_token) || !bridge_enroll_credential_usable(data.refresh_token)) {
        decode_problem = "access_token or refresh_token missing or malformed"
    }
    if decode_problem != "" {
        fmt.eprintfln("bridge credential refresh: PROTOCOL ERROR: hub answered 200 but the reply is unusable (body_len=%d): %s", len(resp.body), decode_problem)
        return {}, false, contracts.wire_error(.Internal_Error, "refresh_reply_undecodable", "hub refresh reply could not be decoded"), true
    }
    cred := Bridge_Enroll_Credential{
        bridge_id = strings.clone(data.bridge_id), access_token = strings.clone(data.access_token),
        refresh_token = strings.clone(data.refresh_token), expires_in = data.expires_in, refresh_expires_in = data.refresh_expires_in,
    }
    return cred, true, {}, false
}

Bridge_Refresh_Pending :: struct {
    version: int,
    key, api_base, bridge_id: string,
    first_ms: i64,
    credential: Bridge_Enroll_Credential,
}
Bridge_Refresh_Recovery :: struct {
    pending: Bridge_Refresh_Pending,
    has_pair: bool,
    // The last exchange may have rotated on the hub (sent, reply lost or unusable).
    // Informational: such an attempt is retried with the same request_id.
    unknown_outcome: bool,
    // This rotation's durable request id (bridge_refresh_request_ensure).
    request_id: string,
}
bridge_refresh_pending_save :: proc(path: string, pending: Bridge_Refresh_Pending) -> bool {
    bytes, err := json.marshal(pending, allocator = context.temp_allocator)
    if err != nil || len(bytes) > 64*1024 do return false
    return bridge_retry_atomic_write(path, bytes)
}
bridge_refresh_pending_load :: proc(path, key, api_base, bridge_id: string) -> (Bridge_Refresh_Recovery, bool) {
    if !os.exists(path) do return {}, true
    info, err := os.stat(path, context.temp_allocator)
    if err != nil || info.type != .Regular || info.size > 64*1024 ||
       info.mode & {.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other} != {} { return {}, false }
    bytes, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil do return {}, false
    pending: Bridge_Refresh_Pending
    if json.unmarshal(bytes, &pending) != nil || pending.version != 1 || pending.key != key ||
       pending.api_base != api_base || pending.bridge_id != bridge_id ||
       !bridge_enroll_credential_usable(pending.credential.access_token) ||
       !bridge_enroll_credential_usable(pending.credential.refresh_token) { return {}, false }
    return {pending = pending, has_pair = true}, true
}
bridge_refresh_pair_commit :: proc(path, refresh_path, api_base, bridge_id: string, cred: Bridge_Enroll_Credential) -> bool {
    // The pending pair remains durable across BOTH file replacements.
    if !bridge_retry_atomic_write(refresh_path, transmute([]byte)cred.refresh_token) do return false
    return bridge_write_credential_file(path, api_base, bridge_id, cred.access_token)
}
bridge_refresh_recovery_step :: proc(
    recovery: ^Bridge_Refresh_Recovery, pending_path, path, refresh_path, api_base, bridge_id, stored: string,
    budget: Bridge_Operation_Budget, timeout_ms: int,
    exchange := bridge_credential_refresh_typed, save_pending := bridge_refresh_pending_save, commit_pair := bridge_refresh_pair_commit,
) -> (bool, contracts.Wire_Error) {
    if sync.atomic_load(&bridge_hub_traffic_stopped) do return false, contracts.wire_error(.Bridge_Offline)
    if !recovery.has_pair {
        cred, ok, err, unknown := exchange(api_base, stored, recovery.request_id, timeout_ms)
        recovery.unknown_outcome = unknown
        if !ok do return false, err
        recovery.pending.credential = cred
        recovery.pending.first_ms = budget.first_ms
        recovery.has_pair = true
    }
    if !save_pending(pending_path, recovery.pending) do return false, contracts.wire_error(.Bridge_Timeout)
    if !commit_pair(path, refresh_path, api_base, bridge_id, recovery.pending.credential) do return false, contracts.wire_error(.Bridge_Timeout)
    return true, {}
}

bridge_refresh_adopt :: proc(cred: Bridge_Enroll_Credential) {
    sync.mutex_lock(&g_bridge_credential_mu)
    bridge_config.bridge_token = strings.clone(cred.access_token, runtime.heap_allocator())
    sync.mutex_unlock(&g_bridge_credential_mu)
    // Renew the live hub session in-band with the new access token
    // (bridge_credential_reauth_drain, on the hub runtime loop).
    sync.atomic_store(&bridge_credential_reauth_pending, true)
    key := bridge_action_scheduler_sync_key()
    defer delete(key)
    bridge_retry_credential_repaired(key)
}

// Only a final authentication refusal destroys persisted enrollment. A pending
// sunset uses a retriable error and must survive the retry budget and a restart.
bridge_refresh_apply_rejection :: proc(config_path, api_base, bridge_id, path, refresh_path, request_path: string, err: contracts.Wire_Error) -> bool {
    if err.code != .Unauthenticated do return false
    bridge_hub_stop_traffic(true)
    _ = os.remove(refresh_path); _ = os.remove(path); _ = os.remove(request_path)
    sync.mutex_lock(&g_bridge_credential_mu); bridge_config.bridge_token = ""; sync.mutex_unlock(&g_bridge_credential_mu)
    bridge_reenroll_mark(config_path, api_base, bridge_id, .Refresh_Rejected)
    return true
}
