package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import jsonx "odin_test:lib/jsonx"

// fold_task is the PURE function from a task's ordered events to its ticket
// view. `tasks.state` is a cached projection of `fold_task(...).state` and is
// property-tested against it; nothing else may compute a state.
//
// Rules (plan §2.2):
//   ready ⇔ published ∧ deps done ∧ blocked_on = null ∧ no work lease ∧ kind = task
//   in_progress ⇔ a live work lease exists
//   attempt_no increments on lease_granted(work) unless the last release was
//   `handoff`; attempts whose previous release was replaced|dep_added|reopen
//   set counts_toward_budget = 0; budget TASK_MAX_ATTEMPTS counts the rest.
//   review_rounds = count of changes_requested; ≥ 3 → backlog · blocked_on human.
//   block / budget exhaustion / no_reviewer_for_role → backlog + blocked_on badge.
//   submit with review_roles = [] ∧ !requires_user_approval → done directly.
//   reopen(done|cancelled) → new attempt (counted at the next grant, non-counting).

// Fold_Input carries the facts that live outside the task's own event stream.
Fold_Input :: struct {
	// deps_done: every depends_on task is done|cancelled (computed by the caller
	// from the other tasks' cached states — their own folds).
	deps_done:                  bool,
	kind:                       domain.Task_Kind,
	requires_user_approval:     bool,
	require_independent_verify: bool,
	// review_roles_count: len(brief.review_roles) + len(brief.reviewers).
	review_roles_count:         int,
	// max_attempts: brief.budget.max_attempts, 0 → TASK_MAX_ATTEMPTS.
	max_attempts:               int,
}

Last_Release :: enum {
	None,
	Submitted,
	Blocked,
	Handoff,
	Expired,
	Changes_Requested,
	Replaced,
	Dep_Added,
	Reopened,
}

Task_View :: struct {
	state:              domain.Task_State,
	published:          bool,
	attempt_no:         int,
	counting_attempts:  int,
	review_rounds:      int,
	// blocked_on_json: "" when not blocked; otherwise the waiting_on object
	// (`{"kind": "human", "reason": …, "since": …}`) exactly as recorded.
	blocked_on_json:    string,
	has_work_lease:     bool,
	work_lease_id:      string,
	holder_instance_id: string,
	review_lease_count: int,
	last_release:       Last_Release,
	budget_exhausted:   bool,
	oscillating:        bool,
	in_review:          bool,
	done:               bool,
	cancelled:          bool,
	// last_event_id is the id of the last event folded (0 for an empty list).
	last_event_id:      i64,
}

// Stage_View (workflow chains): derived over the materialised instances of one
// stage. `complete` = every instance done; `failed` = any instance cancelled or
// blocked on a human after its budget; `outputs` = the `output` facets in
// stage_index order, only when complete. Only the type lands in M0; the
// materialiser (M3b) fills it.
Stage_View :: struct {
	stage_key: string,
	complete:  bool,
	failed:    bool,
	// outputs: verbatim `output` facet bodies in stage_index order.
	outputs:   []string,
}

// fold_task folds `events` (ascending event_id) with `input` into a Task_View.
// It allocates nothing that outlives the call except the returned
// blocked_on_json / ids, which alias the event payload strings.
fold_task :: proc(events: []domain.Task_Event, input: Fold_Input) -> Task_View {
	v := Task_View{state = .Backlog}
	max_attempts := input.max_attempts
	if max_attempts <= 0 do max_attempts = domain.TASK_MAX_ATTEMPTS

	for ev in events {
		v.last_event_id = ev.event_id
		switch ev.kind {
		case EV_MIGRATED:
			v.published = payload_bool(ev.payload_json, "published")
			v.attempt_no = jsonx.extract_int(ev.payload_json, "attempt_no", 0, true)
			v.counting_attempts = v.attempt_no
			state_s := jsonx.extract_string(ev.payload_json, "state", "", true, context.temp_allocator)
			state, _ := domain.task_state_from_string(state_s)
			v.has_work_lease = false
			v.in_review = false
			v.done = false
			v.cancelled = false
			v.blocked_on_json = ""
			#partial switch state {
			case .In_Progress: v.has_work_lease = true
			case .In_Review: v.in_review = true
			case .Done: v.done = true
			case .Cancelled: v.cancelled = true
			}
			if raw, ok := raw_object_field(ev.payload_json, "blocked_on"); ok && strings.trim_space(raw) != "" {
				v.blocked_on_json = raw
			}
		case EV_PUBLISHED:
			v.published = true
		case EV_LEASE_GRANTED:
			kind := jsonx.extract_string(ev.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator)
			if kind == domain.LEASE_KIND_REVIEW {
				v.review_lease_count += 1
				continue
			}
			// A grant on a terminal task cannot happen through the matcher; if an
			// event stream ever carries one it is audit only — terminal wins.
			if v.done || v.cancelled do continue
			v.has_work_lease = true
			v.in_review = false
			v.work_lease_id = jsonx.extract_string(ev.payload_json, "lease_id", "", true, context.temp_allocator)
			v.holder_instance_id = jsonx.extract_string(ev.payload_json, "instance_id", "", true, context.temp_allocator)
			if v.last_release != .Handoff {
				v.attempt_no += 1
				if attempt_counts(v.last_release) do v.counting_attempts += 1
			}
			v.last_release = .None
		case EV_SUBMITTED:
			v.has_work_lease = false
			v.last_release = .Submitted
			is_gate := input.kind == .Gate || payload_bool(ev.payload_json, "gate")
			if !is_gate && input.review_roles_count == 0 && !input.requires_user_approval && !input.require_independent_verify {
				v.done = true
				v.in_review = false
			} else {
				v.in_review = true
			}
		case EV_BLOCKED:
			v.has_work_lease = false
			v.last_release = .Blocked
			if raw, ok := raw_object_field(ev.payload_json, "waiting_on"); ok {
				v.blocked_on_json = raw
			} else {
				v.blocked_on_json = human_block("blocked", ev.ts_ms)
			}
			// Budget is spent by ATTEMPTS, whatever ended them (review S1): a
			// fifth block parks the task for a human exactly like a fifth expiry.
			apply_budget(&v, max_attempts, ev.ts_ms)
		case EV_HANDOFF:
			v.has_work_lease = false
			v.last_release = .Handoff
		case EV_LEASE_EXPIRED:
			kind := jsonx.extract_string(ev.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator)
			if kind == domain.LEASE_KIND_REVIEW {
				if v.review_lease_count > 0 do v.review_lease_count -= 1
				continue
			}
			v.has_work_lease = false
			reason := jsonx.extract_string(ev.payload_json, "reason", "", true, context.temp_allocator)
			switch reason {
			case EXPIRE_REPLACED: v.last_release = .Replaced
			case EXPIRE_DEP_ADDED: v.last_release = .Dep_Added
			case:
				v.last_release = .Expired
				apply_budget(&v, max_attempts, ev.ts_ms)
			}
		case EV_CHANGES_REQUESTED:
			// Verdicts only mean something while the task awaits review.
			if !v.in_review do continue
			v.in_review = false
			if input.kind == .Gate {
				v.cancelled = true
				continue
			}
			v.review_rounds += 1
			v.last_release = .Changes_Requested
			if v.review_rounds >= OSCILLATION_ROUNDS {
				v.oscillating = true
				v.blocked_on_json = human_block("oscillation", ev.ts_ms)
			}
			apply_budget(&v, max_attempts, ev.ts_ms)
		case EV_APPROVED:
			if !v.in_review do continue
			v.in_review = false
			v.done = true
		case EV_CARRIED_FORWARD:
			v.published = true
			v.in_review = false
			v.has_work_lease = false
			v.cancelled = false
			v.done = true
		case EV_CANCELLED:
			v.cancelled = true
			v.has_work_lease = false
			v.in_review = false
		case EV_REOPENED:
			v.done = false
			v.cancelled = false
			v.in_review = false
			v.has_work_lease = false
			v.blocked_on_json = ""
			v.budget_exhausted = false
			v.oscillating = false
			v.review_rounds = 0
			v.last_release = .Reopened
		case EV_ANSWERED:
			v.blocked_on_json = ""
			v.budget_exhausted = false
			v.oscillating = false
			v.review_rounds = 0
		case:
			// audit-only kinds
		}
	}

	v.state = derive_state(v, input)
	return v
}

// OSCILLATION_ROUNDS: changes_requested count at which the task stops bouncing
// between author and reviewer and waits for a human.
OSCILLATION_ROUNDS :: 3

// apply_budget parks the task for a human once `max_attempts` counting
// attempts have been spent, whatever ended the last one (expiry, block,
// changes_requested). The next grant would be attempt max+1; grant_in_uow
// refuses it independently (belt and braces).
@(private = "file")
apply_budget :: proc(v: ^Task_View, max_attempts: int, ts_ms: i64) {
	if v.counting_attempts >= max_attempts && !v.done && !v.cancelled && !v.budget_exhausted {
		v.budget_exhausted = true
		v.blocked_on_json = human_block("budget_exhausted", ts_ms)
	}
}

// budget_allows_grant: whether one more WORK grant is within the budget. A
// grant after a non-counting release (replaced/dep_added/reopened) or a handoff
// continuation never consumes budget.
budget_allows_grant :: proc(v: Task_View, max_attempts_in: int) -> bool {
	max_attempts := max_attempts_in
	if max_attempts <= 0 do max_attempts = domain.TASK_MAX_ATTEMPTS
	if v.last_release == .Handoff || !attempt_counts(v.last_release) do return true
	return v.counting_attempts < max_attempts
}

// human_block builds the blocked_on badge the fold itself raises (budget,
// oscillation). `since_ms` is the event timestamp so the 24 h re-alert can key
// off it exactly like an agent-written `blocked.waiting_on.since_ms`.
// Temp-allocated: callers persist it through save_task (review S9).
@(private = "file")
human_block :: proc(reason: string, since_ms: i64) -> string {
	// NB: Odin's fmt treats `{`/`}` as argument syntax, hence `{{`/`}}`.
	return fmt.tprintf(`{{"kind":"human","reason":"%s","since_ms":%d}}`, reason, since_ms)
}

@(private = "file")
attempt_counts :: proc(prev: Last_Release) -> bool {
	#partial switch prev {
	case .Replaced, .Dep_Added, .Reopened: return false
	}
	return true
}

@(private = "file")
derive_state :: proc(v: Task_View, input: Fold_Input) -> domain.Task_State {
	if v.cancelled do return .Cancelled
	if v.done do return .Done
	if v.has_work_lease do return .In_Progress
	if v.in_review do return .In_Review
	if v.published && input.deps_done && v.blocked_on_json == "" && input.kind == .Task do return .Ready
	return .Backlog
}

// payload_bool accepts JSON true/false and 0/1 (the migration writes integers).
@(private = "file")
payload_bool :: proc(payload, key: string) -> bool {
	if b, ok := jsonx.extract_bool_literal(payload, key, true); ok do return b
	if n, ok := jsonx.extract_int_found(payload, key, true); ok do return n != 0
	return false
}

// ---- brief helpers (the fold input comes from the task row + brief) ----------

// fold_input_for_task derives the per-task fold inputs from the row and brief;
// deps_done is supplied by the caller (it depends on other tasks).
fold_input_for_task :: proc(task: domain.Task, deps_done: bool) -> Fold_Input {
	return Fold_Input{
		deps_done = deps_done,
		kind = task.kind,
		requires_user_approval = task.requires_user_approval,
		require_independent_verify = brief_require_independent_verify(task.brief_json),
		review_roles_count = brief_review_roles_count(task.brief_json),
		max_attempts = brief_max_attempts(task.brief_json),
	}
}

brief_require_independent_verify :: proc(brief_json: string) -> bool {
	if b, ok := jsonx.extract_bool_literal(brief_json, "require_independent_verify", true); ok do return b
	return false
}

brief_auto_submit :: proc(brief_json: string) -> bool {
	if b, ok := jsonx.extract_bool_literal(brief_json, "auto_submit", true); ok do return b
	return false
}

// brief_review_roles_count: how many agent review requirements the brief has,
// counting review roles AND named reviewers (hybrid review model). 0 means no
// agent reviews the task, so a submit with no user approval goes straight to done.
brief_review_roles_count :: proc(brief_json: string) -> int {
	roles := jsonx.extract_string_array(brief_json, "review_roles", true, context.temp_allocator)
	named := jsonx.extract_string_array(brief_json, "reviewers", true, context.temp_allocator)
	return len(roles) + len(named)
}

brief_review_roles :: proc(brief_json: string, allocator := context.allocator) -> [dynamic]string {
	return jsonx.extract_string_array(brief_json, "review_roles", true, allocator)
}

brief_assignee :: proc(brief_json: string) -> string {
	return strings.trim_space(jsonx.extract_string(brief_json, "assignee", "", true, context.temp_allocator))
}

brief_max_attempts :: proc(brief_json: string) -> int {
	if raw, ok := jsonx.extract_raw_object(brief_json, "budget", true, context.temp_allocator); ok {
		if n, nok := jsonx.extract_int_found(raw, "max_attempts", true); nok && n > 0 do return n
	}
	return domain.TASK_MAX_ATTEMPTS
}

// brief_budget_seconds reads brief.budget.<key> (seconds), falling back to def.
brief_budget_seconds :: proc(brief_json, key: string, def: int) -> int {
	if raw, ok := jsonx.extract_raw_object(brief_json, "budget", true, context.temp_allocator); ok {
		if n, nok := jsonx.extract_int_found(raw, key, true); nok && n > 0 do return n
	}
	return def
}

// deps_done_for computes the fold's deps_done input for `task_id` from the
// chain's dependency edges and the other tasks' cached states.
deps_done_for :: proc(task_id: domain.Task_ID, tasks: []domain.Task, deps: []domain.Task_Dependency) -> bool {
	for d in deps {
		if d.task_id != task_id do continue
		found := false
		for t in tasks {
			if t.task_id != d.depends_on_task_id do continue
			found = true
			if !domain.task_state_unblocks_dependents(t.state) do return false
			break
		}
		if !found do return false
	}
	return true
}

// apply_view_to_task writes the projection fields of `view` onto a task row
// copy (state, attempt_no, blocked_on_json, ready_since/started_at/
// completed_at bookkeeping). `now` is the clock reading of the mutating verb.
apply_view_to_task :: proc(task: domain.Task, view: Task_View, now: string) -> domain.Task {
	out := task
	prev := task.state
	out.state = view.state
	out.attempt_no = view.attempt_no
	out.blocked_on_json = view.blocked_on_json
	if view.state == .Ready {
		if prev != .Ready || out.ready_since == "" do out.ready_since = now
	} else {
		out.ready_since = ""
	}
	if view.state == .In_Progress && out.started_at == "" do out.started_at = now
	if domain.task_state_is_terminal(view.state) {
		if out.completed_at == "" do out.completed_at = now
	} else {
		out.completed_at = ""
	}
	out.updated_at = now
	return out
}
