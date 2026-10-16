package taskv2

import domain "odin_test:hub/domain"

// match_chain_in_uow is the pure matcher over (tasks, leases, fleets, instances,
// bridges) for one chain, invoked only from the trigger table (plan §2.4) and
// always inside the caller's unit of work. M0 lands the slot; M1 fills it.
match_chain_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, trigger: Trigger) -> (bool, domain.Domain_Error) {
	_ = svc; _ = u; _ = chain; _ = trigger
	return true, domain.Domain_Error{}
}
