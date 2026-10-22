package app

import domain "odin_test:hub/domain"
import billing_service "odin_test:hub/service/billing"
import bridge_service "odin_test:hub/service/bridge"

reconcile_bridge_entitlements :: proc(ctx: rawptr, user_id: string, entitlements: domain.User_Entitlements) -> domain.Domain_Error {
	graph := (^App_Graph)(ctx)
	return bridge_service.reconcile_plan_limits(&graph.bridges, user_id, entitlements.max_bridges)
}

// Startup follows migrations; webhook changes and the reaper use the same sweep.
// Cache fills reconcile configured accounts at most once per 30s; the reaper also
// observes raw SQL overrides and past_due grace expiry without a browser request.
reconcile_bridge_plans :: proc(ctx: rawptr) -> domain.Domain_Error {
	graph := (^App_Graph)(ctx)
	if graph.repos.bridges.list_owners == nil do return {}
	owners, err := graph.repos.bridges.list_owners(graph.repos.bridges.ctx)
	if err.code != .None do return err
	defer {
		for owner in owners do delete(owner)
		delete(owners)
	}
	for owner in owners {
		entitlements, lookup_err := billing_service.effective_entitlements(&graph.billing, owner)
		if lookup_err.code != .None do return lookup_err
		// Disabled enforcement is deliberately unlimited, including old suspensions.
		if !billing_service.plan_limits_enabled(graph.billing.config) {
			if reconcile_err := bridge_service.reconcile_plan_limits(&graph.bridges, owner, entitlements.max_bridges); reconcile_err.code != .None do return reconcile_err
		}
	}
	return {}
}
