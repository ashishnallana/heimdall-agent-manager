package content

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

// ---- pure gate ----

@(test)
test_title_nudge_gate_chain_fields :: proc(t: ^testing.T) {
	// Non-default chain title stops nudges regardless of activity.
	testing.expect_value(t, evaluate_title_nudge("agent", true, 0, 0, 1000, 60).reason, "non_default_title")
	testing.expect_value(t, evaluate_title_nudge("user", true, 0, 0, 1000, 60).reason, "non_default_title")
	// No activity: never nudge.
	testing.expect_value(t, evaluate_title_nudge("default", false, 0, 0, 1000, 60).reason, "no_activity")
	// First nudge fires immediately.
	testing.expect(t, evaluate_title_nudge("default", true, 500, 0, 1000, 60).should_nudge, "first nudge fires")
	// Re-nudge needs new activity...
	testing.expect_value(t, evaluate_title_nudge("default", true, 100, 100, 1_000_000, 60).reason, "no_new_activity")
	// ...and an elapsed cooldown.
	testing.expect_value(t, evaluate_title_nudge("default", true, 200, 100, 30_000, 60).reason, "cooldown")
	testing.expect(t, evaluate_title_nudge("default", true, 200, 100, 61_000, 60).should_nudge, "re-nudge after cooldown")
}

@(test)
test_title_nudge_targets_coordinator_only :: proc(t: ^testing.T) {
	members := []domain.Task_Chain_Member{
		{agent_instance_id = "inst_worker", role = "worker"},
		{agent_instance_id = "inst_coord_a", role = "coordinator"},
		{agent_instance_id = "inst_coord_b", role = "coordinator"},
		{agent_instance_id = "inst_rev", role = "reviewer"},
	}
	testing.expect_value(t, title_nudge_coordinator_instance(members, "inst_mirror"), "inst_coord_a")
	// No coordinator member: fall back to the mirror column, else "".
	only_worker := []domain.Task_Chain_Member{{agent_instance_id = "inst_worker", role = "worker"}}
	testing.expect_value(t, title_nudge_coordinator_instance(only_worker, "inst_mirror"), "inst_mirror")
	testing.expect_value(t, title_nudge_coordinator_instance(only_worker, ""), "")
}

@(test)
test_title_nudge_target_liveness :: proc(t: ^testing.T) {
	for status in ([]string{"running", "idle", "busy"}) {
		testing.expectf(t, title_nudge_target_is_live(domain.Agent_Instance{bridge_id = "brg_1", runtime_status = status}), "%s is live", status)
	}
	for status in ([]string{"launching", "starting", "stopped", "failed", "terminated", ""}) {
		testing.expectf(t, !title_nudge_target_is_live(domain.Agent_Instance{bridge_id = "brg_1", runtime_status = status}), "%s is not live", status)
	}
	testing.expect(t, !title_nudge_target_is_live(domain.Agent_Instance{runtime_status = "running"}), "no bridge is not live")
}

// ---- end-to-end over sqlite with a capturing bridge sink ----

Title_Nudge_Capture :: struct {
	bodies: [dynamic]string,
}

title_nudge_capture_sink :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	cap := (^Title_Nudge_Capture)(ctx)
	if strings.contains(command.body_json, "\"notify_title_nudge\"") do append(&cap.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

Title_Nudge_Fixture :: struct {
	conn:           sqlite.Conn,
	content_impl:   sqlite.Content_Repo_SQLite,
	agent_impl:     sqlite.Agent_Repo_SQLite,
	taskchain_impl: sqlite.Taskchain_Repo_SQLite,
	content_repo:   iface.Content_Repository,
	agent_repo:     iface.Agent_Repository,
	taskchain_repo: iface.Taskchain_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	svc:            Content_Service,
	capture:        Title_Nudge_Capture,
	db_path:        string,
}

OWNER :: domain.User_ID("u_title_nudge")
CHAIN :: "chain_tn"

title_nudge_fixture_open :: proc(t: ^testing.T, f: ^Title_Nudge_Fixture, name: string) -> bool {
	f.db_path = fmt.aprintf("%s/.cache/heimdall-tests/title_nudge_%s_%d.db", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	os.remove(f.db_path)
	ok: bool
	f.conn, ok, _ = sqlite.open(f.db_path)
	if !testing.expect(t, ok, "db open") do return false
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	if !testing.expect(t, mig_ok, "migrations") do return false
	f.content_impl = sqlite.Content_Repo_SQLite{conn = &f.conn}
	f.agent_impl = sqlite.Agent_Repo_SQLite{conn = &f.conn}
	f.taskchain_impl = sqlite.Taskchain_Repo_SQLite{conn = &f.conn}
	f.content_repo = sqlite.new_content_repository(&f.content_impl, &f.conn)
	f.agent_repo = sqlite.new_agent_repository(&f.agent_impl, &f.conn)
	f.taskchain_repo = sqlite.new_taskchain_repository(&f.taskchain_impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_content_service(&f.content_repo, &f.agent_repo, nil, nil, &f.taskchain_repo, &f.clock, &f.ids)
	f.svc.title_nudge_cooldown_seconds = 60
	f.svc.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = &f.capture, send_runtime_command = title_nudge_capture_sink}

	// Chain with a default title; coordinator + worker members, each with its own conversation.
	_, chain_ok, _ := iface.taskchain_save_chain(&f.taskchain_repo, domain.Task_Chain{chain_id = CHAIN, owner_user_id = OWNER, title = "soloist #1", title_source = "default", coordinator_agent_instance_id = "inst_coord", created_at = "2026-10-15T11:00:00Z", updated_at = "2026-10-15T11:00:00Z"})
	if !testing.expect(t, chain_ok, "save chain") do return false
	for m in ([]domain.Task_Chain_Member{{chain_id = CHAIN, agent_instance_id = "inst_coord", owner_user_id = OWNER, role = "coordinator", created_at = "2026-10-15T11:00:00Z"}, {chain_id = CHAIN, agent_instance_id = "inst_worker", owner_user_id = OWNER, role = "worker", created_at = "2026-10-15T11:00:01Z"}}) {
		_, member_ok, _ := iface.taskchain_save_member(&f.taskchain_repo, m)
		if !testing.expect(t, member_ok, "save member") do return false
	}
	title_nudge_fixture_instance(t, f, "inst_coord", "launching")
	title_nudge_fixture_instance(t, f, "inst_worker", "running")
	for pair in ([][2]string{{"chat_coord", "inst_coord"}, {"chat_worker", "inst_worker"}}) {
		_, conv_ok, _ := iface.content_save_conversation(&f.content_repo, domain.Chat_Conversation{conversation_id = pair[0], owner_user_id = OWNER, agent_instance_id = pair[1], chain_id = CHAIN, title = "default", title_source = "default", created_at = "2026-10-15T11:00:00Z", updated_at = "2026-10-15T11:00:00Z"})
		if !testing.expect(t, conv_ok, "save conversation") do return false
	}
	return true
}

title_nudge_fixture_instance :: proc(t: ^testing.T, f: ^Title_Nudge_Fixture, id, runtime_status: string) {
	_, ok, _ := iface.agent_save_instance(&f.agent_repo, domain.Agent_Instance{agent_instance_id = id, owner_user_id = OWNER, bridge_id = "brg_tn", chain_id = CHAIN, runtime_status = runtime_status})
	testing.expect(t, ok, "save instance")
}

title_nudge_fixture_message :: proc(t: ^testing.T, f: ^Title_Nudge_Fixture, conversation_id, now: string) {
	_, ok, _ := iface.content_save_message(&f.content_repo, domain.Chat_Message{message_id = fmt.tprintf("msg_%s_%s", conversation_id, now), conversation_id = conversation_id, owner_user_id = OWNER, direction = "user_to_agent", body = "hi", message_type = "text", created_at = now})
	testing.expect(t, ok, "save message")
	record_activity_and_maybe_nudge(&f.svc, conversation_id, now)
}

title_nudge_fixture_close :: proc(f: ^Title_Nudge_Fixture) {
	for b in f.capture.bodies do delete(b)
	delete(f.capture.bodies)
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	delete(f.db_path)
}

title_nudge_chain :: proc(f: ^Title_Nudge_Fixture) -> domain.Task_Chain {
	chain, _, _ := iface.taskchain_get_chain(&f.taskchain_repo, CHAIN)
	return chain
}

