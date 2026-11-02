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
