package app

import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"

@(test)
test_parse_metrics_addr :: proc(t: ^testing.T) {
	addr, port, ok, msg := parse_metrics_addr("127.0.0.1:9464")
	testing.expect(t, ok, msg)
	testing.expect_value(t, addr, net.IP4_Loopback)
	testing.expect_value(t, port, 9464)
	for bad in ([]string{"", "9464", "127.0.0.1", "127.0.0.1:", ":9464", "localhost:9464", "127.0.0.1:0", "127.0.0.1:70000", "[::1]:9464"}) {
		_, _, bad_ok, bad_msg := parse_metrics_addr(bad)
		testing.expectf(t, !bad_ok, "expected rejection for %q", bad)
		testing.expect(t, strings.contains(bad_msg, "--metrics-addr"), "message names the flag")
	}
	cfg := default_config()
	defer delete(cfg.forwarded_for_trusted_cidrs)
	testing.expect_value(t, cfg.metrics_addr, "")
}

// The shipped default (HEIMDALL_DB_TELEMETRY unset) boots with basic telemetry
// and registers its families; full/unknown values fail boot without touching
// the mode. (The explicit off override is not exercised here: the mode is
// process-global and other graph tests in this package run in basic.)
@(test)
test_db_telemetry_default_basic :: proc(t: ^testing.T) {
	cfg := default_config()
	defer delete(cfg.forwarded_for_trusted_cidrs)
	testing.expect_value(t, cfg.db_telemetry, "")
	ok, msg := configure_db_telemetry(cfg)
	testing.expect(t, ok, msg)
	testing.expect_value(t, dbt.mode(), dbt.Mode.Basic)
	reg := init_metrics()
	for name in ([]string{"heimdall_db_lock_wait_seconds", "heimdall_db_scope_seconds_total", "heimdall_db_slow_log_dropped_total"}) {
		_, found := reg.by_name[name]
		testing.expectf(t, found, "default basic must register %s", name)
	}
	for bad in ([]string{"full", "on", "BASIC"}) {
		cfg.db_telemetry = bad
		bad_ok, bad_msg := configure_db_telemetry(cfg)
		testing.expectf(t, !bad_ok, "expected boot failure for %q", bad)
		testing.expect(t, strings.contains(bad_msg, "HEIMDALL_DB_TELEMETRY"), "message names the variable")
		testing.expect_value(t, dbt.mode(), dbt.Mode.Basic)
	}
}

@(test)
test_metrics_request_line :: proc(t: ^testing.T) {
	m, p := metrics_request_line("GET /metrics?x=1 HTTP/1.1\r\nHost: a\r\n\r\n")
	testing.expect_value(t, m, "GET")
	testing.expect_value(t, p, "/metrics")
	m, p = metrics_request_line("garbage")
	testing.expect_value(t, m, "")
	testing.expect_value(t, p, "")
}

@(test)
test_metrics_respond_routes :: proc(t: ^testing.T) {
	reg := init_metrics()
	status, ct, body, owned := metrics_respond(reg, "GET", "/metrics")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, ct, metrics.CONTENT_TYPE)
	testing.expect(t, strings.contains(body, "heimdall_hub_build_info{version=\""), "build info present")
	testing.expect(t, strings.contains(body, "# TYPE heimdall_http_in_flight gauge\nheimdall_http_in_flight "), "http family registered")
	if owned do delete(body)
	status, _, body, owned = metrics_respond(reg, "GET", "/healthz")
	testing.expect_value(t, status, 200)
	testing.expect_value(t, body, "ok\n")
	testing.expect(t, !owned, "static body")
	status, _, _, _ = metrics_respond(reg, "GET", "/api/v1/bridges")
	testing.expect_value(t, status, 404)
	status, _, _, _ = metrics_respond(reg, "POST", "/metrics")
	testing.expect_value(t, status, 405)
}

@(private = "file")
Listener_Test_State :: struct {
	listener: net.TCP_Socket,
	state:    Metrics_Listener,
}

@(private = "file")
listener_test_thread :: proc(data: rawptr) {
	s := (^Listener_Test_State)(data)
	// Serve exactly two scrapes then exit so the test can join.
	for _ in 0 ..< 2 {
		client, _, err := net.accept_tcp(s.listener)
		if err != nil do return
		serve_metrics_client(client, s.state.registry)
	}
}

@(private = "file")
listener_test_get :: proc(t: ^testing.T, endpoint: net.Endpoint, path: string) -> string {
	client, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil do testing.fail_now(t, "dial metrics listener")
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
	req := strings.concatenate({"GET ", path, " HTTP/1.1\r\nHost: m\r\n\r\n"})
	defer delete(req)
	_, _ = net.send_tcp(client, transmute([]byte)req)
	b := strings.builder_make()
	buf: [16 * 1024]byte
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n <= 0 do break
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b)
}

// The private listener serves a well-formed 0.0.4 exposition over a real
// socket and 404s everything but /metrics and /healthz.
@(test)
test_metrics_listener_serves_scrape :: proc(t: ^testing.T) {
	reg := init_metrics()
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "listen")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	st := Listener_Test_State{listener = listener, state = Metrics_Listener{registry = reg}}
	worker := thread.create_and_start_with_data(rawptr(&st), listener_test_thread)
	defer { thread.join(worker); thread.destroy(worker) }

	resp := listener_test_get(t, endpoint, "/metrics")
	defer delete(resp)
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"), "200")
	testing.expect(t, strings.contains(resp, "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"), "content type")
	testing.expect(t, strings.contains(resp, "Connection: close\r\n"), "connection close")
	head_end := strings.index(resp, "\r\n\r\n")
	testing.expect(t, head_end > 0, "has body separator")
	body := resp[head_end+4:]
	testing.expect(t, strings.contains(body, "\n# TYPE heimdall_metrics_series gauge\n"), "self metric")
	testing.expect(t, strings.contains(body, "process_start_time_seconds "), "process collector")
	testing.expect(t, strings.has_suffix(body, "\n"), "body ends with newline")
	// Content-Length matches the body exactly.
	cl_idx := strings.index(resp, "Content-Length: ")
	testing.expect(t, cl_idx > 0, "content length header")
	cl_line := resp[cl_idx+len("Content-Length: "):]
	cl_line = cl_line[:strings.index(cl_line, "\r\n")]
	cl, cl_ok := strconv.parse_int(strings.trim_space(cl_line))
	testing.expect(t, cl_ok, "content length parses")
	testing.expect_value(t, cl, len(body))

	other := listener_test_get(t, endpoint, "/api/v1/bridges")
	defer delete(other)
	testing.expect(t, strings.has_prefix(other, "HTTP/1.1 404"), "non-metrics path is 404 on the private listener")
}
