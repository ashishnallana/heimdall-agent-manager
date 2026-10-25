package taskv2

import "core:strings"
import "core:fmt"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"
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
	auth := contracts.Auth_Context{kind = .Session, user_id = "u1"}
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
	started, err = start_task_agent(&fx.svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "u1"}, task.task_id)
	testing.expect(t, !started && err.code == .Forbidden, "agents cannot start task agents")
	// The native app authenticates with an OIDC bearer, not a browser session.
	started, err = start_task_agent(&fx.svc, contracts.Auth_Context{kind = .OIDC, user_id = "u1"}, task.task_id)
	testing.expect(t, started && err.code == .None, "browser-session retry succeeds")
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
	_, forbidden := start_task_agent(&fx.svc, contracts.Auth_Context{kind = .Session, user_id = "someone_else"}, task.task_id)
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
	testing.expect_value(t, fleet_changed(&fx.svc, chain, "agt_w").code, domain.Error_Code.None)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held, "fleet repair resets idle failed instance and retries dispatch")
	testing.expect(t, get_task(fx, "task_queued").blocked_on_json == "", "fleet edit clears affected agent blocks")
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
	auth := contracts.Auth_Context{kind = .Session, user_id = "u1"}
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
	coord.runtime_status = "failed"
	coord.last_error_json = `{"code":"provider_error","class":"fatal","message":"provider credentials expired"}`
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	u, begun, _ := begin_uow(&fx.svc)
	if !testing.expect(t, begun, "rematch async solo failure") do return
	matched, _ := match_chain_in_uow(&fx.svc, &u, chain, .Instance_Terminal)
	_, _ = end_uow(&fx.svc, &u, matched)
	task = get_task(fx, "task_solo_anr")
	testing.expect(t, task.state == .Backlog, "async solo failure reblocks")
	reason := jsonx.extract_string(task.blocked_on_json, "reason", "", true, context.temp_allocator)
	testing.expect(t, strings.contains(reason, "provider credentials expired"), "async provider error visible")
	testing.expect(t, !strings.contains(reason, "{"), "provider error is readable text")
	started, err = start_task_agent(&fx.svc, auth, task.task_id)
	testing.expect(t, started && err.code == .None, "solo retry after async failure")
	coord, _, _ = iface.agent_get_instance(&fx.agents, "inst_coord")
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

@(test)
test_agent_not_running_retriable_failure_queues_until_backoff :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_backoff")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_backoff")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.stopped_at = platform.clock_now(&fx.clock)
	inst.last_error_json = `{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":120000,"attempt":1}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_backoff")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "retriable failure queues")
	fixture_advance(fx, 119)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	testing.expect_value(t, get_task(fx, string(task.task_id)).state, domain.Task_State.Ready)
	fixture_advance(fx, REMATCH_DELAYS_SECONDS[1] + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && wake_log_has_run(log, "inst_w1"), "automatic grant after backoff")
	testing.expect(t, get_task(fx, string(task.task_id)).blocked_on_json == "", "no user intervention")
}

@(test)
test_agent_not_running_reviewer_restart_preserves_rounds :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_reviewer")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_reviewer")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_review_restart", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, submitted, "first submission") do return
	_, reviewed, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", findings_json = `[{"path":"a","line":1,"severity":"major","text":"fix"}]`})
	if !testing.expect(t, reviewed, "first review") do return
	confirm_holder(fx, "inst_w1")
	_, submitted, _ = lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v2", vcs_json = `{"head":"h2","dirty":false}`})
	if !testing.expect(t, submitted, "second submission") do return
	confirm_holder(fx, "inst_r1")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	inst.runtime_status = "failed"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	on_instance_terminal(&fx.svc, "inst_r1")
	task = get_task(fx, string(task.task_id))
	testing.expect(t, is_agent_not_running_block(task.blocked_on_json), "dead reviewer blocks")
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, fold_task(evs, fold_input_for_task(task, true)).review_rounds, 1)
	started, err := start_task_agent(&fx.svc, user_auth(), task.task_id)
	testing.expect(t, started && err.code == .None, "reviewer restart")
	lease, held := lease_of(fx, "inst_r1")
	testing.expect(t, held && lease.kind == domain.LEASE_KIND_REVIEW, "review regranted")
	task = get_task(fx, string(task.task_id))
	evs, _ = iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	testing.expect_value(t, fold_task(evs, fold_input_for_task(task, true)).review_rounds, 1)
	testing.expect_value(t, task.state, domain.Task_State.In_Review)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "review restart")
}

@(test)
test_agent_not_running_hello_only_answers_matching_offline_blocks :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_anr_hello")
	seed_bridge(fx, "br_2", online = false)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	inst.last_error_json = `{"code":"provider_error","class":"fatal","message":"login required"}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	provider_task := publish_task(t, fx, chain, "task_login")
	offline_task := publish_task(t, fx, chain, "task_other_bridge", bridge_pin = "br_2")
	testing.expect(t, is_agent_not_running_block(provider_task.blocked_on_json), "provider failure blocks")
	testing.expect(t, is_agent_not_running_block(offline_task.blocked_on_json), "other bridge blocks")
	on_bridge_hello(&fx.svc, "br_1", nil)
	testing.expect_value(t, get_task(fx, "task_login").blocked_on_json, provider_task.blocked_on_json)
	testing.expect_value(t, get_task(fx, "task_other_bridge").blocked_on_json, offline_task.blocked_on_json)
	testing.expect_value(t, count_events(fx, "task_login", EV_ANSWERED), 0)
	testing.expect_value(t, count_events(fx, "task_other_bridge", EV_ANSWERED), 0)
}

// Covers bridge retry floors and exponential backoff beyond the last rematch,
// including failures after the task's standard rematch timers have expired.
@(test)
test_agent_not_running_long_backoff_retries_at_deadline :: proc(t: ^testing.T) {
	for attempt in ([]int{1, 5, 50}) {
		fx, log, ok := lease_fixture(t, fmt.tprintf("anr_long_%d", attempt))
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_anr_long")
		seed_fleet(fx, chain, "agt_w")
		seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
		task: domain.Task
		if attempt != 1 {
			_ = publish_task(t, fx, chain, "task_occupied")
			confirm_holder(fx, "inst_w1")
			task = publish_task(t, fx, chain, "task_long")
			fixture_advance(fx, 601)
			_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		}
		inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		inst.runtime_status = "failed"
		inst.stopped_at = platform.clock_now(&fx.clock)
		inst.last_error_json = fmt.tprintf(`{{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":900000,"attempt":%d}}`, attempt)
		_, saved, save_err := iface.agent_save_instance(&fx.agents, inst)
		testing.expect(t, saved, save_err.message)
		stored, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		testing.expect(t, agent.failed_instance_disposition(stored, now_ms(&fx.clock)) == .Hold, fmt.tprintf("typed failure stored: %s", stored.last_error_json))
		if attempt == 1 {
			task = publish_task(t, fx, chain, "task_long")
		} else {
			on_instance_terminal(&fx.svc, "inst_w1")
		}
		task = get_task(fx, "task_long")
		testing.expect(t, task.state == .Ready && task.blocked_on_json == "", fmt.tprintf("late failure queues task: %v %s", task.state, task.blocked_on_json))
		wake_log_reset(log)
		delay := agent.instance_retry_delay_ms(attempt, 900000)
		fixture_advance(fx, delay / 1000 - 1)
		_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		_, held := lease_of(fx, "inst_w1")
		testing.expect(t, !held && !wake_log_has_run(log, "inst_w1"), "no retry before deadline")
		fixture_advance(fx, 2)
		_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
		lease, granted := lease_of(fx, "inst_w1")
		testing.expect(t, granted && lease.task_id == task.task_id && wake_log_has_run(log, "inst_w1"), "long backoff grants without external trigger")
	}
}

@(test)
test_agent_not_running_reviewer_long_backoff_retries :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_review_backoff")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_review_backoff")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "failed")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	inst.stopped_at = platform.clock_now(&fx.clock)
	inst.last_error_json = `{"code":"bridge_busy","class":"retriable","message":"rate limited","retry_after_ms":900000,"attempt":1}`
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_review_backoff", brief = `{"goal":"g","review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, submitted, "submit for review") do return
	fixture_advance(fx, 899)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	_, held := lease_of(fx, "inst_r1")
	testing.expect(t, !held, "review waits for backoff")
	fixture_advance(fx, 2)
	_ = fire_due(&fx.svc, now_ms(&fx.clock), false)
	lease, granted := lease_of(fx, "inst_r1")
	testing.expect(t, granted && lease.kind == domain.LEASE_KIND_REVIEW && wake_log_has_run(log, "inst_r1"), "review retries after long backoff")
}

@(test)
test_agent_not_running_solo_hello_recovers_offline_coordinator :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "anr_solo_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := solo_chain(t, fx, "chain_solo_hello")
	coord, _, _ := iface.agent_get_instance(&fx.agents, "inst_coord")
	coord.runtime_status = "unreachable"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	set_bridge_status(fx, "br_1", false)
	task := publish_solo_task(t, fx, chain, "task_solo_hello")
	testing.expect(t, task.state == .Backlog && jsonx.extract_string(task.blocked_on_json, "cause", "", true, context.temp_allocator) == "bridge_offline", "solo bridge absence tagged explicitly")
	set_bridge_status(fx, "br_1", true)
	coord.runtime_status = "running"
	_, _, _ = iface.agent_save_instance(&fx.agents, coord)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_coord"})
	task = get_task(fx, "task_solo_hello")
	testing.expect(t, task.state == .Ready && task.blocked_on_json == "", "hello clears solo offline block")
	testing.expect_value(t, count_events(fx, "task_solo_hello", EV_ANSWERED), 1)
	testing.expect(t, !wake_log_has_run(log, "inst_coord") && !wake_log_has_stop(log, "inst_coord"), "solo remains pull-only")
	res, pulled, _ := lease_next(&fx.svc, inst_auth("inst_coord"), Lease_Next_Input{})
	testing.expect(t, pulled && res.status == "granted", "reconnected coordinator pulls without Start")
}
