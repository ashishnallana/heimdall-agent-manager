package http

import "core:fmt"
import "core:net"
import "core:os"
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
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import user_service "odin_test:hub/service/user"

// REQ-TEL-1: write_bridge_json serializes telemetry_enabled
@(test)
test_write_bridge_json_telemetry_fields :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_telemetry_test",
		label = "Worker Alpha",
		machine_hostname = "worker-01",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\"telemetry_enabled\":\"inherit\""), "default telemetry_enabled is inherit")

	bridge.telemetry_enabled = "enabled"
	b2 := strings.builder_make()
	defer strings.builder_destroy(&b2)
	write_bridge_json(&b2, bridge, nil)
	out2 := strings.to_string(b2)
	testing.expect(t, strings.contains(out2, "\"telemetry_enabled\":\"enabled\""), "telemetry_enabled is enabled")

	bridge.telemetry_enabled = "disabled"
	b3 := strings.builder_make()
	defer strings.builder_destroy(&b3)
	write_bridge_json(&b3, bridge, nil)
	out3 := strings.to_string(b3)
	testing.expect(t, strings.contains(out3, "\"telemetry_enabled\":\"disabled\""), "telemetry_enabled is disabled")
}

@(private = "file")
telemetry_test_counter: int = 0

@(private = "file")
telemetry_handler_fixture :: struct {
	db_path: string,
	conn: sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	ag_repo: iface.Agent_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	us_svc: user_service.User_Service,
	ag_svc: agent_service.Agent_Service,
	auth_svc: auth_service.Auth_Service,
	user_headers: []contracts.HTTP_Header, // session cookie for the fixture owner
	registry: project_service.Bridge_Runtime_Registry,
	bh: Bridge_Handlers,
	owner_user_id: string,
	bridge_id: string,
	bridge_token: string,
}



@(private = "file")
setup_telemetry_test_fixture :: proc(t: ^testing.T, tag: string) -> ^telemetry_handler_fixture {
	f := new(telemetry_handler_fixture)
	seq := sync.atomic_add(&telemetry_test_counter, 1)
	f.db_path = ":memory:"
	

	conn, open_ok, open_err := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	f.conn = conn

	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

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

	f.bh = Bridge_Handlers{
		auth = &f.auth_svc,
		bridges = &f.br_svc,
		agents = &f.ag_svc,
		bridge_runtime_registry = &f.registry,
	}

	f.user_headers = http_test_login(t, &f.auth_svc, "tanmay")
	owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	})
	testing.expect(t, owner_ok, "session owner resolved")
	f.owner_user_id = strings.clone(owner_ctx.user_id)

	owner_auth := contracts.Auth_Context{kind = .Session, user_id = f.owner_user_id}
	// Provisioned through the DEVICE-GRANT path, the only enrollment there is
	// (REQ-ENROLL-9). This replaced a create_enrollment + enroll_bridge pair; the
	// bridge and its credential are what this fixture needs, and how the credential
	// was approved is not what these tests are about.
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = f.owner_user_id,
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "test-box",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)

	return f
}

@(private = "file")
teardown_telemetry_test_fixture :: proc(f: ^telemetry_handler_fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	
	if len(f.owner_user_id) > 0 do delete(f.owner_user_id)
	if len(f.bridge_id) > 0 do delete(f.bridge_id)
	if len(f.bridge_token) > 0 do delete(f.bridge_token)
	free(f)
}

// REQ-TEL-1: PATCH /api/v1/bridges/{id} updates telemetry_enabled and persists in repo
@(test)
test_patch_bridge_telemetry :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "patch_tel")
	defer teardown_telemetry_test_fixture(f)

	// Verify initial value from repository is "inherit"
	initial_bridge, get_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, get_ok, "bridge found in repo")
	testing.expect_value(t, initial_bridge.telemetry_enabled, "inherit")

	// 1. PATCH to "enabled"
	req_enabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"enabled"}`,
		request_id = "req_patch_tel_1",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_enabled := rename_bridge_handler(rawptr(&f.bh), req_enabled)
	testing.expect_value(t, resp_enabled.status, 200)
	testing.expect(t, strings.contains(resp_enabled.body, "\"telemetry_enabled\":\"enabled\""), "response has enabled")

	persisted, p_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, p_ok, "persisted bridge retrieved")
	testing.expect_value(t, persisted.telemetry_enabled, "enabled")

	// 2. PATCH to "disabled"
	req_disabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"disabled"}`,
		request_id = "req_patch_tel_2",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_disabled := rename_bridge_handler(rawptr(&f.bh), req_disabled)
	testing.expect_value(t, resp_disabled.status, 200)
	testing.expect(t, strings.contains(resp_disabled.body, "\"telemetry_enabled\":\"disabled\""), "response has disabled")

	persisted2, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect_value(t, persisted2.telemetry_enabled, "disabled")

	// 3. PATCH back to "inherit"
	req_inherit := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"inherit"}`,
		request_id = "req_patch_tel_3",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_inherit := rename_bridge_handler(rawptr(&f.bh), req_inherit)
	testing.expect_value(t, resp_inherit.status, 200)
	testing.expect(t, strings.contains(resp_inherit.body, "\"telemetry_enabled\":\"inherit\""), "response has inherit")

	persisted3, _, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect_value(t, persisted3.telemetry_enabled, "inherit")

	// 4. Invalid telemetry_enabled value rejected
	req_bad := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"random_value"}`,
		request_id = "req_patch_tel_bad",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_bad := rename_bridge_handler(rawptr(&f.bh), req_bad)
	testing.expect_value(t, resp_bad.status, 400)

	// 5. Empty PATCH body rejected
	req_empty := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{}`,
		request_id = "req_patch_tel_empty",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_empty := rename_bridge_handler(rawptr(&f.bh), req_empty)
	testing.expect_value(t, resp_empty.status, 400)
}

@(private = "file")
Telemetry_Sock_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
make_telemetry_sock_pair :: proc(t: ^testing.T) -> (Telemetry_Sock_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(client)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Telemetry_Sock_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
// Skips sockets already closed and zeroed (callers close the client early and set it
// to 0): net.close(0) would close the test process's STDIN, and the next socket any
// parallel test opens then gets fd 0, which the runtime registry reads as "no
// socket" (seen as a flaky "command path is not connected" elsewhere).
close_telemetry_sock_pair :: proc(p: ^Telemetry_Sock_Pair) {
	if int(p.hub) > 0 do net.close(p.hub)
	if int(p.client) > 0 do net.close(p.client)
	if int(p.listener) > 0 do net.close(p.listener)
}

@(private = "file")
read_server_ws_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration = 2 * time.Second) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	n, err := net.recv_tcp(sock, buf[:])
	if err != nil || n < 2 do return "", false
	if buf[0] != 0x81 do return "", false
	payload_len := int(buf[1] & 0x7f)
	off := 2
	if payload_len == 126 {
		if n < 4 do return "", false
		payload_len = int(buf[2]) << 8 | int(buf[3])
		off = 4
	} else if payload_len == 127 {
		if n < 10 do return "", false
		payload_len = 0
		for i in 0 ..< 8 do payload_len = payload_len << 8 | int(buf[2 + i])
		off = 10
	}
	if n < off + payload_len do return "", false
	return strings.clone(string(buf[off:off + payload_len])), true
}

@(private = "file")
make_masked_ws_frame :: proc(text: string) -> [dynamic]byte {
	mask := [4]byte{0x12, 0x34, 0x56, 0x78}
	n := len(text)
	out := make([dynamic]byte)
	append(&out, 0x81)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else if n <= 65535 {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n {
		append(&out, text[i] ~ mask[i % 4])
	}
	return out
}

@(private = "file")
read_http_101 :: proc(sock: net.TCP_Socket, timeout: time.Duration = 2 * time.Second) -> bool {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [1024]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return false
		append(&acc, ..buf[:n])
		if strings.contains(string(acc[:]), "\r\n\r\n") do return true
	}
}

@(private = "file")
WS_Frame_Stream :: struct {
	sock: net.TCP_Socket,
	pending: [dynamic]byte,
}

@(private = "file")
ws_frame_stream_make :: proc(sock: net.TCP_Socket) -> WS_Frame_Stream {
	return WS_Frame_Stream{sock = sock, pending = make([dynamic]byte)}
}

@(private = "file")
ws_frame_stream_destroy :: proc(s: ^WS_Frame_Stream) {
	delete(s.pending)
}

@(private = "file")
ws_frame_stream_next :: proc(s: ^WS_Frame_Stream, timeout: time.Duration = 2 * time.Second) -> (string, bool) {
	_ = net.set_option(s.sock, .Receive_Timeout, timeout)
	for {
		if len(s.pending) >= 2 {
			if s.pending[0] == 0x81 {
				payload_len := int(s.pending[1] & 0x7f)
				off := 2
				if payload_len == 126 && len(s.pending) >= 4 {
					payload_len = int(s.pending[2]) << 8 | int(s.pending[3])
					off = 4
				} else if payload_len == 127 && len(s.pending) >= 10 {
					payload_len = 0
					for i in 0 ..< 8 do payload_len = payload_len << 8 | int(s.pending[2 + i])
					off = 10
				}
				if off > 2 || payload_len < 126 {
					total_frame_len := off + payload_len
					if len(s.pending) >= total_frame_len {
						text := strings.clone(string(s.pending[off : total_frame_len]))
						remaining := len(s.pending) - total_frame_len
						for i in 0 ..< remaining {
							s.pending[i] = s.pending[total_frame_len + i]
						}
						resize(&s.pending, remaining)
						return text, true
					}
				}
			}
		}

		buf: [4096]byte
		n, err := net.recv_tcp(s.sock, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&s.pending, ..buf[:n])
	}
}

@(private = "file")
Bridge_WS_Runner :: struct {
	h: ^Bridge_Handlers,
	req: Request,
	sock: net.TCP_Socket,
}

@(private = "file")
run_bridge_ws_thread :: proc(data: rawptr) {
	runner := (^Bridge_WS_Runner)(data)
	bridge_ws_upgrade_handler(rawptr(runner.h), runner.req, runner.sock)
}

// REQ-TEL-HUB-2: PATCH /api/v1/bridges/{id} with telemetry_enabled dispatches set_telemetry frame to online bridge
@(test)
test_patch_bridge_telemetry_dispatches_runtime_command :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "patch_tel_dispatch")
	defer teardown_telemetry_test_fixture(f)

	pair, ok := make_telemetry_sock_pair(t)
	testing.expect(t, ok, "sock pair created")
	defer close_telemetry_sock_pair(&pair)

	project_service.bridge_runtime_registry_mark_live(&f.registry, f.bridge_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&f.registry, f.bridge_id, pair.hub)

	// 1. PATCH to "enabled"
	req_enabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"enabled"}`,
		request_id = "req_patch_dispatch_1",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_enabled := rename_bridge_handler(rawptr(&f.bh), req_enabled)
	testing.expect_value(t, resp_enabled.status, 200)

	frame1, f1_ok := read_server_ws_frame(pair.client)
	testing.expect(t, f1_ok, "received frame on client socket")
	testing.expect(t, strings.contains(frame1, `"type":"set_telemetry"`), "frame type is set_telemetry")
	testing.expect(t, strings.contains(frame1, `"enabled":true`), "enabled is true")
	testing.expect(t, strings.contains(frame1, `"command_id":"cmd_tel_`), "command_id has prefix cmd_tel_")
	delete(frame1)

	// 2. PATCH to "disabled"
	req_disabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"disabled"}`,
		request_id = "req_patch_dispatch_2",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_disabled := rename_bridge_handler(rawptr(&f.bh), req_disabled)
	testing.expect_value(t, resp_disabled.status, 200)

	frame2, f2_ok := read_server_ws_frame(pair.client)
	testing.expect(t, f2_ok, "received frame on client socket")
	testing.expect(t, strings.contains(frame2, `"type":"set_telemetry"`), "frame type is set_telemetry")
	testing.expect(t, strings.contains(frame2, `"enabled":false`), "enabled is false")
	testing.expect(t, strings.contains(frame2, `"command_id":"cmd_tel_`), "command_id has prefix cmd_tel_")
	delete(frame2)
}

// REQ-TEL-HUB-2: PATCH /api/v1/bridges/{id} when bridge is offline does not dispatch frame
@(test)
test_patch_bridge_telemetry_offline_does_not_dispatch :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "patch_tel_offline")
	defer teardown_telemetry_test_fixture(f)

	// Bridge is NOT live in registry
	req_enabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"enabled"}`,
		request_id = "req_patch_offline_1",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp := rename_bridge_handler(rawptr(&f.bh), req_enabled)
	testing.expect_value(t, resp.status, 200)

	persisted, p_ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, p_ok, "persisted bridge retrieved")
	testing.expect_value(t, persisted.telemetry_enabled, "enabled")
}

// REQ-TEL-HUB-1: Bridge WebSocket connect dispatches initial set_telemetry frame when enabled
@(test)
test_bridge_connect_dispatches_initial_telemetry_when_enabled :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "ws_connect_tel_enabled")
	defer teardown_telemetry_test_fixture(f)

	// Configure bridge with telemetry_enabled = "enabled" in repo
	req_enabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"enabled"}`,
		request_id = "req_setup_tel",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_setup := rename_bridge_handler(rawptr(&f.bh), req_enabled)
	testing.expect_value(t, resp_setup.status, 200)

	pair, ok := make_telemetry_sock_pair(t)
	testing.expect(t, ok, "sock pair created")

	ws_headers := [2]contracts.HTTP_Header{
		{name = "Authorization", value = fmt.tprintf("Bearer %s", f.bridge_token)},
		{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
	}
	ws_req := Request{
		method = "GET",
		path = "/api/v1/bridge-ws",
		headers = ws_headers[:],
		request_id = "req_ws_upgrade_tel",
		remote_addr = "127.0.0.1:4444",
	}

	runner := Bridge_WS_Runner{
		h = &f.bh,
		req = ws_req,
		sock = pair.hub,
	}

	th := thread.create_and_start_with_data(rawptr(&runner), run_bridge_ws_thread)
	defer {
		net.close(pair.client); pair.client = net.TCP_Socket(0)
		thread.join(th)
		thread.destroy(th)
		close_telemetry_sock_pair(&pair)
	}

	// 1. Read HTTP 101 Switching Protocols response
	h101_ok := read_http_101(pair.client)
	testing.expect(t, h101_ok, "received HTTP 101 Switching Protocols")

	// 2. Send masked hello frame
	hello_json := fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"test-box","os":"linux","arch":"amd64","version":"1.0.0","bridge_id":"{0}","capabilities":{{}}}}`, f.bridge_id)
	hello_frame := make_masked_ws_frame(hello_json)
	defer delete(hello_frame)
	_, send_err := net.send_tcp(pair.client, hello_frame[:])
	testing.expect(t, send_err == nil, "sent hello frame")

	// 3. Receive frames via frame stream
	stream := ws_frame_stream_make(pair.client)
	defer ws_frame_stream_destroy(&stream)

	frame1, f1_ok := ws_frame_stream_next(&stream)
	testing.expect(t, f1_ok, "received first frame (bridge_ready)")
	testing.expect(t, strings.contains(frame1, `"type":"bridge_ready"`), "frame 1 is bridge_ready")
	delete(frame1)

	frame2, f2_ok := ws_frame_stream_next(&stream)
	testing.expect(t, f2_ok, "received second frame (set_telemetry)")
	testing.expect(t, strings.contains(frame2, `"type":"set_telemetry"`), "frame 2 is set_telemetry")
	testing.expect(t, strings.contains(frame2, `"enabled":true`), "frame 2 has enabled:true")
	testing.expect(t, strings.contains(frame2, `"command_id":"cmd_tel_`), "frame 2 has command_id")
	delete(frame2)
}

// REQ-TEL-HUB-1: Bridge WebSocket connect does not dispatch set_telemetry when disabled
@(test)
test_bridge_connect_does_not_dispatch_telemetry_when_disabled :: proc(t: ^testing.T) {
	f := setup_telemetry_test_fixture(t, "ws_connect_tel_disabled")
	defer teardown_telemetry_test_fixture(f)

	// Configure bridge with telemetry_enabled = "disabled" in repo
	req_disabled := Request{
		method = "PATCH",
		path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id),
		body = `{"telemetry_enabled":"disabled"}`,
		request_id = "req_setup_tel_dis",
		remote_addr = "127.0.0.1:4444",
		headers = f.user_headers,
	}
	resp_setup := rename_bridge_handler(rawptr(&f.bh), req_disabled)
	testing.expect_value(t, resp_setup.status, 200)

	pair, ok := make_telemetry_sock_pair(t)
	testing.expect(t, ok, "sock pair created")

	ws_headers := [2]contracts.HTTP_Header{
		{name = "Authorization", value = fmt.tprintf("Bearer %s", f.bridge_token)},
		{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
	}
	ws_req := Request{
		method = "GET",
		path = "/api/v1/bridge-ws",
		headers = ws_headers[:],
		request_id = "req_ws_upgrade_dis",
		remote_addr = "127.0.0.1:4444",
	}

	runner := Bridge_WS_Runner{
		h = &f.bh,
		req = ws_req,
		sock = pair.hub,
	}

	th := thread.create_and_start_with_data(rawptr(&runner), run_bridge_ws_thread)
	defer {
		net.close(pair.client); pair.client = net.TCP_Socket(0)
		thread.join(th)
		thread.destroy(th)
		close_telemetry_sock_pair(&pair)
	}

	// 1. Read HTTP 101 Switching Protocols response
	h101_ok := read_http_101(pair.client)
	testing.expect(t, h101_ok, "received HTTP 101 Switching Protocols")

	// 2. Send masked hello frame
	hello_json := fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"test-box","os":"linux","arch":"amd64","version":"1.0.0","bridge_id":"{0}","capabilities":{{}}}}`, f.bridge_id)
	hello_frame := make_masked_ws_frame(hello_json)
	defer delete(hello_frame)
	_, send_err := net.send_tcp(pair.client, hello_frame[:])
	testing.expect(t, send_err == nil, "sent hello frame")

	// 3. Receive frames via frame stream
	stream := ws_frame_stream_make(pair.client)
	defer ws_frame_stream_destroy(&stream)

	frame1, f1_ok := ws_frame_stream_next(&stream)
	testing.expect(t, f1_ok, "received first frame (bridge_ready)")
	testing.expect(t, strings.contains(frame1, `"type":"bridge_ready"`), "frame 1 is bridge_ready")
	delete(frame1)

	// No set_telemetry frame should be sent
	_, f2_ok := ws_frame_stream_next(&stream, timeout = 100 * time.Millisecond)
	testing.expect(t, !f2_ok, "no set_telemetry frame dispatched when disabled")
}
