package http

import "core:time"
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
}

http_metrics: Http_Metrics

HTTP_DURATION_BUCKETS := [?]f64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

http_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	http_metrics.requests_total = metrics.new_counter(reg, "heimdall_http_requests_total",
		"HTTP requests handled by the hub router, by matched route pattern.", {"route", "method", "status_class"})
	http_metrics.request_duration = metrics.new_histogram_seconds(reg, "heimdall_http_request_duration_seconds",
		"Router dispatch latency in seconds (excludes request read and WebSocket upgrades).", {"route", "method"}, HTTP_DURATION_BUCKETS[:])
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
