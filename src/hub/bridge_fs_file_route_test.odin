package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"

// GET /api/v1/bridges/{id}/fs/file (New project modal: read AGENTS.md / CLAUDE.md
// before the project exists). Driven through the real router so the route is
// registered and not shadowed by /bridges/*/fs or /bridges/*. The bridge-side read
// (fs_root sandbox, vault_locked, vault-encrypted content) is the existing
// fs_read_file command, covered by src/bridge/fs_management_test.odin.
@(test)
test_bridge_fs_file_route_guards :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-bridge-fs-file-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")
	bob := hub_test_user_headers(&graph, "bob")
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")

	path := fmt.tprintf("/api/v1/bridges/%s/fs/file", bridge_id)
	query := "path=%2Fhome%2Falice%2Frepo%2FAGENTS.md&limit=4096"

	// 1. Unauthenticated -> 401.
	unauth := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = query, request_id = "req_f1", remote_addr = "127.0.0.1"})
	testing.expect_value(t, unauth.status, 401)

	// 2. Missing path -> 400 validation, before any bridge lookup or relay.
	no_path := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = "limit=4096", request_id = "req_f2", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, no_path.status, 400)
	testing.expect(t, strings.contains(no_path.body, "path is required"), no_path.body)

	// 3. Another user's bridge -> 404 (owner guard shared with /fs and /fs/stat).
	cross := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = query, request_id = "req_f3", remote_addr = "127.0.0.1", headers = bob[:]})
	testing.expect_value(t, cross.status, 404)

	// 4. Unknown bridge -> 404.
	missing := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges/brg_nonexistent/fs/file", query = query, request_id = "req_f4", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, missing.status, 404)

	// 5. Owner, but the bridge has no live socket -> bridge_offline, never a hang or
	//    a 200 (the route reached the relay, not the /bridges/* detail handler).
	offline := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = query, request_id = "req_f5", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect(t, offline.status != 200, offline.body)
	testing.expect(t, strings.contains(offline.body, "bridge_offline"), offline.body)

	// The same request on the list route behaves the same way (parity with /fs).
	list := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = fmt.tprintf("/api/v1/bridges/%s/fs", bridge_id), query = "path=", request_id = "req_f6", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, offline.status, list.status)
}
