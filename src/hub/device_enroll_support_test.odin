package main

// Shared bridge-provisioning helper for this package's tests (REQ-ENROLL-9).
//
// WHY THIS FILE EXISTS. Before REQ-IMPL-6, every test here that needed a bridge
// open-coded the same two requests: POST /api/v1/bridge-enrollments for a one-time
// token, then POST /api/v1/bridges/enroll to exchange it. Both endpoints are
// deleted. The tests themselves are not about enrollment — they need a bridge and a
// credential so they can exercise shells, resize, input, LSP config and title
// events — so the provisioning was migrated here rather than the tests dropped.
//
// It drives the PRODUCTION device-flow endpoints rather than calling the service,
// so every suite that uses it now covers the real enrollment path as a side effect.
//
// THE THREE NON-OBVIOUS REQUIREMENTS, each of which rejects a request outright:
//
//  1. `bridge_public_key` must be a 130-char lowercase-hex uncompressed P-256
//     point. A short placeholder is refused at the HTTP layer (the service layer
//     only checks non-empty, which is why direct-service fixtures can use one).
//  2. NO `bridge_key_fingerprint` is sent. The Hub derives it from the key and
//     refuses a body-supplied one that disagrees — a requester-chosen fingerprint
//     would defeat the human comparing it on the approval screen.
//  3. PKCE is MANDATORY for a bridge grant and S256-only: `plain` and a missing
//     method are both refused. The pair below is precomputed, so this helper needs
//     no crypto, and the verifier is replayed at the token call.
//
// `device_label` becomes the bridge's machine_hostname and therefore its label, so
// callers that assert on a bridge label pass it as the label.

import "core:strings"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"

// A valid-shaped uncompressed P-256 point. Never a real key; only its SHAPE is
// checked, and only the approving human's comparison gives a key meaning.
DEVICE_TEST_PUBLIC_KEY :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"

// PKCE pair: DEVICE_TEST_CODE_CHALLENGE == BASE64URL(SHA256(DEVICE_TEST_CODE_VERIFIER)),
// unpadded, 43 chars.
DEVICE_TEST_CODE_VERIFIER  :: "heimdall-req-impl-6-test-code-verifier-aaaa"
DEVICE_TEST_CODE_CHALLENGE :: "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI"

// The providers a connected bridge would report. Capabilities are NOT part of
// enrollment in the device flow — see device_enroll_test_bridge.
DEVICE_TEST_CAPABILITIES :: `{"capabilities":[{"provider":"claude","models":["normal","smart"],"default_model":"normal"}]}`

// device_enroll_test_bridge provisions a bridge owned by whoever `headers`
// authenticates as, and returns its id and its access token.
//
// `ok` is false if any step failed; callers assert on it so a provisioning failure
// reports as itself rather than as a confusing downstream error.
// commit=false leaves the enrollment PENDING (as before the vault key is delivered).
device_enroll_test_bridge :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label: string, commit := true) -> (bridge_id: string, bridge_token: string, ok: bool) {
	// Passwordless vault: a bridge enrolls only into an existing directory, with a
	// vault approval (signed by the root device) naming its persistent identity key.
	user_id, version, vault_ok := vt_ensure_vault(graph, headers)
	if !vault_ok do return "", "", false
	br, approval := vt_bridge_approval(graph, user_id, version)
	// Hub-blind pairing: the bridge derives these from its own code; any 64-hex stand-in will do here.
	pair_lookup := vt_lookup(br.sign_pub)
	authorize_body := strings.concatenate({
		`{"client":"ham-bridge","device_label":"`, label,
		`","os":"linux","os_user":"tester","bridge_public_key":"`, DEVICE_TEST_PUBLIC_KEY,
		`","bridge_identity_public_key":"`, br.sign_pub,
		`","bridge_identity_proof":`, vt_enroll_proof(&br, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE),
		`,"code_challenge":"`, DEVICE_TEST_CODE_CHALLENGE, `","code_challenge_method":"S256","pair_lookup":"`, pair_lookup, `","pair_key_mac":"`, vt_lookup(strings.concatenate({"mac|", br.sign_pub}, context.temp_allocator)), `"}`,
	})
	authorized := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/authorize", body = authorize_body,
		request_id = "req_device_authorize", remote_addr = "127.0.0.1",
	})
	if authorized.status != 200 do return "", "", false
	device_code := device_test_json_string(authorized.body, "device_code")
	if device_code == "" do return "", "", false

	// The human approves. Ownership comes from this Auth_Context, never the body.
	approved := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/approve",
		body = strings.concatenate({`{"pair_lookup":"`, pair_lookup, `","approve":true,"vault_approval":`, approval, `}`}),
		request_id = "req_device_approve", remote_addr = "127.0.0.1", headers = headers,
	})
	if approved.status != 200 do return "", "", false

	// The bridge collects its credential. The grant is single-use and spent here.
	issued := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = strings.concatenate({`{"device_code":"`, device_code, `","code_verifier":"`, DEVICE_TEST_CODE_VERIFIER, `"}`}),
		request_id = "req_device_token", remote_addr = "127.0.0.1",
	})
	if issued.status != 200 do return "", "", false
	bridge_id = device_test_json_string(issued.body, "bridge_id")
	bridge_token = device_test_json_string(issued.body, "access_token")
	if bridge_id == "" || bridge_token == "" do return "", "", false

	// ===== THE VAULT KEY IS DELIVERED =====
	//
	// REQ-EA-1: the enrollment stays PENDING (invisible to the owner's bridge
	// routes) until the hub observes the bridge acknowledge its vault keyring on the
	// enroll-only socket (bridge_unseal_handler → bridge_enroll_commit). No bridge
	// connects here, so commit the pending family the same way that path does.
	if !commit do return bridge_id, bridge_token, true
	family_id := ""
	pending_tokens, list_err := iface.bridge_list_live_tokens_by_scope(graph.bridges.repo, bridge_service.BRIDGE_ENROLL_TOKEN_SCOPE)
	if list_err.code != .None do return "", "", false
	for tok in pending_tokens do if tok.bridge_id == bridge_id do family_id = strings.clone(tok.family_id, context.temp_allocator)
	for &tok in pending_tokens do domain.bridge_token_destroy(&tok)
	delete(pending_tokens)
	if family_id == "" do return "", "", false
	committed, commit_ok, _ := bridge_service.commit_pending_enrollment(&graph.bridges, bridge_service.Pending_Commit_Input{bridge_id = bridge_id, family_id = family_id})
	if !commit_ok do return "", "", false
	domain.bridge_destroy(&committed)

	// ===== CAPABILITIES ARE REPORTED, NOT ENROLLED =====
	//
	// The deleted enroll endpoint took a `capabilities` array in its body, so the
	// old code declared the bridge's providers AT ENROLLMENT. The device flow has
	// no such field by design: the Hub records only what the approving human
	// confirmed. A real bridge reports its providers when it CONNECTS, over the
	// runtime WS, which the Hub handles with update_runtime_capabilities.
	//
	// No bridge connects in these tests, so this calls the same service proc the WS
	// handler does. Without it the bridge has no declared providers and anything
	// matching an agent to a provider/model fails — a real difference between the
	// two flows, not a test artifact.
	//
	// NOTE it also marks the bridge Online, as a connect would; the deleted enroll
	// path left a new bridge Offline.
	_, _, _ = bridge_service.update_runtime_capabilities(&graph.bridges, bridge_id, DEVICE_TEST_CAPABILITIES)
	return bridge_id, bridge_token, true
}

// device_test_json_string reads a top-level string field. Deliberately minimal:
// these are hub-generated responses, not arbitrary input.
device_test_json_string :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""})
	defer delete(needle)
	idx := strings.index(body, needle)
	if idx < 0 do return ""
	rest := body[idx + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}
