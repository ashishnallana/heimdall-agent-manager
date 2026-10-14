package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"

// Owner API for bridge error events (bridge_logs plan v2 §4.4): owner-scoped
// like every other /api/v1/bridges/* route (404 unknown, 403 someone else's),
// paginated by id, server-rendered `message`, purge, and revoke cleanup.
@(test)
test_bridge_events_owner_api_roundtrip :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-bridge-events-%d.db", os.get_pid())
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
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if !enroll_ok do return

	// Three events straight through the repository (the writer thread is
	// exercised by its own tests); ids ascend with insertion order.
	rows := [?]domain.Bridge_Log_Event{
		{bridge_id = bridge_id, ts_ms = 1000, received_at = 1001, level = "warn", code = "hub_ws_closed", fields_json = `{"reason":"eof"}`, count = 2},
		{bridge_id = bridge_id, ts_ms = 2000, received_at = 2001, level = "error", code = "provider_missing", fields_json = `{"provider":"claude"}`, count = 1},
		{bridge_id = bridge_id, ts_ms = 3000, received_at = 3001, level = "error", code = "other", fields_json = `{}`, count = 1},
	}
	n, ins_err := iface.bridge_log_insert_batch(&graph.bridge_log_repo, rows[:])
	testing.expect_value(t, ins_err.code, domain.Error_Code.None)
	testing.expect_value(t, n, 3)

	path := fmt.tprintf("/api/v1/bridges/%s/events", bridge_id)
	get := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, request_id = "req_ev_1", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, get.status, 200)
	testing.expect(t, strings.contains(get.body, `"code":"other"`), get.body)
	testing.expect(t, strings.index(get.body, `"code":"other"`) < strings.index(get.body, `"code":"provider_missing"`), "newest first")
	testing.expect(t, strings.contains(get.body, `"message":"Provider CLI is not installed or has no runnable command (provider: claude)"`), get.body)
	testing.expect(t, strings.contains(get.body, `"fields":{"reason":"eof"}`) && strings.contains(get.body, `"count":2`), get.body)
	testing.expect(t, strings.contains(get.body, `"has_more":false`), get.body)
	testing.expect(t, !strings.contains(get.body, "alice"), "owner never appears in the events payload")

	// Pagination by id: limit=1 -> newest only, has_more, cursor to the rest.
	page := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = "limit=1", request_id = "req_ev_2", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, page.status, 200)
	testing.expect(t, strings.contains(page.body, `"has_more":true`) && strings.count(page.body, `"id":`) == 1, page.body)
	cursor := ""
	if idx := strings.index(page.body, `"next_before_id":`); idx >= 0 {
		rest := page.body[idx + len(`"next_before_id":`):]
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
		cursor = rest[:end]
	}
	testing.expect(t, cursor != "" && cursor != "0", "cursor present")
	page2 := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, query = fmt.tprintf("limit=50&before_id=%s", cursor), request_id = "req_ev_3", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, page2.status, 200)
	testing.expect(t, strings.count(page2.body, `"id":`) == 2 && !strings.contains(page2.body, `"code":"other"`), page2.body)

	// Ownership: the codebase's ownership.require_owner answers 404 ("resource
	// not found") for someone else's bridge — never 403, which would confirm the
	// id exists — and 404 for an unknown bridge; this route follows suit.
	forbidden := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, request_id = "req_ev_4", remote_addr = "127.0.0.1", headers = bob[:]})
	testing.expect_value(t, forbidden.status, 404)
	testing.expect(t, strings.contains(forbidden.body, "resource not found"), forbidden.body)
	missing := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/bridges/brg_does_not_exist/events", request_id = "req_ev_5", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, missing.status, 404)
	bob_purge := api_http.router_dispatch(&graph.router, api_http.Request{method = "DELETE", path = path, request_id = "req_ev_6", remote_addr = "127.0.0.1", headers = bob[:]})
	testing.expect_value(t, bob_purge.status, 404)

	// Owner purge empties the ring.
	purge := api_http.router_dispatch(&graph.router, api_http.Request{method = "DELETE", path = path, request_id = "req_ev_7", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, purge.status, 200)
	testing.expect(t, strings.contains(purge.body, `"deleted":3`), purge.body)
	empty := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = path, request_id = "req_ev_8", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect(t, strings.contains(empty.body, `"events":[]`), empty.body)

	// Revoke deletes whatever arrived since.
	_, _ = iface.bridge_log_insert_batch(&graph.bridge_log_repo, rows[:1])
	revoke := api_http.router_dispatch(&graph.router, api_http.Request{method = "POST", path = fmt.tprintf("/api/v1/bridges/%s/revoke", bridge_id), request_id = "req_ev_9", remote_addr = "127.0.0.1", headers = alice[:]})
	testing.expect_value(t, revoke.status, 200)
	left, _ := iface.bridge_log_count_by_bridge(&graph.bridge_log_repo, bridge_id)
	testing.expect_value(t, left, 0)
}
