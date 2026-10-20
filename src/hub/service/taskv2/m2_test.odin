package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// M2 tests: submit / handoff / block / review gate / facets / verify.

inst_auth :: proc(id: string) -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "u1", agent_instance_id = id}
}

user_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "u1"}
}

// write_verify simulates the hub-written verify facet for a finished verify run.
write_verify :: proc(fx: ^Fixture, task_id: string, attempt_no: int, head: string, exit_code: int, dirty := "false", status := "exited", head_end := "", cmd := "") {
	on_verify_session_exited(&fx.svc, Verify_Exit{
		session_id = fmt.tprintf("sh_%s_%d", task_id, attempt_no), label = fmt.tprintf("verify %s #%d @%s", task_id, attempt_no, head),
		owner_user_id = "u1", status = status, exit_code = exit_code, exit_code_set = status != "failed", duration_ms = 1200,
		head_at_end = head_end if head_end != "" else head, dirty = dirty, tail = "ok\n", cmd = cmd,
	})
}

@(test)
test_submit_requires_green_verify_at_head :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_verify")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_v")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"make test","review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	auth := inst_auth("inst_w1")
	// no verify facet → verify_required
	_, sok, serr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done"})
	testing.expect(t, !sok && serr.code == .Conflict && strings.contains(serr.details_json, "verify_required"), "verify_required")
	// empty summary → 422
	_, eok, eerr := lease_submit(&fx.svc, auth, Submit_Input{summary = "  "})
	testing.expect(t, !eok && eerr.code == .Validation_Failed, "summary required")
	// red verify → verify_failed
	write_verify(fx, "task_1", lease.attempt_no, "abc", 1)
	_, fok, ferr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = `{"head":"abc","dirty":false,"files":[]}`})
	testing.expect(t, !fok && strings.contains(ferr.details_json, "verify_failed"), "verify_failed")
	// green at another head → verify_stale
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0)
	_, stok, sterr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = `{"head":"def","dirty":false,"files":[]}`})
	testing.expect(t, !stok && strings.contains(sterr.details_json, "verify_stale"), "verify_stale")
	// green on a dirty tree → verify_dirty
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0, dirty = "true")
	_, dok, derr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = `{"head":"abc","dirty":false,"files":[]}`})
	testing.expect(t, !dok && strings.contains(derr.details_json, "verify_dirty"), "verify_dirty")
	// green verify, but working tree dirtied before submit → verify_dirty (M2-M1)
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0, dirty = "false")
	_, sdok, sderr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = `{"head":"abc","dirty":true,"files":[]}`})
	testing.expect(t, !sdok && strings.contains(sderr.details_json, "verify_dirty"), "submit dirty tree → verify_dirty")
	// green verify with mismatched command → verify_required (M2-C3)
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0, dirty = "false", cmd = "true")
	_, cmok, cmerr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", vcs_json = `{"head":"abc","dirty":false,"files":[]}`})
	testing.expect(t, !cmok && strings.contains(cmerr.details_json, "verify_required"), "mismatched verify command rejected")
	// verify:none without an output contract → refused
	_, nok, nerr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", verify = "none"})
	testing.expect(t, !nok && strings.contains(nerr.details_json, "verify_required"), "verify:none needs an output contract")
	// the lease survived every refusal
	still, sh := lease_of(fx, "inst_w1")
	testing.expect(t, sh && still.lease_id == lease.lease_id, "refusals do not touch the lease")
	// green, clean, same head → submitted; no reviewers & no user approval → done
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0)
	wake_log_reset(log)
	res, gok, gerr := lease_submit(&fx.svc, auth, Submit_Input{summary = "done it", handoff_json = `{"next_steps":"none","decisions":["x"]}`, vcs_json = `{"head":"abc","dirty":false,"files":[{"path":"a.odin","status":"M","add":3,"del":1}]}`})
	if !testing.expect(t, gok, fmt.tprintf("submit: %s", gerr.message)) do return
	testing.expect_value(t, res.outcome, "done")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "holder stopped (fresh context)")
	h, hok := get_facet(&fx.svc, task, lease.attempt_no, FACET_HANDOFF)
	testing.expect(t, hok && strings.contains(h.body_json, `"summary":"done it"`) && strings.contains(h.body_json, `"decisions":["x"]`), "handoff facet verbatim members")
	v, vok := get_facet(&fx.svc, task, lease.attempt_no, FACET_VCS)
	testing.expect(t, vok && strings.contains(v.body_json, `"path":"a.odin"`) && v.writer == FACET_WRITER_BRIDGE, "vcs facet stored verbatim")
	// a second submit from the old process is lease_lost
	_, again, aerr := lease_submit(&fx.svc, auth, Submit_Input{summary = "again"})
	testing.expect(t, !again && aerr.code == .Conflict && strings.contains(aerr.message, "lease_lost"), "second submit 409 lease_lost")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "submit")
}

@(test)
test_submit_after_expiry_409 :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_exp409")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_e409")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	lease, _ := lease_of(fx, "inst_w1")
	write_verify(fx, "task_1", lease.attempt_no, "abc", 0)
	fixture_advance(fx, LEASE_TTL_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	// the old process submits with its old lease id
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{lease_id = lease.lease_id, summary = "late", vcs_json = `{"head":"abc","dirty":false}`})
	testing.expect(t, !sok && serr.code == .Conflict && strings.contains(serr.message, "lease_lost"), "submit after expiry → 409 lease_lost")
	testing.expect_value(t, count_events(fx, "task_1", EV_SUBMITTED), 0)
}

@(test)
test_review_gate_strict_and_request_changes_user_approval :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_gate")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_gate")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":["reviewer"]}`)
	t_row := get_task(fx, "task_1")
	t_row.requires_user_approval = true
	_, _, _ = iface.taskchain_save_task(&fx.repo, t_row)
	confirm_holder(fx, "inst_w1")
	l1, _ := lease_of(fx, "inst_w1")
	write_verify(fx, "task_1", 1, "h1", 0)
	res, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, res.outcome, "in_review")
	// strict AND: both reviewer rows get a review lease
	_, r1 := lease_of(fx, "inst_r1")
	_, r2 := lease_of(fx, "inst_r2")
	testing.expect(t, r1 && r2, "one review lease per needed fleet row")
	// r1 approves → still waiting (r2 + user)
	g1, g1ok, g1err := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if !testing.expect(t, g1ok, fmt.tprintf("review r1: %s", g1err.message)) do return
	testing.expect_value(t, g1.gate, Gate_Result.Waiting)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	// r2 requests changes → task ready (attempt 2 next), remaining review leases dropped
	g2, g2ok, _ := review_post(&fx.svc, inst_auth("inst_r2"), Review_Input{verdict = "request_changes", findings_json = `[{"path":"a.odin","line":3,"severity":"major","text":"off by one"}]`})
	testing.expect(t, g2ok && g2.gate == .Changes_Requested, "request_changes")
	testing.expect_value(t, count_events(fx, "task_1", EV_CHANGES_REQUESTED), 1)
	// the worker is re-granted (prefers the previous holder): attempt 2
	l2, h2 := lease_of(fx, "inst_w1")
	testing.expect(t, h2 && l2.lease_id != l1.lease_id && l2.attempt_no == 2, "re-granted as attempt 2")
	leases, _ := iface.taskchain_list_leases_by_task(&fx.repo, task.task_id)
	for l in leases do testing.expect(t, l.kind != domain.LEASE_KIND_REVIEW, "no review lease lingers after request_changes")
	// attempt 2: prior reviews do not count — both must approve again, plus the user
	confirm_holder(fx, "inst_w1")
	write_verify(fx, "task_1", 2, "h2", 0)
	_, s2ok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v2", vcs_json = `{"head":"h2","dirty":false}`})
	testing.expect(t, s2ok, "submit attempt 2")
	_, ra, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	_, rb, _ := review_post(&fx.svc, inst_auth("inst_r2"), Review_Input{verdict = "approve"})
	testing.expect(t, ra && rb, "both reviewers approve attempt 2")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review) // user approval pending
	// a user request_changes is also honoured; then user approve on the next attempt closes it
	ur, uok, uerr := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "approve"})
	if !testing.expect(t, uok, fmt.tprintf("user review: %s", uerr.message)) do return
	testing.expect_value(t, ur.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	// user review on a done task is refused
	_, late, lerr := user_review(&fx.svc, user_auth(), task.task_id, Review_Input{verdict = "approve"})
	testing.expect(t, !late && lerr.code == .Conflict, "no review on a done task")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "gate")
}

@(test)
test_oscillation_guard_parks_after_three_rounds :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_osc")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_osc")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":["reviewer"],"budget":{"max_attempts":9}}`)
	for round in 1..=3 {
		confirm_holder(fx, "inst_w1")
		l, h := lease_of(fx, "inst_w1")
		if !testing.expect(t, h, fmt.tprintf("round %d leased", round)) do return
		write_verify(fx, "task_1", l.attempt_no, fmt.tprintf("h%d", round), 0)
		_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "try", vcs_json = fmt.tprintf(`{{"head":"h%d","dirty":false}}`, round)})
		if !testing.expect(t, sok, fmt.tprintf("submit %d: %s", round, serr.message)) do return
		if round == 1 {
			// REQ-SOLO-8: a verdict without words is refused — findings first.
			_, nok, nerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes"})
			testing.expect(t, !nok && nerr.code == .Validation_Failed, "request_changes without a summary or findings is refused")
		}
		_, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", summary = fmt.tprintf("round %d: still wrong", round)})
		if !testing.expect(t, rok, fmt.tprintf("review %d: %s", round, rerr.message)) do return
	}
	parked := get_task(fx, "task_1")
	testing.expect_value(t, parked.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(parked.blocked_on_json, "oscillation"), "oscillation guard → blocked_on human")
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held, "no grant while parked")
	// the human answers → ready again → granted, and oscillation counter resets (M2-m2)
	_, aok, _ := task_answer(&fx.svc, parked, Actor{kind = ACTOR_USER, id = "u1"}, "merged the two views")
	testing.expect(t, aok, "answer")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress)
	confirm_holder(fx, "inst_w1")
	l4, _ := lease_of(fx, "inst_w1")
	write_verify(fx, "task_1", l4.attempt_no, "h4", 0)
	_, s4ok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "try 4", vcs_json = `{"head":"h4","dirty":false}`})
	testing.expect(t, s4ok, "submit 4")
	_, r4ok, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", summary = "round 4"})
	testing.expect(t, r4ok, "review 4")
	// 1 round after answer < 3, so NOT parked for oscillation
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Progress)
}

@(test)
test_fleet_delete_reevaluates_gate :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_fleetgate")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_fg")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	// agt_r2 has no instance and br_1 cannot JIT (no agent service) → its review never arrives
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	write_verify(fx, "task_1", 1, "h1", 0)
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v", vcs_json = `{"head":"h1","dirty":false}`})
	testing.expect(t, sok, "submit")
	_, rok, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve"})
	testing.expect(t, rok, "r1 approves")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review) // waiting for agt_r2
	// the operator removes the agt_r2 fleet row → the gate is re-evaluated → done
	_, _ = iface.taskchain_delete_fleet(&fx.repo, chain.chain_id, "agt_r2", "u1")
	testing.expect(t, fleet_changed(&fx.svc, chain).code == .None, "fleet_changed")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
}

@(test)
test_handoff_keeps_attempt_and_block_parks :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_handoff")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_ho")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	l1, _ := lease_of(fx, "inst_w1")
	testing.expect_value(t, l1.attempt_no, 1)
	// handoff: summary required
	_, bad, berr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = ""})
	testing.expect(t, !bad && berr.code == .Validation_Failed, "handoff needs a summary")
	wake_log_reset(log)
	_, hok, herr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "halfway", handoff_json = `{"next_steps":"finish b","vault":"vault:v2:e1:ZGF0YQ=="}`})
	if !testing.expect(t, hok, fmt.tprintf("handoff: %s", herr.message)) do return
	testing.expect(t, wake_log_has_stop(log, "inst_w1") || wake_log_has_run(log, "inst_w1"), "holder released")
	// re-granted (prefers inst_w1) with the SAME attempt number
	holder := ""
	if l, h := lease_of(fx, "inst_w1"); h { holder = "inst_w1"; testing.expect_value(t, l.attempt_no, 1) }
	if l, h := lease_of(fx, "inst_w2"); h { holder = "inst_w2"; testing.expect_value(t, l.attempt_no, 1) }
	testing.expect(t, holder != "", "handoff → re-granted, attempt kept")
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 1)
	h, fok := get_facet(&fx.svc, task, 1, FACET_HANDOFF)
	testing.expect(t, fok && strings.contains(h.body_json, "vault:v2:e1:ZGF0YQ==") && strings.contains(h.body_json, `"next_steps":"finish b"`), "armored handoff stored verbatim")
	// the pack for the new holder carries the previous handoff
	lease, _ := lease_of(fx, holder)
	inst, _, _ := iface.agent_get_instance(&fx.agents, holder)
	pack := build_pack_json(&fx.svc, chain, get_task(fx, "task_1"), lease, inst)
	testing.expect(t, strings.contains(pack, `"why":"handoff"`) && strings.contains(pack, "finish b"), "pack: why=handoff + previous handoff")
	// block → backlog with the waiting_on badge; the attempt is closed
	confirm_holder(fx, holder)
	_, bok, berr2 := lease_block(&fx.svc, inst_auth(holder), Block_Input{waiting_on_json = `{"kind":"external","ref":"INC-42","reason":"staging down"}`, summary = "waiting"})
	if !testing.expect(t, bok, fmt.tprintf("block: %s", berr2.message)) do return
	row := get_task(fx, "task_1")
	testing.expect_value(t, row.state, domain.Task_State.Backlog)
	testing.expect(t, strings.contains(row.blocked_on_json, "INC-42") && strings.contains(row.blocked_on_json, "since_ms"), "waiting_on badge with since")
	_, still := lease_of(fx, holder)
	testing.expect(t, !still, "block releases the lease")
	// bad waiting_on → 422 (and nothing changes)
	_, wbad, werr := lease_block(&fx.svc, inst_auth(holder), Block_Input{waiting_on_json = `{"reason":"no kind"}`})
	testing.expect(t, !wbad && werr.code == .Validation_Failed, "waiting_on.kind required")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "handoff/block")
}

@(test)
test_facets_verbatim_round_trip_and_fetch :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_facets")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_fx")
	task := publish_task(t, fx, chain, "task_1")
	unknown := `{"summary":"s","x_vendor":{"a":[1,2,{"b":null}],"when":"2026-01-01T00:00:00Z"},"next_steps":"n"}`
	saved, serr := save_facet_verbatim(&fx.svc, task, 1, FACET_HANDOFF, unknown, FACET_WRITER_AGENT)
	testing.expect(t, saved, fmt.tprintf("save: %s", serr.message))
	f, fok := get_facet(&fx.svc, task, 1, FACET_HANDOFF)
	testing.expect(t, fok && f.body_json == unknown && f.v == 1, "unknown fields round-trip byte-for-byte")
	saved2, _ := save_facet_verbatim(&fx.svc, task, 1, FACET_HANDOFF, `{"summary":"s2"}`, FACET_WRITER_AGENT)
	f2, _ := get_facet(&fx.svc, task, 1, FACET_HANDOFF)
	testing.expect(t, saved2 && f2.v == 2, "rewrite bumps v")
	bad, _ := save_facet_verbatim(&fx.svc, task, 1, FACET_OUTPUT, `[1,2]`, FACET_WRITER_AGENT)
	testing.expect(t, !bad, "a facet must be an object")
	// fetch
	raw, ok1, _ := task_fetch(&fx.svc, task, "facet:task_1:1:handoff")
	testing.expect(t, ok1 && strings.contains(raw, `"body":{"summary":"s2"}`) && strings.contains(raw, `"v":2`), "facet fetch")
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, "u1")
	ev_raw, ok2, _ := task_fetch(&fx.svc, task, fmt.tprintf("#%d", evs[0].event_id))
	testing.expect(t, ok2 && strings.contains(ev_raw, `"kind":"created"`), "event fetch")
	_, ok3, e3 := task_fetch(&fx.svc, task, "#999999")
	testing.expect(t, !ok3 && e3.code == .Not_Found, "unknown event")
	_, ok4, e4 := task_fetch(&fx.svc, task, "facet:task_other:1:handoff")
	testing.expect(t, !ok4 && e4.code == .Validation_Failed, "facet ref must name this task")
	_, ok5, e5 := task_fetch(&fx.svc, task, "src/x.odin")
	testing.expect(t, !ok5 && e5.code == .Validation_Failed, "path refs are M3")
	// handoff caps: truncated:true at the top level, never inside a field
	long := strings.repeat("x", HANDOFF_SUMMARY_MAX + 10, context.temp_allocator)
	body := handoff_body_json(long, `{"next_steps":"ok","keep":{"me":true}}`)
	testing.expect(t, strings.has_suffix(body, `,"truncated":true}`) && strings.contains(body, `"keep":{"me":true}`), "truncated flag + verbatim members")
	testing.expect(t, len(body) < HANDOFF_SUMMARY_MAX + 200, "summary cut")
	capped, trunc := findings_json_capped(`[{"text":"a"},{"text":"b"}]`)
	testing.expect(t, !trunc && capped == `[{"text":"a"},{"text":"b"}]`, "findings verbatim under the cap")
}

@(test)
test_vault_armored_handoff_passes_shape_validation :: proc(t: ^testing.T) {
	// A bridge-encrypted summary is an opaque string; the hub validates shape only.
	body := handoff_body_json("vault:v2:e1:c3VtbWFyeQ==", `{"next_steps":"vault:v2:e1:bmV4dA==","files":["vault:v2:e1:Zg=="]}`)
	testing.expect(t, strings.has_prefix(body, `{"summary":"vault:v2:e1:c3VtbWFyeQ=="`), "armored summary kept")
	testing.expect(t, strings.contains(body, `"next_steps":"vault:v2:e1:bmV4dA=="`) && strings.contains(body, `"files":["vault:v2:e1:Zg=="]`), "armored members verbatim")
	testing.expect(t, !strings.contains(body, "truncated"), "not truncated")
}

@(test)
test_verify_bridge_death_exit_minus_one :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_verify_death")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_vd")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"sleep 300","review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	// the bridge died: the session inventory lands `failed` with no exit code
	write_verify(fx, "task_1", 1, "h1", 0, dirty = "", status = "failed")
	f, fok := get_facet(&fx.svc, task, 1, FACET_VERIFY)
	if !testing.expect(t, fok, "verify facet written by the hub") do return
	testing.expect(t, strings.contains(f.body_json, `"exit_code":-1`), "exit_code -1 on bridge death")
	testing.expect(t, strings.contains(f.body_json, `"dirty":null`) && strings.contains(f.body_json, `"log_ref":"sh_task_1_1"`), "unknown dirty, log_ref = session")
	testing.expect_value(t, f.writer, FACET_WRITER_HUB)
	// submit is refused on it
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "x", vcs_json = `{"head":"h1","dirty":false}`})
	testing.expect(t, !sok && strings.contains(serr.details_json, "verify_failed"), "a −1 verify never passes the gate")
	// labels that are not verify labels are ignored
	on_verify_session_exited(&fx.svc, Verify_Exit{session_id = "sh_x", label = "build", owner_user_id = "u1", status = "exited", exit_code = 0, exit_code_set = true})
	tid, head, n, pok := parse_verify_label("verify task_9 #3 @deadbeef")
	testing.expect(t, pok && tid == "task_9" && n == 3 && head == "deadbeef", "label parse")
	_, _, _, bad := parse_verify_label("verify task_9")
	testing.expect(t, !bad, "incomplete label rejected")
}

@(test)
test_reopen_starts_new_noncounting_attempt :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_reopen")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_ro")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"verify":"true","review_roles":[]}`)
	_, bad, berr := task_reopen(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"})
	testing.expect(t, !bad && berr.code == .Conflict, "only terminal tasks reopen")
	_ = cancel_task(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"}, "oops")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Cancelled)
	fresh, rok, rerr := task_reopen(&fx.svc, get_task(fx, "task_1"), Actor{kind = ACTOR_USER, id = "u1"})
	if !testing.expect(t, rok, fmt.tprintf("reopen: %s", rerr.message)) do return
	testing.expect_value(t, fresh.state, domain.Task_State.In_Progress) // re-granted at once
	attempts, _ := iface.taskchain_list_attempts_by_task(&fx.repo, task.task_id, "u1")
	counting := 0
	for a in attempts do if a.counts_toward_budget do counting += 1
	testing.expect(t, len(attempts) == 2 && counting == 1, "reopen attempt is non-counting")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "reopen")
}

@(test)
test_m2_review_fixes_verify_none_peek_and_vault_caps :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m2_rvfix")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_rvf")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	// 1. M2-M7: lease_next(peek=true) does not inline-grant a ready task when holding no lease
	t_draft := domain.Task{
		task_id = "task_peek", chain_id = chain.chain_id, owner_user_id = "u1",
		title = "t", kind = .Task, state = .Ready, publish_state = .Published, priority = .P1,
		brief_json = `{"goal":"g","acceptance":["a"],"verify":"make test","output":{"schema":"v1"},"review_roles":[]}`,
		ready_since = "2026-03-01T00:00:00Z", created_at = "2026-03-01T00:00:00Z", updated_at = "2026-03-01T00:00:00Z",
	}
	_, _, _ = iface.taskchain_save_task(&fx.repo, t_draft)
	_, _, _ = append_event(&fx.repo, &fx.clock, t_draft, hub_actor(), EV_CREATED, `{"publish_state":"published"}`)
	peek_res, pok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{peek = true})
	testing.expect(t, pok && peek_res.status == "none", "peek=true does not claim a ready task")
	// Now normal lease_next claims it
	claim_res, cok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{vcs_base = "abc"})
	testing.expect(t, cok && claim_res.status == "granted", "peek=false claims the ready task")

	// 2. M2-C2: task has output contract AND brief.verify != "none" → verify="none" is REJECTED
	_, vn_ok, vn_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary = "try bypass", output_json = `{"ok":true}`, verify = "none",
	})
	testing.expect(t, !vn_ok && strings.contains(vn_err.details_json, "verify_required"), "verify:none rejected when brief.verify != none even with output contract")

	// 3. M2-C3: verify exit for wrong attempt_no is ignored
	on_verify_session_exited(&fx.svc, Verify_Exit{
		session_id = "sh_stale", label = "verify task_peek #99 @abc",
		owner_user_id = "u1", status = "exited", exit_code = 0, exit_code_set = true,
		head_at_end = "abc", dirty = "false",
	})
	_, has_v := get_facet(&fx.svc, get_task(fx, "task_peek"), 1, FACET_VERIFY)
	testing.expect(t, !has_v, "stale attempt verify exit ignored")

	// 4. M2-M5: oversized vault-armored strings are not truncated in handoff_body_json or findings_json_capped
	big_cipher := strings.concatenate({"vault:v2:e1:", strings.repeat("A", HANDOFF_SUMMARY_MAX + 500, context.temp_allocator)}, context.temp_allocator)
	hb := handoff_body_json(big_cipher, fmt.tprintf(`{{"next_steps":"%s"}}`, big_cipher))
	testing.expect(t, !strings.contains(hb, `"truncated":true`) && strings.contains(hb, big_cipher), "vault:v2:e1: handoff never byte-sliced")
	fc, ftrunc := findings_json_capped(fmt.tprintf(`[{{"text":"%s"}}]`, big_cipher))
	testing.expect(t, !ftrunc && strings.contains(fc, big_cipher), "vault:v2:e1: finding never byte-sliced")
}

@(test)
test_m3_r1_r2_r3_end_to_end :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3_e2e")
	defer lease_fixture_close(fx, log)
	if !ok do return

	Notif_Capture :: struct {
		triggers: [dynamic]string,
		lines:    [dynamic]string,
	}
	nc := Notif_Capture{
		triggers = make([dynamic]string, context.temp_allocator),
		lines    = make([dynamic]string, context.temp_allocator),
	}
	fx.svc.notify_observer_ctx = &nc
	fx.svc.notify_observer = proc(ctx: rawptr, coord_id, trigger, line: string) {
		c := (^Notif_Capture)(ctx)
		append(&c.triggers, strings.clone(trigger, context.temp_allocator))
		append(&c.lines, strings.clone(line, context.temp_allocator))
	}
	fx.svc.vcs_show_file = proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, directory_id, rev, file_path: string) -> (string, bool, domain.Domain_Error) {
		return fmt.tprintf("package main // %s@%s", file_path, rev), true, domain.Domain_Error{}
	}

	chain := seed_live_chain(t, fx, "chain_m3")
	chain.publish_state = .Draft
	chain.published_at = ""
	chain.coordinator_agent_instance_id = "inst_coord"
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	seed_instance(fx, chain, "inst_coord", "coordinator", "br_1", "idle")
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{
		chain_id = chain.chain_id, agent_instance_id = "inst_coord", agent_id = "coordinator", owner_user_id = "u1", role = "coordinator", created_at = "2026-03-01T00:00:00Z",
	})
	_, _, _ = iface.taskchain_save_directory(&fx.repo, domain.Task_Chain_Directory{
		directory_id = "dir_1", chain_id = chain.chain_id, owner_user_id = "u1", bridge_id = "br_1", path = "/repo", vcs_kind = "git", created_at = "2026-03-01T00:00:00Z", updated_at = "2026-03-01T00:00:00Z",
	})
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")

	// R3: chain_propose + chain_proposal_decide(approve) transitions Draft -> Published
	prop_chain, pok, perr := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_coord"}, Propose_Input{
		kind        = "task",
		rationale   = "initial 2-task plan",
		alternative = "single monolith task",
		tasks_json  = `[{"id":"t_base","title":"Base task","brief":{"goal":"produce output","acceptance":["ok"],"verify":"make test","output":{"v":1},"review_roles":[]}},{"id":"t_indep","title":"Indep verify task","depends_on":["t_base"],"brief":{"goal":"verify indep","acceptance":["ok"],"verify":"make test","require_independent_verify":true,"requires_user_approval":true,"inputs":["output:t_base","src/main.odin@abc1234"],"review_roles":[]}}]`,
	})
	if !testing.expect(t, pok, fmt.tprintf("chain_propose: %s", perr.message)) do return
	testing.expect(t, strings.contains(chain_proposal_json(prop_chain), `"status":"pending"`), "proposal stored")
	testing.expect(t, strings.contains(chain_proposal_json(prop_chain), `"alternative":"single monolith task"`), "alternative stored")

	dec_chain, mat_tasks, dok, derr := chain_proposal_decide(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "approve")
	if !testing.expect(t, dok && len(mat_tasks) == 2, fmt.tprintf("proposal decide: %s", derr.message)) do return
	testing.expect_value(t, dec_chain.publish_state, domain.Publish_State.Published)
	testing.expect(t, dec_chain.published_at != "", "chain published_at set on proposal approve")
	chain = dec_chain
	t_base := mat_tasks[0]
	t_indep := mat_tasks[1]
	testing.expect_value(t, t_base.publish_state, domain.Publish_State.Published)
	testing.expect_value(t, t_base.state, domain.Task_State.In_Progress) // auto-granted to inst_w1!
	testing.expect_value(t, t_indep.state, domain.Task_State.Backlog)   // waiting on t_base

	// R2: runtime facet written at grant
	rt_f, has_rt := get_facet(&fx.svc, t_base, 1, FACET_RUNTIME)
	testing.expect(t, has_rt && strings.contains(rt_f.body_json, `"bridge_id":"br_1"`), "runtime facet written at grant")

	// Submit t_base with output + artifacts (using spec {kind, ref, label} schema for file, url, preview_port)
	confirm_holder(fx, "inst_w1")
	write_verify(fx, string(t_base.task_id), 1, "abc1234", 0)
	sub1, sok1, serr1 := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary        = "base complete",
		output_json    = `{"result":"forty-two"}`,
		vcs_json       = `{"head":"abc1234","dirty":false,"files":[{"path":"src/main.odin","status":"M","add":10,"del":2}]}`,
		artifacts_json = `{"items":[{"kind":"file","ref":"out/report.txt","label":"Report"},{"kind":"url","ref":"https://example.com/ci","label":"CI"},{"kind":"preview_port","ref":3000,"label":"Preview"}]}`,
	})
	if !testing.expect(t, sok1 && sub1.outcome == "done", fmt.tprintf("submit t_base: %s", serr1.message)) do return
	// Mixed-work prerequisites require the bridge merge to settle, in addition
	// to a successful submit. Simulate that acknowledgement in this fixture.
	merge_uow, merge_began, _ := begin_uow(&fx.svc)
	if !testing.expect(t, merge_began, "merge acknowledgement uow") do return
	fresh_base := get_task(fx, string(t_base.task_id))
	_, _, merge_ok, merge_err := record_event(&fx.svc, &merge_uow, fresh_base, hub_actor(), EV_MERGED, `{"head":"abc1234","branch":"task/base","into":"main"}`)
	if merge_ok do merge_ok, merge_err = after_chain_change(&fx.svc, &merge_uow, chain.chain_id, "u1", .Task_Updated)
	_, _ = end_uow(&fx.svc, &merge_uow, merge_ok)
	if !testing.expect(t, merge_ok, merge_err.message) do return
	art_f, has_art := get_facet(&fx.svc, t_base, 1, FACET_ARTIFACTS)
	testing.expect(t, has_art && strings.contains(art_f.body_json, `"label":"Report"`) && strings.contains(art_f.body_json, `"preview_port"`), "artifacts facet stored with {kind, ref, label}")
	rt_after, _ := get_facet(&fx.svc, t_base, 1, FACET_RUNTIME)
	testing.expect(t, strings.contains(rt_after.body_json, `"ended_at":"2026-`), "runtime facet ended_at populated on close")

	// R1: mechanical chain summary updated on transition (includes title, @vcs.head, and handoff.summary); t_indep now In_Progress with full pack
	cs, cs_ok, _ := iface.taskchain_get_chain_summary(&fx.repo, chain.chain_id, "u1")
	testing.expect(t, cs_ok && strings.contains(cs.body, "Base task") && strings.contains(cs.body, "@abc1234") && strings.contains(cs.body, "base complete"), "mechanical chain summary lists completed task with title, @vcs.head, and handoff summary")

	// Set coordinator-curated summary BEFORE t_indep transitions, and verify subsequent mechanical rebuild preserves it!
	_, sum_ok, sum_err := chain_summary_set(&fx.svc, inst_auth("inst_coord"), chain.chain_id, "Coordinator curated note: architecture v2")
	testing.expect(t, sum_ok, fmt.tprintf("chain_summary_set: %s", sum_err.message))

	l_indep, held_indep := lease_of(fx, "inst_w1")
	testing.expect(t, held_indep && l_indep.task_id == t_indep.task_id, "t_indep granted after t_base done")
	inst_w1, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	pack := build_pack_json(&fx.svc, chain, get_task(fx, string(t_indep.task_id)), l_indep, inst_w1)
	testing.expect(t, strings.contains(pack, `"where_you_are"`) && strings.contains(pack, `"forty-two"`) && strings.contains(pack, "package main // src/main.odin@abc1234"), "pack resolves output:<task> and path@rev inputs")

	// R2: submit t_indep -> enters In_Review because require_independent_verify=true & requires_user_approval=true
	confirm_holder(fx, "inst_w1")
	write_verify(fx, string(t_indep.task_id), 1, "def5678", 0)
	sub2, sok2, serr2 := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary  = "indep ready",
		vcs_json = `{"head":"def5678","dirty":false}`,
		auto     = true,
	})
	if !testing.expect(t, sok2 && sub2.outcome == "in_review", fmt.tprintf("submit t_indep: %s", serr2.message)) do return

	// R3: coordinator proxy review on_behalf_of="user" approves user part, records actor_kind="coordinator", and gate waits for independent verify!
	rev_res, rok, rerr := review_post(&fx.svc, inst_auth("inst_coord"), Review_Input{
		task_id      = string(t_indep.task_id),
		verdict      = "approve",
		on_behalf_of = "user",
	})
	if !testing.expect(t, rok && rev_res.gate == .Waiting, fmt.tprintf("proxy review: %s", rerr.message)) do return
	testing.expect_value(t, get_task(fx, string(t_indep.task_id)).state, domain.Task_State.In_Review)
	indep_evs, _ := iface.taskchain_list_events_by_task(&fx.repo, t_indep.task_id, "u1")
	found_coord_rev := false
	for ev in indep_evs {
		if ev.kind == EV_REVIEW_POSTED && ev.actor_kind == ACTOR_COORDINATOR && strings.contains(ev.payload_json, `"on_behalf_of":"user"`) {
			found_coord_rev = true
		}
	}
	testing.expect(t, found_coord_rev, "proxy review event records actor_kind == coordinator and on_behalf_of == user")

	// R2: independent verify session exits 0 -> gate approves and task transitions to Done!
	on_verify_session_exited(&fx.svc, Verify_Exit{
		session_id    = "sh_indep_1",
		label         = fmt.tprintf("verify %s #1 @def5678 independent", t_indep.task_id),
		owner_user_id = "u1",
		status        = "exited",
		exit_code     = 0,
		exit_code_set = true,
		duration_ms   = 120,
		head_at_end   = "def5678",
		dirty         = "false",
		cmd           = "make test",
		independent   = true,
	})
	testing.expect_value(t, get_task(fx, string(t_indep.task_id)).state, domain.Task_State.Done)
	// Settle the last bridge merge before expecting the batch-finished notice.
	final_uow, final_began, _ := begin_uow(&fx.svc)
	if !testing.expect(t, final_began, "final merge acknowledgement uow") do return
	_, _, final_ok, final_err := record_event(&fx.svc, &final_uow, get_task(fx, string(t_indep.task_id)), hub_actor(), EV_MERGED, `{"head":"def5678","branch":"task/indep","into":"main"}`)
	if final_ok do final_ok, final_err = after_chain_change(&fx.svc, &final_uow, chain.chain_id, "u1", .Task_Updated)
	_, _ = end_uow(&fx.svc, &final_uow, final_ok)
	if !testing.expect(t, final_ok, final_err.message) do return

	// R1: verify coordinator-curated note survived rebuild_chain_summary_in_uow on t_indep completion AND mechanical completed task lines are present!
	cs_after, cs_after_ok, _ := iface.taskchain_get_chain_summary(&fx.repo, chain.chain_id, "u1")
	testing.expect(t, cs_after_ok && strings.contains(cs_after.body, "Coordinator curated note: architecture v2") && strings.contains(cs_after.body, "@def5678") && strings.contains(cs_after.body, "indep ready"), "coordinator summary preserved alongside mechanical updates")

	too_many := strings.repeat("line\n", 65, context.temp_allocator)
	_, bad_sum, bad_sum_err := chain_summary_set(&fx.svc, inst_auth("inst_coord"), chain.chain_id, too_many)
	testing.expect(t, !bad_sum && bad_sum_err.code == .Validation_Failed, ">60 line summary rejected")

	// R3: verify coordinator notifications fired (proposal_decided and work_batch_finished)
	has_prop_notif, has_complete_notif := false, false
	for trig in nc.triggers {
		if trig == "proposal_decided" do has_prop_notif = true
		if trig == "work_batch_finished" do has_complete_notif = true
	}
	testing.expect(t, has_prop_notif && has_complete_notif, "coordinator notified on proposal_decided and work_batch_finished")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "m3_e2e")
}

@(test)
test_chain_propose_validation_and_auto_approve :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3_propose_val")
	defer lease_fixture_close(fx, log)
	if !ok do return

	chain := seed_live_chain(t, fx, "chain_pv")
	chain.publish_state = .Draft
	chain.published_at = ""
	chain.coordinator_agent_instance_id = "inst_coord"
	chain.defaults_json = `{"auto_submit":true,"custom_flag":"keep_me"}`
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	seed_instance(fx, chain, "inst_coord", "coordinator", "br_1", "idle")
	seed_instance(fx, chain, "inst_worker", "agt_w", "br_1", "idle")
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{
		chain_id = chain.chain_id, agent_instance_id = "inst_coord", agent_id = "coordinator", owner_user_id = "u1", role = "coordinator", created_at = "2026-03-01T00:00:00Z",
	})

	valid_tasks := `[{"id":"tp_1","title":"Task 1","brief":{"goal":"build 1","acceptance":["a1"],"verify":"make test","review_roles":[]}}]`

	// 1. Non-coordinator agent rejected with 403 Forbidden (not_coordinator)
	_, pok1, perr1 := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_worker"}, Propose_Input{
		kind       = "task",
		rationale  = "worker try",
		tasks_json = valid_tasks,
	})
	testing.expect(t, !pok1 && perr1.code == .Forbidden && strings.contains(perr1.details_json, "not_coordinator"), "non-coordinator rejected with 403 not_coordinator")

	// 2. Incomplete brief rejected with 400 Validation_Failed (brief_incomplete)
	_, pok2, perr2 := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_coord"}, Propose_Input{
		kind       = "task",
		rationale  = "bad brief",
		tasks_json = `[{"id":"tp_bad","title":"Bad task","brief":{"goal":"","acceptance":[],"verify":""}}]`,
	})
	testing.expect(t, !pok2 && perr2.code == .Validation_Failed && strings.contains(perr2.details_json, "brief_incomplete"), "incomplete brief rejected with brief_incomplete")

	// 3. Valid proposal preserves existing defaults_json keys
	prop_chain, pok3, perr3 := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_coord"}, Propose_Input{
		kind       = "task",
		rationale  = "good plan",
		tasks_json = valid_tasks,
	})
	if !testing.expect(t, pok3, fmt.tprintf("valid propose: %s", perr3.message)) do return
	testing.expect(t, strings.contains(prop_chain.defaults_json, `"custom_flag":"keep_me"`) && strings.contains(prop_chain.defaults_json, `"auto_submit":true`), "defaults_json keys preserved on propose")

	// 4. Reject clears proposal while keeping custom_flag, leaving chain in Draft
	rej_chain, _, rok, _ := chain_proposal_decide(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_USER, id = "u1"}, "reject", "try auto_approve")
	testing.expect(t, rok && rej_chain.publish_state == .Draft && strings.contains(rej_chain.defaults_json, `"custom_flag":"keep_me"`) && chain_proposal_json(rej_chain) == "", "reject clears proposal and preserves defaults_json")

	// 5. auto_approve = true immediately publishes chain and tasks in one UoW
	auto_chain, pok4, perr4 := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_coord"}, Propose_Input{
		kind         = "task",
		rationale    = "auto-approved plan",
		auto_approve = true,
		tasks_json   = valid_tasks,
	})
	if !testing.expect(t, pok4, fmt.tprintf("auto_approve propose: %s", perr4.message)) do return
	testing.expect_value(t, auto_chain.publish_state, domain.Publish_State.Published)
	testing.expect_value(t, get_task(fx, "tp_1").state, domain.Task_State.Ready)

	// 6. A published mixed-work chain can propose another batch without changing its type.
	_, pok5, perr5 := chain_propose(&fx.svc, chain.chain_id, "u1", Actor{kind = ACTOR_AGENT, id = "inst_coord"}, Propose_Input{
		kind       = "task",
		rationale  = "late propose",
		tasks_json = valid_tasks,
	})
	testing.expect(t, pok5 && perr5.code == .None, "published mixed-work chain accepts a new proposal")
}

@(test)
test_pack_full_sections_and_field_safe_cap :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "m3_pack_full")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_pf")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", `["reviewer"]`)
	inst_w := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")

	// 1. Complete an upstream task t_up so we have an event id and output:<task>
	t_up := publish_task(t, fx, chain, "t_up", brief = `{"goal":"upstream","acceptance":["ok"],"verify":"make test","output":{"v":1},"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	write_verify(fx, "t_up", 1, "111aaaa", 0)
	_, sok_up, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary     = "upstream finished",
		output_json = `{"endpoint":"/api/v2"}`,
		vcs_json    = `{"head":"111aaaa","dirty":false}`,
	})
	testing.expect(t, sok_up, "t_up done")
	up_evs, _ := iface.taskchain_list_events_by_task(&fx.repo, t_up.task_id, "u1")
	ev_ref := fmt.tprintf("#%d", up_evs[0].event_id)

	// 2. Publish task_pf with inputs referencing #<event_id>, output:t_up, and facet:task_pf:1:handoff
	brief_pf := fmt.tprintf(`{{"goal":"full pack goal","acceptance":["a1"],"verify":"make test","inputs":["%s","output:t_up","facet:task_pf:1:handoff"],"review_roles":["reviewer"]}}`, ev_ref)
	task := publish_task(t, fx, chain, "task_pf", brief = brief_pf)
	confirm_holder(fx, "inst_w1")
	_, _, _ = lease_heartbeat(&fx.svc, inst_auth("inst_w1"), Lease_Heartbeat_Input{note = "halfway through attempt 1"})
	write_verify(fx, "task_pf", 1, "222bbbb", 0)
	_, sok_pf1, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{
		summary      = "attempt 1 summary",
		handoff_json = `{"summary":"attempt 1 summary","decisions":["use sqlite"],"dead_ends":["avoided polling"],"next_steps":"fix edge case"}`,
		vcs_json     = `{"head":"222bbbb","base":"111aaaa","dirty":false,"files":[{"path":"src/a.odin","status":"M","add":5,"del":1}]}`,
	})
	testing.expect(t, sok_pf1, "attempt 1 submitted to review")

	// 3. Reviewer requests changes with open findings -> triggers attempt 2 grant to inst_w1!
	confirm_holder(fx, "inst_r1")
	_, rok_pf1, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{
		verdict       = "request_changes",
		findings_json = `[{"path":"src/a.odin","line":42,"severity":"blocking","text":"handle nil pointer"}]`,
	})
	testing.expect(t, rok_pf1, "reviewer requested changes")

	lse2, held2 := lease_of(fx, "inst_w1")
	if !testing.expect(t, held2 && lse2.attempt_no == 2, "attempt 2 lease granted") do return
	pack := build_pack_json(&fx.svc, chain, get_task(fx, "task_pf"), lse2, inst_w)
	testing.expect(t, strings.contains(pack, `"why":"changes_requested"`), "pack has why=changes_requested")
	testing.expect(t, strings.contains(pack, `"attempt_no":2`), "pack has attempt_no=2")
	testing.expect(t, strings.contains(pack, `"review_round":1`), "pack has review_round=1")
	testing.expect(t, strings.contains(pack, `"previous_attempt":{"attempt_no":1`), "pack has non-null previous_attempt")
	testing.expect(t, strings.contains(pack, `"avoided polling"`), "pack has previous_attempt dead_ends")
	testing.expect(t, strings.contains(pack, `"use sqlite"`), "pack has previous_attempt decisions")
	testing.expect(t, strings.contains(pack, `"halfway through attempt 1"`), "pack has previous_attempt heartbeat_note")
	testing.expect(t, strings.contains(pack, `"handle nil pointer"`), "pack has open review findings")
	testing.expect(t, strings.contains(pack, `"/api/v2"`), "pack resolves output:t_up input")
	testing.expect(t, strings.contains(pack, `"where_you_are"`), "pack has where_you_are")
	testing.expect(t, strings.contains(pack, `"protocol"`), "pack has protocol")

	// 4. Test 32 KiB field-safe cap (cap_pack_json_field_safe): drops inputs -> verify -> handoff, preserving brief, dead_ends, findings
	big_chunk := strings.repeat("X", 14000, context.temp_allocator)
	huge_pack := fmt.tprintf(
		`{{"lease_id":"lse_cap","task_id":"task_pf","attempt_no":2,"brief":{{"goal":"full pack goal"}},"inputs":[{{"ref":"output:t_up","resolved":true,"data":"%s"}}],"previous_attempt":{{"attempt_no":1,"outcome":"changes_requested","handoff":{{"summary":"%s","dead_ends":["keep_dead_end_1"]}},"verify":{{"exit_code":0,"summary":"%s"}}}},"findings":[{{"role":"reviewer","reviewer":"inst_r1","path":"src/a.odin","line":42,"severity":"blocking","text":"keep_finding_1"}}]}}`,
		big_chunk, big_chunk, big_chunk,
	)
	capped := cap_pack_json_field_safe(huge_pack, "task_pf")
	testing.expect(t, len(capped) <= PACK_MAX_BYTES, fmt.tprintf("capped pack <= 32 KiB (got %d)", len(capped)))
	testing.expect(t, strings.contains(capped, "ham-ctl task fetch task_pf"), "dropped fields replaced with ham-ctl task fetch pointer")
	testing.expect(t, strings.contains(capped, "full pack goal"), "brief preserved under cap")
	testing.expect(t, strings.contains(capped, "keep_dead_end_1"), "dead_ends preserved under cap")
	testing.expect(t, strings.contains(capped, "keep_finding_1"), "findings preserved under cap")
}


@(test)
test_optional_verify_publish_and_submit :: proc(t: ^testing.T) {
 fx, log, ok := lease_fixture(t, "optional_verify")
 defer lease_fixture_close(fx, log)
 if !ok do return
 chain := seed_live_chain(t, fx, "chain_optional_verify")
 seed_fleet(fx, chain, "agt_w")
 seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
 briefs := []string{
  `{"goal":"Document findings","acceptance":["Findings recorded"],"review_roles":[]}`,
  `{"goal":"Document findings","acceptance":["Findings recorded"],"verify":"","review_roles":[]}`,
  `{"goal":"Document findings","acceptance":["Findings recorded"],"verify":"none","review_roles":[]}`,
 }
 for brief, i in briefs {
  id := fmt.tprintf("optional_verify_%d", i)
  _ = publish_task(t, fx, chain, id, brief = brief)
  claim, cok, _ := lease_next(&fx.svc, inst_auth("inst_w1"), Lease_Next_Input{})
  testing.expect(t, cok && (claim.status == "granted" || claim.status == "current"), "task without a verify command is publishable and leasable")
  _, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "Findings recorded"})
  testing.expect(t, sok && serr.code == .None, "submission needs neither a verify facet nor an output contract")
 }
}
