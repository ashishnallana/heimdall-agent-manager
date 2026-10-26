package bridge_start_success_relay_test

// Regression coverage for the "Hub relay failed" (retryable_unavailable) false
// negative on agent.start_success, and the AC-5 retry now applied to the
// agent-actions relay. Two guarantees:
//
//   1. bridge_local_relay_agent_method retries transient bridge->hub failures
//      (5xx / 429 / transport ok=false) with bounded backoff, so a flaky hub
//      response no longer surfaces as a single-shot failure.
//   2. agent.start_success is treated as an idempotent liveness signal: its
//      durable effect is applied locally BEFORE the relay, so a relay failure
//      returns ok:true (accepted-locally, reconcile pending) instead of a hard
//      retryable_unavailable error that would make the agent retry and
//      double-deliver.

import "core:fmt"
import "core:testing"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import bridge "odin_test:bridge"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

// A local one-shot TCP server that serves `count` responses in sequence, each
// taken from `bodies_statuses`. Returns the bound port.
start_seq_server :: proc(listener: net.TCP_Socket, script: []Seq_Response) {
	thread.create_and_start_with_poly_data2(listener, script, proc(l: net.TCP_Socket, script: []Seq_Response) {
		for i in 0..<len(script) {
			client, _, accept_err := net.accept_tcp(l)
			if accept_err != nil do return
			buf: [2048]byte
			_, _ = net.recv_tcp(client, buf[:])
			s := script[i]
			resp := fmt.tprintf(
				"HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
				s.status, s.reason, len(s.body), s.body,
			)
			net.send_tcp(client, transmute([]byte)resp)
			net.close(client)
		}
	})
}

Seq_Response :: struct {
	status: int,
	reason: string,
	body:   string,
}

listen_loopback :: proc() -> (net.TCP_Socket, int) {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	check(err == nil, "listen_tcp failed")
	bound_ep, ep_err := net.bound_endpoint(listener)
	check(ep_err == nil, "bound_endpoint failed")
	return listener, bound_ep.port
}

// 1. The agent-actions envelope relay retries a 503 then succeeds on the 200 —
//    proving bridge_local_relay_agent_envelope goes through bridge_http_request_retry.
test_agent_relay_retries_5xx_then_200 :: proc() {
	listener, port := listen_loopback()
	defer net.close(listener)

	start_seq_server(listener, []Seq_Response{
		{503, "Service Unavailable", "503 down"},
		{200, "OK", "{\"accepted\":true}"},
	})
	time.sleep(20 * time.Millisecond)

	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", port)
	bridge.bridge_config.bridge_token = "hbr_test"
	rec := bridge.Bridge_Local_Agent_Token_Record{
		agent_instance_id = "inst_ss_relay",
		instance_token    = "hit_ss_relay",
		role              = .Agent,
	}

	relay := bridge.bridge_local_relay_agent_envelope(bridge.route_path("api", "v1", "agent-actions", "start-success"), "agent.start_success", "{}", rec)
	check(relay.ok, "agent relay must succeed after retrying the 503")
	check(relay.status == 200, "agent relay status must be 200 after retry")
	check(strings.contains(relay.body, "accepted"), "relay body must carry the hub 200 payload")

	fmt.println("PASS: agent-actions relay retries 5xx then 200")
}

// 2. start_success with the hub DOWN (no server listening) must still return an
//    ok:true accepted-locally response, NOT retryable_unavailable. The durable
//    local mark has already been applied; WS status push reconciles the hub.
test_start_success_relay_down_is_accepted_locally :: proc() {
	bridge.bridge_runtime_init()

	// Point at a closed loopback port so every relay attempt fails transport.
	// (Bind+close to get a definitely-unused port, then don't re-listen.)
	listener, port := listen_loopback()
	net.close(listener)

	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", port)
	bridge.bridge_config.bridge_token = "hbr_test"
	rec := bridge.Bridge_Local_Agent_Token_Record{
		agent_instance_id = "inst_ss_down",
		instance_token    = "hit_ss_down",
		role              = .Agent,
	}

	resp := bridge.bridge_local_handle_agent_method("req_ss_down", "agent.start_success", "{}", rec)
	check(strings.contains(resp, "\"ok\":true"), "start_success must be ok:true even when the hub relay is down")
	check(!strings.contains(resp, "retryable_unavailable"), "start_success must NOT surface retryable_unavailable")
	check(!strings.contains(resp, "Hub relay failed"), "start_success must NOT surface 'Hub relay failed'")
	check(strings.contains(resp, "pending_relay_unavailable"), "start_success should mark reconcile pending on relay failure")

	// And the durable local effect must have been applied regardless of relay.
	snap, ok := bridge.bridge_runtime_instance_snapshot("inst_ss_down")
	check(ok, "instance snapshot must exist after start_success")
	check(snap.runtime_status == "running", "start_success must mark the instance running locally")

	fmt.println("PASS: start_success accepted locally when hub relay is down")
}

// 3. start_success with a healthy hub relays through and returns the hub payload.
test_start_success_relay_ok_passthrough :: proc() {
	bridge.bridge_runtime_init()

	listener, port := listen_loopback()
	defer net.close(listener)
	start_seq_server(listener, []Seq_Response{
		{200, "OK", "{\"accepted\":true,\"hub\":true}"},
	})
	time.sleep(20 * time.Millisecond)

	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", port)
	bridge.bridge_config.bridge_token = "hbr_test"
	rec := bridge.Bridge_Local_Agent_Token_Record{
		agent_instance_id = "inst_ss_ok",
		instance_token    = "hit_ss_ok",
		role              = .Agent,
	}

	resp := bridge.bridge_local_handle_agent_method("req_ss_ok", "agent.start_success", "{}", rec)
	check(strings.contains(resp, "\"ok\":true"), "start_success must be ok:true on healthy relay")
	check(strings.contains(resp, "hub"), "start_success must pass through the hub 200 payload")

	fmt.println("PASS: start_success passes through healthy hub relay")
}

@(test)
test_bridge_start_success_relay_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	test_agent_relay_retries_5xx_then_200()
	test_start_success_relay_down_is_accepted_locally()
	test_start_success_relay_ok_passthrough()
	fmt.println("ALL BRIDGE START-SUCCESS RELAY TESTS PASSED")
}
