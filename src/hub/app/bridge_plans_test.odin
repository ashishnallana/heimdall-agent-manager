package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import billing_service "odin_test:hub/service/billing"
import bridge_service "odin_test:hub/service/bridge"

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
plan_sweep_test_plans :: proc(ctx: rawptr) -> ([]domain.Billing_Plan, domain.Domain_Error) {
	return {}, {}
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
	repo := iface.Billing_Repository{ctx = &state, get_account = plan_sweep_test_account, list_plans = plan_sweep_test_plans}
	graph: App_Graph
	graph.repos.bridges = {ctx = &state, list_owners = plan_sweep_test_owners, reconcile_plan = plan_sweep_test_reconcile}
	graph.bridges.repo = &graph.repos.bridges
	graph.billing.repo = &repo
	graph.billing.config.enforce_plan_limits = true
	defer billing_service.service_free(&graph.billing)
	// The sweep reconciles explicitly; entitlement lookups have no reconcile side effect.
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

// Regression: a taskv2 JIT launch runs the launch gate inside the main write UoW.
// With plan limits on and a cold entitlement cache, the gate must neither begin a
// transaction on another connection (busy_timeout stall) nor reconcile bridges.
@(test)
test_launch_gate_inside_write_uow_with_cold_entitlements_does_not_stall :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-launch-gate-uow-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)
	graph := new(App_Graph)
	defer free(graph)
	built, msg := build_graph(graph, Hub_Config{
		database_path = db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment = "sandbox",
		billing_enforce_plan_limits = true,
	})
	if !testing.expect(t, built, msg) do return
	defer shutdown_graph(graph)
	enrolled, enroll_ok, enroll_err := bridge_service.enroll_bridge_from_device_grant(&graph.bridges, {
		owner_user_id = "launch_owner", bridge_public_key = "04aabb",
	})
	if !testing.expect(t, enroll_ok, enroll_err.message) do return
	bridge := enrolled.bridge

	launch_in_write_uow :: proc(t: ^testing.T, graph: ^App_Graph, bridge: domain.Bridge) -> (domain.Domain_Error, time.Duration) {
		billing_service.invalidate_entitlements(&graph.billing) // expired cache
		uow, began, begin_err := iface.unit_of_work_begin(&graph.uow_factory)
		if !testing.expect(t, began, begin_err.message) do return begin_err, 0
		defer iface.unit_of_work_rollback(&uow)
		// Take the database write lock, as lease/submit and tasks/create have by then.
		testing.expect(t, sqlite.exec(&graph.db, "UPDATE bridges SET label = label;"))
		start := time.tick_now()
		err := agent_service.require_launch_bridge_enabled(&graph.agents, bridge)
		return err, time.tick_since(start)
	}

	err, elapsed := launch_in_write_uow(t, graph, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expectf(t, elapsed < time.Second, "enabled-bridge launch gate took %v inside a write UoW", elapsed)

	// A plan-suspended bridge is still refused, with real entitlement details.
	testing.expect(t, sqlite.exec(&graph.db, fmt.tprintf("UPDATE bridges SET plan_disabled_at = '2026-11-02T00:00:00Z' WHERE bridge_id = '%s';", bridge.bridge_id)))
	err, elapsed = launch_in_write_uow(t, graph, bridge)
	testing.expect_value(t, err.code, domain.Error_Code.Plan_Limit_Reached)
	testing.expect(t, strings.contains(err.details_json, `"current":1`), err.details_json)
	testing.expectf(t, elapsed < time.Second, "suspended-bridge launch gate took %v inside a write UoW", elapsed)
	stored, found, _ := iface.bridge_get_bridge(&graph.repos.bridges, bridge.bridge_id)
	if testing.expect(t, found) {
		defer domain.bridge_destroy(&stored)
		testing.expect(t, stored.plan_disabled_at != "", "the launch gate must not reconcile the suspension")
	}
}
