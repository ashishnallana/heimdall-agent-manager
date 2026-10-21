package http

import "core:fmt"
import "core:strings"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"

// HTTP-layer metrics (plan section 3.7). All families are nil until
// http_metrics_init runs, and every metrics op is nil-safe, so tests that drive
// handle_client directly need no setup.
//
// Rules enforced here:
//   - the timer starts AFTER read_http_request and covers only router_dispatch;
//   - upgrade / raw-upgrade routes are NOT measured here (they would return
//     hours later); they are accounted as ws_connections instead;
//   - `route` is the matched PATTERN or "unmatched", never the raw path;
//   - `method` is enum-mapped (unknown -> "other") so a client cannot mint series.
Http_Metrics :: struct {
	requests_total:   ^metrics.Family, // {route, method, status_class}
	request_duration: ^metrics.Family, // {route, method}
	in_flight:        ^metrics.Series,
	accept_errors:    ^metrics.Series,
	request_db:       ^metrics.Family, // {route, component}; DB telemetry only
}

http_metrics: Http_Metrics

HTTP_DURATION_BUCKETS := [?]f64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}
// With HEIMDALL_DB_TELEMETRY=basic the request histogram also resolves the
// 1-10 ms band (plan §2.2 G7). Never draw a quantile across that layout change.
HTTP_DURATION_BUCKETS_FINE := [?]f64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

http_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	http_metrics.requests_total = metrics.new_counter(reg, "heimdall_http_requests_total",
		"HTTP requests handled by the hub router, by matched route pattern.", {"route", "method", "status_class"})
	buckets := HTTP_DURATION_BUCKETS_FINE[:] if dbt.enabled() else HTTP_DURATION_BUCKETS[:]
	http_metrics.request_duration = metrics.new_histogram_seconds(reg, "heimdall_http_request_duration_seconds",
		"Router dispatch latency in seconds (excludes request read and WebSocket upgrades).", {"route", "method"}, buckets)
	if dbt.enabled() {
		http_metrics.request_db = metrics.new_counter(reg, "heimdall_http_request_db_seconds_total",
			"DB time inside plain HTTP dispatch by disjoint component; divide by request_duration_seconds_sum for the share.", {"route", "component"}, 9)
	}
	http_metrics.in_flight = metrics.with(metrics.new_gauge(reg, "heimdall_http_in_flight",
		"Requests currently inside the hub router (excludes upgraded connections)."))
	http_metrics.accept_errors = metrics.with(metrics.new_counter(reg, "heimdall_http_accept_errors_total",
		"accept() failures on the public listener (e.g. EMFILE)."))
}

// http_metrics_observe records one dispatched request.
http_metrics_observe :: proc(route, method: string, status: int, elapsed: time.Duration) {
	if http_metrics.requests_total == nil do return
	m := http_metric_method(method)
	metrics.counter_inc(metrics.with(http_metrics.requests_total, route, m, http_status_class(status)))
	metrics.observe_duration(metrics.with(http_metrics.request_duration, route, m), elapsed)
}

// http_request_db_observe closes the request's DB scope: adds its disjoint
// components to heimdall_http_request_db_seconds_total{route} and, when the
// request is slow or sampled, writes one sanitized db_slow_request line.
http_request_db_observe :: proc(route, method: string, status: int, elapsed: time.Duration, request_id: string) {
	totals, ok := dbt.scope_end()
	if !ok do return
	if http_metrics.request_db != nil {
		for c in dbt.Component {
			if totals.component[c] > 0 do metrics.counter_add(metrics.with(http_metrics.request_db, route, dbt.COMPONENT_LABELS[c]), u64(totals.component[c]))
		}
	}
	d := dbt.slow_decide(i64(elapsed), dbt.slow_config.slow_ms)
	if !d.emit do return
	line := format_db_slow_request(route, http_metric_method(method), http_status_class(status), i64(elapsed), request_id, totals, d, context.temp_allocator)
	fmt.eprintln(line)
}

// format_db_slow_request builds the db_slow_request record. Only bounded
// values: route PATTERN, mapped method, status class, timings, counts and
// repository file:line of the top-3 calls. Never SQL text, query strings,
// bodies, path parameters or user/agent ids; request_id is client-supplied, so
// it is truncated to 64 bytes and restricted to [A-Za-z0-9_.:-].
format_db_slow_request :: proc(route, method, status_class: string, request_ns: i64, request_id: string, t: dbt.Scope_Totals, d: dbt.Slow_Decision, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "db_slow_request reason=%s route=%q method=%s status=%s request_ns=%d app_lock_wait_ns=%d conn_wait_ns=%d exec_ns=%d busy_wait_ns=%d steps=%d statements=%d tx_count=%d tx_hold_ns=%d busy_errors=%d dropped_since_last=%d",
		dbt.SLOW_REASON_LABELS[d.reason], route, method, status_class, request_ns,
		t.component[.App_Lock_Wait], t.component[.Conn_Wait], t.component[.Exec_Excl_Busy], t.component[.Busy_Wait],
		t.steps, t.statements, t.tx_count, t.tx_hold_ns, t.busy_errors, d.dropped_since_last)
	strings.write_string(&b, " request_id=")
	n := 0
	for i in 0..<len(request_id) {
		if n >= 64 do break
		ch := request_id[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.' || ch == ':' {
			strings.write_byte(&b, ch)
			n += 1
		}
	}
	for top, i in t.top {
		if top.exec_ns == 0 && top.wait_ns == 0 do continue
		fmt.sbprintf(&b, " top%d=%s/%s/%s:%d/exec_ns=%d/wait_ns=%d", i + 1, top.conn, top.op, top.file, top.line, top.exec_ns, top.wait_ns)
	}
	return strings.to_string(b)
}

http_metric_method :: proc(method: string) -> string {
	switch method {
	case "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS":
		return method
	}
	return "other"
}

http_status_class :: proc(status: int) -> string {
	switch {
	case status >= 100 && status < 200: return "1xx"
	case status >= 200 && status < 300: return "2xx"
	case status >= 300 && status < 400: return "3xx"
	case status >= 400 && status < 500: return "4xx"
	case status >= 500 && status < 600: return "5xx"
	}
	return "other"
}
