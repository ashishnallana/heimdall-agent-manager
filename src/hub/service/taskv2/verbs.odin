package taskv2

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Agent verbs that land in M1: `lease.next` and `lease.heartbeat`. (submit /
// handoff / block / review.post / task.fetch are M2.) Each is one UoW.

Lease_Next_Input :: struct {
	// vcs_base: the bridge's .Local enrichment (git head at lease start). When
	// present and no attempt_started exists for the current attempt, it is recorded.
	vcs_base: string,
}

Lease_Next_Result :: struct {
	// status ∈ {granted, current, none}
	status:    string,
	lease:     domain.Task_Lease,
	task:      domain.Task,
	pack_json: string,
}

// lease_next (plan §2.5): idempotent. An instance holding a lease gets it back
// (and the call confirms a wake-delivered lease); a lease-free chain worker is
// granted inline (never woken); the coordinator gets `none`.
lease_next :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Lease_Next_Input) -> (Lease_Next_Result, bool, domain.Domain_Error) {
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	res := Lease_Next_Result{status = "none"}
	rok := true
	rerr := domain.Domain_Error{}
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held {
		if lease.confirmed_at == "" do _ = confirm_in_uow(svc, &u, lease)
		fresh, _, _ := iface.taskchain_get_lease(svc.repo, lease.lease_id)
		task, tok, terr := iface.taskchain_get_task(svc.repo, fresh.task_id)
		if !tok { rok = false; rerr = terr } else {
			record_attempt_started(svc, task, fresh, input.vcs_base)
			res = Lease_Next_Result{status = "current", lease = fresh, task = task}
		}
	} else if recently_expired(svc, inst.agent_instance_id, now_ms(svc.clock)) {
		// The caller's lease just expired: it is being stopped and will be
		// re-woken with a fresh pack. No inline grant for an orphan.
		_, _ = end_uow(svc, &u, false)
		return {}, false, lease_lost_error()
	} else if inst.chain_id != "" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id)); cok {
			if lease, task, granted := grant_inline_for_instance(svc, &u, chain, inst, .Lease_Next); granted {
				record_attempt_started(svc, task, lease, input.vcs_base)
				res = Lease_Next_Result{status = "granted", lease = lease, task = task}
			}
		}
	}
	if rok && res.status != "none" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, res.task.chain_id); cok {
			res.pack_json = build_pack_json(svc, chain, res.task, res.lease, inst)
		}
	}
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	return res, true, domain.Domain_Error{}
}

Lease_Heartbeat_Input :: struct {
	lease_id: string,
	note:     string,
}

// lease_heartbeat extends the TTL (never past the hard cap). 409 lease_lost when
// the caller holds nothing or names a lease it does not hold.
lease_heartbeat :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Lease_Heartbeat_Input) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
	if !held || (strings.trim_space(input.lease_id) != "" && input.lease_id != lease.lease_id) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, lease_lost_error()
	}
	saved, hok, herr := heartbeat_in_uow(svc, &u, lease, Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, input.note)
	_, cerr := end_uow(svc, &u, hok)
	if !hok do return {}, false, herr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

// ---- helpers ---------------------------------------------------------------------------

instance_from_auth :: proc(svc: ^Service, auth: contracts.Auth_Context) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, ok, err := iface.agent_get_instance(svc.agents, auth.agent_instance_id)
	if !ok do return {}, false, err
	if string(inst.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return inst, true, domain.Domain_Error{}
}

@(private = "file")
record_attempt_started :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, vcs_base: string) {
	if lease.kind != domain.LEASE_KIND_WORK do return
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return
	marker := fmt.tprintf(`"attempt_no":%d`, lease.attempt_no)
	for e in evs {
		if e.kind == EV_ATTEMPT_STARTED && strings.contains(e.payload_json, marker) do return
	}
	p := json_begin()
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "vcs_base", strings.trim_space(vcs_base))
	_, _, _ = append_event(svc.repo, svc.clock, task, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_ATTEMPT_STARTED, json_end(&p))
}

@(private = "file")
int_string :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, n)
	return strings.to_string(b)
}
