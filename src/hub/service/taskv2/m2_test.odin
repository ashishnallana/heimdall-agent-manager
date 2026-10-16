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
		_, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes"})
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
	_, r4ok, _ := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes"})
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
	_, hok, herr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "halfway", handoff_json = `{"next_steps":"finish b","vault":"vault:v1:ZGF0YQ=="}`})
	if !testing.expect(t, hok, fmt.tprintf("handoff: %s", herr.message)) do return
	testing.expect(t, wake_log_has_stop(log, "inst_w1") || wake_log_has_run(log, "inst_w1"), "holder released")
	// re-granted (prefers inst_w1) with the SAME attempt number
	holder := ""
	if l, h := lease_of(fx, "inst_w1"); h { holder = "inst_w1"; testing.expect_value(t, l.attempt_no, 1) }
	if l, h := lease_of(fx, "inst_w2"); h { holder = "inst_w2"; testing.expect_value(t, l.attempt_no, 1) }
	testing.expect(t, holder != "", "handoff → re-granted, attempt kept")
	testing.expect_value(t, get_task(fx, "task_1").attempt_no, 1)
	h, fok := get_facet(&fx.svc, task, 1, FACET_HANDOFF)
	testing.expect(t, fok && strings.contains(h.body_json, "vault:v1:ZGF0YQ==") && strings.contains(h.body_json, `"next_steps":"finish b"`), "armored handoff stored verbatim")
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
	body := handoff_body_json("vault:v1:c3VtbWFyeQ==", `{"next_steps":"vault:v1:bmV4dA==","files":["vault:v1:Zg=="]}`)
	testing.expect(t, strings.has_prefix(body, `{"summary":"vault:v1:c3VtbWFyeQ=="`), "armored summary kept")
	testing.expect(t, strings.contains(body, `"next_steps":"vault:v1:bmV4dA=="`) && strings.contains(body, `"files":["vault:v1:Zg=="]`), "armored members verbatim")
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
	big_cipher := strings.concatenate({"ENC:v1:", strings.repeat("A", HANDOFF_SUMMARY_MAX + 500, context.temp_allocator)}, context.temp_allocator)
	hb := handoff_body_json(big_cipher, fmt.tprintf(`{{"next_steps":"%s"}}`, big_cipher))
	testing.expect(t, !strings.contains(hb, `"truncated":true`) && strings.contains(hb, big_cipher), "ENC:v1: handoff never byte-sliced")
	fc, ftrunc := findings_json_capped(fmt.tprintf(`[{{"text":"%s"}}]`, big_cipher))
	testing.expect(t, !ftrunc && strings.contains(fc, big_cipher), "ENC:v1: finding never byte-sliced")
}
