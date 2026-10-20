package taskv2

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import sqlite "odin_test:hub/repository/sqlite"
import project "odin_test:hub/service/project"

@(test)
test_agent_not_running_offline_start_failure_retry_and_dead_holder :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_retry")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	set_bridge_status(fx, "br_1", false)
	task := publish_task(t, fx, chain, "task_anr")
	testing.expect(t, task.state == .Backlog && is_agent_not_running_block(task.blocked_on_json), "offline ready task blocks")
	for part in ([]string{"agt_w", "claude", "claude-opus-5-5", "br_1", "offline"}) do testing.expect(t, strings.contains(task.blocked_on_json, part), part)
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
	auth := contracts.Auth_Context{kind = .User_Token, user_id = "u1"}
	started, err := start_task_agent(&fx.svc, auth, task.task_id, "outdated block")
	testing.expect(t, !started && err.code == .Conflict, "stale retry cannot act on a newer failure")
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, !started && strings.contains(err.message, "offline"), "failed start persists offline block")
	kind, badge := user_attention(&fx.svc, get_task(fx, "task_anr"))
	testing.expect(t, kind == .Blocked && badge == "agent_not_running", "user attention")
	set_bridge_status(fx, "br_1", true)
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Internal_Error, "launch refused: no credentials")
	}}
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, !started && strings.contains(err.message, "launch refused"), "synchronous failed start reported inline")
	task = get_task(fx, "task_anr")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "no credentials"), "failure kept and updated block")
	fx.svc.bridge_command_sink = {}
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, started && err.code == .None, "retry succeeds")
	lease, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && wake_log_has_run(log, "inst_w1"), "success dispatches")
	confirm_holder(fx, "inst_w1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	task = get_task(fx, "task_anr")
	testing.expect(t, task.state == .Backlog && is_agent_not_running_block(task.blocked_on_json), "confirmed dead holder blocks")
	_, held = lease_of(fx, "inst_w1")
	testing.expect(t, !held, "dead lease released")
	attempts, _ = iface.taskchain_list_attempts_by_task(&fx.repo, lease.task_id, "u1")
	for a in attempts do testing.expect(t, !a.counts_toward_budget, "infrastructure never spends budget")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "anr")
	_, forbidden := start_task_agent(&fx.svc, contracts.Auth_Context{kind = .User_Token, user_id = "someone_else"}, task.task_id)
	testing.expect_value(t, forbidden.code, domain.Error_Code.Not_Found)
}

@(test)
test_agent_not_running_capacity_is_queueing_and_failed_ready_is_blocked :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_capacity")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_capacity")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_occupied")
	set_bridge_status(fx, "br_1", false)
	queued := publish_task(t, fx, chain, "task_queued")
	testing.expect(t, queued.state == .Ready && queued.blocked_on_json == "", "full row remains queued even offline")
	set_bridge_status(fx, "br_1", true)
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "failed"
	inst.last_error_json = "{\"message\":\"provider authentication failed\",\"class\":\"recoverable\"}"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_w1")
	queued = get_task(fx, "task_queued")
	testing.expect(t, queued.state == .Backlog && strings.contains(queued.blocked_on_json, "provider authentication failed"), "failed free instance blocks ready task")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, queued.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
}

@(test)
test_agent_not_running_heartbeat_loss_refunds :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_heartbeat")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_heartbeat")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_heartbeat")
	confirm_holder(fx, "inst_w1")
	lease, _ := lease_of(fx, "inst_w1")
	u, begun, _ := begin_uow(&fx.svc)
	if !testing.expect(t, begun, "begin") do return
	fixture_advance(fx, LEASE_TTL_SECONDS + 1)
	result := expire_lease_in_uow(&fx.svc, &u, lease, EXPIRE_TTL, hub_actor())
	_, _ = end_uow(&fx.svc, &u, result == .Expired)
	testing.expect_value(t, result, Expire_Result.Expired)
	task := get_task(fx, "task_heartbeat")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "ttl"), "heartbeat lost parks task")
}


@(test)
test_agent_not_running_unresolvable_provider_and_model :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_model")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_model")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped")
	pv_impl := sqlite.Provider_Repo_SQLite{conn = &fx.conn}
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	ag_service := agent.Agent_Service{providers = &pv_repo}
	fx.svc.agent_service = &ag_service
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	fleets[0].provider = "unknown-provider"
	fleets[0].model = "unknown-model"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	task := publish_task(t, fx, chain, "task_unknown_provider")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "unknown-provider"), "unknown provider blocks before grant")
	fleets[0].provider = "claude"
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	task = publish_task(t, fx, chain, "task_unknown_model")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "unknown-model"), "unknown model blocks before grant")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, len(attempts), 0)
}

@(test)
test_agent_not_running_solo_start_launches_only_on_user_action :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_solo")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_anr_solo")
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	task := publish_solo_task(t, fx, chain, "task_solo_anr")
	testing.expect(t, task.state == .Backlog && is_agent_not_running_block(task.blocked_on_json), "dead solo coordinator blocks ready work")
	testing.expect(t, !wake_log_has_run(log, "inst_coord"), "no automatic coordinator wake")

	pr_impl: sqlite.Project_Repo_SQLite
	pr_repo := sqlite.new_project_repository(&pr_impl, &fx.conn)
	co_impl: sqlite.Content_Repo_SQLite
	co_repo := sqlite.new_content_repository(&co_impl, &fx.conn)
	pv_impl: sqlite.Provider_Repo_SQLite
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	_, _ = iface.bridge_provider_status_upsert(&pv_repo, domain.Bridge_Provider_Status{bridge_id = "br_1", provider = "claude", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&pv_repo, domain.Bridge_Provider_Setting{bridge_id = "br_1", provider = "claude", enabled = true})
	_, _, _ = iface.agent_save_support(&fx.agents, domain.Agent_Bridge_Support{agent_id = "agt_c", bridge_id = "br_1", owner_user_id = "u1", enabled = true})
	registry := project.Bridge_Runtime_Registry{}
	project.bridge_runtime_registry_mark_live(&registry, "br_1", false, "")
	refuse := true
	sink := project.Bridge_Command_Sink{ctx = &refuse, send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		if (^bool)(ctx)^ do return false, domain.domain_error(.Internal_Error, "solo launch refused")
		return true, domain.Domain_Error{}
	}}
	ag_service := agent.new_agent_service_with_runtime(&fx.agents, &fx.bridges, &pr_repo, &co_repo, &fx.repo, sink, &registry, &fx.clock, &fx.ids)
	ag_service.providers = &pv_repo
	fx.svc.agent_service = &ag_service
	auth := contracts.Auth_Context{kind = .User_Token, user_id = "u1"}
	started, err := start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, !started && strings.contains(err.message, "solo launch refused"), "explicit failed launch returned")
	task = get_task(fx, "task_solo_anr")
	testing.expect(t, task.state == .Backlog && strings.contains(task.blocked_on_json, "solo launch refused"), "failed solo start remains blocked with updated reason")
	refuse = false
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, started && err.code == .None, "explicit solo start succeeded")
	coord, _, _ = iface.agent_get_instance(&fx.agents, "inst_coord")
	testing.expect_value(t, coord.runtime_status, "launching")
	task = get_task(fx, "task_solo_anr")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "successful solo start clears block")
	_, held := lease_of(fx, "inst_coord")
	testing.expect(t, !held && !wake_log_has_run(log, "inst_coord"), "matcher remains pull-only")
	coord.runtime_status = "running"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	res, pulled, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, pulled && res.status == "granted", "started solo coordinator pulls task")
}

@(test)
test_agent_not_running_capacity_accounts_for_manual_extra_instances :: proc(t: ^testing.T) {
	instances := make([dynamic]domain.Agent_Instance)
	append(&instances,
		domain.Agent_Instance{agent_instance_id = "held", agent_id = "agt", bridge_id = "br", runtime_status = "running"},
		domain.Agent_Instance{agent_instance_id = "free", agent_id = "agt", bridge_id = "br", runtime_status = "running"},
	)
	held := make(map[string]bool)
	defer delete(held)
	defer delete(instances)
	held["held"] = true
	ctx := Match_Context{instances = instances, held = held}
	testing.expect(t, fleet_row_full(&ctx, domain.Task_Chain_Fleet{agent_id = "agt", capacity = 1}, Placement{bridge_id = "br"}), "manual extra instance cannot bypass full capacity")
	testing.expect(t, !fleet_row_full(&ctx, domain.Task_Chain_Fleet{agent_id = "agt", capacity = 2}, Placement{bridge_id = "br"}), "free capacity is available")
}
