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
	testing.expect(t, !bridge_http_is_terminal(0, false), "status=0 ok=false must not be terminal")

	// Retriable: HTTP 429 (Rate Limit)
	testing.expect(t, bridge_http_is_retriable(429, true), "HTTP 429 must be retriable")
	testing.expect(t, !bridge_http_is_terminal(429, true), "HTTP 429 must not be terminal")

	// Retriable: HTTP 5xx (Server Errors)
	testing.expect(t, bridge_http_is_retriable(500, true), "HTTP 500 must be retriable")
	testing.expect(t, bridge_http_is_retriable(502, true), "HTTP 502 must be retriable")
	testing.expect(t, bridge_http_is_retriable(503, true), "HTTP 503 must be retriable")
	testing.expect(t, bridge_http_is_retriable(504, true), "HTTP 504 must be retriable")

	// Terminal: HTTP 4xx (Client / Auth / Validation, except 429)
	testing.expect(t, !bridge_http_is_retriable(400, true), "HTTP 400 must be terminal")
	testing.expect(t, bridge_http_is_terminal(400, true), "HTTP 400 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(401, true), "HTTP 401 must be terminal")
	testing.expect(t, bridge_http_is_terminal(401, true), "HTTP 401 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(403, true), "HTTP 403 must be terminal")
	testing.expect(t, bridge_http_is_terminal(403, true), "HTTP 403 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(404, true), "HTTP 404 must be terminal")
	testing.expect(t, bridge_http_is_terminal(404, true), "HTTP 404 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(409, true), "HTTP 409 must be terminal")
	testing.expect(t, !bridge_http_is_retriable(422, true), "HTTP 422 must be terminal")

	// Terminal: HTTP 2xx / 3xx (Success / Redirect)
	testing.expect(t, !bridge_http_is_retriable(200, true), "HTTP 200 must be terminal")
	testing.expect(t, bridge_http_is_terminal(200, true), "HTTP 200 must be terminal")
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

@(test)
test_bridge_http_5xx_then_200_sequence :: proc(t: ^testing.T) {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	testing.expect(t, err == nil, "listen_tcp failed")

	bound_ep, ep_err := net.bound_endpoint(listener)
	testing.expect(t, ep_err == nil, "bound_endpoint failed")
	port := bound_ep.port

	server_thread := thread.create_and_start_with_data(rawptr(uintptr(listener)), proc(data: rawptr) {
		l := net.TCP_Socket(uintptr(data))
		req_count := 0
		for req_count < 2 {
			client, _, accept_err := net.accept_tcp(l)
			if accept_err != nil do return
			req_count += 1
			buf: [1024]byte
			_, _ = net.recv_tcp(client, buf[:])
			if req_count == 1 {
				body := "503 service unavailable"
				resp := fmt.tprintf("HTTP/1.1 503 Service Unavailable\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			} else {
				body := "{\"restarted\":true}"
				resp := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
				net.send_tcp(client, transmute([]byte)resp)
			}
			net.close(client)
		}
	})

	hub_url := fmt.tprintf("http://127.0.0.1:%d", port)
	headers := [?]http.Header{
		{name = "Authorization", value = "Bearer test_token"},
		{name = "Content-Type", value = "application/json"},
	}

	resp, ok := bridge_http_request_retry("POST", hub_url, "/api/v1/agent-instances/inst_test/restart", "{}", headers[:], 2000, 4, 5)
	testing.expect(t, ok, "request_retry must return ok=true")
	testing.expect(t, resp.status == 200, "status must be 200 after retry")
	testing.expect(t, strings.contains(resp.body, "restarted"), "body must contain restarted")

	_ = posix.shutdown(posix.FD(listener), .RDWR)
	net.close(listener)
	thread.join(server_thread)
	thread.destroy(server_thread)
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
