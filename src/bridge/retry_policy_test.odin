#+build !windows
package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"

@(test)
test_bridge_http_is_retriable_classifier :: proc(t: ^testing.T) {
	// Retriable: Transport failure (!ok or status == 0)
	testing.expect(t, bridge_http_is_retriable(0, false), "status=0 ok=false must be retriable")
	testing.expect(t, bridge_http_is_retriable(0, true), "status=0 ok=true must be retriable")

	// Retriable: HTTP 429 (Rate Limit)
	testing.expect(t, bridge_http_is_retriable(429, true), "HTTP 429 must be retriable")

	// Retriable: HTTP 5xx (Server Errors)
	testing.expect(t, bridge_http_is_retriable(500, true), "HTTP 500 must be retriable")
	testing.expect(t, bridge_http_is_retriable(502, true), "HTTP 502 must be retriable")
	testing.expect(t, bridge_http_is_retriable(503, true), "HTTP 503 must be retriable")
	testing.expect(t, bridge_http_is_retriable(504, true), "HTTP 504 must be retriable")

	// Terminal: HTTP 4xx (Client / Auth / Validation, except 429)
	testing.expect(t, !bridge_http_is_retriable(400, true), "HTTP 400 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(401, true), "HTTP 401 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(403, true), "HTTP 403 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(404, true), "HTTP 404 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(409, true), "HTTP 409 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(422, true), "HTTP 422 must be terminal")

	// Terminal: HTTP 2xx / 3xx (Success / Redirect)
	testing.expect(t, !bridge_http_is_retriable(200, true), "HTTP 200 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(201, true), "HTTP 201 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(204, true), "HTTP 204 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(304, true), "HTTP 304 must be terminal")
}

@(test)
bridge_http_retry_respects_an_already_expired_command_budget :: proc(t: ^testing.T) {
	started := time.now()
	resp, ok := bridge_http_request_retry(
		"GET", "http://127.0.0.1:1", "/never", "", nil,
		2000, 4, 150,
		time.to_unix_nanoseconds(time.now()) - i64(time.Millisecond),
	)
	_ = resp
	testing.expect(t, !ok, "expired work must fail before dialing")
	testing.expect(t, time.diff(started, time.now()) < 50 * time.Millisecond, "expired work must not consume retry backoff")
}

// Retry_Test_Server answers successive connections with `responses` in order and
// counts the requests it saw.
@(private = "file")
Retry_Test_Server :: struct {
	listener:  net.TCP_Socket,
	responses: []string,
	requests:  int,
	thread:    ^thread.Thread,
	url:       string,
}

@(private = "file")
retry_test_serve :: proc(t: ^testing.T, srv: ^Retry_Test_Server) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil, "listen_tcp failed")
	bound_ep, _ := net.bound_endpoint(listener)
	srv.listener = listener
	srv.url = fmt.tprintf("http://127.0.0.1:%d", bound_ep.port)
	srv.thread = thread.create_and_start_with_data(rawptr(srv), proc(data: rawptr) {
		srv := (^Retry_Test_Server)(data)
		for srv.requests < len(srv.responses) {
			client, _, accept_err := net.accept_tcp(srv.listener)
			if accept_err != nil do return
			buf: [1024]byte
			_, _ = net.recv_tcp(client, buf[:])
			_, _ = net.send_tcp(client, transmute([]byte)srv.responses[srv.requests])
			srv.requests += 1
			net.close(client)
		}
	})
}

@(private = "file")
retry_test_stop :: proc(srv: ^Retry_Test_Server) {
	_ = posix.shutdown(posix.FD(srv.listener), .RDWR)
	net.close(srv.listener)
	thread.join(srv.thread)
	thread.destroy(srv.thread)
}

@(private = "file")
retry_test_response :: proc(status: int, reason, body: string) -> string {
	return fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, reason, len(body), body)
}

@(private = "file")
RETRY_TEST_HEADERS := [?]http.Header{{name = "Authorization", value = "Bearer test_token"}, {name = "Content-Type", value = "application/json"}}

@(test)
test_bridge_http_get_5xx_then_200_sequence :: proc(t: ^testing.T) {
	srv := Retry_Test_Server{responses = {retry_test_response(503, "Service Unavailable", "503 service unavailable"), retry_test_response(200, "OK", `{"restarted":true}`)}}
	retry_test_serve(t, &srv)
	defer retry_test_stop(&srv)
	resp, ok := bridge_http_request_retry("GET", srv.url, "/api/v1/agent-instances/inst_test", "", RETRY_TEST_HEADERS[:], 2000, 4, 5)
	defer delete(resp.body)
	testing.expect(t, ok, "request_retry must return ok=true")
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, strings.contains(resp.body, "restarted"), "body must contain restarted")
}

// REQ-ERR-PROTO-B: a POST that failed with a 5xx may already have been applied (a
// launch, an action, a comment), so it is not repeated.
@(test)
test_bridge_http_post_5xx_is_not_retried :: proc(t: ^testing.T) {
	srv := Retry_Test_Server{responses = {retry_test_response(500, "Internal Server Error", `{"error":{"code":"internal_error","class":"retriable","message":"x"}}`), retry_test_response(200, "OK", `{}`)}}
	retry_test_serve(t, &srv)
	resp, ok := bridge_http_request_retry("POST", srv.url, "/api/v1/agent-instances", "{}", RETRY_TEST_HEADERS[:], 2000, 4, 5)
	defer delete(resp.body)
	testing.expect_value(t, resp.status, 500)
	testing.expect(t, ok)
	// Shutting the listener down wakes the server's second accept, so it exits.
	retry_test_stop(&srv)
	testing.expect_value(t, srv.requests, 1)
}

// A POST the hub refused before doing anything (503 bridge_busy) is retried, and
// not before the hub's retry_after_ms.
@(test)
test_bridge_http_post_busy_is_retried_after_retry_after :: proc(t: ^testing.T) {
	busy := `{"error":{"code":"bridge_busy","class":"retriable","message":"busy","retry_after_ms":200}}`
	srv := Retry_Test_Server{responses = {retry_test_response(503, "Service Unavailable", busy), retry_test_response(200, "OK", `{"ok":true}`)}}
	retry_test_serve(t, &srv)
	defer retry_test_stop(&srv)
	started := time.now()
	resp, ok := bridge_http_request_retry("POST", srv.url, "/api/v1/agent-instances", "{}", RETRY_TEST_HEADERS[:], 2000, 4, 5)
	defer delete(resp.body)
	testing.expect(t, ok)
	testing.expect_value(t, resp.status, 200)
	testing.expect(t, time.diff(started, time.now()) >= 200 * time.Millisecond, "the retry waited for retry_after_ms")
}

@(test)
test_bridge_http_attempt_retriable_by_method :: proc(t: ^testing.T) {
	plain_503 := http.Response{status = 503, body = "unavailable"}
	busy_503 := http.Response{status = 503, body = `{"error":{"code":"bridge_busy","class":"retriable"}}`}
	testing.expect(t, bridge_http_attempt_retriable("GET", plain_503, true))
	testing.expect(t, bridge_http_attempt_retriable("GET", {}, false), "GET transport failure retries")
	testing.expect(t, !bridge_http_attempt_retriable("POST", plain_503, true), "POST 5xx may have been applied")
	testing.expect(t, !bridge_http_attempt_retriable("POST", {}, false), "POST transport failure may have been applied")
	testing.expect(t, bridge_http_attempt_retriable("POST", busy_503, true), "POST refused as busy was not applied")
	testing.expect(t, bridge_http_attempt_retriable("POST", http.Response{status = 429}, true), "429 was not applied")
	testing.expect_value(t, bridge_http_retry_after_ms(http.Response{status = 503, body = `{"error":{"code":"bridge_busy","retry_after_ms":750}}`}, true), i64(750))
}

@(test)
test_bridge_launch_dedupe_idempotency :: proc(t: ^testing.T) {
	bridge_runtime_init()

	// 1. Command caching deduplication
	cmd_id := "test_cmd_dedupe_1"
	cached_resp := "{\"command_id\":\"test_cmd_dedupe_1\",\"status\":\"succeeded\"}"
	bridge_runtime_cache_command(cmd_id, cached_resp)

	retrieved, has := bridge_runtime_cached_command(cmd_id)
	testing.expect(t, has, "cached command should exist")
	testing.expect(t, retrieved == cached_resp, "cached response should match")

	// 2. Launch record replacement (never duplicate for same instance_id)
	inst_id := "inst_test_dedupe"
	launch1 := Bridge_Runtime_Launch{
		agent_instance_id = inst_id,
		command_id        = "cmd_a",
		pane_id           = "%1",
	}
	bridge_runtime_record_launch(launch1)

	rec1, ok1 := bridge_runtime_get_launch(inst_id)
	testing.expect(t, ok1, "launch record should exist")
	testing.expect(t, rec1.command_id == "cmd_a", "command_id should be cmd_a")

	// Second launch for same instance (e.g. retry or relaunch)
	launch2 := Bridge_Runtime_Launch{
		agent_instance_id = inst_id,
		command_id        = "cmd_b",
		pane_id           = "%2",
	}
	bridge_runtime_record_launch(launch2)

	rec2, ok2 := bridge_runtime_get_launch(inst_id)
	testing.expect(t, ok2, "launch record should still exist")
	testing.expect(t, rec2.command_id == "cmd_b", "command_id should be updated in place")
	testing.expect(t, rec2.pane_id == "%2", "pane_id should be updated")

	// Verify no duplicate in registry
	count := 0
	sync.mutex_lock(&bridge_runtime_mutex)
	for l in bridge_runtime_launches {
		if l.agent_instance_id == inst_id do count += 1
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	testing.expect(t, count == 1, "exactly one launch record must exist (no duplicate)")

	bridge_runtime_test_reset()
}

// REQ-ERR-PROTO-B: after a hub restart the reconnect delays double from ~500ms up to
// a 30s ceiling, and are jittered so bridges that lost the hub together do not redial
// together.
@(test)
test_bridge_hub_reconnect_backoff_is_bounded_and_jittered :: proc(t: ^testing.T) {
	p := BRIDGE_HUB_RECONNECT_BACKOFF
	testing.expect_value(t, bridge_backoff_delay_ms(p, 1, 0), i64(400)) // 500 - 20%
	testing.expect_value(t, bridge_backoff_delay_ms(p, 1, 200), i64(600)) // 500 + 20%
	total: i64 = 0
	for failures in 1 ..= 40 {
		d := bridge_backoff_delay_ms(p, failures, u64(failures) * 7919)
		testing.expectf(t, d >= 400 && d <= 36_000, "attempt %d delay %d outside [400ms, 36s]", failures, d)
		total += d
	}
	// 40 attempts take minutes, not the 20s a flat 500ms gives: no reconnect storm.
	testing.expectf(t, total > 10 * 60_000, "40 reconnects took only %dms", total)
	testing.expect(t, bridge_backoff_delay_ms(p, 3, 1) != bridge_backoff_delay_ms(p, 3, 2), "jitter must vary the delay")
}

// REQ-ERR-PROTO-B: bridge_ready's heartbeat_interval_seconds is followed, clamped,
// and an older hub that omits it leaves the 45s default.
@(test)
test_bridge_hub_heartbeat_interval_follows_hub :: proc(t: ^testing.T) {
	defer bridge_hub_set_heartbeat_interval(0)
	bridge_hub_set_heartbeat_interval(30)
	testing.expect_value(t, bridge_hub_heartbeat_interval_ns, i64(30 * time.Second))
	bridge_hub_set_heartbeat_interval(1)
	testing.expect_value(t, bridge_hub_heartbeat_interval_ns, i64(BRIDGE_HUB_HEARTBEAT_INTERVAL_MIN_S) * i64(time.Second))
	bridge_hub_set_heartbeat_interval(3600)
	testing.expect_value(t, bridge_hub_heartbeat_interval_ns, i64(BRIDGE_HUB_HEARTBEAT_INTERVAL_MAX_S) * i64(time.Second))
	bridge_hub_set_heartbeat_interval(0)
	testing.expect_value(t, bridge_hub_heartbeat_interval_ns, i64(BRIDGE_HUB_HEARTBEAT_INTERVAL))
}

// REQ-ERR-PROTO-B: git network operations get the 120s the hub waits for them.
@(test)
test_bridge_vcs_network_commands_match_hub_wait :: proc(t: ^testing.T) {
	for command_type in ([]string{"vcs_push", "vcs_sync", "vcs_pull", "vcs_upload"}) {
		spec, ok := bridge_command_spec(command_type)
		testing.expect(t, ok)
		testing.expect_value(t, spec.timeout_ms, 120_000)
	}
	spec, _ := bridge_command_spec("vcs_commit")
	testing.expect_value(t, spec.timeout_ms, 30_000)
}

// The retry counters shipped in the heartbeat move with each sequence's outcome.
@(test)
test_bridge_http_retry_metrics_count_outcomes :: proc(t: ^testing.T) {
	before := bridge_http_retry_metrics
	srv := Retry_Test_Server{responses = {retry_test_response(503, "Service Unavailable", "x"), retry_test_response(200, "OK", `{}`)}}
	retry_test_serve(t, &srv)
	resp, _ := bridge_http_request_retry("GET", srv.url, "/api/v1/x", "", RETRY_TEST_HEADERS[:], 2000, 4, 5)
	delete(resp.body)
	retry_test_stop(&srv)
	// Other tests in this package retry concurrently, so only lower bounds hold.
	testing.expect(t, bridge_http_retry_metrics.retry >= before.retry + 1, "one repeated attempt")
	testing.expect(t, bridge_http_retry_metrics.recovered >= before.recovered + 1, "the retried GET recovered")
	json := bridge_http_retry_metrics_json()
	defer delete(json)
	testing.expect(t, strings.has_prefix(json, `{"retry":`) && strings.contains(json, `"gave_up":`) && strings.contains(json, `"deferred":`))
}

// REQ-ERR-PROTO-B: the 120s VCS budget must reach the git subprocess itself, not just
// the dispatcher. The recorder only intercepts this test's sentinel path, so VCS tests
// running in parallel still reach the real runner.
VCS_BUDGET_TEST_PATH :: "/nonexistent/req-err-proto-b-vcs-budget"
vcs_budget_test_seen: map[string]time.Duration
vcs_budget_test_mu: sync.Mutex

@(test)
test_vcs_network_operations_run_with_network_budget :: proc(t: ^testing.T) {
	vcs_process_runner = proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, ok, timed_out: bool) {
		if len(args) < 4 || args[2] != VCS_BUDGET_TEST_PATH do return bridge_process_run_capture(args, timeout)
		sync.mutex_lock(&vcs_budget_test_mu)
		defer sync.mutex_unlock(&vcs_budget_test_mu)
		vcs_budget_test_seen[args[3]] = timeout
		return "", "", true, false
	}
	defer vcs_process_runner = bridge_process_run_capture
	defer delete(vcs_budget_test_seen)

	push_ok, _, _ := vcs_git_push(VCS_BUDGET_TEST_PATH)
	sync_ok, _, _ := vcs_git_sync(VCS_BUDGET_TEST_PATH)
	testing.expect(t, push_ok && sync_ok)
	_, _ = vcs_git_status(VCS_BUDGET_TEST_PATH)
	testing.expect_value(t, vcs_budget_test_seen["push"], VCS_NETWORK_TIMEOUT)
	testing.expect_value(t, vcs_budget_test_seen["pull"], VCS_NETWORK_TIMEOUT)
	testing.expect_value(t, vcs_budget_test_seen["status"], VCS_LOCAL_TIMEOUT)
	testing.expect(t, VCS_NETWORK_TIMEOUT == 120 * time.Second, "matches the hub's vcs_command_timeout_ms and the dispatcher cap")
}

// REQ-ERR-PROTO-B: the dispatcher budget is the hub's TOP-LEVEL timeout_ms, capped by
// the spec; a timeout_ms nested in params does not count.
@(test)
test_bridge_command_budget_uses_top_level_timeout :: proc(t: ^testing.T) {
	spec, _ := bridge_command_spec("shell_kill")
	testing.expect_value(t, bridge_command_budget_ms(`{"type":"shell_kill","timeout_ms":5000}`, spec), 5000)
	testing.expect_value(t, bridge_command_budget_ms(`{"type":"shell_kill","timeout_ms":999999}`, spec), spec.timeout_ms)
	testing.expect_value(t, bridge_command_budget_ms(`{"type":"shell_kill","params":{"timeout_ms":1},"timeout_ms":4000}`, spec), 4000)
	testing.expect_value(t, bridge_command_budget_ms(`{"type":"shell_kill","params":{"timeout_ms":1}}`, spec), spec.timeout_ms)
}
