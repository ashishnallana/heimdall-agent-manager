package taskv2

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// ---- task re-check (owner or coordinator) ----------------------------------------------
//
// task_recheck recomputes what the engine would have decided for one task had
// every trigger fired: the review gate against the CURRENT reviewers, review
// roles and user-approval flag; dependency readiness (refold + released task
// blocks); a bridge_offline agent block whose bridge is back; the matcher
// (dispatch); and a done task's pending or failed merge-back (never while a
// merge job for it is still running). It is the safe alternative to
// `task hold` + `task release`:
//
//   - it never approves: the gate only counts verdicts already posted;
//   - a task with a live lease (work or review) is left entirely to its holder;
//   - no attempt is created or charged except by a grant the matcher makes on
//     its normal path (a dispatch, exactly as any other trigger would);
//   - when the task ends up exactly as it was, the unit of work is rolled back,
//     so a repeat call records nothing and sends no notification.
//
// The result lists what changed and, for whatever still holds, why.

Recheck_Result :: struct {
	task:    domain.Task,
	changed: bool,
	// actions: what this re-check changed ("state: in_review → done", …).
	actions: []string,
	// reasons: why the task still is not moving (waiting reviewer, fleet full
	// 2/2, bridge offline, no git directory, …). Empty when nothing holds it.
	reasons: []string,
	message: string,
}

task_recheck :: proc(svc: ^Service, task_in: domain.Task, actor: Actor) -> (Recheck_Result, bool, domain.Domain_Error) {
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	res, ok, err := task_recheck_in_uow(svc, &u, task_in, actor)
	if !ok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, err
	}
	// A re-check that changed nothing leaves nothing behind: no event, no
	// notification (a waiting user-approval gate re-notifies on evaluation).
	if !res.changed {
		_, _ = end_uow(svc, &u, false)
		return res, true, domain.Domain_Error{}
	}
	committed, cerr := end_uow(svc, &u, true)
	if !committed {
		if cerr.code == .None do cerr = domain.domain_error(.Internal_Error, "re-check was not committed")
		return {}, false, cerr
	}
	if fresh, fok, _ := iface.taskchain_get_task(svc.repo, res.task.task_id); fok do res.task = fresh
	return res, true, domain.Domain_Error{}
}

// task_recheck_in_uow does the re-check inside `u`; the caller commits only
// when the result says it changed something, and rolls back otherwise.
task_recheck_in_uow :: proc(svc: ^Service, u: ^Uow, task_in: domain.Task, actor: Actor) -> (Recheck_Result, bool, domain.Domain_Error) {
	actions := make([dynamic]string, context.temp_allocator)
	reasons := make([dynamic]string, context.temp_allocator)
	chain, allowed, aerr := recheck_authorize(svc, task_in.owner_user_id, actor, task_in.chain_id)
	if !allowed do return {}, false, aerr
	task, found, terr := iface.taskchain_get_task(svc.repo, task_in.task_id)
	if !found || task.owner_user_id != task_in.owner_user_id {
		if terr.code == .None do terr = domain.domain_error(.Not_Found, "task not found")
		return {}, false, terr
	}
	before := task
	before_events := recheck_event_count(svc, task)
	before_leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None do return {}, false, lerr
	live := chain.status == .Active && chain.publish_state == .Published
	ok, err := true, domain.Domain_Error{}
	merge_requeued := ""

	switch {
	case task.publish_state != .Published:
		append(&reasons, "task is a draft; publish it first")
	case task.state == .Cancelled:
		append(&reasons, "task is cancelled")
	case len(before_leases) > 0:
		// Leave a leased task to its holder: no gate, no matcher, no merge.
		for l in before_leases {
			append(&reasons, fmt.tprintf("%s lease %s is live (holder %s, attempt #%d); re-check leaves it to the holder", l.kind, l.lease_id, l.holder_instance_id, l.attempt_no))
		}
	case task_is_held(task):
		hold, _ := task_hold_object(task.blocked_on_json)
		append(&reasons, fmt.tprintf("task is held (%s); release it with `task release`", jsonx.extract_string(hold, "reason", "no reason given", true, context.temp_allocator)))
	case:
		if live {
			// 1. The gate against the current review requirements.
			if task.state == .In_Review {
				gate, gok, gerr := evaluate_gate_in_uow(svc, u, chain, task, actor)
				if gok && gate == .Rejected do gok, gerr = gate_replan_in_uow(svc, u, chain, task, actor)
				ok, err = gok, gerr
			}
			// 2. An agent block raised only because the bridge was away (the
			//    bridge hello path, when that hello was missed or raced).
			if ok && is_agent_not_running_block(task.blocked_on_json) && jsonx.extract_string(task.blocked_on_json, "cause", "", true, context.temp_allocator) == "bridge_offline" {
				if bridge := jsonx.extract_string(task.blocked_on_json, "bridge_id", "", true, context.temp_allocator); bridge_online(svc, bridge) {
					if fresh, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do task = fresh
					p := json_begin()
					json_bool(&p, "auto", true)
					json_str(&p, "reason", "recheck_bridge_online")
					json_str(&p, "note", fmt.tprintf("bridge %s is online again", bridge))
					_, _, ok, err = record_event(svc, u, task, actor, EV_ANSWERED, json_end(&p))
				}
			}
			// 3. Readiness, task blocks and dispatch: the shared trigger path.
			if ok do ok, err = after_chain_change(svc, u, chain.chain_id, chain.owner_user_id, .Task_Updated)
		}
		// 4. Merge-back of a task that was ALREADY done (the chain may be
		//    completed). A task this re-check just moved to done had its
		//    merge queued by that transition; queuing it again would race it.
		if ok && before.state == .Done {
			if fresh, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do task = fresh
			merge_requeued = recheck_merge_in_uow(svc, u, task)
		}
	}
	if !ok do return {}, false, err

	after, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	after_leases, _ := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	changed := merge_requeued != "" || recheck_event_count(svc, after) != before_events || len(after_leases) != len(before_leases) ||
		after.state != before.state || after.blocked_on_json != before.blocked_on_json || after.attempt_no != before.attempt_no
	if after.state != before.state {
		append(&actions, fmt.tprintf("state: %s → %s", domain.task_state_string(before.state), domain.task_state_string(after.state)))
	}
	// A hold rides along as a member; only the underlying block counts here.
	if b0, b1 := strings.trim_space(blocked_on_without_hold(before.blocked_on_json)), strings.trim_space(blocked_on_without_hold(after.blocked_on_json)); b0 != b1 {
		if b0 != "" do append(&actions, fmt.tprintf("block cleared: %s", describe_block(b0)))
		if b1 != "" do append(&actions, fmt.tprintf("blocked: %s", describe_block(b1)))
	}
	if len(after_leases) > len(before_leases) {
		for l in after_leases {
			append(&actions, fmt.tprintf("dispatched: %s lease %s to %s on bridge %s (attempt #%d)", l.kind, l.lease_id, l.holder_instance_id, l.bridge_id, l.attempt_no))
		}
	}
	if merge_requeued != "" do append(&actions, merge_requeued)
	if changed && len(actions) == 0 do append(&actions, "task events were re-evaluated")

	// Whatever still holds the task, described against its state after this re-check.
	if len(reasons) == 0 do recheck_reasons(svc, chain, after, &reasons)

	msg := ""
	if changed {
		msg = strings.join(actions[:], "; ", context.temp_allocator)
	} else if len(reasons) > 0 {
		msg = fmt.tprintf("nothing to change: %s", reasons[0])
	} else {
		msg = "nothing to change"
	}
	return Recheck_Result{task = after, changed = changed, actions = actions[:], reasons = reasons[:], message = msg}, true, domain.Domain_Error{}
}

// recheck_authorize: chain owner or its coordinator, like hold/release, but a
// completed chain is allowed too (its done tasks may still owe a merge-back).
@(private = "file")
recheck_authorize :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return {}, false, err
	if chain.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "chain not found")
	authorized := actor.kind == ACTOR_HUB
	if actor.kind == ACTOR_USER do authorized = actor.id == string(owner)
	if actor.kind == ACTOR_AGENT || actor.kind == ACTOR_COORDINATOR do authorized = is_coordinator(svc, chain, actor.id)
	if !authorized do return {}, false, domain.domain_error(.Forbidden, "chain owner or coordinator required")
	return chain, true, domain.Domain_Error{}
}

@(private = "file")
recheck_event_count :: proc(svc: ^Service, task: domain.Task) -> int {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return -1
	return len(evs)
}

// recheck_merge_in_uow re-queues the merge-back of a done task whose merge is
// pending or failed when the bridge that ran its work is online and no job for
// it is still running. Returns the action text, or "" when nothing was queued
// (recheck_reasons explains why).
@(private = "file")
recheck_merge_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task) -> string {
	if task.state != .Done || merge_inflight(svc, string(task.task_id)) do return ""
	st := task_merge_status(svc, task)
	if st.state != "pending" && st.state != "failed" do return ""
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return ""
	bridge := last_work_bridge(evs)
	if bridge == "" || !bridge_online(svc, bridge) do return ""
	queued := len(u.effects.merges)
	effect_merge_worktree(svc, u, task, evs)
	if len(u.effects.merges) == queued do return ""
	return fmt.tprintf("merge-back re-queued on bridge %s (was %s)", bridge, st.state)
}

@(private = "file")
last_work_bridge :: proc(evs: []domain.Task_Event) -> string {
	for i := len(evs) - 1; i >= 0; i -= 1 {
		ev := evs[i]
		if ev.kind != EV_LEASE_GRANTED do continue
		if jsonx.extract_string(ev.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator) != domain.LEASE_KIND_WORK do continue
		return jsonx.extract_string(ev.payload_json, "bridge_id", "", true, context.temp_allocator)
	}
	return ""
}

// describe_block renders a blocked_on object as one line.
describe_block :: proc(raw: string) -> string {
	inner := blocked_on_without_hold(raw)
	if strings.trim_space(inner) == "" do inner = raw
	if reason := jsonx.extract_string(inner, "reason", "", true, context.temp_allocator); reason != "" {
		kind := jsonx.extract_string(inner, "kind", "", true, context.temp_allocator)
		if kind != "" && kind != reason && !strings.contains(reason, " ") do return fmt.tprintf("%s (%s)", reason, kind)
		return reason
	}
	if kind := jsonx.extract_string(inner, "kind", "", true, context.temp_allocator); kind != "" {
		if ref := jsonx.extract_string(inner, "ref", "", true, context.temp_allocator); ref != "" do return fmt.tprintf("%s %s", kind, ref)
		return kind
	}
	return "blocked"
}

// recheck_reasons explains, per state, what the task is still waiting on.
@(private = "file")
recheck_reasons :: proc(svc: ^Service, chain: domain.Task_Chain, task: domain.Task, out: ^[dynamic]string) {
	if leases, err := iface.taskchain_list_leases_by_task(svc.repo, task.task_id); err.code == .None {
		for l in leases do append(out, fmt.tprintf("%s lease %s is live (holder %s, attempt #%d)", l.kind, l.lease_id, l.holder_instance_id, l.attempt_no))
		if len(leases) > 0 && task.state == .In_Progress do return
	}
	if chain.status != .Active && task.state != .Done {
		append(out, fmt.tprintf("chain is %v; only merge-back is re-checked", chain.status))
		return
	}
	if strings.trim_space(task.blocked_on_json) != "" && !domain.task_state_is_terminal(task.state) {
		append(out, fmt.tprintf("blocked: %s", describe_block(task.blocked_on_json)))
	}
	switch task.state {
	case .Backlog:
		if ready, rerr := task_dependencies_ready(svc, task); rerr.code == .None && !ready {
			raw, _ := task_readiness_json(svc, task)
			parsed, perr := json.parse_string(raw, allocator = context.temp_allocator)
			root, _ := parsed.(json.Object)
			edges, _ := root["edges"].(json.Array)
			for e in edges {
				edge, _ := e.(json.Object)
				if satisfied, _ := edge["satisfied"].(json.Boolean); perr != nil || satisfied do continue
				id, _ := edge["id"].(json.String)
				state, _ := edge["state"].(json.String)
				merge, _ := edge["merge"].(json.String)
				line := fmt.tprintf("waiting on prerequisite %s (%s", id, state)
				if merge != "" && merge != "none" do line = fmt.tprintf("%s, merge %s", line, merge)
				append(out, fmt.tprintf("%s)", line))
			}
		}
	case .Ready:
		for r in dispatch_blockers(svc, chain, task) do append(out, r)
	case .In_Review:
		unmet, _ := gate_unmet_components(svc, task)
		for m in unmet {
			if m.kind == "review" {
				append(out, fmt.tprintf("waiting on review from %s (role %s)", m.agent_id, m.role))
			} else {
				append(out, fmt.tprintf("waiting on %s approval", m.role if m.role != "" else "user"))
			}
		}
	case .In_Progress:
	case .Done:
		recheck_merge_reasons(svc, task, out)
	case .Cancelled:
	}
}

@(private = "file")
recheck_merge_reasons :: proc(svc: ^Service, task: domain.Task, out: ^[dynamic]string) {
	st := task_merge_status(svc, task)
	evs, _ := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	switch st.state {
	case "merged":
	case "conflict":
		append(out, fmt.tprintf("merge conflict (%s): resolve it in the task workdir and resubmit", st.detail))
	case "pending", "failed":
		bridge := last_work_bridge(evs)
		if merge_inflight(svc, string(task.task_id)) {
			append(out, fmt.tprintf("merge %s: the merge-back is in flight on bridge %s; its outcome lands on the timeline", st.state, bridge))
		} else if bridge == "" {
			append(out, fmt.tprintf("merge %s: no work lease recorded a bridge", st.state))
		} else if !bridge_online(svc, bridge) {
			append(out, fmt.tprintf("merge %s: bridge %s is offline; it is re-queued when the bridge reconnects", st.state, bridge))
		} else if st.state == "failed" && st.detail != "" {
			append(out, fmt.tprintf("last merge attempt failed: %s", first_line_trimmed(st.detail)))
		}
	case "none":
		if !task_ran_work(evs) do return
		dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if derr.code != .None do return
		if len(dirs) == 0 {
			append(out, "merge none: the chain has no directory, so the branch is never merged")
			return
		}
		for d in dirs {
			if d.vcs_kind == "git" {
				append(out, "merge none: no git directory was attached when the task finished, so its branch is never merged automatically")
				return
			}
		}
		for d in dirs {
			append(out, fmt.tprintf("merge none: chain directory %s has vcs_kind %q (not git), so the branch is never merged", d.directory_id, d.vcs_kind))
		}
	}
}
