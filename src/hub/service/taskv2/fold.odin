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
//   `handoff`; attempts whose previous release was replaced|dep_added|reopen|user_stopped
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
	User_Stopped,
	// a solo coordinator's lease expired (it is never stopped and re-pulls);
	// non-counting like User_Stopped (REQ-SOLO-6).
	Released_Noncounting,
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
	// held: a coordinator/owner hold (REQ-TV2-5). hold_json is its blocked_on
	// object; while a work or review lease is live it carries checkpoint_requested.
	held:               bool,
	hold_json:          string,
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

	current_attempt_counted := false
	for ev in events {
		v.last_event_id = ev.event_id
		switch ev.kind {
		case EV_MIGRATED:
			v.published = payload_bool(ev.payload_json, "published")
			v.attempt_no = jsonx.extract_int(ev.payload_json, "attempt_no", 0, true)
			v.counting_attempts = v.attempt_no
			current_attempt_counted = v.attempt_no > 0
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
				current_attempt_counted = attempt_counts(v.last_release)
				if current_attempt_counted do v.counting_attempts += 1
			}
			v.last_release = .None
		case EV_SUBMITTED:
			v.has_work_lease = false
			v.last_release = .Submitted
			is_gate := input.kind == .Gate || payload_bool(ev.payload_json, "gate")
			if !is_gate && input.review_roles_count == 0 && !input.requires_user_approval {
				v.done = true
				v.in_review = false
			} else {
				v.in_review = true
			}
		case EV_BLOCKED:
			dispatch := payload_bool(ev.payload_json, "dispatch_failed")
			infrastructure := payload_bool(ev.payload_json, "infrastructure")
			continuation := (dispatch && payload_bool(ev.payload_json, "continuation")) || (infrastructure && v.last_release == .Handoff)
			review := jsonx.extract_string(ev.payload_json, "kind", "", true, context.temp_allocator) == domain.LEASE_KIND_REVIEW
			if dispatch && review {
				if v.review_lease_count > 0 do v.review_lease_count -= 1
			} else {
				v.has_work_lease = false
				if dispatch && !payload_bool(ev.payload_json, "continuation") && current_attempt_counted {
					v.counting_attempts -= 1
					current_attempt_counted = false
				}
			}
			v.last_release = .Blocked
			if continuation do v.last_release = .Handoff
			if raw, ok := raw_object_field(ev.payload_json, "waiting_on"); ok {
				v.blocked_on_json = raw
			} else {
				v.blocked_on_json = human_block("blocked", ev.ts_ms)
			}
			// Budget is spent by ATTEMPTS, whatever ended them (review S1): a
			// fifth block parks the task for a human exactly like a fifth expiry.
			if !dispatch && !infrastructure do apply_budget(&v, max_attempts, ev.ts_ms)
		case EV_HANDOFF:
			// A review holder's checkpoint handoff on a held task (REQ-TV2-5)
			// frees only that review lease; the attempt and its reviews stand.
			if jsonx.extract_string(ev.payload_json, "kind", "", true, context.temp_allocator) == domain.LEASE_KIND_REVIEW {
				if v.review_lease_count > 0 do v.review_lease_count -= 1
				continue
			}
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
			case EXPIRE_USER_STOPPED: v.last_release = .User_Stopped
			case:
				// The expiry records whether it counts: a solo coordinator's lapse
				// (counting:false) is not a failed attempt (REQ-SOLO-6).
				if c, cok := jsonx.extract_bool_literal(ev.payload_json, "counting", true); cok && !c {
					v.last_release = .Released_Noncounting
					continue
				}
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
		case EV_HELD:
			v.held = true
			reason := jsonx.extract_string(ev.payload_json, "reason", "", true, context.temp_allocator)
			v.hold_json = hold_block(reason, ev.ts_ms)
		case EV_HOLD_RELEASED:
			v.held = false
			v.hold_json = ""
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
		case EV_MERGE_CONFLICT:
			// The task's branch did not merge into its directory: it is no
			// longer done. It waits on a human; once answered the next
			// (non-counting) attempt reconciles the branch and resubmits.
			if !v.done do continue
			v.done = false
			v.last_release = .Reopened
			v.blocked_on_json = human_block("merge_conflict", ev.ts_ms)
		case EV_ANSWERED:
			infrastructure := is_agent_not_running_block(v.blocked_on_json)
			v.blocked_on_json = ""
			v.budget_exhausted = false
			v.oscillating = false
			if !infrastructure do v.review_rounds = 0
		case:
			// audit-only kinds
		}
	}

	// A hold is an overlay, applied last so a block answered while held (or a
	// handoff, which clears nothing) leaves the hold standing: the task parks
	// in backlog as blocked_on {kind: hold} instead of being re-dispatched
	// (REQ-TV2-5). Another live block (e.g. a failed reviewer's
	// agent_not_running) stays the primary blocked_on so it remains visible,
	// and the hold rides along as its `hold` member; task_hold_object reads
	// either form, so every hold guard sees the hold whatever else blocks.
	if v.held && !v.done && !v.cancelled {
		hold := v.hold_json
		if v.has_work_lease || v.review_lease_count > 0 do hold = hold_checkpoint_block(v.hold_json)
		if v.blocked_on_json == "" {
			v.blocked_on_json = hold
		} else {
			v.blocked_on_json = with_hold_member(v.blocked_on_json, hold)
		}
	}
	v.state = derive_state(v, input)
	return v
}

// hold_block is the blocked_on object of a held task. Temp-allocated.
@(private = "file")
hold_block :: proc(reason: string, since_ms: i64) -> string {
	p := json_begin()
	json_str(&p, "kind", "hold")
	json_str(&p, "reason", reason)
	json_int(&p, "since_ms", since_ms)
	return json_end(&p)
}

// hold_checkpoint_block marks a hold set on a leased task: the holder is asked
// to checkpoint (lease handoff); the lease is never revoked.
@(private = "file")
hold_checkpoint_block :: proc(hold_json: string) -> string {
	body := strings.trim_space(hold_json)
	return fmt.tprintf(`%s,"checkpoint_requested":true}}`, body[:len(body)-1])
}

// with_hold_member appends the hold object to another block as its last
// member, `hold`. Temp-allocated.
@(private = "file")
with_hold_member :: proc(block_json, hold_json: string) -> string {
	body := strings.trim_space(block_json)
	return fmt.tprintf(`%s,"hold":%s}`, body[:len(body)-1], hold_json)
}

// task_is_held: the task carries a hold, either as its primary blocked_on
// (kind == "hold") or nested under another block's `hold` member.
task_is_held :: proc(task: domain.Task) -> bool {
	_, held := task_hold_object(task.blocked_on_json)
	return held
}

// task_hold_object returns the hold object of a blocked_on: blocked_on itself
// when its kind is hold, else its nested `hold` member (see fold_task).
task_hold_object :: proc(blocked_on_json: string) -> (string, bool) {
	if strings.trim_space(blocked_on_json) == "" do return "", false
	if jsonx.extract_string(blocked_on_json, "kind", "", true, context.temp_allocator) == "hold" do return blocked_on_json, true
	return raw_object_field(blocked_on_json, "hold")
}

// blocked_on_without_hold drops the nested `hold` member that fold_task
// appends to another block, so a hold or release does not read as a change
// of that block (no duplicate attention, stale agent-failure cards stay valid).
// A primary hold is returned unchanged. Temp-allocated.
blocked_on_without_hold :: proc(blocked_on_json: string) -> string {
	hold, ok := raw_object_field(blocked_on_json, "hold")
	if !ok do return blocked_on_json
	body := strings.trim_space(blocked_on_json)
	suffix := fmt.tprintf(`,"hold":%s}`, hold)
	if !strings.has_suffix(body, suffix) do return blocked_on_json
	return fmt.tprintf("%s}", body[:len(body)-len(suffix)])
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
	case .Replaced, .Dep_Added, .Reopened, .User_Stopped, .Released_Noncounting: return false
	}
	return true
}

@(private = "file")
derive_state :: proc(v: Task_View, input: Fold_Input) -> domain.Task_State {
	if v.cancelled do return .Cancelled
	if v.done do return .Done
	if v.has_work_lease do return .In_Progress
	if is_agent_not_running_block(v.blocked_on_json) do return .Backlog
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
		review_roles_count = brief_review_roles_count(task.brief_json),
		max_attempts = brief_max_attempts(task.brief_json),
	}
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
