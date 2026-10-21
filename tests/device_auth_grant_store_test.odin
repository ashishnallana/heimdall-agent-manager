// Unit tests for the device-authorization grant store + helpers (ELDA-1 / ELDA-6).
//
// Covers the task-1 acceptance criteria at the service/store layer:
//   AC1: device_code >= 128-bit (64 hex), user_code [A-Z2-7] 8+dash, authorize shape.
//   AC2: device_code/user_code unlinkable (independent CSPRNG draws).
//   AC3: request_ip captured from the request.
//   AC4: resolve_client_ip honors XFF only behind a trusted proxy.
//   AC5: per-IP authorize rate limit -> 429-equivalent (allow_authorize false).
//   + TTL/sweep expiry.
//
// Run: odin run tests/device_auth_grant_store_test.odin -collection:odin_test=src -file
package device_auth_grant_store_test

import "core:fmt"
import "core:crypto/ecdsa"
import vault "odin_test:lib/vault"
import "core:testing"
import "core:os"
import "core:strings"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"

FAILURES: int = 0

assert_eq :: proc(got, want: $T, label: string) {
	if got == want do return
	FAILURES += 1
	fmt.printfln("FAIL {}: got {!v} want {!v}", label, got, want)
}

assert_true :: proc(cond: bool, label: string) {
	if cond do return
	FAILURES += 1
	fmt.printfln("FAIL {}: condition false", label)
}

// --- Fake monotonic clock (returns a mutable global unix-seconds value) ---
FAKE_NOW: i64 = 1_000_000
fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

is_hex :: proc(s: string) -> bool {
	for ch in s {
		ok := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
		if !ok do return false
	}
	return true
}

is_base32 :: proc(s: string) -> bool {
	for ch in s {
		ok := (ch >= 'A' && ch <= 'Z') || (ch >= '2' && ch <= '7')
		if !ok do return false
	}
	return true
}

@(test)
test_device_auth_grant_store_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	fmt.println("=== device_auth grant store + helpers ===")

	// AC1: device_code entropy/length/charset.
	dc, dcok := device_auth.generate_device_code()
	assert_true(dcok, "generate_device_code succeeds")
	assert_true(len(dc) == 64, "device_code is 64 hex chars (256-bit)")
	assert_true(is_hex(dc), "device_code charset is [0-9a-f]")
	// >= 128-bit: 64 hex chars = 32 bytes = 256 bits >= 128. Assert explicitly.
	assert_true(len(dc) * 4 >= 128, "device_code entropy >= 128 bits")

	// AC1: user_code charset/length/format.
	uc, ucok := device_auth.generate_user_code()
	assert_true(ucok, "generate_user_code succeeds")
	assert_true(len(uc) == 9, "user_code is 8 symbols + 1 dash = 9 chars")
	assert_true(uc[4] == '-', "user_code has dash at index 4 (XXXX-XXXX)")
	assert_true(is_base32(uc[0:4]) && is_base32(uc[5:9]), "user_code charset is [A-Z2-7]")
	fmt.println("sample device_code:", dc[:16], "...  user_code:", uc)

	// AC1/AC2: uniqueness + unlinkability over many draws.
	SEEN_DC := make(map[string]bool)
	SEEN_UC := make(map[string]bool)
	UNLINKABLE := true
	for i in 0..<200 {
		d, dok := device_auth.generate_device_code()
		u, uok := device_auth.generate_user_code()
		assert_true(dok && uok, "code generation succeeds in batch")
		SEEN_DC[d] = true
		SEEN_UC[u] = true
		// Unlinkability sanity: device_code is never a transform of user_code.
		if strings.contains(d, u) || strings.contains(u, d) do UNLINKABLE = false
		if strings.has_prefix(d, u[:4]) do UNLINKABLE = false
	}
	assert_true(len(SEEN_DC) == 200, "200 device_codes are all distinct (high entropy)")
	assert_true(len(SEEN_UC) == 200, "200 user_codes are all distinct")
	assert_true(UNLINKABLE, "device_code and user_code are unlinkable (AC2)")
	delete(SEEN_DC)
	delete(SEEN_UC)

	// AC4: resolve_client_ip trusted-XFF semantics.
	TRUSTED := []string{"127.0.0.1/32"}
	// Trusted peer + XFF -> first XFF hop.
	got := device_auth.resolve_client_ip("127.0.0.1:54321", "203.0.113.9, 10.0.0.1", TRUSTED)
	assert_eq(got, "203.0.113.9", "trusted peer uses first XFF hop")
	// Trusted peer, no XFF -> peer IP (stripped of port).
	got = device_auth.resolve_client_ip("127.0.0.1:54325", "", TRUSTED)
	assert_eq(got, "127.0.0.1", "trusted peer, no XFF -> peer IP")
	// Untrusted peer + spoofed XFF -> IGNORED, peer IP used (AC4 spoofing guard).
	got = device_auth.resolve_client_ip("198.51.100.7:9999", "203.0.113.999", TRUSTED)
	assert_eq(got, "198.51.100.7", "untrusted peer ignores spoofed XFF")
	// Multiple XFF hops -> first (original client).
	got = device_auth.resolve_client_ip("127.0.0.1:1", "203.0.113.10, 10.0.0.1, 10.0.0.2", TRUSTED)
	assert_eq(got, "203.0.113.10", "first XFF hop wins among many")
	fmt.println("resolve_client_ip: trusted-XFF + spoofing guard OK")

	// AC5 + AC3 + AC1: grant store, rate limit, authorize end-to-end.
	store := device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600, interval = 5, rate_limit = 3, rate_window = 60,
	})
	defer device_auth.grant_store_free(&store)
	svc := device_auth.new_device_auth_service(&store, fake_clock(), TRUSTED)

	// AC3 + AC1: authorize captures request_ip and returns the full contract.
	res, ok, err := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:5555", "203.0.113.42")
	assert_true(ok, "authorize succeeds (trusted peer)")
	assert_eq(err.code, domain.Error_Code.None, "no error on success")
	assert_true(len(res.device_code) == 64, "authorize returns 64-char device_code")
	assert_true(len(res.user_code) == 9, "authorize returns 9-char user_code")
	assert_eq(res.verification_uri, "https://auth.example.com/device/", "verification_uri returned")
	assert_eq(res.interval, 5, "interval returned")
	assert_true(res.expires_in <= 600, "expires_in <= 600 (ELDA-1 cap)")
	// AC3: request_ip captured on the grant.
	grant, gok := device_auth.get_grant(&store, res.device_code)
	assert_true(gok, "grant stored by device_code")
	assert_eq(grant.request_ip, "203.0.113.42", "grant captured trusted-XFF request_ip (AC3)")
	assert_eq(grant.client, "electron", "grant captured client")
	assert_eq(grant.status, device_auth.Grant_Status.Pending, "grant starts Pending")
	// Validation: missing client -> 400.
	_, vok, verr := device_auth.authorize(&svc, {}, "127.0.0.1:1", "")
	assert_true(!vok, "missing client rejected")
	assert_eq(verr.code, domain.Error_Code.Validation_Failed, "missing client -> Validation_Failed (400)")

	// AC5: per-IP rate limit. We already used 1 of 3 for IP 203.0.113.42.
	_, r2, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	_, r3, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	_, r4, r4err := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	assert_true(r2 && r3, "rate limit allows up to N")
	assert_true(!r4, "rate limit denies over N (AC5)")
	assert_eq(r4err.code, domain.Error_Code.Rate_Limited, "over-limit -> Rate_Limited (429)")
	// Different IP is not affected by another IP's limit.
	_, other_ok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.99")
	assert_true(other_ok, "rate limit is per-IP (different IP unaffected)")
	fmt.println("rate limit: per-IP allow/deny OK (AC5)")

	// Rate window reset: advance fake clock past the window, limit clears.
	FAKE_NOW += 61
	_, after_ok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.42")
	assert_true(after_ok, "rate limit resets after window elapses")

	// TTL/sweep: a grant past expires_at is evicted.
	FAKE_NOW = 2_000_000
	expired_res, eok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.250")
	assert_true(eok, "created grant for sweep test")
	FAKE_NOW += 601 // past its 600s TTL
	removed := device_auth.sweep(&store, FAKE_NOW)
	assert_true(removed >= 1, "sweep removed at least one expired grant")
	_, still := device_auth.get_grant(&store, expired_res.device_code)
	assert_true(!still, "expired grant is gone after sweep")
	fmt.println("TTL/sweep: expired grant evicted OK")


	// =====================================================================
	// REQ-IMPL-2: bridge-enrollment extensions to the grant.
	//
	// Everything above this line is the pre-existing ELDA coverage and must keep
	// passing unchanged — these cases are additive.
	// =====================================================================

	// A well-formed uncompressed P-256 point: "04" + 128 hex chars, the shape
	// bridge_get_public_key_hex() produces (src/bridge/unseal_protocol.odin).
	BPK :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
	IDP, IDPROOF := test_bridge_identity(BPK, PKCE_CHALLENGE)
	// The fingerprint of BPK, computed independently (python hashlib) rather than
	// by the code under test: SHA-256 over the DECODED 65 bytes, first 8 bytes,
	// as four space-separated hex quads. A change to WHAT gets hashed — the hex
	// text instead of the bytes, say — breaks this and nothing else would.
	BPK_FP :: "fb41 9516 cc0c f6ae"
	// A PKCE pair, likewise computed independently: BASE64URL(SHA256(verifier))
	// with padding stripped (RFC 7636 §4.2).
	PKCE_VERIFIER :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	PKCE_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"

	// --- Fingerprint derivation ---
	fp, fpok := device_auth.bridge_key_fingerprint_for(BPK)
	assert_true(fpok, "fingerprint derives from a well-formed key")
	assert_eq(fp, BPK_FP, "fingerprint is SHA-256(decoded key)[:8] as hex quads")
	assert_eq(len(fp), 19, "fingerprint is 16 hex chars + 3 spaces")
	// Fail-closed on a malformed key: no fingerprint rather than an empty one,
	// because an empty fingerprint would render on the approval page as
	// "nothing to compare" and the human would approve anyway.
	_, bad_fpok := device_auth.bridge_key_fingerprint_for("04abc")
	assert_true(!bad_fpok, "malformed key yields no fingerprint (fail closed)")

	// --- Public-key shape validation ---
	assert_true(device_auth.valid_bridge_public_key(BPK), "well-formed P-256 point accepted")
	assert_true(!device_auth.valid_bridge_public_key(""), "empty key rejected")
	assert_true(!device_auth.valid_bridge_public_key(BPK[:129]), "129-char key rejected (length)")
	assert_true(!device_auth.valid_bridge_public_key(strings.concatenate({BPK, "a"})), "131-char key rejected (length)")
	assert_true(!device_auth.valid_bridge_public_key(strings.concatenate({"03", BPK[2:]})), "non-04 prefix rejected (not uncompressed)")
	assert_true(!device_auth.valid_bridge_public_key(strings.concatenate({BPK[:129], "Z"})), "non-hex character rejected")
	assert_true(!device_auth.valid_bridge_public_key(strings.concatenate({BPK[:129], "A"})), "uppercase hex rejected (canonical form is lowercase)")

	// --- PKCE helpers ---
	assert_true(device_auth.valid_pkce_challenge(PKCE_CHALLENGE), "43-char base64url challenge accepted")
	assert_true(!device_auth.valid_pkce_challenge(PKCE_CHALLENGE[:42]), "short challenge rejected")
	assert_true(!device_auth.valid_pkce_challenge(strings.concatenate({PKCE_CHALLENGE[:42], "+"})), "non-base64url char rejected")
	assert_true(!device_auth.valid_pkce_challenge(strings.concatenate({PKCE_CHALLENGE[:42], "="})), "padding rejected")
	assert_true(device_auth.pkce_verifier_matches(PKCE_CHALLENGE, PKCE_VERIFIER), "correct verifier matches challenge")
	assert_true(!device_auth.pkce_verifier_matches(PKCE_CHALLENGE, strings.concatenate({PKCE_VERIFIER[:42], "b"})), "one-character-off verifier rejected")
	assert_true(!device_auth.pkce_verifier_matches(PKCE_CHALLENGE, ""), "empty verifier rejected")
	assert_true(!device_auth.pkce_verifier_matches("", PKCE_VERIFIER), "empty challenge never matches")
	// RFC 7636 §4.1 length bounds.
	assert_true(!device_auth.valid_pkce_verifier("short"), "42-or-fewer-char verifier rejected")
	assert_true(device_auth.valid_pkce_verifier(PKCE_VERIFIER), "43-char verifier accepted")
	fmt.println("REQ-IMPL-2 OK: fingerprint derivation, key shape, PKCE helpers")

	// --- Grant_Kind is derived at authorize and PERSISTED ---
	// A fresh store so the earlier rate-limit exhaustion does not interfere.
	bstore := device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://ui.example.com/api/v1/device",
		expires_in = 600, interval = 5, rate_limit = 100, rate_window = 60,
	})
	defer device_auth.grant_store_free(&bstore)
	bsvc := device_auth.new_device_auth_service(&bstore, fake_clock(), TRUSTED)

	bres, bok, berr := device_auth.authorize(&bsvc, {
		client = "ham-bridge", device_label = "dawnstar", os = "linux", app_version = "0.9.1",
		bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "1111111111111111111111111111111111111111111111111111111111111111", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", os_user = "tanmay",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:5555", "203.0.113.42")
	assert_true(bok, "bridge authorize succeeds")
	assert_eq(berr.code, domain.Error_Code.None, "bridge authorize no error")
	assert_eq(bres.bridge_key_fingerprint, BPK_FP, "authorize echoes the HUB-COMPUTED fingerprint")
	bgrant, bgok := device_auth.get_grant(&bstore, bres.device_code)
	assert_true(bgok, "bridge grant stored")
	assert_eq(bgrant.grant_kind, device_auth.Grant_Kind.Bridge_Enrollment, "grant_kind persisted as Bridge_Enrollment")
	assert_true(device_auth.is_bridge_grant(bgrant), "is_bridge_grant true for a bridge grant")
	assert_eq(bgrant.bridge_public_key, BPK, "bridge_public_key persisted")
	assert_eq(bgrant.bridge_key_fingerprint, BPK_FP, "hub-computed fingerprint persisted on the grant")
	assert_eq(bgrant.os_user, "tanmay", "os_user persisted")
	assert_eq(bgrant.code_challenge, PKCE_CHALLENGE, "code_challenge persisted")
	assert_eq(bgrant.code_challenge_method, "S256", "code_challenge_method persisted")

	// An ELDA grant stays User_Token — the zero value — and carries none of the
	// bridge fields. This is the pairing the coordinator asked for: a grant
	// authorized WITHOUT a key can never be a bridge enrollment.
	eres, eok2, _ := device_auth.authorize(&bsvc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "203.0.113.43")
	assert_true(eok2, "electron authorize succeeds")
	egrant, egok := device_auth.get_grant(&bstore, eres.device_code)
	assert_true(egok, "electron grant stored")
	assert_eq(egrant.grant_kind, device_auth.Grant_Kind.User_Token, "grant_kind defaults to User_Token")
	assert_true(!device_auth.is_bridge_grant(egrant), "is_bridge_grant false for an electron grant")
	assert_eq(egrant.bridge_public_key, "", "electron grant carries no bridge key")
	assert_eq(eres.bridge_key_fingerprint, "", "electron authorize echoes no fingerprint")
	fmt.println("REQ-IMPL-2 OK: grant_kind derived once and persisted, both directions")

	// --- Authorize-time validation, each rule in its own case ---
	// PKCE method must be S256; `plain` and an absent method are both refused
	// rather than defaulted (RFC 7636 §4.2 permits `plain`; this flow does not).
	_, p1ok, p1err := device_auth.authorize(&bsvc, {client = "c", code_challenge = PKCE_CHALLENGE, code_challenge_method = "plain"}, "127.0.0.1:1", "203.0.113.50")
	assert_true(!p1ok, "code_challenge_method=plain rejected")
	assert_eq(p1err.code, domain.Error_Code.Validation_Failed, "plain method -> Validation_Failed")
	_, p2ok, _ := device_auth.authorize(&bsvc, {client = "c", code_challenge = PKCE_CHALLENGE}, "127.0.0.1:1", "203.0.113.51")
	assert_true(!p2ok, "challenge with no method rejected (no `plain` default)")
	_, p3ok, _ := device_auth.authorize(&bsvc, {client = "c", code_challenge_method = "S256"}, "127.0.0.1:1", "203.0.113.52")
	assert_true(!p3ok, "method with no challenge rejected")
	_, p4ok, _ := device_auth.authorize(&bsvc, {client = "c", code_challenge = "tooshort", code_challenge_method = "S256"}, "127.0.0.1:1", "203.0.113.53")
	assert_true(!p4ok, "malformed challenge rejected")

	// A bridge enrollment with no PKCE is refused: without it the device_code is
	// a bare bearer secret and redemption proves nothing.
	_, n1ok, n1err := device_auth.authorize(&bsvc, {client = "ham-bridge", bridge_public_key = BPK}, "127.0.0.1:1", "203.0.113.54")
	assert_true(!n1ok, "bridge grant without a code_challenge rejected")
	assert_eq(n1err.code, domain.Error_Code.Validation_Failed, "missing PKCE -> Validation_Failed")

	// A malformed key is rejected outright rather than stored unfingerprintable.
	_, k1ok, _ := device_auth.authorize(&bsvc, {client = "ham-bridge", bridge_public_key = "04dead", code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256"}, "127.0.0.1:1", "203.0.113.55")
	assert_true(!k1ok, "malformed bridge_public_key rejected")

	// THE MISMATCH RULE (scope item 5): the Hub computes the fingerprint, and a
	// body-supplied one that disagrees is surfaced — never silently preferred in
	// either direction.
	_, m1ok, m1err := device_auth.authorize(&bsvc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "2222222222222222222222222222222222222222222222222222222222222222", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		bridge_key_fingerprint = "0000 0000 0000 0000",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "203.0.113.56")
	assert_true(!m1ok, "body fingerprint that disagrees with the key is REJECTED")
	assert_eq(m1err.code, domain.Error_Code.Validation_Failed, "fingerprint mismatch -> Validation_Failed")
	// An AGREEING body fingerprint is accepted, and the stored value is still the
	// Hub's own derivation.
	m2res, m2ok, _ := device_auth.authorize(&bsvc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "3333333333333333333333333333333333333333333333333333333333333333", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", bridge_key_fingerprint = BPK_FP,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "203.0.113.57")
	assert_true(m2ok, "body fingerprint that agrees is accepted")
	m2grant, _ := device_auth.get_grant(&bstore, m2res.device_code)
	assert_eq(m2grant.bridge_key_fingerprint, BPK_FP, "stored fingerprint is the hub-computed one")
	// A fingerprint with NO key has nothing to be checked against, so it is
	// refused rather than stored unverified.
	_, m3ok, _ := device_auth.authorize(&bsvc, {client = "c", bridge_key_fingerprint = BPK_FP}, "127.0.0.1:1", "203.0.113.58")
	assert_true(!m3ok, "fingerprint without a key rejected")

	// os_user is host-asserted, so it is bounded at the door: control characters
	// (which would break a log line or the approval page) and over-long values.
	_, u1ok, _ := device_auth.authorize(&bsvc, {client = "c", os_user = "ta\nnmay"}, "127.0.0.1:1", "203.0.113.59")
	assert_true(!u1ok, "os_user with a control character rejected")
	long_user := strings.repeat("u", 65)
	defer delete(long_user)
	_, u2ok, _ := device_auth.authorize(&bsvc, {client = "c", os_user = long_user}, "127.0.0.1:1", "203.0.113.60")
	assert_true(!u2ok, "over-long os_user rejected")
	fmt.println("REQ-IMPL-2 OK: authorize validation (PKCE, key shape, fingerprint mismatch, os_user)")

	// --- store -> read -> free with EVERY new field populated ---
	// The store owns its strings on the heap; a field added to Grant and missed
	// in grant_clone_strings/grant_free_strings is a use-after-arena that a test
	// which never frees the store would not catch. This one frees it.
	lstore := device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://ui.example.com/api/v1/device",
		expires_in = 600, interval = 5, rate_limit = 100, rate_window = 60,
	})
	lsvc := device_auth.new_device_auth_service(&lstore, fake_clock(), TRUSTED)
	lres, lok, _ := device_auth.authorize(&lsvc, {
		client = "ham-bridge", device_label = "dawnstar", os = "linux", app_version = "0.9.1",
		bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "4444444444444444444444444444444444444444444444444444444444444444", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", os_user = "tanmay",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256", previous_bridge_id = "brg_previous",
	}, "127.0.0.1:1", "203.0.113.70")
	assert_true(lok, "lifecycle grant created with all new fields")
	// Approve + set_grant so the grant is re-cloned at least once, then read it
	// back: a missed clone shows up here as a corrupted or empty field.
	lsvc_grant, _ := device_auth.get_grant(&lstore, lres.device_code)
	lsvc_grant.minted_bridge_id = "brg_lifecycle"
	device_auth.set_grant(&lstore, lres.device_code, lsvc_grant)
	reread, rok := device_auth.get_grant(&lstore, lres.device_code)
	assert_true(rok, "grant re-readable after set_grant")
	assert_eq(reread.bridge_public_key, BPK, "bridge_public_key survives re-clone")
	assert_eq(reread.bridge_key_fingerprint, BPK_FP, "fingerprint survives re-clone")
	assert_eq(reread.os_user, "tanmay", "os_user survives re-clone")
	assert_eq(reread.code_challenge, PKCE_CHALLENGE, "code_challenge survives re-clone")
	assert_eq(reread.code_challenge_method, "S256", "code_challenge_method survives re-clone")
	assert_eq(reread.minted_bridge_id, "brg_lifecycle", "minted_bridge_id survives re-clone")
	assert_eq(reread.grant_kind, device_auth.Grant_Kind.Bridge_Enrollment, "grant_kind survives re-clone")
	assert_eq(reread.previous_bridge_id, "brg_previous", "previous_bridge_id survives re-clone")
	// Free the store explicitly (not deferred) so a double/bad free on any new
	// field is attributed to this test rather than to process teardown.
	device_auth.grant_store_free(&lstore)
	fmt.println("REQ-IMPL-2 OK: store -> re-clone -> read -> free with all new fields populated")

	if FAILURES == 0 {
		fmt.println("ALL PASS")
	} else {
		fmt.printfln("{} FAILURES", FAILURES)
		os.exit(1)
	}
}

// Passwordless vault: every bridge grant carries a persistent identity key and its
// proof of possession over (bridge_public_key, code_challenge). Fixed scalar.
test_bridge_identity :: proc(ecdh_pub, challenge: string) -> (pub_hex: string, proof: string) {
	priv: ecdsa.Private_Key
	scalar: [32]byte
	scalar[0] = 0x42
	scalar[31] = 0x07
	_ = ecdsa.private_key_set_bytes(&priv, .SECP256R1, scalar[:])
	pub: [65]byte
	ecdsa.private_key_public_bytes(&priv, pub[:])
	pub_hex = vault.hex_encode_lower(pub[:])
	msg, _ := vault.bridge_enroll_proof_canonical(ecdh_pub, challenge)
	sig, _ := vault.sign_p256(&priv, transmute([]byte)msg)
	proof, _ = vault.signature_object(&sig)
	return
}
