package billing

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

cache_test_clock :: proc(ctx: rawptr) -> string { return (^string)(ctx)^ }

@(test)
test_entitlements_cache_ttl_explicit_invalidation_and_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	now := "2026-10-10T10:00:00Z"
	clock = {ctx = &now, now = cache_test_clock}
	first, err := effective_entitlements(&service, "alice")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, first.max_bridges, 1)
	fixture.account.entitlements = domain.unlimited_entitlements()
	now = "2026-10-10T10:00:29Z"
	cached, _ := effective_entitlements(&service, "alice")
	testing.expect_value(t, cached.max_bridges, 1)
	testing.expect_value(t, fixture.get_calls, 1)
	now = "2026-10-10T10:00:30Z"
	refreshed, _ := effective_entitlements(&service, "alice")
	testing.expect(t, refreshed.shells_enabled)
	testing.expect_value(t, fixture.get_calls, 2)
	fixture.account.entitlements.shells_enabled = false
	invalidate_entitlements(&service, "alice")
	overridden, _ := effective_entitlements(&service, "alice")
	testing.expect(t, !overridden.shells_enabled)
	testing.expect_value(t, fixture.get_calls, 3)
	invalidate_entitlements(&service)
	fixture.get_error = domain.domain_error(.Internal_Error, "storage unavailable")
	_, failure := effective_entitlements(&service, "alice")
	testing.expect_value(t, failure.code, domain.Error_Code.Internal_Error)
	fixture.get_error = {}
	_, recovered := effective_entitlements(&service, "alice")
	testing.expect_value(t, recovered.code, domain.Error_Code.None)
	testing.expect_value(t, fixture.get_calls, 5)
}

@(test)
test_entitlements_cache_expires_at_grace_boundary_and_bounds_users :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	now := "2026-10-10T10:00:00Z"
	clock = {ctx = &now, now = cache_test_clock}
	fixture.account.status = "past_due"
	fixture.account.grace_until = "2026-10-10T10:00:10Z"
	fixture.account.entitlements = domain.unlimited_entitlements()
	_, _ = effective_entitlements(&service, "alice")
	now = "2026-10-10T10:00:09Z"
	_, _ = effective_entitlements(&service, "alice")
	testing.expect_value(t, fixture.get_calls, 1)
	fixture.account.entitlements.shells_enabled = false
	now = "2026-10-10T10:00:10Z"
	expired, _ := effective_entitlements(&service, "alice")
	testing.expect(t, !expired.shells_enabled)
	testing.expect_value(t, fixture.get_calls, 2)
	for i in 0..<ENTITLEMENTS_CACHE_CAPACITY+1 {
		fixture.account.user_id = fmt.tprintf("user_%d", i)
		_, _ = effective_entitlements(&service, fixture.account.user_id)
	}
	testing.expect(t, len(service.entitlements_cache) <= ENTITLEMENTS_CACHE_CAPACITY)
}

@(test)
test_entitlements_unconfigured_hubs_and_nil_seams_are_unlimited :: proc(t: ^testing.T) {
	service: Service
	got, err := effective_entitlements(&service, "alice")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, got, domain.unlimited_entitlements())
	from_nil, _ := domain.lookup_entitlements({}, "alice")
	testing.expect_value(t, from_nil, got)
	from_seam, _ := domain.lookup_entitlements(entitlement_lookup(&service), "alice")
	testing.expect_value(t, from_seam, got)
}

@(test)
test_entitlements_webhook_success_invalidates_cache_but_failure_preserves_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	_, _ = effective_entitlements(&service, "alice")
	testing.expect_value(t, len(service.entitlements_cache), 1)
	body := "{\"event_id\":\"evt_cache\",\"event_type\":\"subscription.activated\",\"occurred_at\":\"2026-10-10T10:00:00Z\",\"data\":{\"id\":\"sub_alice\",\"customer_id\":\"ctm_alice\",\"status\":\"active\",\"items\":[{\"price\":{\"id\":\"pri_approved\"}}]}}"
	fixture.apply_error = domain.domain_error(.Conflict, "retry")
	err := receive_webhook(&service, signature_for(body), body)
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect_value(t, len(service.entitlements_cache), 1)
	fixture.apply_error = {}
	err = receive_webhook(&service, signature_for(body), body)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(service.entitlements_cache), 0)
	fixture.account.entitlements.shells_enabled = true
	updated, _ := effective_entitlements(&service, "alice")
	testing.expect(t, updated.shells_enabled)
}

@(test)
test_account_view_serializes_new_entitlements_and_self_hosted_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	fixture.account.entitlements = {max_bridges = 1, terminal_streaming_enabled = true, max_concurrent_streams = 2}
	view, err := account_view(&service, "alice")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	encoded, marshal_err := json.marshal(view, allocator = context.temp_allocator)
	testing.expect(t, marshal_err == nil)
	decoded: struct {entitlements: domain.User_Entitlements}
	testing.expect(t, json.unmarshal(encoded, &decoded, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, decoded.entitlements, fixture.account.entitlements)
	service.config = {}
	unlimited, _ := account_view(&service, "alice")
	testing.expect_value(t, unlimited.entitlements, domain.unlimited_entitlements())
}

@(test)
test_entitlements_partial_paddle_config_and_explicit_enforcement_overrides :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	configs := []Config{
		{webhook_secret = "webhook_only"},
		{api_key = "api_only"},
		{client_token = "client_only"},
		{hobbyist_price_id = "price_only"},
		{enforce_plan_limits = true},
	}
	for config in configs {
		service.config = config
		limited, err := effective_entitlements(&service, "alice")
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, limited.max_bridges, 1)
		view, _ := account_view(&service, "alice")
		testing.expect_value(t, view.entitlements, limited)
		testing.expect(t, !view.checkout_enabled, "limits do not require checkout readiness")
	}
	service.config = {environment = "sandbox", past_due_grace_seconds = 86400}
	unconfigured, _ := effective_entitlements(&service, "alice")
	testing.expect_value(t, unconfigured, domain.unlimited_entitlements())
	service.config = {webhook_secret = "partial", enforce_plan_limits = false}
	opted_out, _ := effective_entitlements(&service, "alice")
	testing.expect_value(t, opted_out, domain.unlimited_entitlements())
	service.config = {environment = "live", api_key = "key", client_token = "token", webhook_secret = "secret", enforce_plan_limits = false}
	disabled, _ := effective_entitlements(&service, "alice")
	testing.expect_value(t, disabled, domain.unlimited_entitlements())
}


Reconcile_Test_State :: struct { calls: int, fail: bool }
reconcile_test_callback :: proc(ctx: rawptr, user_id: string, entitlements: domain.User_Entitlements) -> domain.Domain_Error {
	state := (^Reconcile_Test_State)(ctx)
	state.calls += 1
	if state.fail do return domain.domain_error(.Internal_Error, "reconciliation storage failure")
	return {}
}

@(test)
test_entitlements_reconciliation_failure_is_retried_before_caching :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	state := Reconcile_Test_State{fail = true}
	service.plan_change_ctx = &state
	service.on_entitlements = reconcile_test_callback
	_, failed := effective_entitlements(&service, "alice")
	testing.expect_value(t, failed.code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, len(service.entitlements_cache), 0)
	state.fail = false
	_, recovered := effective_entitlements(&service, "alice")
	testing.expect_value(t, recovered.code, domain.Error_Code.None)
	testing.expect_value(t, state.calls, 2)
	_, cached := effective_entitlements(&service, "alice")
	testing.expect_value(t, cached.code, domain.Error_Code.None)
	testing.expect_value(t, state.calls, 2)
	_, refreshed := account_view(&service, "alice")
	testing.expect_value(t, refreshed.code, domain.Error_Code.None)
	testing.expect_value(t, state.calls, 3)
}

@(test)
test_plan_limit_errors_use_cached_effective_label_and_survive_invalidation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	defer service_free(&service)
	source := entitlement_lookup(&service)
	now := "2026-10-10T10:00:00Z"
	clock = {ctx = &now, now = cache_test_clock}

	for status in ([?]string{"free", "active", "custom", "canceled", "past_due"}) {
		fixture.account.plan_label = "Hobbyist"
		fixture.account.status = status
		fixture.account.grace_until = "2026-10-10T10:00:10Z"
		invalidate_entitlements(&service, "alice")
		_, err := effective_entitlements(&service, "alice")
		testing.expect_value(t, err.code, domain.Error_Code.None)
		calls := fixture.get_calls
		failure := domain.entitlement_limit_error(source, "alice", "shells_enabled", 0, 1)
		details: struct {plan_label: string}
		testing.expect(t, json.unmarshal_string(failure.details_json, &details, .JSON, context.temp_allocator) == nil)
		expected := "Free" if status == "free" || status == "canceled" else "Hobbyist"
		testing.expect_value(t, details.plan_label, expected)
		testing.expect_value(t, fixture.get_calls, calls) // formatting hits the same cache
		invalidate_entitlements(&service, "alice")
		// The returned error is request-owned; invalidating its cache cannot free it.
		testing.expect_value(t, details.plan_label, expected)
	}
	fixture.account.status = "past_due"
	_, _ = effective_entitlements(&service, "alice")
	now = "2026-10-10T10:00:10Z"
	expired := domain.entitlement_limit_error(source, "alice", "shells_enabled", 0, 1)
	details: struct {plan_label: string}
	testing.expect(t, json.unmarshal_string(expired.details_json, &details, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, details.plan_label, "Free")

	fixture.account.status = "custom"
	fixture.account.plan_label = "Team agreement"
	fixture.account.entitlements.shells_enabled = false
	invalidate_entitlements(&service)
	custom := domain.entitlement_limit_error(source, "alice", "shells_enabled", 0, 1)
	testing.expect(t, json.unmarshal_string(custom.details_json, &details, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, details.plan_label, "Team agreement")
}
