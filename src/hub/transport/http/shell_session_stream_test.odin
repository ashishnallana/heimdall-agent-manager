package http

import "core:mem"
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
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

// Loopback socket pair for testing WebSocket endpoints
@(private = "file")
Stream_Sock_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
make_stream_pair :: proc(t: ^testing.T) -> (Stream_Sock_Pair, bool) {
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
	return Stream_Sock_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
close_stream_pair :: proc(p: ^Stream_Sock_Pair) {
	if int(p.hub) > 0 { net.close(p.hub); p.hub = net.TCP_Socket(0) }
	if int(p.client) > 0 { net.close(p.client); p.client = net.TCP_Socket(0) }
	if int(p.listener) > 0 { net.close(p.listener); p.listener = net.TCP_Socket(0) }
}

// Read raw response string until timeout
@(private = "file")
read_raw_response :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
		s := string(acc[:])
		if strings.contains(s, "\r\n\r\n") {
			return strings.clone(s), true
		}
	}
	if len(acc) > 0 {
		return strings.clone(string(acc[:])), true
	}
	return "", false
}

// read_server_stream_frame reads one unmasked text frame sent from Hub to client
@(private = "file")
read_server_stream_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do return "", false
		append(&acc, ..buf[:n])
		b := acc[:]
		if len(b) < 2 do continue
		if b[0] != 0x81 do return "", false
		payload_len := int(b[1] & 0x7f)
		header_len := 2
		switch payload_len {
		case 126:
			if len(b) < 4 do continue
			payload_len = int(b[2]) << 8 | int(b[3])
			header_len = 4
		case 127:
			if len(b) < 10 do continue
			length: u64 = 0
			for i in 0 ..< 8 do length = length << 8 | u64(b[2 + i])
			payload_len = int(length)
			header_len = 10
		}
		if (b[1] & 0x80) != 0 do return "", false
		if len(b) < header_len + payload_len do continue
		return strings.clone(string(b[header_len:header_len + payload_len])), true
	}
}

// read_upgrade_and_stream_frame consumes HTTP 101 response, then reads first WS frame
@(private = "file")
read_upgrade_and_stream_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
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

// Fake experiment repository for shell streaming tests
@(private = "file")
Fake_Shell_Experiments :: struct {
	streaming_enabled: bool,
}

@(private = "file")
fake_shell_experiment_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	f := (^Fake_Shell_Experiments)(ctx)
	out := make([dynamic]domain.Experiment)
	append(&out, domain.Experiment{
		owner_user_id = strings.clone(owner_user_id),
		key           = strings.clone(domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY),
		enabled       = f.streaming_enabled,
		updated_at    = strings.clone("2026-09-27T01:00:00Z"),
	})
	return out, domain.Domain_Error{}
}

// Fake shell repository for tests
@(private = "file")
Fake_Shell_Repo :: struct {
	session: domain.Shell_Session,
}

@(private = "file")
clone_shell_session_helper :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id        = strings.clone(s.session_id),
		owner_user_id     = strings.clone(s.owner_user_id),
		bridge_id         = strings.clone(s.bridge_id),
		project_id        = strings.clone(s.project_id),
		chain_id          = strings.clone(s.chain_id),
		agent_instance_id = strings.clone(s.agent_instance_id),
		kind              = strings.clone(s.kind),
		label             = strings.clone(s.label),
		cmd               = strings.clone(s.cmd),
		cwd               = strings.clone(s.cwd),
		status            = strings.clone(s.status),
		exit_code         = s.exit_code,
		exit_code_set     = s.exit_code_set,
		pid               = s.pid,
		server_port       = s.server_port,
		preview_enabled   = s.preview_enabled,
		started_at        = strings.clone(s.started_at),
		finished_at       = strings.clone(s.finished_at),
		created_at        = strings.clone(s.created_at),
		last_activity_at  = strings.clone(s.last_activity_at),
	}
}

@(private = "file")
fake_shell_repo_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Fake_Shell_Repo)(ctx)
	if f.session.session_id == session_id && f.session.owner_user_id == owner_user_id {
		return clone_shell_session_helper(f.session), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
// Bridge-qualified since REQ-SHELL-1 §7: the key is (bridge_id, session_id), so
// the fake matches on both, exactly as the sqlite repo does.
fake_shell_repo_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Fake_Shell_Repo)(ctx)
	if f.session.session_id == session_id && f.session.bridge_id == bridge_id {
		return clone_shell_session_helper(f.session), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

// Mock bridge command sink to capture dispatched commands
@(private = "file")
Mock_Command_Sink_State :: struct {
	mu:        sync.Mutex,
	allocator: mem.Allocator,
	commands:  [dynamic]project_service.Runtime_Command,
}

@(private = "file")
mock_send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	st := (^Mock_Command_Sink_State)(ctx)
	sync.mutex_lock(&st.mu)
	defer sync.mutex_unlock(&st.mu)
	alloc := st.allocator.procedure != nil ? st.allocator : context.allocator
	append(&st.commands, project_service.Runtime_Command{
		bridge_id  = strings.clone(command.bridge_id, alloc),
		command_id = strings.clone(command.command_id, alloc),
		body_json  = strings.clone(command.body_json, alloc),
	})
	return true, domain.Domain_Error{}
}

@(private = "file")
Stream_Handler_Runner :: struct {
	h:        ^Shell_Session_Stream_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
run_stream_handler_thread :: proc(data: rawptr) {
	r := (^Stream_Handler_Runner)(data)
	shell_session_stream_handler(rawptr(r.h), r.req, r.sock)
	r.finished = true
}

// -----------------------------------------------------------------------------
// Test 1: Ticket authentication & experiment flag gating
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_ticket_and_experiment_gating :: proc(t: ^testing.T) {
	// 1a. Missing ticket -> 401
	{
		pair, ok := make_stream_pair(t)
		testing.expect(t, ok)
		defer close_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)

		h := Shell_Session_Stream_Handlers{
			ws_tickets = &tickets,
		}

		shell_session_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/shells/sh_test/stream", query = "", request_id = "req_1",
		}, pair.hub)

		resp, r_ok := read_raw_response(pair.client, 5 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "401 Unauthorized"), "missing ticket must return 401")
		delete(resp)
	}

	// 1b. Invalid ticket -> 401
	{
		pair, ok := make_stream_pair(t)
		testing.expect(t, ok)
		defer close_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)

		h := Shell_Session_Stream_Handlers{
			ws_tickets = &tickets,
		}

		shell_session_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/shells/sh_test/stream", query = "ticket=invalid_ticket", request_id = "req_2",
		}, pair.hub)

		resp, r_ok := read_raw_response(pair.client, 5 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "401 Unauthorized"), "invalid ticket must return 401")
		delete(resp)
	}

	// 1c. Experiment disabled -> 403 Forbidden
	{
		pair, ok := make_stream_pair(t)
		testing.expect(t, ok)
		defer close_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)
		user_ws_ticket_store_put(&tickets, "ticket_valid", contracts.Auth_Context{
			kind = .User_Token, user_id = "user_test",
		}, 60)

		fake_exp := Fake_Shell_Experiments{streaming_enabled = false}
		exp_repo := iface.Experiment_Repository{ctx = rawptr(&fake_exp), list_by_owner = fake_shell_experiment_list}

		h := Shell_Session_Stream_Handlers{
			ws_tickets  = &tickets,
			experiments = &exp_repo,
		}

		shell_session_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/shells/sh_test/stream", query = "ticket=ticket_valid", request_id = "req_3",
		}, pair.hub)

		resp, r_ok := read_raw_response(pair.client, 5 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "403 Forbidden"), "disabled experiment must return 403")
		testing.expect(t, strings.contains(resp, "streaming_terminal_pane experiment is not enabled"), "must mention streaming flag")
		delete(resp)
	}

	// 1d. Experiment enabled -> Upgrade 101 & ready frame
	{
		pair, ok := make_stream_pair(t)
		testing.expect(t, ok)
		defer close_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)
		user_ws_ticket_store_put(&tickets, "ticket_valid_2", contracts.Auth_Context{
			kind = .User_Token, user_id = "user_test",
		}, 60)

		fake_exp := Fake_Shell_Experiments{streaming_enabled = true}
		exp_repo := iface.Experiment_Repository{ctx = rawptr(&fake_exp), list_by_owner = fake_shell_experiment_list}

		fake_repo := Fake_Shell_Repo{
			session = domain.Shell_Session{
				session_id    = "sh_test",
				owner_user_id = "user_test",
				bridge_id     = "brg_local",
				status        = domain.Shell_Session_Status_Running,
			},
		}
		repo_iface := iface.Shell_Session_Repository{
			ctx = rawptr(&fake_repo),
			get = fake_shell_repo_get,
			get_by_id = fake_shell_repo_get_by_id,
		}

		shell_svc := shell_session_svc.new_shell_session_service(repo = &repo_iface)
		defer shell_session_svc.shell_session_service_free(&shell_svc)

		h := Shell_Session_Stream_Handlers{
			ws_tickets     = &tickets,
			experiments    = &exp_repo,
			shell_repo     = &repo_iface,
			shell_sessions = &shell_svc,
		}

		headers := []contracts.HTTP_Header{
			{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
		}
		runner := new(Stream_Handler_Runner)
		defer free(runner)
		runner.h = &h
		runner.sock = pair.hub
		runner.req = Request{
			method = "GET", path = "/api/v1/shells/sh_test/stream", query = "ticket=ticket_valid_2",
			request_id = "req_4", headers = headers,
		}

		th := thread.create_and_start_with_data(rawptr(runner), run_stream_handler_thread)
		defer thread.destroy(th)

		frame, read_ok := read_upgrade_and_stream_frame(pair.client, 5 * time.Second)
		testing.expect(t, read_ok, "upgrade response and ready frame must arrive")
		if read_ok {
			testing.expect(t, strings.contains(frame, "\"type\":\"ready\""), "must send ready frame")
			testing.expect(t, strings.contains(frame, "\"session_id\":\"sh_test\""), "ready frame must cite session_id")
			delete(frame)
		}

		// Verify viewer was tracked in shell_sessions.viewers
		testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&shell_svc, "sh_test"), 1)

		// Close client to let handler unwind
		net.close(pair.client); pair.client = net.TCP_Socket(0)
		deadline := time.now()
		for !runner.finished && time.duration_seconds(time.since(deadline)) < 5.0 {
			time.sleep(20 * time.Millisecond)
		}
		testing.expect(t, runner.finished, "handler must finish after client disconnect")
		thread.join(th)

		// After disconnect, viewer count drops to 0
		testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&shell_svc, "sh_test"), 0)
	}
}

// -----------------------------------------------------------------------------
// Test 2: Viewer count transitions (0->1 attach, 1->0 detach)
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_viewer_transitions_attach_detach :: proc(t: ^testing.T) {
	sink_state := Mock_Command_Sink_State{}
	defer {
		for cmd in sink_state.commands {
			delete(cmd.bridge_id)
			delete(cmd.command_id)
			delete(cmd.body_json)
		}
		delete(sink_state.commands)
	}

	sink := project_service.Bridge_Command_Sink{
		ctx                  = rawptr(&sink_state),
		send_runtime_command = mock_send_runtime_command,
	}

	ids := http_test_id_generator()
	svc := shell_session_svc.new_shell_session_service(
		bridge_command_sink = sink,
		ids                 = &ids,
	)
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_transition_test"
	bridge_id := "brg_target_1"

	sock1 := net.TCP_Socket(101)
	sock2 := net.TCP_Socket(102)

	// Step 1: 0 -> 1 transition (first viewer attaches)
	shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 1)
	if len(sink_state.commands) >= 1 {
		last := sink_state.commands[0]
		testing.expect_value(t, last.bridge_id, bridge_id)
		testing.expect(t, strings.contains(last.body_json, "\"type\":\"shell_stream_attach\""), "command must be shell_stream_attach")
		testing.expect(t, strings.contains(last.body_json, "\"session_id\":\"sh_transition_test\""), "command must cite session_id")
	}
	sync.mutex_unlock(&sink_state.mu)

	// Step 2: 1 -> 2 transition (second viewer attaches -> no additional attach command)
	shell_session_svc.shell_session_attach(&svc, session_id, sock2, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 2)

	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 1) // still 1!
	sync.mutex_unlock(&sink_state.mu)

	// Step 3: 2 -> 1 transition (first viewer detaches -> still active, no detach command)
	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 1) // still 1!
	sync.mutex_unlock(&sink_state.mu)

	// Step 4: 1 -> 0 transition (last viewer detaches -> shell_stream_detach emitted!)
	shell_session_svc.shell_session_detach(&svc, session_id, sock2, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 0)

	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 2)
	if len(sink_state.commands) >= 2 {
		last := sink_state.commands[1]
		testing.expect_value(t, last.bridge_id, bridge_id)
		testing.expect(t, strings.contains(last.body_json, "\"type\":\"shell_stream_detach\""), "command must be shell_stream_detach")
		testing.expect(t, strings.contains(last.body_json, "\"session_id\":\"sh_transition_test\""), "command must cite session_id")
	}
	sync.mutex_unlock(&sink_state.mu)
}

// -----------------------------------------------------------------------------
// Test 3: Output broadcast to connected client WebSockets
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_broadcast_output :: proc(t: ^testing.T) {
	pair1, ok1 := make_stream_pair(t)
	testing.expect(t, ok1)
	defer close_stream_pair(&pair1)

	pair2, ok2 := make_stream_pair(t)
	testing.expect(t, ok2)
	defer close_stream_pair(&pair2)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_broadcast_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair1.hub)
	shell_session_svc.shell_session_attach(&svc, session_id, pair2.hub)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 2)

	// Simulate output broadcast from Bridge (base64 encoded VT100 bytes)
	test_b64 := "aGVsbG8gd29ybGQ=" // "hello world"
	shell_session_svc.shell_session_broadcast_output(&svc, session_id, test_b64)

	// Verify both client sockets received the unmasked output frame
	frame1, r1 := read_server_stream_frame(pair1.client, 2 * time.Second)
	testing.expect(t, r1, "client 1 must receive output frame")
	if r1 {
		testing.expect(t, strings.contains(frame1, "\"type\":\"output\""))
		testing.expect(t, strings.contains(frame1, test_b64))
		delete(frame1)
	}

	frame2, r2 := read_server_stream_frame(pair2.client, 2 * time.Second)
	testing.expect(t, r2, "client 2 must receive output frame")
	if r2 {
		testing.expect(t, strings.contains(frame2, "\"type\":\"output\""))
		testing.expect(t, strings.contains(frame2, test_b64))
		delete(frame2)
	}
}

// -----------------------------------------------------------------------------
// Test 3b: Output broadcast with enc_b64 (REQ-SHELL-ENC-12)
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_broadcast_enc_output :: proc(t: ^testing.T) {
	pair1, ok1 := make_stream_pair(t)
	testing.expect(t, ok1)
	defer close_stream_pair(&pair1)

	pair2, ok2 := make_stream_pair(t)
	testing.expect(t, ok2)
	defer close_stream_pair(&pair2)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_broadcast_enc_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair1.hub)
	shell_session_svc.shell_session_attach(&svc, session_id, pair2.hub)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 2)

	// Simulate encrypted output broadcast from Bridge
	test_enc_b64 := "dmF1bHQ6djE6YWJjZGVmZ2hpams="
	shell_session_svc.shell_session_broadcast_output(&svc, session_id, test_enc_b64, true)

	// Verify both client sockets received the unmasked output frame containing enc_b64
	frame1, r1 := read_server_stream_frame(pair1.client, 2 * time.Second)
	testing.expect(t, r1, "client 1 must receive encrypted output frame")
	if r1 {
		testing.expect(t, strings.contains(frame1, "\"type\":\"output\""))
		testing.expect(t, strings.contains(frame1, "\"data_b64\":\"dmF1bHQ6djE6YWJjZGVmZ2hpams=\""))
		testing.expect(t, !strings.contains(frame1, "enc_b64"))
		delete(frame1)
	}

	frame2, r2 := read_server_stream_frame(pair2.client, 2 * time.Second)
	testing.expect(t, r2, "client 2 must receive encrypted output frame")
	if r2 {
		testing.expect(t, strings.contains(frame2, "\"type\":\"output\""))
		testing.expect(t, strings.contains(frame2, "\"data_b64\":\"dmF1bHQ6djE6YWJjZGVmZ2hpams=\""))
		testing.expect(t, !strings.contains(frame2, "enc_b64"))
		delete(frame2)
	}
}

// -----------------------------------------------------------------------------
// Test 3c: Bridge shell_pty_output frame with enc_b64 forwards to viewers (REQ-SHELL-ENC-12)
// -----------------------------------------------------------------------------
@(test)
test_bridge_shell_pty_output_enc_b64_forwarding :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	defer close_stream_pair(&pair)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_bridge_enc_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair.hub, "brg_test")
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	bh := Bridge_Handlers{
		shell_sessions = &svc,
	}

	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	bridge_msg := strings.clone("{\"type\":\"shell_pty_output\",\"session_id\":\"sh_bridge_enc_test\",\"data_b64\":\"dmF1bHQ6djE6dGVzdA==\",\"is_encrypted\":true}")
	handled := bridge_ws_process_frame(&bh, "brg_test", 0, pair.hub, &reassemblies, bridge_msg)
	testing.expect(t, handled, "bridge_ws_process_frame must handle shell_pty_output")

	frame, r := read_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, r, "client must receive output frame")
	if r {
		testing.expect(t, strings.contains(frame, "\"type\":\"output\""), "frame must have type output")
		testing.expect(t, strings.contains(frame, "\"data_b64\":\"dmF1bHQ6djE6dGVzdA==\",\"is_encrypted\":true"), "frame must contain enc_b64")
		testing.expect(t, !strings.contains(frame, "enc_b64"), "ciphertext must not be duplicated")
		delete(frame)
	}
}

// -----------------------------------------------------------------------------
// Test 3d: Bridge shell_pty_output with armored data_b64 forwards transparently (REQ-SHELL-ENC-12)
// -----------------------------------------------------------------------------
@(test)
test_bridge_shell_pty_output_armored_data_b64_forwarding :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	defer close_stream_pair(&pair)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_bridge_armored_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair.hub, "brg_test")
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	bh := Bridge_Handlers{
		shell_sessions = &svc,
	}

	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	bridge_msg := strings.clone("{\"type\":\"shell_pty_output\",\"session_id\":\"sh_bridge_armored_test\",\"data_b64\":\"YWJjZGVmZ2hpams=\",\"is_encrypted\":false}")
	handled := bridge_ws_process_frame(&bh, "brg_test", 0, pair.hub, &reassemblies, bridge_msg)
	testing.expect(t, handled, "bridge_ws_process_frame must handle shell_pty_output")

	frame, r := read_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, r, "client must receive output frame")
	if r {
		testing.expect(t, strings.contains(frame, "\"type\":\"output\""), "frame must have type output")
		testing.expect(t, strings.contains(frame, "\"data_b64\":\"YWJjZGVmZ2hpams=\",\"is_encrypted\":false"), "frame must contain armored data_b64")
		delete(frame)
	}
}

// -----------------------------------------------------------------------------
// Test 3e: Bridge shell_pty_stream_ready forwards as stream_ready to viewers (REQ-STREAM-EVENT-3)
// -----------------------------------------------------------------------------
@(test)
test_bridge_shell_pty_stream_ready_forwarding :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	defer close_stream_pair(&pair)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_bridge_ready_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair.hub)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	bh := Bridge_Handlers{
		shell_sessions = &svc,
	}

	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	bridge_msg := strings.clone("{\"type\":\"shell_pty_stream_ready\",\"session_id\":\"sh_bridge_ready_test\"}")
	handled := bridge_ws_process_frame(&bh, "brg_test", 0, pair.hub, &reassemblies, bridge_msg)
	testing.expect(t, handled, "bridge_ws_process_frame must handle shell_pty_stream_ready")

	frame, r := read_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, r, "client must receive stream_ready frame")
	if r {
		testing.expect(t, strings.contains(frame, "\"type\":\"stream_ready\""), "frame must have type stream_ready")
		testing.expect(t, strings.contains(frame, "\"session_id\":\"sh_bridge_ready_test\""), "frame must cite session_id")
		delete(frame)
	}
}

// -----------------------------------------------------------------------------
// Test 3f: Bridge shell_pty_stream_closed forwards as stream_closed to viewers (REQ-STREAM-EVENT-3)
// -----------------------------------------------------------------------------
@(test)
test_bridge_shell_pty_stream_closed_forwarding :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	defer close_stream_pair(&pair)

	svc := shell_session_svc.new_shell_session_service()
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_bridge_closed_test"
	shell_session_svc.shell_session_attach(&svc, session_id, pair.hub)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	bh := Bridge_Handlers{
		shell_sessions = &svc,
	}

	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	bridge_msg := strings.clone("{\"type\":\"shell_pty_stream_closed\",\"session_id\":\"sh_bridge_closed_test\",\"exit_code\":0}")
	handled := bridge_ws_process_frame(&bh, "brg_test", 0, pair.hub, &reassemblies, bridge_msg)
	testing.expect(t, handled, "bridge_ws_process_frame must handle shell_pty_stream_closed")

	frame, r := read_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, r, "client must receive stream_closed frame")
	if r {
		testing.expect(t, strings.contains(frame, "\"type\":\"stream_closed\""), "frame must have type stream_closed")
		testing.expect(t, strings.contains(frame, "\"session_id\":\"sh_bridge_closed_test\""), "frame must cite session_id")
		testing.expect(t, strings.contains(frame, "\"exit_code\":0"), "frame must contain exit_code")
		delete(frame)
	}
}

// -----------------------------------------------------------------------------
// Test 4: Inbound input and resize frame forwarding to Bridge sink
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_input_and_resize_forwarding :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	defer close_stream_pair(&pair)

	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	user_ws_ticket_store_put(&tickets, "ticket_input_test", contracts.Auth_Context{
		kind = .User_Token, user_id = "user_input",
	}, 60)

	fake_exp := Fake_Shell_Experiments{streaming_enabled = true}
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&fake_exp), list_by_owner = fake_shell_experiment_list}

	fake_repo := Fake_Shell_Repo{
		session = domain.Shell_Session{
			session_id    = "sh_input_test",
			owner_user_id = "user_input",
			bridge_id     = "brg_input_target",
			status        = domain.Shell_Session_Status_Running,
		},
	}
	repo_iface := iface.Shell_Session_Repository{
		ctx = rawptr(&fake_repo),
		get = fake_shell_repo_get,
		get_by_id = fake_shell_repo_get_by_id,
	}

	sink_state := Mock_Command_Sink_State{allocator = context.allocator}
	defer {
		for cmd in sink_state.commands {
			delete(cmd.bridge_id, sink_state.allocator)
			delete(cmd.command_id, sink_state.allocator)
			delete(cmd.body_json, sink_state.allocator)
		}
		delete(sink_state.commands)
	}
	mock_sink := project_service.Bridge_Command_Sink{
		ctx                  = rawptr(&sink_state),
		send_runtime_command = mock_send_runtime_command,
	}

	shell_svc := shell_session_svc.new_shell_session_service(repo = &repo_iface, bridge_command_sink = mock_sink)
	defer shell_session_svc.shell_session_service_free(&shell_svc)

	// Create a minimal fake bridge repo so bridge_service.get_bridge returns Online
	bridge_inst := domain.Bridge{
		bridge_id     = "brg_input_target",
		owner_user_id = domain.User_ID("user_input"),
		status        = .Online,
	}
	fake_bridge_repo_impl: struct {
		b: domain.Bridge,
	}
	fake_bridge_repo_impl.b = bridge_inst
	fake_bridge_get := proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
		f := (^struct { b: domain.Bridge })(ctx)
		return f.b, true, domain.Domain_Error{}
	}
	bridge_repo := iface.Bridge_Repository{
		ctx = rawptr(&fake_bridge_repo_impl),
		get_bridge = fake_bridge_get,
	}
	bridges := bridge_service.Bridge_Service{
		repo = &bridge_repo,
		bridge_command_sink = mock_sink,
	}

	h := Shell_Session_Stream_Handlers{
		ws_tickets          = &tickets,
		experiments         = &exp_repo,
		shell_repo          = &repo_iface,
		shell_sessions      = &shell_svc,
		bridges             = &bridges,
		bridge_command_sink = mock_sink,
	}

	headers := []contracts.HTTP_Header{
		{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="},
	}
	runner := new(Stream_Handler_Runner)
	defer free(runner)
	runner.h = &h
	runner.sock = pair.hub
	runner.req = Request{
		method = "GET", path = "/api/v1/shells/sh_input_test/stream", query = "ticket=ticket_input_test",
		request_id = "req_input_1", headers = headers,
	}

	th := thread.create_and_start_with_data(rawptr(runner), run_stream_handler_thread)
	defer thread.destroy(th)

	// Consume upgrade and ready frame
	frame, read_ok := read_upgrade_and_stream_frame(pair.client, 5 * time.Second)
	testing.expect(t, read_ok, "handshake must succeed")
	if read_ok do delete(frame)

	// Send an input frame from client: {"type":"input","data_b64":"Y2xlYXIK"} ("clear\n")
	input_json := "{\"type\":\"input\",\"data_b64\":\"Y2xlYXIK\",\"is_encrypted\":false}"
	_ = write_ws_text_frame(pair.client, input_json)

	// Send an encrypted input frame: {"type":"input","enc_b64":"dmF1bHQ6djE6d3NfZW5j"}
	enc_input_json := "{\"type\":\"input\",\"data_b64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\",\"is_encrypted\":true}"
	_ = write_ws_text_frame(pair.client, enc_input_json)

	// Send a resize frame from client: {"type":"resize","rows":35,"cols":110}
	resize_json := "{\"type\":\"resize\",\"rows\":35,\"cols\":110}"
	_ = write_ws_text_frame(pair.client, resize_json)

	// Allow time for reader thread to process frames
	wait_start := time.now()
	for time.duration_seconds(time.since(wait_start)) < 5.0 {
		sync.mutex_lock(&sink_state.mu)
		count := len(sink_state.commands)
		sync.mutex_unlock(&sink_state.mu)
		if count >= 4 do break
		time.sleep(10 * time.Millisecond)
	}

	sync.mutex_lock(&sink_state.mu)
	// Commands received should include:
	// 1. shell_stream_attach (from 0->1 viewer transition)
	// 2. shell_pty_input (from input frame)
	// 3. shell_pty_input (from enc_b64 input frame)
	// 4. shell_pty_resize (from resize frame)
	testing.expect(t, len(sink_state.commands) >= 4, "expected at least 4 commands in sink")
	has_input := false
	has_enc_input := false
	has_resize := false
	for cmd in sink_state.commands {
		if strings.contains(cmd.body_json, "\"type\":\"shell_pty_input\"") {
			if strings.contains(cmd.body_json, "Y2xlYXIK") {
				has_input = true
				testing.expect_value(t, cmd.bridge_id, "brg_input_target")
			}
			if strings.contains(cmd.body_json, "\"data_b64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\",\"is_encrypted\":true") {
				has_enc_input = true
				testing.expect_value(t, cmd.bridge_id, "brg_input_target")
			}
		}
		if strings.contains(cmd.body_json, "\"type\":\"shell_pty_resize\"") {
			has_resize = true
			testing.expect_value(t, cmd.bridge_id, "brg_input_target")
			testing.expect(t, strings.contains(cmd.body_json, "\"rows\":35"), "rows must match")
			testing.expect(t, strings.contains(cmd.body_json, "\"cols\":110"), "cols must match")
		}
	}
	testing.expect(t, has_input, "must have dispatched shell_pty_input")
	testing.expect(t, has_enc_input, "must have dispatched shell_pty_input with enc_b64")
	testing.expect(t, has_resize, "must have dispatched shell_pty_resize")
	sync.mutex_unlock(&sink_state.mu)

	net.close(pair.client); pair.client = net.TCP_Socket(0)
	deadline := time.now()
	for !runner.finished && time.duration_seconds(time.since(deadline)) < 5.0 {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, runner.finished)
	thread.join(th)
}

// -----------------------------------------------------------------------------
// Test 5: Attach deduplication prevents duplicate sockets in svc.viewers
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_attach_deduplication :: proc(t: ^testing.T) {
	sink_state := Mock_Command_Sink_State{}
	defer {
		for cmd in sink_state.commands {
			delete(cmd.bridge_id)
			delete(cmd.command_id)
			delete(cmd.body_json)
		}
		delete(sink_state.commands)
	}

	sink := project_service.Bridge_Command_Sink{
		ctx                  = rawptr(&sink_state),
		send_runtime_command = mock_send_runtime_command,
	}

	ids := http_test_id_generator()
	svc := shell_session_svc.new_shell_session_service(
		bridge_command_sink = sink,
		ids                 = &ids,
	)
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_dedup_test"
	bridge_id := "brg_target_dedup"
	sock1 := net.TCP_Socket(201)

	// First attach
	shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	// Second attach with same socket (should be a no-op)
	shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	// Third attach with same socket (should still be 1)
	shell_session_svc.shell_session_attach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	// Only 1 attach command emitted to bridge
	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 1)
	sync.mutex_unlock(&sink_state.mu)

	// Detach once drops viewer count to 0 and sends detach
	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 0)

	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 2)
	sync.mutex_unlock(&sink_state.mu)

	// Subsequent detach call when already empty does NOT send duplicate detach
	shell_session_svc.shell_session_detach(&svc, session_id, sock1, bridge_id)
	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 2)
	sync.mutex_unlock(&sink_state.mu)
}

// -----------------------------------------------------------------------------
// Test 6: Broadcast output prunes dead sockets on write failure
// -----------------------------------------------------------------------------
@(test)
test_shell_stream_broadcast_prunes_dead_socket :: proc(t: ^testing.T) {
	pair1, ok1 := make_stream_pair(t)
	testing.expect(t, ok1)
	defer close_stream_pair(&pair1)

	pair2, ok2 := make_stream_pair(t)
	testing.expect(t, ok2)
	defer close_stream_pair(&pair2)

	sink_state := Mock_Command_Sink_State{}
	defer {
		for cmd in sink_state.commands {
			delete(cmd.bridge_id)
			delete(cmd.command_id)
			delete(cmd.body_json)
		}
		delete(sink_state.commands)
	}

	sink := project_service.Bridge_Command_Sink{
		ctx                  = rawptr(&sink_state),
		send_runtime_command = mock_send_runtime_command,
	}

	ids := http_test_id_generator()
	svc := shell_session_svc.new_shell_session_service(
		bridge_command_sink = sink,
		ids                 = &ids,
	)
	defer shell_session_svc.shell_session_service_free(&svc)

	session_id := "sh_prune_test"
	bridge_id := "brg_target_prune"

	shell_session_svc.shell_session_attach(&svc, session_id, pair1.hub, bridge_id)
	shell_session_svc.shell_session_attach(&svc, session_id, pair2.hub, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 2)

	// Intentionally close pair1 client & hub so write fails on pair1.hub
	_ = net.shutdown(pair1.hub, .Send)

	// Broadcast output
	test_b64 := "dGVzdF9kYXRh"
	shell_session_svc.shell_session_broadcast_output(&svc, session_id, test_b64)

	stream_test_wait_viewers(t, &svc, session_id, 1)
	shell_session_svc.shell_session_detach(&svc, session_id, pair1.hub, bridge_id)
	// The woken reader owns detach; this fixture performs its teardown.
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 1)

	// Now close pair2 as well
	_ = net.shutdown(pair2.hub, .Send)

	// Second broadcast should prune pair2, reducing count to 0 and triggering detach to bridge
	shell_session_svc.shell_session_broadcast_output(&svc, session_id, test_b64)
	stream_test_wait_viewers(t, &svc, session_id, 0)
	shell_session_svc.shell_session_detach(&svc, session_id, pair2.hub, bridge_id)
	testing.expect_value(t, shell_session_svc.shell_session_viewer_count(&svc, session_id), 0)

	sync.mutex_lock(&sink_state.mu)
	has_detach := false
	for cmd in sink_state.commands {
		if strings.contains(cmd.body_json, "\"type\":\"shell_stream_detach\"") {
			has_detach = true
		}
	}
	testing.expect(t, has_detach, "broadcast output pruning last socket must send detach to bridge")
	sync.mutex_unlock(&sink_state.mu)
}

stream_test_wait_viewers :: proc(t: ^testing.T, svc: ^shell_session_svc.Shell_Session_Service, session_id: string, expected: int) {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		if shell_session_svc.shell_session_viewer_count(svc, session_id) == expected do return
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "writer did not wake its reader")
}

// REQ-ERR-PROTO-A: a chunk the hub refuses (malformed, over-cap, admission) is answered with a typed
// protocol_error on the bridge's own socket before the connection is closed.
@(test)
test_err_proto_rejected_chunk_frame_gets_protocol_error :: proc(t: ^testing.T) {
	pair, ok := make_stream_pair(t)
	testing.expect(t, ok)
	if !ok do return
	defer close_stream_pair(&pair)

	registry := project_service.Bridge_Runtime_Registry{}
	bridge_id := "brg_err_proto_chunk"
	project_service.bridge_runtime_registry_mark_live(&registry, bridge_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&registry, bridge_id, pair.hub)
	defer project_service.bridge_runtime_registry_destroy(&registry)
	bh := Bridge_Handlers{bridge_runtime_registry = &registry}
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	generation := project_service.bridge_runtime_registry_generation(&registry, bridge_id)
	handled := bridge_ws_process_frame(&bh, bridge_id, generation, pair.hub, &reassemblies, strings.clone(`{"version":1,"kind":"chunk"}`))
	testing.expect(t, !handled, "a rejected chunk closes the connection")

	frame, got := read_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, got, "bridge must receive a protocol_error")
	if !got do return
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"type":"protocol_error"`), frame)
	werr, found := contracts.wire_error_parse(frame, context.temp_allocator)
	testing.expect(t, found, frame)
	testing.expect_value(t, werr.cause, "chunk_rejected")
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.fatal)
}
