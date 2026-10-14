package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_log_service "odin_test:hub/service/bridge_log"

// Lives with the other graph-level tests (not in package app): build_graph
// attaches the process-global DB collectors, which would race app's own
// collector tests under the parallel runner.
//
// The reaper's sweep prunes bridge_log_events older than 7 d by received_at,
// but only every 15 min; the first sweep after boot prunes.
@(test)
test_reaper_prunes_old_bridge_log_events_every_15_min :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-reaper-blog-%d.db", os.get_pid())
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

	now_ms := time.now()._nsec / 1_000_000
	old := now_ms - i64(8 * 24 * time.Hour / time.Millisecond)
	rows := [?]domain.Bridge_Log_Event{
		{bridge_id = "brg_reap", ts_ms = old, received_at = old, level = "warn", code = "hub_ws_closed", fields_json = "{}", count = 1},
		{bridge_id = "brg_reap", ts_ms = now_ms, received_at = now_ms, level = "warn", code = "hub_ws_closed", fields_json = "{}", count = 1},
	}
	_, err := iface.bridge_log_insert_batch(&graph.bridge_log_repo, rows[:])
	testing.expect_value(t, err.code, domain.Error_Code.None)

	app.reaper_sweep_once(&graph)
	n, _ := iface.bridge_log_count_by_bridge(&graph.bridge_log_repo, "brg_reap")
	testing.expect_value(t, n, 1)
	testing.expect(t, graph.bridge_logs.next_prune_ms > now_ms, "next prune scheduled")

	// Within the 15-min window a new old row survives the next sweep.
	_, _ = iface.bridge_log_insert_batch(&graph.bridge_log_repo, rows[:1])
	app.reaper_sweep_once(&graph)
	n, _ = iface.bridge_log_count_by_bridge(&graph.bridge_log_repo, "brg_reap")
	testing.expect_value(t, n, 2)
	// Force the window to elapse.
	graph.bridge_logs.next_prune_ms = now_ms - 1
	app.reaper_sweep_once(&graph)
	n, _ = iface.bridge_log_count_by_bridge(&graph.bridge_log_repo, "brg_reap")
	testing.expect_value(t, n, 1)
	testing.expect_value(t, bridge_log_service.PRUNE_INTERVAL, 15 * time.Minute)
}
