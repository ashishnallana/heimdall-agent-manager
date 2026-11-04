package taskv2

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"

recovery_input :: proc(t: ^testing.T, fx: ^Fixture, task: domain.Task, id := "", role := "") -> Placement_Recovery_Input {
	failures, err := placement_failures(&fx.svc, task)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	for f in failures {
		if id != "" && f.agent_id != id do continue
		if role != "" && f.role != role do continue
		return Placement_Recovery_Input{
			expected_attempt = task.attempt_no, phase = f.phase, agent_id = f.agent_id,
			role = f.role, fingerprint = f.fingerprint, configuration = f.configuration,
			expected_assignment = brief_assignee(task.brief_json) if f.phase == "work" else f.agent_id,
			action = "change_bridge", bridge_id = "br_1", scope = "ticket" if f.phase == "work" else "chain_fleet",
		}
	}
	testing.expect(t, false, "expected placement failure")
	return {}
}

@(test)
test_placement_recovery_independent_review_targets_and_fleet_scope :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recover_parallel")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_recover_parallel")
	seed_bridge(fx, "br_off", false)
	for id in ([]string{"agt_a", "agt_b", "agt_d"}) do seed_agent(fx, id)
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_a", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_b", roles = `["reviewer","security"]`, bridge_id = "br_off")
	seed_fleet(fx, chain, "agt_d", roles = `["reviewer"]`, bridge_id = "br_off")
	seed_instance(fx, chain, "inst_w", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_a", "agt_a", "br_1", "idle")
	seed_instance(fx, chain, "inst_b", "agt_b", "br_1", "idle")
	seed_instance(fx, chain, "inst_d", "agt_d", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_recover_parallel", brief = `{"goal":"g","review_roles":["reviewer","security"],"reviewers":["agt_b"]}`, bridge_pin = "br_1")
	confirm_holder(fx, "inst_w")
	_, submitted, serr := lease_submit(&fx.svc, inst_auth("inst_w"), Submit_Input{summary = "ready", vcs_json = `{"head":"h","dirty":false}`})
	if !testing.expect(t, submitted, serr.message) do return
	task = get_task(fx, string(task.task_id))
	input_b := recovery_input(t, fx, task, "agt_b", "security")
	input_d := recovery_input(t, fx, task, "agt_d", "reviewer")
	active_a, _ := lease_of(fx, "inst_a")
	role_edit := input_b
	role_edit.action, role_edit.replacement_agent_id, role_edit.scope = "change_reviewer", "agt_a", "ticket"
	_, replaced_role, role_err := recover_placement(&fx.svc, user_auth(), task.task_id, role_edit)
	testing.expect(t, !replaced_role && role_err.code == .Conflict, "role replacement routes to fleet configuration, never removes role")
	_, fixed_b, berr := recover_placement(&fx.svc, user_auth(), task.task_id, input_b)
	if !testing.expect(t, fixed_b, berr.message) do return
	// The other failure was observed before this repair. An unrelated fleet
	// target must remain actionable, while b's old target is now stale.
	_, fixed_d, derr := recover_placement(&fx.svc, user_auth(), task.task_id, input_d)
	testing.expect(t, fixed_d, derr.message)
	_, duplicate_b, duplicate_err := recover_placement(&fx.svc, user_auth(), task.task_id, input_b)
	testing.expect(t, !duplicate_b && duplicate_err.code == .Conflict, "old repaired role rejected")
	after_a, held := lease_of(fx, "inst_a")
	testing.expect(t, held && after_a.lease_id == active_a.lease_id, "unrelated active lease not migrated")
	b, b_held := lease_of(fx, "inst_b")
	d, d_held := lease_of(fx, "inst_d")
	testing.expect(t, b_held && d_held && b.bridge_id == "br_1" && d.bridge_id == "br_1", "both repaired targets dispatch")
	fresh := get_task(fx, string(task.task_id))
	testing.expect_value(t, fresh.bridge_id, task.bridge_id)
	testing.expect_value(t, fresh.brief_json, task.brief_json)
	testing.expect_value(t, placement_count(fx, string(task.task_id)), 0)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "fleet repair")
}

@(test)
test_placement_recovery_provider_and_owned_identity_validation :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recover_provider")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_recover_provider")
	seed_bridge(fx, "br_off", false)
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_off")
	_, foreign_saved, foreign_save_err := iface.agent_save(&fx.agents, domain.Agent{
		agent_id = "agt_other", owner_user_id = "other_owner", name = "Other", slug = "other", template_id = domain.TEMPLATE_EMPTY_ID,
	})
	testing.expect(t, foreign_saved, foreign_save_err.message)
	seed_fleet(fx, chain, "agt_other", bridge_id = "br_1")
	task := publish_task(t, fx, chain, "task_recover_provider", brief = `{"goal":"g","assignee":"agt_w","review_roles":[]}`)
	input := recovery_input(t, fx, task)
	input.action, input.replacement_agent_id = "change_assignee", "agt_other"
	_, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !repaired && err.code == .Validation_Failed, "foreign durable identity rejected even with a fleet row")
	input.action = "change_bridge"
	provider_impl: sqlite.Provider_Repo_SQLite
	providers := sqlite.new_provider_repository(&provider_impl, &fx.conn)
	agents := agent.new_agent_service(&fx.agents, &fx.bridges, &fx.clock, &fx.ids)
	agents.providers = &providers
	fx.svc.agent_service = &agents
	_, repaired, err = recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !repaired && err.code == .Validation_Failed && (strings.contains(err.message, "provider") || strings.contains(err.message, "model")), "destination provider/model availability validated before mutation")
	fresh := get_task(fx, string(task.task_id))
	testing.expect_value(t, fresh.bridge_id, task.bridge_id)
	testing.expect_value(t, fresh.brief_json, task.brief_json)
}

@(test)
test_placement_recovery_owner_guards_and_duplicate :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recover_guards")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_recover_guards")
	seed_agent(fx, "agt_w")
	seed_bridge(fx, "br_off", false)
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_off")
	seed_instance(fx, chain, "inst_w", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_recover_guards")
	input := recovery_input(t, fx, task)
	before := count_events(fx, string(task.task_id), EV_UPDATED)
	for auth in ([]contracts.Auth_Context{inst_auth("inst_w"), {kind = .Session, user_id = "foreign"}}) {
		_, repaired, err := recover_placement(&fx.svc, auth, task.task_id, input)
		testing.expect(t, !repaired && (err.code == .Forbidden || err.code == .Not_Found), "owner only")
	}
	for field in ([]string{"attempt", "assignment", "fingerprint", "configuration", "target", "scope"}) {
		bad := input
		switch field {
		case "attempt": bad.expected_attempt += 1
		case "assignment": bad.expected_assignment = "forged"
		case "fingerprint": bad.fingerprint = "forged"
		case "configuration": bad.configuration = "forged"
		case "target": bad.role = "security"
		case "scope": bad.scope = "chain_fleet"
		}
		_, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, bad)
		testing.expect(t, !repaired && err.code != .None, field)
	}
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_UPDATED), before)
	fixed, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	if !testing.expect(t, repaired && err.code == .None, err.message) do return
	testing.expect_value(t, fixed.bridge_id, "br_1")
	lease, held := lease_of(fx, "inst_w")
	testing.expect(t, held && lease.attempt_no == 1, "repair schedules one normal grant")
	live_input := input
	live_input.expected_attempt = lease.attempt_no
	_, moved_live, live_err := recover_placement(&fx.svc, user_auth(), task.task_id, live_input)
	testing.expect(t, !moved_live && live_err.code == .Conflict && strings.contains(live_err.message, "checkpoint"), "live target gets checkpoint guidance without migration")
	before = count_events(fx, string(fixed.task_id), EV_UPDATED)
	_, repeated, rerr := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !repeated && rerr.code == .Conflict, "duplicate observation rejected")
	testing.expect_value(t, count_events(fx, string(fixed.task_id), EV_UPDATED), before)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "recovered worker")
}

@(test)
test_placement_recovery_named_reviewer_preserves_parallel_requirements :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recover_named")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_recover_named")
	seed_bridge(fx, "br_off", false)
	for id in ([]string{"agt_w", "agt_a", "agt_b", "agt_done", "agt_new"}) do seed_agent(fx, id)
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w", "agt_w", "br_1", "idle")
	for id in ([]string{"agt_a", "agt_b", "agt_done", "agt_new"}) {
		seed_fleet(fx, chain, id, roles = `["named-reviewer"]`, bridge_id = "br_off" if id == "agt_b" else "br_1")
	}
	seed_instance(fx, chain, "inst_a", "agt_a", "br_1", "idle")
	seed_instance(fx, chain, "inst_c", "agt_done", "br_1", "idle")
	seed_instance(fx, chain, "inst_new", "agt_new", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_recover_named", brief = `{"goal":"g","acceptance":["x"],"review_roles":[],"reviewers":["agt_a","agt_b","agt_done"]}`)
	confirm_holder(fx, "inst_w")
	_, submitted, serr := lease_submit(&fx.svc, inst_auth("inst_w"), Submit_Input{summary = "ready", vcs_json = `{"head":"h","dirty":false}`})
	if !testing.expect(t, submitted, serr.message) do return
	_, reviewed, rerr := review_post(&fx.svc, inst_auth("inst_c"), Review_Input{verdict = "approve"})
	if !testing.expect(t, reviewed, rerr.message) do return
	task = get_task(fx, string(task.task_id))
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	lease_a, _ := lease_of(fx, "inst_a")
	before, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	input := recovery_input(t, fx, task, "agt_b", NAMED_REVIEW_ROLE)
	input.action, input.replacement_agent_id, input.scope = "change_reviewer", "agt_new", "ticket"
	fixed, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	if !testing.expect(t, repaired, err.message) do return
	testing.expect(t, fixed.requires_user_approval && fixed.state == .In_Review && fixed.attempt_no == task.attempt_no, "business gate preserved")
	testing.expect(t, strings.contains(fixed.brief_json, "agt_new") && !strings.contains(fixed.brief_json, "agt_b") && strings.contains(fixed.brief_json, "agt_a") && strings.contains(fixed.brief_json, "agt_done"), "targeted replacement")
	after_a, held := lease_of(fx, "inst_a")
	testing.expect(t, held && after_a.lease_id == lease_a.lease_id, "unrelated active reviewer preserved")
	after, _ := iface.taskchain_list_reviews_by_task(&fx.repo, task.task_id, "u1")
	testing.expect(t, len(before) == len(after) && before[0].verdict == after[0].verdict, "valid verdict retained")
	_, new_held := lease_of(fx, "inst_new")
	testing.expect(t, new_held, "replacement reviewer scheduled")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "recovered named reviewer")
}

@(test)
test_placement_recovery_validation_workflow_and_assignment :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "recover_validation")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_recover_validation")
	seed_agent(fx, "agt_w")
	seed_agent(fx, "agt_new")
	seed_bridge(fx, "br_off", false)
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_off")
	seed_fleet(fx, chain, "agt_new", bridge_id = "br_1")
	task := publish_task(t, fx, chain, "task_recover_validation", brief = `{"goal":"g","assignee":"agt_w","review_roles":[]}`)
	input := recovery_input(t, fx, task)
	// Fresh target configuration changes invalidate even an unmodified facet.
	seed_fleet(fx, chain, "agt_w", bridge_id = "br_off", capacity = 2)
	_, stale, stale_err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !stale && stale_err.code == .Conflict, "fresh configuration checked, not stored facet alone")
	_, _, _ = task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	input = recovery_input(t, fx, task)
	seed_directory(fx, chain, "dir_off", "br_off")
	_, _, _ = task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	input = recovery_input(t, fx, task)
	_, invalid, invalid_err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !invalid && invalid_err.code == .Validation_Failed && strings.contains(invalid_err.message, "workspace"), "cross-host workspace required")
	seed_directory(fx, chain, "dir_on", "br_1")
	_, _, _ = task_recheck(&fx.svc, task, actor_from_auth(user_auth()))
	input = recovery_input(t, fx, task)
	// Generated identity is immutable: insert a real owned running execution
	// and a generated task rather than trying to retrofit an ordinary ticket.
	workflow_uow, workflow_begun, _ := begin_uow(&fx.svc)
	if !testing.expect(t, workflow_begun, "workflow fixture transaction") do return
	_, run_saved, run_err := iface.taskchain_insert_workflow_run(&fx.repo, domain.Workflow_Run{
		run_id = "run_recovery", chain_id = chain.chain_id, owner_user_id = "u1", title = "Managed",
		definition_ref = "test@1", spec_json = `{"schema":"workflow.v1","name":"repair","stages":[{"key":"managed","kind":"gate","approver":"user"}]}`, inputs_json = "{}", current_execution_no = 1,
		request_id = "recovery", request_hash = "hash", created_by_kind = "user", created_by_id = "u1", revision = 1,
	})
	testing.expect(t, run_saved, run_err.message)
	_, execution_saved, execution_err := iface.taskchain_insert_workflow_execution(&fx.repo, domain.Workflow_Run_Execution{
		run_id = "run_recovery", execution_no = 1, chain_id = chain.chain_id, owner_user_id = "u1",
		state = domain.WORKFLOW_EXECUTION_RUNNING, resolved_inputs_json = "{}", output_manifest_json = "{}", revision = 1,
	})
	testing.expect(t, execution_saved, execution_err.message)
	workflow_committed, workflow_commit_err := end_uow(&fx.svc, &workflow_uow, run_saved && execution_saved)
	testing.expect(t, workflow_committed, workflow_commit_err.message)
	generated := task
	generated.task_id, generated.workflow_run_id, generated.workflow_execution_no, generated.stage_key = "task_managed_recovery", "run_recovery", 1, "managed"
	_, managed_saved, managed_save_err := iface.taskchain_save_task(&fx.repo, generated)
	testing.expect(t, managed_saved, managed_save_err.message)
	_, managed, merr := recover_placement(&fx.svc, user_auth(), generated.task_id, input)
	testing.expectf(t, !managed && merr.code == .Conflict, "workflow controls retained: repaired=%v code=%v message=%s", managed, merr.code, merr.message)
	input.action, input.replacement_agent_id = "change_assignee", "inst_new"
	_, inst, ierr := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, !inst && ierr.code == .Validation_Failed, "instances are not durable identities")
	input.replacement_agent_id = "agt_new"
	seed_instance(fx, chain, "inst_new", "agt_new", "br_1", "idle")
	fixed, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
	testing.expect(t, repaired && err.code == .None && brief_assignee(fixed.brief_json) == "agt_new", err.message)
}

@(test)
test_placement_recovery_stop_consent_and_launch_failure :: proc(t: ^testing.T) {
	for stopped in ([]bool{true, false}) {
		fx, log, ok := lease_fixture(t, "recover_consent" if stopped else "recover_launch")
		defer lease_fixture_close(fx, log)
		if !ok do return
		chain := seed_live_chain(t, fx, "chain_recover_consent")
		seed_agent(fx, "agt_w")
		seed_bridge(fx, "br_off", false)
		seed_fleet(fx, chain, "agt_w", bridge_id = "br_off")
		inst := seed_instance(fx, chain, "inst_w", "agt_w", "br_1", "stopped")
		if stopped { inst.stopped_by = agent.STOPPED_BY_USER; _, _, _ = iface.agent_save_instance(&fx.agents, inst) }
		task := publish_task(t, fx, chain, "task_recover_consent")
		input := recovery_input(t, fx, task)
		fx.svc.bridge_command_sink = project.Bridge_Command_Sink{send_runtime_command = proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
			return false, domain.domain_error(.Internal_Error, "launch refused: credentials missing")
		}}
		fixed, repaired, err := recover_placement(&fx.svc, user_auth(), task.task_id, input)
		if !testing.expect(t, repaired && err.code == .None, err.message) do continue
		testing.expect(t, is_agent_not_running_block(fixed.blocked_on_json), "process error stays actionable after placement repair")
		if stopped {
			after, _, _ := iface.agent_get_instance(&fx.agents, "inst_w")
			testing.expect_value(t, after.stopped_by, agent.STOPPED_BY_USER)
			testing.expect(t, !wake_log_has_run(log, "inst_w"), "no implicit Start consent")
		} else {
			testing.expect(t, strings.contains(fixed.blocked_on_json, "credentials missing"), "post-commit launch failure remains visible")
		}
		attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
		for a in attempts do testing.expect(t, !a.counts_toward_budget, "infrastructure launch failure does not spend attempts")
	}
}
