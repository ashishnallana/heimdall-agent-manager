package http

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// Only user-authenticated requests consume plan capabilities. Agent automation
// keeps its existing authorization rules, even when its owner has a free plan.
terminal_read_only :: proc(source: domain.Entitlement_Lookup, auth: contracts.Auth_Context) -> (bool, domain.Domain_Error) {
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy do return false, {}
	entitlements, err := domain.lookup_entitlements(source, auth.user_id)
	if err.code != .None do return false, err
	return !entitlements.terminal_input_enabled, {}
}

require_terminal_input :: proc(source: domain.Entitlement_Lookup, auth: contracts.Auth_Context) -> domain.Domain_Error {
	read_only, err := terminal_read_only(source, auth)
	if err.code != .None do return err
	// The lookup intentionally exposes capabilities rather than billing metadata;
	// use a neutral label so custom overrides are not misreported as the Free plan.
	if read_only do return domain.plan_limit_error("terminal_input_enabled", 0, 1, "Current")
	return {}
}
