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

	// Register B (self-signed proof); the response carries the 12-symbol code.
	b := vt_make_dev(2)
	reg_st := vt_statement("register", user_id, &b, &b, "", "")
	reg := dispatch(&graph, "POST", "/api/v1/vault/devices/register", strings.concatenate({`{"statement":"`, vt_escape(reg_st), `","proof_signature":`, vt_sign(&b, reg_st), "}"}), alice)
	testing.expect_value(t, reg.status, 201)
	code := device_test_json_string(reg.body, "user_code")
	testing.expect_value(t, len(code), 14)

	// /device/verify resolves it as kind=browser; /device/approve never treats it as a grant.
	ver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"user_code":"`, code, `"}`}), alice)
	testing.expect_value(t, ver.status, 200)
	testing.expect(t, strings.contains(ver.body, `"kind":"browser"`) && strings.contains(ver.body, b.id))
	as_grant := dispatch(&graph, "POST", "/api/v1/device/approve", strings.concatenate({`{"user_code":"`, code, `","approve":true}`}), alice)
	testing.expect_value(t, as_grant.status, 404)
	// Another account cannot resolve alice's code.
	bob := []contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}
	bob_ver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"user_code":"`, code, `"}`}), bob)
	testing.expect_value(t, bob_ver.status, 404)

	// Approve B: unsigned -> 401; signed by the root -> 200, version 2.
	approve_path := strings.concatenate({"/api/v1/vault/devices/", b.id, "/approve"})
	st := vt_statement("approve", user_id, &root, &b, "1", "1")
	body := strings.concatenate({`{"user_code":"`, code, `","expected_version":1,"statement":"`, vt_escape(st), `","signature":`, vt_sign(&root, st), `,"wrap":`, vt_wrap_json(user_id, &root, &b, 1, 1), "}"})
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
	testing.expect(t, strings.contains(self.body, `"status":"approved"`) && strings.contains(self.body, `"wrap":{`), self.body)

	// A bridge without a vault approval is refused; with one it enrolls, and its
	// 8-symbol grant code resolves as kind=bridge only.
	bridge_id, _, enrolled := device_enroll_test_bridge(&graph, alice, "box")
	testing.expect(t, enrolled && bridge_id != "", "bridge enrolls with a vault approval")
	dir := dispatch(&graph, "GET", "/api/v1/vault/directory", "", alice)
	testing.expect_value(t, dir.status, 200)
	testing.expect(t, strings.contains(dir.body, `"kind":"bridge"`) && strings.contains(dir.body, bridge_id), "bridge listed in the directory")
	testing.expect(t, strings.contains(dir.body, `"root_sign_public_key":"`) && strings.contains(dir.body, `"epochs":[{"epoch":1`), "chain material exposed")

	authz := dispatch(&graph, "POST", "/api/v1/device/authorize", strings.concatenate({
		`{"client":"ham-bridge","device_label":"x","os":"linux","bridge_public_key":"`, DEVICE_TEST_PUBLIC_KEY,
		`","bridge_identity_public_key":"`, vt_make_dev(4000, "bridge").sign_pub,
		`","code_challenge":"`, DEVICE_TEST_CODE_CHALLENGE, `","code_challenge_method":"S256"}`,
	}), nil)
	testing.expect_value(t, authz.status, 200)
	grant_code := device_test_json_string(authz.body, "user_code")
	gver := dispatch(&graph, "POST", "/api/v1/device/verify", strings.concatenate({`{"user_code":"`, grant_code, `"}`}), alice)
	testing.expect(t, gver.status == 200 && strings.contains(gver.body, `"kind":"bridge"`), gver.body)
	no_approval := dispatch(&graph, "POST", "/api/v1/device/approve", strings.concatenate({`{"user_code":"`, grant_code, `","approve":true}`}), alice)
	testing.expect_value(t, no_approval.status, 400)
	// The bridge's code as a pending-device code: never found.
	as_device := dispatch(&graph, "POST", approve_path, strings.concatenate({`{"user_code":"`, grant_code, `","expected_version":3}`}), vt_signed_headers(alice, &root, user_id, "POST", approve_path, strings.concatenate({`{"user_code":"`, grant_code, `","expected_version":3}`}), "nonce-vt-000000000003", VT_NOW_MS))
	testing.expect(t, as_device.status == 404 || as_device.status == 409, as_device.body)
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
	bridge_id, bridge_token, enrolled := device_enroll_test_bridge(&graph, alice, "box")
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
