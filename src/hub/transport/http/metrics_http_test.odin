package http

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import metrics "odin_test:lib/metrics"

@(private = "file")
Metrics_Dispatch_State :: struct {
	router: ^Router,
	socket: net.TCP_Socket,
	source: net.Endpoint,
}

@(private = "file")
metrics_dispatch_thread :: proc(data: rawptr) {
	s := (^Metrics_Dispatch_State)(data)
	handle_client(s.socket, s.source, s.router, Server_Config{})
}

@(private = "file")
metrics_test_ok_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return Response{status = 201, content_type = "text/plain", body = "ok"}
}

@(private = "file")
metrics_test_fail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	time.sleep(20 * time.Millisecond)
	return Response{status = 503, content_type = "text/plain", body = "nope"}
}

@(private = "file")
metrics_test_upgrade_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	write_http_response(client, Response{status = 200, content_type = "text/plain", body = "upgraded"})
}

// Drives one raw request through handle_client (same shape as the preview
// origin tests) and returns the response text.
@(private = "file")
metrics_test_request :: proc(t: ^testing.T, router: ^Router, request: string) -> string {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	defer net.close(client)
	server_socket, source, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept loopback")
	state := Metrics_Dispatch_State{router = router, socket = server_socket, source = source}
	worker := thread.create_and_start_with_data(rawptr(&state), metrics_dispatch_thread)
	defer { thread.join(worker); thread.destroy(worker) }
	_, _ = net.send_tcp(client, transmute([]byte)request)
	buf: [2048]byte
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:max(n, 0)]))
}

@(private = "file")
counter_of :: proc(route, method, class: string) -> u64 {
	return metrics.counter_value(metrics.with(http_metrics.requests_total, route, method, class))
}

// REQ: http middleware labels by matched PATTERN (never the raw path), classes
// the status, measures only router_dispatch, excludes upgrade routes, and
// leaves in_flight at zero afterwards.
@(test)
test_http_metrics_middleware :: proc(t: ^testing.T) {
	http_metrics_init(metrics.init_global())
	router := new_router()
	defer router_free(&router)
	hits := 0
	router_add(&router, "GET", "/api/v1/mtest/items/*", rawptr(&hits), metrics_test_ok_handler)
	router_add(&router, "POST", "/api/v1/mtest/fail", rawptr(&hits), metrics_test_fail_handler)
	router_add_upgrade(&router, "GET", "/api/v1/mtest/stream", rawptr(&hits), metrics_test_upgrade_handler)

	before_ok := counter_of("/api/v1/mtest/items/*", "GET", "2xx")
	before_fail := counter_of("/api/v1/mtest/fail", "POST", "5xx")
	before_unmatched := counter_of(ROUTE_UNMATCHED, "GET", "4xx")
	before_other := counter_of(ROUTE_UNMATCHED, "other", "4xx")
	hist_ok := metrics.with(http_metrics.request_duration, "/api/v1/mtest/items/*", "GET")
	hist_fail := metrics.with(http_metrics.request_duration, "/api/v1/mtest/fail", "POST")
	hist_ok_before := metrics.histogram_count(hist_ok)
	hist_fail_before := metrics.histogram_count(hist_fail)
	sum_fail_before := hist_fail.sum

	r1 := metrics_test_request(t, &router, "GET /api/v1/mtest/items/abc-123?x=1 HTTP/1.1\r\nHost: h\r\n\r\n")
	defer delete(r1)
	testing.expect(t, strings.has_prefix(r1, "HTTP/1.1 201"), "matched route served")
	r2 := metrics_test_request(t, &router, "POST /api/v1/mtest/fail HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n")
	defer delete(r2)
	testing.expect(t, strings.has_prefix(r2, "HTTP/1.1 503"), "failing route served")
	r3 := metrics_test_request(t, &router, "GET /api/v1/mtest/items/secret/../../etc/passwd HTTP/1.1\r\nHost: h\r\n\r\n")
	defer delete(r3)
	testing.expect(t, strings.has_prefix(r3, "HTTP/1.1 404"), "unmatched -> 404")
	r4 := metrics_test_request(t, &router, "GET /not-api HTTP/1.1\r\nHost: h\r\n\r\n")
	defer delete(r4)
	r5 := metrics_test_request(t, &router, "BREW /api/v1/mtest/coffee HTTP/1.1\r\nHost: h\r\n\r\n")
	defer delete(r5)
	r6 := metrics_test_request(t, &router, "GET /api/v1/mtest/stream HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
	defer delete(r6)
	testing.expect(t, strings.contains(r6, "upgraded"), "upgrade route dispatched")

	testing.expect_value(t, counter_of("/api/v1/mtest/items/*", "GET", "2xx") - before_ok, u64(1))
	testing.expect_value(t, counter_of("/api/v1/mtest/fail", "POST", "5xx") - before_fail, u64(1))
	testing.expect_value(t, counter_of(ROUTE_UNMATCHED, "GET", "4xx") - before_unmatched, u64(2))
	testing.expect_value(t, counter_of(ROUTE_UNMATCHED, "other", "4xx") - before_other, u64(1))
	testing.expect_value(t, metrics.histogram_count(hist_ok) - hist_ok_before, u64(1))
	testing.expect_value(t, metrics.histogram_count(hist_fail) - hist_fail_before, u64(1))
	testing.expect(t, hist_fail.sum - sum_fail_before >= u64(20 * time.Millisecond), "duration covers the handler")
	testing.expect_value(t, metrics.gauge_value(http_metrics.in_flight), i64(0))

	// The raw path must never appear as a route label.
	testing.expect_value(t, metrics.live_series_count(http_metrics.requests_total) > 0, true)
	for s in http_metrics.requests_total.series {
		testing.expect(t, !strings.contains(s.label_values[0], "abc-123") && !strings.contains(s.label_values[0], "passwd") && !strings.contains(s.label_values[0], "stream"),
			"route label is a pattern, not a raw path or an upgrade route")
	}
}

@(test)
test_http_metric_enums :: proc(t: ^testing.T) {
	testing.expect_value(t, http_metric_method("GET"), "GET")
	testing.expect_value(t, http_metric_method("PROPFIND"), "other")
	testing.expect_value(t, http_status_class(204), "2xx")
	testing.expect_value(t, http_status_class(429), "4xx")
	testing.expect_value(t, http_status_class(0), "other")
}
