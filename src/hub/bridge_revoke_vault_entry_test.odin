package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

// Revoking a bridge from bridge settings also retires its vault directory identity
// (hub-marked revoked), and GET /vault/directory then recommends a rotation, since
// that identity held the keyring and no epoch was rotated.
@(test)
test_bridge_revoke_retires_vault_entry_and_flags_rotation :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("%s/heimdall-hub-test-bridge-revoke-vault-%d.db", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if !enroll_ok do return

	get_dir :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, rid: string) -> api_http.Response {
		return api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/vault/directory", request_id = rid, remote_addr = "127.0.0.1", headers = headers})
	}
	before := get_dir(&graph, alice[:], "req_rv_1")
	testing.expect_value(t, before.status, 200)
	testing.expect(t, strings.contains(before.body, `"rotation_recommended":false`), before.body)
	bridge_entry := strings.concatenate({`"bridge_id":"`, bridge_id, `"`}, context.temp_allocator)
	testing.expect(t, strings.contains(before.body, bridge_entry), "the bridge identity is in the directory")

	revoked := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = fmt.tprintf("/api/v1/bridges/%s/revoke", bridge_id), request_id = "req_rv_2", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, revoked.status, 200)

	after := get_dir(&graph, alice[:], "req_rv_3")
	testing.expect_value(t, after.status, 200)
	testing.expect(t, strings.contains(after.body, `"rotation_recommended":true`), after.body)
	// The bridge's entry is now revoked (no approved identity maps to it).
	idx := strings.index(after.body, bridge_entry)
	testing.expect(t, idx >= 0)
	if idx >= 0 {
		start := strings.last_index(after.body[:idx], `{"device_id"`)
		testing.expect(t, start >= 0 && strings.contains(after.body[start:idx], `"status":"revoked"`), after.body[max(start, 0):idx])
	}
}
