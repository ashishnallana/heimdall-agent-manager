package http

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import shell_service "odin_test:hub/service/shell_session"
import user_service "odin_test:hub/service/user"
import platform "odin_test:hub/platform"

@(test)
test_pty_plan_user_identity_exempts_agent_automation :: proc(t: ^testing.T) {
	for kind in ([]contracts.Auth_Kind{.User_Token, .Trusted_Proxy}) {
		testing.expect_value(t, pty_stream_user_id({kind = kind, user_id = "owner"}), "owner")
	}
	for kind in ([]contracts.Auth_Kind{.Instance_Token, .Bridge_Token}) {
		testing.expect_value(t, pty_stream_user_id({kind = kind, user_id = "owner"}), "")
	}
}

pty_plan_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	return {max_concurrent_streams = (^int)(ctx)^}, {}
}

pty_plan_agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	return {agent_instance_id = strings.clone(id), owner_user_id = "owner", bridge_id = strings.clone("bridge")}, true, {}
}

pty_plan_shell_get :: proc(ctx: rawptr, owner, id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return {session_id = strings.clone(id), owner_user_id = strings.clone("owner"), bridge_id = strings.clone("bridge")}, true, {}
}

pty_plan_pair :: proc(t: ^testing.T) -> (hub, peer: net.TCP_Socket) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil do testing.fail_now(t, "listen failed")
	defer net.close(listener)
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil do testing.fail_now(t, "bound endpoint failed")
	peer, err = net.dial_tcp(bound)
	if err != nil do testing.fail_now(t, "dial failed")
	hub, _, err = net.accept_tcp(listener)
	if err != nil do testing.fail_now(t, "accept failed")
	return
}

@(test)
test_pty_plan_both_stream_routes_refuse_with_error_and_4402 :: proc(t: ^testing.T) {
	limit := 2
	svc := shell_service.new_shell_session_service()
	defer shell_service.shell_session_service_free(&svc)
	svc.entitlements = {ctx = &limit, lookup = pty_plan_lookup}
	first, first_peer := pty_plan_pair(t)
	defer net.close(first)
	defer net.close(first_peer)
	second, second_peer := pty_plan_pair(t)
	defer net.close(second)
	defer net.close(second_peer)
	_ = shell_service.shell_session_attach(&svc, "existing-agent", first, user_id = "owner")
	_ = shell_service.shell_session_attach(&svc, "existing-shell", second, user_id = "owner")

	agent_repo := iface.Agent_Repository{get_instance = pty_plan_agent_get}
	agents := agent_service.new_agent_service(&agent_repo, nil, nil, nil)
	shell_repo := iface.Shell_Session_Repository{get = pty_plan_shell_get}
	experiments := iface.Experiment_Repository{list_by_owner = proc(ctx: rawptr, owner: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
		return make([dynamic]domain.Experiment), {}
	}}
	tickets := new_user_ws_ticket_store()
	defer user_ws_ticket_store_free(&tickets)
	agent_h := Agent_Handlers{ws_tickets = &tickets, experiments = &experiments, agents = &agents, shell_sessions = &svc}
	shell_h := Shell_Session_Stream_Handlers{ws_tickets = &tickets, experiments = &experiments, shell_repo = &shell_repo, shell_sessions = &svc}
	for agent_route in ([]bool{true, false}) {
		hub, peer := pty_plan_pair(t)
		defer net.close(hub)
		defer net.close(peer)
		user_ws_ticket_store_put(&tickets, "plan-ticket", {kind = .User_Token, user_id = "owner"}, 60)
		req := Request{method = "GET", path = "/api/v1/shells/new-shell/stream", query = "ticket=plan-ticket",
			headers = []contracts.HTTP_Header{{name = "Sec-WebSocket-Key", value = "dGhlIHNhbXBsZSBub25jZQ=="}}}
		if agent_route {
			req.path = "/api/v1/agent-instances/new-agent/stream"
			agent_instance_stream_handler(&agent_h, req, hub)
		} else {
			shell_session_stream_handler(&shell_h, req, hub)
		}
		// Both frames are already written; read until the private close frame arrives.
		_ = net.set_option(peer, .Receive_Timeout, time.Second)
		data := make([dynamic]byte)
		defer delete(data)
		buf: [4096]byte
		for !strings.contains(string(data[:]), "\x88\x02\x11\x32") {
			n, err := net.recv_tcp(peer, buf[:])
			if err != nil || n <= 0 do break
			append(&data, ..buf[:n])
		}
		testing.expect(t, strings.contains(string(data[:]), "101 Switching Protocols"))
		testing.expect(t, strings.contains(string(data[:]), `"code":"plan_limit_reached"`))
		testing.expect(t, strings.contains(string(data[:]), `"limit":"max_concurrent_streams"`))
		testing.expect(t, strings.contains(string(data[:]), `"current":2`))
		testing.expect(t, strings.contains(string(data[:]), "\x88\x02\x11\x32"), "must close with 4402")
		testing.expect(t, !strings.contains(string(data[:]), `"type":"ready"`))
		testing.expect_value(t, len(svc.viewer_writers), 2)
		testing.expect_value(t, svc.user_viewer_counts["owner"], 2)
	}
}

@(test)
test_pty_plan_pane_routes_share_budget_and_return_retry_after :: proc(t: ^testing.T) {
	limit := 2
	svc := shell_service.new_shell_session_service()
	defer shell_service.shell_session_service_free(&svc)
	svc.entitlements = {ctx = &limit, lookup = pty_plan_lookup}
	svc.pane_poll_now = proc(ctx: rawptr) -> time.Tick { return {} }
	user_repo := iface.User_Repository{get_by_id = proc(ctx: rawptr, id: domain.User_ID) -> (domain.User, bool, domain.Domain_Error) {
		return {user_id = id, name = string(id), status = .Active}, true, {}
	}}
	clock := platform.real_clock()
	ids := http_test_id_generator()
	users := user_service.new_user_service_basic(&user_repo, &clock, &ids)
	auth := auth_service.new_auth_service({username_header = "X-User", trusted_proxy_cidrs = []string{"127.0.0.1/32"}}, &users)
	agent_repo := iface.Agent_Repository{get_instance = pty_plan_agent_get}
	agents := agent_service.new_agent_service(&agent_repo, nil, nil, nil)
	agent_h := Agent_Handlers{auth = &auth, agents = &agents, shell_sessions = &svc}
	shell_h := Shell_Session_Rest_Handlers{auth = &auth, shell_sessions = &svc}
	// These admitted requests stop at the missing bridge sink. Each route must still
	// consume its shared capture allowance, so neither can bypass the other.
	for i in 0..<4 {
		req := Request{method = "GET", path = "/api/v1/shells/new-shell/pane", remote_addr = "127.0.0.1:1000",
			headers = []contracts.HTTP_Header{{name = "X-User", value = "owner"}}}
		resp: Response
		if i % 2 == 0 {
			req.path = "/api/v1/agent-instances/new-agent/pane"
			resp = get_agent_instance_pane_handler(&agent_h, req)
		} else {
			resp = shell_session_pane_handler(&shell_h, req)
		}
		if i >= 2 {
			testing.expect_value(t, resp.status, 429)
			testing.expect(t, strings.contains(resp.body, `"code":"rate_limited"`))
			testing.expect_value(t, header_value(resp.headers, "Retry-After"), "1")
		} else {
			testing.expect(t, resp.status != 429 && resp.status != 402)
		}
		delete(resp.body)
	}
	limit = 0
	for agent_route in ([]bool{true, false}) {
		req := Request{method = "GET", path = "/api/v1/shells/new-shell/pane", remote_addr = "127.0.0.1:1000",
			headers = []contracts.HTTP_Header{{name = "X-User", value = "owner"}}}
		resp: Response
		if agent_route {
			req.path = "/api/v1/agent-instances/new-agent/pane"
			resp = get_agent_instance_pane_handler(&agent_h, req)
		} else {
			resp = shell_session_pane_handler(&shell_h, req)
		}
		testing.expect_value(t, resp.status, 402)
		testing.expect(t, strings.contains(resp.body, `"limit":"max_concurrent_streams"`))
		delete(resp.body)
	}
}
