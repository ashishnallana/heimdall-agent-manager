package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

flush_ws_socket :: proc(browser: net.TCP_Socket) {
	_ = net.set_option(browser, .Receive_Timeout, time.Millisecond * 50)
	buf := make([]byte, 4096)
	defer delete(buf)
	for {
		n, err := net.recv_tcp(browser, buf[:])
		if err != nil || n <= 0 do break
	}
}

drain_matching_ws_event :: proc(browser: net.TCP_Socket, expected_substring: string, timeout := time.Second * 2) -> (string, bool) {
	_ = net.set_option(browser, .Receive_Timeout, time.Millisecond * 200)
	buf := make([]byte, 4096)
	defer delete(buf)
	accum := strings.builder_make()
	defer strings.builder_destroy(&accum)
	start := time.now()
	for time.since(start) < timeout {
		n, err := net.recv_tcp(browser, buf[:])
		if err == nil && n > 0 {
			strings.write_string(&accum, string(buf[:n]))
			combined := strings.to_string(accum)
			if strings.contains(combined, expected_substring) {
				return strings.clone(combined), true
			}
		}
	}
	return strings.clone(strings.to_string(accum)), false
}

@(test)
test_title_mutation_live_events_and_flat_listing :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-title-mutations-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")

	// Setup mock loopback TCP socket for live event bus verification
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, listen_err == nil, "listen_tcp must succeed")
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	testing.expect(t, bound_err == nil, "bound_endpoint must succeed")

	browser, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	testing.expect(t, dial_err == nil, "dial_tcp must succeed")
	defer net.close(browser)

	hub_sock, _, accept_err := net.accept_tcp(listener)
	testing.expect(t, accept_err == nil, "accept_tcp must succeed")
	defer net.close(hub_sock)

	// Register hub_sock to event bus for "alice"
	ws_idx := events.user_ws_add(&graph.event_bus, "alice", hub_sock)
	testing.expect(t, ws_idx >= 0, "user_ws_add must succeed")
	defer events.user_ws_remove(&graph.event_bus, ws_idx)

	// 1. Provision a bridge through the DEVICE FLOW. See device_enroll_support_test.odin
	// for why the old bridge-enrollments + bridges/enroll pair is gone, and for the
	// three requirements (P-256 key shape, hub-derived fingerprint, mandatory S256
	// PKCE) that make this more than two lines.
	//
	// No `defer delete` on these: the helper returns slices into the response
	// bodies, which the router owns, where the deleted code cloned them.
	bridge_id, bridge_token, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")

	b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	if b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}
	project_service.bridge_runtime_registry_mark_live(graph.agents.bridge_runtime_registry, bridge_id, false, "")
	_, _ = iface.bridge_provider_status_upsert(graph.agents.providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present", checked_at = "2026-10-01T00:00:00Z"})
	_, _ = iface.bridge_provider_setting_upsert(graph.agents.providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true, updated_at = "2026-10-01T00:00:00Z"})

	mock_sink := proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		return true, domain.Domain_Error{}
	}
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = nil,
		send_runtime_command = mock_sink,
	}

	// 2. Create Agent
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/agents",
		body        = `{"name":"Coder","slug":"custom-coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`,
		request_id  = "req_tm_3",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect_value(t, agent_res.status, 201)

	agent_id := ""
	if aid_idx := strings.index(agent_res.body, "\"agent_id\":\""); aid_idx >= 0 {
		rest := agent_res.body[aid_idx + len("\"agent_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do agent_id = strings.clone(rest[:end])
	}
	defer delete(agent_id)

	// Enable bridge support
	support_path := strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id})
	defer delete(support_path)
	api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "PATCH",
		path        = support_path,
		body        = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`,
		request_id  = "req_tm_4",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})

	// 3. Create Task Chain 1
	chain1_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/task-chains",
		body        = `{"title":"Chain Alpha"}`,
		request_id  = "req_tm_5",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect_value(t, chain1_res.status, 201)

	chain1_id := ""
	if cid_idx := strings.index(chain1_res.body, "\"chain_id\":\""); cid_idx >= 0 {
		rest := chain1_res.body[cid_idx + len("\"chain_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do chain1_id = strings.clone(rest[:end])
	}
	defer delete(chain1_id)

	// 4. Create Task Chain 2
	chain2_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/task-chains",
		body        = `{"title":"Chain Beta"}`,
		request_id  = "req_tm_6",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect_value(t, chain2_res.status, 201)

	chain2_id := ""
	if cid2_idx := strings.index(chain2_res.body, "\"chain_id\":\""); cid2_idx >= 0 {
		rest := chain2_res.body[cid2_idx + len("\"chain_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do chain2_id = strings.clone(rest[:end])
	}
	defer delete(chain2_id)

	inst_body := strings.concatenate({`{"agent_id":"`, agent_id, `","bridge_id":"`, bridge_id, `","chain_id":"`, chain1_id, `","provider":"claude","model":"claude-sonnet-5-5"}`})
	defer delete(inst_body)
	inst_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/agent-instances",
		body        = inst_body,
		request_id  = "req_tm_7",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect_value(t, inst_res.status, 201)

	inst_id := ""
	if iid_idx := strings.index(inst_res.body, "\"agent_instance_id\":\""); iid_idx >= 0 {
		rest := inst_res.body[iid_idx + len("\"agent_instance_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do inst_id = strings.clone(rest[:end])
	}
	defer delete(inst_id)

	conv_id := ""
	if c_idx := strings.index(inst_res.body, "\"conversation_id\":\""); c_idx >= 0 {
		rest := inst_res.body[c_idx + len("\"conversation_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do conv_id = strings.clone(rest[:end])
	}
	defer delete(conv_id)
	testing.expect(t, conv_id != "", "instance must have conversation_id")

	bridge_auth_val := strings.concatenate({"Bearer ", bridge_token})
	defer delete(bridge_auth_val)
	bridge_auth_headers := [?]contracts.HTTP_Header{
		{name = "Authorization", value = bridge_auth_val},
	}

	// TEST A: agent_action_chain_set_title_handler broadcasts resource_changed (task_chain updated)
	{
		flush_ws_socket(browser)
		seq_before := graph.event_bus.event_seq
		chain_rename_body := strings.concatenate({`{"agent_instance_id":"`, inst_id, `","params":{"chain_id":"`, chain1_id, `","title":"Renamed Chain by Agent"}}`})
		defer delete(chain_rename_body)
		chain_rename_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "POST",
			path        = "/api/v1/agent-actions/chain/set-title",
			body        = chain_rename_body,
			request_id  = "req_tm_act_chain",
			remote_addr = "127.0.0.1",
			headers     = bridge_auth_headers[:],
		})
		testing.expect_value(t, chain_rename_res.status, 200)
		testing.expect(t, graph.event_bus.event_seq > seq_before, "event bus seq must increment on agent chain title rename")

		msg_str, recv_ok := drain_matching_ws_event(browser, `"resource":"task_chain"`)
		defer delete(msg_str)
		testing.expect(t, recv_ok, "TEST A: browser must receive task_chain WebSocket event frame")
		testing.expect(t, strings.contains(msg_str, `"change":"updated"`), "TEST A event must specify change=updated")
		testing.expect(t, strings.contains(msg_str, chain1_id), "TEST A event must contain chain1_id")
	}

	// TEST B: agent_action_conversation_set_title_handler broadcasts resource_changed (conversation updated)
	{
		flush_ws_socket(browser)
		seq_before := graph.event_bus.event_seq
		conv_rename_body := strings.concatenate({`{"agent_instance_id":"`, inst_id, `","params":{"title":"Renamed Conversation by Agent"}}`})
		defer delete(conv_rename_body)
		conv_rename_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "POST",
			path        = "/api/v1/agent-actions/conversation/set-title",
			body        = conv_rename_body,
			request_id  = "req_tm_act_conv",
			remote_addr = "127.0.0.1",
			headers     = bridge_auth_headers[:],
		})
		testing.expect_value(t, conv_rename_res.status, 200)
		testing.expect(t, graph.event_bus.event_seq > seq_before, "event bus seq must increment on agent conversation title rename")

		msg_str, recv_ok := drain_matching_ws_event(browser, `"resource":"conversation"`)
		defer delete(msg_str)
		testing.expect(t, recv_ok, "TEST B: browser must receive conversation WebSocket event frame")
		testing.expect(t, strings.contains(msg_str, `"change":"updated"`), "TEST B event must specify change=updated")
		testing.expect(t, strings.contains(msg_str, conv_id), "TEST B event must contain conversation_id")
	}

	// TEST C: patch_chat_handler broadcasts resource_changed (conversation updated)
	{
		flush_ws_socket(browser)
		seq_before := graph.event_bus.event_seq
		patch_path := strings.concatenate({"/api/v1/chats/", conv_id})
		defer delete(patch_path)
		patch_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "PATCH",
			path        = patch_path,
			body        = `{"title":"Patched Conversation Title by User"}`,
			request_id  = "req_tm_patch_chat",
			remote_addr = "127.0.0.1",
			headers     = alice[:],
		})
		testing.expect_value(t, patch_res.status, 200)
		testing.expect(t, graph.event_bus.event_seq > seq_before, "event bus seq must increment on PATCH /api/v1/chats/*")

		msg_str, recv_ok := drain_matching_ws_event(browser, `"resource":"conversation"`)
		defer delete(msg_str)
		testing.expect(t, recv_ok, "TEST C: browser must receive conversation WebSocket event frame")
		testing.expect(t, strings.contains(msg_str, `"change":"updated"`), "TEST C event must specify change=updated")
		testing.expect(t, strings.contains(msg_str, conv_id), "TEST C event must contain conversation_id")
	}

	// TEST D: GET /api/v1/task-chains?flat=1 returns a flat JSON array without preview capping
	{
		flat_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "GET",
			path        = "/api/v1/task-chains",
			query       = "flat=1",
			request_id  = "req_tm_flat",
			remote_addr = "127.0.0.1",
			headers     = alice[:],
		})
		testing.expect_value(t, flat_res.status, 200)
		testing.expect(t, strings.contains(flat_res.body, "\"data\":[{\"chain_id\":\""), "flat listing must return array of chains directly under data")
		testing.expect(t, strings.contains(flat_res.body, chain1_id), "flat listing must contain chain1")
		testing.expect(t, strings.contains(flat_res.body, chain2_id), "flat listing must contain chain2")
		testing.expect(t, !strings.contains(flat_res.body, "\"chains\":["), "flat listing must not have nested chains array")
	}

	// TEST E: GET /api/v1/task-chains?all=1 also returns flat format
	{
		all_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "GET",
			path        = "/api/v1/task-chains",
			query       = "all=1",
			request_id  = "req_tm_all",
			remote_addr = "127.0.0.1",
			headers     = alice[:],
		})
		testing.expect_value(t, all_res.status, 200)
		testing.expect(t, strings.contains(all_res.body, "\"data\":[{\"chain_id\":\""), "all=1 listing must return flat array of chains")
		testing.expect(t, !strings.contains(all_res.body, "\"chains\":["), "all=1 listing must not have nested chains array")
	}

	// TEST F: GET /api/v1/task-chains (default, without flat) returns project-grouped view
	{
		grouped_res := api_http.router_dispatch(&graph.router, api_http.Request{
			method      = "GET",
			path        = "/api/v1/task-chains",
			request_id  = "req_tm_grouped",
			remote_addr = "127.0.0.1",
			headers     = alice[:],
		})
		testing.expect_value(t, grouped_res.status, 200)
		testing.expect(t, strings.contains(grouped_res.body, "\"project_id\":"), "grouped listing must contain project_id")
		testing.expect(t, strings.contains(grouped_res.body, "\"chains\":["), "grouped listing must contain nested chains array")
	}
}
