package http

import "core:testing"
import contracts "odin_test:contracts"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"

// heimdall_auth_failures_total{kind}, heimdall_device_auth_total{step,result},
// heimdall_rate_limited_total{endpoint}.

@(private = "file")
auth_req :: proc(headers: []contracts.HTTP_Header, body := "", query := "") -> Request {
	return Request{method = "POST", path = "/api/v1/x", headers = headers, body = body, query = query}
}

@(private = "file")
hdr :: proc(name, value: string) -> contracts.HTTP_Header {
	return contracts.HTTP_Header{name = name, value = value}
}

@(test)
test_auth_failure_kind_classification :: proc(t: ^testing.T) {
	auth := auth_service.Auth_Service{config = {username_header = "X-Authentik-Username"}}
	testing.expect_value(t, auth_failure_kind(&auth, auth_req(nil)), "missing")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hut_abc")})), "user_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hbr_abc")})), "bridge_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hba_abc")})), "bridge_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hbf_abc")})), "bridge_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hba_abc"), hdr("X-Heimdall-Instance-Token", "hit_xyz")})), "instance_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer hba_abc")}, `{"agent_instance_id":"ai_1"}`)), "instance_token")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("Authorization", "Bearer something-else")})), "other")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req({hdr("X-Authentik-Username", "alice")})), "trusted_proxy")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req(nil), proxy_only = true), "trusted_proxy")
	testing.expect_value(t, auth_failure_kind(&auth, auth_req(nil, "", "token=abc")), "other")
	testing.expect_value(t, auth_failure_kind(nil, auth_req(nil)), "missing")
}

@(test)
test_auth_middleware_counts_failures :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // respond_error bodies live on the request arena
	auth_metrics_init(metrics.init_global())
	// An unconfigured Auth_Service refuses everything, which is all this needs.
	auth := auth_service.Auth_Service{}
	count := proc(kind: string) -> u64 { return metrics.counter_value(metrics.with(auth_metrics.auth_failures, kind)) }

	missing_before := count("missing")
	user_before := count("user_token")
	proxy_before := count("trusted_proxy")
	bridge_before := count("bridge_token")

	_, ok1, _ := require_auth(&auth, auth_req(nil))
	testing.expect(t, !ok1, "refused")
	_, ok2, _ := require_auth(&auth, auth_req({hdr("Authorization", "Bearer hut_abc")}))
	testing.expect(t, !ok2, "refused")
	_, ok3, _ := require_trusted_proxy_auth(&auth, auth_req({hdr("Authorization", "Bearer hut_abc")}))
	testing.expect(t, !ok3, "refused")
	_, ok4, _ := require_auth_any(&auth, auth_req({hdr("Authorization", "Bearer hbr_abc")}))
	testing.expect(t, !ok4, "refused")
	_, ok5, _ := require_auth_or_bridge_token(&auth, auth_req({hdr("Authorization", "Bearer hba_abc")}))
	testing.expect(t, !ok5, "refused")

	testing.expect_value(t, count("missing") - missing_before, u64(1))
	testing.expect_value(t, count("user_token") - user_before, u64(1))
	testing.expect_value(t, count("trusted_proxy") - proxy_before, u64(1)) // proxy-only ignores the bearer
	testing.expect_value(t, count("bridge_token") - bridge_before, u64(2))
}

@(test)
test_device_auth_result_mappers :: proc(t: ^testing.T) {
	testing.expect_value(t, device_auth_error_result({}), "ok")
	testing.expect_value(t, device_auth_error_result(domain.domain_error(.Rate_Limited, "")), "rate_limited")
	testing.expect_value(t, device_auth_error_result(domain.domain_error(.Validation_Failed, "")), "invalid")
	testing.expect_value(t, device_auth_error_result(domain.domain_error(.Not_Found, "")), "invalid")
	testing.expect_value(t, device_auth_error_result(domain.domain_error(.Gone, "")), "expired")
	testing.expect_value(t, device_auth_error_result(domain.domain_error(.Internal_Error, "")), "other")
	testing.expect_value(t, device_auth_poll_result(.Pending, {}), "pending")
	testing.expect_value(t, device_auth_poll_result(.Approved, {}), "ok")
	testing.expect_value(t, device_auth_poll_result(.Denied, {}), "denied")
	testing.expect_value(t, device_auth_poll_result(.Expired, {}), "expired")
	testing.expect_value(t, device_auth_poll_result(.Slow_Down, domain.domain_error(.Rate_Limited, "slow_down")), "rate_limited")
	testing.expect_value(t, device_auth_poll_result(.Invalid_Grant, domain.domain_error(.Unauthenticated, "")), "invalid")
	testing.expect_value(t, device_auth_result_enum("weird"), "other")
}

@(test)
test_device_auth_handlers_count_outcomes_and_rate_limits :: proc(t: ^testing.T) {
	// Handlers allocate response bodies on the per-request arena in production;
	// mirror that so the leak tracker does not report them.
	context.allocator = context.temp_allocator
	auth_metrics_init(metrics.init_global())
	config := device_auth.default_grant_store_config()
	config.rate_limit = 2
	store := device_auth.new_grant_store(config)
	defer device_auth.grant_store_free(&store)
	service := device_auth.new_device_auth_service(&store, device_auth.real_monotonic_clock(), nil)
	defer delete(service.trusted_cidrs)
	handlers := Device_Auth_Handlers{service = &service}

	dcount := proc(step, result: string) -> u64 { return metrics.counter_value(metrics.with(auth_metrics.device_auth, step, result)) }
	rl_before := metrics.counter_value(metrics.with(auth_metrics.rate_limited, RATE_LIMIT_ENDPOINT_DEVICE_AUTH))
	ok_before := dcount("authorize", "ok")
	invalid_before := dcount("authorize", "invalid")
	limited_before := dcount("authorize", "rate_limited")
	pending_before := dcount("poll", "pending")

	// Missing client -> invalid (and does not spend the rate budget).
	resp := device_authorize_handler(rawptr(&handlers), Request{method = "POST", path = "/api/v1/device/authorize", remote_addr = "203.0.113.9:4000", body = `{}`})
	testing.expect_value(t, resp.status, 400)
	// Two allowed, third is rate limited.
	for i in 0 ..< 3 {
		resp = device_authorize_handler(rawptr(&handlers), Request{method = "POST", path = "/api/v1/device/authorize", remote_addr = "203.0.113.9:4000", body = `{"client":"ham-bridge","device_label":"box"}`})
		testing.expect_value(t, resp.status, 200 if i < 2 else 429)
	}
	testing.expect_value(t, dcount("authorize", "invalid") - invalid_before, u64(1))
	testing.expect_value(t, dcount("authorize", "ok") - ok_before, u64(2))
	testing.expect_value(t, dcount("authorize", "rate_limited") - limited_before, u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(auth_metrics.rate_limited, RATE_LIMIT_ENDPOINT_DEVICE_AUTH)) - rl_before, u64(1))

	// Unknown device_code polls as pending (anti-enumeration).
	resp = device_token_handler(rawptr(&handlers), Request{method = "POST", path = "/api/v1/device/token", remote_addr = "203.0.113.10:4000", body = `{"device_code":"nope"}`})
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, dcount("poll", "pending") - pending_before, u64(1))
}
