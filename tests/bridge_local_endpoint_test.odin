package bridge_local_endpoint_test

import "core:fmt"
import "core:testing"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import bridge "odin_test:bridge"

// A tiny loopback "hub" that answers any request with a 200 whose JSON body
// contains `marker`, so context.get relay assertions are deterministic offline.
start_fake_hub :: proc(marker: string) -> int {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, err := net.listen_tcp(endpoint)
	check(err == nil, "fake hub listen failed")
	bound, berr := net.bound_endpoint(listener)
	check(berr == nil, "fake hub bound_endpoint failed")
	thread.create_and_start_with_poly_data2(listener, strings.clone(marker), proc(l: net.TCP_Socket, m: string) {
		for {
			client, _, aerr := net.accept_tcp(l)
			if aerr != nil do return
			buf: [4096]byte
			_, _ = net.recv_tcp(client, buf[:])
			// Build JSON via concat (not tprintf) so literal braces aren't read
			// as format directives.
			body := strings.concatenate({"{\"data\":{\"agent_instance_id\":\"", m, "\"},\"meta\":{}}"})
			resp := strings.concatenate({"HTTP/1.1 200 OK\r\nContent-Length: ", itoa_local(len(body)), "\r\nConnection: close\r\n\r\n", body})
			net.send_tcp(client, transmute([]byte)resp)
			net.close(client)
		}
	})
	return bound.port
}

itoa_local :: proc(n: int) -> string {
	if n == 0 do return "0"
	v := n; buf: [24]byte; i := len(buf)
	for v > 0 { i -= 1; buf[i] = byte('0' + (v % 10)); v /= 10 }
	return strings.clone(string(buf[i:]))
}

@(test)
test_bridge_local_endpoint_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	bridge.bridge_runtime_init()
	bridge.bridge_agent_token_store_init()
	// Point the bridge->hub relay at a local fake hub so envelope relays
	// (e.g. context.get) resolve deterministically without the real dev stack.
	fake_port := start_fake_hub("inst_local")
	time.sleep(20 * time.Millisecond)
	bridge.bridge_config.daemon_url = fmt.tprintf("http://127.0.0.1:%d", fake_port)
	bridge.bridge_config.bridge_token = "hbr_test"
	_ = os.remove_all("/tmp/heimdall-bridge-local-endpoint-test")
	defer _ = os.remove_all("/tmp/heimdall-bridge-local-endpoint-test")
	unix_cfg := bridge.bridge_local_endpoint_config_default("/tmp/heimdall-bridge-local-endpoint-test", 0)
	sock_cstr := strings.clone_to_cstring(unix_cfg.unix_socket_path)
	defer delete(sock_cstr)
	unix_cfg.unix_socket_path = string(sock_cstr)
	check(bridge.bridge_local_endpoint_env_value(unix_cfg, true) == "unix:/tmp/heimdall-bridge-local-endpoint-test/bridge.sock", "unix endpoint env must use run_dir bridge.sock")
	check(bridge.bridge_local_endpoint_start_unix(unix_cfg), "unix socket endpoint must start with owner-only mode")
	issued := bridge.bridge_agent_token_issue("inst_local", "hit_bridge_held", .Agent)
	check(strings.has_prefix(issued.plaintext_token, "hlat_"), "local token prefix missing")
	rec, ok := bridge.bridge_agent_token_verify(issued.plaintext_token)
	check(ok && rec.agent_instance_id == "inst_local" && rec.instance_token == "hit_bridge_held", "local token verify must resolve instance and Bridge-held instance token")
	check(!strings.contains(rec.token_hash, issued.plaintext_token) && strings.has_prefix(rec.token_hash, "sha1:"), "local token must be hashed at rest")
	check(bridge.bridge_local_method_allowed("agent.chat.send", .Agent), "agent allowlist missing chat.send")
	check(!bridge.bridge_local_method_allowed("wrapper.exited", .Agent), "agent token must not call wrapper methods")
	check(bridge.bridge_local_method_allowed("wrapper.startup.report", .Wrapper), "wrapper allowlist missing startup")
	check(!bridge.bridge_local_method_allowed("agent.task.comment", .Wrapper), "wrapper token must not call agent methods")
	// Agent API v2: instance lifecycle verbs (agents launching/starting/stopping
	// agents they own) must be on the .Agent allow-list and off the .Wrapper one.
	check(bridge.bridge_local_method_allowed("agent.agents.new_instance", .Agent), "agent allowlist missing agents.new_instance")
	check(bridge.bridge_local_method_allowed("agent.agents.instance_start", .Agent), "agent allowlist missing agents.instance_start")
	check(bridge.bridge_local_method_allowed("agent.agents.instance_restart", .Agent), "agent allowlist missing agents.instance_restart")
	check(bridge.bridge_local_method_allowed("agent.agents.instance_stop", .Agent), "agent allowlist missing agents.instance_stop")
	check(!bridge.bridge_local_method_allowed("agent.agents.new_instance", .Wrapper), "wrapper token must not launch instances")
	// Unified route table: new_instance -> POST /agent-instances (send body);
	// start/restart/stop -> /<id>/{start,restart,stop}.
	r_new := bridge.bridge_agent_route("agent.agents.new_instance", "{\"agent_id\":\"agt_x\"}")
	check(r_new.kind == .Raw && r_new.http_method == "POST" && r_new.path == "/api/v1/agent-instances" && r_new.send_body, "new_instance -> POST /api/v1/agent-instances (body)")
	r_start := bridge.bridge_agent_route("agent.agents.instance_start", "{\"instance_id\":\"inst_z\"}")
	check(r_start.kind == .Raw && r_start.path == "/api/v1/agent-instances/inst_z/start", "instance_start -> /<id>/start")
	r_restart := bridge.bridge_agent_route("agent.agents.instance_restart", "{\"instance_id\":\"inst_z\"}")
	check(r_restart.kind == .Raw && r_restart.path == "/api/v1/agent-instances/inst_z/restart", "instance_restart -> /<id>/restart")
	r_stop := bridge.bridge_agent_route("agent.agents.instance_stop", "{\"agent_instance_id\":\"inst_z\"}")
	check(r_stop.kind == .Raw && r_stop.path == "/api/v1/agent-instances/inst_z/stop" && r_stop.send_body, "instance_stop -> /<id>/stop (body, accepts agent_instance_id)")
	r_start_bad := bridge.bridge_agent_route("agent.agents.instance_start", "{}")
	check(r_start_bad.kind == .Unknown, "instance_start without an instance id must be Unknown (rejected)")
	// Discovery verbs: allowlist (.Agent only) + route table mapping.
	check(bridge.bridge_local_method_allowed("agent.agents.list", .Agent), "agent allowlist missing agents.list")
	check(bridge.bridge_local_method_allowed("agent.agents.template_create", .Agent), "agent allowlist missing agents.template_create")
	check(bridge.bridge_local_method_allowed("agent.bridge.list", .Agent), "agent allowlist missing bridge.list")
	check(bridge.bridge_local_method_allowed("agent.bridge.providers", .Agent), "agent allowlist missing bridge.providers")
	check(!bridge.bridge_local_method_allowed("agent.agents.create", .Wrapper), "wrapper token must not create agents")
	check(!bridge.bridge_local_method_allowed("agent.agents.template_list", .Wrapper), "wrapper token must not list templates")
	r_agents := bridge.bridge_agent_route("agent.agents.list", "{}")
	check(r_agents.kind == .Raw && r_agents.http_method == "GET" && r_agents.path == "/api/v1/agents", "agents.list -> GET /api/v1/agents")
	r_agents_create := bridge.bridge_agent_route("agent.agents.create", "{}")
	check(r_agents_create.kind == .Raw && r_agents_create.http_method == "POST" && r_agents_create.path == "/api/v1/agents" && r_agents_create.send_body, "agents.create -> POST /api/v1/agents (body)")
	r_tmpl := bridge.bridge_agent_route("agent.agents.template_list", "{}")
	check(r_tmpl.kind == .Raw && r_tmpl.path == "/api/v1/templates", "template_list -> GET /api/v1/templates")
	r_bridge := bridge.bridge_agent_route("agent.bridge.list", "{}")
	check(r_bridge.kind == .Local && r_bridge.local_op == "bridge.list", "bridge.list -> Local op")
	r_prov := bridge.bridge_agent_route("agent.bridge.providers", "{\"bridge_id\":\"brg_x\"}")
	check(r_prov.kind == .Raw && r_prov.path == "/api/v1/bridges/brg_x/providers", "bridge.providers -> /bridges/<id>/providers")
	r_chat_user := bridge.bridge_agent_route("agent.chat.send", "{\"to\":\"user\",\"body\":\"hi\"}")
	check(r_chat_user.kind == .Envelope && r_chat_user.path == "/api/v1/agent-actions/chat/send-to-user", "chat.send to=user -> send-to-user")
	r_chat_agent := bridge.bridge_agent_route("agent.chat.send", "{\"to\":\"inst_reviewer\",\"body\":\"hi\"}")
	check(r_chat_agent.kind == .Envelope && r_chat_agent.path == "/api/v1/agent-actions/chat/send-to-agent", "chat.send to=<instance-id> -> send-to-agent")
	r_chat_bad := bridge.bridge_agent_route("agent.chat.send", "{\"body\":\"hi\"}")
	check(r_chat_bad.kind == .Bad_Request && r_chat_bad.message != "", "chat.send without to must be Bad_Request with a message")
	// task-chain: show defaults to the caller's chain via envelope (no context fallback);
	// set-description is an envelope; the removed Task System v2 verbs are Unknown.
	r_chain_show := bridge.bridge_agent_route("agent.task_chain.show", "{}")
	check(r_chain_show.kind == .Envelope && r_chain_show.path == "/api/v1/agent-actions/chain/show", "task_chain.show (no id) -> chain/show envelope, not context")
	r_chain_desc := bridge.bridge_agent_route("agent.task_chain.set_description", "{\"description\":\"x\"}")
	check(r_chain_desc.kind == .Envelope && r_chain_desc.path == "/api/v1/agent-actions/chain/set-description", "task_chain.set_description -> chain/set-description envelope")
	r_removed := bridge.bridge_agent_route("agent.task.status", "{\"task_id\":\"task_x\",\"status\":\"in_progress\"}")
	check(r_removed.kind == .Unknown, "task.status was removed in Task System v2 -> Unknown route")
	// task show/list/comments resolve by task_id alone (envelopes).
	r_task_show := bridge.bridge_agent_route("agent.task.show", "{\"task_id\":\"task_x\"}")
	check(r_task_show.kind == .Envelope && r_task_show.path == "/api/v1/agent-actions/tasks/show", "task.show -> tasks/show envelope (no chain needed)")
	r_unknown := bridge.bridge_agent_route("agent.nope", "{}")
	check(r_unknown.kind == .Unknown, "unknown method must map to Unknown route")
	// Spoof-guard still blocks owner/token fields on a create body.
	admin_spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"admin_spoof\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.agents.create\",\"params\":{\"name\":\"x\",\"owner_user_id\":\"usr_other\"}}"}))
	check(strings.contains(admin_spoof, "\"ok\":false") && strings.contains(admin_spoof, "forbidden"), "admin verbs must not let callers spoof owner_user_id")
	// F2: with no hub runtime session the bridge refuses to relay (nothing is sent);
	// the mock hub below stands in for an established session.
	down := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"down\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.context.get\",\"params\":{}}"}))
	check(strings.contains(down, "hub_unreachable"), "relay refused while the hub runtime is down")
	bridge.bridge_hub_runtime_up = true
	defer bridge.bridge_hub_runtime_up = false
	ctx := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"ctx\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.context.get\",\"params\":{}}"}))
	check(strings.contains(ctx, "\"ok\":true") && strings.contains(ctx, "inst_local") && !strings.contains(ctx, "MISSING"), "context.get should resolve identity and return valid JSON")
	spaced_ctx := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{ \"v\" : 1, \"id\" : \"spaced\", \"token\" : \"", issued.plaintext_token, "\", \"method\" : \"agent.context.get\", \"params\" : { } }"}))
	check(strings.contains(spaced_ctx, "\"id\":\"spaced\"") && strings.contains(spaced_ctx, "\"ok\":true") && strings.contains(spaced_ctx, "inst_local"), "JSONL request parsing must accept normal whitespace")
	spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"spoof\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"wrapper.exited\",\"params\":{}}"}))
	check(strings.contains(spoof, "\"ok\":false") && strings.contains(spoof, "forbidden"), "local callers cannot cross role allowlists")
	identity_spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"spoof_identity\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.chat.send\",\"params\":{\"to\":\"user\",\"body\":\"bad\",\"sender_agent_instance_id\":\"inst_other\"}}"}))
	check(strings.contains(identity_spoof, "\"ok\":false") && strings.contains(identity_spoof, "forbidden"), "local callers cannot spoof sender identity")
	rotated, rotated_ok := bridge.bridge_agent_token_rotate(issued.plaintext_token)
	check(rotated_ok && rotated.plaintext_token != issued.plaintext_token, "rotation must issue a replacement token")
	_, old_ok := bridge.bridge_agent_token_verify(issued.plaintext_token)
	_, new_ok := bridge.bridge_agent_token_verify(rotated.plaintext_token)
	check(!old_ok && new_ok, "rotation must invalidate old token and verify new token")
	check(bridge.bridge_agent_token_invalidate(rotated.plaintext_token), "invalidate should accept active token")
	_, invalid_ok := bridge.bridge_agent_token_verify(rotated.plaintext_token)
	check(!invalid_ok, "invalidated token must fail verify")
	fmt.println("PASS: bridge local endpoint/token store")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
