package taskv2

import "core:fmt"
import "core:math/rand"
import "core:testing"
import domain "odin_test:hub/domain"

@(private = "file")
ev :: proc(id: i64, kind: string, payload := "{}") -> domain.Task_Event {
	return domain.Task_Event{event_id = id, ts_ms = id * 1000, kind = kind, payload_json = payload}
}

@(private = "file")
grant :: proc(id: i64, lease := "l1", inst := "inst_a") -> domain.Task_Event {
	return ev(id, EV_LEASE_GRANTED, fmt.tprintf(`{{"lease_id":"%s","kind":"work","instance_id":"%s"}}`, lease, inst))
}

@(private = "file")
expired :: proc(id: i64, reason: string) -> domain.Task_Event {
	return ev(id, EV_LEASE_EXPIRED, fmt.tprintf(`{{"lease_id":"l1","kind":"work","reason":"%s"}}`, reason))
}

@(private = "file")
input_task :: proc(deps_done := true, roles := 0, user := false) -> Fold_Input {
	return Fold_Input{deps_done = deps_done, kind = .Task, review_roles_count = roles, requires_user_approval = user}
}

@(test)
test_fold_empty_is_backlog :: proc(t: ^testing.T) {
	v := fold_task(nil, input_task())
	testing.expect_value(t, v.state, domain.Task_State.Backlog)
	testing.expect_value(t, v.attempt_no, 0)
}

@(test)
test_fold_published_with_deps_is_ready_only_when_unblocked :: proc(t: ^testing.T) {
	evs := []domain.Task_Event{ev(1, EV_PUBLISHED)}
	testing.expect_value(t, fold_task(evs, input_task(deps_done = true)).state, domain.Task_State.Ready)
	testing.expect_value(t, fold_task(evs, input_task(deps_done = false)).state, domain.Task_State.Backlog)
	gate := Fold_Input{deps_done = true, kind = .Gate}
	testing.expect_value(t, fold_task(evs, gate).state, domain.Task_State.Backlog)
}

@(test)
test_fold_grant_is_in_progress_and_submit_routes_by_reviewers :: proc(t: ^testing.T) {
	evs := []domain.Task_Event{ev(1, EV_PUBLISHED), grant(2), ev(3, EV_SUBMITTED)}
	// no reviewers, no user approval → done directly
	v := fold_task(evs, input_task(roles = 0))
	testing.expect_value(t, v.state, domain.Task_State.Done)
	testing.expect_value(t, v.attempt_no, 1)
	// a review role → in_review
	v2 := fold_task(evs, input_task(roles = 1))
	testing.expect_value(t, v2.state, domain.Task_State.In_Review)
	// user approval alone → in_review
	v3 := fold_task(evs, input_task(roles = 0, user = true))
	testing.expect_value(t, v3.state, domain.Task_State.In_Review)
	// in_progress while the lease is live
	testing.expect_value(t, fold_task(evs[:2], input_task()).state, domain.Task_State.In_Progress)
}

// test_attempt_increments_except_after_handoff (plan §6 M1): every work grant is a
// new attempt unless the previous release was `handoff` (the attempt continues).
@(test)
test_attempt_increments_except_after_handoff :: proc(t: ^testing.T) {
	evs := []domain.Task_Event{
		ev(1, EV_PUBLISHED),
		grant(2), expired(3, EXPIRE_TTL),          // attempt 1 ends
		grant(4), ev(5, EV_HANDOFF),               // attempt 2 … handed off
		grant(6),                                   // still attempt 2
		ev(7, EV_HANDOFF),
		grant(8),                                   // still attempt 2
		expired(9, EXPIRE_IDLE),
		grant(10),                                  // attempt 3
	}
	v := fold_task(evs, input_task())
	testing.expect_value(t, v.attempt_no, 3)
	testing.expect_value(t, v.counting_attempts, 3)
	testing.expect_value(t, v.state, domain.Task_State.In_Progress)
	testing.expect_value(t, fold_task(evs[:7], input_task()).attempt_no, 2)
	testing.expect_value(t, fold_task(evs[:7], input_task()).state, domain.Task_State.Ready)
}

// test_noncounting_attempts_skip_budget (plan §6 M1): replaced / dep_added / reopen
// start attempts that do not consume the budget; five counting failures block.
@(test)
test_noncounting_attempts_skip_budget :: proc(t: ^testing.T) {
	evs := make([dynamic]domain.Task_Event)
	defer delete(evs)
	id: i64 = 1
	append(&evs, ev(id, EV_PUBLISHED)); id += 1
	// four counting attempts that expire
	for _ in 0..<4 {
		append(&evs, grant(id)); id += 1
		append(&evs, expired(id, EXPIRE_TTL)); id += 1
	}
	// two structural restarts: replaced, dep_added
	append(&evs, grant(id)); id += 1
	append(&evs, expired(id, EXPIRE_REPLACED)); id += 1
	append(&evs, grant(id)); id += 1          // non-counting
	append(&evs, expired(id, EXPIRE_DEP_ADDED)); id += 1
	append(&evs, grant(id)); id += 1          // non-counting
	v := fold_task(evs[:], input_task())
	testing.expect_value(t, v.attempt_no, 7)
	testing.expect_value(t, v.counting_attempts, 5)
	testing.expect(t, !v.budget_exhausted, "structural restarts never exhaust the budget")
	testing.expect_value(t, v.state, domain.Task_State.In_Progress)
	// the fifth COUNTING attempt expiring exhausts the budget → backlog · human
	append(&evs, expired(id, EXPIRE_TTL)); id += 1
	v2 := fold_task(evs[:], input_task())
	testing.expect(t, v2.budget_exhausted, "fifth counting failure exhausts the budget")
	testing.expect_value(t, v2.state, domain.Task_State.Backlog)
	testing.expect(t, v2.blocked_on_json != "", "blocked_on human badge set")
	// a human answer clears it
	append(&evs, ev(id, EV_ANSWERED)); id += 1
	testing.expect_value(t, fold_task(evs[:], input_task()).state, domain.Task_State.Ready)
	// reopen after done is non-counting too
	evs2 := []domain.Task_Event{ev(1, EV_PUBLISHED), grant(2), ev(3, EV_SUBMITTED), ev(4, EV_REOPENED), grant(5)}
	v3 := fold_task(evs2, input_task())
	testing.expect_value(t, v3.attempt_no, 2)
	testing.expect_value(t, v3.counting_attempts, 1)
}

// test_block_goes_to_backlog_not_ready (plan §6 M1).
@(test)
test_block_goes_to_backlog_not_ready :: proc(t: ^testing.T) {
	evs := []domain.Task_Event{
		ev(1, EV_PUBLISHED), grant(2),
		ev(3, EV_BLOCKED, `{"lease_id":"l1","waiting_on":{"kind":"human","reason":"need creds","since_ms":3000}}`),
	}
	v := fold_task(evs, input_task())
	testing.expect_value(t, v.state, domain.Task_State.Backlog)
	testing.expect(t, v.blocked_on_json != "", "blocked badge")
	testing.expect(t, !v.has_work_lease, "lease released on block")
	after := []domain.Task_Event{evs[0], evs[1], evs[2], ev(4, EV_ANSWERED)}
	testing.expect_value(t, fold_task(after, input_task()).state, domain.Task_State.Ready)
}

@(test)
test_fold_changes_requested_and_oscillation :: proc(t: ^testing.T) {
	evs := make([dynamic]domain.Task_Event)
	defer delete(evs)
	id: i64 = 1
	append(&evs, ev(id, EV_PUBLISHED)); id += 1
	for round in 0..<3 {
		append(&evs, grant(id)); id += 1
		append(&evs, ev(id, EV_SUBMITTED)); id += 1
		v := fold_task(evs[:], input_task(roles = 1))
		testing.expect_value(t, v.state, domain.Task_State.In_Review)
		append(&evs, ev(id, EV_CHANGES_REQUESTED)); id += 1
		v2 := fold_task(evs[:], input_task(roles = 1))
		testing.expect_value(t, v2.review_rounds, round + 1)
		if round < 2 {
			testing.expect_value(t, v2.state, domain.Task_State.Ready)
		} else {
			testing.expect_value(t, v2.state, domain.Task_State.Backlog)
			testing.expect(t, v2.oscillating, "third round trips the oscillation guard")
		}
	}
	// approval → done
	evs2 := []domain.Task_Event{ev(1, EV_PUBLISHED), grant(2), ev(3, EV_SUBMITTED), ev(4, EV_APPROVED)}
	testing.expect_value(t, fold_task(evs2, input_task(roles = 1)).state, domain.Task_State.Done)
}

@(test)
test_fold_cancel_reopen :: proc(t: ^testing.T) {
	evs := []domain.Task_Event{ev(1, EV_PUBLISHED), grant(2), ev(3, EV_CANCELLED)}
	v := fold_task(evs, input_task())
	testing.expect_value(t, v.state, domain.Task_State.Cancelled)
	testing.expect(t, !v.has_work_lease, "cancel releases the lease")
	re := []domain.Task_Event{evs[0], evs[1], evs[2], ev(4, EV_REOPENED)}
	testing.expect_value(t, fold_task(re, input_task()).state, domain.Task_State.Ready)
}

@(test)
test_fold_migrated_baseline :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"ready", "ready"}, {"backlog", "backlog"}, {"in_progress", "in_progress"},
		{"in_review", "in_review"}, {"done", "done"}, {"cancelled", "cancelled"},
	}
	for c in cases {
		evs := []domain.Task_Event{ev(1, EV_MIGRATED, fmt.tprintf(`{{"from_status":"x","state":"%s","published":1,"attempt_no":1}}`, c[0]))}
		want, _ := domain.task_state_from_string(c[1])
		// A migrated `backlog` is backlog because its deps are not done (the
		// migration computed exactly that); feed the fold the same fact.
		testing.expect_value(t, fold_task(evs, input_task(deps_done = c[0] != "backlog")).state, want)
	}
	// paused → backlog with the blocked badge carried in the payload
	evs := []domain.Task_Event{ev(1, EV_MIGRATED, `{"from_status":"paused","state":"backlog","published":true,"attempt_no":0,"blocked_on":{"kind":"human","reason":"paused_before_v2"}}`)}
	v := fold_task(evs, input_task())
	testing.expect_value(t, v.state, domain.Task_State.Backlog)
	testing.expect(t, v.blocked_on_json != "", "blocked badge from migration")
	// unpublished migrated task never becomes ready
	evs2 := []domain.Task_Event{ev(1, EV_MIGRATED, `{"from_status":"assigned","state":"backlog","published":0,"attempt_no":0}`)}
	testing.expect_value(t, fold_task(evs2, input_task()).state, domain.Task_State.Backlog)
}

// test_fold_property_invariants: random event sequences never violate the state
// invariants of plan §2.2. (The "cached projection == fold" half of the property
// lives in service_test.odin, where real sqlite rows are driven through the engine.)
@(test)
test_fold_property_invariants :: proc(t: ^testing.T) {
	kinds := []string{
		EV_PUBLISHED, EV_LEASE_GRANTED, EV_SUBMITTED, EV_BLOCKED, EV_HANDOFF, EV_LEASE_EXPIRED,
		EV_CHANGES_REQUESTED, EV_APPROVED, EV_CANCELLED, EV_REOPENED, EV_ANSWERED, EV_COMMENT, EV_HEARTBEAT,
	}
	reasons := []string{EXPIRE_TTL, EXPIRE_HARD_CAP, EXPIRE_IDLE, EXPIRE_INSTANCE_LOST, EXPIRE_REPLACED, EXPIRE_DEP_ADDED}
	r := rand.create(0xC0FFEE)
	context.random_generator = rand.default_random_generator(&r)
	for iter in 0..<400 {
		n := int(rand.int31_max(25))
		evs := make([dynamic]domain.Task_Event, context.temp_allocator)
		for i in 0..<n {
			kind := kinds[rand.int31_max(i32(len(kinds)))]
			payload := "{}"
			switch kind {
			case EV_LEASE_GRANTED:
				payload = `{"lease_id":"l","kind":"work","instance_id":"i"}`
			case EV_LEASE_EXPIRED:
				payload = fmt.tprintf(`{{"lease_id":"l","kind":"work","reason":"%s"}}`, reasons[rand.int31_max(i32(len(reasons)))])
			case EV_BLOCKED:
				payload = `{"waiting_on":{"kind":"human"}}`
			}
			append(&evs, ev(i64(i + 1), kind, payload))
		}
		inp := Fold_Input{deps_done = rand.int31_max(2) == 0, kind = .Task, review_roles_count = int(rand.int31_max(2)), requires_user_approval = rand.int31_max(2) == 0}
		v := fold_task(evs[:], inp)
		tag := fmt.tprintf("iter %d", iter)
		switch v.state {
		case .In_Progress:
			testing.expect(t, v.has_work_lease, tag)
		case .Ready:
			testing.expect(t, v.published && inp.deps_done && v.blocked_on_json == "" && !v.has_work_lease && !v.in_review && !v.done && !v.cancelled, tag)
		case .Done:
			testing.expect(t, v.done && !v.cancelled && !v.has_work_lease, tag)
		case .Cancelled:
			testing.expect(t, v.cancelled, tag)
		case .In_Review:
			testing.expect(t, v.in_review && !v.has_work_lease && !v.done && !v.cancelled, tag)
		case .Backlog:
			testing.expect(t, !v.has_work_lease && !v.done && !v.cancelled && !v.in_review, tag)
		}
		testing.expect(t, v.counting_attempts <= v.attempt_no, tag)
		testing.expect(t, v.attempt_no >= 0, tag)
		// determinism: folding twice is identical
		v2 := fold_task(evs[:], inp)
		testing.expect(t, v.state == v2.state && v.attempt_no == v2.attempt_no && v.blocked_on_json == v2.blocked_on_json, tag)
		// prefix monotonicity of attempt_no
		if n > 0 {
			prev := fold_task(evs[:n-1], inp)
			testing.expect(t, prev.attempt_no <= v.attempt_no, tag)
		}
	}
}

@(test)
test_raw_object_field_is_verbatim :: proc(t: ^testing.T) {
	p := `{"a":"x","waiting_on": {"kind":"human", "note":"has } brace \"q\"","n":{"z":1}},"b":2}`
	raw, ok := raw_object_field(p, "waiting_on")
	testing.expect(t, ok, "found")
	testing.expect_value(t, raw, `{"kind":"human", "note":"has } brace \"q\"","n":{"z":1}}`)
	_, missing := raw_object_field(p, "nope")
	testing.expect(t, !missing, "absent key")
	_, not_obj := raw_object_field(p, "a")
	testing.expect(t, !not_obj, "non-object value")
	_, nested_key := raw_object_field(`{"outer":{"waiting_on":{"kind":"x"}}}`, "waiting_on")
	testing.expect(t, !nested_key, "only top-level keys match")
}

// answered_question names the block an `answered` event cleared — never an
// older, already-answered question, and system blocks (no `blocked` event)
// included (review of task_18df5257ac412b52, finding 2).
@(test)
test_answered_question_is_the_active_block :: proc(t: ^testing.T) {
	q1 := ev(2, EV_BLOCKED, `{"lease_id":"l1","attempt_no":1,"waiting_on":{"kind":"human","reason":"Q1?"}}`)
	// Order A: an agent question answered, then a merge conflict answered.
	a := []domain.Task_Event{
		grant(1), q1, ev(3, EV_ANSWERED, `{"note":"A1"}`),
		grant(4, "l2"), ev(5, EV_SUBMITTED, `{"lease_id":"l2","attempt_no":2}`), ev(6, EV_APPROVED),
		ev(7, EV_MERGE_CONFLICT, `{"branch":"b","files":"calc/stats.py"}`), ev(8, EV_ANSWERED, `{"note":"A2"}`),
	}
	testing.expect_value(t, answered_question(a, 2, input_task()), "Q1?")
	testing.expect_value(t, answered_question(a, 7, input_task()), "Your finished branch did not merge (conflicting files: calc/stats.py).")
	// Order B: the merge conflict first, then an agent question.
	b := []domain.Task_Event{
		grant(1), ev(2, EV_SUBMITTED, `{"lease_id":"l1","attempt_no":1}`), ev(3, EV_APPROVED),
		ev(4, EV_MERGE_CONFLICT, `{"branch":"b","files":"README.md"}`), ev(5, EV_ANSWERED, `{"note":"A1"}`),
		grant(6, "l2"), ev(7, EV_BLOCKED, `{"lease_id":"l2","attempt_no":2,"waiting_on":{"kind":"human","reason":"Q2?"}}`), ev(8, EV_ANSWERED, `{"note":"A2"}`),
	}
	testing.expect_value(t, answered_question(b, 4, input_task()), "Your finished branch did not merge (conflicting files: README.md).")
	testing.expect_value(t, answered_question(b, 7, input_task()), "Q2?")
}
