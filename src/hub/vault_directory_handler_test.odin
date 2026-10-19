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
import api_http "odin_test:hub/transport/http"

VT_NOW    :: "2026-10-19T10:00:00Z"
VT_NOW_MS :: i64(1_792_404_000_000)

@(private = "file")
vt_clock_now :: proc(ctx: rawptr) -> string { return VT_NOW }

// A per-test throwaway database file (billing needs a file-backed DB).
@(private = "file")
vt_db_path :: proc() -> string {
	dir := os.get_env("TEMP", context.temp_allocator)
	if dir == "" do dir = os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" do dir = "/tmp"
	return fmt.tprintf("%s/heimdall-vault-dir-test-%d.db", dir, os.get_pid())
}

@(private = "file")
vt_graph :: proc(t: ^testing.T, graph: ^app.App_Graph, db_path: string) -> bool {
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
	graph.clock = platform.Clock{now = vt_clock_now}
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
	db_path := vt_db_path()
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
