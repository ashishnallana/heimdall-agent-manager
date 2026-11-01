package taskv2

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Requirements use the existing append-only, owner-scoped event log. A change
// event is also the durable pending-delivery record: delivery is not read
// acknowledgement. Lease-scoped acknowledgement events retire that obligation.
// Legacy tasks have revision 1 without a migration or synthetic history.
EV_REQUIREMENTS_CHANGED :: "requirements_changed"
EV_REQUIREMENTS_ACKNOWLEDGED :: "requirements_acknowledged"

Requirements_State :: struct {
	revision: i64,
	event_id: i64,
	request_id: string,
}

requirements_state :: proc(events: []domain.Task_Event) -> Requirements_State {
	out := Requirements_State{revision = 1}
	for event in events {
		if event.kind != EV_REQUIREMENTS_CHANGED do continue
		revision := i64(jsonx.extract_int(event.payload_json, "revision", 0, true))
		if revision > out.revision {
			out = {revision = revision, event_id = event.event_id,
				   request_id = jsonx.extract_string(event.payload_json, "request_id", "", true, context.temp_allocator)}
		}
	}
	return out
}

requirements_read :: proc(repo: ^iface.Taskchain_Repository, task: domain.Task) -> (Requirements_State, domain.Domain_Error) {
	events, err := iface.taskchain_list_events_by_task(repo, task.task_id, task.owner_user_id)
	if err.code != .None do return {}, err
	return requirements_state(events), {}
}

// Only requirement fields belong in history. In production their values are
// already vault envelopes; never decrypt or copy other brief fields here.
requirements_snapshot :: proc(brief: string) -> string {
	out := json_begin()
	members := jsonx_top_level_members(brief)
	for key in ([]string{"goal", "acceptance"}) {
		raw, present := members[key]
		json_raw(&out, key, raw if present else "null")
	}
	return json_end(&out)
}

requirements_differ :: proc(before, after: string) -> bool {
	before_goal := jsonx.extract_string(before, "goal", "", true, context.temp_allocator)
	after_goal := jsonx.extract_string(after, "goal", "", true, context.temp_allocator)
	if before_goal != after_goal do return true
	a := jsonx.extract_string_array(before, "acceptance", true)
	b := jsonx.extract_string_array(after, "acceptance", true)
	if len(a) != len(b) do return true
	for value, i in a do if value != b[i] do return true
	return false
}

// Called inside the taskchain mutation's UOW, after validation and before the
// brief is saved. A failure rolls back the history, pending notice and brief.
requirements_record :: proc(repo: ^iface.Taskchain_Repository, clock: ^platform.Clock,
	before: domain.Task, after_brief: string, actor: Actor, expected: i64,
	reason, request_id: string) -> domain.Domain_Error {
	if expected < 0 || len(request_id) > 200 || len(reason) > 256 * 1024 {
		return domain.domain_error(.Validation_Failed, "invalid requirements revision, request id or change reason")
	}
	sealed_goal := jsonx.extract_string(before.brief_json, "goal", "", true, context.temp_allocator)
	if domain.is_vault_armored(sealed_goal) && reason != "" && !domain.is_vault_armored(reason) {
		return domain.domain_error(.Validation_Failed, "requirements change reason must be vault encrypted")
	}
	state, err := requirements_read(repo, before)
	if err.code != .None do return err
	if expected > 0 && expected != state.revision {
		return domain.domain_error(.Conflict, "requirements changed; reload the task before editing")
	}
	if !requirements_differ(before.brief_json, after_brief) do return {}
	if before.state == .Done || before.state == .Cancelled {
		return domain.domain_error(.Conflict, "reopen the task before changing requirements")
	}
	payload := json_begin()
	json_int(&payload, "revision", state.revision + 1)
	json_int(&payload, "previous_revision", state.revision)
	json_raw(&payload, "before", requirements_snapshot(before.brief_json))
	json_raw(&payload, "after", requirements_snapshot(after_brief))
	json_str(&payload, "reason", reason)
	json_str(&payload, "request_id", request_id)
	_, ok, append_err := append_event(repo, clock, before, actor, EV_REQUIREMENTS_CHANGED, json_end(&payload))
	if !ok do return append_err
	return {}
}
