// Expiring bridge credentials: issue, verify, rotate, revoke (REQ-IMPL-3,
// REQ-ENROLL-13, design §7.2/§7.4/§7.5).
//
// WHAT THIS REPLACES. Audit finding F3: the `hbr_` bridge token never expired and
// never rotated, so a credential read once from a disk or a database was good
// forever. A device-enrolled bridge now receives a PAIR:
//
//   hba_<token_id>.<secret>   access   1 hour,  presented on every WS connect / API call
//   hbf_<token_id>.<secret>   refresh  30 days sliding, presented ONLY to the refresh
//                                      endpoint, single-use, rotated on every use
//
// Both are minted by `issue_credential` (REQ-IMPL-1, settled 7) — 256-bit CSPRNG
// secret, stored as `sha256:v1:<salt>:<digest>`, verified with a constant-time
// compare over the whole stored string. Nothing here derives a secret from
// `platform.generate_id`, which is prefix + unix-nanoseconds; `generate_id` is used
// only for the non-secret `btk_` row id and `bfam_` family id.
//
// THE THREE PROPERTIES THIS FILE EXISTS TO HOLD, each with a test named after it:
//
//  1. EXPIRY IS ENFORCED ON THE VALIDATION PATH, not merely recorded. An `hba_`
//     past its expiry authenticates nothing, whatever the bridge row says.
//  2. ROTATION IS SINGLE-USE AND REUSE IS TREATED AS THEFT. Presenting a refresh
//     token that was already spent revokes the ENTIRE FAMILY — every generation,
//     both kinds — and forces re-enrollment (§7.4.3). This is the control that
//     turns refresh-token theft from silent persistent access into a loud,
//     self-limiting event, and it is the reason a spent row is kept rather than
//     deleted: a deleted row makes a replay look like an unknown token.
//  3. THE EXISTENCE ORACLE STAYS SHUT TO THE SAME DEGREE REQ-IMPL-1 LEFT IT.
//     Every lookup miss on this path burns the same salted hash and constant-time
//     compare a hit would, via `verify_credential_miss`, and returns the identical
//     error. Settled 6. Read verify_credential_miss's own header before changing
//     any miss path here — the protection is conditional on that proc allocating.
//
// WHAT IT DOES NOT DEFEND AGAINST, stated plainly because REQ-ENROLL-8 requires it
// and because the narrower claim is the honest one:
//   - The DATABASE HALF of the existence oracle. A miss skips a successful SQLite
//     fetch and column decode that a hit performs, which is plausibly a larger
//     timing signal than the hash this equalises. A local attacker with timing
//     precision may still distinguish a known `token_id` from an unknown one. The
//     oracle is NARROWED, NOT CLOSED, exactly as REQ-IMPL-1 left it.
//   - A STOLEN ACCESS TOKEN inside its hour. Expiry bounds the damage; it does not
//     detect the theft. Only the refresh token's rotation does that.
//   - A SAME-UID COMPROMISE of the bridge host, which reads both tokens from memory
//     or the keyring (threat T1).
package bridge

import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// ACCESS/REFRESH prefixes. Distinct prefixes are not cosmetic: they are what makes
// "a refresh token presented as an access token" a parse failure rather than a
// lookup that happens to find the wrong kind of row. The kind is ALSO checked
// against the stored row (see verify_access_token / refresh_bridge_token), because
// a prefix is attacker-supplied and a row's kind is not.
ACCESS_TOKEN_PREFIX :: "hba_"
REFRESH_TOKEN_PREFIX :: "hbf_"

// ===== LIFETIMES, AND WHY THESE NUMBERS (design §7.2, task scope item 1) =====
//
// ACCESS = 1 HOUR. This is the direct answer to F3. The access token is the one
// presented constantly — every WS connect, every Hub API call — so it is the one
// most likely to be captured from a log, a proxy, a core dump or a disk image, and
// the only cheap control over a bearer credential is how long a captured copy
// remains useful. One hour is short enough that a stolen access token is an
// incident rather than a tenancy, and long enough that refresh traffic stays
// negligible: at 80% proactive refresh (§7.5) one bridge refreshes ~20 times a day,
// so even a thousand-bridge fleet is ~20k refreshes/day — nothing. Going shorter
// (5-10 min, as some OAuth deployments do) buys little here because the refresh
// token, not the access token, is the real long-lived secret, and it would multiply
// the one request that cannot be served from the bridge's cache.
//
// REFRESH = 30 DAYS SLIDING. The refresh token must outlive a bridge being powered
// off over a holiday; a machine that comes back after two weeks must reconnect
// without a human at a browser. Sliding (re-based on every rotation) means an
// actively-used bridge never re-enrolls, while an abandoned one ages out.
//
// FAMILY CAP = 365 DAYS ABSOLUTE. Sliding expiry alone means a credential used
// often never expires, which is how a machine decommissioned-but-still-running
// keeps access indefinitely. The cap is copied forward unchanged through every
// rotation, so it is a true ceiling and not another sliding window; reaching it
// requires re-enrollment, i.e. a human approving in a browser again.
BRIDGE_ACCESS_TOKEN_TTL_SECONDS :: 3600
BRIDGE_REFRESH_TOKEN_TTL_SECONDS :: 2592000
BRIDGE_TOKEN_FAMILY_MAX_SECONDS :: 31536000

// BRIDGE_TOKEN_CLOCK_SKEW_SECONDS is the grace added to every expiry comparison on
// the Hub side (task scope item 6: "a headless box with bad time must not brick
// itself").
//
// BE PRECISE ABOUT WHOSE CLOCK IS AT RISK, because the obvious reading is wrong.
// The Hub computes `expires_at` from its own clock and compares it against its own
// clock, so Hub-side skew cancels out entirely and this grace does nothing for it.
// The machine with the bad clock is the BRIDGE, and the structural fix is not a
// tolerance at all: the Hub returns `expires_in` as a DURATION, never an absolute
// timestamp, so a bridge schedules refresh off a monotonic timer and its wall clock
// never enters the decision. A bridge with a clock set to 1970 still refreshes
// correctly. That contract is REQ-IMPL-4's to implement and is posted as a task
// comment.
//
// What the 60s grace IS for: the boundary itself. A refresh that is in flight when
// the access token expires, or a request that crosses the second its expiry falls
// on, must not hard-fail; and the hub's timestamps have one-second resolution
// (format_rfc3339_utc), so a comparison at the edge is genuinely ambiguous. 60s is
// large enough to cover an in-flight request plus a retry and small enough that it
// does not meaningfully extend a stolen token's life (1h becomes 1h0m60s).
BRIDGE_TOKEN_CLOCK_SKEW_SECONDS :: 60

// BRIDGE_REFRESH_REUSE_GRACE_SECONDS implements design §7.4.4 and it is the one
// deliberate hole in reuse detection, so it is documented as a hole rather than as a
// feature.
//
// THE PROBLEM IT SOLVES. Rotation is two writes on two machines: the Hub marks the
// old refresh token spent and returns a new one, then the bridge persists the new
// one. A power cut between those leaves a bridge holding a token the Hub considers
// spent — and under strict reuse detection its next refresh revokes the family, so a
// power cut at the wrong instant BRICKS the machine and needs a human at a browser.
// A two-phase commit is not available: the bridge cannot promise to persist.
//
// THE TRADE, stated honestly. For 30 seconds after a rotation, the
// immediately-previous refresh token is accepted ONE more time. An attacker who
// steals a refresh token and replays it inside that window therefore gets a working
// pair instead of being detected. What they do not get is silence: the orphaned
// generation is revoked, so the legitimate bridge's next refresh presents a revoked
// token and the family dies loudly. Detection is preserved for every generation but
// the newest, and for all but 30 seconds of that one.
BRIDGE_REFRESH_REUSE_GRACE_SECONDS :: 30

// BRIDGE_REFRESH_RETRY_GRACE_SECONDS bounds the SECOND, narrower hole: a retry of
// one exact rotation, identified by the request id the bridge sent with it
// (BRIDGE_REFRESH_REQUEST_ID_HEADER), whose reply was lost.
//
// WHY IT EXISTS. The 30-second grace above assumes the retry comes at once. A lost
// reply does not work like that: the bridge backs off, may be restarted (an update,
// a crash), and only then retries. Past 30s its retry used to be read as theft and
// revoked the family, or, before the bridge retried at all, it parked forever. Either
// way the machine needed a human (incident, 2026-10-25).
//
// WHAT BOUNDS IT, all required:
//   - the presented token was spent by a request carrying THIS request id (its salted
//     digest is on the spent row; the id is 128 random bits, sent only with the
//     token, and never logged);
//   - at most 10 minutes since that spend;
//   - no descendant refresh token has been redeemed, i.e. the pair minted for the
//     lost reply was demonstrably never used. Once any descendant is used, the old
//     token is plain reuse again.
// Every grant revokes the never-used descendants (both kinds), so a graced retry
// never leaves two live generations; and a replay with the wrong or no request id,
// or after the window, or of an older token, still revokes the family.
BRIDGE_REFRESH_RETRY_GRACE_SECONDS :: 600

// BRIDGE_REFRESH_REQUEST_ID_HEADER carries the bridge's per-rotation request id.
BRIDGE_REFRESH_REQUEST_ID_HEADER :: "X-Heimdall-Refresh-Request-Id"

// refresh_request_id_valid: 32-128 chars of [A-Za-z0-9_-] (the bridge sends `rrq_`
// + 32 hex, 128 random bits). Anything else is ignored
// (treated as absent), never an error, so a malformed header cannot change a
// refresh that would otherwise succeed.
refresh_request_id_valid :: proc(id: string) -> bool {
	if len(id) < 32 || len(id) > 128 do return false
	for c in transmute([]byte)id {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') do return false
	}
	return true
}

// Bridge_Token_Pair is what a mint or a rotation hands back. The two plaintexts
// exist ONLY in this value and in the response built from it — the Hub stores
// salted digests and can never reproduce them, which is why a rotation cannot
// "re-send the current pair" and the grace window above mints a new generation
// instead.
//
// expires_in / refresh_expires_in are DURATIONS IN SECONDS, deliberately not
// timestamps. See BRIDGE_TOKEN_CLOCK_SKEW_SECONDS.
Bridge_Token_Pair :: struct {
	access_token:       string,
	refresh_token:      string,
	bridge_id:          string,
	family_id:          string,
	generation:         int,
	expires_in:         int,
	refresh_expires_in: int,
}

BRIDGE_TOKEN_SCOPE :: "bridge:runtime"

// BRIDGE_ENROLL_TOKEN_SCOPE marks a PENDING enrollment's credential (REQ-EA-1): the
// family a bridge receives on approval while its vault key has not been delivered.
// It authenticates exactly one thing — the enroll-only WebSocket the vault key is
// relayed over (verify_enroll_access_token) — and nothing else: verify_access_token
// and refresh_bridge_token both fail closed on any scope other than
// BRIDGE_TOKEN_SCOPE. The hub promotes the family to BRIDGE_TOKEN_SCOPE when it
// observes the delivery succeed (REQ-EA-2), or revokes it on rollback (REQ-EA-3).
BRIDGE_ENROLL_TOKEN_SCOPE :: "bridge:enroll"

// BRIDGE_ENROLL_PENDING_SECONDS is how long an approved enrollment may wait for its
// vault key before the hub rolls it back (REQ-EA-3). Matches the bridge's own wait
// (BRIDGE_ENROLL_VAULT_WAIT_SECONDS) so neither side gives up while the other waits.
BRIDGE_ENROLL_PENDING_SECONDS :: 300

// issue_bridge_token_pair mints generation 0 of a new family for a freshly enrolled
// bridge. Called from the device-grant enrollment path; this is the ONLY place a
// family begins.
//
// Fails closed on entropy failure with `.Provider_Unavailable` (503) and a retry
// hint, per settled 8 — never a weaker credential, never `.Internal_Error`.
issue_bridge_token_pair :: proc(service: ^Bridge_Service, bridge_id: string, scope := BRIDGE_TOKEN_SCOPE) -> (Bridge_Token_Pair, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return Bridge_Token_Pair{}, false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if bridge_id == "" do return Bridge_Token_Pair{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	now := platform.clock_now(service.clock)
	family_expires_at, cap_ok := platform.expires_at_after_seconds_from(now, BRIDGE_TOKEN_FAMILY_MAX_SECONDS)
	if !cap_ok do return Bridge_Token_Pair{}, false, domain.domain_error(.Internal_Error, "could not derive a credential lifetime from the hub clock")
	family_id := platform.generate_id(service.ids, "bfam_")
	return mint_generation(service, bridge_id, family_id, 0, family_expires_at, now, scope)
}

// mint_generation writes one generation of a family: an access row and a refresh
// row, both fresh credentials, and returns the two plaintexts.
//
// EITHER-BOTH-OR-NEITHER is not achievable here — the repository has no transaction
// seam — so the ORDER is chosen to fail safe: the REFRESH row is written first and
// the access row second. A crash between them leaves a bridge that cannot
// authenticate (its access token was never stored) but CAN refresh, which recovers
// on the bridge's next refresh. The reverse order would leave a bridge that
// authenticates for an hour and can never renew, i.e. a machine that silently dies
// later instead of immediately.
mint_generation :: proc(service: ^Bridge_Service, bridge_id, family_id: string, generation: int, family_expires_at, now: string, scope := BRIDGE_TOKEN_SCOPE) -> (Bridge_Token_Pair, bool, domain.Domain_Error) {
	pair, refresh_row, access_row, ok, err := prepare_generation(service, bridge_id, family_id, generation, family_expires_at, now, scope)
	if !ok do return Bridge_Token_Pair{}, false, err
	_, rsave_ok, rsave_err := iface.bridge_save_token(service.repo, refresh_row)
	if !rsave_ok do return Bridge_Token_Pair{}, false, rsave_err
	_, asave_ok, asave_err := iface.bridge_save_token(service.repo, access_row)
	if !asave_ok do return Bridge_Token_Pair{}, false, asave_err
	return pair, true, domain.Domain_Error{}
}

// prepare_generation issues the two credentials of one generation and builds their
// rows without writing anything; the caller persists them (mint_generation, or the
// atomic re-grant in rotate_from).
prepare_generation :: proc(service: ^Bridge_Service, bridge_id, family_id: string, generation: int, family_expires_at, now: string, scope := BRIDGE_TOKEN_SCOPE) -> (pair: Bridge_Token_Pair, refresh_row, access_row: domain.Bridge_Token, ok: bool, err: domain.Domain_Error) {
	access_expires_at, a_ok := platform.expires_at_after_seconds_from(now, BRIDGE_ACCESS_TOKEN_TTL_SECONDS)
	refresh_expires_at, r_ok := platform.expires_at_after_seconds_from(now, BRIDGE_REFRESH_TOKEN_TTL_SECONDS)
	if !a_ok || !r_ok do return {}, {}, {}, false, domain.domain_error(.Internal_Error, "could not derive a credential lifetime from the hub clock")
	// The sliding refresh window is CAPPED by the family's absolute ceiling, so a
	// long-lived family does not slide past its own cap one rotation at a time.
	// String comparison is correct for this format: format_rfc3339_utc is
	// fixed-width, zero-padded and UTC, so lexical order IS chronological order —
	// the same property every expiry comparison in this file relies on.
	if family_expires_at != "" && refresh_expires_at > family_expires_at do refresh_expires_at = family_expires_at

	refresh_token_id := platform.generate_id(service.ids, "btk_")
	refresh_token, refresh_hash, refresh_ok := issue_credential(REFRESH_TOKEN_PREFIX, refresh_token_id)
	if !refresh_ok do return {}, {}, {}, false, domain.domain_error(.Provider_Unavailable, "secure random source unavailable; no bridge credential was issued, retry")
	access_token_id := platform.generate_id(service.ids, "btk_")
	access_token, access_hash, access_ok := issue_credential(ACCESS_TOKEN_PREFIX, access_token_id)
	if !access_ok do return {}, {}, {}, false, domain.domain_error(.Provider_Unavailable, "secure random source unavailable; no bridge credential was issued, retry")
	refresh_row = domain.Bridge_Token{
		token_id = refresh_token_id, bridge_id = bridge_id, kind = .Refresh, token_hash = refresh_hash,
		family_id = family_id, generation = generation, scope = scope, issued_at = now,
		expires_at = refresh_expires_at, family_expires_at = family_expires_at,
	}
	access_row = domain.Bridge_Token{
		token_id = access_token_id, bridge_id = bridge_id, kind = .Access, token_hash = access_hash,
		family_id = family_id, generation = generation, scope = scope, issued_at = now,
		expires_at = access_expires_at, family_expires_at = family_expires_at,
	}
	pair = Bridge_Token_Pair{
		access_token = access_token,
		refresh_token = refresh_token,
		bridge_id = bridge_id,
		family_id = family_id,
		generation = generation,
		expires_in = BRIDGE_ACCESS_TOKEN_TTL_SECONDS,
		refresh_expires_in = seconds_until(now, refresh_expires_at),
	}
	return pair, refresh_row, access_row, true, domain.Domain_Error{}
}

// seconds_until is `expires_at - now` in whole seconds, floored at 0. Used only to
// report a DURATION to the bridge; a value that cannot be parsed yields 0, which a
// bridge must treat as "refresh now" rather than "never expires".
seconds_until :: proc(now, expires_at: string) -> int {
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now)
	exp_ms, exp_ok := platform.rfc3339_to_unix_ms(expires_at)
	if !now_ok || !exp_ok do return 0
	if exp_ms <= now_ms do return 0
	return int((exp_ms - now_ms) / 1000)
}

// token_is_expired compares a row's expiry against `now` with the skew grace.
//
// An EMPTY expires_at is treated as EXPIRED, not as "never expires". That is the
// fail-closed direction and it matters: '' is what a row gets if a future writer
// forgets the column, and the alternative reading would silently resurrect exactly
// the never-expiring credential F3 is about.
token_is_expired :: proc(expires_at, now: string) -> bool {
	if expires_at == "" do return true
	if now == "" do return false
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now)
	exp_ms, exp_ok := platform.rfc3339_to_unix_ms(expires_at)
	if !exp_ok do return true
	// An unparseable `now` means the hub's own clock string is broken. Refusing to
	// judge is the safer answer than treating every credential as expired, which
	// would lock out the whole fleet over a formatting bug.
	if !now_ok do return false
	return now_ms > exp_ms + i64(BRIDGE_TOKEN_CLOCK_SKEW_SECONDS) * 1000
}

// verify_access_token authenticates an `hba_` token and resolves it to its bridge.
//
// ERROR SHAPE IS DELIBERATE. Every failure that could reveal whether a `token_id`
// exists returns the SAME `.Unauthenticated` "bridge token is invalid" and runs the
// same hash+compare (settled 6). Two states return something different ON PURPOSE,
// because they are states the holder of a VALID credential has already proven they
// may learn, and the bridge must distinguish them to behave correctly (§7.5):
//   - EXPIRED -> `.Unauthenticated` "bridge access token has expired": the bridge
//     refreshes and retries once.
//   - REVOKED -> `.Forbidden` "bridge credential is revoked": the bridge stops and
//     surfaces re-enrollment. Telling a revoked bridge to keep refreshing is how a
//     revoked fleet becomes a self-inflicted DoS.
verify_access_token :: proc(service: ^Bridge_Service, token: string) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	auth, _, ok, err := verify_access_token_scoped(service, token, BRIDGE_TOKEN_SCOPE)
	return auth, ok, err
}

// verify_enroll_access_token authenticates a PENDING enrollment's credential and
// nothing else (REQ-EA-1). Only the bridge WS upgrade calls it, to admit the
// enroll-only socket the vault key is relayed over. Returns the family id so the
// commit and the rollback act on exactly the lineage that was approved.
verify_enroll_access_token :: proc(service: ^Bridge_Service, token: string) -> (auth: contracts.Auth_Context, family_id: string, ok: bool, err: domain.Domain_Error) {
	return verify_access_token_scoped(service, token, BRIDGE_ENROLL_TOKEN_SCOPE)
}

// verify_access_token_scoped is verify_access_token's body with the required scope as
// a parameter. The scope check FAILS CLOSED: a row whose scope is not exactly the one
// asked for does not authenticate, so a pending credential can never reach a path
// that calls verify_access_token, and an unknown future scope reaches none.
verify_access_token_scoped :: proc(service: ^Bridge_Service, token: string, scope: string) -> (contracts.Auth_Context, string, bool, domain.Domain_Error) {
	invalid := domain.domain_error(.Unauthenticated, "bridge token is invalid")
	token_id, presented_secret, split_ok := split_credential(ACCESS_TOKEN_PREFIX, token)
	if !split_ok do return contracts.Auth_Context{}, "", false, invalid
	row, ok, _ := iface.bridge_get_token(service.repo, token_id)
	if !ok {
		// Not an early return: burn the same work a wrong secret would. See
		// verify_credential_miss, and read its header before touching this.
		_ = verify_credential_miss(presented_secret)
		return contracts.Auth_Context{}, "", false, invalid
	}
	// Check the STORED kind, not just the prefix the caller sent. A refresh row
	// reached through an `hba_` prefix must not authenticate anything: the two have
	// different authority, and this is the privilege-confusion check that a
	// prefix-only test would miss.
	if row.kind != .Access {
		_ = verify_credential_miss(presented_secret)
		return contracts.Auth_Context{}, "", false, invalid
	}
	if !verify_credential(row.token_hash, presented_secret) do return contracts.Auth_Context{}, "", false, invalid
	// Checked after the secret, like kind: the scope is not secret, but a mismatch
	// must look exactly like a wrong token rather than confirm the row exists.
	if row.scope != scope do return contracts.Auth_Context{}, "", false, invalid
	if row.revoked_at != "" {
		if credential_revocation_is_recoverable(service, row.token_id) do return {}, "", false, pending_sunset_error()
		return {}, "", false, revoked_credential_error("bridge credential is revoked")
	}
	now := platform.clock_now(service.clock)
	if token_is_expired(row.expires_at, now) do return contracts.Auth_Context{}, "", false, domain.domain_error(.Unauthenticated, "bridge access token has expired")
	if row.family_expires_at != "" && token_is_expired(row.family_expires_at, now) {
		return contracts.Auth_Context{}, "", false, domain.domain_error(.Forbidden, "bridge credential has reached its maximum lifetime; re-enrollment is required")
	}
	bridge, bridge_ok, _ := iface.bridge_get_bridge(service.repo, row.bridge_id)
	if !bridge_ok do return contracts.Auth_Context{}, "", false, invalid
	// A revoked BRIDGE and a revoked TOKEN are two separate records and both are
	// checked: revoke_bridge stamps both, but a token row written before that change
	// (or by a future path that forgets) must not outlive its bridge.
	if bridge.status == .Revoked {
		if credential_revocation_is_recoverable(service, row.token_id) do return {}, "", false, pending_sunset_error()
		return {}, "", false, revoked_credential_error("bridge is revoked")
	}
	// First authentication with this access token: record it. It proves the reply
	// that carried the token was delivered, which ends the retry grace of the
	// refresh token it was minted from (family_descendant_delivered). Once per
	// token; the steady state reads the stamp and writes nothing.
	if row.first_used_at == "" do _, _ = iface.bridge_mark_token_used(service.repo, row.token_id, now)
	return contracts.Auth_Context{kind = .Bridge_Token, user_id = string(bridge.owner_user_id), bridge_id = bridge.bridge_id}, row.family_id, true, domain.Domain_Error{}
}

// Session_Credential is what a live bridge session is bound to: the token row that
// authenticated it and how long, from now on the hub clock, it keeps
// authenticating. The bridge WebSocket checks it for the whole session (expiry) and
// re-reads the row periodically (revocation); see bridge_ws_runtime_loop.
Session_Credential :: struct {
	token_id:     string, // temp-allocated
	valid_for_ms: i64,
}

// access_token_session_credential resolves an ALREADY VERIFIED `hba_` token to its
// session bound. valid_for_ms runs to the same instant verify_access_token stops
// accepting it: expires_at plus the clock-skew grace, never past the family cap.
access_token_session_credential :: proc(service: ^Bridge_Service, token: string) -> (Session_Credential, bool) {
	if service == nil || service.repo == nil do return {}, false
	token_id, _, split_ok := split_credential(ACCESS_TOKEN_PREFIX, token)
	if !split_ok do return {}, false
	row, ok, _ := iface.bridge_get_token(service.repo, token_id)
	if !ok || row.kind != .Access do return {}, false
	defer domain.bridge_token_destroy(&row)
	now_ms, now_ok := platform.rfc3339_to_unix_ms(platform.clock_now(service.clock))
	exp_ms, exp_ok := platform.rfc3339_to_unix_ms(row.expires_at)
	if !now_ok || !exp_ok do return {}, false
	until := exp_ms + i64(BRIDGE_TOKEN_CLOCK_SKEW_SECONDS) * 1000
	if row.family_expires_at != "" {
		if cap_ms, cap_ok := platform.rfc3339_to_unix_ms(row.family_expires_at); cap_ok {
			until = min(until, cap_ms + i64(BRIDGE_TOKEN_CLOCK_SKEW_SECONDS) * 1000)
		}
	}
	return Session_Credential{token_id = strings.clone(token_id, context.temp_allocator), valid_for_ms = until - now_ms}, true
}

// Session_Credential_State is the outcome of re-checking a live session's token row.
Session_Credential_State :: enum {
	Valid,
	Pending_Sunset,
	Revoked,
	Expired,
}

// session_credential_state re-reads a live session's token row: revoked (token,
// family or bridge) or expired by the hub clock ends the session. A row that has
// vanished is treated as revoked.
session_credential_state :: proc(service: ^Bridge_Service, token_id: string) -> Session_Credential_State {
	if service == nil || service.repo == nil || token_id == "" do return .Revoked
	row, ok, _ := iface.bridge_get_token(service.repo, token_id)
	if !ok do return .Revoked
	defer domain.bridge_token_destroy(&row)
	if row.revoked_at != "" {
		if credential_revocation_is_recoverable(service, token_id) do return .Pending_Sunset
		return .Revoked
	}
	bridge, bridge_ok, _ := iface.bridge_get_bridge(service.repo, row.bridge_id)
	if !bridge_ok do return .Revoked
	defer domain.bridge_destroy(&bridge)
	if bridge.status == .Revoked {
		if credential_revocation_is_recoverable(service, token_id) do return .Pending_Sunset
		return .Revoked
	}
	now := platform.clock_now(service.clock)
	// token_is_expired applies BRIDGE_TOKEN_CLOCK_SKEW_SECONDS, exactly as
	// verify_access_token does, so the re-check never ends a session that verify
	// would still accept.
	if token_is_expired(row.expires_at, now) do return .Expired
	if row.family_expires_at != "" && token_is_expired(row.family_expires_at, now) do return .Expired
	return .Valid
}

// refresh_bridge_token rotates a refresh token (design §7.4).
//
// THE ORDER OF THE CHECKS BELOW IS THE SECURITY PROPERTY. Reuse detection must come
// AFTER the secret is verified (so a guessed token_id cannot revoke someone else's
// family — that would be a denial-of-service oracle) and BEFORE anything is minted.
//
// All four failure modes the task names — expired, unknown, already-used, revoked —
// return ONE wire error, `invalid_grant`, mapped to `.Unauthenticated` (401). The
// bridge's required response to all four is identical (§7.5: stop, wipe both tokens,
// require re-enrollment, DO NOT LOOP), so distinguishing them on the wire would add
// an oracle and no capability. The server log distinguishes them.
refresh_bridge_token :: proc(service: ^Bridge_Service, presented: string, request_id := "") -> (Bridge_Token_Pair, bool, domain.Domain_Error) {
	invalid_grant := domain.domain_error(.Unauthenticated, "invalid_grant")
	request_id := request_id if refresh_request_id_valid(request_id) else ""
	if service == nil || service.repo == nil do return Bridge_Token_Pair{}, false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	token_id, presented_secret, split_ok := split_credential(REFRESH_TOKEN_PREFIX, presented)
	if !split_ok do return Bridge_Token_Pair{}, false, invalid_grant
	row, ok, _ := iface.bridge_get_token(service.repo, token_id)
	if !ok {
		_ = verify_credential_miss(presented_secret)
		return Bridge_Token_Pair{}, false, invalid_grant
	}
	// An ACCESS token presented to the refresh endpoint is refused here. Without
	// this check an access token would be a refresh token for one rotation, which
	// would hand the holder of a short-lived credential a 30-day one.
	if row.kind != .Refresh {
		_ = verify_credential_miss(presented_secret)
		return Bridge_Token_Pair{}, false, invalid_grant
	}
	if !verify_credential(row.token_hash, presented_secret) do return Bridge_Token_Pair{}, false, invalid_grant
	// A pending enrollment's credential is never renewed (REQ-EA-1): it lives for at
	// most BRIDGE_ENROLL_PENDING_SECONDS, well inside its access token's hour, and
	// rotate_from would otherwise be a way to keep a lineage alive past its rollback.
	if row.scope != BRIDGE_TOKEN_SCOPE do return Bridge_Token_Pair{}, false, invalid_grant
	// From here the caller has PROVEN possession of this exact refresh token, so the
	// remaining branches may act on the family without being an oracle.
	if row.revoked_at != "" {
		if credential_revocation_is_recoverable(service, row.token_id) do return {}, false, pending_sunset_error()
		return {}, false, invalid_grant
	}
	now := platform.clock_now(service.clock)
	if token_is_expired(row.expires_at, now) do return Bridge_Token_Pair{}, false, invalid_grant
	if row.family_expires_at != "" && token_is_expired(row.family_expires_at, now) do return Bridge_Token_Pair{}, false, invalid_grant

	if row.rotated_at != "" {
		// SPENT. A retry of this exact rotation, a crash-recovery replay inside the
		// grace window, or theft.
		if refresh_is_retry_of_rotation(service, row, request_id, now) || refresh_within_grace(service, row, now) {
			return rotate_from(service, row, now, revoke_newer_generations = true)
		}
		// THEFT (§7.4.3): revoke the whole lineage, both kinds, every generation,
		// and end the bridge's live session: its access token is one of them.
		_, _, _ = revoke_token_family(service, row.family_id, now)
		_ = close_bridge_connection(service, row.bridge_id)
		return Bridge_Token_Pair{}, false, invalid_grant
	}
	return rotate_from(service, row, now, revoke_newer_generations = false, request_id = request_id)
}

// refresh_within_grace decides whether a SPENT refresh token is the crash-recovery
// case (§7.4.4) rather than theft. Two conditions, both required:
//
//   1. It was spent less than BRIDGE_REFRESH_REUSE_GRACE_SECONDS ago.
//   2. It is the IMMEDIATELY-PREVIOUS generation — i.e. no generation newer than
//      the one that replaced it exists. "The immediately-previous token only" is
//      the design's wording and the restriction is what keeps the hole small: an
//      attacker cannot walk back through an entire lineage, only the last step.
//
// A row whose rotated_at does not parse is NOT graced. Fail closed: an unreadable
// timestamp must not become an unbounded grace window.
refresh_within_grace :: proc(service: ^Bridge_Service, row: domain.Bridge_Token, now: string) -> bool {
	rotated_ms, rot_ok := platform.rfc3339_to_unix_ms(row.rotated_at)
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now)
	if !rot_ok || !now_ok do return false
	if now_ms - rotated_ms > i64(BRIDGE_REFRESH_REUSE_GRACE_SECONDS) * 1000 do return false
	family, _ := iface.bridge_list_tokens_by_family(service.repo, row.family_id)
	defer free_bridge_tokens(family)
	newest := row.generation
	for t in family {
		if t.generation > newest do newest = t.generation
	}
	return newest <= row.generation + 1 && !family_descendant_delivered(family, row.generation)
}

// refresh_is_retry_of_rotation decides the BRIDGE_REFRESH_RETRY_GRACE_SECONDS case:
// see that constant for the three conditions, all of which are checked here.
refresh_is_retry_of_rotation :: proc(service: ^Bridge_Service, row: domain.Bridge_Token, request_id, now: string) -> bool {
	if request_id == "" || row.rotation_request_hash == "" do return false
	if !verify_credential(row.rotation_request_hash, request_id) do return false
	rotated_ms, rot_ok := platform.rfc3339_to_unix_ms(row.rotated_at)
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now)
	if !rot_ok || !now_ok do return false
	if now_ms - rotated_ms > i64(BRIDGE_REFRESH_RETRY_GRACE_SECONDS) * 1000 do return false
	family, _ := iface.bridge_list_tokens_by_family(service.repo, row.family_id)
	defer free_bridge_tokens(family)
	return !family_descendant_delivered(family, row.generation)
}

// family_descendant_delivered reports whether any generation minted from (after)
// `generation` has demonstrably reached its holder: its access token authenticated
// something (first_used_at: WS upgrade, bridge_reauth or any API call), or its
// refresh token was redeemed. Revoked descendants count too: whoever used one held
// it. Once true, re-presenting the older refresh token is reuse, never a retry.
family_descendant_delivered :: proc(family: []domain.Bridge_Token, generation: int) -> bool {
	for t in family {
		if t.generation <= generation do continue
		if t.kind == .Access && t.first_used_at != "" do return true
		if t.kind == .Refresh && t.rotated_at != "" do return true
	}
	return false
}

// rotate_from mints the next generation for a family.
//
// `revoke_newer_generations` is set only on the grace path, and it is what keeps
// single-use meaningful there: the generation that was minted from this token (and
// which the bridge demonstrably never persisted, or it would not be presenting the
// old one) is revoked, so it cannot be redeemed by whoever else may hold it. Without
// that, a graced rotation would leave TWO live generations from one token.
rotate_from :: proc(service: ^Bridge_Service, row: domain.Bridge_Token, now: string, revoke_newer_generations: bool, request_id := "") -> (Bridge_Token_Pair, bool, domain.Domain_Error) {
	invalid_grant := domain.domain_error(.Unauthenticated, "invalid_grant")
	// The bridge must still exist and still be allowed to connect. Checked before
	// minting so a revoked bridge cannot renew its way back in.
	bridge, bridge_ok, _ := iface.bridge_get_bridge(service.repo, row.bridge_id)
	if !bridge_ok do return Bridge_Token_Pair{}, false, invalid_grant
	if bridge.status == .Revoked {
		if credential_revocation_is_recoverable(service, row.token_id) do return {}, false, pending_sunset_error()
		return {}, false, invalid_grant
	}

	if !revoke_newer_generations {
		// SPEND IT FIRST, and let the database decide the winner. `mark_token_rotated`
		// updates only where rotated_at is still empty, so two concurrent refreshes
		// presenting the same token produce exactly one change; the loser takes the
		// reuse path rather than minting a second live generation. This is why
		// single-use is enforced in the UPDATE's WHERE clause and not by the
		// read-then-check above, which every caller would pass.
		// The request id is recorded as a salted digest beside the spend, so only a
		// caller holding both the token and the id can claim the retry grace.
		request_hash := ""
		if request_id != "" {
			hashed, hash_ok := hash_credential_secret(request_id)
			if !hash_ok do return Bridge_Token_Pair{}, false, domain.domain_error(.Provider_Unavailable, "secure random source unavailable; no bridge credential was issued, retry")
			request_hash = hashed
		}
		// hash_credential_secret returns temp-allocated bytes.
		changed, mark_err := iface.bridge_mark_token_rotated(service.repo, row.token_id, now, request_hash)
		if mark_err.code != .None do return Bridge_Token_Pair{}, false, mark_err
		if !changed {
			state, state_err := iface.bridge_credential_revocation(service.repo, row.token_id)
			if state_err.code != .None || state == .Pending_Sunset do return {}, false, pending_sunset_error()
			// Rollback may have completed between the rejected spend and this
			// read. An unspent token is not evidence of a second holder.
			current, current_ok, current_err := iface.bridge_get_token(service.repo, row.token_id)
			if current_err.code != .None do return {}, false, current_err
			if current_ok {
				unspent := current.rotated_at == ""
				domain.bridge_token_destroy(&current)
				if unspent do return {}, false, pending_sunset_error()
			}
			_, _, _ = revoke_token_family(service, row.family_id, now)
			_ = close_bridge_connection(service, row.bridge_id)
			return Bridge_Token_Pair{}, false, invalid_grant
		}
	}

	family, _ := iface.bridge_list_tokens_by_family(service.repo, row.family_id)
	newest := row.generation
	family_expires_at := row.family_expires_at
	for t in family {
		if t.generation > newest do newest = t.generation
	}
	if revoke_newer_generations {
		// A GRACED RE-GRANT (crash grace or request-id retry) is claimed atomically
		// before anything is revoked or minted. The claim is the generation this grant
		// will mint, compare-and-set from the claim observed when the row was read, and
		// it must move forward: two concurrent presentations of the same spent token
		// read the same claim, so exactly one wins; a racer that read the row after the
		// winner claimed but before it minted sees no forward move. Every loser is
		// treated as a second holder of the token: theft. Without this, both racers
		// minted generation N+1 and two live lineages existed with no reuse signal.
		claim_ok := true
		if prev, has_prev := strconv.parse_int(row.regrant_claim); row.regrant_claim != "" && (!has_prev || newest + 1 <= prev) do claim_ok = false
		free_bridge_tokens(family)
		if claim_ok {
			// Claim + revoke-newer + both inserts commit together or not at all
			// (bridge_regrant_atomic). A failure part-way used to leave the claim at
			// N+1 with no N+1 row, so the bridge's next legitimate retry read as theft.
			pair, refresh_row, access_row, prep_ok, prep_err := prepare_generation(service, row.bridge_id, row.family_id, newest + 1, family_expires_at, now)
			if !prep_ok do return Bridge_Token_Pair{}, false, prep_err
			buf: [24]byte
			outcome, regrant_err := iface.bridge_regrant_atomic(service.repo, iface.Bridge_Regrant_Input{
				spent_token_id = row.token_id, family_id = row.family_id, generation = row.generation,
				expected = row.regrant_claim, claim = strconv.write_int(buf[:], i64(newest + 1), 10), now = now,
				refresh_row = refresh_row, access_row = access_row,
			})
			switch outcome {
			case .Granted:
				return pair, true, domain.Domain_Error{}
			case .Failed:
				// Nothing was written; the claim is untouched, so a retry can succeed.
				return Bridge_Token_Pair{}, false, regrant_err if regrant_err.code != .None else domain.domain_error(.Internal_Error, "the bridge credential re-grant failed; retry")
			case .Lost:
				// A sunset can reject the CAS and roll back before we classify
				// it. An unchanged claim is a retry, not proof of token theft.
				current, current_ok, current_err := iface.bridge_get_token(service.repo, row.token_id)
				if current_err.code != .None do return {}, false, current_err
				if current_ok {
					unchanged := current.regrant_claim == row.regrant_claim
					domain.bridge_token_destroy(&current)
					if unchanged do return {}, false, pending_sunset_error()
				}
				claim_ok = false
			}
		}
		state, state_err := iface.bridge_credential_revocation(service.repo, row.token_id)
		if state_err.code != .None || state == .Pending_Sunset do return {}, false, pending_sunset_error()
		// A lost claim is a second holder of the token: theft. This also revokes the
		// pair the winner just received; see docs/bounded-action-recovery.md.
		_, _, _ = revoke_token_family(service, row.family_id, now)
		_ = close_bridge_connection(service, row.bridge_id)
		return Bridge_Token_Pair{}, false, invalid_grant
	}
	free_bridge_tokens(family)
	return mint_generation(service, row.bridge_id, row.family_id, newest + 1, family_expires_at, now)
}

// revoke_token_family revokes every generation and both kinds of one lineage.
//
// A ZERO-ROW RESULT IS AN ERROR, not a success. "Revoked the family" that matched
// nothing is the failure that turns theft detection into a no-op, and it is silent
// by nature — the caller returns invalid_grant either way. The bool exists so the
// reuse-detection test can assert the revocation actually happened rather than
// asserting only the error the attacker sees. An already-revoked family legitimately
// changes 0 rows, which is why the caller treats false as "nothing more to do"
// rather than as a hard failure.
revoke_token_family :: proc(service: ^Bridge_Service, family_id, now: string) -> (int, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return 0, false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if family_id == "" do return 0, false, domain.domain_error(.Validation_Failed, "family_id is required")
	stamp := now
	if stamp == "" do stamp = platform.clock_now(service.clock)
	changed, ok, err := iface.bridge_revoke_token_family(service.repo, family_id, stamp)
	return changed, ok && changed > 0, err
}

// free_bridge_tokens releases a slice returned by bridge_list_tokens_by_family.
//
// The repository's row reader hands back an owned string for every text column, and the family
// list is read on the refresh path — a request path with an arena, but also from
// revocation, which runs wherever its caller does. Freeing explicitly keeps this
// correct in both, and mirrors domain.bridge_destroy's reason for existing.
free_bridge_tokens :: proc(tokens: []domain.Bridge_Token) {
	for i in 0..<len(tokens) {
		t := tokens[i]
		domain.bridge_token_destroy(&t)
	}
	if tokens != nil do delete(tokens)
}

// A sunset receipt is a durable suspension, not a permanent credential rejection.
// Use the existing retriable wire error (500), understood by installed bridges:
// they retain both credential files and retry with the same rotation request id.
// Current bridges recognize the cause and park without polling; the retriable
// envelope keeps older bridges from destroying recoverable credentials.
// Do not turn a lookup failure or a stale revoked read racing rollback into a 401.
pending_sunset_error :: proc() -> domain.Domain_Error {
	err := domain.domain_error(.Internal_Error, "bridge retirement is pending enrollment; retain credentials and explicitly resume after rollback")
	err.cause = "bridge_sunset_pending"
	return err
}

credential_revocation_is_recoverable :: proc(service: ^Bridge_Service, token_id: string) -> bool {
	state, err := iface.bridge_credential_revocation(service.repo, token_id)
	return err.code != .None || state != .Final
}

revoked_credential_error :: proc(message: string) -> domain.Domain_Error {
    err := domain.domain_error(.Forbidden, message)
    err.cause = "bridge_credential_revoked"
    return err
}
