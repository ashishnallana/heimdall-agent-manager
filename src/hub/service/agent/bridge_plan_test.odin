package agent

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Launch_Plan_Fixture :: struct {
	disabled: bool,
	upgrade: bool,
	lookup_failed: bool,
}

launch_plan_get_bridge :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	f := (^Launch_Plan_Fixture)(ctx)
	return domain.Bridge{
		bridge_id = strings.clone(id), owner_user_id = domain.User_ID(strings.clone("alice")),
		plan_disabled_at = strings.clone("2026-10-22T00:00:00Z" if f.disabled else ""),
	}, true, {}
}

launch_plan_count :: proc(ctx: rawptr, owner: domain.User_ID) -> (int, domain.Domain_Error) {
	return 2, {}
}

launch_plan_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	f := (^Launch_Plan_Fixture)(ctx)
	if f.lookup_failed do return {}, domain.domain_error(.Internal_Error, "test lookup failure")
	// Model the production entitlement callback, which reconciles before returning.
	if f.upgrade do f.disabled = false
	result := domain.unlimited_entitlements()
	result.max_bridges = 2 if f.upgrade else 1
	return result, {}
}

@(test)
test_plan_launch_gate_refresh_and_reconfiguration_details :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := Launch_Plan_Fixture{disabled = true}
	repo := iface.Bridge_Repository{ctx = &f, get_bridge = launch_plan_get_bridge, count_active_by_owner = launch_plan_count}
	service := Agent_Service{bridges = &repo, entitlements = {ctx = &f, lookup = launch_plan_lookup}}
	bridge := domain.Bridge{bridge_id = "disabled", owner_user_id = domain.User_ID("alice"), plan_disabled_at = "old"}
	refusal := require_launch_bridge_enabled(&service, bridge)
	testing.expect_value(t, refusal.code, domain.Error_Code.Plan_Limit_Reached)
	testing.expect(t, strings.contains(refusal.details_json, `"allowed":1`))
	testing.expect(t, strings.contains(refusal.details_json, `"current":2`))

	// The apply/recovery gate must use actual entitlements too, not synthetic 0/1 details.
	op := domain.Instance_Reconfiguration{owner_user_id = "alice", destination = {bridge_id = "disabled"}}
	valid, reconfiguration_err := reconfiguration_validate_live_destination(&service, op)
	testing.expect(t, !valid)
	testing.expect_value(t, reconfiguration_err.code, domain.Error_Code.Plan_Limit_Reached)
	testing.expect_value(t, reconfiguration_err.details_json, refusal.details_json)

	f.lookup_failed = true
	testing.expect_value(t, require_launch_bridge_enabled(&service, bridge).code, domain.Error_Code.Internal_Error)
	f.lookup_failed = false
	f.upgrade = true
	testing.expect(t, require_launch_bridge_enabled(&service, bridge).code == .None, "re-read the flag after an entitlement refresh")
}
