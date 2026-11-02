// Device-authorization service (ELDA-1 / ELDA-6 orchestration).
//
// Device_Auth_Service wires the grant store, trusted-XFF IP resolver, and the
// per-IP authorize rate limit together behind a testable API. The HTTP layer
// (transport/http/device_auth_handlers.odin) is a thin adapter over this.
//
// authorize() is the only public entry point in task 1:
//   1. validate input (client is required),
//   2. resolve the real client IP (trusted-XFF when behind a trusted proxy),
//   3. enforce the per-IP rate limit BEFORE touching the store's grant map,
//   4. mint a grant with unlinkable device_code + user_code, capture request_ip,
//   5. return the device-poll contract {device_code, user_code, verification_uri,
//      interval, expires_in}.
//
// Failures map to domain errors: Rate_Limited (429), Validation_Failed (400),
// Provider_Unavailable (503) when the OS CSPRNG is unavailable.

package device_auth

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"

// Device_Auth_Service is the orchestrator. All fields are read-only after
// construction except `store`, which carries its own mutex.
Device_Auth_Service :: struct {
	store:           ^Grant_Store,
	clock:           Monotonic_Clock,
	trusted_cidrs:   []string,
	// REQ-IMPL-2: bridge_minter issues the per-machine, bridge-scoped credential
	// for a BRIDGE grant. It is a separate seam from `minter` on purpose — the
	// two produce different identities (a `brg_` vs a user token), and a single
	// minter that decided between them from its arguments would be one `if` away
	// from handing a machine a user-scoped token. May be nil; a bridge grant then
	// fails approval loudly rather than falling back to the user minter.
	bridge_minter:     Bridge_Token_Minter,
	bridge_minter_ctx: rawptr,
}

// Bridge_Mint_Request is everything the bridge minter needs to create the
// machine's identity. owner_user_id is bound from Auth_Context by approve() and
// is never read from the request body (ELDA-6 / REQ-IMPL-2 scope item 4).
Bridge_Mint_Request :: struct {
	owner_user_id:          string,
	bridge_public_key:      string, // the key the credential is bound to
	bridge_key_fingerprint: string, // hub-computed; stored for later display/audit
	os_user:                string,
	device_label:           string, // host-asserted machine descriptor
	os:                     string,
	app_version:            string,
	// target_bridge_id carries the approver's "attach to an existing bridge"
	// choice through to the minter. Empty means mint a new bridge.
	target_bridge_id:       string,
	// Operator-chosen display label for a NEW bridge. Empty falls back to the
	// host-asserted hostname. Invalid when target_bridge_id is also present.
	new_bridge_label:       string,
	// sunset_bridge_id is the approver's bridge to retire in the same unit of work
	// that creates the NEW one (a full plan's "register new and sunset one"). Like
	// target_bridge_id it is not an ownership assertion: the bridge service re-checks
	// it. Invalid when target_bridge_id is also present.
	sunset_bridge_id:       string,
	// Passwordless vault: the bridge's persistent identity key (from the grant) and
	// the approving device's signed vault approval (from the approve body). The
	// minter validates the approval BEFORE minting and commits it with the mint.
	bridge_identity_public_key: string,
	vault_approval:             Vault_Approval,
}

// Vault_Approval is the `vault_approval` object of POST /device/approve.
Vault_Approval :: struct {
	present:          bool,
	expected_version: i64,
	statement:        string,
	signature:        string,
}

// Bridge_Mint_Result is what the bridge minter hands back.
//
// IT IS A STRUCT, NOT A TUPLE, because REQ-IMPL-3 turned the single credential into
// an expiring PAIR plus two lifetimes, and a five-value tuple return is exactly
// where an argument gets transposed. `bridge_id` MUST be the `brg_` the credential
// resolves to server-side, so the bridge learns its own id from the poll response
// rather than asserting one (design §7.3).
//
// refresh_token may be empty, and that is not a bug: it means the minter issued a
// non-expiring credential (the legacy `hbr_` shape). A bridge seeing no refresh
// token must not invent a refresh schedule.
Bridge_Mint_Result :: struct {
	access_token:       string,
	refresh_token:      string,
	bridge_id:          string,
	expires_in:         int,
	refresh_expires_in: int,
	vault_delivery_expected: bool,
	// error, when set on a failed mint, is the reason the approver sees instead of
	// the generic "could not issue". Used for refusals that are the approver's to fix,
	// such as enrolling a bridge before setting up a vault (REQ-EA, decision A).
	error: domain.Domain_Error,
}

// Bridge_Token_Minter mints a bridge-scoped credential pair. Returns ok=false to
// fail the approval outright — a bridge grant never falls back to the user minter.
Bridge_Token_Minter :: proc(ctx: rawptr, req: Bridge_Mint_Request) -> (Bridge_Mint_Result, bool)

new_device_auth_service :: proc(store: ^Grant_Store, clock: Monotonic_Clock, trusted_cidrs: []string) -> Device_Auth_Service {
	// Own a stable copy of the trusted CIDR strings. Callers often pass config or
	// test-local slices; holding those slice headers directly can leave the
	// long-lived service pointing at stack/temporary memory after construction.
	owned_cidrs := make([]string, len(trusted_cidrs))
	for i in 0..<len(trusted_cidrs) {
		owned_cidrs[i] = strings.clone(trusted_cidrs[i])
	}
	return Device_Auth_Service{store = store, clock = clock, trusted_cidrs = owned_cidrs}
}

// with_bridge_token_minter attaches the REQ-IMPL-2 bridge-credential issuer, used
// for grants that carry a bridge_public_key. App wiring passes the App_Graph;
// tests pass their fake's state.
with_bridge_token_minter :: proc(service: ^Device_Auth_Service, minter: Bridge_Token_Minter, minter_ctx: rawptr = nil) {
	service.bridge_minter = minter
	service.bridge_minter_ctx = minter_ctx
}

// authorize creates a device grant for the given input + request provenance.
// `remote_addr` is the TCP peer; `xff_header` is the raw X-Forwarded-For value.
// Returns (result, true, {}) on success or (_, false, err) on failure.
authorize :: proc(service: ^Device_Auth_Service, input: Authorize_Input, remote_addr, xff_header: string) -> (Authorize_Result, bool, domain.Domain_Error) {
	// Validate input: client is required (identifies the calling app).
	if input.client == "" {
		return Authorize_Result{}, false, domain.domain_error(.Validation_Failed, "client is required")
	}
	// REQ-IMPL-2: validate the bridge-enrollment extensions and derive the
	// fingerprint BEFORE the rate-limit bucket is spent, so a malformed request
	// does not consume the caller's budget.
	bridge_fingerprint, grant_kind, bok, berr := validate_bridge_authorize_input(input)
	if !bok do return Authorize_Result{}, false, berr
	// Resolve the effective client IP (trusted-XFF only behind a trusted proxy).
	request_ip := resolve_client_ip(remote_addr, xff_header, service.trusted_cidrs)
	// Rate limit BEFORE grant creation to avoid store-filling DoS (ELDA-1).
	now := service.clock.now()
	sync.mutex_lock(&service.store.mutex)
	allowed := allow_authorize(service.store, request_ip, now)
	sync.mutex_unlock(&service.store.mutex)
	if !allowed {
		return Authorize_Result{}, false, domain.domain_error(.Rate_Limited, "too many device authorize requests from this IP")
	}
	// Mint the grant (independent CSPRNG draws => unlinkable codes).
	result, ok := create_grant(service.store, input, request_ip, service.clock, bridge_fingerprint, grant_kind)
	if !ok {
		if input.pair_lookup != "" do return Authorize_Result{}, false, domain.domain_error(.Conflict, "this pairing code is already in use; run the enrollment again")
		return Authorize_Result{}, false, domain.domain_error(.Provider_Unavailable, "could not generate secure codes; try again")
	}
	return result, true, domain.Domain_Error{}
}

// Device_Info is the subset of a grant shown on the browser verify page. It
// deliberately EXCLUDES secrets (device_code, user_code, minted_token) and the
// owner/approver fields (not yet bound at verify time).
Device_Info :: struct {
	device_label: string,
	os:           string,
	app_version:  string,
	client:       string,
	request_ip:   string,
	requested_at: i64,
	// REQ-IMPL-2. Exposed so the approval page can run design §5.4.4's
	// cross-check: the browser encrypts to the key it read from the link
	// FRAGMENT and compares it against this, the Hub's copy. A mismatch means
	// the Hub is reporting a different key than the machine emitted — an attack
	// signal the UI must surface, not resolve. Still not a secret: the public
	// key and its fingerprint are both public by construction.
	bridge_public_key:      string, // host-asserted (submitted at authorize)
	bridge_key_fingerprint: string, // hub-computed from the key above
	os_user:                string, // host-asserted
	is_bridge_enrollment:   bool,
	bridge_identity_public_key:  string, // host-asserted persistent identity key
	bridge_identity_fingerprint: string, // hub-computed
	// server_time is the Hub's own clock reading at the moment it answered this
	// verify, in unix seconds -- the SAME units as requested_at, so the two are
	// directly subtractable.
	//
	// It exists because the approval screen needs a trustworthy "now" to show
	// the operator how stale the request is, and that is the check that catches
	// an approval screen opened from an old phishing link. Before this field the
	// screen used the BROWSER's clock under a heading promising the Hub had
	// measured it, so operator clock skew silently shifted the apparent age of
	// the request in either direction.
	//
	// It is deliberately read from the same `now` that verify already uses for
	// expiry and rate-limit math, not sampled a second time: the time the
	// operator is shown is then the very reading that decided this grant was
	// still alive.
	server_time:            i64, // hub-measured
	// Hub-blind pairing (bridge grants): the bridge's MAC over identity|ecdh|challenge
	// under its secret code, and the PKCE challenge it covers. The approver recomputes
	// the MAC with the code the operator typed; the hub cannot.
	pair_key_mac:           string,
	code_challenge:         string,
	pair_salt:              string,
	pair_hub_origin:        string,
	// REQ-BE-2: the RAW host-asserted hint, exactly as stored. Untrusted: the HTTP
	// layer must check it against the approving user before showing it to anyone.
	previous_bridge_id:     string,
}

// GENERIC_UNKNOWN_CODE_ERROR is the single error returned for an unknown,
// expired, OR otherwise-unverifiable code so callers cannot enumerate valid
// codes by distinguishing responses (ELDA-2). Terminal grants use a distinct
// 410/409 (AC5) since the acting user already knows the code was valid.
GENERIC_UNKNOWN_CODE_ERROR :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Not_Found, "invalid or expired code")
}

// verify resolves a grant by its short user_code and returns the device info
// captured at authorize time, for display on the browser confirm page.
//   - unknown code  -> Not_Found generic (no enumeration)
//   - expired code  -> Not_Found generic (no enumeration), grant evicted
//   - terminal code -> Gone (410) "code already used" (AC5)
//   - pending valid -> Device_Info (AC3)
// Caller MUST have already authenticated the approving user (handler enforces it).
verify :: proc(service: ^Device_Auth_Service, user_code: string) -> (Device_Info, bool, domain.Domain_Error) {
	return verify_with_ip(service, user_code, "")
}

// verify_with_ip adds ELDA-6 brute-force protection for the short user_code.
// The HTTP handler passes the trusted-XFF-resolved browser IP; service tests may
// call verify() directly when they do not need rate limiting.
verify_with_ip :: proc(service: ^Device_Auth_Service, user_code, request_ip: string) -> (Device_Info, bool, domain.Domain_Error) {
	now := service.clock.now()
	if request_ip != "" {
		sync.mutex_lock(&service.store.mutex)
		allowed := verify_rate_allow(service.store, request_ip, now)
		sync.mutex_unlock(&service.store.mutex)
		if !allowed do return Device_Info{}, false, domain.domain_error(.Rate_Limited, "too many device verification attempts from this IP")
	}
	device_code, grant, ok := grant_by_user_code(service.store, user_code)
	if !ok do return Device_Info{}, false, GENERIC_UNKNOWN_CODE_ERROR()
	if is_expired(grant, now) {
		// Evict quietly; report generic error (do not distinguish from unknown).
		sweep(service.store, now)
		return Device_Info{}, false, GENERIC_UNKNOWN_CODE_ERROR()
	}
	if grant.status != .Pending {
		// Terminal: the acting user already decided; reveal "already used" (AC5).
		return Device_Info{}, false, domain.domain_error(.Gone, "code already used")
	}
	_ = device_code
	return Device_Info{
		device_label = grant.device_label,
		os = grant.os,
		app_version = grant.app_version,
		client = grant.client,
		request_ip = grant.request_ip,
		requested_at = grant.requested_at,
		bridge_public_key = grant.bridge_public_key,
		bridge_key_fingerprint = grant.bridge_key_fingerprint,
		os_user = grant.os_user,
		is_bridge_enrollment = is_bridge_grant(grant),
		bridge_identity_public_key = grant.bridge_identity_public_key,
		bridge_identity_fingerprint = grant.bridge_identity_fingerprint,
		server_time = now,
		pair_key_mac = grant.pair_key_mac,
		code_challenge = grant.code_challenge,
		pair_salt = grant.pair_salt,
		pair_hub_origin = grant.pair_hub_origin,
		previous_bridge_id = grant.previous_bridge_id,
	}, true, domain.Domain_Error{}
}

// Pending_Bridge_Pair is one bridge pairing candidate: the public pair_salt and the
// canonical hub origin the bridge declared it bound into its stretch.
Pending_Bridge_Pair :: struct {
	pair_salt:       string,
	pair_hub_origin: string,
}

// pending_bridge_pair_salts lists the public pair_salt and declared hub origin of up
// to `limit` live, pending bridge grants, newest first (temp-allocated). An approver
// needs both before it can derive the lookup from the code it was given (pairing
// stretch, plan §1 "Pairing"). Bridge grants have no owner before approval, so the
// list is not per user; it reveals only random salts and the hub origins bridges used.
pending_bridge_pair_salts :: proc(service: ^Device_Auth_Service, limit: int) -> []Pending_Bridge_Pair {
	now := service.clock.now()
	Entry :: struct {
		pair: Pending_Bridge_Pair,
		at:   i64,
	}
	found := make([dynamic]Entry, 0, 8, context.temp_allocator)
	sync.mutex_lock(&service.store.mutex)
	for _, g in service.store.grants {
		if g.status != .Pending || is_expired(g, now) || !is_bridge_grant(g) || g.pair_salt == "" || g.pair_hub_origin == "" do continue
		append(&found, Entry{pair = {pair_salt = strings.clone(g.pair_salt, context.temp_allocator), pair_hub_origin = strings.clone(g.pair_hub_origin, context.temp_allocator)}, at = g.requested_at})
	}
	sync.mutex_unlock(&service.store.mutex)
	slice.sort_by(found[:], proc(a, b: Entry) -> bool { return a.at > b.at })
	out := make([dynamic]Pending_Bridge_Pair, 0, min(len(found), max(limit, 0)), context.temp_allocator)
	for e in found {
		if len(out) >= limit do break
		append(&out, e.pair)
	}
	return out[:]
}

// Approve_Input is the approve request body. owner_user_id is INTENTIONALLY
// absent: the owner is bound from Auth_Context only (ELDA-6); any client-
// supplied owner field in the raw body is ignored by the handler.
//
// target_bridge_id is the "attach to an existing bridge" choice the approving
// human makes on the approval page, for a .Bridge_Enrollment grant only. Empty
// (the default) means "mint a new bridge", today's only behavior. It is NOT an
// ownership assertion by itself — the bridge minter re-checks that the bound
// owner_user_id actually owns this bridge before touching it, the same way
// every other bridge-id-by-string input in this codebase is re-checked rather
// than trusted.
//
// sunset_bridge_id is the "register new and sunset this one" choice: the named bridge
// is revoked atomically with the new bridge's creation (never before it), so a
// refused or failed approval leaves it running. Mutually exclusive with
// target_bridge_id — an attach consumes no new slot, so there is nothing to sunset for.
Approve_Input :: struct {
	user_code:        string,
	approve:          bool,
	target_bridge_id: string,
	new_bridge_label: string,
	sunset_bridge_id: string,
	vault_approval:   Vault_Approval,
}

// approve records the user's terminal decision on a grant.
//   - owner_user_id is taken from Auth_Context ONLY (never the body) (ELDA-6/AC4)
//   - approver_ip via trusted-XFF, approver_ua from the request (ELDA-7/AC6)
//   - on approve, pre-mint the token via the task-3 minter and hold plaintext
//   - terminal grant -> Conflict (409) "code already used" (AC5)
//   - unknown/expired -> generic Not_Found (no enumeration)
approve :: proc(service: ^Device_Auth_Service, input: Approve_Input, owner_user_id, approver_ip, approver_ua: string, approver_username: string = "") -> (bool, domain.Domain_Error) {
	if input.user_code == "" do return false, GENERIC_UNKNOWN_CODE_ERROR()
	if strings.trim_space(input.target_bridge_id) != "" && strings.trim_space(input.new_bridge_label) != "" {
		return false, domain.domain_error(.Validation_Failed, "new_bridge_label is only valid when creating a new bridge")
	}
	if strings.trim_space(input.target_bridge_id) != "" && strings.trim_space(input.sunset_bridge_id) != "" {
		return false, domain.domain_error(.Validation_Failed, "sunset_bridge_id is only valid when creating a new bridge")
	}
	if len(strings.trim_space(input.new_bridge_label)) > 128 {
		return false, domain.domain_error(.Validation_Failed, "new_bridge_label must be 128 characters or fewer")
	}
	_, grant, ok := grant_by_user_code(service.store, input.user_code)
	if !ok do return false, GENERIC_UNKNOWN_CODE_ERROR()
	now := service.clock.now()
	if is_expired(grant, now) {
		sweep(service.store, now)
		return false, GENERIC_UNKNOWN_CODE_ERROR()
	}
	if grant.status != .Pending {
		return false, domain.domain_error(.Conflict, "code already used")
	}
	// Bind owner from Auth_Context ONLY (ELDA-6). Ignore any body owner field.
	grant.owner_user_id = owner_user_id
	grant.approver_username = approver_username
	grant.approver_ip = approver_ip
	grant.approver_ua = approver_ua
	grant.decided_at = now
	if input.approve {
		// Dispatch on the PERSISTED grant kind, decided at authorize. A `switch`
		// rather than an `if` so adding a third kind later is a compile error here
		// instead of a silent fall-through to the user-token minter.
		switch grant.grant_kind {
		case .Bridge_Enrollment:
			// REQ-IMPL-2: a bridge grant mints a PER-MACHINE, bridge-scoped
			// credential. It deliberately does NOT fall back to the user-token
			// minter when bridge_minter is nil: a user token with the machine as a
			// free-text label is exactly the identity confusion this task exists to
			// remove (design §11.3), so an unwired bridge minter is a hard failure.
			if service.bridge_minter == nil {
				return false, domain.domain_error(.Internal_Error, "bridge credential issuer is not configured")
			}
			mint, tok_ok := service.bridge_minter(service.bridge_minter_ctx, Bridge_Mint_Request{
				owner_user_id = owner_user_id, // from Auth_Context, never the body
				bridge_public_key = grant.bridge_public_key,
				bridge_key_fingerprint = grant.bridge_key_fingerprint,
				os_user = grant.os_user,
				device_label = grant.device_label,
				os = grant.os,
				app_version = grant.app_version,
				target_bridge_id = input.target_bridge_id,
				new_bridge_label = input.new_bridge_label,
				sunset_bridge_id = input.sunset_bridge_id,
				bridge_identity_public_key = grant.bridge_identity_public_key,
				vault_approval = input.vault_approval,
			})
			if !tok_ok {
				if mint.error.code != .None do return false, mint.error
				return false, domain.domain_error(.Internal_Error, "could not issue bridge credential")
			}
			// A minter that returns no bridge_id would leave the credential
			// unattributable, which defeats the point; refuse it.
			if mint.bridge_id == "" do return false, domain.domain_error(.Internal_Error, "bridge credential was issued without a bridge id")
			grant.minted_token = mint.access_token
			grant.minted_token_id = mint.bridge_id
			grant.minted_bridge_id = mint.bridge_id
			// REQ-IMPL-3: the refresh half rides on the grant exactly as the access
			// half does, and is handed over in the SAME single-use poll. Two
			// separate deliveries would mean a window where a bridge holds one
			// credential of the pair and cannot complete enrollment.
			grant.minted_refresh_token = mint.refresh_token
			grant.minted_expires_in = mint.expires_in
			grant.minted_refresh_expires_in = mint.refresh_expires_in
			grant.vault_delivery_expected = mint.vault_delivery_expected
		case .Unsupported:
			// Unreachable (authorize refuses these); never approve one.
			return false, domain.domain_error(.Validation_Failed, DEVICE_AUTH_USER_GRANT_REMOVED)
		}
		grant.status = .Approved
	} else {
		grant.status = .Denied
	}
	set_grant(service.store, grant.device_code, grant)
	return true, domain.Domain_Error{}
}

// approved_bridge_id returns the `brg_` a just-approved bridge grant was minted
// against, for the approver's own browser.
//
// REQ-IMPL-5 needs this because the vault key has to be delivered TO A SPECIFIC
// BRIDGE over the `bridge_unseal` relay, and until approval there is no bridge
// to address: the id is created by the minter during approve() and handed to the
// BRIDGE on its own /device/token poll. Without this the approving page would
// have no way to name the bridge it just authorised.
//
// It is a separate accessor rather than a third return value on approve()
// because every existing caller of approve() — the handler and the device-grant
// test suites in tests/ — would have to be rewritten to deliver one additive
// field. This reads the same stored value the poll path returns, so the two
// cannot disagree.
//
// The value is HUB-OBSERVED: the Hub minted it, the machine did not assert it.
// Returns ("", false) for a non-bridge grant, an unapproved grant, or an unknown
// code — callers must not treat an empty id as "the current bridge".
approved_bridge_id :: proc(service: ^Device_Auth_Service, user_code: string) -> (string, bool) {
	if user_code == "" do return "", false
	_, grant, ok := grant_by_user_code(service.store, user_code)
	if !ok do return "", false
	if grant.status != .Approved do return "", false
	if !is_bridge_grant(grant) do return "", false
	if grant.minted_bridge_id == "" do return "", false
	return grant.minted_bridge_id, true
}

// approved_bridge_identity_key returns the identity public key of an APPROVED bridge
// grant (what its vault directory entry was created from). Temp-allocated.
approved_bridge_identity_key :: proc(service: ^Device_Auth_Service, user_code: string) -> (string, bool) {
	if user_code == "" do return "", false
	_, grant, ok := grant_by_user_code(service.store, user_code)
	if !ok || grant.status != .Approved || !is_bridge_grant(grant) || grant.bridge_identity_public_key == "" do return "", false
	return strings.clone(grant.bridge_identity_public_key, context.temp_allocator), true
}

// Poll_Status is the device-poll response status (ELDA-3).
Poll_Status :: enum {
	Pending,
	Approved,
	Denied,
	Expired,
	Slow_Down,
	// REQ-IMPL-2: the presented code_verifier did not match the grant's PKCE
	// challenge (RFC 7636 §4.6 / RFC 6749 invalid_grant). Distinct from Denied
	// (the human refused) and from Expired (the window closed) because it means
	// the redeemer is not the process that started the flow.
	Invalid_Grant,
}

// Poll_Result is the /device/token response body shape (ELDA-3).
Poll_Result :: struct {
	status:       Poll_Status,
	approver_username: string,
	access_token: string, // plaintext token; only set on first approved poll
	token_id:     string, // token id; only set on first approved poll
	expires_in:   int,    // seconds until the grant's token/flow expires; 0 if n/a
	// REQ-IMPL-2: the `brg_` the credential is scoped to, for a bridge grant
	// only. Server-resolved at mint time — the bridge learns its own id here
	// rather than asserting one (design §7.3).
	bridge_id:    string,
	// REQ-IMPL-3: the refresh half of the pair, for a bridge grant only, handed
	// over in the same single-use poll as the access token. Empty for an ELDA
	// grant and for a legacy non-expiring credential.
	refresh_token: string,
	refresh_expires_in: int,
	// True only for a bridge grant whose approving owner has a stored vault
	// envelope. The enrolling process uses this to decide whether it must remain
	// connected for the encrypted unseal relay before restarting the service.
	vault_delivery_expected: bool,
	// The approving account, for a bridge grant only. The bridge pins it as its
	// enrolled owner and refuses any keyring for another user (plan §1, C1).
	owner_user_id: string,
}

// poll implements the device token-poll lifecycle (ELDA-3):
//   - unknown device_code  -> Pending  (anti-enumeration: NOT 404)
//   - too-fast poll (< interval since last poll) -> Slow_Down (handler: 429 + Retry-After)
//   - approved grant       -> hand out the pre-minted plaintext token ONCE, then
//                             mark the grant Used; subsequent polls -> Expired
//   - denied grant         -> Denied
//   - expired/used grant   -> Expired
//   - pending grant        -> Pending
// `request_ip` is used for the per-IP poll rate limit (distinct from authorize).
// `code_verifier` is the PKCE proof (REQ-IMPL-2). It is REQUIRED when, and only
// when, the grant carries a code_challenge — so the pre-existing Electron poll,
// which sends none, is unaffected, while a bridge grant cannot be redeemed by
// anything but the process that started it.
poll :: proc(service: ^Device_Auth_Service, device_code, request_ip: string, code_verifier: string = "") -> (Poll_Result, domain.Domain_Error) {
	now := service.clock.now()
	// Per-IP poll rate limit (separate bucket from authorize). Checked first so
	// a flood of polls cannot pin the mutex. Returns Slow_Down + Rate_Limited.
	sync.mutex_lock(&service.store.mutex)
	poll_allowed := poll_rate_allow(service.store, request_ip, now)
	sync.mutex_unlock(&service.store.mutex)
	if !poll_allowed {
		return Poll_Result{status = .Slow_Down}, domain.domain_error(.Rate_Limited, "slow_down")
	}
	grant, ok := get_grant(service.store, device_code)
	if !ok {
		// Anti-enumeration: unknown device_code looks exactly like a pending grant.
		return Poll_Result{status = .Pending}, domain.Domain_Error{}
	}
	// Expired TTL -> Expired, but ONLY for a grant nobody ever decided.
	//
	// This used to run unconditionally, before the status switch below, which
	// meant an ALREADY-APPROVED grant still got reported Expired the instant
	// `now` crossed the original authorize-time deadline -- even though a
	// human had successfully approved it moments earlier (device_auth.approve
	// has its own, independent is_expired check, and once that passes the
	// approval is real and the token is minted; the clock bounds how long an
	// UNDECIDED request may sit around, not how long a decided one has left
	// to be delivered to the one process polling for it).
	//
	// Observed in production: a human approving near the end of the window
	// saw the UI say "Approved — the machine should connect", while the
	// bridge's very next poll (its loop sleeps `interval` seconds between
	// polls) landed moments later, now() had ticked past expires_at, and this
	// check fired before the status switch ever looked at grant.status ==
	// .Approved -- reporting Expired for a grant that had, in fact, just been
	// approved. Gating on .Pending here means a decided grant (Approved,
	// Denied, or already Used/Expired) always falls through to the switch
	// below, which is the one place that actually knows what happened to it.
	if grant.status == .Pending && is_expired(grant, now) {
		set_grant_status(service.store, device_code, .Expired, &grant)
		return Poll_Result{status = .Expired}, domain.Domain_Error{}
	}
	// Terminal grants are not subject to slow_down; replaying a used grant must
	// return expired immediately to enforce single-use (ELDA-3/AC3).
	#partial switch grant.status {
	case .Denied:
		return Poll_Result{status = .Denied}, domain.Domain_Error{}
	case .Used, .Expired:
		grant.minted_token = ""
		set_grant(service.store, device_code, grant)
		return Poll_Result{status = .Expired}, domain.Domain_Error{}
	case:
	}
	interval := service.store.config.interval
	if interval <= 0 do interval = 5
	if grant.last_poll_at > 0 && now - grant.last_poll_at < i64(interval) {
		return Poll_Result{status = .Slow_Down}, domain.domain_error(.Rate_Limited, "slow_down")
	}
	// Record this accepted pending/approved poll for slow_down gating on the NEXT call.
	grant.last_poll_at = now
	#partial switch grant.status {
	case .Approved:
		// PKCE (RFC 7636 §4.6), checked BEFORE the single-use consumption below:
		// a wrong verifier must not burn the grant, or anyone holding the
		// device_code could deny the real bridge its credential by polling once
		// with garbage. The grant stays Approved and the legitimate bridge's next
		// poll still succeeds.
		if grant.code_challenge != "" && !pkce_verifier_matches(grant.code_challenge, code_verifier) {
			// Persist last_poll_at anyway so a verifier-guessing loop is still
			// subject to the per-grant interval gate, not just the per-IP bucket.
			set_grant(service.store, device_code, grant)
			return Poll_Result{status = .Invalid_Grant}, domain.domain_error(.Unauthenticated, "invalid_grant: code_verifier does not match the PKCE challenge")
		}
		// Single-use: hand out the token, then mark Used so the next poll is Expired.
		token := grant.minted_token
		tid := grant.minted_token_id
		refresh := grant.minted_refresh_token
		minted_expires_in := grant.minted_expires_in
		minted_refresh_expires_in := grant.minted_refresh_expires_in
		grant.status = .Used
		grant.minted_token = ""
		// The refresh plaintext is dropped from the grant for the same reason the
		// access plaintext is: once handed over it must not be re-servable, and the
		// grant lives in memory for the rest of its TTL.
		grant.minted_refresh_token = ""
		set_grant(service.store, device_code, grant)
		if token == "" {
			// No pre-minted token (minter not wired). Surface as Pending so the
			// device keeps polling until task-3 lazy mint supplies one; do NOT
			// mark Used. (Approved-without-token is a wiring gap, not a terminal.)
			grant.status = .Approved
			grant.minted_refresh_token = refresh
			set_grant(service.store, device_code, grant)
			return Poll_Result{status = .Pending}, domain.Domain_Error{}
		}
		// expires_in is the CREDENTIAL's lifetime when the minter supplied one, and
		// falls back to the grant/flow expiry otherwise. Those are different clocks
		// and conflating them is how a bridge ends up scheduling its refresh off the
		// 900-second device-code window.
		expires_in := minted_expires_in if minted_expires_in > 0 else service.store.config.expires_in
		return Poll_Result{status = .Approved, approver_username = grant.approver_username, access_token = token, token_id = tid, bridge_id = grant.minted_bridge_id, expires_in = expires_in, refresh_token = refresh, refresh_expires_in = minted_refresh_expires_in, vault_delivery_expected = grant.vault_delivery_expected, owner_user_id = grant.owner_user_id if grant.minted_bridge_id != "" else ""}, domain.Domain_Error{}
	case: // .Pending (covers Pending only; exhaustiveness)
		set_grant(service.store, device_code, grant)
	}
	return Poll_Result{status = .Pending}, domain.Domain_Error{}
}

// set_grant_status is a thin helper used by poll to update status + fields.
set_grant_status :: proc(store: ^Grant_Store, device_code: string, status: Grant_Status, grant: ^Grant) {
	grant.status = status
	set_grant(store, device_code, grant^)
}

// rate_check applies the per-IP verify budget (verify_rate_allow) from outside the
// package. Pending vault-device codes share the "verify:" budget with bridge codes, so
// brute force is bounded across both code namespaces; registration uses its own.
rate_check :: proc(service: ^Device_Auth_Service, namespace, request_ip: string) -> bool {
	if request_ip == "" do return true
	key := strings.concatenate({namespace, request_ip}, context.temp_allocator)
	sync.mutex_lock(&service.store.mutex)
	defer sync.mutex_unlock(&service.store.mutex)
	return verify_rate_allow(service.store, key, service.clock.now())
}

// verify_rate_allow enforces per-IP brute-force protection for the short
// user_code. It uses its own key namespace so authorize/token budgets are
// independent. MUST be called under the store mutex.
verify_rate_allow :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true
	if store.config.rate_limit <= 0 do return true
	key := strings.concatenate({"verify:", ip})
	defer delete(key)
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	entry, has := store.rate[key]
	if !has || now - entry.window_start >= window {
		store.rate[strings.clone(key, runtime.heap_allocator())] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= store.config.rate_limit do return false
	entry.count += 1
	store.rate[key] = entry
	return true
}

// poll_rate_allow enforces a per-IP poll rate limit using the store's rate map
// under a `poll:` key namespace, so it is independent of the authorize budget.
// Conservative default: 60 polls/min/IP (one every second) — well above the
// device's nominal interval but stops a single IP from hammering the endpoint.
poll_rate_allow :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true
	key := strings.concatenate({"poll:", ip})
	defer delete(key)
	limit := 60
	window := 60
	if store.config.rate_limit > 0 {
		// Reuse the configured rate_limit as the poll budget too (per window).
		limit = store.config.rate_limit * 6
	}
	entry, has := store.rate[key]
	if !has || now - entry.window_start >= i64(window) {
		// Map string keys keep the string header/data; clone the temporary key on
		// insertion so the stored key remains valid after this proc returns.
		store.rate[strings.clone(key, runtime.heap_allocator())] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= limit do return false
	entry.count += 1
	store.rate[key] = entry
	return true
}
