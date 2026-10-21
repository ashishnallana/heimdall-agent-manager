package http

import "core:strings"
import "core:testing"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"

// Per-request DB accounting (DB telemetry plan §2.3.4, §3). Flips the global
// telemetry mode: verify-db-telemetry.sh runs these with ODIN_TEST_THREADS=1.

@(test)
test_request_db_scope_flush :: proc(t: ^testing.T) {
	dbt.set_mode(.Basic)
	defer dbt.set_mode(.Off)
	reg := metrics.init_global()
	dbt.init(reg)
	http_metrics_init(reg)
	testing.expect(t, http_metrics.request_db != nil, "request_db family registered in basic mode")
	route := "/api/v1/dbt-test/{id}"

	dbt.scope_begin(.Http)
	started := time.tick_now()
	dbt.add_component(.App_Lock_Wait, 1_000)
	dbt.scope_begin(.Http) // nested scope: only the outermost flushes
	dbt.add_component(.Conn_Wait, 2_000)
	_, inner_flushed := dbt.scope_end()
	testing.expect(t, !inner_flushed, "nested scope_end does not flush")
	dbt.add_component(.Exec_Excl_Busy, 3_000)
	time.sleep(time.Millisecond)
	elapsed := time.tick_since(started)
	http_request_db_observe(route, "GET", 200, elapsed, "req_local")

	got := [dbt.Component]u64{}
	sum: u64
	for c in dbt.Component {
		got[c] = metrics.counter_value(metrics.with(http_metrics.request_db, route, dbt.COMPONENT_LABELS[c]))
		sum += got[c]
	}
	testing.expect_value(t, got[.App_Lock_Wait], u64(1_000))
	testing.expect_value(t, got[.Conn_Wait], u64(2_000))
	testing.expect_value(t, got[.Exec_Excl_Busy], u64(3_000))
	testing.expect_value(t, got[.Busy_Wait], u64(0))
	testing.expect(t, sum <= u64(elapsed), "components sum <= request duration")
	scope_http := metrics.counter_value(dbt.tm.scope_seconds[.Http][.Exec_Excl_Busy])
	testing.expect(t, scope_http >= 3_000, "scope=http total flushed")
	_, again := dbt.scope_end()
	testing.expect(t, !again, "scope closed")
}

@(test)
test_slow_request_log_sanitized :: proc(t: ^testing.T) {
	totals := dbt.Scope_Totals{scope = .Http, steps = 3, statements = 2}
	totals.component[.Conn_Wait] = 40_000_000
	totals.top[0] = dbt.Top_Call{conn = "main", op = "select", exec_ns = 5, wait_ns = 40_000_000, file = "task_repo_sqlite.odin", line = 42}
	d := dbt.Slow_Decision{emit = true, reason = .Slow, dropped_since_last = 2}
	hostile_id := "abc'; SELECT * FROM users WHERE name='x' --?token=secret&body={\"a\":1}"
	line := format_db_slow_request("/api/v1/tasks/{id}", "GET", "2xx", 300_000_000, hostile_id, totals, d, context.temp_allocator)
	testing.expect(t, strings.has_prefix(line, "db_slow_request reason=slow "), line)
	testing.expect(t, strings.contains(line, "route=\"/api/v1/tasks/{id}\""), "route pattern only")
	testing.expect(t, strings.contains(line, "top1=main/select/task_repo_sqlite.odin:42/"), "top call as file:line")
	testing.expect(t, strings.contains(line, "dropped_since_last=2"), "drop count carried")
	id_at := strings.index(line, "request_id=")
	rest := line[id_at + len("request_id="):]
	id := rest[:strings.index_byte(rest, ' ')] if strings.index_byte(rest, ' ') >= 0 else rest
	testing.expect(t, len(id) <= 64, "request_id truncated")
	for bad in ([]string{"'", ";", "*", "=", "?", "&", "{", "\""}) {
		testing.expectf(t, !strings.contains(id, bad), "request_id keeps %q: %s", bad, id)
	}
	testing.expect(t, !strings.contains(line, "SELECT *"), "no SQL text")
	testing.expect(t, !strings.contains(line, "token=secret"), "no query string")

	// Token bucket: bursts beyond 10/s are dropped and counted.
	dbt.set_mode(.Basic)
	defer dbt.set_mode(.Off)
	dbt.init(metrics.init_global())
	dbt.slow_reset_for_test()
	dropped0 := metrics.counter_value(dbt.tm.slow_dropped[.Slow])
	emitted := 0
	for _ in 0..<25 do if dbt.slow_decide(500_000_000, 250).emit do emitted += 1
	testing.expect(t, emitted >= 10 && emitted <= 11, "rate limited to ~10 lines")
	testing.expect(t, metrics.counter_value(dbt.tm.slow_dropped[.Slow]) >= dropped0 + 14, "drops counted")
	dbt.slow_reset_for_test()
}
