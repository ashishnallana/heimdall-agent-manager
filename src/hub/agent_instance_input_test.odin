package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import app "odin_test:hub/app"
import project_service "odin_test:hub/service/project"
import api_http "odin_test:hub/transport/http"

Resize_Mock :: struct {
	call_count: int,
	last_bridge_id: string,
	last_command_id: string,
	last_body_json: string,
}

@(test)
test_agent_instance_input_route_registered_and_dispatches :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-input-unit-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")
	bob := hub_test_user_headers(&graph, "bob")

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

	call_count := 0
	mock_sink := proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		p_count := (^int)(ctx)
		p_count^ += 1
		return true, domain.Domain_Error{}
	}
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&call_count),
		send_runtime_command = mock_sink,
	}

	// Create agent
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agents",
		body = `{"name":"Coder","slug":"coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`,
		request_id = "req_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, agent_res.status == 201, "agent create failed")

	agent_id := ""
	aid_idx := strings.index(agent_res.body, "\"agent_id\":\"")
	if aid_idx >= 0 {
		rest := agent_res.body[aid_idx + len("\"agent_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do agent_id = rest[:end]
	}

	// Enable bridge support
	api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}),
		body = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`,
		request_id = "req_4",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	// Create agent instance
	inst_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = strings.concatenate({`{"agent_id":"`, agent_id, `","bridge_id":"`, bridge_id, `","provider":"claude","model":"claude-sonnet-5-5"}`}),
		request_id = "req_5",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, inst_res.status == 201, "instance create failed")

	inst_id := ""
	iid_idx := strings.index(inst_res.body, "\"agent_instance_id\":\"")
	if iid_idx >= 0 {
		rest := inst_res.body[iid_idx + len("\"agent_instance_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do inst_id = rest[:end]
	}

	input_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/input"})

	// 1. Unauthenticated -> 401
	unauth := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_6",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth.status, 401)

	// 2. Bridge token -> 403
	bridge_hdr := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	br_call := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_7",
		remote_addr = "127.0.0.1",
		headers = bridge_hdr[:],
	})
	testing.expect_value(t, br_call.status, 403)

	// 3. Cross-user (bob) -> 404
	cross := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_8",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	testing.expect_value(t, cross.status, 404)

	// 4. Non-existent instance -> 404
	nonexist := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances/inst_fake/input",
		body = `{"data":"ls -la\n"}`,
		request_id = "req_9",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, nonexist.status, 404)

	// 5. Valid input request -> 200
	call_count = 0
	valid := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_10",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, valid.status, 200)
	testing.expect(t, strings.contains(valid.body, "\"ok\":true"), "body has ok: true")
	testing.expect_value(t, call_count, 1)
}

@(test)
test_agent_instance_resize_route_registered_and_dispatches :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-resize-unit-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")
	bob := hub_test_user_headers(&graph, "bob")

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

	mock_state := Resize_Mock{}
	defer {
		delete(mock_state.last_bridge_id)
		delete(mock_state.last_command_id)
		delete(mock_state.last_body_json)
	}
	mock_sink := proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		p := (^Resize_Mock)(ctx)
		p.call_count += 1
		delete(p.last_bridge_id)
		delete(p.last_command_id)
		delete(p.last_body_json)
		p.last_bridge_id = strings.clone(command.bridge_id)
		p.last_command_id = strings.clone(command.command_id)
		p.last_body_json = strings.clone(command.body_json)
		return true, domain.Domain_Error{}
	}
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&mock_state),
		send_runtime_command = mock_sink,
	}

	// Create agent
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agents",
		body = `{"name":"Coder","slug":"coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`,
		request_id = "req_3",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, agent_res.status == 201, "agent create failed")

	agent_id := ""
	aid_idx := strings.index(agent_res.body, "\"agent_id\":\"")
	if aid_idx >= 0 {
		rest := agent_res.body[aid_idx + len("\"agent_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do agent_id = rest[:end]
	}

	// Enable bridge support
	api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id}),
		body = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`,
		request_id = "req_4",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})

	// Create agent instance
	inst_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = strings.concatenate({`{"agent_id":"`, agent_id, `","bridge_id":"`, bridge_id, `","provider":"claude","model":"claude-sonnet-5-5"}`}),
		request_id = "req_5",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect(t, inst_res.status == 201, "instance create failed")

	inst_id := ""
	iid_idx := strings.index(inst_res.body, "\"agent_instance_id\":\"")
	if iid_idx >= 0 {
		rest := inst_res.body[iid_idx + len("\"agent_instance_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do inst_id = rest[:end]
	}

	resize_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/resize"})
	defer delete(resize_path)

	// 1. Unauthenticated -> 401
	unauth := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":110}`,
		request_id = "req_6",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth.status, 401)

	// 2. Bridge token -> 403
	bridge_hdr := [?]contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_token})}}
	br_call := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":110}`,
		request_id = "req_7",
		remote_addr = "127.0.0.1",
		headers = bridge_hdr[:],
	})
	testing.expect_value(t, br_call.status, 403)

	// 3. Cross-user (bob) -> 404
	cross := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":110}`,
		request_id = "req_8",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	testing.expect_value(t, cross.status, 404)

	// 4. Non-existent instance -> 404
	nonexist := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances/inst_fake/resize",
		body = `{"rows":25,"cols":110}`,
		request_id = "req_9",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, nonexist.status, 404)

	// 5. Invalid rows / cols (rows < 1) -> 400
	bad_rows := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":0,"cols":110}`,
		request_id = "req_10",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, bad_rows.status, 400)

	// 6. Invalid rows / cols (cols < 1) -> 400
	bad_cols := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":0}`,
		request_id = "req_11",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, bad_cols.status, 400)

	// 7. Missing fields -> 400
	empty_body := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{}`,
		request_id = "req_12",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, empty_body.status, 400)

	// 8. Valid resize request -> 200 and dispatches agent_pty_resize
	mock_state.call_count = 0
	valid := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":110}`,
		request_id = "req_13",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, valid.status, 200)
	testing.expect(t, strings.contains(valid.body, "\"ok\":true"), "body has ok: true")
	testing.expect_value(t, mock_state.call_count, 1)
	testing.expect_value(t, mock_state.last_bridge_id, bridge_id)
	testing.expect(t, strings.contains(mock_state.last_body_json, "\"type\":\"shell_pty_resize\"") || strings.contains(mock_state.last_body_json, "\"type\":\"agent_pty_resize\""), "type is shell_pty_resize or agent_pty_resize")
	testing.expect(t, strings.contains(mock_state.last_body_json, "\"rows\":25"), "rows is 25")
	testing.expect(t, strings.contains(mock_state.last_body_json, "\"cols\":110"), "cols is 110")
	expected_inst_sub := strings.concatenate({`"agent_instance_id":"`, inst_id, `"`})
	defer delete(expected_inst_sub)
	testing.expect(t, strings.contains(mock_state.last_body_json, expected_inst_sub), "body contains agent_instance_id")
	expected_shell_sub := strings.concatenate({`"shell_id":"`, inst_id, `"`})
	defer delete(expected_shell_sub)
	testing.expect(t, strings.contains(mock_state.last_body_json, expected_shell_sub), "body contains shell_id")
}
