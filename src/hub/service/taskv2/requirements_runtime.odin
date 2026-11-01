package taskv2

import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

EV_REQUIREMENTS_PRESENTED :: "requirements_presented"
EV_REQUIREMENTS_REWORK :: "requirements_rework"
EV_REQUIREMENTS_NOTICE_ATTEMPTED :: "requirements_notice_attempted"
REQUIREMENTS_RETRY_SECONDS :: 60

Requirements_Submission :: struct {
	event_id: i64,
	revision: i64,
	attempt_no: int,
	head, snapshot: string,
}

requirements_submission :: proc(events: []domain.Task_Event, attempt: int) -> Requirements_Submission {
	out := Requirements_Submission{revision = 1, attempt_no = attempt}
	for event in events {
		if event.kind != EV_SUBMITTED || jsonx.extract_int(event.payload_json, "attempt_no", 0, true) != attempt do continue
		out.revision = i64(jsonx.extract_int(event.payload_json, "requirements_revision", 1, true))
		out.event_id = event.event_id
		out.head = jsonx.extract_string(event.payload_json, "head", "", true, context.temp_allocator)
		out.snapshot, _ = raw_object_field(event.payload_json, "requirements")
	}
	return out
}

requirements_lease_revision :: proc(events: []domain.Task_Event, lease_id, kind: string) -> i64 {
	for i := len(events) - 1; i >= 0; i -= 1 {
		event := events[i]
		if event.kind != kind || jsonx.extract_string(event.payload_json, "lease_id", "", true, context.temp_allocator) != lease_id do continue
		return i64(jsonx.extract_int(event.payload_json, "revision", 0, true))
	}
	return 0
}

requirements_stale_review :: proc(svc: ^Service, task: domain.Task) -> bool {
	if task.state != .In_Review do return false
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	// Fail closed: on read failure no new reviewer or approval may proceed.
	if err.code != .None do return true
	return requirements_submission(events, task.attempt_no).revision != requirements_state(events).revision
}

requirements_present :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease) -> domain.Domain_Error {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return err
	revision := requirements_state(events).revision
	if revision == 1 || requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_PRESENTED) == revision do return {}
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_int(&p, "revision", revision)
	_, ok, aerr := append_event(svc.repo, svc.clock, task, {kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_REQUIREMENTS_PRESENTED, json_end(&p))
	if !ok do return aerr
	return {}
}

// Explicit acknowledgement is carried by lease.heartbeat. It can acknowledge
// only a current revision previously fetched for this exact live lease.
requirements_ack_in_uow :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, revision: i64) -> domain.Domain_Error {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return err
	current := requirements_state(events).revision
	if revision != current || (current > 1 && requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_PRESENTED) != current) {
		return domain.domain_error(.Conflict, "reload the current task requirements before acknowledging")
	}
	if requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_ACKNOWLEDGED) == current do return {}
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_int(&p, "revision", current)
	_, ok, aerr := append_event(svc.repo, svc.clock, task, {kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_REQUIREMENTS_ACKNOWLEDGED, json_end(&p))
	if !ok do return aerr
	return {}
}

requirements_submit_guard :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, revision: i64) -> domain.Domain_Error {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return err
	current := requirements_state(events).revision
	if current == 1 && (revision == 0 || revision == 1) do return {} // no change to acknowledge
	if revision != current || requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_ACKNOWLEDGED) != current {
		return domain.domain_error(.Conflict, "requirements changed; fetch, read and acknowledge the latest revision before submitting")
	}
	return {}
}

requirements_review_guard :: proc(svc: ^Service, task: domain.Task, input: Review_Input) -> domain.Domain_Error {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return err
	current := requirements_state(events).revision
	submitted := requirements_submission(events, task.attempt_no)
	if current != submitted.revision do return domain.domain_error(.Conflict, "requirements changed after submission; worker rework is required")
	if current == 1 && input.requirements_revision == 0 do return {}
	if input.requirements_revision != current || input.expected_attempt_no != task.attempt_no || input.expected_head != submitted.head {
		return domain.domain_error(.Conflict, "review context is stale; reload the submitted attempt and requirements")
	}
	return {}
}

requirements_review_binding :: proc(svc: ^Service, task: domain.Task, payload: ^Json_Object) -> domain.Domain_Error {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return err
	submitted := requirements_submission(events, task.attempt_no)
	json_int(payload, "requirements_revision", submitted.revision)
	json_str(payload, "head", submitted.head)
	return {}
}

// Reconstruct pending notices from durable changes and acknowledgements. The
// timer is only a disposable index; boot and lease grants rebuild it.
requirements_reconcile_in_uow :: proc(svc: ^Service, u: ^Uow, task_in: domain.Task) -> (bool, domain.Domain_Error) {
	task := task_in
	if domain.task_state_is_terminal(task.state) do return true, {}
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return false, err
	state := requirements_state(events)
	if state.revision == 1 do return true, {}
	leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, task.task_id)
	if lerr.code != .None do return false, lerr
	stale_review := task.state == .In_Review && requirements_submission(events, task.attempt_no).revision != state.revision
	if stale_review && len(leases) == 0 {
		p := json_begin()
		json_int(&p, "revision", state.revision)
		json_int(&p, "attempt_no", i64(task.attempt_no))
		_, _, ok, rerr := record_event(svc, u, task, hub_actor(), EV_REQUIREMENTS_REWORK, json_end(&p))
		return ok, rerr
	}
	pending := false
	for lease in leases {
		// A reviewer must checkpoint even if it acknowledged the new brief;
		// that does not turn the old submission into compliant work.
		if !stale_review && requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_ACKNOWLEDGED) == state.revision do continue
		pending = true
		recent := false
		for i := len(events) - 1; i >= 0; i -= 1 {
			event := events[i]
			if event.kind != EV_REQUIREMENTS_NOTICE_ATTEMPTED || jsonx.extract_string(event.payload_json, "lease_id", "", true, context.temp_allocator) != lease.lease_id do continue
			now := now_ms(svc.clock)
			recent = i64(jsonx.extract_int(event.payload_json, "revision", 0, true)) == state.revision && now >= event.ts_ms && now - event.ts_ms < REQUIREMENTS_RETRY_SECONDS * 1000
			break
		}
		if recent do continue
		notice := json_begin()
		json_str(&notice, "lease_id", lease.lease_id)
		json_int(&notice, "revision", state.revision)
		if _, ok, nerr := append_event(svc.repo, svc.clock, task, hub_actor(), EV_REQUIREMENTS_NOTICE_ATTEMPTED, json_end(&notice)); !ok do return false, nerr
		line := fmt.tprintf("[taskv2] requirements changed: task %s revision %d. Run ham-ctl lease next, read TASK.md, then acknowledge revision %d before continuing.", task.task_id, state.revision, state.revision)
		if stale_review do line = fmt.tprintf("[taskv2] requirements changed during review: task %s revision %d. Run ham-ctl lease next; checkpoint review with ham-ctl lease handoff --summary <progress>. Do not post a verdict; worker rework is required.", task.task_id, state.revision)
		effect_nudge_instance(u, lease.holder_instance_id, lease.bridge_id, line)
	}
	if pending do timers_arm(svc, .Requirements_Notice, string(task.task_id), now_ms(svc.clock) + REQUIREMENTS_RETRY_SECONDS * 1000, "")
	return true, {}
}

requirements_pack_json :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease) -> string {
	events, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	p := json_begin()
	if err.code != .None { json_bool(&p, "unavailable", true); return json_end(&p) }
	state := requirements_state(events)
	submitted := requirements_submission(events, task.attempt_no)
	ack := requirements_lease_revision(events, lease.lease_id, EV_REQUIREMENTS_ACKNOWLEDGED)
	json_int(&p, "revision", state.revision)
	json_int(&p, "acknowledged_revision", ack)
	json_bool(&p, "acknowledgement_required", state.revision > 1 && ack != state.revision)
	json_int(&p, "submitted_revision", submitted.revision)
	json_int(&p, "submitted_attempt_no", i64(submitted.attempt_no))
	json_str(&p, "submitted_head", submitted.head)
	if submitted.event_id > 0 do json_str(&p, "submitted_fetch", fmt.tprintf("ham-ctl task fetch %s '#%d'", task.task_id, submitted.event_id))
	if submitted.snapshot != "" && len(submitted.snapshot) <= 2048 do json_raw(&p, "submitted_requirements", submitted.snapshot)
	json_bool(&p, "review_checkpoint_required", task.state == .In_Review && submitted.revision != state.revision)
	// Keep packs bounded. Full history remains available through task.fetch.
	for i := len(events) - 1; i >= 0; i -= 1 {
		if events[i].kind != EV_REQUIREMENTS_CHANGED do continue
		json_int(&p, "latest_change_event_id", events[i].event_id)
		if len(events[i].payload_json) <= 2048 do json_raw(&p, "latest_change", events[i].payload_json)
		json_str(&p, "change_fetch", fmt.tprintf("ham-ctl task fetch %s '#%d'", task.task_id, events[i].event_id))
		break
	}
	return json_end(&p)
}
