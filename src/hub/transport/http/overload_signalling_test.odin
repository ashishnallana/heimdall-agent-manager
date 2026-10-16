package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// REQ-ERR-PROTO-B: overload answers carry Retry-After (whole seconds, rounded up)
// and the exact retry_after_ms in the body; other errors carry neither.
@(test)
test_respond_error_overload_sets_retry_after :: proc(t: ^testing.T) {
	busy := domain.domain_error(.Bridge_Busy, "busy")
	busy.details_json = `{"retry_after_ms":2500,"overload_scope":"global"}`
	resp := respond_error(busy, "req_1")
	defer delete(resp.body)
	testing.expect_value(t, resp.status, 503)
	testing.expect_value(t, len(resp.headers), 1)
	if len(resp.headers) == 1 {
		testing.expect_value(t, resp.headers[0].name, "Retry-After")
		testing.expect_value(t, resp.headers[0].value, "3")
	}
	testing.expect(t, strings.contains(resp.body, `"retry_after_ms":2500`), "body carries the exact back-off")

	limited := respond_error(domain.domain_error(.Rate_Limited, "slow down"), "req_2")
	defer delete(limited.body)
	testing.expect_value(t, limited.status, 429)
	testing.expect(t, len(limited.headers) == 1 && limited.headers[0].value == "1", "no hint still says at least 1s")
	testing.expect(t, !strings.contains(limited.body, "retry_after_ms"), "no hint, no body field")

	missing := respond_error(domain.domain_error(.Not_Found, "nope"), "req_3")
	defer delete(missing.body)
	testing.expect_value(t, len(missing.headers), 0)
}

@(test)
test_respond_error_counts_errors_by_code_and_class :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	series := metrics.with(project_service.fleet_metrics.errors, "not_found", "fatal")
	before := metrics.counter_value(series)
	for _ in 0 ..< 2 do delete(respond_error(domain.domain_error(.Not_Found, "nope"), "req").body)
	testing.expect_value(t, metrics.counter_value(series), before + 2)
}

// REQ-ERR-PROTO-B: the bridge's dispatcher, HTTP-retry and breaker counters from the
// heartbeat reach /metrics, and are removed when the bridge disconnects.
@(test)
test_heartbeat_reliability_counters_exported :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_reliability"
	frame := `{"type":"bridge_heartbeat","command_dispatch":{"queued":0,"accepted":40,"rejected":3,"completed":36,"deadline_expired":1},"dependency_breakers":{"tracked":2,"open":1,"opened":5,"rejected":9},"http_retries":{"retry":7,"recovered":4,"gave_up":2,"deferred":1},"active_instance_ids":[]}`
	bridge_apply_heartbeat_reliability(bid, frame)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(40))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "shed")), u64(3))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "completed")), u64(36))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "deadline_expired")), u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "retry")), u64(7))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "recovered")), u64(4))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "gave_up")), u64(2))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "deferred")), u64(1))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_breakers_open, bid)), i64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_breaker_trips, bid)), u64(5))

	project_service.fleet_metrics_tombstone_bridge(bid)
	for fam in ([]^metrics.Family{m.bridge_dispatch, m.bridge_http_retries, m.bridge_breakers_open, m.bridge_breaker_trips}) {
		for s in fam.series do if s.label_values[0] == bid do testing.expectf(t, metrics.series_is_dead(s), "%s tombstoned on disconnect", fam.name)
	}
}

// An older bridge sends no http_retries, and a malformed object is skipped whole.
@(test)
test_heartbeat_reliability_tolerates_missing_and_bad_objects :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_reliability_old"
	bridge_apply_heartbeat_reliability(bid, `{"type":"bridge_heartbeat","command_dispatch":{"accepted":-1,"rejected":0,"completed":0,"deadline_expired":0},"active_instance_ids":[]}`)
	for fam in ([]^metrics.Family{m.bridge_dispatch, m.bridge_http_retries}) {
		for s in fam.series do testing.expectf(t, s.label_values[0] != bid || metrics.series_is_dead(s), "%s must not be set from a bad/missing object", fam.name)
	}
}

// REQ-ERR-PROTO-B: bridge_ready asks for the 45s heartbeat the bridge follows.
@(test)
test_bridge_ready_payload_heartbeat_interval :: proc(t: ^testing.T) {
	ready := bridge_ready_payload("brg_x", 1, false, "etag")
	defer delete(ready)
	testing.expect(t, strings.contains(ready, `"heartbeat_interval_seconds":45,`), "bridge_ready carries the 45s cadence")
}

// REQ-ERR-PROTO-B: fs mutations get the bridge's 20s cap (hub_command_dispatch.odin
// bridge_command_spec), so the hub's wait never cuts a delete or batch write short;
// reads keep 10s.
@(test)
test_fs_command_timeout_matches_bridge_cap :: proc(t: ^testing.T) {
	for command_type in ([]string{"fs_make_dir", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete"}) {
		testing.expect_value(t, fs_command_timeout_ms(command_type), 20_000)
	}
	for command_type in ([]string{"fs_list_dir", "fs_stat", "fs_read_file", "agent_run_dir_list"}) {
		testing.expect_value(t, fs_command_timeout_ms(command_type), 10_000)
	}
}
