package taskv2

import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Review gate (plan §2.5). Evaluated inside the UoW after every review post,
// independent verify exit, and fleet change, for a task in `in_review`:
//
//   needed = required_review_pairs: { (agent, "named") : agent ∈ brief.reviewers }
//            ∪ { (fleet row, role) : role ∈ brief.review_roles ∧ row has role },
//            minus the attempt's author template
//   gate   = every needed pair has an `approve` review on THIS attempt
//            ∧ no `request_changes` on this attempt
//            ∧ (independent verify passed on this attempt, if require_independent_verify)
//            ∧ (user approved on this attempt, if requires_user_approval)
//
// Strict AND per fleet row: two reviewer templates both review. Any
// request_changes → EV_CHANGES_REQUESTED (task → ready, other review leases
// expired); the oscillation guard (fold) parks the task after 3 rounds. A new
// attempt invalidates prior reviews because reviews are keyed by attempt_no.

// Rejected: a request_changes on a GATE task (it is cancelled). Explicit-verdict
// callers (review_post, user_review) then run gate_replan_in_uow; the fleet
// change and verify paths keep the plain cancel (F1).
Gate_Result :: enum { Waiting, Approved, Changes_Requested, Rejected }

gate_approver_policy :: proc(task: domain.Task) -> string {
	approver := jsonx.extract_string(task.brief_json, "approver", "user_or_coordinator", true, context.temp_allocator)
	if gate_obj, gok := jsonx.extract_raw_object(task.brief_json, "gate", true, context.temp_allocator); gok {
		if a := jsonx.extract_string(gate_obj, "approver", "", true, context.temp_allocator); a != "" do approver = a
	}
	if task.requires_user_approval do return "user"
	return approver
}

evaluate_gate_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, task_in: domain.Task, actor: Actor) -> (Gate_Result, bool, domain.Domain_Error) {
	task := task_in
	if task.state != .In_Review do return .Waiting, true, domain.Domain_Error{}
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return .Waiting, false, rerr
	// 1. any request_changes on this attempt wins
	for r in reviews {
		if r.attempt_no != task.attempt_no || r.verdict != "request_changes" do continue
		p := json_begin()
		json_int(&p, "attempt_no", i64(task.attempt_no))
		json_str(&p, "role", r.role)
		json_str(&p, "reviewer", r.reviewer_agent_id if r.reviewer_kind == "agent" else "user")
		if _, _, ok, err := record_event(svc, u, task, actor, EV_CHANGES_REQUESTED, json_end(&p)); !ok do return .Waiting, false, err
		if task.kind == .Gate {
			cp := json_begin()
			json_str(&cp, "reason", "gate_rejected")
			if fresh, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do task = fresh
			if _, _, ok, err := record_event(svc, u, task, actor, EV_CANCELLED, json_end(&cp)); !ok do return .Waiting, false, err
		}
		// other review leases on the task are dropped (reason changes_requested)
		if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
			for l in leases {
				if l.kind != domain.LEASE_KIND_REVIEW do continue
				if expire_lease_in_uow(svc, u, l, EXPIRE_CHANGES_REQUESTED, actor) == .Failed do return .Waiting, false, domain.domain_error(.Internal_Error, "failed to drop a review lease")
			}
		}
		if task.kind == .Gate {
			metric_gate_evaluated(.Rejected)
			return .Rejected, true, domain.Domain_Error{}
		}
		metric_gate_evaluated(.Changes_Requested)
		return .Changes_Requested, true, domain.Domain_Error{}
	}
	if task.kind == .Gate {
		approver := gate_approver_policy(task)
		gate_approved := false
		for r in reviews {
			if r.attempt_no != task.attempt_no || r.verdict != "approve" do continue
			if approver == "user" {
				if r.reviewer_kind == "user" && r.reviewer_instance_id == "" { gate_approved = true; break }
			} else {
				if r.reviewer_kind == "user" || r.role == "coordinator" || r.reviewer_agent_id == "coordinator" { gate_approved = true; break }
			}
		}
		if !gate_approved {
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
		p := json_begin()
		json_int(&p, "attempt_no", i64(task.attempt_no))
		if _, _, ok, err := record_event(svc, u, task, actor, EV_APPROVED, json_end(&p)); !ok do return .Waiting, false, err
		metric_gate_evaluated(.Approved)
		return .Approved, true, domain.Domain_Error{}
	}
	// 2-3. every required agent (role) pair approved and the independent verify
	//      passed — shared with awaits_user_review (attention deck).
	if sat, serr := agent_review_satisfied(svc, chain.chain_id, chain.owner_user_id, task, reviews); serr.code != .None {
		return .Waiting, false, serr
	} else if !sat {
		metric_gate_evaluated(.Waiting)
		return .Waiting, true, domain.Domain_Error{}
	}
	if task.requires_user_approval {
		user_ok := false
		for r in reviews do if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "user" { user_ok = true; break }
		if !user_ok {
			effect_notify_coordinator(svc, u, task.chain_id, task.owner_user_id, "review_requested_from_user", fmt.tprintf("[taskv2] review_requested_from_user: task %s (%s) passed review gate and awaits user approval", task.task_id, task.title))
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
	}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	if _, _, ok, err := record_event(svc, u, task, actor, EV_APPROVED, json_end(&p)); !ok do return .Waiting, false, err
	if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); lerr.code == .None {
		for l in leases {
			if l.kind != domain.LEASE_KIND_REVIEW do continue
			if expire_lease_in_uow(svc, u, l, EXPIRE_REPLACED, actor) == .Failed do return .Waiting, false, domain.domain_error(.Internal_Error, "failed to drop a review lease")
		}
	}
	metric_gate_evaluated(.Approved)
	return .Approved, true, domain.Domain_Error{}
}

// agent_review_satisfied: steps 2-3 of the gate for a non-gate task — every
// required (agent, role) pair approved this attempt (named reviewers and holders
// of each review role, review_pairs.odin) and, if the brief asks for one, a
// passing independent verify on this attempt. Read-only.
agent_review_satisfied :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, task: domain.Task, reviews: []domain.Task_Review) -> (bool, domain.Domain_Error) {
	author_agent := ""
	if holder := last_attempt_holder(svc, task); holder != "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, holder); iok do author_agent = inst.agent_id
	}
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain_id, owner)
	if ferr.code != .None do return false, ferr
	for pair in required_review_pairs(task, fleets, author_agent) {
		approved := false
		for r in reviews {
			if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "agent" && r.role == pair.role && r.reviewer_agent_id == pair.agent_id { approved = true; break }
		}
		if !approved do return false, domain.Domain_Error{}
	}
	if brief_require_independent_verify(task.brief_json) {
		vf, vok := get_facet(svc, task, task.attempt_no, FACET_VERIFY)
		if !vok do return false, domain.Domain_Error{}
		code, cok := jsonx.extract_int_found(vf.body_json, "exit_code", true)
		ind, iok := jsonx.extract_bool_literal(vf.body_json, "independent", true)
		if !cok || code != 0 || !iok || !ind do return false, domain.Domain_Error{}
	}
	return true, domain.Domain_Error{}
}

// ---- attention deck: does this task await the USER? ---------------------------------

User_Attention :: enum { None, Review, Blocked }

// user_attention is the single rule behind the user's attention card for a
// task (card projector, accept guard, reconcile). Read-only.
//
//   Review   — in_review and it is the user's turn: a gate the user may approve
//              (approver user | user_or_coordinator) with no decision yet, or a
//              requires_user_approval task whose agent reviews / independent
//              verify have passed (the moment the coordinator is told
//              review_requested_from_user) and the user has not approved this
//              attempt.
//   Blocked  — blocked_on set and the user can resolve it: every system block
//              (kind human, reason merge_conflict | budget_exhausted |
//              oscillation | blocked) and any agent block except kind "task"
//              (cleared automatically, C3-2) and the v2 backfill of legacy
//              paused tasks (reason paused_before_v2). `badge` is the reason for
//              the three system ones, else "question".
user_attention :: proc(svc: ^Service, task: domain.Task) -> (kind: User_Attention, badge: string) {
	if svc == nil || domain.task_state_is_terminal(task.state) do return .None, ""
	if task.state == .In_Review && awaits_user_review(svc, task) {
		return .Review, ("gate" if task.kind == .Gate else "review")
	}
	if ok, b := blocked_on_user(task); ok do return .Blocked, b
	return .None, ""
}

awaits_user_review :: proc(svc: ^Service, task: domain.Task) -> bool {
	if svc == nil || task.state != .In_Review do return false
	reviews, rerr := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if rerr.code != .None do return false
	for r in reviews {
		if r.attempt_no != task.attempt_no do continue
		// A decision on this attempt is already in: request_changes moves the
		// task on; the user's approve is waiting only on agents (or done).
		if r.verdict == "request_changes" do return false
		if r.verdict == "approve" && r.reviewer_kind == "user" do return false
	}
	if task.kind == .Gate {
		policy := gate_approver_policy(task)
		return policy == "user" || policy == "user_or_coordinator"
	}
	if !task.requires_user_approval do return false
	sat, serr := agent_review_satisfied(svc, task.chain_id, task.owner_user_id, task, reviews)
	return serr.code == .None && sat
}

blocked_on_user :: proc(task: domain.Task) -> (bool, string) {
	raw := task.blocked_on_json
	if len(raw) == 0 || domain.task_state_is_terminal(task.state) do return false, ""
	if jsonx.extract_string(raw, "kind", "", true, context.temp_allocator) == "task" do return false, ""
	reason := jsonx.extract_string(raw, "reason", "", true, context.temp_allocator)
	switch reason {
	case "paused_before_v2": return false, ""
	case "merge_conflict", "budget_exhausted", "oscillation": return true, reason
	}
	return true, "question"
}

// reevaluate_gates_in_uow runs the gate for every in_review task of the chain
// (fleet_upserted/deleted trigger row).
reevaluate_gates_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> (bool, domain.Domain_Error) {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false, err
	for t in tasks {
		if t.state != .In_Review do continue
		if _, ok, gerr := evaluate_gate_in_uow(svc, u, chain, t, hub_actor()); !ok do return false, gerr
	}
	return true, domain.Domain_Error{}
}

// review_needed_from: whether `agent_id` with `role` still owes a review on
// the task's current attempt (matcher: one review lease per needed pair).
review_needed_from :: proc(reviews: []domain.Task_Review, task: domain.Task, agent_id, role: string) -> bool {
	for r in reviews {
		if r.attempt_no == task.attempt_no && r.role == role && r.reviewer_kind == "agent" && r.reviewer_agent_id == agent_id do return false
	}
	return true
}

// regate_after_reviewer_change (F3): the task's named reviewers / review roles
// changed while it awaits review. Review leases whose (agent, role) is no
// longer owed are expired (`replaced`; expire stops the live holder, and a late
// `review post` gets lease_lost). Then the gate is re-run: removing the last
// owed reviewer can satisfy it, which nothing else would notice (no lease left
// to post a verdict). The caller runs after_chain_change once afterwards.
regate_after_reviewer_change :: proc(svc: ^Service, u: ^Uow, task_in: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	task, tok, terr := iface.taskchain_get_task(svc.repo, task_in.task_id)
	if !tok do return false, terr
	// Dropping every reviewer can fold the task straight to done (a submit with
	// nothing owed is done); its review leases are still stale and end here as
	// `replaced` rather than later as `chain_closed`.
	if task.state != .In_Review && task.state != .Done do return true, domain.Domain_Error{}
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return false, cerr
	author_agent := ""
	if holder := last_attempt_holder(svc, task); holder != "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, holder); iok do author_agent = inst.agent_id
	}
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return false, ferr
	pairs := required_review_pairs(task, fleets, author_agent)
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None do return false, lerr
	for l in leases {
		if l.kind != domain.LEASE_KIND_REVIEW do continue
		agent_id := ""
		if inst, iok, _ := iface.agent_get_instance(svc.agents, l.holder_instance_id); iok do agent_id = inst.agent_id
		owed := false
		for role in split_review_roles(l.review_role) {
			for p in pairs do if p.agent_id == agent_id && p.role == role { owed = true; break }
			if owed do break
		}
		if owed do continue
		if expire_lease_in_uow(svc, u, l, EXPIRE_REPLACED, actor) == .Failed {
			return false, domain.domain_error(.Internal_Error, "failed to expire a stale review lease")
		}
	}
	fresh, fok, ferr2 := iface.taskchain_get_task(svc.repo, task.task_id)
	if !fok do return false, ferr2
	if fresh.state != .In_Review do return true, domain.Domain_Error{}
	if _, gok, gerr := evaluate_gate_in_uow(svc, u, chain, fresh, actor); !gok do return false, gerr
	return true, domain.Domain_Error{}
}
