package http

import "core:strings"
import auth_service "odin_test:hub/service/auth"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"

// Auth / device-auth / rate-limit metrics (hub telemetry plan 3.7).
//
//   heimdall_auth_failures_total{kind}
//     kind is derived from the CREDENTIAL SHAPE the request presented, not
//     from the error (a failed request has no Auth_Context.kind):
//       trusted_proxy  - no bearer; trusted-proxy identity header present or
//                        the route is proxy-only (require_trusted_proxy_auth)
//       user_token     - Bearer hut_*
//       bridge_token   - bare Bearer hbr_/hba_ or a refresh token hbf_
//       instance_token - bridge bearer plus an instance assertion (header/body)
//       missing        - no credential at all
//       other          - any other bearer shape
//   heimdall_device_auth_total{step,result}
//     step in authorize/verify/approve/poll; result in
//     ok/pending/denied/expired/rate_limited/invalid/other. `step` is an
//     addition over the plan's {result}: 4x7 series, and without it a flood of
//     pending polls would drown the approve/deny signal.
//   heimdall_rate_limited_total{endpoint}
//     endpoint from a FIXED list (device_auth, other).
//
// All families are nil until auth_metrics_init runs; every op is nil-safe.
Auth_Metrics :: struct {
	auth_failures: ^metrics.Family, // {kind}
	device_auth:   ^metrics.Family, // {step, result}
	rate_limited:  ^metrics.Family, // {endpoint}
}

auth_metrics: Auth_Metrics

RATE_LIMIT_ENDPOINT_DEVICE_AUTH :: "device_auth"

auth_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	auth_metrics.auth_failures = metrics.new_counter(reg, "heimdall_auth_failures_total",
		"Requests refused by an authentication middleware, by presented credential kind.", {"kind"})
	auth_metrics.device_auth = metrics.new_counter(reg, "heimdall_device_auth_total",
		"Device-authorization flow steps by outcome.", {"step", "result"})
	auth_metrics.rate_limited = metrics.new_counter(reg, "heimdall_rate_limited_total",
		"Requests refused with 429 by a hub rate limiter, by endpoint family.", {"endpoint"})
	for kind in ([]string{"trusted_proxy", "user_token", "bridge_token", "instance_token", "missing", "other"}) do metrics.with(auth_metrics.auth_failures, kind)
	metrics.with(auth_metrics.rate_limited, RATE_LIMIT_ENDPOINT_DEVICE_AUTH)
}

// auth_metrics_record_failure counts one refused request. `proxy_only` marks
// the trusted-proxy-only middleware, where Authorization is ignored entirely.
auth_metrics_record_failure :: proc(auth: ^auth_service.Auth_Service, req: Request, proxy_only := false) {
	if auth_metrics.auth_failures == nil do return
	metrics.counter_inc(metrics.with(auth_metrics.auth_failures, auth_failure_kind(auth, req, proxy_only)))
}

// auth_failure_kind classifies the credential shape of a refused request.
auth_failure_kind :: proc(auth: ^auth_service.Auth_Service, req: Request, proxy_only := false) -> string {
	if proxy_only do return "trusted_proxy"
	token, has_bearer := bearer_token(req)
	if has_bearer {
		switch {
		case strings.has_prefix(token, "hut_"):
			return "user_token"
		case auth_service.is_bridge_bearer(token):
			relay := header_value(req.headers, "X-Heimdall-Instance-Token")
			if strings.has_prefix(relay, "hit_") && len(relay) > len("hit_") do return "instance_token"
			if auth_service.extract_body_instance_id(req.body) != "" do return "instance_token"
			return "bridge_token"
		case strings.has_prefix(token, "hbf_"):
			return "bridge_token"
		}
		return "other"
	}
	if auth != nil && auth.config.username_header != "" && strings.trim_space(header_value(req.headers, auth.config.username_header)) != "" {
		return "trusted_proxy"
	}
	if auth_service.token_in_query_or_body(req.query, req.body) do return "other"
	return "missing"
}

// device_auth_record counts one device-auth step outcome and, for a
// rate-limited outcome, the rate_limited_total series too.
device_auth_record :: proc(step, result: string) {
	if auth_metrics.device_auth == nil do return
	metrics.counter_inc(metrics.with(auth_metrics.device_auth, step, device_auth_result_enum(result)))
	if result == "rate_limited" do metrics.counter_inc(metrics.with(auth_metrics.rate_limited, RATE_LIMIT_ENDPOINT_DEVICE_AUTH))
}

device_auth_result_enum :: proc(result: string) -> string {
	switch result {
	case "ok", "pending", "denied", "expired", "rate_limited", "invalid":
		return result
	}
	return "other"
}

// device_auth_error_result maps a service error onto the result enum.
device_auth_error_result :: proc(err: domain.Domain_Error) -> string {
	#partial switch err.code {
	case .None:              return "ok"
	case .Rate_Limited:      return "rate_limited"
	case .Validation_Failed: return "invalid"
	case .Not_Found:         return "invalid"
	case .Unauthenticated:   return "invalid"
	case .Forbidden:         return "denied"
	case .Gone:              return "expired"
	}
	return "other"
}

// device_auth_poll_result maps a poll outcome onto the result enum.
device_auth_poll_result :: proc(status: device_auth.Poll_Status, err: domain.Domain_Error) -> string {
	if err.code == .Rate_Limited do return "rate_limited"
	switch status {
	case .Pending:       return "pending"
	case .Approved:      return "ok"
	case .Denied:        return "denied"
	case .Expired:       return "expired"
	case .Slow_Down:     return "rate_limited"
	case .Invalid_Grant: return "invalid"
	}
	return "other"
}
