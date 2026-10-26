package bridge_log

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import httpc "odin_test:lib/httpc"
import metrics "odin_test:lib/metrics"

@(private = "file")
Script :: struct {
	statuses: []int, // 0 = transport failure/timeout
	calls:    int,
	bodies:   [dynamic]string,
	paths:    [dynamic]string,
}

@(private = "file")
scripted_send :: proc(ctx: rawptr, endpoint: httpc.Url, path: []string, body: httpc.Body, timeout_ms: int) -> (int, bool) {
	s := (^Script)(ctx)
	append(&s.bodies, strings.clone(string(body.(httpc.Json_Body).encoded)))
	full, _ := httpc.build_url(endpoint, path)
	append(&s.paths, full)
	i := min(s.calls, len(s.statuses) - 1)
	s.calls += 1
	st := s.statuses[i]
	if st == 0 do return 0, false
	return st, true
}

@(private = "file")
script_free :: proc(s: ^Script) {
	for b in s.bodies do delete(b)
	delete(s.bodies)
	for p in s.paths do delete(p)
	delete(s.paths)
}

@(private = "file")
client_for :: proc(s: ^Script) -> Push_Client {
	c := new_push_client("http://127.0.0.1:9428/", "0.3.3-test")
	c.send = scripted_send
	c.send_ctx = rawptr(s)
	return c
}

@(test)
test_bridge_log_push_format_is_loki_with_two_label_streams :: proc(t: ^testing.T) {
	events := [?]domain.Bridge_Log_Event{
		{bridge_id = "brg_1", ts_ms = 1_700_000_000_123, level = "error", code = "provider_missing", fields_json = `{"provider":"claude"}`, count = 2},
		{bridge_id = "brg_2", ts_ms = 1_700_000_000_456, level = "warn", code = "hub_ws_closed", fields_json = `{"reason":"eof","duration_ms":250}`, count = 1},
		{bridge_id = "brg_1", ts_ms = 1_700_000_000_789, level = "error", code = "other", fields_json = `{}`, count = 1},
	}
	encoded := httpc.json_body(loki_push_payload(events[:], "1.2.3", context.temp_allocator), sort_keys = true)
	body := string(encoded.(httpc.Json_Body).encoded)
	testing.expect(t, strings.has_prefix(body, `{"streams":[{"stream":{"job":"heimdall-bridge","level":"warn"},"values":[`), body)
	testing.expect_value(t, strings.count(body, `"stream":{`), 2)
	// Labels are ONLY job + level: bridge_id/code/owner never appear as labels.
	testing.expect(t, !strings.contains(body, `"stream":{"job":"heimdall-bridge","level":"warn","`), "no extra labels")
	testing.expect(t, !strings.contains(body, "owner"), "owner is never shipped")
	// Values: [ns, line, metadata] (metadata keys sorted by the marshaller).
	testing.expect(t, strings.contains(body, `["1700000000456000000","Connection to the hub closed; reconnecting (reason: eof, after 250 ms)",{"bridge_id":"brg_2","class":"retriable","code":"hub_ws_closed","count":"1","duration_ms":"250","reason":"eof","version":"1.2.3"}]`), body)
	testing.expect(t, strings.contains(body, `["1700000000123000000","Provider CLI is not installed or has no runnable command (provider: claude) (x2)",{"bridge_id":"brg_1","class":"recoverable","code":"provider_missing","count":"2","provider":"claude","version":"1.2.3"}]`), body)
	testing.expect(t, strings.contains(body, `"class":"fatal","code":"other","count":"1","version"`), body)
	testing.expect(t, strings.has_suffix(body, "]}]}"), body)
}

@(test)
test_bridge_log_push_retries_5xx_once_and_never_4xx :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	before := metrics.counter_value(project_service.fleet_metrics.log_push_failures)
	events := [?]domain.Bridge_Log_Event{{bridge_id = "brg_1", ts_ms = 1, level = "error", code = "internal", fields_json = "{}", count = 1}}

	// 204 first time: one call, no failure.
	ok_s := Script{statuses = {204}}
	defer script_free(&ok_s)
	c := client_for(&ok_s)
	defer push_client_destroy(&c)
	push_sink(rawptr(&c), events[:])
	testing.expect_value(t, ok_s.calls, 1)
	testing.expect_value(t, c.failures, 0)
	testing.expect_value(t, ok_s.paths[0], "http://127.0.0.1:9428/insert/loki/api/v1/push")

	// 400: permanent, exactly one attempt, one failure.
	bad := Script{statuses = {400}}
	defer script_free(&bad)
	c2 := client_for(&bad)
	defer push_client_destroy(&c2)
	push_sink(rawptr(&c2), events[:])
	testing.expect_value(t, bad.calls, 1)
	testing.expect_value(t, c2.failures, 1)

	// 503 then 204: retried once, success, no failure.
	flaky := Script{statuses = {503, 204}}
	defer script_free(&flaky)
	c3 := client_for(&flaky)
	defer push_client_destroy(&c3)
	push_sink(rawptr(&c3), events[:])
	testing.expect_value(t, flaky.calls, 2)
	testing.expect_value(t, c3.failures, 0)

	// Timeout twice: two attempts, counted once.
	dead := Script{statuses = {0, 0, 0}}
	defer script_free(&dead)
	c4 := client_for(&dead)
	defer push_client_destroy(&c4)
	push_sink(rawptr(&c4), events[:])
	testing.expect_value(t, dead.calls, 2)
	testing.expect_value(t, c4.failures, 1)

	testing.expect_value(t, metrics.counter_value(project_service.fleet_metrics.log_push_failures) - before, u64(2))

	// Empty batch / unconfigured client: no call at all.
	c5 := client_for(&dead)
	defer push_client_destroy(&c5)
	push_sink(rawptr(&c5), nil)
	c6 := client_for(&dead)
	defer push_client_destroy(&c6)
	c6.base_url = ""
	push_sink(rawptr(&c6), events[:])
	testing.expect_value(t, dead.calls, 2)
}

// The sink is only ever invoked after the SQLite commit, from the writer thread
// (see service test test_bridge_log_push_sink_receives_committed_batch); a
// failing backend therefore cannot lose or block a stored event.
@(test)
test_bridge_log_push_client_from_url_strips_trailing_slash :: proc(t: ^testing.T) {
	c := new_push_client("  http://127.0.0.1:9428///  ")
	defer push_client_destroy(&c)
	testing.expect_value(t, c.base_url, "http://127.0.0.1:9428")
	testing.expect_value(t, c.timeout_ms, PUSH_TIMEOUT_MS)
	testing.expect(t, c.send != nil, "default sender installed")
}

@(test)
test_bridge_log_render_class_uses_reason_and_hub_status :: proc(t: ^testing.T) {
	testing.expect_value(t, render_class("provider_missing", `{"provider":"claude"}`), "recoverable")
	testing.expect_value(t, render_class("hub_ws_closed", `{"reason":"eof"}`), "retriable")
	testing.expect_value(t, render_class("hub_rejected", `{"hub_status":503}`), "retriable")
	testing.expect_value(t, render_class("hub_rejected", `{"hub_status":401}`), "recoverable")
	testing.expect_value(t, render_class("hub_rejected", `{"hub_status":400}`), "fatal")
	testing.expect_value(t, render_class("enroll_failed", `{"stage":"poll","reason":"expired"}`), "recoverable")
	testing.expect_value(t, render_class("update_apply_failed", `{"reason":"missing_binary"}`), "fatal")
	testing.expect_value(t, render_class("internal", `{}`), "fatal")
	// A code this hub does not know (normalized to "other") still gets a valid
	// class: from its fields when they carry evidence, else fatal.
	testing.expect_value(t, render_class("other", `{}`), "fatal")
	testing.expect_value(t, render_class("from_a_newer_bridge", `{}`), "fatal")
	testing.expect_value(t, render_class("other", `{"reason":"timeout"}`), "retriable")
	testing.expect_value(t, render_class("other", `{"hub_status":401}`), "recoverable")
}
