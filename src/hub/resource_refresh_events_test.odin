package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"
import taskv2 "odin_test:hub/service/taskv2"
import card_service "odin_test:hub/service/card"
import api_http "odin_test:hub/transport/http"

// REQ-2 (refresh_producers): after-write resource hints reach every socket of
// the owner and no other owner, failed writes publish nothing, and
// reconfiguration progress no longer depends on anyone reading the GET.

Refresh_Socket :: struct { listener, client, server: net.TCP_Socket, idx: int }

refresh_socket_open :: proc(t: ^testing.T, graph: ^app.App_Graph, owner: string) -> Refresh_Socket {
	s: Refresh_Socket
	err: net.Network_Error
	s.listener, err = net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil, "listen_tcp")
	bound, _ := net.bound_endpoint(s.listener)
	s.client, err = net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	testing.expect(t, err == nil, "dial_tcp")
	s.server, _, err = net.accept_tcp(s.listener)
	testing.expect(t, err == nil, "accept_tcp")
	s.idx = events.user_ws_add(&graph.event_bus, owner, s.server)
	testing.expect(t, s.idx >= 0, "user_ws_add")
	return s
}

refresh_socket_close :: proc(graph: ^app.App_Graph, s: Refresh_Socket) {
	events.user_ws_remove(&graph.event_bus, s.idx)
	net.close(s.server); net.close(s.client); net.close(s.listener)
}

refresh_json_field :: proc(body, key: string) -> string {
	needle := fmt.aprintf("\"%s\":\"", key)
	i := strings.index(body, needle)
	if i < 0 do return ""
	rest := body[i + len(needle):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return strings.clone(rest[:end])
}

// Package scope: the graph keeps the config slice, so it must outlive setup.
refresh_trusted_cidrs := [?]string{"127.0.0.1/32"}

Refresh_Fixture :: struct {
	graph: app.App_Graph,
	db_path: string,
	alice: [1]contracts.HTTP_Header,
	bridge_id, bridge_token, agent_id, inst_id, conv_id: string,
}

refresh_fixture_setup :: proc(t: ^testing.T, f: ^Refresh_Fixture, tag: string) -> bool {
	// Test outputs live under $HOME/.cache/heimdall-tests (repo convention).
	cache_dir := fmt.aprintf("%s/.cache/heimdall-tests", os.get_env("HOME", context.temp_allocator))
	_ = os.make_directory(cache_dir)
	f.db_path = fmt.aprintf("%s/refresh-events-%s-%d.db", cache_dir, tag, os.get_pid())
	_ = os.remove(f.db_path)
	ok, msg := app.build_graph(&f.graph, app.Hub_Config{
		database_path = f.db_path, migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email",
		trusted_proxy_cidrs = refresh_trusted_cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout", paddle_environment = "sandbox",
	})
	if !testing.expect(t, ok, msg) do return false
	f.alice = {{name = "X-authentik-username", value = "alice"}}
	bridge_id, bridge_token, enroll_ok := device_enroll_test_bridge(&f.graph, f.alice[:], "Refresh Bridge")
	if !testing.expect(t, enroll_ok, "bridge enroll") do return false
	f.bridge_id = bridge_id
	f.bridge_token = bridge_token
	if b, b_ok, _ := iface.bridge_get_bridge(f.graph.bridges.repo, bridge_id); b_ok { b.status = .Online; _, _, _ = iface.bridge_save_bridge(f.graph.bridges.repo, b) }
	project_service.bridge_runtime_registry_mark_live(f.graph.agents.bridge_runtime_registry, bridge_id, false, "")
	_, _ = iface.bridge_provider_status_upsert(f.graph.agents.providers, domain.Bridge_Provider_Status{bridge_id = bridge_id, provider = "claude", state = "present", checked_at = "2026-10-01T00:00:00Z"})
	_, _ = iface.bridge_provider_setting_upsert(f.graph.agents.providers, domain.Bridge_Provider_Setting{bridge_id = bridge_id, provider = "claude", enabled = true, updated_at = "2026-10-01T00:00:00Z"})
	f.graph.agents.bridge_command_sink = project_service.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) { return true, {} }}

	agent_res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agents", body = `{"name":"Coder","slug":"refresh-coder","default_provider":"claude","default_model":"claude-sonnet-5-5"}`, request_id = "req_rf_agent", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, agent_res.status, 201) do return false
	f.agent_id = refresh_json_field(agent_res.body, "agent_id")
	api_http.router_dispatch(&f.graph.router, api_http.Request{method = "PATCH", path = fmt.aprintf("/api/v1/agents/%s/bridge-support/%s", f.agent_id, bridge_id), body = `{"enabled":true,"provider":"claude","model":"claude-sonnet-5-5"}`, request_id = "req_rf_support", remote_addr = "127.0.0.1", headers = f.alice[:]})
	inst_res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agent-instances", body = fmt.aprintf(`{{"agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, f.agent_id, bridge_id), request_id = "req_rf_inst", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, inst_res.status, 201) do return false
	f.inst_id = refresh_json_field(inst_res.body, "agent_instance_id")
	f.conv_id = refresh_json_field(inst_res.body, "conversation_id")
	return testing.expect(t, f.inst_id != "" && f.conv_id != "", "instance and conversation ids")
}

refresh_fixture_teardown :: proc(f: ^Refresh_Fixture) {
	app.shutdown_graph(&f.graph)
	_ = os.remove(f.db_path)
}

@(test)
test_refresh_user_send_reaches_every_owner_tab_only :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "send") do return
	tab_a := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab_a)
	tab_b := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab_b)
	bob := refresh_socket_open(t, &f.graph, "bob"); defer refresh_socket_close(&f.graph, bob)
	flush_ws_socket(tab_a.client); flush_ws_socket(tab_b.client); flush_ws_socket(bob.client)

	res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = fmt.aprintf("/api/v1/chats/%s/messages", f.conv_id), body = `{"body":"SECRET-PLAINTEXT-4711"}`, request_id = "req_rf_send", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, res.status, 201) do return
	message_id := refresh_json_field(res.body, "message_id")

	for tab, i in ([]Refresh_Socket{tab_a, tab_b}) {
		frame, got := drain_matching_ws_event(tab.client, `"event":"message_created"`)
		defer delete(frame)
		testing.expectf(t, got, "tab %d must receive message_created", i)
		testing.expect(t, strings.contains(frame, f.conv_id), "event carries conversation_id")
		testing.expect(t, strings.contains(frame, message_id), "event carries message_id")
		testing.expect(t, strings.contains(frame, `"direction":"user_to_agent"`), "event carries direction")
		testing.expect(t, strings.contains(frame, `"last_message_at":"20`), "event carries committed last_message_at")
		testing.expect(t, !strings.contains(frame, "SECRET-PLAINTEXT-4711"), "event must not carry the message body")
	}
	other, leaked := drain_matching_ws_event(bob.client, f.conv_id, 300_000_000)
	defer delete(other)
	testing.expect(t, !leaked, "another owner must not receive alice's chat event")

	// A failed write publishes nothing.
	flush_ws_socket(tab_a.client)
	seq_before := f.graph.event_bus.event_seq
	bad := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/chats/chat_missing/messages", body = `{"body":"x"}`, request_id = "req_rf_bad", remote_addr = "127.0.0.1", headers = f.alice[:]})
	testing.expect(t, bad.status >= 400, "send to a missing conversation fails")
	none, got_none := drain_matching_ws_event(tab_a.client, `"event":"message_created"`, 300_000_000)
	defer delete(none)
	testing.expect(t, !got_none, "failed send must not publish message_created")
	testing.expect_value(t, f.graph.event_bus.event_seq, seq_before)
}

@(test)
test_refresh_conversation_created_and_updated_summary :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "conv") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	flush_ws_socket(tab.client)

	res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/chats", body = fmt.aprintf(`{{"agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, f.agent_id, f.bridge_id), request_id = "req_rf_chat", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, res.status, 201) do return
	new_conv := refresh_json_field(res.body, "conversation_id")
	frame, got := drain_matching_ws_event(tab.client, `"change":"created"`)
	defer delete(frame)
	testing.expect(t, got, "POST /chats must publish conversation created")
	testing.expect(t, strings.contains(frame, `"resource":"conversation"`) && strings.contains(frame, new_conv), "created event names the new conversation")

	flush_ws_socket(tab.client)
	patch := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "PATCH", path = fmt.aprintf("/api/v1/chats/%s", new_conv), body = `{"title":"Refreshed Title"}`, request_id = "req_rf_patch", remote_addr = "127.0.0.1", headers = f.alice[:]})
	testing.expect_value(t, patch.status, 200)
	upd, got_upd := drain_matching_ws_event(tab.client, `"change":"updated"`)
	defer delete(upd)
	testing.expect(t, got_upd, "rename must publish conversation updated")
	testing.expect(t, strings.contains(upd, `"title":"Refreshed Title"`), "updated summary carries the title")
	testing.expect(t, strings.contains(upd, `"unread_count":`), "updated summary carries unread_count")
}

@(test)
test_refresh_reconfiguration_get_is_pure_and_reaper_times_out :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "reconfig") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)

	// An operation stuck in Stopping well past the 180s confirmation window, as
	// left behind by a hub restart or a bridge that never answered.
	op := domain.Instance_Reconfiguration{operation_id = "reconfig_rf", owner_user_id = "alice", agent_instance_id = f.inst_id, conversation_id = f.conv_id, actor_user_id = "alice", idempotency_key = "key_rf", revision = 1, phase = .Prepared, source = domain.Instance_Configuration{bridge_id = f.bridge_id, provider = "claude", model = "claude-sonnet-5-5"}, destination = domain.Instance_Configuration{bridge_id = f.bridge_id, provider = "claude", model = "claude-opus-5-5"}, stop_command_id = "stop_rf", launch_command_id = "launch_rf", launch_epoch = "epoch_rf", created_at = "2026-01-01T00:00:00Z", updated_at = "2026-01-01T00:00:00Z"}
	begun, began, begin_err := iface.instance_reconfiguration_begin(&f.graph.repos.agents, op)
	if !testing.expect(t, began, begin_err.message) do return
	stopping := begun; stopping.phase = .Stopping; stopping.revision = 2; stopping.updated_at = "2026-01-01T00:00:01Z"
	stored, advanced, adv_err := iface.instance_reconfiguration_advance(&f.graph.repos.agents, stopping, 1)
	if !testing.expect(t, advanced, adv_err.message) do return
	testing.expect_value(t, stored.revision, 2)

	flush_ws_socket(tab.client)
	path := fmt.aprintf("/api/v1/agent-instances/%s/reconfigurations", f.inst_id)
	for i in 0..<2 {
		res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = path, request_id = fmt.aprintf("req_rf_get_%d", i), remote_addr = "127.0.0.1", headers = f.alice[:]})
		testing.expect_value(t, res.status, 200)
		testing.expect(t, strings.contains(res.body, `"revision":2`), "GET must not advance the operation")
	}
	quiet, mutated := drain_matching_ws_event(tab.client, "agent_instance_reconfiguration", 300_000_000)
	defer delete(quiet)
	testing.expect(t, !mutated, "GET must not publish reconfiguration events")

	// No client involved: the autonomous pass applies the timeout and announces it.
	agent_service.reconcile_active_reconfigurations(&f.graph.agents)
	frame, got := drain_matching_ws_event(tab.client, `"resource":"agent_instance_reconfiguration"`)
	defer delete(frame)
	testing.expect(t, got, "reaper pass must publish the timeout")
	testing.expect(t, strings.contains(frame, `"change":"error"`) && strings.contains(frame, `"error_code":"confirmation_timeout"`) && strings.contains(frame, "reconfig_rf") && strings.contains(frame, f.inst_id), "timeout event carries change, error_code, operation and instance ids")

	// Idempotent: a second pass on the now-terminal-for-timeouts row changes nothing.
	flush_ws_socket(tab.client)
	seq_before := f.graph.event_bus.event_seq
	agent_service.reconcile_active_reconfigurations(&f.graph.agents)
	testing.expect_value(t, f.graph.event_bus.event_seq, seq_before)

	// A lost compare-and-set (stale revision) publishes nothing.
	stale, lost, _ := agent_service.reconfiguration_advance(&f.graph.agents, stored, .Failed, true, false)
	testing.expect(t, !lost, "stale revision must lose the CAS")
	_ = stale
	testing.expect_value(t, f.graph.event_bus.event_seq, seq_before)
}

@(test)
test_refresh_instance_writers_publish :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "instance") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	bob := refresh_socket_open(t, &f.graph, "bob"); defer refresh_socket_close(&f.graph, bob)

	// taskv2 instance-pointer writes publish only after COMMIT; rollback drops them.
	flush_ws_socket(tab.client)
	rolled, began, _ := taskv2.begin_uow(&f.graph.task_engine)
	if !testing.expect(t, began, "begin_uow") do return
	taskv2.effect_instance_changed(&rolled, f.inst_id)
	_, _ = taskv2.end_uow(&f.graph.task_engine, &rolled, false)
	none, leaked := drain_matching_ws_event(tab.client, `"change":"current_task_changed"`, 300_000_000)
	defer delete(none)
	testing.expect(t, !leaked, "rolled-back UoW must not publish")

	committed, began2, _ := taskv2.begin_uow(&f.graph.task_engine)
	if !testing.expect(t, began2, "begin_uow") do return
	taskv2.effect_instance_changed(&committed, f.inst_id)
	taskv2.effect_instance_changed(&committed, f.inst_id)
	_, _ = taskv2.end_uow(&f.graph.task_engine, &committed, true)
	frame, got := drain_matching_ws_event(tab.client, `"change":"current_task_changed"`)
	defer delete(frame)
	testing.expect(t, got, "committed UoW publishes current_task_changed")
	testing.expect(t, strings.contains(frame, f.inst_id) && strings.contains(frame, `"current_task_id":`) && strings.contains(frame, `"configuration_revision":`) && strings.contains(frame, `"provider":"claude"`), "instance summary carries task pointer and configuration")
	testing.expect_value(t, strings.count(frame, `"change":"current_task_changed"`), 1)
	other, crossed := drain_matching_ws_event(bob.client, f.inst_id, 300_000_000)
	defer delete(other)
	testing.expect(t, !crossed, "another owner must not receive alice's instance event")

	// Bridge status reports: a transition reports changed, an identical
	// liveness beat does not (the digest publishes only on changed).
	moved := false
	first, applied, _ := agent_service.apply_bridge_status_report(&f.graph.agents, f.bridge_id, f.inst_id, 1, "running", "idle", changed = &moved)
	testing.expect(t, applied, "first status report applies")
	testing.expect(t, moved, "launching -> running is a visible change")
	domain.agent_instance_destroy(&first)
	moved = true
	again, applied2, _ := agent_service.apply_bridge_status_report(&f.graph.agents, f.bridge_id, f.inst_id, 1, "running", "idle", changed = &moved)
	testing.expect(t, applied2, "liveness beat still refreshes last_seen_at")
	testing.expect(t, !moved, "an unchanged beat is not a change")
	domain.agent_instance_destroy(&again)
	moved = false
	busy, applied3, _ := agent_service.apply_bridge_status_report(&f.graph.agents, f.bridge_id, f.inst_id, 1, "running", "busy", changed = &moved)
	testing.expect(t, applied3 && moved, "an activity flip on a liveness beat is a change")
	domain.agent_instance_destroy(&busy)
}

@(test)
test_refresh_identity_bridge_provider_events :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "identity") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	bob := refresh_socket_open(t, &f.graph, "bob"); defer refresh_socket_close(&f.graph, bob)

	// Instance creation announces the instance AND its conversation.
	flush_ws_socket(tab.client)
	inst_res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agent-instances", body = fmt.aprintf(`{{"agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-opus-5-5"}}`, f.agent_id, f.bridge_id), request_id = "req_rf_inst2", remote_addr = "127.0.0.1", headers = f.alice[:]})
	testing.expect_value(t, inst_res.status, 201)
	new_conv := refresh_json_field(inst_res.body, "conversation_id")
	frames, got_create := drain_matching_ws_event(tab.client, new_conv)
	defer delete(frames)
	testing.expect(t, got_create && strings.contains(frames, `"resource":"agent_instance"`) && strings.contains(frames, `"resource":"conversation"`), "instance create publishes agent_instance and conversation created")

	Case :: struct { method, path, body, expect: string }
	cases := []Case{
		{"PATCH", fmt.aprintf("/api/v1/agents/%s", f.agent_id), `{"name":"Coder Renamed"}`, `"resource":"agent","resource_id":"`},
		{"PATCH", fmt.aprintf("/api/v1/agents/%s/bridge-support/%s", f.agent_id, f.bridge_id), `{"enabled":true,"provider":"claude","model":"claude-opus-5-5"}`, `"change":"support_changed"`},
		{"PATCH", fmt.aprintf("/api/v1/bridges/%s", f.bridge_id), `{"label":"Renamed Bridge"}`, `"resource":"bridge","resource_id":"`},
		{"PUT", fmt.aprintf("/api/v1/bridges/%s/providers/claude", f.bridge_id), `{"enabled":false}`, `"change":"provider_status_changed"`},
	}
	for c, i in cases {
		flush_ws_socket(tab.client)
		res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = c.method, path = c.path, body = c.body, request_id = fmt.aprintf("req_rf_id_%d", i), remote_addr = "127.0.0.1", headers = f.alice[:]})
		testing.expectf(t, res.status >= 200 && res.status < 300, "case %d %s %s: status %d body %s", i, c.method, c.path, res.status, res.body)
		frame, got := drain_matching_ws_event(tab.client, c.expect)
		defer delete(frame)
		testing.expectf(t, got, "case %d %s %s must publish %s, got %s", i, c.method, c.path, c.expect, frame)
	}
	other, leaked := drain_matching_ws_event(bob.client, `"resource":"`, 300_000_000)
	defer delete(other)
	testing.expect(t, !leaked, "another owner must not receive alice's identity/bridge events")

}

@(test)
test_refresh_shell_background_publishes_after_write :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "shell") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	svc := &f.graph.shell_session_service
	row := domain.Shell_Session{session_id = "sh_refresh_run", owner_user_id = "alice", bridge_id = f.bridge_id, kind = "run", status = domain.Shell_Session_Status_Running, pid = 4242, run_seq = 1, chain_id = "chain_rf", created_at = "2026-10-21T00:00:00Z", started_at = "2026-10-21T00:00:00Z", last_activity_at = "2026-10-21T00:00:00Z"}
	_, up_err := iface.shell_session_upsert(svc.repo, row)
	if !testing.expect(t, up_err.code == .None, up_err.message) do return

	flush_ws_socket(tab.client)
	_, ok, err := shell_session_svc._shell_session_set_background_for_owner(svc, "alice", "sh_refresh_run")
	testing.expect(t, ok, err.message)
	frame, got := drain_matching_ws_event(tab.client, `"resource":"shell_session"`)
	defer delete(frame)
	testing.expect(t, got, "backgrounding publishes shell_session")
	testing.expect(t, strings.contains(frame, `"change":"backgrounded"`) && strings.contains(frame, "sh_refresh_run") && strings.contains(frame, `"pid":4242`) && strings.contains(frame, `"run_seq":1`) && strings.contains(frame, `"chain_id":"chain_rf"`), "summary carries change, pid, run_seq and chain")

	// A refused change (already background) writes nothing and publishes nothing.
	flush_ws_socket(tab.client)
	seq_before := f.graph.event_bus.event_seq
	_, again, _ := shell_session_svc._shell_session_set_background_for_owner(svc, "alice", "sh_refresh_run")
	testing.expect(t, !again, "second background is refused")
	testing.expect_value(t, f.graph.event_bus.event_seq, seq_before)
}

@(test)
test_refresh_workflow_events_name_run_and_stage :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "workflow") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)

	flush_ws_socket(tab.client)
	rolled, began, _ := taskv2.begin_uow(&f.graph.task_engine)
	if !testing.expect(t, began, "begin_uow") do return
	taskv2.effect_publish_workflow_stage(&rolled, "chain_wf", "alice", "wfrun_rolled", "build")
	_, _ = taskv2.end_uow(&f.graph.task_engine, &rolled, false)
	none, leaked := drain_matching_ws_event(tab.client, "wfrun_rolled", 300_000_000)
	defer delete(none)
	testing.expect(t, !leaked, "rolled-back workflow effects must not publish")

	u, began2, _ := taskv2.begin_uow(&f.graph.task_engine)
	if !testing.expect(t, began2, "begin_uow") do return
	taskv2.effect_publish_workflow(&u, "chain_wf", "alice", "wfrun_1", "workflow_started")
	taskv2.effect_publish_workflow_stage(&u, "chain_wf", "alice", "wfrun_1", "build")
	_, _ = taskv2.end_uow(&f.graph.task_engine, &u, true)
	frames, got := drain_matching_ws_event(tab.client, `"change":"stage_changed"`)
	defer delete(frames)
	testing.expect(t, got, "committed stage expansion publishes workflow_run/stage_changed")
	testing.expect(t, strings.contains(frames, `"resource":"workflow_run","resource_id":"wfrun_1"`) && strings.contains(frames, `"stage_key":"build"`), "stage event names run and stage")
	testing.expect(t, strings.contains(frames, `"change":"workflow_started"`) && strings.contains(frames, `"workflow_run_id":"wfrun_1"`), "chain workflow event carries workflow_run_id")
}

@(test)
test_refresh_task_effects_dedupe_and_facet_kind :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "facet") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	task := domain.Task{task_id = "task_rf", chain_id = "chain_rf", owner_user_id = "alice"}

	flush_ws_socket(tab.client)
	u, began, _ := taskv2.begin_uow(&f.graph.task_engine)
	if !testing.expect(t, began, "begin_uow") do return
	// Two refolds of one task in one UoW, plus one handoff facet write on attempt 2.
	taskv2.effect_publish_task(&u, task, "updated")
	taskv2.effect_publish_task(&u, task, "updated")
	taskv2.effect_publish_facet(&u, task, 2, "handoff")
	_, _ = taskv2.end_uow(&f.graph.task_engine, &u, true)
	frames, got := drain_matching_ws_event(tab.client, `"change":"facet_changed"`)
	defer delete(frames)
	testing.expect(t, got, "facet write publishes task/facet_changed")
	testing.expect(t, strings.contains(frames, `"attempt_no":2`) && strings.contains(frames, `"kind":"handoff"`), "facet event carries attempt and kind")
	testing.expect_value(t, strings.count(frames, `"change":"updated"`), 1)
}

// refresh_collect returns every frame that arrives within the window (the
// sentinel never matches), so a test can count events per change.
refresh_collect :: proc(sock: net.TCP_Socket) -> string {
	frames, _ := drain_matching_ws_event(sock, "\x00refresh-never\x00", 400_000_000)
	return frames
}

refresh_stop_instance :: proc(f: ^Refresh_Fixture) {
	if inst, ok, _ := iface.agent_get_instance(&f.graph.repos.agents, f.inst_id); ok {
		inst.runtime_status = "stopped"
		_, _, _ = iface.agent_save_instance(&f.graph.repos.agents, inst)
	}
}

@(test)
test_refresh_restart_and_action_sends_publish :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "restart") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	bob := refresh_socket_open(t, &f.graph, "bob"); defer refresh_socket_close(&f.graph, bob)

	// Sending to a stopped conversation restarts it: one status_changed for the
	// restart plus one message_created for the row.
	refresh_stop_instance(&f)
	flush_ws_socket(tab.client)
	res := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = fmt.aprintf("/api/v1/chats/%s/messages", f.conv_id), body = `{"body":"wake up"}`, request_id = "req_rf_wake", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expectf(t, res.status == 201, "send to stopped: %d %s", res.status, res.body) do return
	frames := refresh_collect(tab.client)
	defer delete(frames)
	testing.expect_value(t, strings.count(frames, `"change":"status_changed"`), 1)
	testing.expect(t, strings.contains(frames, f.inst_id) && strings.contains(frames, `"run_count":`), "restart hint names the instance and carries run state")
	testing.expect_value(t, strings.count(frames, `"event":"message_created"`), 1)

	// Run-now action against the stopped instance: restart + action message.
	refresh_stop_instance(&f)
	create := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/actions", body = fmt.aprintf(`{{"name":"Nightly","target_instance_id":"%s","prompt_text":"ACTION-SECRET-99"}}`, f.inst_id), request_id = "req_rf_act", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expectf(t, create.status >= 200 && create.status < 300, "create action: %d %s", create.status, create.body) do return
	action_id := refresh_json_field(create.body, "action_id")
	if action_id == "" do action_id = refresh_json_field(create.body, "id")
	flush_ws_socket(tab.client)
	run := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = fmt.aprintf("/api/v1/actions/%s/run", action_id), body = `{}`, request_id = "req_rf_run", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expectf(t, run.status == 200, "run action: %d %s", run.status, run.body) do return
	msg_id := refresh_json_field(run.body, "message_id")
	run_frames := refresh_collect(tab.client)
	defer delete(run_frames)
	testing.expect_value(t, strings.count(run_frames, `"change":"status_changed"`), 1)
	testing.expect_value(t, strings.count(run_frames, `"event":"message_created"`), 1)
	testing.expect(t, msg_id != "" && strings.contains(run_frames, msg_id) && strings.contains(run_frames, `"message_type":"action"`), "action message hint carries id and type")
	testing.expect(t, !strings.contains(run_frames, "ACTION-SECRET-99"), "hint must not carry the prompt")
	other := refresh_collect(bob.client)
	defer delete(other)
	testing.expect(t, !strings.contains(other, f.inst_id) && !strings.contains(other, f.conv_id), "another owner hears nothing")
}

@(test)
test_refresh_card_prompt_publishes_only_after_commit :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "card") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	alice := contracts.Auth_Context{kind = .User_Token, user_id = "alice"}

	// A later op fails, the accept rolls back: the prompt hint is dropped.
	bad, bad_ok, bad_err := card_service.create_card(&f.graph.cards, alice, card_service.Card_Input{title = "Rolls back", scope = "agent", operations_json = fmt.aprintf(`[{{"op":"agent.prompt","args":{{"instance_id":"%s","prompt":"p1"}}}},{{"op":"agent.update","args":{{"agent_id":"agt_missing","name":"x"}}}}]`, f.inst_id)})
	if !testing.expect(t, bad_ok, bad_err.message) do return
	flush_ws_socket(tab.client)
	_, accepted_bad, _ := card_service.accept_card(&f.graph.cards, alice, bad.card_id)
	testing.expect(t, !accepted_bad, "accept with a failing op fails")
	none := refresh_collect(tab.client)
	defer delete(none)
	testing.expect_value(t, strings.count(none, `"event":"message_created"`), 0)

	good, good_ok, good_err := card_service.create_card(&f.graph.cards, alice, card_service.Card_Input{title = "Prompts", scope = "agent", operations_json = fmt.aprintf(`[{{"op":"agent.prompt","args":{{"instance_id":"%s","prompt":"CARD-SECRET-7"}}}}]`, f.inst_id)})
	if !testing.expect(t, good_ok, good_err.message) do return
	flush_ws_socket(tab.client)
	_, accepted, acc_err := card_service.accept_card(&f.graph.cards, alice, good.card_id)
	testing.expect(t, accepted, acc_err.message)
	frames := refresh_collect(tab.client)
	defer delete(frames)
	testing.expect_value(t, strings.count(frames, `"event":"message_created"`), 1)
	testing.expect(t, strings.contains(frames, f.conv_id) && strings.contains(frames, `"message_type":"action"`) && strings.contains(frames, `"last_message_at":"20`), "hint carries conversation and committed last_message_at")
	testing.expect(t, !strings.contains(frames, "CARD-SECRET-7"), "hint must not carry the prompt")
}

@(test)
test_refresh_agent_to_agent_and_read_receipts :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "a2a") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	bridge_auth := fmt.aprintf("Bearer %s", f.bridge_token)
	headers := []contracts.HTTP_Header{{name = "Authorization", value = bridge_auth}}

	second := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agent-instances", body = fmt.aprintf(`{{"agent_id":"%s","bridge_id":"%s","provider":"claude","model":"claude-sonnet-5-5"}}`, f.agent_id, f.bridge_id), request_id = "req_rf_inst_b", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, second.status, 201) do return
	target_inst := refresh_json_field(second.body, "agent_instance_id")
	target_conv := refresh_json_field(second.body, "conversation_id")

	// E3: agent->agent lands in the TARGET conversation and announces it there.
	flush_ws_socket(tab.client)
	a2a := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agent-actions/chat/send-to-agent", body = fmt.aprintf(`{{"agent_instance_id":"%s","params":{{"to_instance":"%s","body":"A2A-SECRET-5"}}}}`, f.inst_id, target_inst), request_id = "req_rf_a2a", remote_addr = "127.0.0.1", headers = headers})
	if !testing.expectf(t, a2a.status == 201, "send-to-agent: %d %s", a2a.status, a2a.body) do return
	frames := refresh_collect(tab.client)
	defer delete(frames)
	testing.expect_value(t, strings.count(frames, `"event":"message_created"`), 1)
	testing.expect(t, strings.contains(frames, target_conv) && strings.contains(frames, `"direction":"agent_to_agent"`), "hint names the target conversation")
	testing.expect(t, !strings.contains(frames, "A2A-SECRET-5"), "hint must not carry the body")

	// E4: the agent's read reports the committed read_at, in the response rows
	// and in the messages_read event, and it equals what a refetch returns.
	sent := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = fmt.aprintf("/api/v1/chats/%s/messages", f.conv_id), body = `{"body":"please read"}`, request_id = "req_rf_tobe_read", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expect_value(t, sent.status, 201) do return
	flush_ws_socket(tab.client)
	read := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "POST", path = "/api/v1/agent-actions/chat/read", body = fmt.aprintf(`{{"agent_instance_id":"%s","params":{{}}}}`, f.inst_id), request_id = "req_rf_read", remote_addr = "127.0.0.1", headers = headers})
	if !testing.expectf(t, read.status == 200, "chat read: %d %s", read.status, read.body) do return
	testing.expect(t, !strings.contains(read.body, `"read_at":""`), "response rows carry the receipt, not the pre-mark state")
	read_at := refresh_json_field(read.body, "read_at")
	testing.expect(t, read_at != "", "response carries read_at")
	evt, got := drain_matching_ws_event(tab.client, `"event":"messages_read"`)
	defer delete(evt)
	testing.expect(t, got, "agent read publishes messages_read")
	testing.expect(t, strings.contains(evt, fmt.aprintf(`"read_at":"%s"`, read_at)), "event read_at equals the committed receipt")
}

@(test)
test_refresh_shell_retention_and_seeding_publish :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "retention") do return
	tab := refresh_socket_open(t, &f.graph, "alice"); defer refresh_socket_close(&f.graph, tab)
	bob := refresh_socket_open(t, &f.graph, "bob"); defer refresh_socket_close(&f.graph, bob)
	svc := &f.graph.shell_session_service
	old := domain.Shell_Session{session_id = "sh_refresh_old", owner_user_id = "alice", bridge_id = f.bridge_id, kind = "run", status = "exited", run_seq = 1, created_at = "2026-01-01T00:00:00Z", started_at = "2026-01-01T00:00:00Z", finished_at = "2026-01-01T00:01:00Z", last_activity_at = "2026-01-01T00:01:00Z"}
	_, up_err := iface.shell_session_upsert(svc.repo, old)
	if !testing.expect(t, up_err.code == .None, up_err.message) do return

	flush_ws_socket(tab.client)
	n, sweep_err := shell_session_svc.shell_session_sweep_terminal_rows(svc, "2026-10-21T00:00:00Z")
	testing.expect(t, sweep_err.code == .None, sweep_err.message)
	testing.expect_value(t, n, 1)
	frames := refresh_collect(tab.client)
	defer delete(frames)
	testing.expect_value(t, strings.count(frames, `"change":"pruned"`), 1)
	testing.expect(t, strings.contains(frames, `"deleted":1`), "pruned hint carries the owner's count")
	other := refresh_collect(bob.client)
	defer delete(other)
	testing.expect(t, !strings.contains(other, `"pruned"`), "another owner hears nothing")
	// Nothing left to delete: no hint.
	n2, _ := shell_session_svc.shell_session_sweep_terminal_rows(svc, "2026-10-21T00:00:00Z")
	testing.expect_value(t, n2, 0)
	quiet := refresh_collect(tab.client)
	defer delete(quiet)
	testing.expect(t, !strings.contains(quiet, `"pruned"`), "an empty sweep publishes nothing")

	// Canonical seeding for a newly provisioned owner announces each agent.
	carol := refresh_socket_open(t, &f.graph, "carol"); defer refresh_socket_close(&f.graph, carol)
	flush_ws_socket(carol.client)
	carol_headers := []contracts.HTTP_Header{{name = "X-authentik-username", value = "carol"}}
	list := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = "/api/v1/agents", request_id = "req_rf_carol", remote_addr = "127.0.0.1", headers = carol_headers})
	testing.expect_value(t, list.status, 200)
	seeded := refresh_collect(carol.client)
	defer delete(seeded)
	testing.expect_value(t, strings.count(seeded, `"resource":"agent"`), 4)
	testing.expect_value(t, strings.count(seeded, `"change":"created"`), 4)
}
