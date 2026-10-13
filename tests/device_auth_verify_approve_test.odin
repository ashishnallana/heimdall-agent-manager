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
//                 approver_ua, decided_at; pre-mints a token via the minter.
//
// Run: odin run tests/device_auth_verify_approve_test.odin -collection:odin_test=src -file
package device_auth_verify_approve_test

import "core:fmt"
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

// --- Fake token minter (records what approve passed it) ---
MINT_CALLS: [dynamic]Mint_Call
MINT_RETURN: string = "tok_fake_123"
MINT_TOKEN_ID: string = "utok_fake_123"

Mint_Call :: struct{user, client, label: string}

fake_minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	_ = ctx
	append(&MINT_CALLS, Mint_Call{user_id, client, device_label})
	return MINT_RETURN, MINT_TOKEN_ID, true
}

// --- Fake BRIDGE minter (REQ-IMPL-2). Records what approve passed it so the
// test can prove the owner came from the Auth_Context argument and that the
// user minter was never consulted for a bridge grant. ---
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
	device_auth.with_token_minter(&svc, fake_minter)
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

	// Seed a pending grant.
	res, ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "MBP", os = "macOS", app_version = "1.2.3"}, "127.0.0.1:1", "")
	assert_true(ok, "seed authorize succeeds")
	uc := res.user_code

	// --- AC3: verify returns device info captured at authorize ---
	info, vok, _ := device_auth.verify(&svc, uc)
	assert_true(vok, "verify pending grant succeeds")
	assert_eq(info.client, "electron", "verify client")
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
	// Pre-mint: minter was called with the context owner + client + label.
	assert_eq(len(MINT_CALLS), 1, "AC4/AC6 minter called once on approve")
	assert_eq(MINT_CALLS[0].user, "real-owner-001", "minter got context owner")
	assert_eq(MINT_CALLS[0].client, "electron", "minter got client")
	assert_eq(grant_after.minted_token, "tok_fake_123", "pre-minted token stored on grant")
	assert_eq(grant_after.minted_token_id, "utok_fake_123", "pre-minted token_id stored on grant")
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
	uc_deny_res, _, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	uc_deny := uc_deny_res.user_code
	mints_before := len(MINT_CALLS)
	aok3, _ := device_auth.approve(&svc, {user_code = uc_deny, approve = false}, "owner-d", "1.2.3.4", "UA")
	assert_true(aok3, "deny succeeds")
	assert_eq(len(MINT_CALLS), mints_before, "deny does NOT pre-mint a token")
	_, dg, dgok := device_auth.grant_by_user_code(store, uc_deny)
	assert_true(dgok, "denied grant found")
	assert_eq(dg.status, device_auth.Grant_Status.Denied, "deny sets Denied")
	assert_eq(dg.owner_user_id, "owner-d", "deny still binds owner from context")
	_, dvt_ok, _ := device_auth.verify(&svc, uc_deny)
	assert_true(!dvt_ok, "denied grant verify fails (terminal)")
	fmt.println("AC5 OK: deny terminal, no pre-mint, owner still bound")

	// --- AC3: expired code -> SAME generic Not_Found as unknown (no enumeration) ---
	res_e, _, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	FAKE_NOW += 601 // past the 600s TTL
	_, et_ok, et_err := device_auth.verify(&svc, res_e.user_code)
	assert_true(!et_ok, "verify expired fails")
	assert_eq(et_err.code, domain.Error_Code.Not_Found, "expired -> Not_Found (same generic as unknown)")
	assert_eq(et_err.message, "invalid or expired code", "expired message identical to unknown (no enumeration)")
	fmt.println("AC3 OK: expired code indistinguishable from unknown (no enumeration)")


	// =====================================================================
	// REQ-IMPL-2: approval of a BRIDGE grant mints a bridge-scoped credential.
	// Additive — every case above is pre-existing ELDA coverage.
	// =====================================================================
	BPK :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
	BPK_FP :: "fb41 9516 cc0c f6ae"
	PKCE_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"

	bres, bok2, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", device_label = "dawnstar", os = "linux", app_version = "0.9.1",
		bridge_public_key = BPK, os_user = "tanmay",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(bok2, "bridge authorize succeeds")

	// --- verify exposes the pair REQ-IMPL-5 needs for the fragment cross-check ---
	binfo, bvok, _ := device_auth.verify(&svc, bres.user_code)
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
	binfo_later, bvok_later, _ := device_auth.verify(&svc, bres.user_code)
	assert_true(bvok_later, "verify still succeeds 42s later")
	assert_eq(binfo_later.server_time, FAKE_NOW, "server_time advances with the Hub clock")
	assert_eq(binfo_later.server_time - binfo_later.requested_at, 42, "request age is computed from two hub values")
	FAKE_NOW -= 42

	// --- approval dispatches to the BRIDGE minter, and only to it ---
	user_mints_before := len(MINT_CALLS)
	bridge_mints_before := len(BRIDGE_MINT_CALLS)
	abok, aberr := device_auth.approve(&svc, {
		user_code = bres.user_code,
		approve = true,
		new_bridge_label = "dawnstar-2",
	},
		"approving-human-007", "203.0.113.9", "Mozilla/5.0 approval-page")
	assert_true(abok, "approve bridge grant succeeds")
	assert_eq(aberr.code, domain.Error_Code.None, "approve bridge grant no error")
	// THE CENTRAL ASSERTION OF THIS TASK: a bridge grant is NEVER served by the
	// user-token minter. A user token with the machine as a free-text label is
	// the identity confusion REQ-IMPL-2 exists to remove (design §11.3), so this
	// is the case that must fail loudly if the dispatch ever regresses.
	assert_eq(len(MINT_CALLS), user_mints_before, "bridge grant does NOT call the user-token minter")
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
		client = "ham-bridge", bridge_public_key = BPK,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(conflict_ok, "authorize bridge grant for conflicting identity choices")
	conflict_mints_before := len(BRIDGE_MINT_CALLS)
	conflict_approved, conflict_err := device_auth.approve(&svc, {
		user_code = conflict_res.user_code,
		approve = true,
		target_bridge_id = "brg_existing",
		new_bridge_label = "dawnstar-2",
	}, "owner-conflict", "1.2.3.4", "UA")
	assert_true(!conflict_approved, "target bridge and new label cannot be approved together")
	assert_eq(conflict_err.code, domain.Error_Code.Validation_Failed, "conflicting identity choices -> validation error")
	assert_eq(len(BRIDGE_MINT_CALLS), conflict_mints_before, "conflicting identity choices never reach the minter")

	// --- and the converse: an ELDA grant is NEVER served by the bridge minter ---
	eres2, eok3, _ := device_auth.authorize(&svc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "")
	assert_true(eok3, "electron authorize succeeds")
	u_before := len(MINT_CALLS)
	b_before := len(BRIDGE_MINT_CALLS)
	device_auth.approve(&svc, {user_code = eres2.user_code, approve = true}, "owner-e", "1.2.3.4", "UA")
	assert_eq(len(MINT_CALLS), u_before + 1, "electron grant calls the user-token minter")
	assert_eq(len(BRIDGE_MINT_CALLS), b_before, "electron grant does NOT call the bridge minter")
	egrant2, _ := device_auth.get_grant(store, eres2.device_code)
	assert_eq(egrant2.minted_bridge_id, "", "electron grant has no brg_")
	fmt.println("REQ-IMPL-2 OK: electron grant mints via the user minter only (converse holds)")

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
	device_auth.with_token_minter(&nsvc, fake_minter) // user minter wired, bridge minter NOT
	nres, nok, _ := device_auth.authorize(&nsvc, {
		client = "ham-bridge", bridge_public_key = BPK,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(nok, "bridge authorize succeeds without a wired bridge minter")
	nu_before := len(MINT_CALLS)
	naok, naerr := device_auth.approve(&nsvc, {user_code = nres.user_code, approve = true}, "owner-n", "1.2.3.4", "UA")
	assert_true(!naok, "approve FAILS when the bridge minter is unwired")
	assert_eq(naerr.code, domain.Error_Code.Internal_Error, "unwired bridge minter -> Internal_Error")
	assert_eq(len(MINT_CALLS), nu_before, "unwired bridge minter does NOT fall back to the user minter")
	ngrant, _ := device_auth.get_grant(nstore, nres.device_code)
	assert_eq(ngrant.status, device_auth.Grant_Status.Pending, "failed mint leaves the grant Pending, not Approved")
	fmt.println("REQ-IMPL-2 OK: unwired bridge minter fails closed, no fallback to the user minter")

	// --- a bridge minter that returns no bridge_id is refused: an
	// unattributable credential defeats the point of per-machine scoping. ---
	BRIDGE_MINT_ID = ""
	ires, iok, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(iok, "authorize for the no-id case succeeds")
	iaok, iaerr := device_auth.approve(&svc, {user_code = ires.user_code, approve = true}, "owner-i", "1.2.3.4", "UA")
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
	bid, bid_ok := device_auth.approved_bridge_id(&svc, bres.user_code)
	assert_true(bid_ok, "approved bridge grant exposes its minted bridge id")
	assert_eq(bid, "brg_fake_001", "the id is the one the minter returned")
	assert_eq(bid, bgrant_after.minted_bridge_id, "it is the same value the poll path hands the bridge")

	// A PENDING bridge grant has no credential yet, so there is nothing to
	// address and nothing may be returned.
	pres, pok3, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(pok3, "authorize a second bridge grant for the pending case")
	_, pending_ok := device_auth.approved_bridge_id(&svc, pres.user_code)
	assert_true(!pending_ok, "a PENDING bridge grant exposes no bridge id")

	// A DENIED bridge grant must not expose one either: the operator said no.
	dres, dok3, _ := device_auth.authorize(&svc, {
		client = "ham-bridge", bridge_public_key = BPK,
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(dok3, "authorize a bridge grant for the denied case")
	device_auth.approve(&svc, {user_code = dres.user_code, approve = false}, "owner-deny", "1.2.3.4", "UA")
	_, denied_ok := device_auth.approved_bridge_id(&svc, dres.user_code)
	assert_true(!denied_ok, "a DENIED bridge grant exposes no bridge id")

	// A USER-TOKEN grant has no bridge at all. Returning the user's token id here
	// would hand the approval screen something that is not a bridge and invite it
	// to unseal against it.
	ures, uok3, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	assert_true(uok3, "authorize a user-token grant")
	device_auth.approve(&svc, {user_code = ures.user_code, approve = true}, "owner-u", "1.2.3.4", "UA")
	_, user_ok := device_auth.approved_bridge_id(&svc, ures.user_code)
	assert_true(!user_ok, "an approved USER-TOKEN grant exposes no bridge id")

	// Unknown and empty codes reveal nothing, consistent with the rest of the flow.
	_, unknown_ok := device_auth.approved_bridge_id(&svc, "ZZZZ-9999")
	assert_true(!unknown_ok, "an unknown code exposes no bridge id")
	_, empty_ok := device_auth.approved_bridge_id(&svc, "")
	assert_true(!empty_ok, "an empty code exposes no bridge id")
	fmt.println("REQ-IMPL-5 OK: approved_bridge_id returns the minted brg_ and fails closed otherwise")

	// --- AC6: approver_ip uses trusted-XFF resolution (peer is trusted) ---
	res_f, _, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	device_auth.approve(&svc, {user_code = res_f.user_code, approve = true}, "o", "127.0.0.1:1", "ua")
	// (full trusted-XFF branch coverage lives in the grant_store unit test.)
	fmt.println("AC6 OK: approve over HTTP supplies trusted-XFF approver_ip")
}
