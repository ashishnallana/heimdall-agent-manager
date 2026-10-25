package http

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"
import metrics "odin_test:lib/metrics"

// Fleet metrics integration test: drives the REAL bridge_ws_upgrade_handler over a
// loopback socket pair (hello -> bridge_ready -> heartbeat -> close) and asserts
// counter deltas and series tombstoning (plan M2 verification).

@(private = "file")
Fleet_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	us_repo:        iface.User_Repository,
	ag_repo:        iface.Agent_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	us_svc:         user_service.User_Service,
	ag_svc:         agent_service.Agent_Service,
	auth_svc:       auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	registry:       project_service.Bridge_Runtime_Registry,
	bh:             Bridge_Handlers,
	owner_user_id:  string,
	bridge_id:      string,
	bridge_token:   string,
}


@(private = "file")
fleet_fixture_setup :: proc(t: ^testing.T) -> ^Fleet_Fixture {
	f := new(Fleet_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc
	f.bh = Bridge_Handlers{auth = &f.auth_svc, bridges = &f.br_svc, agents = &f.ag_svc, bridge_runtime_registry = &f.registry}
	f.user_headers = http_test_login(t, &f.auth_svc, "fleet-owner")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	testing.expect(t, owner_ok, "owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "fleet-box",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)
	return f
}

@(private = "file")
fleet_fixture_teardown :: proc(f: ^Fleet_Fixture) {
	if f == nil do return
	project_service.bridge_runtime_registry_destroy(&f.registry)
	sqlite.close(&f.conn)
	delete(f.owner_user_id)
	delete(f.bridge_id)
	delete(f.bridge_token)
	free(f)
}

@(private = "file")
Fleet_Sock_Pair :: struct {
	listener, client, hub: net.TCP_Socket,
}

@(private = "file")
fleet_sock_pair :: proc(t: ^testing.T) -> Fleet_Sock_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "listen")
	bound, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "dial")
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "accept")
	return Fleet_Sock_Pair{listener = listener, client = client, hub = hub}
}

@(private = "file")
fleet_masked_frame :: proc(opcode: u8, text: string) -> [dynamic]byte {
	mask := [4]byte{0x12, 0x34, 0x56, 0x78}
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x80 | opcode)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n do append(&out, text[i] ~ mask[i % 4])
	return out
}

@(private = "file")
fleet_send_frame :: proc(t: ^testing.T, sock: net.TCP_Socket, opcode: u8, text: string) {
	frame := fleet_masked_frame(opcode, text)
	defer delete(frame)
	_, err := net.send_tcp(sock, frame[:])
	testing.expect(t, err == nil, "frame sent")
}

// fleet_read_until reads server frames until one contains `needle` (or the
// deadline passes). Returns whether it was seen.
@(private = "file")
fleet_read_until :: proc(sock: net.TCP_Socket, needle: string, timeout: time.Duration = 3 * time.Second) -> bool {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	acc := make([dynamic]byte)
	defer delete(acc)
	buf: [8192]byte
	deadline := time.tick_now()
	for time.tick_since(deadline) < timeout {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return false
		append(&acc, ..buf[:n])
		if strings.contains(string(acc[:]), needle) do return true
	}
	return false
}

@(private = "file")
Fleet_Runner :: struct {
	h:    ^Bridge_Handlers,
	req:  Request,
	sock: net.TCP_Socket,
	done: bool,
}

@(private = "file")
fleet_runner_thread :: proc(data: rawptr) {
	r := (^Fleet_Runner)(data)
	bridge_ws_upgrade_handler(rawptr(r.h), r.req, r.sock)
	sync.atomic_store(&r.done, true)
}

@(private = "file")
fleet_connects :: proc(bridge_id, result: string) -> u64 {
	return metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_ws_connects, bridge_id, result))
}

@(test)
test_fleet_metrics_bridge_ws_lifecycle :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	f := fleet_fixture_setup(t)
	defer fleet_fixture_teardown(f)

	connects_ok_before := fleet_connects(f.bridge_id, "ok")
	disconnects_before := metrics.counter_value(metrics.with(m.bridge_ws_disconnects, "clean_close"))
	session_count_before := metrics.histogram_count(m.bridge_session_duration)
	ws_connects_total_before := metrics.counter_value(metrics.with(m.ws_connections_total, project_service.WS_KIND_BRIDGE, "ok"))
	rx_heartbeats_before := metrics.counter_value(metrics.with(m.bridge_ws_frames, "rx", "heartbeat"))
	tx_control_before := metrics.counter_value(metrics.with(m.bridge_ws_frames, "tx", "control"))
	rx_bytes := metrics.with(m.bridge_ws_bytes, f.bridge_id, "rx")
	tx_bytes := metrics.with(m.bridge_ws_bytes, f.bridge_id, "tx")
	rx_bytes_before := metrics.counter_value(rx_bytes)
	tx_bytes_before := metrics.counter_value(tx_bytes)

	pair := fleet_sock_pair(t)
	ws_headers := [2]contracts.HTTP_Header{
		{name = "Authorization", value = fmt.tprintf("Bearer %s", f.bridge_token)},
		{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
	}
	runner := Fleet_Runner{h = &f.bh, req = Request{method = "GET", path = "/api/v1/bridge-ws", headers = ws_headers[:], request_id = "req_fleet", remote_addr = "127.0.0.1:4444"}, sock = pair.hub}
	th := thread.create_and_start_with_data(rawptr(&runner), fleet_runner_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
		net.close(pair.hub)
		net.close(pair.listener)
	}

	testing.expect(t, fleet_read_until(pair.client, "\r\n\r\n"), "101 received")
	hello := fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"fleet-box","os":"linux","arch":"amd64","version":"9.9.9","bridge_id":"{0}","capabilities":{{}}}}`, f.bridge_id)
	fleet_send_frame(t, pair.client, 0x1, hello)
	testing.expect(t, fleet_read_until(pair.client, `"type":"bridge_ready"`), "bridge_ready received")

	// --- connected: info + connects + open gauge ---
	// bridge_metrics_connected runs after bridge_ready is written (it sits at
	// the "fully established" point with the lifecycle log), so poll briefly.
	for i in 0 ..< 200 {
		if metrics.live_series_count(m.bridge_info) > 0 && fleet_connects(f.bridge_id, "ok") > connects_ok_before do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, fleet_connects(f.bridge_id, "ok") - connects_ok_before, u64(1))
	info := metrics.with(m.bridge_info, f.bridge_id, f.owner_user_id, "9.9.9", "linux", "amd64")
	testing.expect_value(t, metrics.gauge_value(info), i64(1))
	testing.expect(t, !metrics.series_is_dead(info), "bridge_info live while connected")
	// The open gauge is fleet-wide and siblings close bridge sockets concurrently,
	// so assert the monotonic counter instead of the gauge delta.
	testing.expect(t, metrics.counter_value(metrics.with(m.ws_connections_total, project_service.WS_KIND_BRIDGE, "ok")) > ws_connects_total_before, "ws_connections_total{bridge,ok} incremented")
	testing.expect(t, metrics.counter_value(tx_bytes) > tx_bytes_before, "tx bytes counted (bridge_ready)")
	testing.expect(t, metrics.counter_value(metrics.with(m.bridge_ws_frames, "tx", "control")) > tx_control_before, "bridge_ready counted as tx control frame")

	// --- heartbeat: timestamp gauge + rx frame kind ---
	hb := metrics.with(m.bridge_last_heartbeat, f.bridge_id)
	hb_before := metrics.gauge_value(hb)
	time.sleep(1100 * time.Millisecond) // the gauge has 1 s resolution
	fleet_send_frame(t, pair.client, 0x1, `{"type":"bridge_heartbeat","active_instance_ids":[],"stats":{"rss":4096,"pty_host_rss":1,"cpu_s":0.5,"instances":[{"provider":"claude","rss":77,"cpu_s":0.1}]}}`)
	testing.expect(t, fleet_read_until(pair.client, `"type":"bridge_heartbeat_ack"`), "heartbeat ack received")
	// M3: resource gauges from the stats object, per bridge.
	rss_series := metrics.with(m.bridge_process_resident, f.bridge_id, "bridge")
	inst_series := metrics.with(m.instance_resident, f.bridge_id, "claude")
	testing.expect_value(t, metrics.gauge_value(rss_series), i64(4096))
	testing.expect_value(t, metrics.gauge_value(inst_series), i64(77))
	testing.expect(t, metrics.gauge_value(hb) > hb_before, "last_heartbeat advanced")
	testing.expect(t, metrics.counter_value(rx_bytes) > rx_bytes_before, "rx bytes counted (heartbeat)")
	testing.expect(t, metrics.gauge_value(hb) > 1_600_000_000, "last_heartbeat is unix seconds")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_ws_frames, "rx", "heartbeat")) - rx_heartbeats_before, u64(1))

	// --- clean close: reason counter, duration, tombstones, gauge back ---
	fleet_send_frame(t, pair.client, 0x8, "")
	net.close(pair.client)
	for i in 0 ..< 300 {
		if sync.atomic_load(&runner.done) do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&runner.done), "handler returned after close")
	// Sibling tests in this package also open/close bridge sockets concurrently
	// (shared process-wide registry), so fleet-wide deltas are lower bounds; the
	// per-bridge series above are exact.
	testing.expect(t, metrics.counter_value(metrics.with(m.bridge_ws_disconnects, "clean_close")) - disconnects_before >= 1, "clean_close counted")
	testing.expect(t, metrics.histogram_count(m.bridge_session_duration) - session_count_before >= 1, "session duration observed")
	testing.expect(t, metrics.series_is_dead(info), "bridge_info tombstoned on disconnect")
	testing.expect(t, metrics.series_is_dead(hb), "last_heartbeat tombstoned on disconnect")
	testing.expect(t, metrics.series_is_dead(rss_series) && metrics.series_is_dead(inst_series), "resource gauges tombstoned on disconnect")
	testing.expect(t, metrics.gauge_value(metrics.with(m.ws_connections, project_service.WS_KIND_BRIDGE)) >= 0, "open gauge never negative")
	// Scrape output must not mention the owner anymore.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	metrics.gather(metrics.global(), &b)
	out := strings.to_string(b)
	needle := fmt.tprintf(`heimdall_bridge_info{{bridge_id="%s"`, f.bridge_id)
	testing.expect(t, !strings.contains(out, needle), "tombstoned bridge_info absent from exposition")
	testing.expect(t, strings.contains(out, `heimdall_bridge_ws_disconnects_total{reason="clean_close"}`), "disconnect reason exposed")
}

@(test)
test_fleet_metrics_auth_failure_is_one_shared_series :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f := fleet_fixture_setup(t)
	defer fleet_fixture_teardown(f)
	before := fleet_connects(BRIDGE_ID_UNKNOWN, "auth_failed")

	pair := fleet_sock_pair(t)
	ws_headers := [2]contracts.HTTP_Header{
		{name = "Authorization", value = "Bearer hbt_definitely_not_a_token"},
		{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
	}
	runner := Fleet_Runner{h = &f.bh, req = Request{method = "GET", path = "/api/v1/bridge-ws", headers = ws_headers[:], request_id = "req_fleet_bad", remote_addr = "127.0.0.1:4444"}, sock = pair.hub}
	th := thread.create_and_start_with_data(rawptr(&runner), fleet_runner_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
		net.close(pair.hub)
		net.close(pair.listener)
	}
	testing.expect(t, fleet_read_until(pair.client, "\r\n\r\n"), "101 received")
	fleet_send_frame(t, pair.client, 0x1, `{"type":"bridge_hello","protocol_version":2,"hostname":"x","os":"linux","arch":"amd64","version":"1"}`)
	testing.expect(t, fleet_read_until(pair.client, `"type":"bridge_error"`), "error frame received")
	net.close(pair.client)
	for i in 0 ..< 300 {
		if sync.atomic_load(&runner.done) do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, fleet_connects(BRIDGE_ID_UNKNOWN, "auth_failed") - before, u64(1))
	// No per-token / per-attempt series were minted.
	for s in project_service.fleet_metrics.bridge_ws_connects.series {
		testing.expect(t, !strings.contains(s.label_values[0], "hbt_"), "token never becomes a label")
	}
}

@(test)
test_fleet_frame_kind_mapping_is_closed :: proc(t: ^testing.T) {
	testing.expect_value(t, project_service.bridge_frame_kind("bridge_heartbeat"), "heartbeat")
	testing.expect_value(t, project_service.bridge_frame_kind("fs_read_file_result"), "fs")
	testing.expect_value(t, project_service.bridge_frame_kind("vcs_commit"), "vcs")
	testing.expect_value(t, project_service.bridge_frame_kind("shell_pty_output"), "shell_pty_output")
	testing.expect_value(t, project_service.bridge_frame_kind("shell_start_result"), "shell")
	testing.expect_value(t, project_service.bridge_frame_kind("bridge_ready"), "control")
	testing.expect_value(t, project_service.bridge_frame_kind("totally_made_up_by_a_peer"), "other")
	testing.expect_value(t, project_service.bridge_frame_kind(""), "other")
	testing.expect_value(t, project_service.bridge_command_error_code("Bridge_Timeout"), "Bridge_Timeout")
	testing.expect_value(t, project_service.bridge_command_error_code("Whatever"), "other")
	_ = domain.Error_Code.None
}
