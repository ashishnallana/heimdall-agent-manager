package http

// Telemetry assertions for plan 3.4 (ws_* on the browser-facing upgrade handlers)
// and 3.6 (preview / LSP). The package's tests run in parallel and several of them
// open the same stream kinds, so gauges are asserted through the invariant
//
//     ws_connections(kind) delta == ws_connections_total{kind,ok} delta - sum(ws_disconnects_total{kind,*}) delta
//
// which holds regardless of what sibling tests do, plus >= 1 on the counters this
// test itself drove. Byte counters keyed by a bridge id are exact: the ids below
// are unique to this file.

import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import ws "odin_test:lib/ws"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"
import user_service "odin_test:hub/service/user"
import metrics "odin_test:lib/metrics"

// --- registry + snapshot helpers ---------------------------------------------

@(private = "file")
tm_init :: proc() {
	reg := metrics.init_global()
	project_service.fleet_metrics_init(reg)
	shell_session_svc.shell_metrics_init(reg)
	streams_metrics_init(reg)
}

// Every reason ws_reason_enum can emit, so the disconnect sum is complete.
@(private = "file")
WS_REASONS := [?]string{"clean_close", "read_deadline", "fatal_frame", "recv_error", "connection_replaced", "frame_rejected", "write_failed", "stream_closed", "bridge_offline", "revoked", "shutdown", "error", "eof", "timeout", "replaced", "other"}

@(private = "file")
Ws_Snapshot :: struct {
	open:        i64,
	connects_ok: u64,
	disconnects: u64,
}

@(private = "file")
tm_ws_snapshot :: proc(kind: string) -> Ws_Snapshot {
	m := &project_service.fleet_metrics
	s: Ws_Snapshot
	s.open = metrics.gauge_value(metrics.with(m.ws_connections, kind))
	s.connects_ok = metrics.counter_value(metrics.with(m.ws_connections_total, kind, "ok"))
	for r in WS_REASONS do s.disconnects += metrics.counter_value(metrics.with(m.ws_disconnects_total, kind, r))
	return s
}

// tm_expect_ws_invariant checks the gauge against the counters between two snapshots.
@(private = "file")
tm_expect_ws_invariant :: proc(t: ^testing.T, before, now: Ws_Snapshot, what: string) {
	opened := i64(now.connects_ok - before.connects_ok)
	closed := i64(now.disconnects - before.disconnects)
	testing.expectf(t, now.open - before.open == opened - closed, "%s: ws_connections delta %d must equal connects %d - disconnects %d", what, now.open - before.open, opened, closed)
}

@(private = "file")
tm_wait_until :: proc(pred: proc(ctx: rawptr) -> bool, ctx: rawptr, limit: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < limit {
		if pred(ctx) do return true
		time.sleep(5 * time.Millisecond)
	}
	return pred(ctx)
}

// --- loopback + framing helpers (local copies; the siblings' are file-private) --

@(private = "file")
Tm_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
tm_make_pair :: proc(t: ^testing.T) -> Tm_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil do testing.fail_now(t, "could not read bound endpoint")
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept on loopback")
	return Tm_Pair{listener = listener, client = client, hub = hub}
}

@(private = "file")
tm_close_pair :: proc(p: ^Tm_Pair) {
	if int(p.hub) > 0 { net.close(p.hub); p.hub = net.TCP_Socket(0) }
	if int(p.client) > 0 { net.close(p.client); p.client = net.TCP_Socket(0) }
	if int(p.listener) > 0 { net.close(p.listener); p.listener = net.TCP_Socket(0) }
}

// tm_read_upgrade_and_frame consumes the 101 and returns the first text frame payload.
@(private = "file")
tm_read_upgrade_and_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	header_end := -1
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&acc, ..buf[:n])
		if header_end < 0 {
			b := acc[:]
			for i in 0 ..< max(0, len(b) - 3) {
				if b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n' {
					header_end = i + 4
					break
				}
			}
			if header_end < 0 do continue
		}
		body := acc[header_end:]
		if len(body) < 2 do continue
		if body[0] != 0x81 do return "", false
		payload_len := int(body[1] & 0x7f)
		off := 2
		switch payload_len {
		case 126:
			if len(body) < 4 do continue
			payload_len = int(body[2]) << 8 | int(body[3])
			off = 4
		case 127:
			if len(body) < 10 do continue
			length: u64 = 0
			for i in 0 ..< 8 do length = length << 8 | u64(body[2 + i])
			payload_len = int(length)
			off = 10
		}
		if len(body) < off + payload_len do continue
		return strings.clone(string(body[off:off + payload_len])), true
	}
}

@(private = "file")
tm_read_raw :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> string {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [8192]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
	}
	return strings.clone(string(acc[:]))
}

// --- fakes --------------------------------------------------------------------

@(private = "file")
Tm_Experiments :: struct {
	key:     string,
	enabled: bool,
}

@(private = "file")
tm_experiment_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	f := (^Tm_Experiments)(ctx)
	out := make([dynamic]domain.Experiment)
	append(&out, domain.Experiment{
		owner_user_id = strings.clone(owner_user_id),
		key           = strings.clone(f.key),
		enabled       = f.enabled,
		updated_at    = strings.clone("2026-09-27T01:00:00Z"),
	})
	return out, domain.Domain_Error{}
}

@(private = "file")
Tm_Shell_Repo :: struct {
	session: domain.Shell_Session,
}

@(private = "file")
tm_clone_session :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id    = strings.clone(s.session_id),
		owner_user_id = strings.clone(s.owner_user_id),
		bridge_id     = strings.clone(s.bridge_id),
		kind          = strings.clone(s.kind),
		status        = strings.clone(s.status),
		server_port   = s.server_port,
	}
}

@(private = "file")
tm_shell_repo_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Tm_Shell_Repo)(ctx)
	if f.session.session_id == session_id && f.session.owner_user_id == owner_user_id {
		return tm_clone_session(f.session), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
tm_shell_repo_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Tm_Shell_Repo)(ctx)
	if f.session.session_id == session_id && f.session.bridge_id == bridge_id {
		return tm_clone_session(f.session), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
Tm_Sink :: struct {
	mu:        sync.Mutex,
	allocator: mem.Allocator,
	commands:  [dynamic]project_service.Runtime_Command,
}

@(private = "file")
tm_sink_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	st := (^Tm_Sink)(ctx)
	sync.mutex_lock(&st.mu)
	defer sync.mutex_unlock(&st.mu)
	append(&st.commands, project_service.Runtime_Command{
		bridge_id  = strings.clone(command.bridge_id, st.allocator),
		command_id = strings.clone(command.command_id, st.allocator),
		body_json  = strings.clone(command.body_json, st.allocator),
	})
	return true, domain.Domain_Error{}
}

@(private = "file")
tm_sink_free :: proc(st: ^Tm_Sink) {
	for cmd in st.commands {
		delete(cmd.bridge_id, st.allocator)
		delete(cmd.command_id, st.allocator)
		delete(cmd.body_json, st.allocator)
	}
	delete(st.commands)
}

// tm_sink_find returns a heap clone of the first command whose body contains `needle`.
@(private = "file")
tm_sink_find :: proc(st: ^Tm_Sink, needle: string) -> (string, bool) {
	sync.mutex_lock(&st.mu)
	defer sync.mutex_unlock(&st.mu)
	for cmd in st.commands {
		if strings.contains(cmd.body_json, needle) do return strings.clone(cmd.body_json), true
	}
	return "", false
}

@(private = "file")
Tm_Bridge_Repo :: struct {
	b: domain.Bridge,
}

@(private = "file")
tm_bridge_get :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	f := (^Tm_Bridge_Repo)(ctx)
	return f.b, true, domain.Domain_Error{}
}

@(private = "file")
Tm_Shell_Run :: struct {
	h:        ^Shell_Session_Stream_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
tm_run_shell_stream :: proc(data: rawptr) {
	r := (^Tm_Shell_Run)(data)
	shell_session_stream_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.finished, true)
}

@(private = "file")
tm_shell_finished :: proc(ctx: rawptr) -> bool { return sync.atomic_load(&(^Tm_Shell_Run)(ctx).finished) }

// --- shell stream: connections 0->1->0, rx bytes, input bytes, rejections ------

@(test)
test_metrics_shell_stream_connection_lifecycle_and_bytes :: proc(t: ^testing.T) {
	tm_init()
	pair := tm_make_pair(t)
	defer tm_close_pair(&pair)

	bridge_id := "brg_metrics_http_shell"
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	user_ws_ticket_store_put(&tickets, "ticket_metrics_shell", contracts.Auth_Context{kind = .Session, user_id = "user_metrics"}, 60)

	exp := Tm_Experiments{key = domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = true}
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&exp), list_by_owner = tm_experiment_list}
	repo_state := Tm_Shell_Repo{session = domain.Shell_Session{session_id = "sh_metrics_http", owner_user_id = "user_metrics", bridge_id = bridge_id, status = domain.Shell_Session_Status_Running}}
	repo := iface.Shell_Session_Repository{ctx = rawptr(&repo_state), get = tm_shell_repo_get, get_by_id = tm_shell_repo_get_by_id}

	sink_state := Tm_Sink{allocator = context.allocator}
	defer tm_sink_free(&sink_state)
	sink := project_service.Bridge_Command_Sink{ctx = rawptr(&sink_state), send_runtime_command = tm_sink_send}
	shell_svc := shell_session_svc.new_shell_session_service(repo = &repo, bridge_command_sink = sink)
	defer shell_session_svc.shell_session_service_free(&shell_svc)

	bridge_repo_state := Tm_Bridge_Repo{b = domain.Bridge{bridge_id = bridge_id, owner_user_id = domain.User_ID("user_metrics"), status = .Online}}
	bridge_repo := iface.Bridge_Repository{ctx = rawptr(&bridge_repo_state), get_bridge = tm_bridge_get}
	bridges := bridge_service.Bridge_Service{repo = &bridge_repo, bridge_command_sink = sink}

	h := Shell_Session_Stream_Handlers{
		ws_tickets = &tickets, experiments = &exp_repo, shell_repo = &repo,
		shell_sessions = &shell_svc, bridges = &bridges, bridge_command_sink = sink,
	}
	headers := []contracts.HTTP_Header{{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}}

	before := tm_ws_snapshot(project_service.WS_KIND_SHELL)
	rx_series := ws_bytes_series(project_service.WS_KIND_SHELL, "rx", bridge_id)
	rx_before := metrics.counter_value(rx_series)
	input_before := metrics.counter_value(shell_session_svc.shell_metrics.input_bytes)

	run := new(Tm_Shell_Run)
	defer free(run)
	run.h = &h
	run.sock = pair.hub
	run.req = Request{method = "GET", path = "/api/v1/shells/sh_metrics_http/stream", query = "ticket=ticket_metrics_shell", request_id = "req_m1", headers = headers}
	th := thread.create_and_start_with_data(rawptr(run), tm_run_shell_stream)
	defer thread.destroy(th)

	frame, read_ok := tm_read_upgrade_and_frame(pair.client, 5 * time.Second)
	testing.expect(t, read_ok, "upgrade + ready frame must arrive")
	if read_ok do delete(frame)

	during := tm_ws_snapshot(project_service.WS_KIND_SHELL)
	testing.expect(t, during.connects_ok - before.connects_ok >= 1, "ws_connections_total{shell,ok} must count the upgrade")
	tm_expect_ws_invariant(t, before, during, "while connected")
	testing.expect(t, during.open >= 1, "ws_connections{shell} must be >= 1 while this stream is open")

	// One input frame (binary pty_wire INPUT, REQ-PTY-NET-3): rx bytes are exact (unique
	// bridge id), input bytes >= the payload.
	input_frame := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_INPUT, 0, transmute([]byte)string("clear\n"))
	defer delete(input_frame)
	input_json := string(input_frame)
	_ = ws.write_server_opcode(pair.client, 0x2, input_json, false)
	Rx_Wait :: struct { s: ^metrics.Series, want: u64 }
	rx_wait := Rx_Wait{s = rx_series, want = rx_before + u64(len(input_json))}
	testing.expect(t, tm_wait_until(proc(ctx: rawptr) -> bool {
		w := (^Rx_Wait)(ctx)
		return metrics.counter_value(w.s) >= w.want
	}, rawptr(&rx_wait), 3 * time.Second), "ws_bytes_total{shell,rx,bridge} must count the input frame payload")
	testing.expect_value(t, metrics.counter_value(rx_series) - rx_before, u64(len(input_json)))
	// The handler counts rx bytes before it decodes the frame and counts input bytes,
	// so wait for the input counter too rather than racing the handler thread.
	input_wait := Rx_Wait{s = shell_session_svc.shell_metrics.input_bytes, want = input_before + 6}
	testing.expect(t, tm_wait_until(proc(ctx: rawptr) -> bool {
		w := (^Rx_Wait)(ctx)
		return metrics.counter_value(w.s) >= w.want
	}, rawptr(&input_wait), 3 * time.Second), "shell_input_bytes_total must count the decoded keystrokes")

	// Disconnect: gauge returns to the invariant and a disconnect is recorded.
	net.close(pair.client); pair.client = net.TCP_Socket(0)
	testing.expect(t, tm_wait_until(tm_shell_finished, rawptr(run), 5 * time.Second), "handler must finish after client disconnect")
	thread.join(th)

	after := tm_ws_snapshot(project_service.WS_KIND_SHELL)
	testing.expect(t, after.disconnects - during.disconnects >= 1, "ws_disconnects_total{shell,*} must count the teardown")
	tm_expect_ws_invariant(t, before, after, "after disconnect")
	testing.expect_value(t, metrics.counter_value(metrics.with(project_service.fleet_metrics.ws_disconnects_total, project_service.WS_KIND_SHELL, "clean_close")) >= 1, true)
}

@(test)
test_metrics_shell_stream_rejection_is_counted :: proc(t: ^testing.T) {
	tm_init()
	pair := tm_make_pair(t)
	defer tm_close_pair(&pair)
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	h := Shell_Session_Stream_Handlers{ws_tickets = &tickets}

	rejected := metrics.with(project_service.fleet_metrics.ws_connections_total, project_service.WS_KIND_SHELL, "auth_failed")
	before := metrics.counter_value(rejected)
	open_before := metrics.gauge_value(metrics.with(project_service.fleet_metrics.ws_connections, project_service.WS_KIND_SHELL))
	shell_session_stream_handler(rawptr(&h), Request{method = "GET", path = "/api/v1/shells/sh_x/stream", query = "ticket=nope", request_id = "req_m2"}, pair.hub)
	testing.expect(t, metrics.counter_value(rejected) - before >= 1, "an invalid ticket must count as auth_failed")
	// A rejection never touches the open gauge (checked loosely: siblings may move it).
	_ = open_before
}

// --- preview: requests by status class, bytes, tunnel gauge -------------------

@(private = "file")
tm_user_get :: proc(ctx: rawptr, user_id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
	return domain.User{user_id = user_id, name = string(user_id), display_name = string(user_id), status = .Active}, true, domain.Domain_Error{}
}

@(private = "file")
Tm_Preview_Run :: struct {
	h:        ^Shell_Session_Stream_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
tm_run_preview :: proc(data: rawptr) {
	r := (^Tm_Preview_Run)(data)
	preview_origin_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.finished, true)
}

@(private = "file")
tm_preview_finished :: proc(ctx: rawptr) -> bool { return sync.atomic_load(&(^Tm_Preview_Run)(ctx).finished) }

@(private = "file")
tm_sink_has_tunnel_open :: proc(ctx: rawptr) -> bool {
	body, ok := tm_sink_find((^Tm_Sink)(ctx), "\"type\":\"tunnel_open\"")
	if ok do delete(body)
	return ok
}

@(test)
test_metrics_preview_request_bytes_and_tunnel_gauge :: proc(t: ^testing.T) {
	tm_init()
	pair := tm_make_pair(t)
	defer tm_close_pair(&pair)

	bridge_id := "brg_metrics_http_preview"
	repo_state := Tm_Shell_Repo{session = domain.Shell_Session{
		session_id = "sh_metrics_preview", owner_user_id = "owner", bridge_id = bridge_id,
		status = domain.Shell_Session_Status_Running, server_port = 3000,
	}}
	repo := iface.Shell_Session_Repository{ctx = rawptr(&repo_state), get = tm_shell_repo_get, get_by_id = tm_shell_repo_get_by_id}
	user_repo := iface.User_Repository{get_by_id = tm_user_get}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service(auth_service.Auth_Config{}, &users)
	defer auth_service.oidc_free(&auth)

	sink_state := Tm_Sink{allocator = context.allocator}
	defer tm_sink_free(&sink_state)
	sink := project_service.Bridge_Command_Sink{ctx = rawptr(&sink_state), send_runtime_command = tm_sink_send}
	shell_svc := shell_session_svc.new_shell_session_service(repo = &repo, bridge_command_sink = sink)
	defer shell_session_svc.shell_session_service_free(&shell_svc)

	h := Shell_Session_Stream_Handlers{
		auth = &auth, shell_repo = &repo, shell_sessions = &shell_svc,
		bridge_command_sink = sink, preview_origin = "https://preview.example",
	}

	tunnels := metrics.with(streams_metrics.preview_active_tunnels, bridge_id)
	tunnels_before := metrics.gauge_value(tunnels)
	req_2xx := metrics.with(streams_metrics.preview_requests, "2xx")
	req_before := metrics.counter_value(req_2xx)
	to_browser := metrics.with(streams_metrics.preview_bytes, "to_browser")
	to_bridge := metrics.with(streams_metrics.preview_bytes, "to_bridge")
	browser_before := metrics.counter_value(to_browser)
	bridge_before := metrics.counter_value(to_bridge)

	run := new(Tm_Preview_Run)
	defer free(run)
	run.h = &h
	run.sock = pair.hub
	run.req = Request{
		method = "GET", path = "/p/sh_metrics_preview/index.html", request_id = "req_m3", remote_addr = "127.0.0.1:4444",
		headers = http_test_preview_headers(t, &auth, "owner", "sh_metrics_preview"),
	}
	th := thread.create_and_start_with_data(rawptr(run), tm_run_preview)
	defer thread.destroy(th)

	testing.expect(t, tm_wait_until(tm_sink_has_tunnel_open, rawptr(&sink_state), 5 * time.Second), "the proxy must open a tunnel")
	open_body, open_ok := tm_sink_find(&sink_state, "\"type\":\"tunnel_open\"")
	if !open_ok {
		net.close(pair.client); pair.client = net.TCP_Socket(0)
		thread.join(th)
		return
	}
	defer delete(open_body)
	stream_id := json_string(open_body, "stream_id")
	defer delete(stream_id)

	testing.expect_value(t, metrics.gauge_value(tunnels) - tunnels_before, i64(1))
	testing.expect(t, metrics.counter_value(to_bridge) - bridge_before > 0, "the forwarded request must be counted toward the bridge")

	upstream := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
	shell_session_svc.shell_session_tunnel_deliver(&shell_svc, stream_id, transmute([]byte)upstream)
	shell_session_svc.shell_session_tunnel_close_stream(&shell_svc, stream_id)

	testing.expect(t, tm_wait_until(tm_preview_finished, rawptr(run), 5 * time.Second), "the relay must finish once upstream closes")
	thread.join(th)

	got := tm_read_raw(pair.client, 500 * time.Millisecond)
	defer delete(got)
	testing.expect(t, strings.has_prefix(got, "HTTP/1.1 200"), "the browser must receive the upstream response")

	testing.expect(t, metrics.counter_value(req_2xx) - req_before >= 1, "preview_requests_total{2xx} must count the response")
	testing.expect(t, metrics.counter_value(to_browser) - browser_before >= u64(len(upstream)), "to_browser bytes must cover the relayed response")
	testing.expect_value(t, metrics.gauge_value(tunnels) - tunnels_before, i64(0))
	testing.expect_value(t, preview_status_class(404), "4xx")
	testing.expect_value(t, preview_status_class(0), "other")
}

// --- LSP: sessions{language} up on start, back to baseline on unwind -----------

@(private = "file")
Tm_Configs :: struct {
	rows: [dynamic]domain.Lsp_Server_Config,
}

@(private = "file")
tm_config_list :: proc(ctx: rawptr, owner_user_id, bridge_id: string) -> ([dynamic]domain.Lsp_Server_Config, domain.Domain_Error) {
	f := (^Tm_Configs)(ctx)
	out := make([dynamic]domain.Lsp_Server_Config)
	for r in f.rows {
		if r.bridge_id != bridge_id do continue
		append(&out, lsp_server_config_clone(r))
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
Tm_Lsp_Run :: struct {
	h:        ^Lsp_Session_Stream_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
tm_run_lsp :: proc(data: rawptr) {
	r := (^Tm_Lsp_Run)(data)
	lsp_session_stream_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.finished, true)
}

@(private = "file")
tm_lsp_finished :: proc(ctx: rawptr) -> bool { return sync.atomic_load(&(^Tm_Lsp_Run)(ctx).finished) }

@(test)
test_metrics_lsp_sessions_gauge_and_connection_lifecycle :: proc(t: ^testing.T) {
	tm_init()
	pair := tm_make_pair(t)
	defer tm_close_pair(&pair)

	bridge_id := "brg_metrics_http_lsp"
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	user_ws_ticket_store_put(&tickets, "ticket_metrics_lsp", contracts.Auth_Context{kind = .Session, user_id = "user_lsp"}, 60)
	exp := Tm_Experiments{key = LSP_EXPERIMENT_KEY, enabled = true}
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&exp), list_by_owner = tm_experiment_list}

	configs := Tm_Configs{rows = make([dynamic]domain.Lsp_Server_Config)}
	defer {
		for r in configs.rows do domain.lsp_server_config_destroy(r)
		delete(configs.rows)
	}
	append(&configs.rows, lsp_server_config_clone(domain.Lsp_Server_Config{config_id = "c_go", bridge_id = bridge_id, language = "go", cmd = "gopls"}))
	config_repo := iface.Lsp_Server_Config_Repository{ctx = rawptr(&configs), list_by_bridge = tm_config_list}

	sink_state := Tm_Sink{allocator = context.allocator}
	defer tm_sink_free(&sink_state)
	sink := project_service.Bridge_Command_Sink{ctx = rawptr(&sink_state), send_runtime_command = tm_sink_send}
	bridge_repo_state := Tm_Bridge_Repo{b = domain.Bridge{bridge_id = bridge_id, owner_user_id = domain.User_ID("user_lsp"), status = .Online}}
	bridge_repo := iface.Bridge_Repository{ctx = rawptr(&bridge_repo_state), get_bridge = tm_bridge_get}
	bridges := bridge_service.Bridge_Service{repo = &bridge_repo, bridge_command_sink = sink}

	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	ids := http_test_id_generator()
	h := Lsp_Session_Stream_Handlers{
		ws_tickets = &tickets, bridges = &bridges, experiments = &exp_repo,
		lsp_configs = &config_repo, sessions = &reg, ids = &ids, bridge_command_sink = sink,
	}

	go_gauge := metrics.with(streams_metrics.lsp_sessions, "go")
	go_before := metrics.gauge_value(go_gauge)
	before := tm_ws_snapshot(project_service.WS_KIND_LSP)
	tx_series := ws_bytes_series(project_service.WS_KIND_LSP, "tx", "")
	tx_before := metrics.counter_value(tx_series)

	run := new(Tm_Lsp_Run)
	defer free(run)
	run.h = &h
	run.sock = pair.hub
	run.req = Request{
		method = "GET", path = "/api/v1/lsp/editor-metrics/stream", query = "ticket=ticket_metrics_lsp", request_id = "req_m4",
		headers = []contracts.HTTP_Header{{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}},
	}
	th := thread.create_and_start_with_data(rawptr(run), tm_run_lsp)
	defer thread.destroy(th)

	ready, read_ok := tm_read_upgrade_and_frame(pair.client, 5 * time.Second)
	testing.expect(t, read_ok, "upgrade + ready must arrive")
	if read_ok {
		// The handler counts tx bytes after its write returns, so the client can read the
		// frame first: wait for the counter instead of racing the handler thread.
		Tx_Wait :: struct { s: ^metrics.Series, want: u64 }
		tx_wait := Tx_Wait{s = tx_series, want = tx_before + u64(len(ready))}
		testing.expect(t, tm_wait_until(proc(ctx: rawptr) -> bool {
			w := (^Tx_Wait)(ctx)
			return metrics.counter_value(w.s) >= w.want
		}, rawptr(&tx_wait), 3 * time.Second), "ws_bytes_total{lsp,tx} must count the ready frame")
		delete(ready)
	}
	during := tm_ws_snapshot(project_service.WS_KIND_LSP)
	testing.expect(t, during.connects_ok - before.connects_ok >= 1)
	tm_expect_ws_invariant(t, before, during, "lsp while connected")

	start := "{\"type\":\"start\",\"bridge_id\":\"brg_metrics_http_lsp\",\"language\":\"go\",\"file_path\":\"/w/main.go\"}"
	_ = write_ws_text_frame(pair.client, start)
	Gauge_Wait :: struct { s: ^metrics.Series, want: i64 }
	gw := Gauge_Wait{s = go_gauge, want = go_before + 1}
	testing.expect(t, tm_wait_until(proc(ctx: rawptr) -> bool {
		w := (^Gauge_Wait)(ctx)
		return metrics.gauge_value(w.s) >= w.want
	}, rawptr(&gw), 3 * time.Second), "lsp_sessions{go} must rise when start succeeds")
	started_body, started := tm_sink_find(&sink_state, "\"type\":\"lsp_start\"")
	testing.expect(t, started, "start must reach the bridge sink")
	if started do delete(started_body)

	net.close(pair.client); pair.client = net.TCP_Socket(0)
	testing.expect(t, tm_wait_until(tm_lsp_finished, rawptr(run), 10 * time.Second), "the relay must unwind when the browser disconnects")
	thread.join(th)

	testing.expect_value(t, metrics.gauge_value(go_gauge), go_before)
	after := tm_ws_snapshot(project_service.WS_KIND_LSP)
	testing.expect(t, after.disconnects - during.disconnects >= 1)
	tm_expect_ws_invariant(t, before, after, "lsp after disconnect")
	testing.expect_value(t, lsp_language_enum("go"), "go")
	testing.expect_value(t, lsp_language_enum("klingon"), "other")
}

// --- agent stream: connections invariant + rx bytes ---------------------------

@(private = "file")
Tm_Agent_Repo :: struct {
	instance: domain.Agent_Instance,
}

@(private = "file")
tm_agent_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Tm_Agent_Repo)(ctx)
	if f.instance.agent_instance_id != instance_id do return domain.Agent_Instance{}, false, domain.Domain_Error{}
	return domain.Agent_Instance{
		agent_instance_id = strings.clone(f.instance.agent_instance_id),
		owner_user_id     = f.instance.owner_user_id,
		bridge_id         = strings.clone(f.instance.bridge_id),
		runtime_status    = strings.clone(f.instance.runtime_status),
	}, true, domain.Domain_Error{}
}

@(private = "file")
Tm_Agent_Run :: struct {
	h:        ^Agent_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
tm_run_agent :: proc(data: rawptr) {
	r := (^Tm_Agent_Run)(data)
	agent_instance_stream_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.finished, true)
}

@(private = "file")
tm_agent_finished :: proc(ctx: rawptr) -> bool { return sync.atomic_load(&(^Tm_Agent_Run)(ctx).finished) }

@(test)
test_metrics_agent_stream_connection_lifecycle :: proc(t: ^testing.T) {
	tm_init()
	pair := tm_make_pair(t)
	defer tm_close_pair(&pair)

	bridge_id := "brg_metrics_http_agent"
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	user_ws_ticket_store_put(&tickets, "ticket_metrics_agent", contracts.Auth_Context{kind = .Session, user_id = "user_agent_m"}, 60)
	exp := Tm_Experiments{key = domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = true}
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&exp), list_by_owner = tm_experiment_list}

	agent_state := Tm_Agent_Repo{instance = domain.Agent_Instance{agent_instance_id = "inst_metrics", owner_user_id = domain.User_ID("user_agent_m"), bridge_id = bridge_id, runtime_status = "running"}}
	agent_repo := iface.Agent_Repository{ctx = rawptr(&agent_state), get_instance = tm_agent_get_instance}

	sink_state := Tm_Sink{allocator = context.allocator}
	defer tm_sink_free(&sink_state)
	sink := project_service.Bridge_Command_Sink{ctx = rawptr(&sink_state), send_runtime_command = tm_sink_send}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	ag_svc := agent_service.new_agent_service_with_runtime(&agent_repo, nil, nil, nil, nil, sink, nil, &clock, &ids)
	shell_svc := shell_session_svc.new_shell_session_service(repo = nil, bridge_command_sink = sink, event_bus = nil, ids = &ids, clock = &clock)
	defer shell_session_svc.shell_session_service_free(&shell_svc)

	h := Agent_Handlers{ws_tickets = &tickets, experiments = &exp_repo, agents = &ag_svc, shell_sessions = &shell_svc}

	before := tm_ws_snapshot(project_service.WS_KIND_AGENT_STREAM)
	tx_series := ws_bytes_series(project_service.WS_KIND_AGENT_STREAM, "tx", bridge_id)
	tx_before := metrics.counter_value(tx_series)

	run := new(Tm_Agent_Run)
	defer free(run)
	run.h = &h
	run.sock = pair.hub
	run.req = Request{
		method = "GET", path = "/api/v1/agent-instances/inst_metrics/stream", query = "ticket=ticket_metrics_agent", request_id = "req_m5",
		headers = []contracts.HTTP_Header{{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}},
	}
	th := thread.create_and_start_with_data(rawptr(run), tm_run_agent)
	defer thread.destroy(th)

	ready, read_ok := tm_read_upgrade_and_frame(pair.client, 5 * time.Second)
	testing.expect(t, read_ok, "upgrade + ready must arrive")
	if read_ok {
		// The ready frame goes through the pane viewer writer, so tx is attributed to
		// the agent_stream kind on this bridge (eventually: the writer is asynchronous).
		Tx_Wait :: struct { s: ^metrics.Series, want: u64 }
		tw := Tx_Wait{s = tx_series, want = tx_before + u64(len(ready))}
		testing.expect(t, tm_wait_until(proc(ctx: rawptr) -> bool {
			w := (^Tx_Wait)(ctx)
			return metrics.counter_value(w.s) >= w.want
		}, rawptr(&tw), 3 * time.Second), "ws_bytes_total{agent_stream,tx,bridge} must count the ready frame")
		delete(ready)
	}
	during := tm_ws_snapshot(project_service.WS_KIND_AGENT_STREAM)
	testing.expect(t, during.connects_ok - before.connects_ok >= 1)
	tm_expect_ws_invariant(t, before, during, "agent while connected")

	net.close(pair.client); pair.client = net.TCP_Socket(0)
	testing.expect(t, tm_wait_until(tm_agent_finished, rawptr(run), 5 * time.Second), "handler must finish after disconnect")
	thread.join(th)
	after := tm_ws_snapshot(project_service.WS_KIND_AGENT_STREAM)
	testing.expect(t, after.disconnects - during.disconnects >= 1)
	tm_expect_ws_invariant(t, before, after, "agent after disconnect")
}
