package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// These are the canonical mixed-work orchestration operations. Transport and
// the run-scoped matcher will call this surface during the engine cutover.
// Every mutation checks authority and reads/writes the graph in the same UoW.
work_control_chain :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return {}, false, err
	if chain.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "chain not found")
	authorized := actor.kind == ACTOR_HUB
	if actor.kind == ACTOR_USER do authorized = actor.id == string(owner)
	if actor.kind == ACTOR_AGENT || actor.kind == ACTOR_COORDINATOR {
		authorized = is_coordinator(svc, chain, actor.id)
	}
	if !authorized do return {}, false, domain.domain_error(.Forbidden, "chain owner or coordinator required")
	if chain.status != .Active do return {}, false, domain.domain_error(.Conflict, "chain must be active")

	return chain, true, domain.Domain_Error{}
}

work_actor_kind :: proc(actor: Actor) -> string {
	if actor.kind == ACTOR_COORDINATOR do return ACTOR_AGENT
	return actor.kind
}

Work_Item_Snapshot :: struct {
	generation: int,
	succeeded:  bool,
	started:    bool,
	terminal:   bool,
	manifest:   string,
}

// Strict success is intentional: cancelled work and excluded work never
// produce a successful prerequisite. Missing/unknown endpoints fail closed.
work_item_snapshot :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, item: domain.Work_Item_Ref) -> (Work_Item_Snapshot, bool, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	if strings.trim_space(item.id) == "" do return {}, false, domain.domain_error(.Validation_Failed, "work item id required")
	switch item.kind {
	case domain.WORK_ITEM_TASK:
		task, ok, err := iface.taskchain_get_task(svc.repo, domain.Task_ID(item.id))
		if !ok do return {}, false, err
		if task.chain_id != chain_id || task.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "work item not found")
		if task.stage_key != "" || task.kind != .Task {
			return {}, false, domain.domain_error(.Validation_Failed, "external dependencies must address ordinary tickets or whole workflow runs", `{"code":"workflow_task_managed"}`)
		}
		manifest := json_begin()
		json_str(&manifest, "task_id", string(task.task_id))
		json_int(&manifest, "attempt_no", i64(task.attempt_no))
		json_str(&manifest, "output_ref", fmt.tprintf("facet:%s:%d:output", task.task_id, task.attempt_no))
		merge := task_merge_status(svc, task)
		return Work_Item_Snapshot{
			generation = task.attempt_no, succeeded = task.state == .Done && (merge.state == "none" || merge.state == "merged"),
			started = task.attempt_no > 0 || (task.state != .Backlog && task.state != .Ready),
			terminal = domain.task_state_is_terminal(task.state), manifest = json_end(&manifest),
		}, true, domain.Domain_Error{}
	case domain.WORK_ITEM_WORKFLOW_RUN:
		run, ok, err := iface.taskchain_get_workflow_run(svc.repo, domain.Workflow_Run_ID(item.id), owner)
		if !ok do return {}, false, err
		if run.chain_id != chain_id do return {}, false, domain.domain_error(.Not_Found, "work item not found")
		execution, eok, eerr := iface.taskchain_get_workflow_execution(svc.repo, run.run_id, run.current_execution_no, owner)
		if !eok do return {}, false, eerr
		return Work_Item_Snapshot{
			generation = execution.execution_no, succeeded = execution.state == domain.WORKFLOW_EXECUTION_SUCCEEDED,
			started = execution.started_at != "" || (execution.state != domain.WORKFLOW_EXECUTION_DRAFT && execution.state != domain.WORKFLOW_EXECUTION_PENDING),
			terminal = execution.state == domain.WORKFLOW_EXECUTION_SUCCEEDED || execution.state == domain.WORKFLOW_EXECUTION_FAILED || execution.state == domain.WORKFLOW_EXECUTION_CANCELLED,
			manifest = execution.output_manifest_json,
		}, true, domain.Domain_Error{}
	}
	return {}, false, domain.domain_error(.Validation_Failed, "work item kind must be task or workflow_run")
}

work_dependency_add :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, dependent, prerequisite: domain.Work_Item_Ref, reconcile := true) -> (domain.Work_Dependency, bool, domain.Domain_Error) {
	if svc.uow_factory == nil do return {}, false, domain.domain_error(.Internal_Error, "mixed work requires a unit of work")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	result, ok, err := work_dependency_add_in_uow(svc, &u, owner, actor, chain_id, dependent, prerequisite)
	if ok && reconcile do ok, err = after_chain_change(svc, &u, chain_id, owner, .Dep_Added)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return {}, false, err
	if cerr.code != .None do return {}, false, cerr
	return result, true, domain.Domain_Error{}
}

work_dependency_add_in_uow :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, dependent, prerequisite: domain.Work_Item_Ref) -> (domain.Work_Dependency, bool, domain.Domain_Error) {
	if _, ok, err := work_control_chain(svc, owner, actor, chain_id); !ok do return {}, false, err
	consumer, cok, cerr := work_item_snapshot(svc, chain_id, owner, dependent)
	if !cok do return {}, false, cerr
	if _, pok, perr := work_item_snapshot(svc, chain_id, owner, prerequisite); !pok do return {}, false, perr
	edges, err := iface.taskchain_list_work_dependencies(svc.repo, chain_id, owner)
	if err.code != .None do return {}, false, err
	for edge in edges {
		if edge.removed_at == "" && edge.dependent == dependent && edge.prerequisite == prerequisite {
			return edge, true, domain.Domain_Error{}
		}
	}
	if consumer.started do return {}, false, domain.domain_error(.Conflict, "cannot change the input contract of started work", `{"code":"work_already_started"}`)
	if dependent == prerequisite do return {}, false, domain.domain_error(.Validation_Failed, "work cannot depend on itself")
	result, saved, serr := iface.taskchain_insert_work_dependency(svc.repo, domain.Work_Dependency{
		dependency_id = platform.generate_id(svc.ids, "wdep_"), chain_id = chain_id, owner_user_id = owner,
		dependent = dependent, prerequisite = prerequisite, created_by_kind = work_actor_kind(actor),
		created_by_id = actor.id, created_at = platform.clock_now(svc.clock),
	})
	if saved {
		if ok, err := work_refold_dependent_in_uow(svc, u, chain_id, dependent, .Dep_Added); !ok do return {}, false, err
		effect_publish_chain(u, chain_id, owner, "work_dependency_added")
	}
	return result, saved, serr
}

work_dependency_remove :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, dependency_id, reason: string, reconcile := true) -> (bool, domain.Domain_Error) {
	if svc.uow_factory == nil do return false, domain.domain_error(.Internal_Error, "mixed work requires a unit of work")
	u, uok, uerr := begin_uow(svc)
	if !uok do return false, uerr
	ok, err := work_dependency_remove_in_uow(svc, &u, owner, actor, chain_id, dependency_id, reason)
	if ok && reconcile do ok, err = after_chain_change(svc, &u, chain_id, owner, .Dep_Removed)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return false, err
	if cerr.code != .None do return false, cerr
	return true, domain.Domain_Error{}
}

work_dependency_remove_in_uow :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, dependency_id, reason: string) -> (bool, domain.Domain_Error) {
	if _, ok, err := work_control_chain(svc, owner, actor, chain_id); !ok do return false, err
	if strings.trim_space(reason) == "" do return false, domain.domain_error(.Validation_Failed, "dependency removal reason required")
	edges, err := iface.taskchain_list_work_dependencies(svc.repo, chain_id, owner)
	if err.code != .None do return false, err
	for edge in edges {
		if edge.dependency_id != dependency_id do continue
		if edge.removed_at != "" do return true, domain.Domain_Error{}
		ok, rerr := iface.taskchain_remove_work_dependency(svc.repo, chain_id, owner, dependency_id, platform.clock_now(svc.clock), work_actor_kind(actor), actor.id, reason)
		if ok {
			if refolded, ferr := work_refold_dependent_in_uow(svc, u, chain_id, edge.dependent, .Dep_Removed); !refolded do return false, ferr
			effect_publish_chain(u, chain_id, owner, "work_dependency_removed")
		}
		return ok, rerr
	}
	return false, domain.domain_error(.Not_Found, "dependency not found")
}

work_refold_dependent_in_uow :: proc(svc: ^Service, u: ^Uow, chain_id: domain.Task_Chain_ID, item: domain.Work_Item_Ref, trigger: Trigger) -> (bool, domain.Domain_Error) {
	if item.kind != domain.WORK_ITEM_TASK do return true, domain.Domain_Error{}
	task, tok, terr := iface.taskchain_get_task(svc.repo, domain.Task_ID(item.id))
	if !tok do return false, terr
	if _, _, ok, err := refold_task(svc, u, task); !ok do return false, err
	return true, domain.Domain_Error{}
}

// Caller holds the UoW so readiness cannot race with a prerequisite retry.
work_dependencies_ready_in_uow :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, item: domain.Work_Item_Ref) -> (bool, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	if _, ok, err := work_item_snapshot(svc, chain_id, owner, item); !ok do return false, err
	edges, err := iface.taskchain_list_work_dependencies(svc.repo, chain_id, owner)
	if err.code != .None do return false, err
	for edge in edges {
		if edge.removed_at != "" || edge.dependent != item do continue
		provider, pok, perr := work_item_snapshot(svc, chain_id, owner, edge.prerequisite)
		if !pok do return false, perr
		if !provider.succeeded do return false, domain.Domain_Error{}
	}
	return true, domain.Domain_Error{}
}

// task_dependencies_ready is THE readiness predicate for an ordinary ticket,
// shared by the engine (refold_task) and the wire (`blocked`, REQ-TV2-3b):
// every legacy depends_on parent is Done and every active work-dependency edge
// is satisfied (prerequisite Done with merge none|merged, or a succeeded run).
// Read-only. Stage and gate tasks only use the legacy edges.
task_dependencies_ready :: proc(svc: ^Service, task: domain.Task, all_tasks: []domain.Task = nil, all_deps: []domain.Task_Dependency = nil) -> (bool, domain.Domain_Error) {
	tasks, deps := all_tasks, all_deps
	if tasks == nil {
		loaded, err := iface.taskchain_list_tasks_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if err.code != .None do return false, err
		tasks = loaded
	}
	if deps == nil {
		loaded, err := iface.taskchain_list_dependencies_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if err.code != .None do return false, err
		deps = loaded
	}
	if !deps_done_for(task.task_id, tasks, deps) do return false, domain.Domain_Error{}
	if task.stage_key != "" || task.kind != .Task do return true, domain.Domain_Error{}
	return work_dependencies_ready_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
}

// task_unblocks_dependents: whether this ticket satisfies a work-dependency
// edge on it — Done and its branch merged or never needing a merge. The wire's
// `unblocks_dependents` flag uses it so it agrees with the engine.
task_unblocks_dependents :: proc(svc: ^Service, task: domain.Task) -> bool {
	if task.state != .Done do return false
	merge := task_merge_status(svc, task)
	return merge.state == "none" || merge.state == "merged"
}

// Called after starting the consumer but before committing its lease/execution.
// The DB validates current generations, active edges and strict success again.
// If ANY receipt fails, the caller must roll back the whole start transaction.
work_capture_inputs_in_uow :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, item: domain.Work_Item_Ref) -> (bool, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	consumer, cok, cerr := work_item_snapshot(svc, chain_id, owner, item)
	if !cok do return false, cerr
	if !consumer.started || consumer.terminal do return false, domain.domain_error(.Conflict, "consumer must be starting")
	edges, err := iface.taskchain_list_work_dependencies(svc.repo, chain_id, owner)
	if err.code != .None do return false, err
	receipts, rerr := iface.taskchain_list_work_receipts_by_dependent(svc.repo, chain_id, owner, item)
	if rerr.code != .None do return false, rerr
	for edge in edges {
		if edge.removed_at != "" || edge.dependent != item do continue
		provider, pok, perr := work_item_snapshot(svc, chain_id, owner, edge.prerequisite)
		if !pok do return false, perr
		if !provider.succeeded do return false, domain.domain_error(.Conflict, "prerequisite has not succeeded", `{"code":"prerequisite_unsatisfied"}`)
		already_recorded := false
		for receipt in receipts {
			if receipt.dependent_generation != consumer.generation || receipt.prerequisite != edge.prerequisite do continue
			if receipt.prerequisite_generation != provider.generation || receipt.output_manifest_json != provider.manifest {
				return false, domain.domain_error(.Conflict, "consumed output changed")
			}
			already_recorded = true
			break
		}
		if already_recorded do continue
		_, saved, serr := iface.taskchain_insert_work_input_receipt(svc.repo, domain.Work_Input_Receipt{
			receipt_id = platform.generate_id(svc.ids, "winput_"), chain_id = chain_id, owner_user_id = owner,
			dependent = item, dependent_generation = consumer.generation, prerequisite = edge.prerequisite,
			prerequisite_generation = provider.generation, output_manifest_json = provider.manifest,
			created_at = platform.clock_now(svc.clock),
		})
		if !saved do return false, serr
	}
	return true, domain.Domain_Error{}
}

work_require_unconsumed_in_uow :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, item: domain.Work_Item_Ref) -> domain.Domain_Error {
	if _, ok, err := work_item_snapshot(svc, chain_id, owner, item); !ok do return err
	receipts, err := iface.taskchain_list_work_receipts_by_prerequisite(svc.repo, chain_id, owner, item)
	if err.code != .None do return err
	if len(receipts) == 0 do return domain.Domain_Error{}
	consumers := strings.builder_make(context.temp_allocator)
	strings.write_byte(&consumers, '[')
	for receipt, i in receipts {
		if i > 0 do strings.write_byte(&consumers, ',')
		entry := json_begin()
		json_str(&entry, "kind", receipt.dependent.kind)
		json_str(&entry, "id", receipt.dependent.id)
		json_int(&entry, "generation", i64(receipt.dependent_generation))
		json_int(&entry, "consumed_generation", i64(receipt.prerequisite_generation))
		strings.write_string(&consumers, json_end(&entry))
	}
	strings.write_byte(&consumers, ']')
	details := json_begin()
	json_str(&details, "code", "output_already_consumed")
	json_raw(&details, "consumers", strings.to_string(consumers))
	return domain.domain_error(.Conflict, "output already consumed; create replacement work", json_end(&details))
}

work_scope_decide :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, item: domain.Work_Item_Ref, action, reason: string) -> (domain.Work_Scope_Decision, bool, domain.Domain_Error) {
	if svc.uow_factory == nil do return {}, false, domain.domain_error(.Internal_Error, "mixed work requires a unit of work")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	result, ok, err := work_scope_decide_in_uow(svc, &u, owner, actor, chain_id, item, action, reason)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return {}, false, err
	if cerr.code != .None do return {}, false, cerr
	return result, true, domain.Domain_Error{}
}

work_scope_decide_in_uow :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, item: domain.Work_Item_Ref, action, reason: string) -> (domain.Work_Scope_Decision, bool, domain.Domain_Error) {
	if _, ok, err := work_control_chain(svc, owner, actor, chain_id); !ok do return {}, false, err
	snapshot, sok, serr := work_item_snapshot(svc, chain_id, owner, item)
	if !sok do return {}, false, serr
	if action != "include" && action != "exclude" do return {}, false, domain.domain_error(.Validation_Failed, "scope action must be include or exclude")
	if strings.trim_space(reason) == "" do return {}, false, domain.domain_error(.Validation_Failed, "scope reason required")
	if action == "exclude" && !snapshot.terminal do return {}, false, domain.domain_error(.Conflict, "cancel active work before excluding it")
	result, saved, err := iface.taskchain_append_work_scope_decision(svc.repo, domain.Work_Scope_Decision{
		chain_id = chain_id, owner_user_id = owner, item = item, action = action, reason = reason,
		actor_kind = work_actor_kind(actor), actor_id = actor.id, created_at = platform.clock_now(svc.clock),
	})
	if saved do effect_publish_chain(u, chain_id, owner, "work_scope_changed")
	return result, saved, err
}

work_chain_complete :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, expected_revision: i64, summary: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	u, ok, err := begin_uow(svc)
	if !ok do return {}, false, err
	chain, complete, cerr := work_chain_complete_in_uow(svc, &u, owner, actor, chain_id, expected_revision, summary)
	_, commit_err := end_uow(svc, &u, complete)
	if !complete do return {}, false, cerr
	if commit_err.code != .None do return {}, false, commit_err
	return chain, true, domain.Domain_Error{}
}

work_chain_complete_in_uow :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, actor: Actor, chain_id: domain.Task_Chain_ID, expected_revision: i64, summary: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := work_control_chain(svc, owner, actor, chain_id)
	if !ok do return {}, false, err
	if strings.trim_space(summary) == "" do return {}, false, domain.domain_error(.Validation_Failed, "final acceptance summary is required")
	if pending := strings.trim_space(chain_proposal_json(chain)); pending != "" && pending != "{}" && pending != "null" do return {}, false, domain.domain_error(.Conflict, "decide the pending proposal before finishing")
	if chain.work_revision != expected_revision do return {}, false, domain.domain_error(.Conflict, "work changed; refresh before finishing", `{"code":"work_changed"}`)
	scope, serr := iface.taskchain_list_work_scope_decisions(svc.repo, chain_id, owner)
	if serr.code != .None do return {}, false, serr
	excluded := make(map[domain.Work_Item_Ref]bool, context.temp_allocator)
	for decision in scope do excluded[decision.item] = decision.action == "exclude"
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain_id, owner)
	if terr.code != .None do return {}, false, terr
	// Every offending item is named with its state, merge state and failing
	// prerequisite, plus the recovery options (REQ-TV2-3c). No merge bypass.
	blockers := make([dynamic]string, context.temp_allocator)
	successes := 0
	for task in tasks {
		if task.workflow_run_id != "" do continue
		item := domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)}
		merge := task_merge_status(svc, task)
		if excluded[item] {
			if !domain.task_state_is_terminal(task.state) do append(&blockers, completion_blocker_json(item, domain.task_state_string(task.state), merge.state, "excluded_active", ""))
			continue
		}
		if task.state != .Done || task.publish_state != .Published {
			append(&blockers, completion_blocker_json(item, domain.task_state_string(task.state), merge.state, "not_done", ""))
			continue
		}
		if merge.state != "none" && merge.state != "merged" {
			append(&blockers, completion_blocker_json(item, domain.task_state_string(task.state), merge.state, "merge_unresolved", ""))
			continue
		}
		if ready, rerr := work_dependencies_ready_in_uow(svc, chain_id, owner, item); !ready || rerr.code != .None {
			append(&blockers, completion_blocker_json(item, domain.task_state_string(task.state), merge.state, "prerequisite_unsuccessful", first_unsatisfied_prerequisite(svc, chain_id, owner, item)))
			continue
		}
		successes += 1
	}
	runs, rerr := iface.taskchain_list_workflow_runs(svc.repo, chain_id, owner)
	if rerr.code != .None do return {}, false, rerr
	for run in runs {
		item := domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(run.run_id)}
		snapshot, sok, serr := work_item_snapshot(svc, chain_id, owner, item)
		if !sok do return {}, false, serr
		if excluded[item] {
			if !snapshot.terminal do append(&blockers, completion_blocker_json(item, run_state_label(snapshot), "", "excluded_active", ""))
			continue
		}
		if !snapshot.succeeded {
			append(&blockers, completion_blocker_json(item, run_state_label(snapshot), "", "not_succeeded", ""))
			continue
		}
		if ready, rerr := work_dependencies_ready_in_uow(svc, chain_id, owner, item); !ready || rerr.code != .None {
			append(&blockers, completion_blocker_json(item, run_state_label(snapshot), "", "prerequisite_unsuccessful", first_unsatisfied_prerequisite(svc, chain_id, owner, item)))
			continue
		}
		successes += 1
	}
	if len(blockers) > 0 {
		names := make([dynamic]string, context.temp_allocator)
		for b in blockers do append(&names, jsonx.extract_string(b, "id", "", true, context.temp_allocator))
		details := fmt.tprintf(`{"code":"chain_incomplete","items":[%s],"recovery":%s}`, strings.join(blockers[:], ",", context.temp_allocator), COMPLETION_RECOVERY_JSON)
		return {}, false, domain.domain_error(.Conflict, fmt.tprintf("chain cannot finish; unresolved work items: %s", strings.join(names[:], ", ", context.temp_allocator)), details)
	}
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain_id)
	if lerr.code != .None do return {}, false, lerr
	if len(leases) != 0 do return {}, false, domain.domain_error(.Conflict, "chain still has live leases")
	if completed, err := iface.taskchain_complete_work_chain(svc.repo, chain_id, owner, expected_revision, summary, platform.clock_now(svc.clock)); !completed do return {}, false, err
	fresh, _, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	effect_publish_chain(u, chain_id, owner, "completed")
	return fresh, true, domain.Domain_Error{}
}

// COMPLETION_RECOVERY_JSON: the supported ways out of a chain_incomplete error.
COMPLETION_RECOVERY_JSON :: `[{"action":"exclude","hint":"record a scope decision excluding the item (it must be terminal)"},{"action":"retry_merge","hint":"resolve the conflict in the task workdir and resubmit, or wait for the bridge to come online so the pending merge is requeued"},{"action":"settle_merge_none","hint":"a task that produced no branch (bridge VCS mode none) settles as merge none"}]`

completion_blocker_json :: proc(item: domain.Work_Item_Ref, state, merge_state, reason, prerequisite: string) -> string {
	p := json_begin()
	json_str(&p, "kind", item.kind)
	json_str(&p, "id", item.id)
	json_str(&p, "state", state)
	if merge_state != "" do json_str(&p, "merge", merge_state)
	json_str(&p, "reason", reason)
	if prerequisite != "" do json_str(&p, "prerequisite", prerequisite)
	return json_end(&p)
}

run_state_label :: proc(snapshot: Work_Item_Snapshot) -> string {
	if snapshot.succeeded do return "succeeded"
	if snapshot.terminal do return "terminal"
	if snapshot.started do return "running"
	return "pending"
}

// first_unsatisfied_prerequisite names the first active edge of `item` whose
// prerequisite has not succeeded ("" when none).
first_unsatisfied_prerequisite :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, item: domain.Work_Item_Ref) -> string {
	edges, err := iface.taskchain_list_work_dependencies(svc.repo, chain_id, owner)
	if err.code != .None do return ""
	for edge in edges {
		if edge.removed_at != "" || edge.dependent != item do continue
		provider, pok, _ := work_item_snapshot(svc, chain_id, owner, edge.prerequisite)
		if !pok || !provider.succeeded do return edge.prerequisite.id
	}
	return ""
}
