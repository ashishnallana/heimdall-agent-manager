package http

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import content_service "odin_test:hub/service/content"
import user_service "odin_test:hub/service/user"
import shell_service "odin_test:hub/service/shell_session"
import project_service "odin_test:hub/service/project"

@(private = "file")
live_http_start :: proc(ctx: rawptr, cmd: project_service.Runtime_Command, timeout: int) -> (string, bool, domain.Domain_Error) {
	failed := (^bool)(ctx)
	if failed^ do return "", false, domain.domain_error(.Bridge_Offline, "test refusal")
	return strings.clone(`{"ok":true,"pid":4242}`), true, {}
}
@(test)
test_live_provider_shell_and_legacy_endpoint_write_zero_db_messages :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	testing.expect(t, opened)
	if !opened do return
	defer sqlite.close(&conn)
	migrated, err := sqlite.run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	if !migrated do return
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	users_impl: sqlite.User_Repo_SQLite
	users_repo := sqlite.new_user_repository(&users_impl, &conn)
	users := user_service.new_user_service_basic(&users_repo, &clock, &ids)
	auth := auth_service.new_auth_service(auth_service.Trusted_Proxy_Config{username_header = "X-authentik-username",
		trusted_proxy_cidrs = []string{"127.0.0.1/32"}, auto_provision_users = true}, &users)
	user_headers := []contracts.HTTP_Header{{name = "X-authentik-username", value = "live_owner"}}
	owner, authed, auth_err := auth_service.resolve_auth(&auth, auth_service.Auth_Request{remote_addr = "127.0.0.1", headers = user_headers})
	testing.expect(t, authed, auth_err.message)
	if !authed do return
	bridges_impl: sqlite.Bridge_Repo_SQLite
	bridges_repo := sqlite.new_bridge_repository(&bridges_impl, &conn)
	bridges := bridge_service.new_bridge_service(&bridges_repo, &clock, &ids)
	enrollment, enrolled, enroll_err := bridge_service.enroll_bridge_from_device_grant(&bridges, bridge_service.Device_Enroll_Input{
		owner_user_id = owner.user_id, bridge_public_key = "04aabb", bridge_key_fingerprint = "aa bb",
		os_user = "test", machine_hostname = "live-test", machine_os = "linux"})
	testing.expect(t, enrolled, enroll_err.message)
	if !enrolled do return
	agents_impl: sqlite.Agent_Repo_SQLite
	agents_repo := sqlite.new_agent_repository(&agents_impl, &conn)
	inst := domain.Agent_Instance{agent_instance_id = "live_http", agent_id = "agent_http", owner_user_id = domain.User_ID(owner.user_id),
		bridge_id = enrollment.bridge.bridge_id, kind = "agent", runtime_status = "running", provider_session_id = "s1"}
	_, saved, save_err := iface.agent_save_instance(&agents_repo, inst)
	testing.expect(t, saved, save_err.message)
	if !saved do return
	agents := agent_service.new_agent_service(&agents_repo, &bridges_repo, &clock, &ids)
	defer agent_service.tool_live_destroy(&agents.tool_live)
	auth.bridges = &bridges; auth.agents = &agents
	content_impl: sqlite.Content_Repo_SQLite
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	content := content_service.Content_Service{content = &content_repo, clock = &clock, ids = &ids}
	conv := domain.Chat_Conversation{conversation_id = "live_chat", owner_user_id = inst.owner_user_id,
		agent_instance_id = inst.agent_instance_id, agent_id = inst.agent_id, last_message_preview = "last real reply",
		last_message_at = "2026-01-01T00:00:00Z", updated_at = "2026-01-01T00:00:00Z", unread_count = 7}
	_, conv_saved, conv_err := iface.content_save_conversation(&content_repo, conv)
	testing.expect(t, conv_saved, conv_err.message)
	headers := []contracts.HTTP_Header{{name = "Authorization", value = strings.concatenate({"Bearer ", enrollment.bridge_token}, context.temp_allocator)}}
	action := Agent_Action_Handlers{auth = &auth, agents = &agents, content = &content}
	token_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = owner.user_id, agent_instance_id = inst.agent_instance_id}
	// Timestamp ahead of boot by one second avoids source timestamp precision loss.
	ts := platform.format_rfc3339_utc(time.time_add(time.now(), time.Second))
	event := fmt.tprintf(`{{"agent_instance_id":"live_http","params":{{"events":[{{"schema":"ham.ext.v1","provider":"claude","event":"tool.start","ts":"%s","session_id":"s1","tool":{{"name":"Bash","use_id":"x"}}, "payload":{{}}},{{"schema":"ham.ext.v1","provider":"claude","event":"tool.end","ts":"%s","session_id":"s1","tool":{{"name":"Bash","use_id":"x"}}, "payload":{{}}}]}}}`, ts, ts)
	resp := agent_action_extension_events_handler(&action, Request{headers = headers, body = event})
	testing.expect_value(t, resp.status, 200)
	legacy := Request{headers = headers, body = `{"agent_instance_id":"live_http","params":{"message_type":"tool_activity","body":"legacy retry","metadata":{"calls":[]}}}`}
	for _ in 0..<2 {
		resp = agent_action_tool_activity_handler(&action, legacy)
		testing.expect_value(t, resp.status, 200)
		testing.expect(t, strings.contains(resp.body, `"persisted":false`))
	}
	// Old bridges remain authenticated: a wrong bridge/instance cannot use the no-op.
	bad := legacy; bad.headers = nil
	denied := agent_action_tool_activity_handler(&action, bad)
	testing.expect(t, denied.status != 200)
	shell_impl: sqlite.Shell_Session_Repo_SQLite
	shell_repo := sqlite.new_shell_session_repository(&shell_impl, &conn)
	fail_start := false
	shell := shell_service.new_shell_session_service(repo = &shell_repo, ids = &ids, clock = &clock, content = &content,
		bridge_command_sink = project_service.Bridge_Command_Sink{ctx = &fail_start, send_runtime_command_wait = live_http_start})
	defer shell_service.shell_session_service_free(&shell)
	shell.live_agents = &agents
	input := shell_service.Shell_Session_Create_Input{bridge_id = inst.bridge_id, kind = "run", cmd = "echo hi"}
	row, run_ok, run_err := shell_service.shell_session_create(&shell, token_auth, input)
	testing.expect(t, run_ok, run_err.message)
	if run_ok {
		_, _, _ = shell_service.shell_session_set_background(&shell, token_auth, row.session_id)
		testing.expect(t, shell_service.shell_session_handle_exited(&shell, row.session_id, inst.bridge_id, "exited", 0, true))
	}
	fail_start = true
	failed, failed_ok, _ := shell_service.shell_session_create(&shell, token_auth, input)
	testing.expect(t, !failed_ok)
	testing.expect_value(t, failed.status, "failed")
	messages, msg_err := iface.content_list_messages(&content_repo, conv.conversation_id, inst.owner_user_id, 100, "")
	testing.expect_value(t, msg_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(messages), 0)
	after, _, _ := iface.content_get_conversation(&content_repo, conv.conversation_id)
	testing.expect_value(t, after.last_message_preview, conv.last_message_preview)
	testing.expect_value(t, after.last_message_at, conv.last_message_at)
	testing.expect_value(t, after.updated_at, conv.updated_at)
	testing.expect_value(t, after.unread_count, conv.unread_count)
	timeline, timeline_err := iface.agent_ext_list_events(&agents_repo, inst.agent_instance_id, "", 0, 100)
	testing.expect_value(t, timeline_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(timeline), 2)
	// UI GET uses owner auth, independent of chat or timeline history.
	reader := Agent_Handlers{auth = &auth, agents = &agents}
	resp = agent_instance_tool_activity_live_handler(&reader, Request{remote_addr = "127.0.0.1", headers = user_headers,
		path = "/api/v1/agent-instances/live_http/tool-activity-live"})
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, strings.contains(resp.body, `"active":[]`))
	foreign_headers := []contracts.HTTP_Header{{name = "X-authentik-username", value = "foreign_owner"}}
	resp = agent_instance_tool_activity_live_handler(&reader, Request{remote_addr = "127.0.0.1", headers = foreign_headers,
		path = "/api/v1/agent-instances/live_http/tool-activity-live"})
	testing.expect_value(t, resp.status, 404)
}

