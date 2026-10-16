package taskv2

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// on_dep_added_in_uow: a dependency added to a LEASED task expires its work
// lease first (reason dep_added, non-counting). M1.
on_dep_added_in_uow :: proc(svc: ^Service, u: ^Uow, task: domain.Task, actor: Actor) -> (bool, domain.Domain_Error) {
	_ = svc; _ = u; _ = task; _ = actor
	return true, domain.Domain_Error{}
}

// on_instance_terminal is the ONE chokepoint for every instance-death path
// (runtime status terminal, reaper, bridge disconnect, delete, member removal):
// expire(instance_lost) → match_chain. M1.
on_instance_terminal :: proc(svc: ^Service, instance_id: string) {
	_ = svc; _ = instance_id
}

// chain_closed reclaims every lease of the chain (M1) and, when the chain was
// CANCELLED, cancels its open tasks so nothing stays ready/in_review on a dead
// chain. Completed/archived chains keep their task states.
chain_closed :: proc(svc: ^Service, chain: domain.Task_Chain, actor: Actor, cancel_tasks: bool) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	rok := true
	rerr := domain.Domain_Error{}
	if cancel_tasks {
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None {
			rok = false
			rerr = terr
		} else {
			for t in tasks {
				if domain.task_state_is_terminal(t.state) do continue
				payload := json_begin()
				json_str(&payload, "reason", EXPIRE_CHAIN_CLOSED)
				if _, _, eok, eerr := record_event(svc, &u, t, actor, EV_CANCELLED, json_end(&payload)); !eok {
					rok = false
					rerr = eerr
					break
				}
			}
		}
	}
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// cancel_task records `cancelled` for one task, reclaims its leases (M1) and
// re-plans the chain. Dependents are untouched.
cancel_task :: proc(svc: ^Service, task: domain.Task, actor: Actor, reason: string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "reason", reason if reason != "" else "cancelled")
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_CANCELLED, json_end(&payload))
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Cancelled)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}
