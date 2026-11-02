package taskv2

// T8: worker and reviewer agents keep their process across attempts and review
// rounds; they are stopped only when their tasks complete (or by their own
// `lease handoff`, or the bridge's context rollover).

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// wake_log_run_entry returns the last run[] entry naming `inst` (raw JSON
// object text), or "" when no wake ran it.
@(private = "file")
wake_log_run_entry :: proc(log: ^Wake_Log, inst: string) -> string {
	id_field := fmt.tprintf(`"agent_instance_id":"%s"`, inst)
	found := ""
	for c in log.cmds {
		run, ok := jsonx.extract_raw_array(c.body_json, "run", false, context.temp_allocator)
		if !ok do continue
		// Split the array into its top-level objects (string-aware).
		depth, start, in_str, esc := 0, -1, false, false
		for i in 0..<len(run) {
			ch := run[i]
			if in_str {
				if esc do esc = false
				else if ch == '\\' do esc = true
				else if ch == '"' do in_str = false
				continue
			}
			switch ch {
			case '"': in_str = true
			case '{':
				if depth == 1 do start = i
				depth += 1
			case '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 1 && ch == '}' && start >= 0 {
					obj := run[start:i + 1]
					if strings.contains(obj, id_field) do found = obj
					start = -1
				}
			}
		}
	}
	return found
}

@(private = "file")
expect_nudged :: proc(t: ^testing.T, log: ^Wake_Log, inst: string, run_count: int, what: string) {
	entry := wake_log_run_entry(log, inst)
	testing.expectf(t, entry != "", "%s: %s is delivered", what, inst)
	testing.expectf(t, strings.contains(entry, `"deliver":"nudge"`), "%s: %s is nudged, not relaunched (%s)", what, inst, entry)
	testing.expectf(t, strings.contains(entry, fmt.tprintf(`"run_count":%d`, run_count)), "%s: %s keeps generation %d (%s)", what, inst, run_count, entry)
	testing.expectf(t, !wake_log_has_stop(log, inst), "%s: %s is not stopped", what, inst)
}

@(private = "file")
run_count_of :: proc(fx: ^Fixture, inst: string) -> int {
	cur, _, _ := iface.agent_get_instance(&fx.agents, inst)
	return cur.run_count
}

// Submit, request_changes, re-submit and the re-review never stop or relaunch
// the worker or the reviewer; the approval that completes the task stops both.
@(test)
test_t8_attempts_and_review_rounds_keep_agents_until_done :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_rounds")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_rounds")
	seed_agent(fx, "agt_r")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	wake_log_reset(log)
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	w_gen, r_gen := run_count_of(fx, "inst_w1"), run_count_of(fx, "inst_r1")
	expect_nudged(t, log, "inst_w1", w_gen, "first grant to a live worker")
	confirm_holder(fx, "inst_w1")

	wake_log_reset(log)
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1", vcs_json = `{"head":"h1","dirty":false}`})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "submit does not stop the worker")
	expect_nudged(t, log, "inst_r1", r_gen, "review grant")
	confirm_holder(fx, "inst_r1")

	wake_log_reset(log)
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "request_changes", findings_json = `[{"path":"a.odin","line":1,"severity":"major","text":"fix"}]`})
	if !testing.expect(t, rok, fmt.tprintf("request_changes: %s", rerr.message)) do return
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "review post does not stop the reviewer")
	expect_nudged(t, log, "inst_w1", w_gen, "changes_requested re-grant")
	confirm_holder(fx, "inst_w1")

	wake_log_reset(log)
	_, s2ok, s2err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v2", vcs_json = `{"head":"h2","dirty":false}`})
	if !testing.expect(t, s2ok, fmt.tprintf("resubmit: %s", s2err.message)) do return
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "resubmit does not stop the worker")
	expect_nudged(t, log, "inst_r1", r_gen, "re-review grant")
	confirm_holder(fx, "inst_r1")

	wake_log_reset(log)
	res, aok, aerr := review_post(&fx.svc, inst_auth("inst_r1"), Review_Input{verdict = "approve", findings_json = "[]"})
	if !testing.expect(t, aok, fmt.tprintf("approve: %s", aerr.message)) do return
	testing.expect_value(t, res.gate, Gate_Result.Approved)
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.Done)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "task done: the worker is stopped")
	testing.expect(t, wake_log_has_stop(log, "inst_r1"), "task done: the reviewer is stopped")
	testing.expect_value(t, run_count_of(fx, "inst_w1"), w_gen)
	testing.expect_value(t, run_count_of(fx, "inst_r1"), r_gen)
}

// A worker that also holds another task's lease is not stopped when one of
// its tasks completes; the instance is stopped when its last task completes.
@(test)
test_t8_done_task_does_not_stop_holder_of_another_lease :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_other")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_other")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	brief := `{"goal":"g","acceptance":["a"],"review_roles":[]}`
	_ = publish_task(t, fx, chain, "task_1", brief = brief)
	_ = publish_task(t, fx, chain, "task_2", brief = brief)
	confirm_holder(fx, "inst_w1")
	first, _ := lease_of(fx, "inst_w1")
	wake_log_reset(log)
	_, sok, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "one"})
	if !testing.expect(t, sok, fmt.tprintf("submit: %s", serr.message)) do return
	testing.expect_value(t, get_task(fx, string(first.task_id)).state, domain.Task_State.Done)
	second, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && second.task_id != first.task_id, "the next task is granted to the same instance")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "a holder of another lease is not stopped")
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	_, s2ok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "two"})
	testing.expect(t, s2ok, "second submit")
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "last task done: stopped")
}

// lease block keeps the process (the task is not done); lease handoff stops
// it, and a handoff re-granted to the same instance relaunches it (fresh
// context), never nudges it.
@(test)
test_t8_block_keeps_process_and_handoff_relaunches :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_block")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_block")
	seed_fleet(fx, chain, "agt_w", idle_ttl = 60)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	wake_log_reset(log)
	_, bok, berr := lease_block(&fx.svc, inst_auth("inst_w1"), Block_Input{waiting_on_json = `{"kind":"human","reason":"which option?"}`})
	if !testing.expect(t, bok, fmt.tprintf("block: %s", berr.message)) do return
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "block does not stop the worker")
	// Idle TTL never stops an instance whose task is still open.
	fixture_advance(fx, 61)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "idle TTL spares an instance whose task is blocked")

	// A second task: handoff stops; the same-UoW re-grant relaunches.
	_ = publish_task(t, fx, chain, "task_2", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	l2, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "second task granted") do return
	confirm_holder(fx, "inst_w1")
	before := run_count_of(fx, "inst_w1")
	wake_log_reset(log)
	_, hok, herr := lease_handoff(&fx.svc, inst_auth("inst_w1"), Handoff_Input{summary = "need a fresh window"})
	if !testing.expect(t, hok, fmt.tprintf("handoff: %s", herr.message)) do return
	if again, rh := lease_of(fx, "inst_w1"); rh && again.task_id == l2.task_id {
		entry := wake_log_run_entry(log, "inst_w1")
		testing.expect(t, entry != "" && !strings.contains(entry, `"deliver"`), "re-grant after handoff relaunches")
		testing.expect_value(t, run_count_of(fx, "inst_w1"), before + 1)
	} else {
		testing.expect(t, wake_log_has_stop(log, "inst_w1"), "handoff stops the holder")
	}
}

// Idle-grace expiry releases the lease without stopping the agent, and does
// not refuse its next `lease next`.
@(test)
test_t8_idle_grace_expiry_keeps_process :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_idle")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_idle")
	seed_fleet(fx, chain, "agt_w")
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":[]}`)
	confirm_holder(fx, "inst_w1")
	lease, _ := lease_of(fx, "inst_w1")
	on_instance_activity(&fx.svc, "inst_w1", "idle")
	wake_log_reset(log)
	fixture_advance(fx, IDLE_GRACE_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"idle"`), "idle grace expired the lease")
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "idle-grace expiry does not stop the agent")
	testing.expect(t, !recently_expired(&fx.svc, "inst_w1", now_ms(&fx.clock)), "the live agent may pull again")
	if again, held := lease_of(fx, "inst_w1"); held && again.lease_id != lease.lease_id {
		expect_nudged(t, log, "inst_w1", run_count_of(fx, "inst_w1"), "re-grant after idle expiry")
	}
}

// Bridge reconnect and the idle TTL do not stop a lease-free fleet worker that
// waits for review.
@(test)
test_t8_bridge_hello_keeps_worker_waiting_for_review :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_hello")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_hello")
	seed_agent(fx, "agt_r")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, sok, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "v1"})
	if !testing.expect(t, sok, "submit") do return
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_w1"})
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "a worker waiting for review survives reconnect")
	// Idle TTL also spares it while the review is pending.
	wake_log_reset(log)
	fixture_advance(fx, IDLE_TTL_DEFAULT_SECONDS + 1)
	_ = fire_due(&fx.svc, now_ms(&fx.clock))
	testing.expect(t, !wake_log_has_stop(log, "inst_w1"), "idle TTL spares a worker waiting for review")
}

// A review checkpoint (`lease handoff` after a requirements change) releases
// the reviewer's lease without stopping it; its next review grant is a nudge
// to the same generation, not a relaunch.
@(test)
test_t8_review_checkpoint_keeps_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_checkpoint")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_checkpoint")
	seed_fleet(fx, chain, "agt_w")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), {summary = "v1", vcs_json = `{"head":"h1"}`})
	if !testing.expect(t, submitted, "submit") do return
	_, approved, _ := review_post(&fx.svc, inst_auth("inst_r1"), {verdict = "approve"})
	testing.expect(t, approved, "first reviewer approves")
	confirm_holder(fx, "inst_r2")
	requirements_test_change(t, fx, "task_1", `{"goal":"g2","acceptance":["a","new"],"review_roles":["reviewer"]}`, 1)
	review_lease, still := lease_of(fx, "inst_r2")
	if !testing.expect(t, still && review_lease.kind == domain.LEASE_KIND_REVIEW, "reviewer still holds its review lease") do return
	fresh, read, _ := lease_next(&fx.svc, inst_auth("inst_r2"), {})
	testing.expect(t, read && strings.contains(fresh.pack_json, `"review_checkpoint_required":true`), "checkpoint requested")
	r_gen := run_count_of(fx, "inst_r2")

	wake_log_reset(log)
	_, checkpointed, cerr := lease_handoff(&fx.svc, inst_auth("inst_r2"), {summary = "checkpoint obsolete review"})
	if !testing.expectf(t, checkpointed, "checkpoint: %s", cerr.message) do return
	_, r2_held := lease_of(fx, "inst_r2")
	testing.expect(t, !r2_held, "checkpoint released the review lease")
	testing.expect(t, !wake_log_has_stop(log, "inst_r2"), "review checkpoint does not stop the reviewer")
	testing.expect_value(t, run_count_of(fx, "inst_r2"), r_gen)

	next, has_work := lease_of(fx, "inst_w1")
	if !testing.expect(t, has_work && next.attempt_no == 2, "rework gets a fresh attempt") do return
	confirm_holder(fx, "inst_w1")
	_, _, _ = lease_next(&fx.svc, inst_auth("inst_w1"), {})
	_, _, _ = requirements_test_ack(fx, "inst_w1", 2)
	wake_log_reset(log)
	_, s2, serr := lease_submit(&fx.svc, inst_auth("inst_w1"), {lease_id = next.lease_id, summary = "v2", requirements_revision = 2, vcs_json = `{"head":"h2"}`})
	if !testing.expectf(t, s2, "resubmit: %s", serr.message) do return
	again, regranted := lease_of(fx, "inst_r2")
	testing.expect(t, regranted && again.kind == domain.LEASE_KIND_REVIEW, "the checkpointed reviewer owes a fresh review")
	expect_nudged(t, log, "inst_r2", r_gen, "review re-grant after checkpoint")
}

// A request_changes drops the other reviewers' leases (reason
// changes_requested) without stopping them or refusing their next pull; an
// expiry for any other reason still stops the holder.
@(test)
test_t8_changes_requested_expiry_keeps_other_reviewer :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "t8_cr_expiry")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_t8_cr_expiry")
	seed_fleet(fx, chain, "agt_w")
	seed_agent(fx, "agt_r2")
	seed_fleet(fx, chain, "agt_r", roles = `["reviewer"]`)
	seed_fleet(fx, chain, "agt_r2", roles = `["reviewer"]`)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "idle")
	seed_instance(fx, chain, "inst_r2", "agt_r2", "br_1", "idle")
	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","acceptance":["a"],"review_roles":["reviewer"]}`)
	confirm_holder(fx, "inst_w1")
	_, submitted, _ := lease_submit(&fx.svc, inst_auth("inst_w1"), {summary = "v1", vcs_json = `{"head":"h1"}`})
	if !testing.expect(t, submitted, "submit") do return
	_, a_held := lease_of(fx, "inst_r1")
	b_lease, b_held := lease_of(fx, "inst_r2")
	if !testing.expect(t, a_held && b_held, "both reviewers hold review leases") do return
	confirm_holder(fx, "inst_r1")
	confirm_holder(fx, "inst_r2")
	b_gen := run_count_of(fx, "inst_r2")

	wake_log_reset(log)
	_, rok, rerr := review_post(&fx.svc, inst_auth("inst_r1"), {verdict = "request_changes", findings_json = `[{"path":"a.odin","line":1,"severity":"major","text":"fix"}]`})
	if !testing.expectf(t, rok, "request_changes: %s", rerr.message) do return
	if b_now, still := lease_of(fx, "inst_r2"); still {
		testing.expect(t, b_now.lease_id != b_lease.lease_id, "B's review lease was dropped")
	}
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"changes_requested"`), "B expired with reason changes_requested")
	testing.expect(t, !wake_log_has_stop(log, "inst_r2"), "changes_requested expiry does not stop B")
	testing.expect(t, !wake_log_has_stop(log, "inst_r1"), "review post does not stop A")
	testing.expect_value(t, run_count_of(fx, "inst_r2"), b_gen)
	testing.expect(t, !recently_expired(&fx.svc, "inst_r2", now_ms(&fx.clock)), "B may pull again at once")

	// Any other expiry reason still stops the holder.
	for reason in ([]string{EXPIRE_TTL, EXPIRE_HARD_CAP, EXPIRE_INSTANCE_LOST, EXPIRE_UNCONFIRMED, EXPIRE_REPLACED, EXPIRE_DEP_ADDED, EXPIRE_CHAIN_CLOSED, EXPIRE_CANCELLED, EXPIRE_USER_STOPPED}) {
		testing.expectf(t, expiry_stops_holder(reason), "%s expiry stops the holder", reason)
	}
	testing.expect(t, !expiry_stops_holder(EXPIRE_IDLE), "idle expiry keeps the holder")
	testing.expect(t, !expiry_stops_holder(EXPIRE_CHANGES_REQUESTED), "changes_requested expiry keeps the holder")
	// Behaviourally: the reworking worker's lease hits the hard cap → stopped.
	if _, w_held := lease_of(fx, "inst_w1"); !testing.expect(t, w_held, "worker re-granted for rework") do return
	confirm_holder(fx, "inst_w1")
	w_gen := run_count_of(fx, "inst_w1")
	wake_log_reset(log)
	for _ in 0..<((LEASE_HARD_CAP_SECONDS / 300) + 1) {
		fixture_advance(fx, 300)
		touch_instance(&fx.svc, "inst_w1")
		_ = fire_due(&fx.svc, now_ms(&fx.clock))
		if count_events(fx, "task_1", EV_LEASE_EXPIRED) >= 2 do break
	}
	testing.expect(t, strings.contains(last_event_payload(fx, "task_1", EV_LEASE_EXPIRED), `"reason":"hard_cap"`), "worker lease hit the hard cap")
	// The stop and the same-UoW re-grant fold into a relaunch (new generation,
	// full bootstrap); either way the old process is ended, never nudged.
	if entry := wake_log_run_entry(log, "inst_w1"); entry != "" {
		testing.expectf(t, !strings.contains(entry, `"deliver":"nudge"`), "hard-cap re-grant relaunches, not nudges (%s)", entry)
		testing.expect_value(t, run_count_of(fx, "inst_w1"), w_gen + 1)
	} else {
		testing.expect(t, wake_log_has_stop(log, "inst_w1"), "hard-cap expiry stops the holder")
	}
}
