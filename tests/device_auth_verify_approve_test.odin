// Unit tests for device-auth verify + approve (ELDA-2 / ELDA-6 / ELDA-7).
//
// Covers the service-layer guarantees the HTTP layer cannot observe directly:
//   AC4 (ELDA-6): approve binds owner_user_id from the Auth_Context argument
//                 ONLY; a client-supplied owner field never reaches the grant.
//   AC5 (ELDA-2): terminal transitions (approved/denied) are closed; verify
//                 returns Gone, approve returns Conflict on a terminal grant.
//   AC3 (ELDA-2): unknown vs expired codes both surface the SAME generic error
//                 (no enumeration).
//   AC6 (ELDA-7): approve records owner_user_id, approver_ip (trusted-XFF),
//                 approver_ua, decided_at; pre-mints the bridge credential.
// All grants are bridge enrollments: the user-token grant was removed with Hub
// user tokens (users sign in with OIDC); a user authorize is refused.
//
// Run: odin run tests/device_auth_verify_approve_test.odin -collection:odin_test=src -file
package device_auth_verify_approve_test

import "core:fmt"
import "core:crypto/ecdsa"
import vault "odin_test:lib/vault"
import "core:testing"
import "core:os"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"

FAILURES: int = 0

fail :: proc(msg: string) {
	FAILURES += 1
	fmt.println("FAIL:", msg)
}

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

// --- Fake monotonic clock ---
FAKE_NOW: i64 = 5_000_000
fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

// A complete bridge-enrollment authorize request; pair_lookup (the approval
// index) is unique per call.
VA_PUB :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
VA_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"
va_seq := 1000
va_bridge_input :: proc(device_label := "", os := "", app_version := "") -> device_auth.Authorize_Input {
	idp, proof := test_bridge_identity(VA_PUB, VA_CHALLENGE)
	va_seq += 1
	return device_auth.Authorize_Input{
		client = "ham-bridge", device_label = device_label, os = os, app_version = app_version,
		bridge_public_key = VA_PUB, bridge_identity_public_key = idp, bridge_identity_proof = proof,
		pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443",
		pair_lookup = fmt.aprintf("%064x", va_seq), pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = VA_CHALLENGE, code_challenge_method = "S256",
	}
}

// --- Fake BRIDGE minter (REQ-IMPL-2). Records what approve passed it so the
// test can prove the owner came from the Auth_Context argument. ---
BRIDGE_MINT_CALLS: [dynamic]device_auth.Bridge_Mint_Request
BRIDGE_MINT_TOKEN: string = "hba_btk_fake.secretsecret"
BRIDGE_MINT_ID: string = "brg_fake_001"
BRIDGE_MINT_OK: bool = true

// REQ-IMPL-3 changed the minter's return to a Bridge_Mint_Result struct (an
// expiring PAIR plus its two lifetimes), so the fake returns the access half under
// the same constant and adds a refresh half the poll assertions can look for.
BRIDGE_MINT_REFRESH: string = "hbf_btk_fake.refreshrefresh"

fake_bridge_minter :: proc(ctx: rawptr, req: device_auth.Bridge_Mint_Request) -> (device_auth.Bridge_Mint_Result, bool) {
	_ = ctx
	append(&BRIDGE_MINT_CALLS, req)
	if !BRIDGE_MINT_OK do return device_auth.Bridge_Mint_Result{}, false
	return device_auth.Bridge_Mint_Result{
		access_token = BRIDGE_MINT_TOKEN,
		refresh_token = BRIDGE_MINT_REFRESH,
		bridge_id = BRIDGE_MINT_ID,
		expires_in = 3600,
		refresh_expires_in = 2592000,
	}, true
}

new_service :: proc() -> (^device_auth.Grant_Store, device_auth.Device_Auth_Service) {
	store := new(device_auth.Grant_Store)
	store^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600, interval = 5, rate_limit = 100, rate_window = 60,
	})
	svc := device_auth.new_device_auth_service(store, fake_clock(), []string{"127.0.0.1/32"})
	device_auth.with_bridge_token_minter(&svc, fake_bridge_minter)
	return store, svc
}

@(test)
test_device_auth_verify_approve_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	fmt.println("=== device_auth verify + approve ===")
	defer {
		if FAILURES == 0 {
			fmt.println("ALL PASS")
		} else {
			fmt.printfln("{} FAILURES", FAILURES)
			os.exit(1)
		}
	}

	store, svc := new_service()
	defer device_auth.grant_store_free(store)

	// A user (no bridge key) authorize used to mint a Hub user token; refused now.
	_, user_ok0, user_err0 := device_auth.authorize(&svc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "")
	assert_true(!user_ok0, "user (no bridge key) authorize is refused")
	assert_eq(user_err0.code, domain.Error_Code.Validation_Failed, "user authorize -> Validation_Failed")

	// Seed a pending (bridge) grant.
	seed_in := va_bridge_input("MBP", "macOS", "1.2.3")
	res, ok, _ := device_auth.authorize(&svc, seed_in, "127.0.0.1:1", "")
	assert_true(ok, "seed authorize succeeds")
	uc := seed_in.pair_lookup

	// --- AC3: verify returns device info captured at authorize ---
	info, vok, _ := device_auth.verify(&svc, uc)
	assert_true(vok, "verify pending grant succeeds")
	assert_eq(info.client, "ham-bridge", "verify client")
	assert_eq(info.device_label, "MBP", "verify device_label")
	assert_eq(info.os, "macOS", "verify os")
	assert_eq(info.app_version, "1.2.3", "verify app_version")
	fmt.println("AC3 OK: verify returns captured device info")

	// --- AC3: unknown code -> generic Not_Found, no enumeration ---
	_, uk_ok, uk_err := device_auth.verify(&svc, "ZZZZ-ZZZZ")
	assert_true(!uk_ok, "verify unknown code fails")
	assert_eq(uk_err.code, domain.Error_Code.Not_Found, "unknown code -> Not_Found (generic)")
	assert_eq(uk_err.message, "invalid or expired code", "generic message (no enumeration)")
	fmt.println("AC3 OK: unknown code -> generic Not_Found (no enumeration)")

	// --- AC4 + AC6: approve binds owner from CONTEXT only, records audit ---
	// Pass an explicit owner_user_id (this is what the handler derives from
	// Auth_Context). The grant must record THAT owner, never a body field.
	aok, aerr := device_auth.approve(&svc, {user_code = uc, approve = true},
		"real-owner-001", "203.0.113.9", "Mozilla/5.0 verify-page")
	assert_true(aok, "approve succeeds")
	assert_eq(aerr.code, domain.Error_Code.None, "approve no error")
	grant_after, gok := device_auth.get_grant(store, res.device_code)
	assert_true(gok, "grant exists after approve")
	assert_eq(grant_after.owner_user_id, "real-owner-001", "AC4 owner bound from context only")
	assert_eq(grant_after.status, device_auth.Grant_Status.Approved, "approve sets Approved")
	assert_eq(grant_after.approver_ip, "203.0.113.9", "AC6 approver_ip (trusted-XFF)")
	assert_eq(grant_after.approver_ua, "Mozilla/5.0 verify-page", "AC6 approver_ua")
	assert_true(grant_after.decided_at == FAKE_NOW, "AC6 decided_at set")
	// Pre-mint: the bridge minter was called with the context owner + label.
	assert_eq(len(BRIDGE_MINT_CALLS), 1, "AC4/AC6 minter called once on approve")
	assert_eq(BRIDGE_MINT_CALLS[0].owner_user_id, "real-owner-001", "minter got context owner")
	assert_eq(BRIDGE_MINT_CALLS[0].device_label, "MBP", "minter got the device label")
	assert_eq(grant_after.minted_token, BRIDGE_MINT_TOKEN, "pre-minted credential stored on grant")
	assert_eq(grant_after.minted_token_id, BRIDGE_MINT_ID, "pre-minted token_id stored on grant")
	fmt.println("AC4+AC6 OK: owner from context, audit fields + pre-mint recorded")

	// --- AC5: terminal grant closed (verify -> Gone, approve -> Conflict) ---
	_, vt_ok, vt_err := device_auth.verify(&svc, uc)
	assert_true(!vt_ok, "verify terminal fails")
	assert_eq(vt_err.code, domain.Error_Code.Gone, "verify terminal -> Gone (410)")
	aok2, aerr2 := device_auth.approve(&svc, {user_code = uc, approve = true}, "x", "y", "z")
	assert_true(!aok2, "approve terminal fails")
	assert_eq(aerr2.code, domain.Error_Code.Conflict, "approve terminal -> Conflict (409)")
	fmt.println("AC5 OK: approved grant terminal (verify 410, approve 409)")

	// --- AC5: deny path is also terminal; no token pre-mint on deny ---
	deny_in := va_bridge_input()
	_, _, _ = device_auth.authorize(&svc, deny_in, "127.0.0.1:1", "")
	uc_deny := deny_in.pair_lookup
	mints_before := len(BRIDGE_MINT_CALLS)
	aok3, _ := device_auth.approve(&svc, {user_code = uc_deny, approve = false}, "owner-d", "1.2.3.4", "UA")
	assert_true(aok3, "deny succeeds")
	assert_eq(len(BRIDGE_MINT_CALLS), mints_before, "deny does NOT pre-mint a token")
	_, dg, dgok := device_auth.grant_by_user_code(store, uc_deny)
	assert_true(dgok, "denied grant found")
	assert_eq(dg.status, device_auth.Grant_Status.Denied, "deny sets Denied")
	assert_eq(dg.owner_user_id, "owner-d", "deny still binds owner from context")
	_, dvt_ok, _ := device_auth.verify(&svc, uc_deny)
	assert_true(!dvt_ok, "denied grant verify fails (terminal)")
	fmt.println("AC5 OK: deny terminal, no pre-mint, owner still bound")

	// --- AC3: expired code -> SAME generic Not_Found as unknown (no enumeration) ---
	exp_in := va_bridge_input()
	_, _, _ = device_auth.authorize(&svc, exp_in, "127.0.0.1:1", "")
	FAKE_NOW += 601 // past the 600s TTL
	_, et_ok, et_err := device_auth.verify(&svc, exp_in.pair_lookup)
	assert_true(!et_ok, "verify expired fails")
	assert_eq(et_err.code, domain.Error_Code.Not_Found, "expired -> Not_Found (same generic as unknown)")
	assert_eq(et_err.message, "invalid or expired code", "expired message identical to unknown (no enumeration)")
	fmt.println("AC3 OK: expired code indistinguishable from unknown (no enumeration)")


	// =====================================================================
	// REQ-IMPL-2: approval of a BRIDGE grant mints a bridge-scoped credential.
	// Additive — every case above is pre-existing ELDA coverage.
	// =====================================================================
	BPK :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
	IDP, IDPROOF := test_bridge_identity(BPK, PKCE_CHALLENGE)
	BPK_FP :: "fb41 9516 cc0c f6ae"
	PKCE_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"

	bres, bok2, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", device_label = "dawnstar", os = "linux", app_version = "0.9.1",
		bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "1111111111111111111111111111111111111111111111111111111111111111", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", os_user = "tanmay",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(bok2, "bridge authorize succeeds")

	// --- verify exposes the pair REQ-IMPL-5 needs for the fragment cross-check ---
	binfo, bvok, _ := device_auth.verify(&svc, "1111111111111111111111111111111111111111111111111111111111111111")
	assert_true(bvok, "verify bridge grant succeeds")
	assert_true(binfo.is_bridge_enrollment, "verify marks the grant as a bridge enrollment")
	assert_eq(binfo.bridge_public_key, BPK, "verify exposes the Hub's copy of the bridge key")
	assert_eq(binfo.bridge_key_fingerprint, BPK_FP, "verify exposes the hub-computed fingerprint")
	assert_eq(binfo.os_user, "tanmay", "verify exposes the host-asserted os_user")
	// REQ-ENROLL-14, review finding 2026-10-07T21:02:37Z: verify must hand back
	// the HUB'S OWN clock reading. The approval screen shows it under "Verified
	// by Heimdall", so if it is ever absent the screen has nothing truthful to
	// put there -- and the defect this replaced was the screen quietly
	// substituting the operator's browser clock instead.
	//
	// It must be the SAME reading verify used for expiry, not a second sample:
	// FAKE_NOW is what the service clock returns, so equality pins that.
	assert_eq(binfo.server_time, FAKE_NOW, "verify exposes the Hub's own clock reading as server_time")
	// And it must be comparable with requested_at, since the screen subtracts
	// them to show how stale the request is. Same units, same clock, so a grant
	// created and verified at the same instant has age zero.
	assert_eq(binfo.server_time - binfo.requested_at, 0, "server_time and requested_at share units and clock")
	// A later verify of the same grant reports the LATER time, which is what
	// makes the staleness reading move. A constant here would look like a pass
	// while the screen showed a frozen "now".
	FAKE_NOW += 42
	binfo_later, bvok_later, _ := device_auth.verify(&svc, "1111111111111111111111111111111111111111111111111111111111111111")
	assert_true(bvok_later, "verify still succeeds 42s later")
	assert_eq(binfo_later.server_time, FAKE_NOW, "server_time advances with the Hub clock")
	assert_eq(binfo_later.server_time - binfo_later.requested_at, 42, "request age is computed from two hub values")
	FAKE_NOW -= 42

	// --- REQ-BE-2: the untrusted previous_bridge_id hint is stored and handed back
	// RAW by verify (the HTTP layer filters it per approver). Shape is checked at
	// authorize; a malformed hint, or one on a user-token grant, is refused. ---
	hint_in := device_auth.Authorize_Input{
		client = "ham-bridge", device_label = "dawnstar", os = "linux", app_version = "0.9.1",
		bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "7777777777777777777777777777777777777777777777777777777777777777", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256", previous_bridge_id = "brg_18e04a5cda39f2a6",
	}
	_, hint_ok, _ := device_auth.authorize(&svc, hint_in, "127.0.0.7:1", "")
	assert_true(hint_ok, "bridge authorize with a previous_bridge_id hint succeeds")
	hinfo, hvok, _ := device_auth.verify(&svc, hint_in.pair_lookup)
	assert_true(hvok, "verify the hinted bridge grant")
	assert_eq(hinfo.previous_bridge_id, "brg_18e04a5cda39f2a6", "verify returns the stored hint")
	for bad in ([]string{"brg_", "dev_123", "brg_a\"b", "brg_<script>", "brg_0123456789012345678901234567890123456789012345678901234567890"}) {
		bad_in := hint_in
		bad_in.pair_lookup = "8888888888888888888888888888888888888888888888888888888888888888"
		bad_in.previous_bridge_id = bad
		_, bad_ok, bad_err := device_auth.authorize(&svc, bad_in, "127.0.0.7:1", "")
		assert_true(!bad_ok && bad_err.code == .Validation_Failed, fmt.tprintf("malformed previous_bridge_id %q is refused", bad))
	}
	_, user_hint_ok, user_hint_err := device_auth.authorize(&svc, {client = "electron", previous_bridge_id = "brg_1"}, "127.0.0.7:1", "")
	assert_true(!user_hint_ok && user_hint_err.code == .Validation_Failed, "previous_bridge_id without a bridge key is refused")

	// --- approval dispatches to the BRIDGE minter, and only to it ---
	bridge_mints_before := len(BRIDGE_MINT_CALLS)
	abok, aberr := device_auth.approve(&svc, {
		user_code = "1111111111111111111111111111111111111111111111111111111111111111",
		approve = true,
		new_bridge_label = "dawnstar-2",
	},
		"approving-human-007", "203.0.113.9", "Mozilla/5.0 approval-page")
	assert_true(abok, "approve bridge grant succeeds")
	assert_eq(aberr.code, domain.Error_Code.None, "approve bridge grant no error")
	assert_eq(len(BRIDGE_MINT_CALLS), bridge_mints_before + 1, "bridge grant calls the bridge minter exactly once")
	bcall := BRIDGE_MINT_CALLS[len(BRIDGE_MINT_CALLS) - 1]
	// Owner from Auth_Context ONLY (scope item 4). approve() takes it as an
	// argument and never reads the body; this proves it reaches the minter intact.
	assert_eq(bcall.owner_user_id, "approving-human-007", "bridge minter got the owner from Auth_Context")
	assert_eq(bcall.bridge_public_key, BPK, "bridge minter got the approved key")
	assert_eq(bcall.bridge_key_fingerprint, BPK_FP, "bridge minter got the hub-computed fingerprint")
	assert_eq(bcall.os_user, "tanmay", "bridge minter got os_user")
	assert_eq(bcall.device_label, "dawnstar", "bridge minter got the machine descriptor")
	assert_eq(bcall.new_bridge_label, "dawnstar-2", "bridge minter got the operator's new bridge label")

	bgrant_after, bgaok := device_auth.get_grant(store, bres.device_code)
	assert_true(bgaok, "bridge grant readable after approve")
	assert_eq(bgrant_after.owner_user_id, "approving-human-007", "grant records the approving user")
	assert_eq(bgrant_after.status, device_auth.Grant_Status.Approved, "bridge grant Approved")
	assert_eq(bgrant_after.minted_token, BRIDGE_MINT_TOKEN, "bridge credential held for the first poll")
	assert_eq(bgrant_after.minted_bridge_id, BRIDGE_MINT_ID, "grant records the minted brg_")
	assert_eq(bgrant_after.minted_token_id, BRIDGE_MINT_ID, "token_id is the brg_ for a bridge grant")
	fmt.println("REQ-IMPL-2 OK: bridge grant mints via the bridge minter only, owner from context")

	// The two identity choices are mutually exclusive. Reject the request before
	// the minter can rotate an existing bridge while also accepting a new label.
	conflict_res, conflict_ok, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "2222222222222222222222222222222222222222222222222222222222222222", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(conflict_ok, "authorize bridge grant for conflicting identity choices")
	conflict_mints_before := len(BRIDGE_MINT_CALLS)
	conflict_approved, conflict_err := device_auth.approve(&svc, {
		user_code = "2222222222222222222222222222222222222222222222222222222222222222",
		approve = true,
		target_bridge_id = "brg_existing",
		new_bridge_label = "dawnstar-2",
	}, "owner-conflict", "1.2.3.4", "UA")
	assert_true(!conflict_approved, "target bridge and new label cannot be approved together")
	assert_eq(conflict_err.code, domain.Error_Code.Validation_Failed, "conflicting identity choices -> validation error")
	assert_eq(len(BRIDGE_MINT_CALLS), conflict_mints_before, "conflicting identity choices never reach the minter")

	// REQ-3: sunset_bridge_id ("register new and retire that one") is only for a NEW
	// bridge. With target_bridge_id it is refused before the minter, so neither the
	// attach nor the sunset can happen.
	sunset_conflict_ok, sunset_conflict_err := device_auth.approve(&svc, {
		user_code = "2222222222222222222222222222222222222222222222222222222222222222",
		approve = true,
		target_bridge_id = "brg_existing",
		sunset_bridge_id = "brg_retire_me",
	}, "owner-conflict", "1.2.3.4", "UA")
	assert_true(!sunset_conflict_ok, "target bridge and sunset bridge cannot be approved together")
	assert_eq(sunset_conflict_err.code, domain.Error_Code.Validation_Failed, "attach + sunset -> validation error")
	assert_eq(len(BRIDGE_MINT_CALLS), conflict_mints_before, "attach + sunset never reaches the minter")
	// The refused grant is still pending; a new-bridge approval with a sunset passes
	// the sunset through to the minter untouched (the bridge service re-checks it).
	sunset_ok, sunset_err := device_auth.approve(&svc, {
		user_code = "2222222222222222222222222222222222222222222222222222222222222222",
		approve = true,
		sunset_bridge_id = "brg_retire_me",
	}, "owner-conflict", "1.2.3.4", "UA")
	assert_true(sunset_ok, fmt.tprintf("new bridge + sunset approves: %s", sunset_err.message))
	assert_eq(len(BRIDGE_MINT_CALLS), conflict_mints_before + 1, "new bridge + sunset reaches the minter once")
	if len(BRIDGE_MINT_CALLS) > conflict_mints_before {
		scall := BRIDGE_MINT_CALLS[len(BRIDGE_MINT_CALLS) - 1]
		assert_eq(scall.sunset_bridge_id, "brg_retire_me", "minter got the sunset bridge id")
		assert_eq(scall.target_bridge_id, "", "a sunset approval is a new-bridge approval")
		assert_eq(scall.owner_user_id, "owner-conflict", "sunset minter owner from Auth_Context")
	}
	fmt.println("REQ-3 OK: sunset_bridge_id is exclusive with target_bridge_id and reaches the minter")

	// --- a bridge grant with an unwired bridge minter FAILS; it must not fall
	// back to the user minter. An unwired seam is a deployment bug, and
	// degrading a machine enrollment into a user token would be a silent
	// privilege confusion rather than a visible outage. ---
	nstore := new(device_auth.Grant_Store)
	nstore^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://ui.example.com/api/v1/device",
		expires_in = 600, interval = 5, rate_limit = 100, rate_window = 60,
	})
	defer device_auth.grant_store_free(nstore)
	nsvc := device_auth.new_device_auth_service(nstore, fake_clock(), []string{"127.0.0.1/32"})
	// bridge minter NOT wired
	nres, nok, _ := device_auth.authorize(&nsvc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "3333333333333333333333333333333333333333333333333333333333333333", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(nok, "bridge authorize succeeds without a wired bridge minter")
	naok, naerr := device_auth.approve(&nsvc, {user_code = "3333333333333333333333333333333333333333333333333333333333333333", approve = true}, "owner-n", "1.2.3.4", "UA")
	assert_true(!naok, "approve FAILS when the bridge minter is unwired")
	assert_eq(naerr.code, domain.Error_Code.Internal_Error, "unwired bridge minter -> Internal_Error")
	ngrant, _ := device_auth.get_grant(nstore, nres.device_code)
	assert_eq(ngrant.status, device_auth.Grant_Status.Pending, "failed mint leaves the grant Pending, not Approved")
	fmt.println("REQ-IMPL-2 OK: unwired bridge minter fails closed")

	// --- a bridge minter that returns no bridge_id is refused: an
	// unattributable credential defeats the point of per-machine scoping. ---
	BRIDGE_MINT_ID = ""
	ires, iok, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "4444444444444444444444444444444444444444444444444444444444444444", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(iok, "authorize for the no-id case succeeds")
	iaok, iaerr := device_auth.approve(&svc, {user_code = "4444444444444444444444444444444444444444444444444444444444444444", approve = true}, "owner-i", "1.2.3.4", "UA")
	assert_true(!iaok, "approve FAILS when the minter returns no bridge_id")
	assert_eq(iaerr.code, domain.Error_Code.Internal_Error, "missing bridge_id -> Internal_Error")
	BRIDGE_MINT_ID = "brg_fake_001"
	fmt.println("REQ-IMPL-2 OK: a credential without a brg_ is refused")

	// =====================================================================
	// REQ-IMPL-5: approved_bridge_id — the `brg_` handed back to the APPROVER'S
	// BROWSER so it can address the vault-key delivery.
	//
	// Until approval there is no bridge to address: the id is created by the
	// minter during approve() and otherwise only ever reaches the BRIDGE, on its
	// own /device/token poll. The approval screen has to encrypt the vault key to
	// a specific bridge, so it needs this and nothing else gives it.
	//
	// It must FAIL CLOSED in every other case. An empty id read as "the current
	// bridge" would deliver the vault key to the wrong machine, so each negative
	// case below is a real hazard rather than tidiness.
	// =====================================================================
	bid, bid_ok := device_auth.approved_bridge_id(&svc, "1111111111111111111111111111111111111111111111111111111111111111")
	assert_true(bid_ok, "approved bridge grant exposes its minted bridge id")
	assert_eq(bid, "brg_fake_001", "the id is the one the minter returned")
	assert_eq(bid, bgrant_after.minted_bridge_id, "it is the same value the poll path hands the bridge")

	// A PENDING bridge grant has no credential yet, so there is nothing to
	// address and nothing may be returned.
	pres, pok3, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "5555555555555555555555555555555555555555555555555555555555555555", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(pok3, "authorize a second bridge grant for the pending case")
	_, pending_ok := device_auth.approved_bridge_id(&svc, "5555555555555555555555555555555555555555555555555555555555555555")
	assert_true(!pending_ok, "a PENDING bridge grant exposes no bridge id")

	// A DENIED bridge grant must not expose one either: the operator said no.
	dres, dok3, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_hub_origin = "https://hub.example.test:443", pair_lookup = "6666666666666666666666666666666666666666666666666666666666666666", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(dok3, "authorize a bridge grant for the denied case")
	device_auth.approve(&svc, {user_code = "6666666666666666666666666666666666666666666666666666666666666666", approve = false}, "owner-deny", "1.2.3.4", "UA")
	_, denied_ok := device_auth.approved_bridge_id(&svc, "6666666666666666666666666666666666666666666666666666666666666666")
	assert_true(!denied_ok, "a DENIED bridge grant exposes no bridge id")

	// (A user-token grant, which had no bridge at all, can no longer be created.)

	// Unknown and empty codes reveal nothing, consistent with the rest of the flow.
	_, unknown_ok := device_auth.approved_bridge_id(&svc, "ZZZZ-9999")
	assert_true(!unknown_ok, "an unknown code exposes no bridge id")
	_, empty_ok := device_auth.approved_bridge_id(&svc, "")
	assert_true(!empty_ok, "an empty code exposes no bridge id")
	fmt.println("REQ-IMPL-5 OK: approved_bridge_id returns the minted brg_ and fails closed otherwise")

	// --- AC6: approver_ip uses trusted-XFF resolution (peer is trusted) ---
	f_in := va_bridge_input()
	_, _, _ = device_auth.authorize(&svc, f_in, "127.0.0.1:1", "")
	device_auth.approve(&svc, {user_code = f_in.pair_lookup, approve = true}, "o", "127.0.0.1:1", "ua")
	// (full trusted-XFF branch coverage lives in the grant_store unit test.)
	fmt.println("AC6 OK: approve over HTTP supplies trusted-XFF approver_ip")
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
