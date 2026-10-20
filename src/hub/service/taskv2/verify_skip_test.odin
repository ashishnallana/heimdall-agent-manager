package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

@(test)
test_submit_explicit_verify_skip_is_auditable :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "verify_skip")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_skip")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_skip", brief = `{"goal":"g","verify":"make test","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "leased") do return
	auth := inst_auth("inst_w1")
	for reason in ([]string{"", " \t\n "}) {
		_, sok, err := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", skip_verify = true, skip_verify_reason = reason})
		testing.expect(t, !sok && err.code == .Validation_Failed && strings.contains(err.details_json, "verify_skip_reason_required"), "blank skip reason rejected")
	}
	_, flag_ok, flag_err := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", skip_verify_reason = "missing flag"})
	testing.expect(t, !flag_ok && flag_err.code == .Validation_Failed, "reason alone rejected")
	_, _, forged_err := lease_submit(&fx.svc, auth, Submit_Input{summary = "done", handoff_json = `{"skip_verify_reason":"forged"}`})
	testing.expect(t, strings.contains(forged_err.details_json, "verify_required"), "handoff cannot bypass the verify gate")
	write_verify(fx, string(task.task_id), lease.attempt_no, "old", 127)
	res, sok, err := lease_submit(&fx.svc, auth, Submit_Input{
		summary = "done", skip_verify = true, skip_verify_reason = "  Odin is unavailable on this host; reviewer must run tests.  ",
		handoff_json = `{"decisions":["kept scope"],"skip_verify_reason":"forged"}`, vcs_json = `{"head":"new","dirty":false}`,
	})
	if !testing.expect(t, sok, fmt.tprintf("explicit skip can submit despite failed verify: %s", err.message)) do return
	testing.expect_value(t, res.outcome, "done")
	f, fok := get_facet(&fx.svc, task, lease.attempt_no, FACET_HANDOFF)
	reason := "Odin is unavailable on this host; reviewer must run tests."
	testing.expect(t, fok && jsonx.extract_string(f.body_json, "skip_verify_reason", "", true, context.temp_allocator) == reason, "trimmed authoritative skip reason persisted on attempt")
	testing.expect(t, strings.contains(f.body_json, `"decisions":["kept scope"]`), "other handoff fields retained")
	v, vok := get_facet(&fx.svc, task, lease.attempt_no, FACET_VERIFY)
	testing.expect(t, vok && strings.contains(v.body_json, `"exit_code":127`), "real verify evidence retained, not replaced with a fake pass")
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, task.owner_user_id)
	found := false
	for e in evs do if e.kind == EV_SUBMITTED && jsonx.extract_string(e.payload_json, "skip_verify_reason", "", true, context.temp_allocator) == reason do found = true
	testing.expect(t, found, "submitted event records skip reason")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "skip verify")
}

@(test)
test_independent_verify_forbids_submit_skip :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "verify_skip_independent")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_strict")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_strict", brief = `{"goal":"g","verify":"true","acceptance":["a"],"review_roles":[],"require_independent_verify":true}`)
	confirm_holder(fx, "inst_w1")
	lease, _ := lease_of(fx, "inst_w1")
	write_verify(fx, string(task.task_id), lease.attempt_no, "h", 0)
	_, sok, err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "done", skip_verify = true, skip_verify_reason = "no time", vcs_json = `{"head":"h","dirty":false}`})
	testing.expect(t, !sok && strings.contains(err.details_json, "verify_skip_forbidden"), "independent verification cannot be skipped even with green worker evidence")
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, held, "rejected skip leaves lease intact")
	testing.expect_value(t, count_events(fx, string(task.task_id), EV_SUBMITTED), 0)
}
