package taskv2

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

@(test)
test_dispatch_exit_blocks_notifies_refunds_and_unblocks :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "dispatch_exit")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_dispatch")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	notices := 0
	fx.svc.notify_observer_ctx = &notices
	fx.svc.notify_observer = proc(ctx: rawptr, coord_id, trigger, line: string) {
		if trigger == "agent_not_running" && coord_id == "inst_coord" && strings.contains(line, "Agent agt_w (claude/claude-opus-5-5) on bridge br_1 is not running: authentication failed") {
			(^int)(ctx)^ += 1
		}
	}
	_ = publish_task(t, fx, chain, "task_dispatch", brief = `{"goal":"g","review_roles":[],"budget":{"max_attempts":1}}`)
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.runtime_status = "failed"
	inst.last_error_json = `{"message":"authentication failed","cause":"provider_not_logged_in"}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	wake_log_reset(log)
	on_instance_terminal(&fx.svc, "inst_w1")
	blocked := get_task(fx, "task_dispatch")
	testing.expect_value(t, blocked.state, domain.Task_State.Backlog)
	testing.expect_value(t, jsonx.extract_string(blocked.blocked_on_json, "kind", "", true, context.temp_allocator), "agent_not_running")
	testing.expect_value(t, notices, 1)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held && !wake_log_has_run(log, "inst_w1"), "no automatic redispatch")
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, blocked.task_id, "u1")
	testing.expect(t, len(attempts) == 1 && !attempts[0].counts_toward_budget && attempts[0].outcome == "dispatch_failed" && attempts[0].ended_at != "", "failed dispatch retained as non-counting history")
	on_instance_terminal(&fx.svc, "inst_w1")
	testing.expect_value(t, notices, 1)
	// Neither an unrelated fleet edit nor the usual matching pass clears it.
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_r").code, domain.Error_Code.None)
	testing.expect_value(t, get_task(fx, "task_dispatch").state, domain.Task_State.Backlog)
	set_bridge_status(fx, "br_1", false)
	fresh, answered, err := task_answer(&fx.svc, blocked, Actor{kind = ACTOR_COORDINATOR, id = "inst_coord"}, "credentials repaired")
	testing.expect(t, answered && err.code == .None, "coordinator may unblock")
	testing.expect_value(t, fresh.state, domain.Task_State.Backlog) // offline cause is immediately re-detected
	inst.runtime_status = "stopped"
	inst.last_error_json = ""
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	set_bridge_status(fx, "br_1", true)
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_w").code, domain.Error_Code.None)
	lease, held2 := lease_of(fx, "inst_w1")
	testing.expect(t, held2 && lease.attempt_no == 2, "retry despite max_attempts=1")
	on_dispatch_failed(&fx.svc, lease.lease_id, "retry failed")
	testing.expect_value(t, get_task(fx, "task_dispatch").state, domain.Task_State.Backlog)
	// Editing the affected fleet row clears this dispatch block automatically.
	set_bridge_status(fx, "br_1", false)
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_w").code, domain.Error_Code.None)
	testing.expect_value(t, get_task(fx, "task_dispatch").state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(get_task(fx, "task_dispatch").blocked_on_json, "offline"), "fleet edit clears old block then detects remaining cause")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "dispatch")
}

@(test)
test_dispatch_send_failure_and_confirmation_race :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "dispatch_send")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_dispatch_send")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
		return false, domain.domain_error(.Internal_Error, "bridge write failed")
	}}
	_ = publish_task(t, fx, chain, "task_dispatch_send")
	blocked := get_task(fx, "task_dispatch_send")
	testing.expect_value(t, blocked.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(blocked.blocked_on_json, "bridge write failed"), "send error visible")
	fx.svc.bridge_command_sink = {}
	_, answered, _ := task_answer(&fx.svc, blocked, Actor{kind = ACTOR_USER, id = "u1"}, "reconnected")
	testing.expect(t, answered, "owner unblocks")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "retry granted") do return
	confirm_holder(fx, "inst_w1")
	on_dispatch_failed(&fx.svc, lease.lease_id, "late send error")
	current, still := lease_of(fx, "inst_w1")
	testing.expect(t, still && current.lease_id == lease.lease_id, "confirmed lease wins the race")
	testing.expect_value(t, get_task(fx, "task_dispatch_send").state, domain.Task_State.In_Progress)
}

@(test)
test_dispatch_provider_override_empty_model_matches_catalog :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "dispatch_model")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_dispatch_model")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "stopped") // old Claude selection
	pv_impl := sqlite.Provider_Repo_SQLite{conn = &fx.conn}
	pv_repo := sqlite.new_provider_repository(&pv_impl, &fx.conn)
	_, _ = iface.bridge_provider_status_upsert(&pv_repo, domain.Bridge_Provider_Status{bridge_id = "br_1", provider = "codex", state = "present"})
	_, _ = iface.bridge_provider_setting_upsert(&pv_repo, domain.Bridge_Provider_Setting{bridge_id = "br_1", provider = "codex", enabled = true})
	ag_service := agent.Agent_Service{providers = &pv_repo}
	fx.svc.agent_service = &ag_service
	fleets, _ := iface.taskchain_list_fleets_by_chain(&fx.repo, chain.chain_id, "u1")
	fleets[0].provider = "codex"
	fleets[0].model = ""
	_, _ = iface.taskchain_upsert_fleet(&fx.repo, fleets[0])
	provider, model := resolve_launch_model(&ag_service, "br_1", "codex", "")
	defer delete(provider)
	defer delete(model)
	testing.expect(t, provider == "codex" && model != "" && !strings.has_prefix(model, "claude"), "catalog resolves the provider override")
	_ = publish_task(t, fx, chain, "task_dispatch_model")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "warm instance leased") do return
	testing.expect_value(t, lease.provider, provider)
	testing.expect_value(t, lease.model, model)
	testing.expect(t, len(log.cmds) > 0 && strings.contains(log.cmds[0].body_json, model) && !strings.contains(log.cmds[0].body_json, "claude-opus-5-5"), "wake uses catalog default, never old instance model")
	runtime, found := get_facet(&fx.svc, get_task(fx, "task_dispatch_model"), 1, FACET_RUNTIME)
	testing.expect(t, found && jsonx.extract_string(runtime.body_json, "model", "", true, context.temp_allocator) == model, "runtime facet matches the launched model")
}

@(test)
test_dispatch_discovered_default_and_explicit_selection :: proc(t: ^testing.T) {
	fx,log,ok:=lease_fixture(t,"discovered_default")
	defer lease_fixture_close(fx,log)
	if !ok do return
	chain:=seed_live_chain(t,fx,"chain_discovered_default")
	seed_fleet(fx,chain,"agt_w")
	seed_instance(fx,chain,"inst_w1","agt_w","br_1","stopped")
	impl:sqlite.Provider_Repo_SQLite
	repo:=sqlite.new_provider_repository(&impl,&fx.conn)
	_,_=iface.bridge_provider_status_upsert(&repo,{bridge_id="br_1",provider="codex",state="present"})
	_,_=iface.bridge_provider_setting_upsert(&repo,{bridge_id="br_1",provider="codex",enabled=true})
	err:=iface.bridge_provider_models_upsert(&repo,{bridge_id="br_1",provider="codex",has_snapshot=true,models_json=`[{"model_id":"new-discovered-launch-id","label":"New"}]`,models_source="codex_app_server",models_state="success",models_checked_at="now",models_attempted_at="now"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	svc:=agent.Agent_Service{providers=&repo}
	fx.svc.agent_service=&svc
	selected,valid,validation_err:=agent.validate_provider_model_intersection(&svc,"br_1","codex","new-discovered-launch-id")
	testing.expect(t,valid)
	testing.expect_value(t,validation_err.code,domain.Error_Code.None)
	testing.expect_value(t,selected.model,"new-discovered-launch-id")
	p,m:=resolve_launch_model(&svc,"br_1","codex","")
	defer delete(p);defer delete(m)
	testing.expect_value(t,m,"new-discovered-launch-id")
	ep,em:=resolve_launch_model(&svc,"br_1","codex","unavailable-explicit")
	defer delete(ep);defer delete(em)
	testing.expect_value(t,em,"unavailable-explicit")
	fleets,_:=iface.taskchain_list_fleets_by_chain(&fx.repo,chain.chain_id,"u1")
	fleets[0].provider="codex";fleets[0].model=""
	_,_=iface.taskchain_upsert_fleet(&fx.repo,fleets[0])
	_=publish_task(t,fx,chain,"task_discovered_default")
	lease,held:=lease_of(fx,"inst_w1")
	testing.expect(t,held)
	testing.expect_value(t,lease.model,"new-discovered-launch-id")
	testing.expect(t,len(log.cmds)>0 && strings.contains(log.cmds[0].body_json,"new-discovered-launch-id"),"discovered ID reaches launch command unchanged")
}
