package taskv2

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:slice"
import "core:strconv"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

Workflow_Run_Input :: struct {
	chain_id: string,
	ref: string,
	title: string,
	inputs_json: string,
	request_id: string,
	prerequisites: []domain.Work_Item_Ref,
}

workflow_context :: proc(svc: ^Service, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, execution_no := 0) -> (Workflow_Context, bool, domain.Domain_Error) {
	run, ok, err := iface.taskchain_get_workflow_run(svc.repo, run_id, owner)
	if !ok do return {}, false, err
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, run.chain_id)
	if !cok do return {}, false, cerr
	if chain.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "workflow run not found")
	no := execution_no
	if no == 0 do no = run.current_execution_no
	execution, eok, eerr := iface.taskchain_get_workflow_execution(svc.repo, run_id, no, owner)
	if !eok do return {}, false, eerr
	return Workflow_Context{chain = chain, run = run, execution = execution}, true, domain.Domain_Error{}
}

workflow_execution_tasks :: proc(svc: ^Service, wf: Workflow_Context) -> ([]domain.Task, domain.Domain_Error) {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, wf.chain_id, wf.owner_user_id)
	if err.code != .None do return nil, err
	out := make([dynamic]domain.Task, context.temp_allocator)
	for task in tasks {
		if task.workflow_run_id == wf.run.run_id && task.workflow_execution_no == wf.execution.execution_no do append(&out, task)
	}
	return out[:], domain.Domain_Error{}
}

workflow_event :: proc(svc: ^Service, u: ^Uow, wf: Workflow_Context, actor: Actor, kind: string, payload := "{}") -> domain.Domain_Error {
	_, ok, err := iface.taskchain_append_workflow_run_event(svc.repo, domain.Workflow_Run_Event{
		run_id = wf.run.run_id, execution_no = wf.execution.execution_no, chain_id = wf.chain_id, owner_user_id = wf.owner_user_id,
		ts_ms = now_ms(svc.clock), actor_kind = work_actor_kind(actor), actor_id = actor.id, kind = kind, payload_json = payload,
	})
	if !ok do return err
	effect_publish_chain(u, wf.chain_id, wf.owner_user_id, fmt.tprintf("workflow_%s", kind))
	return domain.Domain_Error{}
}

workflow_run :: proc(svc: ^Service, owner: domain.User_ID, actor: Actor, input: Workflow_Run_Input) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	u, ok, err := begin_uow(svc)
	if !ok do return {}, false, err
	run, rok, rerr := workflow_run_in_uow(svc, &u, owner, actor, input)
	if rok do rok, rerr = after_chain_change(svc, &u, run.chain_id, owner, .Task_Created)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	return run, true, domain.Domain_Error{}
}

workflow_run_in_uow :: proc(svc: ^Service, u: ^Uow, owner: domain.User_ID, actor: Actor, input: Workflow_Run_Input) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	chain, cok, cerr := work_control_chain(svc, owner, actor, domain.Task_Chain_ID(input.chain_id))
	if !cok do return {}, false, cerr
	if strings.trim_space(input.request_id) == "" do return {}, false, domain.domain_error(.Validation_Failed, "request_id is required")
    inputs := strings.trim_space(input.inputs_json)
    if inputs == "" do inputs = "{}"
    // parse_integers keeps `3` an integer, so snapshots and {{inputs.*}} /
    // {{item}} placeholders render "3", not a float.
    value, parse_err := json.parse(inputs, parse_integers = true, allocator = context.temp_allocator)
    if parse_err != nil do return {}, false, domain.domain_error(.Validation_Failed, "inputs must be a JSON object")
    if _, object := value.(json.Object); !object do return {}, false, domain.domain_error(.Validation_Failed, "inputs must be a JSON object")
    inputs = workflow_canonical_json(value)
	// Hash the REQUEST, not the resolved mutable latest definition. A retry of
	// the same creation request must return its original immutable snapshot.
	body := json_begin()
	json_str(&body, "ref", input.ref); json_str(&body, "title", input.title)
	json_str(&body, "inputs", inputs)
	prereqs := strings.builder_make(context.temp_allocator)
	for item in input.prerequisites { json_value := json_begin(); json_str(&json_value, "kind", item.kind); json_str(&json_value, "id", item.id); strings.write_string(&prereqs, json_end(&json_value)) }
	json_str(&body, "prerequisites", strings.to_string(prereqs))
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, json_end(&body), digest[:])
	encoded := hex.encode(digest[:], context.temp_allocator)
	request_hash := string(encoded)
	previous, exists, previous_err := iface.taskchain_get_workflow_run_by_request(svc.repo, chain.chain_id, owner, input.request_id)
	if exists {
		if previous.request_hash != request_hash do return {}, false, domain.domain_error(.Conflict, "request_id was already used with different inputs")
		return previous, true, domain.Domain_Error{}
	}
	if previous_err.code != .Not_Found do return {}, false, previous_err
	definition_ref, spec, found := resolve_workflow_ref(svc, owner, input.ref)
	if !found do return {}, false, domain.domain_error(.Not_Found, "workflow definition not found")
	parsed, pok, perr := parse_and_validate_workflow_spec(spec)
	if !pok do return {}, false, perr
	for stage in parsed.stages {
		if stage.kind != .Gate {
			if err := workflow_validate_fleet(svc, chain, stage.brief_raw); err.code != .None do return {}, false, err
		}
	}
	for field in parsed.inputs {
		val, supplied := extract_scalar_or_raw_string(inputs, field.name)
		if field.required && !field.has_default && (!supplied || strings.trim_space(val) == "") {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("missing required input: %s", field.name))
		}
	}
	if err := validate_workflow_run_inputs(parsed, inputs); err.code != .None do return {}, false, err
	now := platform.clock_now(svc.clock)
	run := domain.Workflow_Run{
		run_id = domain.Workflow_Run_ID(platform.generate_id(svc.ids, "wrun_")), chain_id = chain.chain_id, owner_user_id = owner,
		title = input.title if strings.trim_space(input.title) != "" else parsed.title, definition_ref = definition_ref,
		spec_json = parsed.normalized_json, inputs_json = inputs, current_execution_no = 1,
		request_id = input.request_id, request_hash = request_hash, created_by_kind = work_actor_kind(actor), created_by_id = actor.id,
		created_at = now, updated_at = now, revision = 1,
	}
	saved, sok, serr := iface.taskchain_insert_workflow_run(svc.repo, run)
	if !sok do return {}, false, serr
	execution, eok, eerr := iface.taskchain_insert_workflow_execution(svc.repo, domain.Workflow_Run_Execution{
		run_id = run.run_id, execution_no = 1, chain_id = chain.chain_id, owner_user_id = owner,
		state = "pending" if chain.publish_state == .Published else "draft", resolved_inputs_json = inputs, output_manifest_json = "{}", revision = 1,
	})
	if !eok do return {}, false, eerr
	wf := Workflow_Context{chain = chain, run = run, execution = execution}
	if err := workflow_event(svc, u, wf, actor, "created"); err.code != .None do return {}, false, err
	for prerequisite in input.prerequisites {
		if _, ok, err := work_dependency_add_in_uow(svc, u, owner, actor, chain.chain_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(run.run_id)}, prerequisite); !ok do return {}, false, err
	}
	return saved, true, domain.Domain_Error{}
}

workflow_set_state :: proc(svc: ^Service, u: ^Uow, wf: ^Workflow_Context, state: string, reason := "", manifest := "{}") -> domain.Domain_Error {
	execution := wf.execution
	execution.state = state
	execution.revision += 1
	if state == "running" do execution.started_at = platform.clock_now(svc.clock)
	if state == "succeeded" || state == "failed" || state == "cancelled" {
		execution.ended_at = platform.clock_now(svc.clock)
		execution.failure_code = reason
		execution.failure_detail = reason
		execution.output_manifest_json = manifest
	}
	saved, ok, err := iface.taskchain_update_workflow_execution(svc.repo, execution)
	if !ok do return err
	wf.execution = saved
	payload := json_begin(); json_str(&payload, "reason", reason)
	return workflow_event(svc, u, wf^, hub_actor(), state, json_end(&payload))
}

workflow_stop_tasks :: proc(svc: ^Service, u: ^Uow, wf: Workflow_Context, actor: Actor, reason: string) -> domain.Domain_Error {
	tasks, err := workflow_execution_tasks(svc, wf)
	if err.code != .None do return err
	for task in tasks {
		if domain.task_state_is_terminal(task.state) do continue
		leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
		if lerr.code != .None do return lerr
		for lease in leases {
			if expire_lease_in_uow(svc, u, lease, EXPIRE_CHAIN_CLOSED, actor) == .Failed do return domain.domain_error(.Internal_Error, "failed to reclaim workflow lease")
		}
		fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
		payload := json_begin(); json_str(&payload, "reason", reason)
		if _, _, ok, err := record_event(svc, u, fresh, actor, EV_CANCELLED, json_end(&payload)); !ok do return err
	}
	return domain.Domain_Error{}
}

// Reconciliation runs in the same UoW as task transitions and lease matching.
// A chain can contain many pending/running runs, all with independent stages.
workflow_reconcile_chain :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> (bool, bool, domain.Domain_Error) {
	if chain.status != .Active || chain.publish_state != .Published do return false, true, domain.Domain_Error{}
	runs, err := iface.taskchain_list_workflow_runs(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false, false, err
	changed := false
	for run in runs {
		wf, ok, err := workflow_context(svc, run.run_id, chain.owner_user_id)
		if !ok do return changed, false, err
		if wf.execution.state == "draft" {
			if err := workflow_set_state(svc, u, &wf, "pending"); err.code != .None do return changed, false, err
			changed = true
		}
		if wf.execution.state == "pending" {
			ready, rerr := work_dependencies_ready_in_uow(svc, chain.chain_id, chain.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(run.run_id)})
			if rerr.code != .None do return changed, false, rerr
			if !ready do continue
			if err := workflow_set_state(svc, u, &wf, "running"); err.code != .None do return changed, false, err
			if captured, cerr := work_capture_inputs_in_uow(svc, chain.chain_id, chain.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(run.run_id)}); !captured do return changed, false, cerr
			changed = true
		}
		if wf.execution.state != "running" do continue
        // Dynamic expansion can fail after a producer submits (for example a
        // now-missing fleet role). Roll back partial stage rows/effects without
        // losing the producer's successful submission or poisoning its lease.
        expansion_uow, began, begin_err := begin_uow(svc)
        if !began do return changed, false, begin_err
        materialized, mok, merr := materialize_ready_stages_in_uow(svc, &expansion_uow, wf)
        if !mok {
            _, _ = end_uow(svc, &expansion_uow, false)
            if merr.code != .Validation_Failed && merr.code != .Not_Found do return changed, false, merr
            if err := workflow_stop_tasks(svc, u, wf, hub_actor(), "expansion_failed"); err.code != .None do return changed, false, err
            if err := workflow_set_state(svc, u, &wf, "failed", merr.message); err.code != .None do return changed, false, err
            effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "workflow_failed", fmt.tprintf("[taskv2] run %s expansion failed: %s", run.run_id, merr.message))
            changed = true
            continue
        }
        if expansion_uow.has_tx {
            if committed, err := iface.unit_of_work_commit(&expansion_uow.tx); !committed {
                cancel_reservations(svc, &expansion_uow.effects)
                destroy_effects(&expansion_uow.effects)
                return changed, false, err
            }
        }
        move_effects(&u.effects, &expansion_uow.effects)
        changed = changed || materialized
		tasks, terr := workflow_execution_tasks(svc, wf)
		if terr.code != .None do return changed, false, terr
		snap, sok := extract_workflow_snapshot(wf)
		if !sok do return changed, false, domain.domain_error(.Internal_Error, "invalid stored workflow snapshot")
		all_done, failed := true, false
		outputs := json_begin()
		for stage in snap.spec.stages {
			view := fold_stage(svc, wf, stage.key, tasks, is_stage_marked_empty_done(svc, wf, stage.key))
			all_done = all_done && view.complete
			failed = failed || view.failed
			array := strings.builder_make(context.temp_allocator); strings.write_byte(&array, '[')
			for output, i in view.outputs { if i > 0 do strings.write_byte(&array, ','); strings.write_string(&array, output) }
			strings.write_byte(&array, ']'); json_raw(&outputs, stage.key, strings.to_string(array))
		}
		if failed {
			if err := workflow_stop_tasks(svc, u, wf, hub_actor(), "workflow_failed"); err.code != .None do return changed, false, err
			if err := workflow_set_state(svc, u, &wf, "failed", "stage_failed"); err.code != .None do return changed, false, err
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "workflow_failed", fmt.tprintf("[taskv2] run %s failed; inspect it and retry the run or create replacement work", run.run_id))
			changed = true
		} else if all_done {
			if err := workflow_set_state(svc, u, &wf, "succeeded", "", json_end(&outputs)); err.code != .None do return changed, false, err
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "workflow_complete", fmt.tprintf("[taskv2] run %s succeeded; assess the goal and add work or explicitly complete the chain", run.run_id))
			changed = true
		}
	}
	return changed, true, domain.Domain_Error{}
}

workflow_status_json :: proc(svc: ^Service, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, execution_no := 0) -> (string, bool, domain.Domain_Error) {
	wf, ok, err := workflow_context(svc, run_id, owner, execution_no)
	if !ok do return "", false, err
	return workflow_status_json_for_chain(svc, wf)
}

workflow_stage_output_json :: proc(svc: ^Service, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, stage_key: string, execution_no := 0) -> (string, bool, domain.Domain_Error) {
	wf, ok, err := workflow_context(svc, run_id, owner, execution_no)
	if !ok do return "", false, err
	return workflow_stage_output_json_for_chain(svc, wf, stage_key)
}

workflow_list_json :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> (string, bool, domain.Domain_Error) {
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok || chain.owner_user_id != owner do return "", false, domain.domain_error(.Not_Found, "chain not found")
	runs, err := iface.taskchain_list_workflow_runs(svc.repo, chain_id, owner)
	if err.code != .None do return "", false, err
	array := strings.builder_make(context.temp_allocator); strings.write_byte(&array, '[')
	for run, i in runs {
		if i > 0 do strings.write_byte(&array, ',')
		status, ok, err := workflow_status_json(svc, run.run_id, owner)
		if !ok do return "", false, err
		strings.write_string(&array, status)
	}
	strings.write_byte(&array, ']')
	o := json_begin(); json_raw(&o, "runs", strings.to_string(array)); json_int(&o, "work_revision", chain.work_revision)
	return json_end(&o), true, domain.Domain_Error{}
}

workflow_retry :: proc(svc: ^Service, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, actor: Actor, reason: string, expected_revision: i64) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	u, ok, err := begin_uow(svc)
	if !ok do return {}, false, err
	run, rok, rerr := workflow_retry_in_uow(svc, &u, run_id, owner, actor, reason, expected_revision)
	if rok do rok, rerr = after_chain_change(svc, &u, run.chain_id, owner, .Task_Reopened)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	return run, true, domain.Domain_Error{}
}

workflow_retry_in_uow :: proc(svc: ^Service, u: ^Uow, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, actor: Actor, reason: string, expected_revision: i64) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	wf, ok, err := workflow_context(svc, run_id, owner)
	if !ok do return {}, false, err
	if _, ok, err := work_control_chain(svc, owner, actor, wf.chain_id); !ok do return {}, false, err
	if wf.run.revision != expected_revision do return {}, false, domain.domain_error(.Conflict, "run changed; refresh before retrying")
	if strings.trim_space(reason) == "" do return {}, false, domain.domain_error(.Validation_Failed, "retry reason is required")
	if wf.execution.state != "failed" && wf.execution.state != "cancelled" && wf.execution.state != "succeeded" do return {}, false, domain.domain_error(.Conflict, "only a terminal run can be retried")
	if err := work_require_unconsumed_in_uow(svc, wf.chain_id, owner, domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(run_id)}); err.code != .None do return {}, false, err
	if err := workflow_require_merges_settled(svc, wf); err.code != .None do return {}, false, err
	run := wf.run
	run.current_execution_no += 1; run.revision += 1; run.updated_at = platform.clock_now(svc.clock)
	_, eok, eerr := iface.taskchain_insert_workflow_execution(svc.repo, domain.Workflow_Run_Execution{
		run_id = run_id, execution_no = run.current_execution_no, chain_id = wf.chain_id, owner_user_id = owner,
		state = "pending", resolved_inputs_json = run.inputs_json, output_manifest_json = "{}", revision = 1,
	})
	if !eok do return {}, false, eerr
	saved, sok, serr := iface.taskchain_update_workflow_run(svc.repo, run)
	if !sok do return {}, false, serr
	fresh, _, _ := workflow_context(svc, run_id, owner)
	payload := json_begin(); json_str(&payload, "reason", reason)
	if err := workflow_event(svc, u, fresh, actor, "retried", json_end(&payload)); err.code != .None do return {}, false, err
	return saved, true, domain.Domain_Error{}
}

workflow_cancel :: proc(svc: ^Service, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, actor: Actor, reason: string, execution_no: int) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	u, ok, err := begin_uow(svc)
	if !ok do return {}, false, err
	target, _, _ := iface.taskchain_get_workflow_execution(svc.repo, run_id, execution_no, owner)
	run, rok, rerr := workflow_cancel_in_uow(svc, &u, run_id, owner, actor, reason, execution_no)
	if rok && target.state != "cancelled" do rok, rerr = after_chain_change(svc, &u, run.chain_id, owner, .Task_Cancelled)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	return run, true, domain.Domain_Error{}
}

workflow_cancel_in_uow :: proc(svc: ^Service, u: ^Uow, run_id: domain.Workflow_Run_ID, owner: domain.User_ID, actor: Actor, reason: string, execution_no: int) -> (domain.Workflow_Run, bool, domain.Domain_Error) {
	wf, ok, err := workflow_context(svc, run_id, owner)
	if !ok do return {}, false, err
	if _, ok, err := work_control_chain(svc, owner, actor, wf.chain_id); !ok do return {}, false, err
    if execution_no <= 0 do return {}, false, domain.domain_error(.Validation_Failed, "execution_no is required")
    target, exists, target_err := iface.taskchain_get_workflow_execution(svc.repo, run_id, execution_no, owner)
    if !exists do return {}, false, target_err
    // Retransmitting a cancellation of an old cancelled execution is harmless.
    if target.state == "cancelled" do return wf.run, true, domain.Domain_Error{}
    if execution_no != wf.execution.execution_no do return {}, false, domain.domain_error(.Conflict, "execution changed; refresh before cancelling")
    if err := workflow_require_merges_settled(svc, wf); err.code != .None do return {}, false, err

	if wf.execution.state == "succeeded" || wf.execution.state == "failed" do return {}, false, domain.domain_error(.Conflict, "run is already terminal; exclude it from final scope if appropriate")
	if err := workflow_stop_tasks(svc, u, wf, actor, reason); err.code != .None do return {}, false, err
	if err := workflow_set_state(svc, u, &wf, "cancelled", reason); err.code != .None do return {}, false, err
	return wf.run, true, domain.Domain_Error{}
}

gate_replan_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, gate: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	if gate.workflow_run_id == "" do return true, domain.Domain_Error{}
	wf, ok, err := workflow_context(svc, gate.workflow_run_id, gate.owner_user_id)
	if !ok do return false, err
	if wf.execution.execution_no != gate.workflow_execution_no do return false, domain.domain_error(.Conflict, "gate belongs to a previous execution")
	if err := workflow_stop_tasks(svc, u, wf, actor, "gate_rejected"); err.code != .None do return false, err
	if err := workflow_set_state(svc, u, &wf, "failed", "gate_rejected"); err.code != .None do return false, err
	effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "gate_rejected", fmt.tprintf("[taskv2] run %s gate rejected; inspect feedback and retry the run explicitly", gate.workflow_run_id))
	return true, domain.Domain_Error{}
}

// An output trigger adds a sibling run under the SAME coordinator and chain.
// Creation idempotency is per source attempt; the event survives reconnects.
trigger_on_output_workflows_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, tasks: []domain.Task) -> (bool, domain.Domain_Error) {
	if chain.status != .Active do return true, domain.Domain_Error{}
	runs, err := iface.taskchain_list_workflow_runs(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false, err
	run_count := len(runs)
	for task in tasks {
		if task.state != .Done do continue
		if task.workflow_run_id != "" {
			run, ok, err := iface.taskchain_get_workflow_run(svc.repo, task.workflow_run_id, task.owner_user_id)
			if !ok do return false, err
			if task.workflow_execution_no != run.current_execution_no do continue
		}
		trigger, present := jsonx.extract_raw_object(task.brief_json, "on_output", true, context.temp_allocator)
		if !present do continue
		ref := jsonx.extract_string(trigger, "start_workflow", jsonx.extract_string(trigger, "workflow", "", true, context.temp_allocator), true, context.temp_allocator)
        if ref == "" do continue
        events, events_err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
        if events_err.code != .None do return false, events_err
        trigger_failed := false
        for event in events {
            if event.kind == "workflow_trigger_failed" && jsonx.extract_int(event.payload_json, "attempt_no", -1, true) == task.attempt_no do trigger_failed = true
        }
        if trigger_failed do continue
        request_id := fmt.tprintf("output:%s:%d", task.task_id, task.attempt_no)
		if _, found, _ := iface.taskchain_get_workflow_run_by_request(svc.repo, chain.chain_id, chain.owner_user_id, request_id); found do continue
		if run_count >= 128 {
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "workflow_budget", "[taskv2] automatic workflow run budget reached; continue with explicit work")
			continue
		}
		output := "{}"
		facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
		if ferr.code != .None do return false, ferr
		for facet in facets do if facet.kind == FACET_OUTPUT && facet.attempt_no == task.attempt_no do output = facet.body_json
		inputs, specified := jsonx.extract_raw_object(trigger, "inputs", true, context.temp_allocator)
		if !specified do inputs = output
		if strings.contains(inputs, "{{output") {
			resolved := json_begin()
			for key, raw in jsonx_top_level_members(inputs) {
				if strings.has_prefix(strings.trim_space(raw), `"`) {
					val := jsonx.extract_string(inputs, key, "", true, context.temp_allocator)
					json_str(&resolved, key, substitute_on_output_placeholders(val, output))
				} else do json_raw(&resolved, key, raw)
			}
			inputs = json_end(&resolved)
		}
		source := domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)}
        if task.workflow_run_id != "" do source = domain.Work_Item_Ref{kind = domain.WORK_ITEM_WORKFLOW_RUN, id = string(task.workflow_run_id)}
        child, began, begin_err := begin_uow(svc)
        if !began do return false, begin_err
        run, ok, err := workflow_run_in_uow(svc, &child, chain.owner_user_id, hub_actor(), Workflow_Run_Input{chain_id = string(chain.chain_id), ref = ref, inputs_json = inputs, request_id = request_id, prerequisites = []domain.Work_Item_Ref{source}})
        if !ok {
            _, _ = end_uow(svc, &child, false)
            if err.code != .Validation_Failed && err.code != .Not_Found do return false, err
            failure := json_begin(); json_int(&failure, "attempt_no", i64(task.attempt_no)); json_str(&failure, "ref", ref); json_str(&failure, "reason", err.message)
            if _, recorded, record_err := append_event(svc.repo, svc.clock, task, hub_actor(), "workflow_trigger_failed", json_end(&failure)); !recorded do return false, record_err
            effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "workflow_trigger_failed", fmt.tprintf("[taskv2] task %s finished, but follow-up workflow %s could not start: %s; configure it and create a run explicitly", task.task_id, ref, err.message))
            continue
        }
        if child.has_tx {
            if committed, err := iface.unit_of_work_commit(&child.tx); !committed {
                cancel_reservations(svc, &child.effects); destroy_effects(&child.effects)
                return false, err
            }
        }
        move_effects(&u.effects, &child.effects)
		run_count += 1
		payload := json_begin(); json_str(&payload, "run_id", string(run.run_id)); json_int(&payload, "attempt_no", i64(task.attempt_no))
		if _, ok, err := append_event(svc.repo, svc.clock, task, hub_actor(), EV_STARTED_WORKFLOW, json_end(&payload)); !ok do return false, err
	}
	return true, domain.Domain_Error{}
}

workflow_task_max_parallel :: proc(svc: ^Service, task: domain.Task) -> int {
	wf, ok, _ := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
	if !ok || wf.execution.execution_no != task.workflow_execution_no do return 0
	return workflow_stage_max_parallel(wf, task.stage_key)
}
workflow_proposal_run_in_uow :: proc(svc: ^Service, u: ^Uow, chain_in: domain.Task_Chain, actor: Actor, ref, inputs: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
 chain := chain_in
 chain.publish_state = .Published
 if chain.published_at == "" do chain.published_at = platform.clock_now(svc.clock)
 chain.defaults_json = set_chain_proposal_json(chain.defaults_json, "")
 chain.updated_at = platform.clock_now(svc.clock)
 if _, ok, err := iface.taskchain_save_chain(svc.repo, chain); !ok do return {}, false, err
 _, ok, err := workflow_run_in_uow(svc, u, chain.owner_user_id, actor, Workflow_Run_Input{
  chain_id = string(chain.chain_id), ref = ref, inputs_json = inputs, request_id = platform.generate_id(svc.ids, "proposal_"),
 })
 if !ok do return {}, false, err
 if ok, err := after_chain_change(svc, u, chain.chain_id, chain.owner_user_id, .Task_Created); !ok do return {}, false, err
 return iface.taskchain_get_chain(svc.repo, chain.chain_id)
}

// Every action on a generated task must address the current running execution.
// Historical task records remain readable, but cannot create new live work.
workflow_require_current_task :: proc(svc: ^Service, task: domain.Task) -> domain.Domain_Error {
 if task.workflow_run_id == "" do return domain.Domain_Error{}
 wf, ok, err := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
 if !ok do return err
 if wf.execution.execution_no != task.workflow_execution_no || wf.execution.state != "running" || wf.chain.status != .Active {
  return domain.domain_error(.Conflict, "workflow task belongs to an inactive execution; inspect history or retry the whole run", `{"code":"workflow_execution_inactive"}`)
 }
 return domain.Domain_Error{}
}

// Object order is not part of request identity. This also keeps nested input
// maps stable when an HTTP retry is marshalled by a different process.
workflow_canonical_json :: proc(value: json.Value) -> string {
 #partial switch v in value {
 case json.Object:
  keys := make([dynamic]string, context.temp_allocator)
  for key in v do append(&keys, key)
  slice.sort_by(keys[:], proc(a, b: string) -> bool { return a < b })
  out := json_begin()
  for key in keys do json_raw(&out, key, workflow_canonical_json(v[key]))
  return json_end(&out)
 case json.Array:
  out := strings.builder_make(context.temp_allocator); strings.write_byte(&out, '[')
  for item, i in v {
   if i > 0 do strings.write_byte(&out, ',')
   strings.write_string(&out, workflow_canonical_json(item))
  }
  strings.write_byte(&out, ']'); return strings.to_string(out)
 case json.Float:
  // Shortest round-trip form ("1.5", not "1.5000000000000000").
  buf := make([]byte, 64, context.temp_allocator)
  text := strconv.write_float(buf, f64(v), 'g', -1, 64)
  if strings.has_prefix(text, "+") do text = text[1:] // strconv always signs
  return strings.clone(text, context.temp_allocator)
 case:
  encoded, err := json.marshal(value, allocator = context.temp_allocator)
  if err != nil do return "null"
  return string(encoded)
 }
}

// Completion is durable before a merge job is queued; the outcome is durable
// only after its bridge reply. Refuse generation changes throughout that window,
// including offline/failed delivery. Recovery must settle it before retry.
workflow_require_merges_settled :: proc(svc: ^Service, wf: Workflow_Context) -> domain.Domain_Error {
 tasks, err := workflow_execution_tasks(svc, wf)
 if err.code != .None do return err
 for task in tasks {
  if task.state != .Done do continue
  events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
  if err.code != .None do return err
  status := task_merge_status(svc, task)
  if status.state != "none" && merge_pending(events) do return domain.domain_error(.Conflict, "workflow merges are unsettled; reconnect the bridge and settle merges before cancellation or retry", `{"code":"workflow_merge_pending"}`)
 }
 return domain.Domain_Error{}
}

// The chain-level cancel path uses the same fence before saving its status.
work_require_chain_merges_settled :: proc(svc: ^Service, chain: domain.Task_Chain) -> domain.Domain_Error {
 runs, err := iface.taskchain_list_workflow_runs(svc.repo, chain.chain_id, chain.owner_user_id)
 if err.code != .None do return err
 for run in runs {
  wf, ok, err := workflow_context(svc, run.run_id, chain.owner_user_id)
  if !ok do return err
  if err := workflow_require_merges_settled(svc, wf); err.code != .None do return err
 }
 return domain.Domain_Error{}
}
