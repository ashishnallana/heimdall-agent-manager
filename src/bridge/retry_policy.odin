package main

import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"

BRIDGE_RETRY_MAX_ATTEMPTS :: 4
BRIDGE_RETRY_BASE_BACKOFF_MS :: 150

// ---- typed errors + the shared backoff policy ---------------------------
//
// A failure that a caller may act on is a Bridge_Error, never a free-text string:
// the code/reason come from the bridge_log allow-list and the class (retriable /
// recoverable / fatal, see contracts.bridge_error_classify) tells the caller what
// it may do. Every retry loop computes its wait with bridge_backoff_delay_ms so
// the whole bridge backs off the same way: base * 2^(failures-1), capped, with
// optional +-jitter so many bridges never retry in lockstep.

Bridge_Error :: struct {
	code:           contracts.Bridge_Log_Code,
	reason:         contracts.Bridge_Log_Sym,
	hub_status:     int,
	class:          contracts.Bridge_Error_Class,
	retry_after_ms: i64, // server-supplied floor for the next attempt (0 = none)
}

bridge_error :: proc(code: contracts.Bridge_Log_Code, reason: contracts.Bridge_Log_Sym = .other, hub_status := 0, retry_after_ms: i64 = 0) -> Bridge_Error {
	return Bridge_Error{
		code           = code,
		reason         = reason,
		hub_status     = hub_status,
		class          = contracts.bridge_error_classify(code, reason, hub_status),
		retry_after_ms = retry_after_ms,
	}
}

// bridge_error_string renders "code reason=<sym> hub_status=<n> class=<class>" for
// local stderr lines; temp-allocated.
bridge_error_string :: proc(err: Bridge_Error) -> string {
	return fmt.tprintf("%s reason=%s hub_status=%d class=%s", contracts.bridge_log_code_name(err.code), contracts.bridge_log_sym_name(err.reason), err.hub_status, contracts.bridge_error_class_name(err.class))
}

Bridge_Backoff_Policy :: struct {
	base_ms:    i64,
	max_ms:     i64, // <= 0: uncapped
	jitter_pct: int, // delay is spread uniformly over +-jitter_pct% (0 = exact)
}

BRIDGE_BACKOFF_DEFAULT :: Bridge_Backoff_Policy{base_ms = 1_000, max_ms = 300_000, jitter_pct = 20}

// bridge_backoff_delay_ms is the wait before retry number `failures` (>= 1):
// base * 2^(failures-1), capped at max_ms, then spread by +-jitter_pct% using
// jitter_seed (any value; callers pass a random one, tests a fixed one).
bridge_backoff_delay_ms :: proc(policy: Bridge_Backoff_Policy, failures: int, jitter_seed: u64 = 0) -> i64 {
	if failures <= 0 || policy.base_ms <= 0 do return 0
	delay := policy.base_ms
	for _ in 1..<failures {
		if policy.max_ms > 0 && delay >= policy.max_ms do break
		delay *= 2
	}
	if policy.max_ms > 0 && delay > policy.max_ms do delay = policy.max_ms
	if policy.jitter_pct > 0 {
		span := delay * i64(policy.jitter_pct) / 100
		if span > 0 do delay += i64(jitter_seed % u64(2 * span + 1)) - span
	}
	return delay
}

// bridge_backoff_next_at_ms is when retry number `failures` may run: now plus the
// policy delay, but never earlier than a server-supplied retry_after.
bridge_backoff_next_at_ms :: proc(policy: Bridge_Backoff_Policy, failures: int, now_ms: i64, err: Bridge_Error, jitter_seed: u64 = 0) -> i64 {
	delay := bridge_backoff_delay_ms(policy, failures, jitter_seed)
	if err.retry_after_ms > delay do delay = err.retry_after_ms
	return now_ms + delay
}

// bridge_http_is_retriable reports whether an HTTP response status and transport ok
// flag indicate a transient failure eligible for retry under the Heimdall retry policy:
//   - Transport failure (!ok or status == 0) -> true (retriable)
//   - HTTP 429 (Too Many Requests / Rate Limited) -> true (retriable)
//   - HTTP 5xx (Server Errors: 500, 502, 503, 504, ...) -> true (retriable)
//   - HTTP 4xx (Client / Auth / Validation, except 429) -> false (terminal, non-retriable)
//   - HTTP 2xx / 3xx (Success / Redirect / Not Modified) -> false (terminal, non-retriable)
bridge_http_is_retriable :: proc(status: int, ok: bool) -> bool {
	if !ok || status == 0 do return true
	if status < 400 do return false
	return contracts.bridge_error_http_class(status) == .retriable
}

// bridge_http_response_is_retriable prefers the class the hub put in its error
// envelope (REQ-ERR-PROTO-A) and falls back to the status mapping above.
bridge_http_response_is_retriable :: proc(resp: http.Response, ok: bool) -> bool {
	if ok && resp.status >= 400 {
		if werr, found := contracts.wire_error_parse(resp.body, context.temp_allocator); found do return werr.class == .retriable
	}
	return bridge_http_is_retriable(resp.status, ok)
}

// bridge_http_is_terminal reports whether an HTTP response is terminal (not retriable).
bridge_http_is_terminal :: proc(status: int, ok: bool) -> bool {
	return !bridge_http_is_retriable(status, ok)
}

// bridge_http_backoff_sleep sleeps for base_ms * 2^(attempt-1).
bridge_http_backoff_sleep :: proc(attempt: int, base_ms: int = BRIDGE_RETRY_BASE_BACKOFF_MS) {
	ms := bridge_backoff_delay_ms(Bridge_Backoff_Policy{base_ms = i64(base_ms)}, attempt)
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// bridge_http_request_retry issues an HTTP request with bounded retry and exponential
// backoff for retriable failures. Non-retriable (terminal) responses return immediately.
bridge_http_request_retry :: proc(
	method, hub_url, path, body: string,
	headers: []http.Header,
	timeout_ms: int = http.DEFAULT_TIMEOUT_MS,
	max_attempts: int = BRIDGE_RETRY_MAX_ATTEMPTS,
	base_backoff_ms: int = BRIDGE_RETRY_BASE_BACKOFF_MS,
	deadline_ns: i64 = 0,
) -> (http.Response, bool) {
	resp: http.Response
	ok := false
	for attempt in 1..=max_attempts {
		attempt_timeout_ms := timeout_ms
		if deadline_ns > 0 {
			remaining_ns := deadline_ns - time.to_unix_nanoseconds(time.now())
			if remaining_ns <= 0 do return resp, false
			remaining_ms := int(remaining_ns / i64(time.Millisecond))
			if remaining_ms < 1 do remaining_ms = 1
			attempt_timeout_ms = min(attempt_timeout_ms, remaining_ms)
		}
		resp, ok = http.request_with_headers_timeout(method, hub_url, path, body, headers, attempt_timeout_ms)
		if !bridge_http_response_is_retriable(resp, ok) {
			// Log the terminal outcome when it followed at least one retry, so a
			// retried-then-succeeded (or retried-then-failed-hard) sequence is
			// visible in the log rather than trailing off at the last "retry" line.
			if attempt > 1 {
				fmt.println("bridge http retry DONE", "method=", method, "path=", path, "attempts=", attempt, "final_status=", resp.status, "ok=", ok, "outcome=", ok && resp.status >= 200 && resp.status < 300 ? "succeeded_after_retry" : "failed_terminal")
			}
			return resp, ok
		}
		if attempt < max_attempts {
			fmt.println("bridge http retry", "method=", method, "path=", path, "attempt=", attempt, "status=", resp.status, "ok=", ok)
			if resp.body != "" {
				delete(resp.body)
				resp.body = ""
			}
			backoff_ms := int(bridge_backoff_delay_ms(Bridge_Backoff_Policy{base_ms = i64(base_backoff_ms)}, attempt))
			if deadline_ns > 0 {
				remaining_ns := deadline_ns - time.to_unix_nanoseconds(time.now())
				if remaining_ns <= 0 do return resp, false
				remaining_ms := int(remaining_ns / i64(time.Millisecond))
				if remaining_ms <= 0 do return resp, false
				backoff_ms = min(backoff_ms, remaining_ms)
			}
			time.sleep(time.Duration(backoff_ms) * time.Millisecond)
		}
	}
	// All attempts were retriable and none terminal-succeeded: retries exhausted.
	fmt.println("bridge http retry EXHAUSTED", "method=", method, "path=", path, "attempts=", max_attempts, "final_status=", resp.status, "ok=", ok)
	return resp, ok
}
