package app

import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import metrics "odin_test:lib/metrics"
import http "odin_test:hub/transport/http"
import project_service "odin_test:hub/service/project"
import push_service "odin_test:hub/service/push"
import shell_session_svc "odin_test:hub/service/shell_session"
import billing_service "odin_test:hub/service/billing"
import sqlite "odin_test:hub/repository/sqlite"

// Private Prometheus listener (plan 4.2). Deliberately NOT the public server:
//   - its own TCP listener on an operator-chosen loopback address;
//   - one request at a time on one thread (a scrape is cheap, and serialising
//     bounds the exposure of the registry locks);
//   - receive and send timeouts so a stalled scraper cannot pin the thread;
//   - only GET /metrics and GET /healthz; everything else is 404.
// Nothing here uses context.allocator for anything that outlives a request.

METRICS_IO_TIMEOUT :: 5 * time.Second
METRICS_MAX_REQUEST_BYTES :: 8 * 1024

Metrics_Listener :: struct {
	registry: ^metrics.Registry,
	address:  net.IP4_Address,
	port:     int,
}

// init_metrics creates the global registry and registers hub-wide families and
// collectors. Idempotent: tests build many graphs in one process.
init_metrics :: proc() -> ^metrics.Registry {
	reg := metrics.init_global()
	http.http_metrics_init(reg)
	http.auth_metrics_init(reg)
	project_service.fleet_metrics_init(reg)
	shell_session_svc.shell_metrics_init(reg)
	http.streams_metrics_init(reg)
	sqlite.sqlite_metrics_init(reg)
	reaper_metrics_init(reg)
	db_collectors_init(reg)
	push_service.push_metrics_init(reg)
	billing_service.billing_metrics_init(reg)
	metrics.register_process_collector(reg)
	build_info := metrics.new_gauge(reg, "heimdall_hub_build_info", "Hub build information (value is always 1).", {"version", "commit"})
	metrics.gauge_set(metrics.with(build_info, contracts.APP_VERSION, contracts.GIT_COMMIT), 1)
	return reg
}

// start_metrics_listener binds `metrics_addr` and serves it on a new thread.
// Returns false (after logging) if the address is invalid or cannot be bound;
// the hub keeps running without a metrics endpoint in that case.
start_metrics_listener :: proc(reg: ^metrics.Registry, metrics_addr: string) -> bool {
	if metrics_addr == "" do return false
	address, port, ok, message := parse_metrics_addr(metrics_addr)
	if !ok {
		fmt.eprintln("ham-hub metrics listener disabled:", message)
		return false
	}
	listener, err := net.listen_tcp({address, port})
	if err != nil {
		fmt.eprintln("ham-hub metrics listen failed", metrics_addr, err)
		return false
	}
	state := new(Metrics_Listener)
	state^ = Metrics_Listener{registry = reg, address = address, port = port}
	fmt.println("ham-hub metrics listening", metrics_addr)
	// The thread owns `listener` and `state` for the process lifetime.
	thread.run_with_poly_data2(listener, state, serve_metrics_loop)
	return true
}

// serve_metrics_loop accepts and serves scrapes serially. Exported for tests,
// which run it on their own thread against an ephemeral port.
serve_metrics_loop :: proc(listener: net.TCP_Socket, state: ^Metrics_Listener) {
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			time.sleep(10 * time.Millisecond)
			continue
		}
		serve_metrics_client(client, state.registry)
	}
}

// serve_metrics_client handles exactly one request and closes the socket.
serve_metrics_client :: proc(client: net.TCP_Socket, reg: ^metrics.Registry) {
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, METRICS_IO_TIMEOUT)
	_ = net.set_option(client, .Send_Timeout, METRICS_IO_TIMEOUT)

	// Read just the head: these are GETs without bodies.
	buf: [METRICS_MAX_REQUEST_BYTES]byte
	n := 0
	for {
		got, recv_err := net.recv_tcp(client, buf[n:])
		if recv_err != nil || got <= 0 do return
		n += got
		if strings.contains(string(buf[:n]), "\r\n\r\n") do break
		if n >= len(buf) do return
	}
	method, path := metrics_request_line(string(buf[:n]))
	status, content_type, body, body_owned := metrics_respond(reg, method, path)
	defer if body_owned do delete(body)

	head_buf: [256]byte
	head := fmt.bprintf(head_buf[:], "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
		status, http.status_text(status), content_type, len(body))
	if _, send_err := net.send_tcp(client, transmute([]byte)head); send_err != nil do return
	if len(body) > 0 do _, _ = net.send_tcp(client, transmute([]byte)body)
}

// metrics_respond routes the two supported paths. The /metrics body is built on
// the heap (not the registry allocator: it is transient and freed here).
metrics_respond :: proc(reg: ^metrics.Registry, method, path: string) -> (status: int, content_type, body: string, body_owned: bool) {
	if method != "GET" && method != "HEAD" do return 405, "text/plain; charset=utf-8", "method not allowed\n", false
	switch path {
	case "/metrics":
		b := strings.builder_make()
		metrics.gather(reg, &b)
		return 200, metrics.CONTENT_TYPE, strings.to_string(b), true
	case "/healthz":
		return 200, "text/plain; charset=utf-8", "ok\n", false
	}
	return 404, "text/plain; charset=utf-8", "not found\n", false
}

// metrics_request_line extracts method and path (query stripped) from the head.
metrics_request_line :: proc(head: string) -> (method, path: string) {
	line := head
	if end := strings.index(head, "\r\n"); end >= 0 do line = head[:end]
	rest := line
	fields: [3]string
	count := 0
	for field in strings.fields_iterator(&rest) {
		if count >= 3 do break
		fields[count] = field
		count += 1
	}
	if count < 2 do return "", ""
	path = fields[1]
	if q := strings.index_byte(path, '?'); q >= 0 do path = path[:q]
	return fields[0], path
}
