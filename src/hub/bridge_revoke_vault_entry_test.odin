package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

// Revoking a bridge from bridge settings gives its vault directory identity a
// retirement HINT: no version is consumed and the signed log is untouched; GET
// /vault/directory lists it in retired_hints for an approved browser to revoke.
@(test)
test_bridge_revoke_hints_vault_entry_retirement :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("%s/heimdall-hub-test-bridge-revoke-vault-%d.db", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if !enroll_ok do return

	get_dir :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, rid: string) -> api_http.Response {
		return api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/vault/directory", request_id = rid, remote_addr = "127.0.0.1", headers = headers})
	}
	before := get_dir(&graph, alice[:], "req_rv_1")
	testing.expect_value(t, before.status, 200)
	testing.expect(t, strings.contains(before.body, `"retired_hints":[]`), before.body)
	bridge_entry := strings.concatenate({`"bridge_id":"`, bridge_id, `"`}, context.temp_allocator)
	testing.expect(t, strings.contains(before.body, bridge_entry), "the bridge identity is in the directory")

	revoked := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = fmt.tprintf("/api/v1/bridges/%s/revoke", bridge_id), request_id = "req_rv_2", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, revoked.status, 200)

	after := get_dir(&graph, alice[:], "req_rv_3")
	testing.expect_value(t, after.status, 200)
	testing.expect(t, strings.contains(after.body, `"retired_hints":["dev_`), after.body)
	testing.expect_value(t, device_test_json_string(after.body, "head_hash"), device_test_json_string(before.body, "head_hash"))
	// The entry stays approved until a browser signs its revoke, with retired_at set.
	idx := strings.index(after.body, bridge_entry)
	testing.expect(t, idx >= 0)
	if idx >= 0 {
		start := strings.last_index(after.body[:idx], `{"device_id"`)
		end := idx + strings.index(after.body[idx:], "}")
		entry := after.body[max(start, 0):end]
		testing.expect(t, start >= 0 && strings.contains(entry, `"status":"approved"`) && !strings.contains(entry, `"retired_at":""`), entry)
	}
}
