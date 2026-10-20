package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// Dispatch is infrastructure failure, before work starts. Retain the attempt
// and runtime history for diagnosis, but refund its budget and park the task.
dispatch_failed_in_uow :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, failure: string) -> Expire_Result {
	detail := failure
	current, held, err := iface.taskchain_get_lease(svc.repo, lease.lease_id)
	if err.code != .None do return .Failed
	if !held || current.confirmed_at != "" || current.delivery != domain.LEASE_DELIVERY_WAKE do return .Gone
	// A failed wake of a handoff continuation did not create a new attempt.
	// Keep the earlier worker's budget charge and resume that same attempt.
	continuation := false
	if lease.kind == domain.LEASE_KIND_WORK {
		evs, eerr := iface.taskchain_list_events_by_task(svc.repo, lease.task_id, lease.owner_user_id)
		if eerr.code != .None do return .Failed
		for ev, i in evs {
			if ev.kind != EV_LEASE_GRANTED || jsonx.extract_string(ev.payload_json, "lease_id", "", true, context.temp_allocator) != lease.lease_id do continue
			pre := fold_task(evs[:i], Fold_Input{deps_done = true})
			continuation = pre.last_release == .Handoff
			break
		}
	}
	provider, model, bridge, agent_id := lease.provider, lease.model, lease.bridge_id, ""
	if inst, ok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); ok {
		agent_id = inst.agent_id
		if provider == "" do provider = inst.provider
		if model == "" && (lease.provider == "" || lease.provider == inst.provider) do model = inst.model
		if bridge == "" do bridge = inst.bridge_id
		if message := jsonx.extract_string(inst.last_error_json, "message", "", true, context.temp_allocator); message != "" {
			detail = fmt.tprintf("%s (%s)", message, inst.runtime_status)
		} else if inst.runtime_status == "failed" || inst.runtime_status == "stopped" || inst.runtime_status == "unreachable" {
			detail = fmt.tprintf("%s (%s)", detail, inst.runtime_status)
		}
	}
	if strings.trim_space(detail) == "" do detail = "launch failed before startup confirmation"
	waiting := json_begin()
	json_str(&waiting, "kind", "dispatch")
	json_str(&waiting, "agent_id", agent_id)
	json_str(&waiting, "reason", fmt.tprintf("%s/%s on %s failed to start: %s", provider, model, bridge, detail))
	json_int(&waiting, "since_ms", now_ms(svc.clock))
	p := json_begin()
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "kind", lease.kind)
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_bool(&p, "dispatch_failed", true)
	json_bool(&p, "continuation", continuation)
	json_raw(&p, "waiting_on", json_end(&waiting))
	if _, ok, _ := release_in_uow(svc, u, lease, hub_actor(), EV_BLOCKED, json_end(&p), "dispatch_failed"); !ok do return .Failed
	if lease.kind == domain.LEASE_KIND_WORK && !continuation {
		attempts, aerr := iface.taskchain_list_attempts_by_task(svc.repo, lease.task_id, lease.owner_user_id)
		if aerr.code != .None do return .Failed
		for a in attempts {
			if a.attempt_no != lease.attempt_no do continue
			refunded := a
			refunded.counts_toward_budget = false
			if _, ok, _ := iface.taskchain_save_attempt(svc.repo, refunded); !ok do return .Failed
		}
	}
	return .Expired
}

// Called after commit when the wake command could not even be sent. Re-read
// the lease inside the transaction: a racing start-success wins over failure.
on_dispatch_failed :: proc(svc: ^Service, lease_id, detail: string) {
	u, ok, _ := begin_uow(svc)
	if !ok do return
	lease, held, err := iface.taskchain_get_lease(svc.repo, lease_id)
	if err.code != .None || !held { _, _ = end_uow(svc, &u, false); return }
	result := dispatch_failed_in_uow(svc, &u, lease, detail)
	acted := result != .Failed
	if result == .Expired do acted, _ = after_chain_change(svc, &u, lease.chain_id, lease.owner_user_id, .Instance_Terminal)
	_, _ = end_uow(svc, &u, acted)
}
