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

Gate_Result :: enum { Waiting, Approved, Changes_Requested }

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
	// 2. every required (agent, role) pair approved: named reviewers on the task
	//    and holders of each review role (review_pairs.odin).
	author_agent := ""
	if holder := last_attempt_holder(svc, task); holder != "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, holder); iok do author_agent = inst.agent_id
	}
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return .Waiting, false, ferr
	for pair in required_review_pairs(task, fleets, author_agent) {
		approved := false
		for r in reviews {
			if r.attempt_no == task.attempt_no && r.verdict == "approve" && r.reviewer_kind == "agent" && r.role == pair.role && r.reviewer_agent_id == pair.agent_id { approved = true; break }
		}
		if !approved {
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
	}
	// 3. require_independent_verify: requires a passing independent verify facet on this attempt
	if brief_require_independent_verify(task.brief_json) {
		vf, vok := get_facet(svc, task, task.attempt_no, FACET_VERIFY)
		ind_ok := false
		if vok {
			if code, cok := jsonx.extract_int_found(vf.body_json, "exit_code", true); cok && code == 0 {
				if ind, iok := jsonx.extract_bool_literal(vf.body_json, "independent", true); iok && ind {
					ind_ok = true
				}
			}
		}
		if !ind_ok {
			metric_gate_evaluated(.Waiting)
			return .Waiting, true, domain.Domain_Error{}
		}
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
