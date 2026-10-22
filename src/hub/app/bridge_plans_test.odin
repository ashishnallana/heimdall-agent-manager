package app

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import billing_service "odin_test:hub/service/billing"

@(private = "file")
Plan_Sweep_Test_State :: struct {
	lookups: int,
	reconciles: int,
}

@(private = "file")
plan_sweep_test_owners :: proc(ctx: rawptr) -> ([]string, domain.Domain_Error) {
	owners := make([]string, 2)
	owners[0] = strings.clone("bad_owner")
	owners[1] = strings.clone("healthy_owner")
	return owners, {}
}

@(private = "file")
plan_sweep_test_account :: proc(ctx: rawptr, user_id, now: string) -> (domain.Account_Billing, domain.Domain_Error) {
	state := (^Plan_Sweep_Test_State)(ctx)
	state.lookups += 1
	if user_id == "bad_owner" do return {}, domain.domain_error(.Internal_Error, "injected lookup failure")
	return {entitlements = {max_bridges = 1}}, {}
}

@(private = "file")
plan_sweep_test_reconcile :: proc(ctx: rawptr, owner: domain.User_ID, max_bridges: int, now: string, before: iface.Bridge_Plan_Rank_Proc) -> domain.Domain_Error {
	state := (^Plan_Sweep_Test_State)(ctx)
	state.reconciles += 1
	if owner == domain.User_ID("bad_owner") do return domain.domain_error(.Internal_Error, "injected reconcile failure")
	return {}
}

@(test)
test_plan_sweep_continues_after_owner_lookup_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	state: Plan_Sweep_Test_State
	repo := iface.Billing_Repository{ctx = &state, get_account = plan_sweep_test_account}
	graph: App_Graph
	graph.repos.bridges = {ctx = &state, list_owners = plan_sweep_test_owners, reconcile_plan = plan_sweep_test_reconcile}
	graph.bridges.repo = &graph.repos.bridges
	graph.billing.repo = &repo
	graph.billing.config.enforce_plan_limits = true
	graph.billing.plan_change_ctx = &graph
	graph.billing.on_entitlements = reconcile_bridge_entitlements
	defer billing_service.service_free(&graph.billing)
	err := reconcile_bridge_plans(&graph)
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	testing.expect(t, strings.contains(err.message, "1 owner(s)"))
	testing.expect_value(t, state.lookups, 2)
	testing.expect_value(t, state.reconciles, 1)
}

@(test)
test_plan_sweep_continues_after_owner_reconcile_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	state: Plan_Sweep_Test_State
	graph: App_Graph
	graph.repos.bridges = {ctx = &state, list_owners = plan_sweep_test_owners, reconcile_plan = plan_sweep_test_reconcile}
	graph.bridges.repo = &graph.repos.bridges
	graph.billing.config.enforce_plan_limits = false
	err := reconcile_bridge_plans(&graph)
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	testing.expect(t, strings.contains(err.message, "1 owner(s)"))
	testing.expect_value(t, state.reconciles, 2)
}
