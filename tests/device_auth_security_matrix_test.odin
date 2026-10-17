// ELDA-6 / ELDA-7 security matrix for the device-authorization flow.
//
// Covers:
//   - owner spoof in approve body ignored; owner comes from trusted Auth_Context
//   - X-Forwarded-For honored only from trusted CIDRs (authorize + approve)
//   - user_code verify brute-force cap + cooldown
//   - authorize/token public endpoint rate limits
//   - single-use/terminal grants and unknown device_code anti-enumeration
//   - device_code/user_code unlinkability smoke
//   - audit fields queryable on grants and token provenance visible via tokens list
//
// Run: odin run tests/device_auth_security_matrix_test.odin -collection:odin_test=src -file
package device_auth_security_matrix_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import device_auth "odin_test:hub/service/device_auth"
import api_http "odin_test:hub/transport/http"

FAILURES: int = 0
FAKE_NOW: i64 = 8_000_000

fake_now :: proc() -> i64 { return FAKE_NOW }
fake_clock :: proc() -> device_auth.Monotonic_Clock { return {now = fake_now} }

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

fake_minter :: proc(ctx: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	_ = ctx
	_ = user_id
	_ = client
	_ = device_label
	return "hut_security_fake", "utok_security_fake", true
}

new_service :: proc(rate_limit := 2, interval := 5) -> (^device_auth.Grant_Store, device_auth.Device_Auth_Service) {
	store := new(device_auth.Grant_Store)
	store^ = device_auth.new_grant_store(device_auth.Grant_Store_Config{
		verification_uri = "https://auth.example.com/device/",
		expires_in = 600,
		interval = interval,
		rate_limit = rate_limit,
		rate_window = 10,
	})
	svc := device_auth.new_device_auth_service(store, fake_clock(), []string{"127.0.0.1/32"})
	device_auth.with_token_minter(&svc, fake_minter)
	return store, svc
}

@(test)
test_device_auth_security_matrix :: proc(t: ^testing.T) {
	main()
	testing.expect_value(t, FAILURES, 0)
}

main :: proc() {
	FAILURES = 0
	FAKE_NOW = 8_000_000
	fmt.println("=== device_auth security matrix ===")
	defer {
		if FAILURES == 0 {
			fmt.println("ALL PASS")
		} else {
			fmt.printfln("{} FAILURES", FAILURES)
			os.exit(1)
		}
	}

	test_unlinkability_smoke()
	test_trusted_xff_and_verify_bruteforce()
	test_public_rate_limit_and_token_single_use()
	test_http_owner_spoof_and_audit_queryability()
	test_bridge_enrollment_end_to_end()
}

// REQ-IMPL-2 end-to-end, through the real HTTP handlers and a real repository:
// bridge authorize -> human approves in the browser -> bridge redeems with its
// PKCE verifier -> the credential resolves to exactly one `brg_`.
//
// Five properties are asserted here that cannot be seen at the service layer:
//   1. The owner is the APPROVING USER from the trusted-proxy identity headers,
//      even when the body shouts a different one.
//   2. The minted credential is BRIDGE-SCOPED: verify_bridge_token resolves it
//      to a `brg_` Auth_Context, not to a bare user.
//   3. CROSS-BRIDGE IS REJECTED (chain register T9): bridge A's credential
//      cannot act for an instance owned by bridge B.
//   4. The credential does NOT derive from a timestamp: two back-to-back
//      enrolments produce unrelated secrets, and the token splits as
//      `hba_<token_id>.<secret>`. REQ-IMPL-3 moved the device-grant credential
//      from the non-expiring `hbr_<brg_>` shape to the expiring PAIR, so the id
//      half is now the token row's own `btk_` and not the bridge id — the bridge
//      is resolved from the row, which is what lets one bridge hold a lineage of
//      credentials at all.
//   5. The approved public key is on record against the bridge row.
test_bridge_enrollment_end_to_end :: proc() {
	BPK_A :: "04030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"
	BPK_A_FP :: "fb41 9516 cc0c f6ae"
	PKCE_VERIFIER :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	PKCE_CHALLENGE :: "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"
	WRONG_VERIFIER :: "testverifier-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	db_path := "/tmp/heimdall-device-auth-bridge-enroll.db"
	_ = os.remove(db_path)
	config := app.default_config()
	config.database_path = db_path
	config.migrations_dir = "src/hub/repository/sqlite/migrations"
	config.paddle_environment = "sandbox"
	graph: app.App_Graph
	graph_ok, graph_msg := app.build_graph(&graph, config)
	assert_true(graph_ok, graph_msg)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}

	trusted_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "approving-human"},
		{name = "X-authentik-name", value = "Approving Human"},
		{name = "X-authentik-email", value = "approver@example.com"},
		{name = "X-Forwarded-For", value = "203.0.113.88, 10.0.0.1"},
		{name = "User-Agent", value = "ApprovalPage/1.0"},
	}

	// --- authorize over HTTP, as an unauthenticated bridge would ---
	auth_body := strings.concatenate({
		"{\"client\":\"ham-bridge\",\"device_label\":\"dawnstar\",\"os\":\"linux\",\"app_version\":\"0.9.1\"",
		",\"bridge_public_key\":\"", BPK_A, "\"",
		",\"os_user\":\"tanmay\"",
		",\"code_challenge\":\"", PKCE_CHALLENGE, "\",\"code_challenge_method\":\"S256\"}",
	})
	auth_resp := api_http.device_authorize_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/authorize", body = auth_body,
		request_id = "req_bridge_authorize", remote_addr = "198.51.100.30:5555",
	})
	assert_eq(auth_resp.status, 200, "bridge authorize over HTTP succeeds unauthenticated")
	assert_true(strings.contains(auth_resp.body, BPK_A_FP), "authorize response echoes the hub-computed fingerprint")
	// Recover the codes from the store rather than parsing the response body.
	res_a, found_a := grant_for_label(&graph.device_auth_store, "dawnstar")
	assert_true(found_a, "bridge grant stored by authorize handler")
	assert_eq(res_a.grant_kind, device_auth.Grant_Kind.Bridge_Enrollment, "HTTP authorize derives Bridge_Enrollment")
	assert_eq(res_a.bridge_key_fingerprint, BPK_A_FP, "fingerprint on the grant is hub-computed")

	// --- the approval page sees BOTH provenance groups (REQ-ENROLL-14) ---
	verify_body := strings.concatenate({"{\"user_code\":\"", res_a.user_code, "\"}"})
	verify_resp := api_http.device_verify_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/verify", body = verify_body,
		request_id = "req_bridge_verify", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:],
	})
	assert_eq(verify_resp.status, 200, "verify succeeds through the trusted proxy")
	assert_true(strings.contains(verify_resp.body, "\"hub_observed\""), "verify payload groups hub-observed fields")
	assert_true(strings.contains(verify_resp.body, "\"host_asserted\""), "verify payload groups host-asserted fields")
	assert_true(strings.contains(verify_resp.body, "\"is_bridge_enrollment\":true"), "verify marks a bridge enrollment")
	assert_true(strings.contains(verify_resp.body, BPK_A), "verify exposes the Hub's copy of the key for the fragment cross-check")
	assert_true(strings.contains(verify_resp.body, BPK_A_FP), "verify exposes the hub-computed fingerprint")
	assert_true(strings.contains(verify_resp.body, "\"os_user\":\"tanmay\""), "verify exposes host-asserted os_user")

	// REQ-EA decision A: a bridge is enrolled only once its vault is unlocked, so the
	// approver must already have a vault. Seed one (the envelope content is opaque
	// to the hub; only its presence matters here).
	vault_saved, vault_err := iface.user_vault_save(&graph.repos.user_vaults, domain.User_Vault{
		user_id = "approving-human", encrypted_vault_key = "00", vault_key_nonce = "00", vault_key_tag = "00",
		kdf_algorithm = "PBKDF2-SHA256", kdf_salt = "00", kdf_iterations = 100000,
		recovery_encrypted_vault_key = "00", recovery_nonce = "00", recovery_tag = "00", recovery_salt = "00",
		created_at = "2026-10-16T00:00:00Z", updated_at = "2026-10-16T00:00:00Z",
	})
	assert_true(vault_saved, vault_err.message)

	// --- approve: the body tries to name a different owner; it must be ignored ---
	approve_body := strings.concatenate({
		"{\"user_code\":\"", res_a.user_code,
		"\",\"approve\":true,\"owner_user_id\":\"spoof-owner\",\"user\":\"spoof-user\"}",
	})
	approve_resp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/approve", body = approve_body,
		request_id = "req_bridge_approve", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:],
	})
	assert_eq(approve_resp.status, 200, "bridge approve succeeds through the trusted proxy")
	grant_a, ga_ok := device_auth.get_grant(&graph.device_auth_store, res_a.device_code)
	assert_true(ga_ok, "approved bridge grant queryable")
	assert_eq(grant_a.owner_user_id, "approving-human", "owner is the approving user from Auth_Context, NOT the body")
	assert_true(grant_a.minted_bridge_id != "", "approval minted a brg_")
	assert_true(strings.has_prefix(grant_a.minted_bridge_id, "brg_"), "minted identity is a brg_, not a user token id")
	bridge_id_a := strings.clone(grant_a.minted_bridge_id)
	defer delete(bridge_id_a)

	// --- redeem: the wrong verifier is a 401, the right one yields the token ---
	// The two polls go to SEPARATE grants on purpose. This graph runs on the real
	// clock, and a rejected verifier still stamps last_poll_at (so a verifier-
	// guessing loop stays subject to the per-grant interval gate) — so a second
	// poll on the same grant within `interval` would be slow_down, not a verifier
	// result. The interval gate itself is covered in the token-poll test with a
	// fake clock; here each grant is polled once.
	bad_grant, bad_found := seed_bridge_grant(&graph, "wrong-verifier-host", BPK_A, PKCE_CHALLENGE, trusted_headers[:])
	assert_true(bad_found, "seeded a second bridge grant for the wrong-verifier case")
	bad_poll := strings.concatenate({"{\"device_code\":\"", bad_grant.device_code, "\",\"code_verifier\":\"", WRONG_VERIFIER, "\"}"})
	bad_resp := api_http.device_token_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/token", body = bad_poll,
		request_id = "req_bridge_poll_bad", remote_addr = "198.51.100.31:5555",
	})
	assert_eq(bad_resp.status, 401, "redemption with the wrong PKCE verifier -> 401")
	// The rejected grant is NOT burned: the legitimate bridge can still redeem.
	bad_after, bad_after_ok := device_auth.get_grant(&graph.device_auth_store, bad_grant.device_code)
	assert_true(bad_after_ok, "the grant survives a wrong verifier")
	assert_eq(bad_after.status, device_auth.Grant_Status.Approved, "a wrong verifier does not burn the grant")
	good_poll := strings.concatenate({"{\"device_code\":\"", res_a.device_code, "\",\"code_verifier\":\"", PKCE_VERIFIER, "\"}"})
	good_resp := api_http.device_token_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/token", body = good_poll,
		request_id = "req_bridge_poll_good", remote_addr = "198.51.100.30:5555",
	})
	assert_eq(good_resp.status, 200, "redemption with the correct PKCE verifier -> 200")
	assert_true(strings.contains(good_resp.body, bridge_id_a), "redemption returns the brg_ the credential is scoped to")
	token_a := json_field(good_resp.body, "access_token")
	assert_true(token_a != "", "redemption returns a plaintext credential")

	// --- REQ-EA-1: until the vault key is delivered the credential is PENDING ---
	// It authenticates the enroll-only socket and nothing else, and the bridge row
	// is not enrolled: no runtime path may accept it.
	_, pending_runtime_ok, _ := bridge_service.verify_bridge_token(&graph.bridges, token_a)
	assert_true(!pending_runtime_ok, "a pending enrollment's credential is refused by the runtime verifier")
	enroll_ctx, family_a, enroll_ok, enroll_err := bridge_service.verify_enroll_access_token(&graph.bridges, token_a)
	assert_true(enroll_ok, enroll_err.message)
	assert_eq(enroll_ctx.bridge_id, bridge_id_a, "the enroll credential resolves to its own brg_")
	pending_row, pending_row_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id_a)
	assert_true(pending_row_ok, "pending bridge row readable")
	assert_true(domain.bridge_is_pending(pending_row), "the bridge row is pending until the vault key is delivered")
	_, owner_get_ok, _ := bridge_service.get_bridge(&graph.bridges, contracts.Auth_Context{kind = .User_Token, user_id = "approving-human"}, bridge_id_a)
	assert_true(!owner_get_ok, "a pending bridge is not a usable bridge for its owner yet")
	// The hub observes the delivery and commits (REQ-EA-2).
	_, commit_ok, commit_err := bridge_service.commit_pending_enrollment(&graph.bridges, bridge_service.Pending_Commit_Input{bridge_id = bridge_id_a, family_id = family_a})
	assert_true(commit_ok, commit_err.message)

	// --- the credential is BRIDGE-SCOPED, and the Hub stored only a hash ---
	ctx_a, va_ok, va_err := bridge_service.verify_bridge_token(&graph.bridges, token_a)
	assert_true(va_ok, va_err.message)
	assert_eq(ctx_a.bridge_id, bridge_id_a, "credential resolves to exactly its own brg_")
	assert_eq(ctx_a.user_id, "approving-human", "credential carries the approving owner")
	assert_eq(ctx_a.kind, contracts.Auth_Kind.Bridge_Token, "credential is a Bridge_Token context, not a user token")
	row_a, row_a_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id_a)
	assert_true(row_a_ok, "bridge row readable")
	assert_eq(string(row_a.owner_user_id), "approving-human", "bridge row owned by the approving user")
	// REQ-IMPL-3: a device-enrolled bridge's credentials live in `bridge_tokens`,
	// so this column is EMPTY for it rather than holding a hash. That is the
	// stronger property and worth asserting positively: an empty stored hash
	// verifies nothing (verify_credential), so this bridge has no non-expiring
	// credential at all, not merely a hashed one.
	assert_eq(row_a.bridge_token_hash, "", "no non-expiring hbr_ hash is written for a device-enrolled bridge")
	assert_true(!strings.contains(row_a.bridge_token_hash, token_a), "the plaintext credential is not stored")
	// Property 5: the approved key is on record against the bridge.
	assert_true(strings.contains(row_a.capabilities_json, BPK_A), "the approved public key is on record against the bridge row")
	assert_true(strings.contains(row_a.capabilities_json, BPK_A_FP), "the hub-computed fingerprint is on record")
	assert_true(strings.contains(row_a.capabilities_json, "device_authorization"), "the bridge row records how it was enrolled")

	// --- Property 4: the secret is CSPRNG-derived, not timestamp-derived ---
	// Two back-to-back enrolments. `generate_id` is prefix + unix-nanoseconds, so
	// if a secret were ever built from it again, two enrolments moments apart
	// would share a long common prefix and differ only in the low digits.
	e1, e1_ok, _ := bridge_service.enroll_bridge_from_device_grant(&graph.bridges, bridge_service.Device_Enroll_Input{
		owner_user_id = "approving-human", bridge_public_key = BPK_A,
		bridge_key_fingerprint = BPK_A_FP, os_user = "tanmay", machine_hostname = "host-e1",
	})
	e2, e2_ok, _ := bridge_service.enroll_bridge_from_device_grant(&graph.bridges, bridge_service.Device_Enroll_Input{
		owner_user_id = "approving-human", bridge_public_key = BPK_A,
		bridge_key_fingerprint = BPK_A_FP, os_user = "tanmay", machine_hostname = "host-e2",
	})
	assert_true(e1_ok && e2_ok, "two back-to-back device-grant enrolments succeed")
	assert_true(e1.bridge_token != e2.bridge_token, "two enrolments produce different credentials")
	assert_true(e1.bridge.bridge_id != e2.bridge.bridge_id, "two enrolments produce different brg_ ids")
	// Shape: hba_<token_id>.<secret>. A regression to a timestamp-derived token
	// fails on shape as well as on entropy.
	id1, secret1, split1 := bridge_service.split_credential(bridge_service.ACCESS_TOKEN_PREFIX, e1.bridge_token)
	id2, secret2, split2 := bridge_service.split_credential(bridge_service.ACCESS_TOKEN_PREFIX, e2.bridge_token)
	assert_true(split1 && split2, "both credentials split as hba_<token_id>.<secret>")
	assert_true(strings.has_prefix(id1, "btk_") && strings.has_prefix(id2, "btk_"), "the id half is the token row's id")
	assert_true(id1 != id2, "two enrolments produce different token rows")
	// REQ-IMPL-3: the refresh half is a SEPARATE credential with its own row and
	// its own secret. A pair that shared a secret would make the 1-hour bound on
	// the access token meaningless.
	r1, rsecret1, rsplit1 := bridge_service.split_credential(bridge_service.REFRESH_TOKEN_PREFIX, e1.refresh_token)
	assert_true(rsplit1, "the refresh half splits as hbf_<token_id>.<secret>")
	assert_true(r1 != id1, "access and refresh are distinct rows")
	assert_true(rsecret1 != secret1, "access and refresh do not share a secret")
	assert_true(secret1 != secret2, "the two secrets differ")
	assert_eq(len(secret1), 64, "secret is 64 hex chars (256 bits of CSPRNG)")
	// Unrelated, not merely unequal: no shared prefix beyond what chance gives.
	shared := 0
	for shared < len(secret1) && shared < len(secret2) && secret1[shared] == secret2[shared] do shared += 1
	assert_true(shared < 8, "consecutive secrets share no long common prefix (not timestamp-derived)")
	assert_true(!strings.contains(secret1, e1.bridge.bridge_id[len("brg_"):]), "the secret does not embed the id's timestamp")
	fmt.println("REQ-IMPL-2/3 OK: credential pair is CSPRNG-derived and splits as hba_/hbf_<btk_>.<secret>")

	// --- Property 3: CROSS-BRIDGE IS REJECTED (T9) ---
	// Enrol a second bridge, put an agent instance on it, then have bridge A's
	// credential try to act for it.
	agent_row := domain.Agent{
		agent_id = "agt_crossbridge", owner_user_id = "approving-human", name = "Cross Bridge",
		slug = "cross-bridge", state = .Active,
		created_at = "2026-10-07T00:00:00Z", updated_at = "2026-10-07T00:00:00Z",
	}
	_, _, _ = iface.agent_save(graph.agents.agents, agent_row)
	// The instance rows are written straight to the repository rather than going
	// through create_instance, which additionally requires the bridge to be
	// Online AND present in the live runtime registry — a WS connection this
	// test has no reason to stand up. resolve_bridge_instance_auth reads only
	// inst.bridge_id and inst.owner_user_id, which is exactly what T9 is about.
	inst_a := save_instance(&graph, "inst_on_bridge_a", e1.bridge.bridge_id)
	inst_b := save_instance(&graph, "inst_on_bridge_b", e2.bridge.bridge_id)
	assert_eq(inst_b.bridge_id, e2.bridge.bridge_id, "instance belongs to bridge B")
	assert_eq(inst_a.bridge_id, e1.bridge.bridge_id, "instance belongs to bridge A")
	own_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", e1.bridge_token})}}
	own_body := strings.concatenate({"{\"agent_instance_id\":\"", inst_a.agent_instance_id, "\"}"})
	own_ctx, own_ok, own_err := auth_service.resolve_bridge_instance_auth(&graph.auth, auth_service.Auth_Request{
		headers = own_headers[:], body = own_body,
	})
	assert_true(own_ok, own_err.message)
	assert_eq(own_ctx.bridge_id, e1.bridge.bridge_id, "bridge A may act for its OWN instance")

	// The attack: bridge A's credential asserting bridge B's instance.
	cross_body := strings.concatenate({"{\"agent_instance_id\":\"", inst_b.agent_instance_id, "\"}"})
	_, cross_ok, cross_err := auth_service.resolve_bridge_instance_auth(&graph.auth, auth_service.Auth_Request{
		headers = own_headers[:], body = cross_body,
	})
	assert_true(!cross_ok, "T9: bridge A CANNOT act for an instance owned by bridge B")
	assert_eq(cross_err.code, domain.Error_Code.Forbidden, "cross-bridge attempt -> Forbidden")
	// And B's own credential is not confused by A's existence.
	b_headers := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", e2.bridge_token})}}
	b_ctx, b_ok, b_err := auth_service.resolve_bridge_instance_auth(&graph.auth, auth_service.Auth_Request{
		headers = b_headers[:], body = cross_body,
	})
	assert_true(b_ok, b_err.message)
	assert_eq(b_ctx.bridge_id, e2.bridge.bridge_id, "bridge B may act for its own instance")
	// A credential is not interchangeable: A's token never resolves to B.
	ctx_e1, _, _ := bridge_service.verify_bridge_token(&graph.bridges, e1.bridge_token)
	ctx_e2, _, _ := bridge_service.verify_bridge_token(&graph.bridges, e2.bridge_token)
	assert_true(ctx_e1.bridge_id != ctx_e2.bridge_id, "the two credentials resolve to different bridges")
	fmt.println("REQ-IMPL-2 OK: bridge-scoped credential, cross-bridge rejected (T9), key on record")
}

// seed_bridge_grant drives authorize + approve over HTTP for one more bridge
// grant and returns it, so a test needing a second independent grant does not
// have to repeat the whole body construction.
seed_bridge_grant :: proc(graph: ^app.App_Graph, label, public_key, challenge: string, headers: []contracts.HTTP_Header) -> (device_auth.Grant, bool) {
	body := strings.concatenate({
		"{\"client\":\"ham-bridge\",\"device_label\":\"", label, "\",\"os\":\"linux\"",
		",\"bridge_public_key\":\"", public_key, "\"",
		",\"code_challenge\":\"", challenge, "\",\"code_challenge_method\":\"S256\"}",
	})
	resp := api_http.device_authorize_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/authorize", body = body,
		request_id = "req_seed_authorize", remote_addr = "198.51.100.31:5555",
	})
	if resp.status != 200 do return device_auth.Grant{}, false
	grant, found := grant_for_label(&graph.device_auth_store, label)
	if !found do return device_auth.Grant{}, false
	approve_body := strings.concatenate({"{\"user_code\":\"", grant.user_code, "\",\"approve\":true}"})
	aresp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{
		method = "POST", path = "/api/v1/device/approve", body = approve_body,
		request_id = "req_seed_approve", remote_addr = "127.0.0.1:4444", headers = headers,
	})
	if aresp.status != 200 do return device_auth.Grant{}, false
	return grant_for_label(&graph.device_auth_store, label)
}

// save_instance writes an agent-instance row owned by the approving user and
// pinned to `bridge_id`, which is all resolve_bridge_instance_auth needs.
save_instance :: proc(graph: ^app.App_Graph, instance_id, bridge_id: string) -> domain.Agent_Instance {
	inst := domain.Agent_Instance{
		agent_instance_id = instance_id, owner_user_id = "approving-human",
		agent_id = "agt_crossbridge", bridge_id = bridge_id,
		display_name = "Cross Bridge #1", provider = "claude", model = "normal",
		runtime_status = "running", startup_status = "ready", activity_status = "idle",
		created_at = "2026-10-07T00:00:00Z", updated_at = "2026-10-07T00:00:00Z",
	}
	saved, _, _ := iface.agent_save_instance(graph.agents.agents, inst)
	return saved
}

// grant_for_label finds a stored grant by its device_label, so a test can drive
// the HTTP authorize handler (whose response it does not need to parse) and
// still reach the codes.
grant_for_label :: proc(store: ^device_auth.Grant_Store, label: string) -> (device_auth.Grant, bool) {
	for _, grant in store.grants {
		if grant.device_label == label do return grant, true
	}
	return device_auth.Grant{}, false
}

// json_field pulls a string field out of a response body. Deliberately crude —
// it only has to read back values this test wrote.
json_field :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	end := strings.index(rest, "\"")
	if end < 0 do return ""
    return rest[:end]
}

test_unlinkability_smoke :: proc() {
	for i in 0..<32 {
		dc, dc_ok := device_auth.generate_device_code()
		uc, uc_ok := device_auth.generate_user_code()
		assert_true(dc_ok && uc_ok, "code generation succeeds")
		assert_true(len(dc) == 64 && len(uc) == 9, "code lengths are expected")
		assert_true(!strings.contains(dc, uc[:4]) && !strings.contains(dc, uc[5:]), "device_code does not embed user_code segments")
		_ = i
	}
	fmt.println("ELDA-6 OK: device_code/user_code unlinkability smoke")
}

test_trusted_xff_and_verify_bruteforce :: proc() {
	store, svc := new_service(2, 5)
	defer device_auth.grant_store_free(store)

	trusted_res, trusted_ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Trusted XFF"}, "127.0.0.1:1111", "203.0.113.5, 10.0.0.1")
	assert_true(trusted_ok, "trusted authorize succeeds")
	trusted_grant, _ := device_auth.get_grant(store, trusted_res.device_code)
	assert_eq(trusted_grant.request_ip, "203.0.113.5", "trusted peer honors first XFF hop at authorize")

	untrusted_res, untrusted_ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Spoofed XFF"}, "198.51.100.9:4444", "203.0.113.99")
	assert_true(untrusted_ok, "untrusted authorize succeeds")
	untrusted_grant, _ := device_auth.get_grant(store, untrusted_res.device_code)
	assert_eq(untrusted_grant.request_ip, "198.51.100.9", "untrusted peer ignores spoofed XFF at authorize")

	// Brute-force cap: unknown-code attempts from one IP are capped; after the
	// configured cooldown/window, a legitimate code from the same IP works again.
	_, u1_ok, u1_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZA", "198.51.100.200")
	_, u2_ok, u2_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZB", "198.51.100.200")
	_, u3_ok, u3_err := device_auth.verify_with_ip(&svc, "ZZZZ-ZZZC", "198.51.100.200")
	assert_true(!u1_ok && !u2_ok, "unknown verify attempts fail generically before cap")
	assert_eq(u1_err.code, domain.Error_Code.Not_Found, "first unknown -> generic Not_Found")
	assert_eq(u2_err.code, domain.Error_Code.Not_Found, "second unknown -> generic Not_Found")
	assert_true(!u3_ok, "third verify over cap fails")
	assert_eq(u3_err.code, domain.Error_Code.Rate_Limited, "verify brute-force cap -> Rate_Limited")
	FAKE_NOW += 11
	info, legit_ok, legit_err := device_auth.verify_with_ip(&svc, trusted_res.user_code, "198.51.100.200")
	assert_true(legit_ok, legit_err.message)
	assert_eq(info.device_label, "Trusted XFF", "legitimate verify works after cooldown")
	fmt.println("ELDA-6 OK: trusted-XFF-only and verify brute-force cap/cooldown")
}

test_public_rate_limit_and_token_single_use :: proc() {
	// Public authorize endpoint rate limit.
	rate_store, rate_svc := new_service(2, 5)
	defer device_auth.grant_store_free(rate_store)
	_, a1, _ := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	_, a2, _ := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	_, a3, a3_err := device_auth.authorize(&rate_svc, {client = "electron"}, "127.0.0.1:1", "203.0.113.44")
	assert_true(a1 && a2 && !a3, "authorize per-IP rate limit trips after budget")
	assert_eq(a3_err.code, domain.Error_Code.Rate_Limited, "authorize over budget -> Rate_Limited")

	// Token poll: unknown device_code stays pending, same grant is single-use,
	// and too-fast polling trips slow_down/Rate_Limited.
	store, svc := new_service(10, 5)
	defer device_auth.grant_store_free(store)
	res, ok, _ := device_auth.authorize(&svc, {client = "electron", device_label = "Single Use"}, "127.0.0.1:1", "203.0.113.55")
	assert_true(ok, "authorize for token test succeeds")
	unknown, unknown_err := device_auth.poll(&svc, "not-a-device-code", "203.0.113.56")
	assert_eq(unknown_err.code, domain.Error_Code.None, "unknown device poll no error")
	assert_eq(unknown.status, device_auth.Poll_Status.Pending, "unknown device_code -> pending")
	pending, pending_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(pending_err.code, domain.Error_Code.None, "first pending poll allowed")
	assert_eq(pending.status, device_auth.Poll_Status.Pending, "unapproved grant -> pending")
	too_fast, too_fast_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(too_fast.status, device_auth.Poll_Status.Slow_Down, "too-fast grant poll -> slow_down")
	assert_eq(too_fast_err.code, domain.Error_Code.Rate_Limited, "too-fast grant poll -> Rate_Limited")
	FAKE_NOW += 5
	approved_ok, approved_err := device_auth.approve(&svc, {user_code = res.user_code, approve = true}, "owner", "203.0.113.99", "UA")
	assert_true(approved_ok, approved_err.message)
	approved, poll_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(poll_err.code, domain.Error_Code.None, "approved poll no error")
	assert_eq(approved.status, device_auth.Poll_Status.Approved, "approved grant returns token once")
	replay, replay_err := device_auth.poll(&svc, res.device_code, "203.0.113.57")
	assert_eq(replay_err.code, domain.Error_Code.None, "used replay no error")
	assert_eq(replay.status, device_auth.Poll_Status.Expired, "used grant replay -> expired")
	fmt.println("ELDA-6 OK: public rate limits, no-enumeration, single-use terminal grants")
}

test_http_owner_spoof_and_audit_queryability :: proc() {
	db_path := "/tmp/heimdall-device-auth-security-matrix.db"
	_ = os.remove(db_path)
	config := app.default_config()
	config.database_path = db_path
	config.migrations_dir = "src/hub/repository/sqlite/migrations"
	config.paddle_environment = "sandbox"
	graph: app.App_Graph
	graph_ok, graph_msg := app.build_graph(&graph, config)
	assert_true(graph_ok, graph_msg)
	defer {
		app.shutdown_graph(&graph)
		_ = os.remove(db_path)
	}

	res, auth_ok, auth_err := device_auth.authorize(&graph.device_auth, {client = "heimdall-electron", device_label = "Audit Laptop", os = "macOS", app_version = "0.1"}, "198.51.100.20:5555", "203.0.113.250")
	assert_true(auth_ok, auth_err.message)
	trusted_headers := [?]contracts.HTTP_Header{
		{name = "X-authentik-username", value = "real-owner"},
		{name = "X-authentik-name", value = "Real Owner"},
		{name = "X-authentik-email", value = "real-owner@example.com"},
		{name = "X-Forwarded-For", value = "203.0.113.88, 10.0.0.1"},
		{name = "User-Agent", value = "SecurityMatrix/1.0"},
	}
	body := strings.concatenate({"{\"user_code\":\"", res.user_code, "\",\"approve\":true,\"owner_user_id\":\"spoof-owner\",\"user\":\"spoof-user\"}"})
	approve_resp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{method = "POST", path = "/api/v1/device/approve", body = body, request_id = "req_security_approve", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:]})
	assert_eq(approve_resp.status, 200, "HTTP approve succeeds through trusted proxy")
	grant, grant_ok := device_auth.get_grant(&graph.device_auth_store, res.device_code)
	assert_true(grant_ok, "approved grant queryable")
	assert_eq(grant.owner_user_id, "real-owner", "spoofed owner body ignored; owner from Auth_Context")
	assert_eq(grant.approver_ip, "203.0.113.88", "approve honors trusted XFF for audit IP")
	assert_eq(grant.approver_ua, "SecurityMatrix/1.0", "approve records user-agent")
	assert_eq(grant.device_label, "Audit Laptop", "audit carries device_label")
	assert_eq(grant.client, "heimdall-electron", "audit carries client")
	assert_true(grant.decided_at > 0, "audit decided_at recorded")

	tokens, token_err := auth_service.list_user_api_tokens(&graph.auth, domain.User_ID("real-owner"))
	assert_eq(token_err.code, domain.Error_Code.None, "tokens list succeeds for approving owner")
	found_device_token := false
	found_token_id := ""
	for token in tokens {
		if token.created_from == "device_authorization" && token.device_label == "Audit Laptop" && token.revoked_at == "" {
			found_device_token = true
			found_token_id = token.token_id
		}
	}
	assert_true(found_device_token, "tokens list surfaces device provenance")

	deny_res, deny_auth_ok, _ := device_auth.authorize(&graph.device_auth, {client = "heimdall-electron", device_label = "Denied Laptop"}, "198.51.100.21:5555", "")
	assert_true(deny_auth_ok, "authorize deny audit grant succeeds")
	deny_body := strings.concatenate({"{\"user_code\":\"", deny_res.user_code, "\",\"approve\":false,\"owner_user_id\":\"spoof-deny\"}"})
	deny_resp := api_http.device_approve_handler(rawptr(&graph.device_auth_handlers), api_http.Request{method = "POST", path = "/api/v1/device/approve", body = deny_body, request_id = "req_security_deny", remote_addr = "127.0.0.1:4444", headers = trusted_headers[:]})
	assert_eq(deny_resp.status, 200, "HTTP deny succeeds through trusted proxy")
	deny_grant, deny_grant_ok := device_auth.get_grant(&graph.device_auth_store, deny_res.device_code)
	assert_true(deny_grant_ok, "denied grant queryable")
	assert_eq(deny_grant.status, device_auth.Grant_Status.Denied, "deny terminal status recorded")
	assert_eq(deny_grant.owner_user_id, "real-owner", "deny owner from context")
	assert_eq(deny_grant.approver_ip, "203.0.113.88", "deny audit IP recorded")
	assert_eq(deny_grant.approver_ua, "SecurityMatrix/1.0", "deny UA recorded")
	assert_eq(deny_grant.minted_token, "", "deny does not mint token")

	// Authoritative token row is queryable by id too, proving provenance survives
	// repository read paths and is not only an in-memory grant field.
	if found_device_token && found_token_id != "" {
		row, row_ok, _ := iface.user_token_get_by_id(graph.auth.user_tokens, found_token_id)
		assert_true(row_ok, "token row query by id succeeds")
		assert_true(row.created_from != "" && row.device_label != "", "token provenance query by id includes audit fields")
	}
	fmt.println("ELDA-6/ELDA-7 OK: HTTP owner spoof guard + queryable approve/deny audit/provenance")
}
