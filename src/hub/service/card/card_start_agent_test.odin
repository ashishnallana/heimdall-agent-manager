package card

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project "odin_test:hub/service/project"
import taskv2 "odin_test:hub/service/taskv2"

@(test)
test_start_agent_card_failure_preserves_block_and_retry_dispatches :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_start_agent")
	defer ph_close(&h)
	bridge_impl: sqlite.Bridge_Repo_SQLite
	bridges := sqlite.new_bridge_repository(&bridge_impl, &h.conn)
	repos := iface.Repositories{taskchains = h.tasks, agents = h.agents, bridges = bridges}
	uow_impl: sqlite.SQLite_Unit_Of_Work_Factory
	uow := sqlite.new_unit_of_work_factory(&uow_impl, &h.conn, &repos)
	h.engine.bridges = &bridges
	h.engine.uow_factory = &uow
	h.engine.attention = &h.svc.attention_notifier
	h.svc.uow_factory = &uow
	_, _, _ = iface.bridge_save_bridge(&bridges, domain.Bridge{bridge_id = "br_anr", owner_user_id = PH_OWNER, status = .Offline})
	_, _ = iface.taskchain_upsert_fleet(&h.tasks, domain.Task_Chain_Fleet{task_chain_id = PH_CHAIN, agent_id = "agt_anr", bridge_id = "br_anr", capacity = 1, roles_json = "[\"worker\"]"})
	_, _, _ = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = "inst_anr", agent_id = "agt_anr", owner_user_id = PH_OWNER, chain_id = string(PH_CHAIN), bridge_id = "br_anr", provider = "claude", model = "claude-opus-5-5", runtime_status = "stopped"})
	task := ph_task("task_anr", .In_Progress, "2026-10-01T02:00:00Z")
	task.brief_json = "{\"goal\":\"g\",\"review_roles\":[]}"
	task.state = .Backlog
	_, _, _ = iface.taskchain_save_task(&h.tasks, task)
	err := taskv2.task_created(&h.engine, task, taskv2.Actor{kind = taskv2.ACTOR_USER, id = string(PH_OWNER)})
	testing.expect_value(t, err.code, domain.Error_Code.None)
	cid := attention_task_card_id(task.task_id)
	c, exists := ph_card(t, &h, cid)
	if !testing.expect(t, exists, "unavailable agent raises a card") do return
	testing.expect(t, strings.contains(c.operations_json, "\"op\":\"agent.start\"") && strings.contains(c.operations_json, "Start agent"), "card offers Start agent")
	auth := contracts.Auth_Context{kind = .User_Token, user_id = string(PH_OWNER)}
	_, accepted, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = string(PH_OWNER), agent_instance_id = "inst_anr"}, cid)
	testing.expect(t, !accepted && acc_err.code == .Forbidden, "agent cannot execute user's Start action")
	_, accepted, acc_err = accept_card(&h.svc, auth, cid, Card_Decision{expected_block = "stale"})
	testing.expect(t, !accepted && acc_err.code == .Conflict, "stale browser block rejected")
	_, accepted, acc_err = accept_card(&h.svc, auth, cid)
	testing.expect(t, !accepted && strings.contains(acc_err.message, "offline"), "failed start returned to UI")
	c, _ = ph_card(t, &h, cid)
	testing.expect(t, c.status == domain.CARD_STATUS_PENDING && strings.contains(c.rationale, "offline"), "failure keeps actionable card with reason")
	bridge, _, _ := iface.bridge_get_bridge(&bridges, "br_anr")
	bridge.status = .Online
	_, _, _ = iface.bridge_save_bridge(&bridges, bridge)
	h.engine.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Internal_Error, "bridge launch refused")
	}}
	_, accepted, acc_err = accept_card(&h.svc, auth, cid)
	testing.expect(t, !accepted && strings.contains(acc_err.message, "launch refused"), "post-commit launch error propagated")
	c, _ = ph_card(t, &h, cid)
	testing.expect(t, c.status == domain.CARD_STATUS_PENDING && strings.contains(c.rationale, "launch refused"), "new failure persists despite card accept error")
	h.engine.bridge_command_sink = {}
	_, accepted, acc_err = accept_card(&h.svc, auth, cid)
	testing.expect(t, accepted && acc_err.code == .None, "retry succeeds")
	fresh, _, _ := iface.taskchain_get_task(&h.tasks, task.task_id)
	testing.expect(t, fresh.state == .In_Progress && fresh.blocked_on_json == "", "retry dispatched task")
	c, _ = ph_card(t, &h, cid)
	testing.expect(t, c.status == domain.CARD_STATUS_RESOLVED || c.status == domain.CARD_STATUS_ACCEPTED, "success retires card")
}

@(test)
test_start_agent_card_operations_require_task_and_are_standalone :: proc(t: ^testing.T) {
	ok, _ := validate_card_operations("[{\"op\":\"agent.start\",\"args\":{\"task_id\":\"task_a\"}}]")
	testing.expect(t, ok, "valid start")
	ok, _ = validate_card_operations("[{\"op\":\"agent.start\",\"args\":{}}]")
	testing.expect(t, !ok, "task required")
	ok, _ = validate_card_operations("[{\"op\":\"agent.start\",\"args\":{\"task_id\":\"task_a\"}},{\"op\":\"memory.approve\",\"args\":{\"memory_id\":\"mem_a\"}}]")
	testing.expect(t, !ok, "start has its own transaction and cannot mix with other operations")
}
