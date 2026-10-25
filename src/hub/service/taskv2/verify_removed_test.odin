package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

// REQ-TV2-1/2: configured verification commands are gone. Review verdicts are
// the gate; legacy keys are accepted and dropped; in-flight work migrates per
// D1 (fresh review, old votes kept as audit) and D2 (legacy facets read-only).

// A named reviewer's approve completes the task with no other evidence;
// request_changes still blocks.
@(test)
test_reviewer_approve_alone_completes_task :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "tv2_approve_only")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_approve_only")
	seed_agent(fx, "agt_r")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["named-reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_ao", brief = `{"goal":"write the design note","acceptance":["note covers the three options"],"reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "note written; read it back against the acceptance list"})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, get_task(fx, "task_ao").state, domain.Task_State.In_Review)
	confirm_holder(fx, "inst_r1")
	rc, rcok, rcerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", summary = "option C is missing"})
	if !testing.expect(t, rcok, fmt.tprintf("request_changes: %s", rcerr.message)) do return
	testing.expect_value(t, rc.gate, Gate_Result.Changes_Requested)
	testing.expect(t, get_task(fx, "task_ao").state != .Done, "request_changes blocks completion")
	confirm_holder(fx, "inst_w1")
	_, s2ok, s2err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "added option C"})
	if !testing.expect(t, s2ok, fmt.tprintf("submit 2: %s", s2err.message)) do return
	confirm_holder(fx, "inst_r1")
	ap, apok, aperr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	if !testing.expect(t, apok, fmt.tprintf("approve: %s", aperr.message)) do return
	testing.expect_value(t, ap.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, "task_ao").state, domain.Task_State.Done)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "approve only")
}

// D1 end to end: a task in review whose gate waited on the independent-verify
// facet, with an approval given under the old regime. Migration 129 (applied
// here to pre-removal rows, exactly as on deploy) re-keys
// the approval as audit and strips the brief; the next boot re-evaluates the
// gate, which does NOT auto-complete; the reviewer owes (and gets) a fresh
// review on the same attempt, and its approve completes the task. A task whose
// only gate was the command now waits on the user instead of completing.
@(test)
test_d1_verify_waiting_task_gets_fresh_review_after_migration :: proc(t: ^testing.T) {
	fx, log, ok0 := lease_fixture(t, "tv2_d1")
	defer lease_fixture_close(fx, log)
	if !ok0 do return
	// the fixture database is fully migrated: consume the marker its own 129
	// run left, so the one this test's deploy leaves is the one boot sees
	_, _ = iface.taskchain_take_boot_regate(&fx.repo)
	sql := sqlite.migration_sql("129_remove_task_verify.sql", "")
	chain := seed_live_chain(t, fx, "chain_d1")
	seed_agent(fx, "agt_r")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_d1", brief = `{"goal":"g","acceptance":["a"],"verify":"make test","require_independent_verify":true,"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done"})
	if !testing.expect(t, sok, fmt.tprintf("submit d1: %s", serr.message)) do return
	_ = publish_task(t, fx, chain, "task_solo_cmd", brief = `{"goal":"g","acceptance":["a"],"verify":"make test","require_independent_verify":true,"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	_, s2ok, s2err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done"})
	if !testing.expect(t, s2ok, fmt.tprintf("submit solo: %s", s2err.message)) do return
	// The pre-removal hub kept task_solo_cmd in review (its gate was the verify);
	// pin that state the way the old fold left it.
	solo := get_task(fx, "task_solo_cmd")
	solo.state = .In_Review
	_, _, _ = iface.taskchain_save_task(&fx.repo, solo)
	d1 := get_task(fx, "task_d1")
	testing.expect_value(t, d1.state, domain.Task_State.In_Review)
	// the old-regime approval (posted while the gate still waited on the verify)
	_, _, _ = iface.taskchain_save_review(&fx.repo, domain.Task_Review{task_id = d1.task_id, chain_id = d1.chain_id, owner_user_id = "u1", attempt_no = d1.attempt_no, role = "reviewer", reviewer_kind = "agent", reviewer_agent_id = "agt_r", reviewer_instance_id = "inst_old", verdict = "approve", findings_json = "[]", created_at = "2026-03-01T00:00:00Z"})

	if !testing.expect(t, sqlite.exec(&fx.conn, sql), "migration 129 applies") do return
	d1 = get_task(fx, "task_d1")
	for key in ([]string{`"verify"`, "require_independent_verify"}) {
		testing.expectf(t, !strings.contains(d1.brief_json, key), "M1 strips %s", key)
	}
	reviews, _ := iface.taskchain_list_reviews_by_task(&fx.repo, d1.task_id, "u1")
	testing.expect(t, len(reviews) == 1 && reviews[0].role == "legacy-verify:reviewer" && reviews[0].verdict == "approve", "old approval kept as an audit row under the legacy role")
	testing.expect_value(t, count_events(fx, "task_d1", "reviews_superseded"), 1)
	testing.expect(t, get_task(fx, "task_solo_cmd").requires_user_approval, "command-only gate becomes a user approval")

	// idempotence: a second application changes nothing
	testing.expect(t, sqlite.exec(&fx.conn, sql), "129 re-runs cleanly")
	reviews, _ = iface.taskchain_list_reviews_by_task(&fx.repo, d1.task_id, "u1")
	testing.expect(t, len(reviews) == 1 && reviews[0].role == "legacy-verify:reviewer", "re-run does not re-key again")
	testing.expect_value(t, count_events(fx, "task_d1", "reviews_superseded"), 1)
	testing.expect_value(t, get_task(fx, "task_d1").brief_json, d1.brief_json)

	// boot: one gate re-evaluation; nothing completes on the old approval
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	boot(&fx.svc)
	testing.expect_value(t, get_task(fx, "task_d1").state, domain.Task_State.In_Review)
	testing.expect_value(t, get_task(fx, "task_solo_cmd").state, domain.Task_State.In_Review)
	taken, _ := iface.taskchain_take_boot_regate(&fx.repo)
	testing.expect(t, !taken, "boot consumed the regate marker")
	rl, held := lease_of(fx, "inst_r1")
	if !testing.expect(t, held && rl.kind == domain.LEASE_KIND_REVIEW && rl.task_id == d1.task_id, "the reviewer owes a fresh review on the same attempt") do return
	testing.expect_value(t, rl.attempt_no, d1.attempt_no)
	confirm_holder(fx, "inst_r1")
	ap, apok, aperr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	if !testing.expect(t, apok, fmt.tprintf("fresh approve: %s", aperr.message)) do return
	testing.expect_value(t, ap.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, "task_d1").state, domain.Task_State.Done)
	reviews, _ = iface.taskchain_list_reviews_by_task(&fx.repo, d1.task_id, "u1")
	testing.expect_value(t, len(reviews), 2) // legacy audit row + fresh verdict
}

@(test)
test_strip_removed_verify_keys :: proc(t: ^testing.T) {
	clean, removed := strip_removed_verify_keys(`{"goal":"g","verify":"make test","acceptance":["a"],"auto_submit":true,"require_independent_verify":false,"inputs":[]}`)
	testing.expect_value(t, clean, `{"goal":"g","acceptance":["a"],"inputs":[]}`)
	testing.expect(t, len(removed) == 3 && removed[0] == "verify" && removed[1] == "auto_submit" && removed[2] == "require_independent_verify", "removed fields in source order")
	same := `{"goal":"g", "acceptance":["a"]}`
	unchanged, none := strip_removed_verify_keys(same)
	testing.expect(t, unchanged == same && len(none) == 0, "a clean brief is returned verbatim")
	nested, _ := strip_removed_verify_keys(`{"goal":"g","output":{"verify":"kept"}}`)
	testing.expect_value(t, nested, `{"goal":"g","output":{"verify":"kept"}}`)

	specs, sr := strip_removed_verify_keys_in_task_specs(`[{"title":"a","verify":"x"},{"title":"b","brief":{"goal":"g","acceptance":["a"],"require_independent_verify":true}}]`)
	testing.expect_value(t, specs, `[{"title":"a"},{"title":"b","brief":{"goal":"g","acceptance":["a"]}}]`)
	testing.expect(t, len(sr) == 2, "both spec-level and brief-level keys reported")

	wf, wr := strip_removed_verify_keys_in_workflow_spec(`{"name":"w","defaults":{"priority":"p2","auto_submit":true},"stages":[{"key":"a","brief":{"goal":"g","acceptance":["x"],"verify":"{{inputs.verify_cmd}}"}},{"key":"b","kind":"gate"}]}`)
	testing.expect_value(t, wf, `{"name":"w","defaults":{"priority":"p2"},"stages":[{"key":"a","brief":{"goal":"g","acceptance":["x"]}},{"key":"b","kind":"gate"}]}`)
	testing.expect(t, len(wr) == 2, "defaults and stage keys reported")
	testing.expect_value(t, verify_removed_warnings_json(nil), "")
	testing.expect_value(t, verify_removed_warnings_json([]string{"verify"}), `[{"code":"verify_removed","fields":["verify"]}]`)
}

// A ticket with a goal and acceptance, no verify and no output contract, is
// publishable; nothing else is required (the one publish validator).
@(test)
test_publish_validator_needs_only_goal_and_acceptance :: proc(t: ^testing.T) {
	chain := domain.Task_Chain{chain_id = "c", owner_user_id = "u1"}
	testing.expect_value(t, len(brief_publish_missing(nil, chain, .Task, `{"goal":"research","acceptance":["options compared"]}`)), 0)
	missing := brief_publish_missing(nil, chain, .Task, `{"goal":"","verify":"make test","output":{"schema":"findings.v1"}}`)
	testing.expect(t, len(missing) == 2 && missing[0] == "goal" && missing[1] == "acceptance", "a command or output never stands in for goal/acceptance")
	testing.expect_value(t, len(brief_publish_missing(nil, chain, .Gate, `{}`)), 0)
}

// Built-in workflows parse, carry no verify keys, and their task stages need
// only goals and acceptance.
@(test)
test_builtin_workflows_have_no_verify :: proc(t: ^testing.T) {
	for tpl in workflow_builtin_templates() {
		testing.expectf(t, !strings.contains(tpl.spec_json, `"verify"`) && !strings.contains(tpl.spec_json, "verify_cmd"), "%s has no verify keys", tpl.name)
		testing.expectf(t, !strings.contains(tpl.title, "Verify"), "%s title", tpl.name)
		_, ok, err := parse_and_validate_workflow_spec(tpl.spec_json)
		testing.expectf(t, ok, "%s parses: %s", tpl.name, err.message)
	}
	_, ok, err := parse_and_validate_workflow_spec(`{"name":"bad","stages":[{"key":"a","brief":{"goal":"g","verify":"make test"}}]}`)
	testing.expect(t, !ok && strings.contains(err.message, "acceptance"), "a verify command no longer satisfies a stage brief")
}
