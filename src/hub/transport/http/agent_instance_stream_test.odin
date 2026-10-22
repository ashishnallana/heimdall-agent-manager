package http

import "core:encoding/base64"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

// Loopback socket pair for testing WebSocket endpoints
@(private = "file")
Agent_Stream_Sock_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
make_agent_stream_pair :: proc(t: ^testing.T) -> (Agent_Stream_Sock_Pair, bool) {
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
	return Agent_Stream_Sock_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
close_agent_stream_pair :: proc(p: ^Agent_Stream_Sock_Pair) {
	net.close(p.hub)
	net.close(p.client)
	net.close(p.listener)
}

// Read raw response string until timeout
@(private = "file")
read_agent_raw_response :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
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

// read_agent_server_stream_frame reads one unmasked text frame sent from Hub to client
@(private = "file")
read_agent_server_stream_frame :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
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
			for i := 0; i + 3 < len(acc); i += 1 {
				if acc[i] == '\r' && acc[i + 1] == '\n' && acc[i + 2] == '\r' && acc[i + 3] == '\n' {
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

// Fake experiment repository for agent streaming tests
@(private = "file")
Fake_Agent_Experiments :: struct {
	streaming_enabled: bool,
}

@(private = "file")
fake_agent_experiment_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	f := (^Fake_Agent_Experiments)(ctx)
	out := make([dynamic]domain.Experiment)
	append(&out, domain.Experiment{
		owner_user_id = strings.clone(owner_user_id),
		key           = strings.clone(domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY),
		enabled       = f.streaming_enabled,
		updated_at    = strings.clone("2026-09-27T01:00:00Z"),
	})
	return out, domain.Domain_Error{}
}

// Fake agent repository for tests
@(private = "file")
Fake_Agent_Repo :: struct {
	instance: domain.Agent_Instance,
}

@(private = "file")
clone_agent_instance_helper :: proc(s: domain.Agent_Instance) -> domain.Agent_Instance {
	return domain.Agent_Instance{
		agent_instance_id = strings.clone(s.agent_instance_id),
		owner_user_id     = s.owner_user_id,
		agent_id          = strings.clone(s.agent_id),
		bridge_id         = strings.clone(s.bridge_id),
		display_name      = strings.clone(s.display_name),
		provider          = strings.clone(s.provider),
		model              = strings.clone(s.model),
		project_id        = s.project_id,
		chain_id          = strings.clone(s.chain_id),
		conversation_id   = strings.clone(s.conversation_id),
		runtime_status    = strings.clone(s.runtime_status),
		startup_status    = strings.clone(s.startup_status),
		activity_status   = strings.clone(s.activity_status),
		status_message    = strings.clone(s.status_message),
		last_applied_seq  = s.last_applied_seq,
		run_count         = s.run_count,
		current_task_id   = strings.clone(s.current_task_id),
		current_task_role = s.current_task_role,
		created_at        = strings.clone(s.created_at),
		updated_at        = strings.clone(s.updated_at),
		started_at        = strings.clone(s.started_at),
	}
}

@(private = "file")
fake_agent_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Fake_Agent_Repo)(ctx)
	if f.instance.agent_instance_id == instance_id {
		return clone_agent_instance_helper(f.instance), true, domain.Domain_Error{}
	}
	return domain.Agent_Instance{}, false, domain.Domain_Error{}
}

// Mock bridge command sink to capture dispatched commands
@(private = "file")
Agent_Mock_Command_Sink_State :: struct {
	mu:        sync.Mutex,
	allocator: mem.Allocator,
	commands:  [dynamic]project_service.Runtime_Command,
}

@(private = "file")
agent_mock_send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	st := (^Agent_Mock_Command_Sink_State)(ctx)
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
Agent_Stream_Handler_Runner :: struct {
	h:        ^Agent_Handlers,
	req:      Request,
	sock:     net.TCP_Socket,
	finished: bool,
}

@(private = "file")
run_agent_stream_handler_thread :: proc(data: rawptr) {
	r := (^Agent_Stream_Handler_Runner)(data)
	agent_instance_stream_handler(rawptr(r.h), r.req, r.sock)
	r.finished = true
}

// -----------------------------------------------------------------------------
// Test 1: Ticket authentication & experiment flag gating
// -----------------------------------------------------------------------------
@(test)
test_agent_instance_stream_ticket_and_experiment_gating :: proc(t: ^testing.T) {
	// 1a. Missing ticket -> 401
	{
		pair, ok := make_agent_stream_pair(t)
		testing.expect(t, ok)
		defer close_agent_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)

		h := Agent_Handlers{
			ws_tickets = &tickets,
		}

		agent_instance_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/agent-instances/inst_test/stream", query = "", request_id = "req_1",
		}, pair.hub)

		resp, r_ok := read_agent_raw_response(pair.client, 2 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "401 Unauthorized"), "missing ticket must return 401")
		delete(resp)
	}

	// 1b. Invalid ticket -> 401
	{
		pair, ok := make_agent_stream_pair(t)
		testing.expect(t, ok)
		defer close_agent_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)

		h := Agent_Handlers{
			ws_tickets = &tickets,
		}

		agent_instance_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/agent-instances/inst_test/stream", query = "ticket=invalid_ticket", request_id = "req_2",
		}, pair.hub)

		resp, r_ok := read_agent_raw_response(pair.client, 2 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "401 Unauthorized"), "invalid ticket must return 401")
		delete(resp)
	}

	// 1c. Experiment disabled -> 403 Forbidden
	{
		pair, ok := make_agent_stream_pair(t)
		testing.expect(t, ok)
		defer close_agent_stream_pair(&pair)

		tickets := new_user_ws_ticket_store()
		defer user_ws_ticket_store_free(&tickets)
		user_ws_ticket_store_put(&tickets, "ticket_exp_test", contracts.Auth_Context{
			user_id = "user_42",
			kind    = .User_Token,
		}, 60)

		exp_state := Fake_Agent_Experiments{streaming_enabled = false}
		exp_repo := iface.Experiment_Repository{
			ctx = rawptr(&exp_state),
			list_by_owner = fake_agent_experiment_list,
		}

		h := Agent_Handlers{
			ws_tickets  = &tickets,
			experiments = &exp_repo,
		}

		agent_instance_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/agent-instances/inst_test/stream", query = "ticket=ticket_exp_test", request_id = "req_3",
		}, pair.hub)

		resp, r_ok := read_agent_raw_response(pair.client, 2 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "403 Forbidden"), "disabled experiment must return 403")
		delete(resp)
	}
}

// -----------------------------------------------------------------------------
// Test 2: Agent Instance validation & permissions
// -----------------------------------------------------------------------------
@(test)
test_agent_instance_stream_validation_and_permissions :: proc(t: ^testing.T) {
	pair, ok := make_agent_stream_pair(t)
	testing.expect(t, ok)
	defer close_agent_stream_pair(&pair)

	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)

	exp_state := Fake_Agent_Experiments{streaming_enabled = true}
	exp_repo := iface.Experiment_Repository{
		ctx = rawptr(&exp_state),
		list_by_owner = fake_agent_experiment_list,
	}

	agent_state := Fake_Agent_Repo{
		instance = domain.Agent_Instance{
			agent_instance_id = "inst_valid",
			owner_user_id     = domain.User_ID("user_alice"),
			bridge_id         = "brg_1",
			runtime_status    = "running",
		},
	}
	agent_repo := iface.Agent_Repository{
		ctx = rawptr(&agent_state),
		get_instance = fake_agent_get_instance,
	}

	clock := platform.real_clock()
	ids := http_test_id_generator()
	ag_svc := agent_service.new_agent_service(&agent_repo, nil, &clock, &ids)

	h := Agent_Handlers{
		ws_tickets  = &tickets,
		experiments = &exp_repo,
		agents      = &ag_svc,
	}

	// 2a. Instance not found -> 404
	{
		user_ws_ticket_store_put(&tickets, "ticket_alice", contracts.Auth_Context{user_id = "user_alice", kind = .User_Token}, 60)

		agent_instance_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/agent-instances/inst_unknown/stream", query = "ticket=ticket_alice", request_id = "req_4",
		}, pair.hub)

		resp, r_ok := read_agent_raw_response(pair.client, 2 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "404 Not Found"), "unknown instance must return 404")
		delete(resp)
	}

	// 2b. Forbidden (different owner) -> 403
	{
		pair2, ok2 := make_agent_stream_pair(t)
		testing.expect(t, ok2)
		defer close_agent_stream_pair(&pair2)

		user_ws_ticket_store_put(&tickets, "ticket_bob", contracts.Auth_Context{user_id = "user_bob", kind = .User_Token}, 60)

		agent_instance_stream_handler(rawptr(&h), Request{
			method = "GET", path = "/api/v1/agent-instances/inst_valid/stream", query = "ticket=ticket_bob", request_id = "req_5",
		}, pair2.hub)

		resp, r_ok := read_agent_raw_response(pair2.client, 2 * time.Second)
		testing.expect(t, r_ok)
		testing.expect(t, strings.contains(resp, "403 Forbidden"), "non-owner must return 403")
		delete(resp)
	}
}

// -----------------------------------------------------------------------------
// Test 3: WebSocket handshake & ready frame
// -----------------------------------------------------------------------------
@(test)
test_agent_instance_stream_handshake_and_ready_frame :: proc(t: ^testing.T) {
	agent_stream_check_input_policy(t, false)
}

@(test)
test_agent_stream_read_only_input_resize_and_snapshot :: proc(t: ^testing.T) {
	agent_stream_check_input_policy(t, true)
}

@(private = "file")
agent_stream_check_input_policy :: proc(t: ^testing.T, read_only: bool) {
	pair, ok := make_agent_stream_pair(t)
	testing.expect(t, ok)
	defer close_agent_stream_pair(&pair)

	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)

	exp_state := Fake_Agent_Experiments{streaming_enabled = true}
	exp_repo := iface.Experiment_Repository{
		ctx = rawptr(&exp_state),
		list_by_owner = fake_agent_experiment_list,
	}

	agent_state := Fake_Agent_Repo{
		instance = domain.Agent_Instance{
			agent_instance_id = "inst_handshake",
			owner_user_id     = domain.User_ID("user_alice"),
			bridge_id         = "brg_hs",
			runtime_status    = "",
		},
	}
	agent_repo := iface.Agent_Repository{
		ctx = rawptr(&agent_state),
		get_instance = fake_agent_get_instance,
	}

	sink_state := Agent_Mock_Command_Sink_State{allocator = context.allocator}
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
		send_runtime_command = agent_mock_send_runtime_command,
	}

	clock := platform.real_clock()
	ids := http_test_id_generator()
	ag_svc := agent_service.new_agent_service_with_runtime(&agent_repo, nil, nil, nil, nil, mock_sink, nil, &clock, &ids)

	shell_svc := shell_session_svc.new_shell_session_service(repo = nil, bridge_command_sink = mock_sink, event_bus = nil, ids = &ids, clock = &clock)
	defer shell_session_svc.shell_session_service_free(&shell_svc)

	h := Agent_Handlers{
		ws_tickets     = &tickets,
		experiments    = &exp_repo,
		agents         = &ag_svc,
		shell_sessions = &shell_svc,
	}

	h.entitlements = {lookup = plan_test_paid_lookup}
	if read_only do h.entitlements = {lookup = plan_test_read_only_lookup}

	user_ws_ticket_store_put(&tickets, "ticket_hs", contracts.Auth_Context{user_id = "user_alice", kind = .User_Token}, 60)

	headers := make([dynamic]contracts.HTTP_Header)
	defer delete(headers)
	append(&headers, contracts.HTTP_Header{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="})

	runner := Agent_Stream_Handler_Runner{
		h = &h,
		req = Request{
			method = "GET", path = "/api/v1/agent-instances/inst_handshake/stream", query = "ticket=ticket_hs", headers = headers[:], request_id = "req_hs",
		},
		sock = pair.hub,
	}

	th := thread.create_and_start_with_data(rawptr(&runner), run_agent_stream_handler_thread)
	defer {
		net.close(pair.client); pair.client = net.TCP_Socket(0)
		thread.join(th)
		thread.destroy(th)
		testing.expect_value(t, shell_svc.user_viewer_counts["user_alice"], 0, "disconnect releases the user's stream slot")
	}

	// Read HTTP 101 Switching Protocols response and ready frame
	frame, f_ok := read_agent_server_stream_frame(pair.client, 2 * time.Second)
	testing.expect(t, f_ok, "client must receive ready frame")
	testing.expect(t, strings.contains(frame, `"type":"ready"`), "frame type is ready")
	testing.expect(t, strings.contains(frame, `"agent_instance_id":"inst_handshake"`), "frame contains agent_instance_id")
	testing.expect(t, strings.contains(frame, "\"read_only\":true" if read_only else "\"read_only\":false"))
	delete(frame)

	sync.mutex_lock(&shell_svc.mu)
	testing.expect_value(t, shell_svc.user_viewer_counts["user_alice"], 1)
	sync.mutex_unlock(&shell_svc.mu)

	if read_only {
		shell_session_svc.shell_session_broadcast_output(&shell_svc, "inst_handshake", transmute([]byte)string("live output"))
		output_reader := bridge_ws_reader_make(pair.client)
		output, got_output, _ := bridge_ws_read_frame(&output_reader, 5 * time.Second)
		testing.expect(t, got_output, "read-only viewers receive live output")
		if got_output {
			kind, _, payload, _, _, valid := contracts.pty_wire_decode_viewer_frame(transmute([]byte)output)
			testing.expect(t, valid && kind == contracts.PTY_WIRE_KIND_OUTPUT)
			testing.expect_value(t, string(payload), "live output")
			delete(output)
		}
		bridge_ws_reader_destroy(&output_reader)
		screen := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_SCREEN, 0, transmute([]byte)string("cached screen"))
		shell_session_svc.shell_session_snapshot_cache_store_capture(&shell_svc, "inst_handshake", [][]byte{screen}, 80, 24, net.TCP_Socket(0))
		delete(screen)
		for flags in ([]u8{0, contracts.PTY_WIRE_FLAG_ENCRYPTED}) {
			input := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_INPUT, flags, transmute([]byte)string("keystrokes"))
			_ = ws.write_server_opcode(pair.client, 0x2, string(input), false)
			delete(input)
		}
		_ = write_ws_text_frame(pair.client, "{\"type\":\"resize\",\"rows\":24,\"cols\":80}")
		reader := bridge_ws_reader_make(pair.client)
		reply, got, _ := bridge_ws_read_frame(&reader, 5 * time.Second)
		testing.expect(t, got, "read-only first resize still serves a snapshot")
		if got {
			kind, _, payload, _, _, valid := contracts.pty_wire_decode_viewer_frame(transmute([]byte)reply)
			testing.expect(t, valid && kind == contracts.PTY_WIRE_KIND_SCREEN)
			testing.expect_value(t, string(payload), "cached screen")
			delete(reply)
		}
		bridge_ws_reader_destroy(&reader)
	}

	// Verify that shell_stream_attach was dispatched to bridge
	sync.mutex_lock(&sink_state.mu)
	testing.expect_value(t, len(sink_state.commands), 1)
	if len(sink_state.commands) > 0 {
		cmd := sink_state.commands[0]
		testing.expect_value(t, cmd.bridge_id, "brg_hs")
		testing.expect(t, strings.contains(cmd.body_json, `"type":"shell_stream_attach"`), "dispatches shell_stream_attach")
		testing.expect(t, strings.contains(cmd.body_json, `"session_id":"inst_handshake"`), "session_id is inst_handshake")
	}
	sync.mutex_unlock(&sink_state.mu)
}
