package bridge

import "core:strconv"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Reconciliation changes only the plan flag, never credentials, status or sockets.
reconcile_plan_limits :: proc(service: ^Bridge_Service, user_id: string, max_bridges: int) -> domain.Domain_Error {
	if service == nil || service.repo == nil || service.repo.reconcile_plan == nil do return domain.domain_error(.Internal_Error, "bridge plan reconciliation is not configured")
	return service.repo.reconcile_plan(service.repo.ctx, domain.User_ID(user_id), max_bridges, platform.clock_now(service.clock), bridge_plan_before)
}

reconcile_owner_plan :: proc(service: ^Bridge_Service, user_id: string) -> domain.Domain_Error {
	if service.entitlements.lookup == nil do return {} // isolated services have no plan policy
	entitlements, err := domain.lookup_entitlements(service.entitlements, user_id)
	if err.code != .None do return err
	return reconcile_plan_limits(service, user_id, entitlements.max_bridges)
}

// Refresh entitlements before reading the flag: cache fills may re-enable a bridge.
// Called before runtime admission, so a refused hello cannot replace a live socket.
// Reuse the caller's authenticated row, but re-read the flag after cache refresh.
// Runtime connect repeats the gate after admission to cover an intervening downgrade.
check_bridge_plan :: proc(service: ^Bridge_Service, bridge: domain.Bridge) -> domain.Domain_Error {
	entitlements, lookup_err := domain.lookup_entitlements(service.entitlements, string(bridge.owner_user_id))
	if lookup_err.code != .None do return lookup_err
	current, current_ok, current_err := iface.bridge_get_bridge(service.repo, bridge.bridge_id)
	if !current_ok do return current_err
	defer domain.bridge_destroy(&current)
	if current.plan_disabled_at == "" do return {}
	count, count_err := iface.bridge_count_active_by_owner(service.repo, bridge.owner_user_id)
	if count_err.code != .None do return count_err
	return domain.plan_limit_error("max_bridges", entitlements.max_bridges, count, "Current")
}

bridge_plan_before :: proc(a, b: domain.Bridge) -> bool {
	// Keep retained bridges stable while suspended live sockets keep heartbeating.
	// Activity/version ordering only selects new suspensions or fills freed slots.
	if (a.plan_disabled_at == "") != (b.plan_disabled_at == "") do return a.plan_disabled_at == ""
	a_seen, a_valid := platform.parse_rfc3339_utc(a.last_seen_at)
	b_seen, b_valid := platform.parse_rfc3339_utc(b.last_seen_at)
	if a_valid != b_valid do return a_valid
	if a_valid && a_seen != b_seen do return time.to_unix_nanoseconds(a_seen) > time.to_unix_nanoseconds(b_seen)
	if cmp := bridge_plan_compare_version(a.version, b.version); cmp != 0 do return cmp > 0
	a_created, a_created_valid := platform.parse_rfc3339_utc(a.created_at)
	b_created, b_created_valid := platform.parse_rfc3339_utc(b.created_at)
	if a_created_valid != b_created_valid do return a_created_valid
	if a_created_valid && a_created != b_created do return time.to_unix_nanoseconds(a_created) > time.to_unix_nanoseconds(b_created)
	return a.bridge_id < b.bridge_id // total order for exact ties
}

// Numeric major/minor/patch, then SemVer prerelease precedence. Build metadata
// does not affect precedence; a release outranks the corresponding prerelease.
bridge_plan_compare_version :: proc(a, b: string) -> int {
	a_base, _, _ := strings.partition(strings.trim_space(a), "+")
	b_base, _, _ := strings.partition(strings.trim_space(b), "+")
	a_core, a_dash, a_pre := strings.partition(a_base, "-")
	b_core, b_dash, b_pre := strings.partition(b_base, "-")
	if core := compare_semver(a_core, b_core); core != 0 do return core
	if a_dash == "" && b_dash != "" do return 1
	if a_dash != "" && b_dash == "" do return -1
	a_parts := strings.split(a_pre, ".", context.temp_allocator)
	b_parts := strings.split(b_pre, ".", context.temp_allocator)
	for i := 0; i < min(len(a_parts), len(b_parts)); i += 1 {
		if a_parts[i] == b_parts[i] do continue
		a_num, a_numeric := strconv.parse_u64(a_parts[i])
		b_num, b_numeric := strconv.parse_u64(b_parts[i])
		if a_numeric && b_numeric { return 1 if a_num > b_num else -1 }
		if a_numeric != b_numeric do return -1 if a_numeric else 1
		return 1 if a_parts[i] > b_parts[i] else -1
	}
	if len(a_parts) == len(b_parts) do return 0
	return 1 if len(a_parts) > len(b_parts) else -1
}
