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

@(test)
test_bridge_shell_input_and_resize_routes :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-bridge-shell-unit-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bob := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "bob"}}

	// 1. Provision a bridge for alice.
	// Bridge provisioned through the DEVICE FLOW. See device_enroll_support_test.odin
	// for why the old bridge-enrollments + bridges/enroll pair is gone, and for the
	// three requirements (P-256 key shape, hub-derived fingerprint, mandatory S256
	// PKCE) that make this more than two lines.
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
	last_command: project_service.Runtime_Command
	mock_sink := proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		p_data := (^struct {
			count: ^int,
			cmd:   ^project_service.Runtime_Command,
		})(ctx)
		p_data.count^ += 1
		if p_data.cmd.bridge_id != "" do delete(p_data.cmd.bridge_id)
		if p_data.cmd.command_id != "" do delete(p_data.cmd.command_id)
		if p_data.cmd.body_json != "" do delete(p_data.cmd.body_json)
		p_data.cmd.bridge_id = strings.clone(command.bridge_id)
		p_data.cmd.command_id = strings.clone(command.command_id)
		p_data.cmd.body_json = strings.clone(command.body_json)
		return true, domain.Domain_Error{}
	}
	mock_data := struct {
		count: ^int,
		cmd:   ^project_service.Runtime_Command,
	}{
		count = &call_count,
		cmd   = &last_command,
	}
	graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&mock_data),
		send_runtime_command = mock_sink,
	}
	graph.bridges.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&mock_data),
		send_runtime_command = mock_sink,
	}

	shell_id := "sh_custom_test_1"
	input_path := fmt.tprintf("/api/v1/bridges/%s/shells/%s/input", bridge_id, shell_id)
	resize_path := fmt.tprintf("/api/v1/bridges/%s/shells/%s/resize", bridge_id, shell_id)

	// --- INPUT ENDPOINT TESTS ---
	// 1. Unauthenticated -> 401
	unauth_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"hello\n"}`,
		request_id = "req_in_1",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth_input.status, 401)

	// 2. Bridge token -> 403
	bridge_bearer := fmt.tprintf("Bearer %s", bridge_token)
	bridge_hdr := [?]contracts.HTTP_Header{{name = "Authorization", value = bridge_bearer}}
	br_call_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"hello\n"}`,
		request_id = "req_in_2",
		remote_addr = "127.0.0.1",
		headers = bridge_hdr[:],
	})
	testing.expect_value(t, br_call_input.status, 403)

	// 3. Cross-user (bob) -> 404
	cross_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"hello\n"}`,
		request_id = "req_in_3",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	testing.expect_value(t, cross_input.status, 404)

	// 4. Non-existent bridge -> 404
	nonexist_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/brg_nonexistent/shells/sh_1/input",
		body = `{"data":"hello\n"}`,
		request_id = "req_in_4",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, nonexist_input.status, 404)

	// 5. Valid input request -> 200 & dispatches shell_pty_input
	call_count = 0
	valid_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"ls -la\n"}`,
		request_id = "req_in_5",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, valid_input.status, 200)
	testing.expect(t, strings.contains(valid_input.body, "\"ok\":true"), "body has ok: true")
	testing.expect_value(t, call_count, 1)
	testing.expect_value(t, last_command.bridge_id, bridge_id)
	testing.expect(t, strings.contains(last_command.body_json, "\"type\":\"shell_pty_input\""), "type must be shell_pty_input")
	testing.expect(t, strings.contains(last_command.body_json, fmt.tprintf("\"shell_id\":\"%s\"", shell_id)), "must contain shell_id")
	testing.expect(t, strings.contains(last_command.body_json, "\"data_b64\":\"bHMgLWxhCg==\""), "must contain base64-encoded data")
	testing.expect(t, strings.contains(last_command.body_json, "\"is_encrypted\":false"), "must mark unencrypted input")

	// 6. Input with control characters (Ctrl+C)
	call_count = 0
	ctrl_c_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"\u0003"}`,
		request_id = "req_in_6",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, ctrl_c_input.status, 200)
	testing.expect_value(t, call_count, 1)
	testing.expect(t, strings.contains(last_command.body_json, "\"data_b64\":\"Aw==\""), "must preserve base64-encoded control characters")

	// 6b. Input with enc_b64
	call_count = 0
	enc_input := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = input_path,
		body = `{"data":"","enc_b64":"dmF1bHQ6djE6dGVzdA=="}`,
		request_id = "req_in_6b",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, enc_input.status, 200)
	testing.expect_value(t, call_count, 1)
	testing.expect(t, strings.contains(last_command.body_json, "\"data_b64\":\"dmF1bHQ6djE6dGVzdA==\""), "must forward encrypted payload as data_b64")
	testing.expect(t, strings.contains(last_command.body_json, "\"is_encrypted\":true"), "must set is_encrypted true")

	// --- RESIZE ENDPOINT TESTS ---
	// 7. Unauthenticated -> 401
	unauth_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":80}`,
		request_id = "req_res_1",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth_resize.status, 401)

	// 8. Bridge token -> 403
	br_call_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":80}`,
		request_id = "req_res_2",
		remote_addr = "127.0.0.1",
		headers = bridge_hdr[:],
	})
	testing.expect_value(t, br_call_resize.status, 403)

	// 9. Cross-user (bob) -> 404
	cross_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":80}`,
		request_id = "req_res_3",
		remote_addr = "127.0.0.1",
		headers = bob[:],
	})
	testing.expect_value(t, cross_resize.status, 404)

	// 10. Non-existent bridge -> 404
	nonexist_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/bridges/brg_nonexistent/shells/sh_1/resize",
		body = `{"rows":25,"cols":80}`,
		request_id = "req_res_4",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, nonexist_resize.status, 404)

	// 11. Invalid rows (< 1) -> 400
	bad_rows := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":0,"cols":80}`,
		request_id = "req_res_5",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, bad_rows.status, 400)

	// 12. Invalid cols (< 1) -> 400
	bad_cols := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":25,"cols":0}`,
		request_id = "req_res_6",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, bad_cols.status, 400)

	// 13. Valid resize request -> 200 & dispatches shell_pty_resize
	call_count = 0
	valid_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":30,"cols":120}`,
		request_id = "req_res_7",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, valid_resize.status, 200)
	testing.expect(t, strings.contains(valid_resize.body, "\"ok\":true"), "body has ok: true")
	testing.expect_value(t, call_count, 1)
	testing.expect_value(t, last_command.bridge_id, bridge_id)
	testing.expect(t, strings.contains(last_command.body_json, "\"type\":\"shell_pty_resize\""), "type must be shell_pty_resize")
	testing.expect(t, strings.contains(last_command.body_json, fmt.tprintf("\"shell_id\":\"%s\"", shell_id)), "must contain shell_id")
	testing.expect(t, strings.contains(last_command.body_json, "\"rows\":30"), "must contain rows:30")
	testing.expect(t, strings.contains(last_command.body_json, "\"cols\":120"), "must contain cols:120")

	// 14. String numbers in resize request
	call_count = 0
	str_resize := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = resize_path,
		body = `{"rows":"40","cols":"100"}`,
		request_id = "req_res_8",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, str_resize.status, 200)
	testing.expect_value(t, call_count, 1)
	testing.expect(t, strings.contains(last_command.body_json, "\"rows\":40"), "must parse string rows to 40")
	testing.expect(t, strings.contains(last_command.body_json, "\"cols\":100"), "must parse string cols to 100")

	// --- AGENT INSTANCE ENDPOINT FORWARDING (AC-3) ---
	// Create an agent for alice
	agent_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agents",
		body = `{"name":"Coder Agent","slug":"coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`,
		request_id = "req_agent",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, agent_res.status, 201)
	agent_id := ""
	aid_idx := strings.index(agent_res.body, "\"agent_id\":\"")
	if aid_idx >= 0 {
		rest := agent_res.body[aid_idx + len("\"agent_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do agent_id = strings.clone(rest[:end])
	}
	defer if agent_id != "" do delete(agent_id)

	// Enable bridge support for agent
	support_path := strings.concatenate({"/api/v1/agents/", agent_id, "/bridge-support/", bridge_id})
	defer delete(support_path)
	support_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "PATCH",
		path = support_path,
		body = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`,
		request_id = "req_supp",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, support_res.status, 200)

	// Create an agent instance
	inst_body := strings.concatenate({"{\"agent_id\":\"", agent_id, "\",\"bridge_id\":\"", bridge_id, "\",\"provider\":\"claude\",\"model\":\"claude-sonnet-5-5\"}"})
	defer delete(inst_body)
	inst_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = "/api/v1/agent-instances",
		body = inst_body,
		request_id = "req_inst",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, inst_res.status, 201)
	inst_id := ""
	iid_idx := strings.index(inst_res.body, "\"agent_instance_id\":\"")
	if iid_idx >= 0 {
		rest := inst_res.body[iid_idx + len("\"agent_instance_id\":\""):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do inst_id = strings.clone(rest[:end])
	}
	defer if inst_id != "" do delete(inst_id)

	// Verify POST /api/v1/agent-instances/{id}/input forwards with shell_id = agent_instance_id
	call_count = 0
	ai_input_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/input"})
	defer delete(ai_input_path)
	ai_input_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = ai_input_path,
		body = `{"data":"git status\n"}`,
		request_id = "req_ai_in",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, ai_input_res.status, 200)
	testing.expect_value(t, call_count, 1)
	testing.expect_value(t, last_command.bridge_id, bridge_id)
	testing.expect(t, strings.contains(last_command.body_json, fmt.tprintf("\"shell_id\":\"%s\"", inst_id)), "agent instance input must forward shell_id = agent_instance_id")
	testing.expect(t, strings.contains(last_command.body_json, "\"data_b64\":\"Z2l0IHN0YXR1cwo=\""), "agent instance input must pass base64 data")

	// Verify POST /api/v1/agent-instances/{id}/resize forwards with shell_id = agent_instance_id
	call_count = 0
	ai_resize_path := strings.concatenate({"/api/v1/agent-instances/", inst_id, "/resize"})
	defer delete(ai_resize_path)
	ai_resize_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST",
		path = ai_resize_path,
		body = `{"rows":45,"cols":140}`,
		request_id = "req_ai_res",
		remote_addr = "127.0.0.1",
		headers = alice[:],
	})
	testing.expect_value(t, ai_resize_res.status, 200)
	testing.expect_value(t, call_count, 1)
	testing.expect_value(t, last_command.bridge_id, bridge_id)
	testing.expect(t, strings.contains(last_command.body_json, fmt.tprintf("\"shell_id\":\"%s\"", inst_id)), "agent instance resize must forward shell_id = agent_instance_id")
	testing.expect(t, strings.contains(last_command.body_json, "\"rows\":45"), "agent instance resize must pass rows")
	testing.expect(t, strings.contains(last_command.body_json, "\"cols\":140"), "agent instance resize must pass cols")

	if last_command.bridge_id != "" do delete(last_command.bridge_id)
	if last_command.command_id != "" do delete(last_command.command_id)
	if last_command.body_json != "" do delete(last_command.body_json)
}

@(private = "file")
T10_Route_Sink :: struct {
	reply: string,
	waits: int,
}

// T10 (REQ-T10-2): a REST keystroke into a pane on a LOCKED bridge answers HTTP 423
// {error:{code:"vault_locked", details:{bridge_id}}} instead of a silent 200; any other
// bridge outcome keeps the pre-T10 200.
@(test)
test_bridge_shell_input_on_locked_bridge_returns_423 :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-t10-vault-locked-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs[:],
		auto_provision_users = true,
		logout_url = "/_dev/logout",
		paddle_environment = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}
	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	if !enroll_ok do return
	if b, b_ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id); b_ok {
		b.status = .Online
		_, _, _ = iface.bridge_save_bridge(graph.bridges.repo, b)
	}

	state := T10_Route_Sink{reply = `{"type":"command_result","protocol_version":1,"command_id":"x","ok":false,"error":{"code":"vault_locked","class":"recoverable","cause":"vault_locked","message":""},"payload":{"status":"failed"}}`}
	graph.bridges.bridge_command_sink = project_service.Bridge_Command_Sink{
		ctx = rawptr(&state),
		send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			return true, {}
		},
		send_runtime_command_wait = proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
			s := (^T10_Route_Sink)(ctx)
			s.waits += 1
			return strings.clone(s.reply), true, {}
		},
	}

	path := fmt.tprintf("/api/v1/bridges/%s/shells/sh_t10/input", bridge_id)
	locked := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = path, body = `{"enc_b64":"vault:v1:AAAA"}`,
		request_id = "req_t10_locked", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, locked.status, 423)
	testing.expect(t, strings.contains(locked.body, `"code":"vault_locked"`), locked.body)
	testing.expect(t, strings.contains(locked.body, fmt.tprintf(`"bridge_id":"%s"`, bridge_id)), locked.body)
	testing.expect_value(t, state.waits, 1)

	state.reply = `{"type":"command_result","protocol_version":1,"command_id":"x","payload":{"status":"succeeded"}}`
	delivered := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = path, body = `{"enc_b64":"vault:v1:AAAA"}`,
		request_id = "req_t10_ok", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, delivered.status, 200)
}
