package taskv2

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"

requirements_test_change :: proc(t: ^testing.T, fx: ^Fixture, id, brief: string, expected: i64) {
	task := get_task(fx, id)
	u, ok, _ := begin_uow(&fx.svc)
	if !testing.expect(t, ok) do return
	err := requirements_record(&fx.repo, &fx.clock, task, brief, {kind = ACTOR_USER, id = "u1"}, expected, "Updated requirement", "")
	if !testing.expectf(t, err.code == .None, "record: %s", err.message) { _, _ = end_uow(&fx.svc, &u, false); return }
	task.brief_json = brief
	_, saved, _ := iface.taskchain_save_task(&fx.repo, task)
	if !testing.expect(t, saved) { _, _ = end_uow(&fx.svc, &u, false); return }
	err = task_updated(&fx.svc, task, {kind = ACTOR_USER, id = "u1"}, []string{"brief"})
	_, cerr := end_uow(&fx.svc, &u, err.code == .None)
	testing.expectf(t, err.code == .None && cerr.code == .None, "update: %s %s", err.message, cerr.message)
}

Requirements_Notice_Probe :: struct { attempts: int, fail: bool }
requirements_test_send :: proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	probe := (^Requirements_Notice_Probe)(ctx)
	if strings.contains(cmd.body_json, "requirements changed") {
		probe.attempts += 1
		if probe.fail do return false, domain.domain_error(.Internal_Error, "synthetic offline")
	}
	return true, {}
}

requirements_test_ack :: proc(fx: ^Fixture, id: string, revision: i64) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	lease, _ := lease_of(fx, id)
	return lease_heartbeat(&fx.svc, inst_auth(id), {lease_id = lease.lease_id, acknowledge_requirements_revision = revision})
}

@(test)
test_requirements_notice_retry_restart_rollback_and_ack :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "requirements_retry")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_requirements")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	original, _ := lease_of(fx, "inst_w1")
	probe := Requirements_Notice_Probe{fail = true}
	fx.svc.bridge_command_sink = {ctx = &probe, send_runtime_command = requirements_test_send}
	outer, begun, _ := iface.unit_of_work_begin(&fx.uow)
	if !testing.expect(t, begun) do return
	requirements_test_change(t, fx, "task_1", `{"goal":"rolled back","acceptance":["a"],"review_roles":[]}`, 1)
	testing.expect_value(t, probe.attempts, 0)
	iface.unit_of_work_rollback(&outer)
	state, _ := requirements_read(&fx.repo, task)
	testing.expect_value(t, state.revision, i64(1))
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a"],"review_roles":[]}`, 1)
	testing.expect_value(t, probe.attempts, 1)
	for _ in 0..<100 do timers_arm(&fx.svc, .Requirements_Notice, "task_1", now_ms(&fx.clock) + 1000, "")
	notice_timers := 0
	for timer in fx.svc.timers.heap do if timer.kind == .Requirements_Notice && timer.key == "task_1" do notice_timers += 1
	testing.expect_value(t, notice_timers, 1)
	held, _ := lease_of(fx, "inst_w1")
	testing.expect_value(t, held.lease_id, original.lease_id)
	// A failed send is still pending; retries are rate limited, not forgotten.
	fixture_advance(fx, 61)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, probe.attempts, 2)
	// A fresh engine with no in-memory timers reconstructs delivery from SQLite.
	restarted := new_service(&fx.repo, &fx.agents, &fx.bridges, &fx.clock, &fx.ids)
	restarted.uow_factory = &fx.uow
	restarted.bridge_command_sink = fx.svc.bridge_command_sink
	fixture_advance(fx, 61)
	boot(&restarted)
	testing.expect_value(t, probe.attempts, 3)
	// Explicit ack cannot skip fetching the current context.
	_, premature, perr := requirements_test_ack(fx, "inst_w1", 2)
	testing.expect(t, !premature && perr.code == .Conflict)
    _, _, _ = lease_next(&fx.svc, inst_auth("inst_w1"), {peek = true})
    _, peek_ack, _ := requirements_test_ack(fx, "inst_w1", 2)
    testing.expect(t, !peek_ack, "a read-only peek does not refresh TASK.md or authorize acknowledgement")
	_, wrong_lease, _ := lease_heartbeat(&fx.svc, inst_auth("inst_w1"), {lease_id = "old_lease", acknowledge_requirements_revision = 2})
	testing.expect(t, !wrong_lease, "acknowledgement names the exact lease")
	res, fetched, _ := lease_next(&fx.svc, inst_auth("inst_w1"), {})
	testing.expect(t, fetched && strings.contains(res.pack_json, "g2") && strings.contains(res.pack_json, "acknowledgement_required"))
	_, acked, aerr := lease_heartbeat(&fx.svc, inst_auth("inst_w1"), {lease_id = original.lease_id, acknowledge_requirements_revision = 2})
	testing.expectf(t, acked, "ack: %s", aerr.message)
	_, duplicate, _ := requirements_test_ack(fx, "inst_w1", 2)
	testing.expect(t, duplicate)
	testing.expect_value(t, count_events(fx, "task_1", EV_REQUIREMENTS_ACKNOWLEDGED), 1)
	fixture_advance(fx, 61)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect_value(t, probe.attempts, 3)
	// An edit racing an already-read context invalidates ack and submission.
	requirements_test_change(t, fx, "task_1", `{"goal":"g3","acceptance":["a"],"review_roles":[]}`, 2)
	_, stale_ack, _ := requirements_test_ack(fx, "inst_w1", 2)
	testing.expect(t, !stale_ack)
	_, stale_submit, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), {lease_id = original.lease_id, summary = "old work", requirements_revision = 2})
	testing.expect(t, !stale_submit && serr.code == .Conflict)
	_, _, _ = lease_next(&fx.svc, inst_auth("inst_w1"), {})
	_, _, _ = requirements_test_ack(fx, "inst_w1", 3)
	done, submitted, derr := lease_submit(&fx.svc, inst_auth("inst_w1"), {lease_id = original.lease_id, summary = "current work", requirements_revision = 3, vcs_json = `{"head":"current-head","dirty":false}`})
	testing.expectf(t, submitted && done.task.state == .Done, "current submit: %s", derr.message)
}

@(test)
test_requirements_change_waiting_for_user_starts_rework :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "requirements_user_wait")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_req_user_wait")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), {summary = "v1", vcs_json = `{"head":"h1"}`})
	if !testing.expect(t, submitted) do return
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a"],"review_roles":[]}`, 1)
	worker, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && worker.attempt_no == 2, "no reviewer to checkpoint; rework starts immediately")
	_, stale, _ := user_review(&fx.svc, user_auth(), task.task_id, {verdict = "approve"})
	testing.expect(t, !stale, "old attention card cannot approve the new attempt")
}

@(test)
test_requirements_review_change_checkpoints_and_invalidates_verdicts :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "requirements_review")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_req_review")
	seed_fleet(fx, chain, "agt_w")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	task.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), {summary = "v1", vcs_json = `{"head":"h1"}`})
	if !testing.expect(t, submitted) do return
	_, approved, _ := review_post(&fx.svc, inst_auth("inst_r1"), {verdict = "approve"})
	testing.expect(t, approved)
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a","new"],"review_roles":["reviewer"]}`, 1)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	review_lease, still := lease_of(fx, "inst_r2")
	testing.expect(t, still && review_lease.kind == domain.LEASE_KIND_REVIEW, "active reviewer is not killed")
	_, late, _ := review_post(&fx.svc, inst_auth("inst_r2"), {verdict = "approve"})
	testing.expect(t, !late, "old verdict rejected")
	_, human_late, _ := user_review(&fx.svc, user_auth(), task.task_id, {verdict = "approve"})
	testing.expect(t, !human_late, "old user approval rejected")
	fresh, read, _ := lease_next(&fx.svc, inst_auth("inst_r2"), {})
	testing.expect(t, read && strings.contains(fresh.pack_json, `"review_checkpoint_required":true`) && strings.contains(fresh.pack_json, "h1"))
	_, checkpointed, cerr := lease_handoff(&fx.svc, inst_auth("inst_r2"), {summary = "checkpoint obsolete review"})
	if !testing.expectf(t, checkpointed, "checkpoint: %s", cerr.message) do return
	next, has_work := lease_of(fx, "inst_w1")
	if !testing.expect(t, has_work && next.attempt_no == 2, "rework gets a fresh attempt") do return
	testing.expect_value(t, count_events(fx, "task_1", EV_REQUIREMENTS_REWORK), 1)
	testing.expect_value(t, count_events(fx, "task_1", EV_CHANGES_REQUESTED), 0)
	_, _, _ = lease_next(&fx.svc, inst_auth("inst_w1"), {})
	_, _, _ = requirements_test_ack(fx, "inst_w1", 2)
	_, s2, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), {lease_id = next.lease_id, summary = "v2", requirements_revision = 2, vcs_json = `{"head":"h2"}`})
	if !testing.expectf(t, s2, "resubmit: %s", serr.message) do return
	for id in ([]string{"inst_r1", "inst_r2"}) {
		_, live := lease_of(fx, id)
		testing.expect(t, live, "both reviewers owe fresh reviews")
		_, _, _ = lease_next(&fx.svc, inst_auth(id), {})
		_, _, _ = requirements_test_ack(fx, id, 2)
	}
	r1lease, _ := lease_of(fx, "inst_r1")
	r2lease, _ := lease_of(fx, "inst_r2")
	_, stale, _ := review_post(&fx.svc, inst_auth("inst_r1"), {lease_id = r1lease.lease_id, verdict = "approve", requirements_revision = 2, expected_attempt_no = 1, expected_head = "h1"})
	testing.expect(t, !stale)
	_, r1, _ := review_post(&fx.svc, inst_auth("inst_r1"), {lease_id = r1lease.lease_id, verdict = "approve", requirements_revision = 2, expected_attempt_no = 2, expected_head = "h2"})
	testing.expect(t, r1)
	_, stale_user, _ := user_review(&fx.svc, user_auth(), task.task_id, {verdict = "approve", requirements_revision = 2, expected_attempt_no = 2, expected_head = "h1"})
	testing.expect(t, !stale_user)
	_, user_ok, _ := user_review(&fx.svc, user_auth(), task.task_id, {verdict = "approve", requirements_revision = 2, expected_attempt_no = 2, expected_head = "h2"})
	testing.expect(t, user_ok)
	final, r2, rerr := review_post(&fx.svc, inst_auth("inst_r2"), {lease_id = r2lease.lease_id, verdict = "approve", requirements_revision = 2, expected_attempt_no = 2, expected_head = "h2"})
	testing.expectf(t, r2 && final.task.state == .Done, "current reviews: %s", rerr.message)
}
