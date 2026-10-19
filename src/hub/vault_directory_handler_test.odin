package main

// Passwordless vault directory over the real router (plan §2 P2): genesis, register,
// code resolution with the kind discriminator, signed approval, bridge enrollment gate.
// Hermetic: in-memory database, injected clock, fixed keys, no network.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"
import vd "odin_test:hub/service/vault_directory"

VT_NOW    :: "2026-10-19T10:00:00Z"
VT_NOW_MS :: i64(1_792_404_000_000)

// The clock reads a per-test string (tests run in parallel), VT_NOW by default.
@(private = "file")
vt_clock_now :: proc(ctx: rawptr) -> string {
	if ctx == nil do return VT_NOW
	return (^string)(ctx)^
}

// A per-test throwaway database file (billing needs a file-backed DB).
@(private = "file")
vt_db_path :: proc(tag: string) -> string {
	dir := os.get_env("TEMP", context.temp_allocator)
	if dir == "" do dir = os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" do dir = "/tmp"
	return fmt.tprintf("%s/heimdall-vault-dir-test-%d-%s.db", dir, os.get_pid(), tag)
}

@(private = "file")
vt_graph :: proc(t: ^testing.T, graph: ^app.App_Graph, db_path: string, now: ^string = nil) -> bool {
	// The config keeps the slice: it must outlive this proc.
	cidrs := new([1]string)
	cidrs[0] = "127.0.0.1/32"
	_ = os.remove(db_path)
	ok, msg := app.build_graph(graph, app.Hub_Config{
		database_path        = db_path,
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	graph.clock = platform.Clock{ctx = rawptr(now), now = vt_clock_now}
	return ok
}

@(private = "file")
dispatch :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_vt", remote_addr = "127.0.0.1", headers = headers})
}

@(test)
test_vault_directory_http_flow :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	graph: app.App_Graph
	db_path := vt_db_path("flow")
	defer for suffix in ([]string{"", "-wal", "-shm"}) do _ = os.remove(strings.concatenate({db_path, suffix}))
	if !vt_graph(t, &graph, db_path) do return
	defer app.shutdown_graph(&graph)
	alice := []contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}

	// No directory yet: 404 {configured:false}; a bridge cannot enroll.
	none := dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect_value(t, none.status, 404)
	testing.expect(t, strings.contains(none.body, `"configured":false`))

	user_id, _, vok := vt_ensure_vault(&graph, alice)
	testing.expect(t, vok, "genesis over HTTP")
	root := vt_make_dev(VT_ROOT_SEED)
	again := dispatch(&graph, "POST", "/api/v1/vault/directory/genesis", vt_genesis_body(user_id, &root), alice)
	testing.expect_value(t, again.status, 409)

	// Register B (self-signed proof + the pairing values it derived from its own code);
	// the hub never sees or returns a code.
	b := vt_make_dev(2)
	reg_st := vt_statement("register", user_id, &b, &b, "", "")
	code := vt_lookup("b")
	reg_body := strings.concatenate({`{"statement":"`, vt_escape(reg_st), `","proof_signature":`, vt_sign(&b, reg_st), `,"pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443","pair_lookup":"`, code, `","pair_key_mac":"`, vt_lookup("mac-b"), `"}`})
	reg := dispatch(&graph, "POST", "/api/v1/vault/devices/register", reg_body, alice)
	testing.expect_value(t, reg.status, 201)
	testing.expect(t, !strings.contains(reg.body, "user_code") && !strings.contains(reg.body, code), reg.body)
	no_pairing := dispatch(&graph, "POST", "/api/v1/vault/devices/register", strings.concatenate({`{"statement":"`, vt_escape(reg_st), `","proof_signature":`, vt_sign(&b, reg_st), "}"}), alice)
	testing.expect_value(t, no_pairing.status, 400)

	// /device/verify resolves the lookup as kind=browser with the register statement and
	// key_mac; /device/approve never treats it as a grant.
	ver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"pair_lookup":"`, code, `"}`}), alice)
	testing.expect_value(t, ver.status, 200)
	testing.expect(t, strings.contains(ver.body, `"kind":"browser"`) && strings.contains(ver.body, b.id) && strings.contains(ver.body, `"pair_key_mac":"`) && strings.contains(ver.body, `"register_statement":"`), ver.body)
	// Several candidate lookups at once (one per pair_salt): the one that resolves answers.
	multi := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"pair_lookups":["`, vt_lookup("nope"), `","`, code, `"]}`}), alice)
	testing.expect(t, multi.status == 200 && strings.contains(multi.body, b.id), multi.body)
	as_grant := dispatch(&graph, "POST", "/api/v1/device/approve", strings.concatenate({`{"pair_lookup":"`, code, `","approve":true}`}), alice)
	testing.expect_value(t, as_grant.status, 404)
	// Another account cannot resolve alice's lookup.
	bob := []contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}
	bob_ver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"pair_lookup":"`, code, `"}`}), bob)
	testing.expect_value(t, bob_ver.status, 404)
	// Pairing stretch: the approver fetches the public pair_salt first; only the
	// session user's own pending browsers are listed.
	salts := dispatch(&graph, "POST", "/api/v1/device/pair-salts", "{}", alice)
	testing.expect(t, salts.status == 200 && strings.contains(salts.body, `{"kind":"browser","pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443"}`), salts.body)
	bob_salts := dispatch(&graph, "POST", "/api/v1/device/pair-salts", "{}", bob)
	testing.expect(t, bob_salts.status == 200 && !strings.contains(bob_salts.body, `"kind":"browser"`), bob_salts.body)

	// Approve B: unsigned -> 401; signed by the root -> 200, version 2.
	approve_path := strings.concatenate({"/api/v1/vault/devices/", b.id, "/approve"})
	head_view, _ := vd.get_directory(&graph.vault_directory, user_id)
	st := vt_statement("approve", user_id, &root, &b, "2", "1", vt_wrap_sha(&root, &b, 2, 1), prev = head_view.directory.head_hash)
	body := strings.concatenate({`{"pair_lookup":"`, code, `","pair_mac":"`, vt_lookup("pair-mac"), `","expected_version":1,"statement":"`, vt_escape(st), `","signature":`, vt_sign(&root, st), `,"wrap":`, vt_wrap_json(user_id, &root, &b, 2, 1), "}"})
	unsigned := dispatch(&graph, "POST", approve_path, body, alice)
	testing.expect_value(t, unsigned.status, 401)
	signed := dispatch(&graph, "POST", approve_path, body, vt_signed_headers(alice, &root, user_id, "POST", approve_path, body, "nonce-vt-000000000001", VT_NOW_MS))
	testing.expect_value(t, signed.status, 200)
	testing.expect(t, strings.contains(signed.body, `"directory_version":2`), signed.body)
	replay := dispatch(&graph, "POST", approve_path, body, vt_signed_headers(alice, &root, user_id, "POST", approve_path, body, "nonce-vt-000000000001", VT_NOW_MS))
	testing.expect_value(t, replay.status, 401)

	// B fetches its wrap.
	self := dispatch(&graph, "GET", "/api/v1/vault/devices/self", "", vt_signed_headers(alice, &b, user_id, "GET", "/api/v1/vault/devices/self", "", "nonce-vt-000000000002", VT_NOW_MS))
	testing.expect_value(t, self.status, 200)
	testing.expect(t, strings.contains(self.body, `"status":"approved"`) && strings.contains(self.body, `"wrap":{`) && strings.contains(self.body, vt_lookup("pair-mac")), self.body)

	// A bridge without a vault approval is refused; with one it enrolls, and its
	// 8-symbol grant code resolves as kind=bridge only.
	bridge_id, bridge_token, enrolled := device_enroll_test_bridge(&graph, alice, "box", commit = false)
	testing.expect(t, enrolled && bridge_id != "", "bridge enrolls with a vault approval")

	// L4: an (enrolled) bridge credential of the same account cannot resolve a
	// pending browser code; the user session can.
	_, family, fam_ok, _ := bridge_service.verify_enroll_access_token(&graph.bridges, bridge_token)
	_, committed, _ := bridge_service.commit_pending_enrollment(&graph.bridges, bridge_service.Pending_Commit_Input{bridge_id = bridge_id, family_id = family})
	testing.expect(t, fam_ok && committed)
	c := vt_make_dev(3)
	c_st := vt_statement("register", user_id, &c, &c, "", "")
	c_reg := dispatch(&graph, "POST", "/api/v1/vault/devices/register", strings.concatenate({`{"statement":"`, vt_escape(c_st), `","proof_signature":`, vt_sign(&c, c_st), `,"pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443","pair_lookup":"`, vt_lookup("c"), `","pair_key_mac":"`, vt_lookup("mac-c"), `"}`}), alice)
	testing.expect_value(t, c_reg.status, 201)
	c_code_body := strings.concatenate({`{"pair_lookup":"`, vt_lookup("c"), `"}`})
	as_bridge := dispatch(&graph, "POST", "/api/v1/device/verify", c_code_body, []contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}})
	testing.expect_value(t, as_bridge.status, 403)
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/device/verify", c_code_body, alice).status, 200)
	dir := dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect_value(t, dir.status, 200)
	testing.expect(t, strings.contains(dir.body, `"kind":"bridge"`) && strings.contains(dir.body, bridge_id), "bridge listed in the directory")
	testing.expect(t, strings.contains(dir.body, `"root_sign_public_key":"`) && strings.contains(dir.body, `"log":[{"seq":1`) && strings.contains(dir.body, `"head_hash":"`), "the signed log is exposed")
	testing.expect(t, strings.contains(dir.body, `"signature":{"alg":"ecdsa-p256-sha256","sig":"`) && strings.contains(dir.body, `"revocation_signature":null`), "signatures are typed objects (null when absent)")

	other_br := vt_make_dev(4000, "bridge")
	authz_prefix := strings.concatenate({
		`{"client":"ham-bridge","device_label":"x","os":"linux","bridge_public_key":"`, DEVICE_TEST_PUBLIC_KEY,
		`","bridge_identity_public_key":"`, other_br.sign_pub, `","bridge_identity_proof":`,
	})
	authz_suffix := strings.concatenate({`,"code_challenge":"`, DEVICE_TEST_CODE_CHALLENGE, `","code_challenge_method":"S256","pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443","pair_lookup":"`, vt_lookup("grant"), `","pair_key_mac":"`, vt_lookup("mac-grant"), `"}`})
	// L1: a proof by another key (or over another challenge) is refused.
	forged := dispatch(&graph, "POST", "/api/v1/device/authorize", strings.concatenate({authz_prefix, vt_enroll_proof(&root, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE), authz_suffix}), nil)
	testing.expect_value(t, forged.status, 400)
	no_salt := dispatch(&graph, "POST", "/api/v1/device/authorize", strings.concatenate({authz_prefix, vt_enroll_proof(&other_br, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE), strings.concatenate({`,"code_challenge":"`, DEVICE_TEST_CODE_CHALLENGE, `","code_challenge_method":"S256","pair_lookup":"`, vt_lookup("grant"), `","pair_key_mac":"`, vt_lookup("mac-grant"), `"}`})}), nil)
	testing.expect_value(t, no_salt.status, 400)
	authz := dispatch(&graph, "POST", "/api/v1/device/authorize", strings.concatenate({authz_prefix, vt_enroll_proof(&other_br, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE), authz_suffix}), nil)
	testing.expect_value(t, authz.status, 200)
	// A bridge grant has no hub-known code: no user_code, and a code-less link.
	testing.expect(t, !strings.contains(authz.body, "user_code") && !strings.contains(authz.body, "code="), authz.body)
	grant_code := vt_lookup("grant")
	gver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"pair_lookup":"`, grant_code, `"}`}), alice)
	testing.expect(t, gver.status == 200 && strings.contains(gver.body, `"kind":"bridge"`) && strings.contains(gver.body, vt_lookup("mac-grant")), gver.body)
	gsalts := dispatch(&graph, "POST", "/api/v1/device/pair-salts", "{}", alice)
	testing.expect(t, strings.contains(gsalts.body, `{"kind":"bridge","pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443"}`), gsalts.body)
	// The lookup never resolves as an (Electron) user code.
	as_user_code := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"user_code":"`, grant_code, `"}`}), alice)
	testing.expect_value(t, as_user_code.status, 404)
	// The same lookup cannot open a second grant.
	dup := dispatch(&graph, "POST", "/api/v1/device/authorize", strings.concatenate({authz_prefix, vt_enroll_proof(&other_br, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE), authz_suffix}), nil)
	testing.expect_value(t, dup.status, 409)
	no_approval := dispatch(&graph, "POST", "/api/v1/device/approve", strings.concatenate({`{"pair_lookup":"`, grant_code, `","approve":true}`}), alice)
	testing.expect_value(t, no_approval.status, 400)
	// The bridge's lookup as a pending-device lookup: never found.
	as_device := dispatch(&graph, "POST", approve_path, strings.concatenate({`{"pair_lookup":"`, grant_code, `","pair_mac":"`, grant_code, `","expected_version":3}`}), vt_signed_headers(alice, &root, user_id, "POST", approve_path, strings.concatenate({`{"pair_lookup":"`, grant_code, `","pair_mac":"`, grant_code, `","expected_version":3}`}), "nonce-vt-000000000003", VT_NOW_MS))
	testing.expect(t, as_device.status == 404 || as_device.status == 409, as_device.body)

	// M3(a): the operator cancels the still-pending enrollment after its directory
	// commit: the bridge identity gets a retirement HINT (no version, no log op).
	testing.expect(t, !strings.contains(dir.body, `"status":"revoked"`))
	pending_id, _, pending_ok := device_enroll_test_bridge(&graph, alice, "box2", commit = false)
	testing.expect(t, pending_ok)
	cancel := dispatch(&graph, "POST", strings.concatenate({"/api/v1/bridges/", pending_id, "/enrollment/cancel"}), "{}", alice)
	testing.expect(t, cancel.status == 200 && strings.contains(cancel.body, `"rolled_back":true`), cancel.body)
	after := dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect(t, strings.contains(after.body, `"retired_hints":["`), after.body)
	testing.expect(t, !strings.contains(after.body, `"status":"revoked"`), "a hint never revokes")
}

// M2: the unsigned entry points (genesis, register, reset) take only an interactive
// browser session; an owner reset is announced, visible in the directory, cancellable
// by a signed approver request, and executes only after its delay.
@(test)
test_vault_directory_reset_and_session_kinds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	graph: app.App_Graph
	db_path := vt_db_path("reset")
	defer for suffix in ([]string{"", "-wal", "-shm"}) do _ = os.remove(strings.concatenate({db_path, suffix}))
	now := VT_NOW
	if !vt_graph(t, &graph, db_path, &now) do return
	defer app.shutdown_graph(&graph)
	alice := []contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	user_id := vt_user_id(&graph, alice)
	root := vt_make_dev(VT_ROOT_SEED)

	// A user API token (ham-ctl / script credential) may neither genesis nor register
	// nor reset.
	tok := dispatch(&graph, "POST", "/api/v1/me/tokens", `{"label":"ctl"}`, alice)
	testing.expect_value(t, tok.status, 201)
	bearer := []contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", device_test_json_string(tok.body, "plaintext")})}}
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/directory/genesis", vt_genesis_body(user_id, &root), bearer).status, 403)
	b := vt_make_dev(2)
	reg_st := vt_statement("register", user_id, &b, &b, "", "")
	reg_body := strings.concatenate({`{"statement":"`, vt_escape(reg_st), `","proof_signature":`, vt_sign(&b, reg_st), "}"})
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/devices/register", reg_body, bearer).status, 403)

	_, _, vok := vt_ensure_vault(&graph, alice)
	testing.expect(t, vok)
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/directory/reset", "{}", bearer).status, 403)

	// Schedule: 201, then idempotent 200 with the same due time.
	sched := dispatch(&graph, "POST", "/api/v1/vault/directory/reset", "{}", alice)
	testing.expect_value(t, sched.status, 201)
	testing.expect(t, strings.contains(sched.body, `"due_at":"2026-10-22T10:00:00Z"`), sched.body)
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/directory/reset", "{}", alice).status, 200)
	dir := dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect(t, strings.contains(dir.body, `"reset":{"requested_at":"2026-10-19T10:00:00Z","due_at":"2026-10-22T10:00:00Z"}`), dir.body)

	// Cancel: unsigned refused; signed by the root accepted.
	cancel_path :: "/api/v1/vault/directory/reset/cancel"
	testing.expect_value(t, dispatch(&graph, "POST", cancel_path, "{}", alice).status, 401)
	cancelled := dispatch(&graph, "POST", cancel_path, "{}", vt_signed_headers(alice, &root, user_id, "POST", cancel_path, "{}", "nonce-vt-reset-000001", VT_NOW_MS))
	testing.expect(t, cancelled.status == 200 && strings.contains(cancelled.body, `"cancelled":true`), cancelled.body)
	dir = dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect(t, strings.contains(dir.body, `"reset":null`), dir.body)

	// Schedule again with a bridge enrolled; before the delay nothing happens, after
	// it the directory is gone and the bridge's credential is revoked.
	bridge_id, bridge_token, enrolled := device_enroll_test_bridge(&graph, alice, "box", commit = false)
	testing.expect(t, enrolled)
	_, before_found, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	testing.expect(t, before_found)
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/directory/reset", "{}", alice).status, 201)
	now = "2026-10-22T09:59:59Z"
	testing.expect_value(t, app.reaper_sweep_vault_resets(&graph), 0)
	testing.expect_value(t, dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice).status, 200)
	now = "2026-10-22T10:00:00Z"
	testing.expect_value(t, app.reaper_sweep_vault_resets(&graph), 1)
	testing.expect_value(t, dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice).status, 404)
	_ = bridge_token
	// A still-pending enrollment is rolled back (row deleted); an enrolled one revoked.
	row, row_found, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	testing.expect(t, !row_found || row.status == .Revoked, "the bridge lost its credentials")
	// A new genesis is possible again.
	testing.expect_value(t, dispatch(&graph, "POST", "/api/v1/vault/directory/genesis", vt_genesis_body(user_id, &root), alice).status, 201)
}
