// Unit tests for the /device/token poll lifecycle (ELDA-3) and device-token
// issuance boundary (ELDA-4 token_id propagation).
//
// Covers:
//   AC1: pending -> approved(token) -> used/expired; denied; expired;
//        slow_down/429 with Retry-After.
//   AC2: unknown device_code -> pending (anti-enumeration).
//   AC3: approved token is single-use; plaintext cleared after first poll.
//   AC7: public token polling is rate-limited per IP.
//
// Run: odin run tests/device_auth_token_poll_test.odin -collection:odin_test=src -file
package device_auth_token_poll_test

import "core:encoding/json"
import "core:fmt"
import "core:crypto/ecdsa"
import vault "odin_test:lib/vault"
import "core:testing"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import api_http "odin_test:hub/transport/http"

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

FAKE_NOW: i64 = 7_000_000
fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

MINT_COUNT: int = 0
fake_minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	_ = ctx
	_ = user_id
	_ = client
	_ = device_label
	MINT_COUNT += 1
	return "hut_fake_poll_token", "utok_fake_poll", true
}

new_service :: proc(rate_limit := 100, interval := 5) -> (^device_auth.Grant_Store, device_auth.Device_Auth_Service) {
	store := new(device_auth.Grant_Store)
	store^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600,
		interval = interval,
		rate_limit = rate_limit,
		rate_window = 60,
	})
	svc := device_auth.new_device_auth_service(store, fake_clock(), []string{"127.0.0.1/32"})
	device_auth.with_token_minter(&svc, fake_minter)
	device_auth.with_bridge_token_minter(&svc, fake_bridge_minter)
	return store, svc
}

// --- Fake BRIDGE minter (REQ-IMPL-2) ---
BRIDGE_MINT_COUNT: int = 0
fake_bridge_minter :: proc(ctx: rawptr, req: device_auth.Bridge_Mint_Request) -> (device_auth.Bridge_Mint_Result, bool) {
	_ = ctx
	_ = req
	BRIDGE_MINT_COUNT += 1
	// REQ-IMPL-3: an expiring pair. expires_in is the CREDENTIAL's hour, which is
	// deliberately different from this store's 600s grant window — poll must report
	// the credential's lifetime, not the flow's.
	return device_auth.Bridge_Mint_Result{
		access_token = "hba_btk_poll_fake.secret",
		refresh_token = "hbf_btk_poll_fake.refresh",
		bridge_id = "brg_poll_fake",
		expires_in = 3600,
		refresh_expires_in = 2592000,
		vault_delivery_expected = true,
	}, true
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if strings.to_lower(h.name) == strings.to_lower(name) do return h.value
	}
	return ""
}

@(test)
test_device_auth_token_poll_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	fmt.println("=== device_auth token poll ===")
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

	res, ok, err := device_auth.authorize(&svc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "")
	assert_true(ok, "authorize for poll lifecycle succeeds")
	assert_eq(err.code, domain.Error_Code.None, "authorize no error")

	// AC2: unknown device_code never reveals validity.
	unknown, unknown_err := device_auth.poll(&svc, "not-a-real-device-code", "203.0.113.20")
	assert_eq(unknown_err.code, domain.Error_Code.None, "unknown poll has no error")
	assert_eq(unknown.status, device_auth.Poll_Status.Pending, "unknown device_code -> pending")

	// AC1: pending while not yet approved; too-fast second poll -> slow_down.
	pending, pending_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(pending_err.code, domain.Error_Code.None, "pending poll no error")
	assert_eq(pending.status, device_auth.Poll_Status.Pending, "unapproved grant -> pending")
	too_fast, too_fast_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(too_fast.status, device_auth.Poll_Status.Slow_Down, "too-fast poll -> slow_down")
	assert_eq(too_fast_err.code, domain.Error_Code.Rate_Limited, "too-fast poll -> Rate_Limited")

	// AC1/AC3: once approved and polled at interval, token is returned once, then expired.
	FAKE_NOW += 5
	aok, aerr := device_auth.approve(&svc, {user_code = res.user_code, approve = true}, "owner-1", "203.0.113.30", "UA")
	assert_true(aok, "approve for token poll succeeds")
	assert_eq(aerr.code, domain.Error_Code.None, "approve no error")
	approved, approved_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(approved_err.code, domain.Error_Code.None, "approved poll no error")
	assert_eq(approved.status, device_auth.Poll_Status.Approved, "approved grant -> approved status")
	assert_eq(approved.access_token, "hut_fake_poll_token", "approved poll returns plaintext token")
	assert_eq(approved.token_id, "utok_fake_poll", "approved poll returns authoritative token_id")
	assert_eq(approved.expires_in, 600, "approved poll returns expires_in")
	used_grant, used_ok := device_auth.get_grant(store, res.device_code)
	assert_true(used_ok, "used grant remains recorded")
	assert_eq(used_grant.status, device_auth.Grant_Status.Used, "approved poll marks grant Used")
	assert_eq(used_grant.minted_token, "", "approved poll clears plaintext token from grant")
	replay, replay_err := device_auth.poll(&svc, res.device_code, "203.0.113.21")
	assert_eq(replay_err.code, domain.Error_Code.None, "used replay no error")
	assert_eq(replay.status, device_auth.Poll_Status.Expired, "used grant replay -> expired")
	fmt.println("AC1/AC2/AC3 OK: pending, slow_down, approved single-use, unknown")

	// AC1: denied grants poll as denied.
	FAKE_NOW += 10
	denied_res, dok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	assert_true(dok, "authorize denied grant succeeds")
	device_auth.approve(&svc, {user_code = denied_res.user_code, approve = false}, "owner-1", "203.0.113.30", "UA")
	denied, denied_err := device_auth.poll(&svc, denied_res.device_code, "203.0.113.22")
	assert_eq(denied_err.code, domain.Error_Code.None, "denied poll no error")
	assert_eq(denied.status, device_auth.Poll_Status.Denied, "denied grant -> denied")

	// AC1: TTL expiry polls as expired.
	exp_res, eok, _ := device_auth.authorize(&svc, {client = "electron"}, "127.0.0.1:1", "")
	assert_true(eok, "authorize expired grant succeeds")
	FAKE_NOW += 601
	expired, expired_err := device_auth.poll(&svc, exp_res.device_code, "203.0.113.23")
	assert_eq(expired_err.code, domain.Error_Code.None, "expired poll no error")
	assert_eq(expired.status, device_auth.Poll_Status.Expired, "expired grant -> expired")
	fmt.println("AC1 OK: denied and expired states")


	// =====================================================================
	// REQ-IMPL-2: PKCE on redemption (RFC 7636 §4.6).
	//
	// The rule is conditional on purpose: a verifier is REQUIRED iff the grant
	// carries a challenge. That keeps the pre-existing Electron poll — which
	// sends no verifier, and whose cases above still pass — working untouched,
	// while making a bridge grant unredeemable by anything but the process that
	// started the flow.
	// =====================================================================
	BPK :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
	IDP, IDPROOF := test_bridge_identity(BPK, PKCE_CHALLENGE)
	PKCE_VERIFIER :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	PKCE_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"
	// A different, well-formed verifier whose SHA-256 is NOT the challenge above.
	WRONG_VERIFIER :: "testverifier-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	pstore, psvc := new_service()
	defer device_auth.grant_store_free(pstore)
	PFAKE_BASE := FAKE_NOW
	_ = PFAKE_BASE

	bres, bok, _ := device_auth.authorize(&psvc, {
		client = "ham-bridge", device_label = "dawnstar", os = "linux",
		bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_lookup = "1111111111111111111111111111111111111111111111111111111111111111", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", os_user = "tanmay",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(bok, "bridge authorize for PKCE poll succeeds")
	bmints_before := BRIDGE_MINT_COUNT
	abok, _ := device_auth.approve(&psvc, {user_code = "1111111111111111111111111111111111111111111111111111111111111111", approve = true}, "owner-pkce", "203.0.113.30", "UA")
	assert_true(abok, "approve bridge grant for PKCE poll succeeds")
	assert_eq(BRIDGE_MINT_COUNT, bmints_before + 1, "bridge minter ran on approve")

	// 1. No verifier at all -> rejected. This is the case that would silently
	//    pass if the challenge were persisted but never checked.
	nov, nov_err := device_auth.poll(&psvc, bres.device_code, "203.0.113.40")
	assert_eq(nov.status, device_auth.Poll_Status.Invalid_Grant, "approved bridge grant with NO verifier -> Invalid_Grant")
	assert_eq(nov_err.code, domain.Error_Code.Unauthenticated, "missing verifier -> Unauthenticated (401)")
	assert_eq(nov.access_token, "", "no token handed out without a verifier")

	// 2. A wrong verifier -> rejected, AND the grant is not burned. Otherwise
	//    anyone holding the device_code could deny the real bridge its
	//    credential by polling once with garbage.
	FAKE_NOW += 5
	wrongv, wrongv_err := device_auth.poll(&psvc, bres.device_code, "203.0.113.40", WRONG_VERIFIER)
	assert_eq(wrongv.status, device_auth.Poll_Status.Invalid_Grant, "wrong verifier -> Invalid_Grant")
	assert_eq(wrongv_err.code, domain.Error_Code.Unauthenticated, "wrong verifier -> Unauthenticated")
	assert_eq(wrongv.access_token, "", "no token handed out for a wrong verifier")
	still, still_ok := device_auth.get_grant(pstore, bres.device_code)
	assert_true(still_ok, "grant survives a failed verifier")
	assert_eq(still.status, device_auth.Grant_Status.Approved, "a failed verifier does NOT burn the grant")
	assert_true(still.minted_token != "", "the credential is still held for the legitimate bridge")

	// 3. The correct verifier succeeds, and returns the brg_ the credential is
	//    scoped to — the bridge learns its own id here rather than asserting one.
	FAKE_NOW += 5
	good, good_err := device_auth.poll(&psvc, bres.device_code, "203.0.113.40", PKCE_VERIFIER)
	assert_eq(good_err.code, domain.Error_Code.None, "correct verifier poll no error")
	assert_eq(good.status, device_auth.Poll_Status.Approved, "correct verifier -> approved")
	assert_eq(good.access_token, "hba_btk_poll_fake.secret", "correct verifier returns the bridge credential")
	// REQ-IMPL-3: the refresh half rides the SAME single-use poll. A bridge that
	// received only the access token could never renew and would be unrecoverable
	// after an hour, so this is part of the poll contract, not an extra.
	assert_eq(good.refresh_token, "hbf_btk_poll_fake.refresh", "the refresh half is handed over in the same poll")
	assert_true(good.expires_in == 3600, "expires_in is the CREDENTIAL's lifetime, not the grant window")
	assert_true(good.refresh_expires_in == 2592000, "refresh lifetime is reported to the bridge")
	assert_eq(good.bridge_id, "brg_poll_fake", "approved bridge poll returns the brg_ it is scoped to")
	assert_true(good.vault_delivery_expected, "approved bridge poll tells enrollment to await the stored vault envelope")

	// 4. Single-use still holds for a bridge grant: the second redemption is
	//    Expired even with the right verifier.
	FAKE_NOW += 5
	replay2, _ := device_auth.poll(&psvc, bres.device_code, "203.0.113.40", PKCE_VERIFIER)
	assert_eq(replay2.status, device_auth.Poll_Status.Expired, "bridge credential is single-use (replay -> expired)")
	fmt.println("REQ-IMPL-2 OK: PKCE enforced on redemption; wrong verifier rejected without burning the grant")

	// 5. An ELDA grant (no challenge) still redeems with NO verifier — the
	//    pre-existing contract is unchanged — and a stray verifier on such a
	//    grant is simply ignored rather than becoming a new failure mode.
	eres2, eok2, _ := device_auth.authorize(&psvc, {client = "electron", device_label = "MBP"}, "127.0.0.1:1", "")
	assert_true(eok2, "electron authorize succeeds")
	FAKE_NOW += 5
	device_auth.approve(&psvc, {user_code = eres2.user_code, approve = true}, "owner-e2", "203.0.113.30", "UA")
	epoll, epoll_err := device_auth.poll(&psvc, eres2.device_code, "203.0.113.41")
	assert_eq(epoll_err.code, domain.Error_Code.None, "electron poll with no verifier no error")
	assert_eq(epoll.status, device_auth.Poll_Status.Approved, "electron grant redeems with NO verifier (unchanged)")
	assert_eq(epoll.access_token, "hut_fake_poll_token", "electron grant still returns its user token")
	assert_eq(epoll.bridge_id, "", "electron grant carries no brg_")
	assert_true(!epoll.vault_delivery_expected, "electron grant never requests bridge vault delivery")
	eres3, _, _ := device_auth.authorize(&psvc, {client = "electron"}, "127.0.0.1:1", "")
	FAKE_NOW += 5
	device_auth.approve(&psvc, {user_code = eres3.user_code, approve = true}, "owner-e3", "203.0.113.30", "UA")
	epoll3, _ := device_auth.poll(&psvc, eres3.device_code, "203.0.113.42", PKCE_VERIFIER)
	assert_eq(epoll3.status, device_auth.Poll_Status.Approved, "a stray verifier on a challenge-less grant is ignored")
	fmt.println("REQ-IMPL-2 OK: the pre-existing Electron poll contract is unchanged")

	// 6. Through the HTTP handler: a PKCE failure is a 401, not a 200 with a
	//    status field, so a bridge with the wrong verifier cannot mistake it for
	//    "keep polling".
	hres, hok, _ := device_auth.authorize(&psvc, {
		client = "ham-bridge", bridge_public_key = BPK, bridge_identity_public_key = IDP, bridge_identity_proof = IDPROOF, pair_salt = "0123456789abcdef0123456789abcdef", pair_lookup = "2222222222222222222222222222222222222222222222222222222222222222", pair_key_mac = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
		code_challenge = PKCE_CHALLENGE, code_challenge_method = "S256",
	}, "127.0.0.1:1", "")
	assert_true(hok, "bridge authorize for handler test succeeds")
	FAKE_NOW += 5
	device_auth.approve(&psvc, {user_code = "2222222222222222222222222222222222222222222222222222222222222222", approve = true}, "owner-h", "203.0.113.30", "UA", "alice")
	phandlers := api_http.Device_Auth_Handlers{service = &psvc}
	FAKE_NOW += 5
	bad_resp := api_http.device_token_handler(rawptr(&phandlers), api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = tp_poll_body(hres.device_code, WRONG_VERIFIER),
		request_id = "req_pkce_bad", remote_addr = "127.0.0.1:4444",
	})
	assert_eq(bad_resp.status, 401, "handler: wrong verifier -> HTTP 401")
	assert_true(!strings.contains(bad_resp.body, "\"status\":\"pending\""), "handler: a PKCE failure is not reported as pending")
	FAKE_NOW += 5
	good_resp := api_http.device_token_handler(rawptr(&phandlers), api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = tp_poll_body(hres.device_code, PKCE_VERIFIER),
		request_id = "req_pkce_good", remote_addr = "127.0.0.1:4444",
	})
	assert_eq(good_resp.status, 200, "handler: correct verifier -> HTTP 200")
	assert_true(strings.contains(good_resp.body, "\"approver_username\":\"alice\""), "handler: approved poll reports the authenticated approving username")
	assert_true(strings.contains(good_resp.body, "\"bridge_id\":\"brg_poll_fake\""), "handler: approved bridge poll carries bridge_id")
	assert_true(strings.contains(good_resp.body, "\"vault_delivery_expected\":true"), "handler: bridge poll carries the vault handoff decision")
	fmt.println("REQ-IMPL-2 OK: handler maps a PKCE failure to 401 and emits bridge_id on success")


	// =====================================================================
	// REGRESSION (found end-to-end on the live dev stack, REQ-IMPL-2):
	// set_grant must not leave the user_code index ALIASING CALLER MEMORY.
	//
	// The old line was `store.by_user_code[grant.user_code] = device_code`,
	// where `device_code` arrives straight from the caller. On the poll path the
	// caller is the HTTP handler and that string is
	// `jsonx.extract_string(..., context.allocator)` — a per-request allocation
	// the server reclaims after the response. A process-lifetime index was
	// therefore left pointing at memory the next request reuses, and
	// `/device/verify` answered "invalid or expired code" for a live grant.
	//
	// ON THE LIVE STACK THIS WAS DETERMINISTIC, not a rare race: one
	// `/device/token` poll on a pending grant permanently broke
	// `/device/verify` for that user_code while the device_code kept working
	// (reproduced against the hub on 127.0.0.1:8193 — authorize, poll, verify).
	// RFC 8628 has the device polling while the human is still on the approval
	// page, so this was the normal path, and it affected the pre-existing
	// Electron flow too.
	//
	// WHY THIS TEST ASSERTS THE INVARIANT AND NOT THE SYMPTOM: reproducing the
	// symptom in-process needs an arena that is actually reset between requests,
	// which this harness does not have — a test that keeps the caller's string
	// alive sees nothing wrong, because the dangling alias still reads the right
	// bytes. So the guard is the OWNERSHIP RULE this file documents at the top:
	// the `grants` map owns every string, and `by_user_code` only aliases
	// strings that map owns. Comparing the backing pointers proves exactly that,
	// and fails the moment anyone reintroduces the caller-aliasing assignment.
	// =====================================================================
	rstore, rsvc := new_service()
	defer device_auth.grant_store_free(rstore)
	rres, rok, _ := device_auth.authorize(&rsvc, {client = "electron", device_label = "index-regression"}, "127.0.0.1:1", "")
	assert_true(rok, "regression: authorize succeeds")
	_, rv1_ok, _ := device_auth.verify(&rsvc, rres.user_code)
	assert_true(rv1_ok, "regression: user_code resolves before any poll")

	// Hand set_grant a device_code string the TEST owns, the way a handler hands
	// it a request-scoped one.
	caller_dc := strings.clone(rres.device_code)
	defer delete(caller_dc)
	caller_uc := strings.clone(rres.user_code)
	defer delete(caller_uc)
	grant_snapshot, gs_ok := device_auth.get_grant(rstore, rres.device_code)
	assert_true(gs_ok, "regression: grant readable before set_grant")
	grant_snapshot.user_code = caller_uc
	grant_snapshot.last_poll_at = FAKE_NOW
	device_auth.set_grant(rstore, caller_dc, grant_snapshot)

	// THE ASSERTION: what the index hands back must be store-owned memory, not
	// the caller's buffer.
	indexed_dc, _, idx_ok := device_auth.grant_by_user_code(rstore, caller_uc)
	assert_true(idx_ok, "REGRESSION: user_code still resolves after set_grant")
	assert_eq(indexed_dc, caller_dc, "regression: the indexed device_code has the right VALUE")
	assert_true(
		raw_data(indexed_dc) != raw_data(caller_dc),
		"REGRESSION: by_user_code must own its device_code, NOT alias the caller's string (a request-arena alias here is a use-after-free)",
	)
	// Same rule for the user_code the index is keyed on, reached through the
	// grant the store returns.
	_, indexed_grant, ig_ok := device_auth.grant_by_user_code(rstore, caller_uc)
	assert_true(ig_ok, "regression: grant reachable by user_code")
	assert_true(
		raw_data(indexed_grant.user_code) != raw_data(caller_uc),
		"REGRESSION: the stored grant must own its user_code, not alias the caller's",
	)

	// And the behaviour the invariant protects: poll -> verify -> approve -> poll
	// completes, which is the real order of events in RFC 8628.
	FAKE_NOW += 10
	rhandlers := api_http.Device_Auth_Handlers{service = &rsvc}
	rbody := tp_poll_body(rres.device_code)
	rresp := api_http.device_token_handler(rawptr(&rhandlers), api_http.Request{
		method = "POST", path = "/api/v1/device/token", body = rbody,
		request_id = "req_index_regression", remote_addr = "127.0.0.1:4444",
	})
	assert_eq(rresp.status, 200, "regression: poll on a pending grant returns 200")
	assert_true(strings.contains(rresp.body, "\"status\":\"pending\""), "regression: poll reports pending")
	_, rv2_ok, rv2_err := device_auth.verify(&rsvc, caller_uc)
	assert_true(rv2_ok, "REGRESSION: user_code still resolves after a poll through the handler")
	assert_eq(rv2_err.code, domain.Error_Code.None, "regression: no error verifying after a poll")
	FAKE_NOW += 10
	rap_ok, rap_err := device_auth.approve(&rsvc, {user_code = caller_uc, approve = true}, "owner-reg", "1.2.3.4", "UA")
	assert_true(rap_ok, "REGRESSION: a polled grant can still be approved by user_code")
	assert_eq(rap_err.code, domain.Error_Code.None, "regression: approve after poll has no error")
	rfinal, _ := device_auth.poll(&rsvc, rres.device_code, "203.0.113.90")
	assert_eq(rfinal.status, device_auth.Poll_Status.Approved, "regression: the device gets its token after approval")
	fmt.println("REGRESSION OK: by_user_code owns its strings; poll -> verify -> approve -> poll completes")

	// AC7: independent per-IP token poll rate limit, observable through handler as
	// HTTP 429 + Retry-After.
	rate_store, rate_svc := new_service(1, 7)
	defer device_auth.grant_store_free(rate_store)
	for i in 0..<6 {
		p, perr := device_auth.poll(&rate_svc, fmt.tprintf("unknown-%d", i), "198.51.100.77")
		assert_eq(perr.code, domain.Error_Code.None, "poll rate pre-budget no error")
		assert_eq(p.status, device_auth.Poll_Status.Pending, "poll rate pre-budget unknown -> pending")
	}
	handlers := api_http.Device_Auth_Handlers{service = &rate_svc}
	resp := api_http.device_token_handler(rawptr(&handlers), api_http.Request{
		method = "POST",
		path = "/api/v1/device/token",
		body = "{\"device_code\":\"unknown-rate-limited\"}",
		request_id = "req_poll_rate",
		remote_addr = "198.51.100.77:4444",
	})
	assert_eq(resp.status, 429, "poll rate limit -> HTTP 429")
	assert_eq(header_value(resp.headers, "Retry-After"), "7", "poll rate limit sets Retry-After")
	assert_true(strings.contains(resp.body, "\"status\":\"slow_down\""), "poll rate limit body status slow_down")
	fmt.println("AC7 OK: per-IP poll rate limit + Retry-After")

	// =====================================================================
	// REGRESSION, observed in production: approving near the end of the
	// authorize-time window reported Expired to the polling device, even
	// though the UI had just confirmed "Approved -- the machine should
	// connect".
	//
	// poll() used to check is_expired(grant, now) FIRST, unconditionally,
	// before ever looking at grant.status. approve() has its own, separate
	// is_expired check, so a human clicking Approve just inside the deadline
	// genuinely succeeds -- the grant is real, the token is minted. But the
	// device's poll loop sleeps `interval` seconds between polls
	// (src/bridge/enroll_device_flow.odin), so its NEXT poll can land a few
	// seconds later, by which point now() has ticked past the ORIGINAL
	// authorize-time expires_at -- and the old unconditional check reported
	// Expired for a grant that had, in fact, just been approved, before the
	// status switch ever got to see .Approved.
	//
	// The fix guards the expiry short-circuit on grant.status == .Pending:
	// the clock bounds how long an UNDECIDED grant may sit around, not how
	// long a DECIDED one has left to be delivered to the one process polling
	// for it. This reproduces the exact timeline: authorize, advance the
	// clock to just inside the deadline, approve (succeeds), advance the
	// clock past the ORIGINAL deadline, then poll -- which must still return
	// Approved with the token, not Expired.
	// =====================================================================
	race_store, race_svc := new_service()
	defer device_auth.grant_store_free(race_store)
	race_res, race_ok, _ := device_auth.authorize(&race_svc, {client = "ham-bridge", device_label = "late-approval"}, "127.0.0.1:1", "")
	assert_true(race_ok, "regression: authorize for late-approval race succeeds")

	// The grant's window is 600s (new_service's default expires_in). Approve
	// with 5s left on the clock -- comfortably still Pending, so approve()'s
	// own is_expired check passes.
	FAKE_NOW += 595
	race_approve_ok, race_approve_err := device_auth.approve(&race_svc, {user_code = race_res.user_code, approve = true}, "owner-race", "203.0.113.50", "UA")
	assert_true(race_approve_ok, "REGRESSION: approving just inside the deadline succeeds")
	assert_eq(race_approve_err.code, domain.Error_Code.None, "regression: late approval has no error")

	// Now cross the ORIGINAL authorize-time deadline (600s total has elapsed)
	// before the device's next scheduled poll -- the exact gap the bridge's
	// own interval sleep leaves open in production.
	FAKE_NOW += 10
	race_poll, race_poll_err := device_auth.poll(&race_svc, race_res.device_code, "203.0.113.51")
	assert_eq(race_poll_err.code, domain.Error_Code.None, "REGRESSION: poll just past the original deadline has no error")
	assert_eq(race_poll.status, device_auth.Poll_Status.Approved, "REGRESSION: a grant approved in time must poll Approved, never Expired, even after the original deadline has since passed")
	assert_eq(race_poll.access_token, "hut_fake_poll_token", "regression: the approved-late grant still hands out its token")
	fmt.println("REGRESSION OK: approval just inside the deadline is not reported Expired by a poll that lands just after it")
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

// Tp_Poll_Body is the /device/token request body (typed; json.marshal).
Tp_Poll_Body :: struct {
	device_code:   string,
	code_verifier: string `json:"code_verifier,omitempty"`,
}

tp_poll_body :: proc(device_code: string, code_verifier := "") -> string {
	data, err := json.marshal(Tp_Poll_Body{device_code = device_code, code_verifier = code_verifier}, allocator = context.temp_allocator)
	assert(err == nil, "poll body encodes")
	return string(data)
}
