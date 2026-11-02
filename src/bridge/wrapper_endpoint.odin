package main

import local_socket "odin_test:lib/local_socket"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:encoding/json"
import httpc "odin_test:lib/httpc"
import jsonx "odin_test:lib/jsonx"

Bridge_Local_Endpoint_Config :: struct {
	// Primary v1 transport is unix:${run_dir}/bridge.sock. The current portable
	// implementation exposes the same JSONL contract over loopback TCP as the
	// fallback while keeping the endpoint descriptor/permission invariant explicit
	// for wrapper launch materialization.
	unix_socket_path: string,
	loopback_host: string,
	loopback_port: u16,
}

Bridge_Local_Relay_Result :: struct {
	status: int,
	body: string,
	ok: bool,
}

Bridge_Wrapper_Push_Conn_Kind :: enum { TCP, Unix }
Bridge_Wrapper_Push_Conn :: struct { agent_instance_id: string, kind: Bridge_Wrapper_Push_Conn_Kind, tcp: net.TCP_Socket, unix: local_socket.Socket }
bridge_wrapper_push_mutex: sync.Mutex
bridge_wrapper_push_conns: [dynamic]Bridge_Wrapper_Push_Conn

bridge_local_endpoint_config_default :: proc(run_dir: string, loopback_port: u16) -> Bridge_Local_Endpoint_Config {
	path := strings.concatenate({strings.trim_right(run_dir, "/"), "/bridge.sock"})
	defer delete(path)
	return Bridge_Local_Endpoint_Config{
		unix_socket_path = bridge_unix_socket_bounded_path(path),
		loopback_host = "127.0.0.1",
		loopback_port = loopback_port,
	}
}

bridge_local_endpoint_env_value :: proc(config: Bridge_Local_Endpoint_Config, prefer_unix := true) -> string {
	if prefer_unix && strings.trim_space(config.unix_socket_path) != "" do return strings.concatenate({"unix:", config.unix_socket_path})
	return fmt.tprintf("tcp:%s:%d", config.loopback_host, config.loopback_port)
}

bridge_local_endpoint_prepare_unix_socket_path :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	// Unix socket file mode invariant: 0600 owner-only before wrapper/agent env handoff.
	if strings.trim_space(config.unix_socket_path) == "" do return false
	return bridge_unix_socket_prepare_parent(config.unix_socket_path)
}

bridge_local_endpoint_start_unix :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	if !bridge_local_endpoint_prepare_unix_socket_path(config) do return false
	path := strings.trim_space(config.unix_socket_path)
	// Replaces a stale socket file; 0600 owner-only local Bridge socket on Unix.
	fd, ok := local_socket.listen(path, 16)
	if !ok do return false
	if !bridge_os_socket_close_on_exec(i64(fd)) {
		local_socket.close(fd)
		return false
	}
	thread.run_with_poly_data(fd, bridge_local_endpoint_accept_unix_loop)
	return true
}

bridge_local_endpoint_start_loopback :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	address := net.IP4_Loopback
	listener, err := net.listen_tcp({address, int(config.loopback_port)})
	if err != nil do return false
	if !bridge_os_socket_close_on_exec(i64(listener)) {
		net.close(listener)
		return false
	}
	thread.run_with_poly_data(listener, bridge_local_endpoint_accept_loop)
	return true
}

bridge_local_endpoint_accept_unix_loop :: proc(listener: local_socket.Socket) {
	for {
		client, ok := local_socket.accept(listener)
		if !ok do continue
		thread.run_with_poly_data(client, bridge_local_endpoint_unix_client_thread)
	}
}

bridge_local_endpoint_unix_client_thread :: proc(client: local_socket.Socket) {
	registered_instance := ""
	// REQ-XM-4: see bridge_local_endpoint_client_thread — the proxy path takes
	// ownership of the socket and closes it itself.
	proxy_owned := false
	first_line := true
	defer {
		if registered_instance != "" do bridge_wrapper_push_drop(registered_instance)
		if !proxy_owned do local_socket.close(client)
	}
	buf: [8192]byte
	pending := ""
	for {
		n := local_socket.recv(client, buf[:])
		if n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:n])})
		// REQ-XM-4: same first-line HTTP demultiplex as the loopback listener.
		if first_line {
			if idx := strings.index_byte(pending, '\n'); idx >= 0 {
				first_line_str := strings.trim_space(pending[:idx])
				if bridge_telemetry_looks_like_agents_count(first_line_str) {
					resp := bridge_telemetry_agents_count_http_response()
					defer delete(resp)
					bytes := transmute([]byte)resp
					_ = local_socket.send(client, bytes)
					return
				}
				if bridge_telemetry_looks_like_processes(first_line_str) {
					resp := bridge_telemetry_processes_http_response()
					defer delete(resp)
					bytes := transmute([]byte)resp
					_ = local_socket.send(client, bytes)
					return
				}
				if bridge_config.local_proxy_enabled && bridge_proxy_looks_like_http(first_line_str) {
					bridge_local_proxy_serve_unix(client, pending)
					proxy_owned = true
					return
				}
				first_line = false
			}
		}
		for {
			idx := strings.index_byte(pending, '\n')
			if idx < 0 do break
			line := strings.trim_space(pending[:idx])
			pending = pending[idx + 1:]
			if line == "" do continue
			if inst, sub_ok := bridge_local_subscribe_instance(line); sub_ok { registered_instance = inst; bridge_wrapper_push_register_unix(inst, client) }
			resp := bridge_local_endpoint_handle_jsonl_line(line)
			defer delete(resp)
			resp_line := strings.concatenate({resp, "\n"})
			defer delete(resp_line)
			bytes := transmute([]byte)resp_line
			_ = local_socket.send(client, bytes)
		}
	}
}

bridge_local_endpoint_accept_loop :: proc(listener: net.TCP_Socket) {
	for {
		client, _, err := net.accept_tcp(listener)
		if err != nil do continue
		thread.run_with_poly_data(client, bridge_local_endpoint_client_thread)
	}
}

bridge_local_endpoint_client_thread :: proc(client: net.TCP_Socket) {
	registered_instance := ""
	// REQ-XM-4: once the proxy path takes the socket it owns its lifetime (the
	// response streams back asynchronously via proxy_data), so this thread must
	// NOT close it on the way out.
	proxy_owned := false
	first_line := true
	defer {
		if registered_instance != "" do bridge_wrapper_push_drop(registered_instance)
		if !proxy_owned do net.close(client)
	}
	buf: [8192]byte
	pending := ""
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:n])})
		// REQ-XM-4: demultiplex HTTP from JSONL on the first line only. An HTTP
		// request line means this is a /proxy/<session_id>/<path> call, which owns
		// the socket for the rest of its life; anything else is the JSONL protocol
		// and falls through completely unchanged.
		if first_line {
			if idx := strings.index_byte(pending, '\n'); idx >= 0 {
				first_line_str := strings.trim_space(pending[:idx])
				if bridge_telemetry_looks_like_agents_count(first_line_str) {
					resp := bridge_telemetry_agents_count_http_response()
					defer delete(resp)
					_, _ = net.send_tcp(client, transmute([]byte)resp)
					return
				}
				if bridge_telemetry_looks_like_processes(first_line_str) {
					resp := bridge_telemetry_processes_http_response()
					defer delete(resp)
					_, _ = net.send_tcp(client, transmute([]byte)resp)
					return
				}
				if bridge_config.local_proxy_enabled && bridge_proxy_looks_like_http(first_line_str) {
					bridge_local_proxy_serve_tcp(client, pending)
					proxy_owned = true
					return
				}
				first_line = false
			}
		}
		for {
			idx := strings.index_byte(pending, '\n')
			if idx < 0 do break
			line := strings.trim_space(pending[:idx])
			pending = pending[idx + 1:]
			if line == "" do continue
			if inst, sub_ok := bridge_local_subscribe_instance(line); sub_ok { registered_instance = inst; bridge_wrapper_push_register_tcp(inst, client) }
			resp := bridge_local_endpoint_handle_jsonl_line(line)
			defer delete(resp)
			resp_line := strings.concatenate({resp, "\n"})
			defer delete(resp_line)
			_, _ = net.send_tcp(client, transmute([]byte)resp_line)
		}
	}
}

bridge_local_endpoint_handle_jsonl_line :: proc(line: string) -> string {
	request_id := bridge_local_extract_json_string(line, "id", "")
	if bridge_local_extract_json_int(line, "v", 0) != 1 do return bridge_local_response_error(request_id, "bad_version", "local endpoint protocol version must be 1")
	token := bridge_local_extract_json_string(line, "token", "")
	method := bridge_local_extract_json_string(line, "method", "")
	params := bridge_local_extract_json_object(line, "params")
	if bridge_local_spoofable_params(params) do return bridge_local_response_error(request_id, "forbidden", "local callers cannot spoof owner, sender, instance, or Hub credentials")
	rec, ok := bridge_agent_token_verify(token)
	if !ok do return bridge_local_response_error(request_id, "unauthenticated", "local agent token is invalid or rotated")
	if !bridge_local_method_allowed(method, rec.role) do return bridge_local_response_error(request_id, "forbidden", "method is not allowed for this local token role")
	if strings.has_prefix(method, "wrapper.") do return bridge_local_handle_wrapper_method(request_id, method, params, rec)
	if strings.has_prefix(method, "agent.") do return bridge_local_handle_agent_method(request_id, method, params, rec)
	return bridge_local_response_error(request_id, "forbidden", "method is not allowlisted")
}

bridge_local_spoofable_params :: proc(params: string) -> bool {
	// Identity/credential fields a local caller must never set: the bridge injects
	// the caller's REAL identity from its verified token, and every agent-action
	// handler derives the acting instance from that token (inst.agent_instance_id),
	// never from the request body. So these keys in the payload are spoof attempts.
	//
	// NOTE: "agent_instance_id" is intentionally NOT blocked. It is required inside
	// task targeting fields (legacy assignee_ref / reviewer_refs objects) to point at OTHER agents,
	// and the hub never treats a body-level agent_instance_id as the acting
	// identity (that always comes from the token). The genuine spoofing vector is
	// "sender_agent_instance_id"/"owner_user_id"/credentials, which stay blocked.
	blocked := [?]string{"owner_user_id", "sender_agent_instance_id", "hub_url", "Authorization", "authorization", "hub_token", "bridge_token", "token", "access_token"}
	for key in blocked {
		if strings.contains(params, strings.concatenate({"\"", key, "\""})) do return true
	}
	return false
}

bridge_local_subscribe_instance :: proc(line: string) -> (string, bool) {
	if bridge_local_extract_json_string(line, "method", "") != "wrapper.notifications.subscribe" do return "", false
	if bridge_local_extract_json_int(line, "v", 0) != 1 do return "", false
	params := bridge_local_extract_json_object(line, "params")
	if bridge_local_spoofable_params(params) do return "", false
	token := bridge_local_extract_json_string(line, "token", "")
	rec, ok := bridge_agent_token_verify(token)
	if !ok || rec.role != .Wrapper do return "", false
	return rec.agent_instance_id, rec.agent_instance_id != ""
}

bridge_wrapper_push_register_tcp :: proc(instance_id: string, socket: net.TCP_Socket) { bridge_wrapper_push_register(Bridge_Wrapper_Push_Conn{agent_instance_id=strings.clone(instance_id),kind=.TCP,tcp=socket}) }
bridge_wrapper_push_register_unix :: proc(instance_id: string, socket: local_socket.Socket) { bridge_wrapper_push_register(Bridge_Wrapper_Push_Conn{agent_instance_id=strings.clone(instance_id),kind=.Unix,unix=socket}) }
bridge_wrapper_push_register :: proc(conn: Bridge_Wrapper_Push_Conn) {
	if bridge_wrapper_push_conns == nil do bridge_wrapper_push_conns = make([dynamic]Bridge_Wrapper_Push_Conn)
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) { if bridge_wrapper_push_conns[i].agent_instance_id == conn.agent_instance_id { bridge_wrapper_push_conns[i] = conn; return } }
	append(&bridge_wrapper_push_conns, conn)
}
bridge_wrapper_push_drop :: proc(instance_id: string) {
	if bridge_wrapper_push_conns == nil do return
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) { if bridge_wrapper_push_conns[i].agent_instance_id == instance_id { unordered_remove(&bridge_wrapper_push_conns, i); return } }
}
bridge_wrapper_push :: proc(instance_id, json_payload: string) -> bool {
	return bridge_wrapper_push_line(instance_id, strings.concatenate({"{\"push\":\"agent_message\",\"payload\":", json_payload, "}\n"}))
}

bridge_wrapper_push_task_nudge :: proc(instance_id, json_payload: string) -> bool {
	return bridge_wrapper_push_line(instance_id, strings.concatenate({"{\"push\":\"task_nudge\",\"payload\":", json_payload, "}\n"}))
}

bridge_wrapper_push_title_nudge :: proc(instance_id, json_payload: string) -> bool {
	return bridge_wrapper_push_line(instance_id, strings.concatenate({"{\"push\":\"title_nudge\",\"payload\":", json_payload, "}\n"}))
}

bridge_wrapper_push_startup_prompt :: proc(instance_id: string) -> bool {
	return bridge_wrapper_push_line(instance_id, "{\"push\":\"startup_prompt\"}\n")
}

bridge_wrapper_push_line :: proc(instance_id, line: string) -> bool {
	if bridge_wrapper_push_conns == nil do return false
	bytes := transmute([]byte)line
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) {
		if bridge_wrapper_push_conns[i].agent_instance_id != instance_id do continue
		ok := false
		if bridge_wrapper_push_conns[i].kind == .TCP { _, err := net.send_tcp(bridge_wrapper_push_conns[i].tcp, bytes); ok = err == nil } else { ok = local_socket.send(bridge_wrapper_push_conns[i].unix, bytes) >= 0 }
		if !ok { unordered_remove(&bridge_wrapper_push_conns, i); return false }
		return true
	}
	return false
}

bridge_local_method_allowed :: proc(method: string, role: Bridge_Local_Token_Role) -> bool {
	switch role {
	case .Wrapper:
		return method == "wrapper.startup.report" || method == "wrapper.activity.report" || method == "wrapper.liveness.ping" || method == "wrapper.exited" || method == "wrapper.notifications.subscribe" || method == "wrapper.pane_capture.result" || method == "wrapper.bootstrap.list" || method == "wrapper.bootstrap.file"
	case .Agent:
		// Agent API v2: a single allowlist driven by the unified route table
		// (see agent_api.odin). No more 400-char `||` chain.
		return bridge_agent_method_allowed(method)
	}
	return false
}

bridge_local_handle_wrapper_method :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if method == "wrapper.startup.report" {
		phase := bridge_local_extract_json_string(params, "phase", "startup_unknown")
		pane_id := bridge_local_extract_json_string(params, "pane_id", "")
		if pane_id != "" do bridge_runtime_update_launch_pane(rec.agent_instance_id, pane_id)
		runtime := "starting"
		// Wrapper "ready" only means the child process was launched. The agent is
		// not running from Heimdall's perspective until explicit start-success.
		if phase == "startup_failed" do runtime = "failed"
		// A startup probe that classifies the pane as blocked (e.g. an interactive
		// prompt the wrapper could not auto-dismiss) surfaces as a distinct "blocked"
		// runtime state: active-but-not-ready, so it neither expires as stale nor
		// counts as ready. It is projected to startup_status "startup_blocked" upstream.
		if phase == "startup_blocked" do runtime = "blocked"
		if runtime == "starting" { bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle") } else { bridge_runtime_set_status(rec.agent_instance_id, runtime, "idle") }
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.activity.report" {
		activity := bridge_local_extract_json_string(params, "status", "idle")
		// Optional source: the wrapper's harness-agnostic pane detector reports
		// source="pane_diff", which ranks above the plain wrapper heartbeat but below a
		// native agent extension. Absent/blank source keeps the legacy "wrapper" rank.
		source := bridge_local_extract_json_string(params, "source", "")
		if strings.trim_space(source) == "" {
			bridge_runtime_note_wrapper_signal(rec.agent_instance_id, activity)
		} else {
			bridge_runtime_note_agent_activity(rec.agent_instance_id, activity, source)
		}
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.liveness.ping" {
		bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle")
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.exited" {
		bridge_runtime_set_status(rec.agent_instance_id, "stopped", "idle")
		bridge_wrapper_push_drop(rec.agent_instance_id)
		bridge_runtime_remove_launch(rec.agent_instance_id)
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.notifications.subscribe" {
		// Subscription itself is a live signal. This is the bridge-restart recovery
		// path: a ham-wrapper that outlived the bridge can reconnect with its
		// persisted wrapper token and rehydrate bridge runtime state before the next
		// liveness tick, without implying start-success.
		bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle")
		return bridge_local_response_data(request_id, "{\"accepted\":true,\"subscribed\":true}")
	}
	if method == "wrapper.bootstrap.list" {
		// List the finished bootstrap files for THIS wrapper's instance. The
		// instance identity comes from the authenticated wrapper token, never from
		// params (spoof-guarded upstream), so there is no instance_id argument.
		list_json, ok := bridge_bootstrap_fileset_list_json(rec.agent_instance_id)
		if !ok do return bridge_local_response_error(request_id, "not_found", "no bootstrap file set is published for this instance")
		return bridge_local_response_data(request_id, list_json)
	}
	if method == "wrapper.bootstrap.file" {
		// Return one finished file (content included) by file_id for THIS wrapper's
		// instance.
		file_id := bridge_local_extract_json_string(params, "file_id", "")
		if strings.trim_space(file_id) == "" do return bridge_local_response_error(request_id, "bad_request", "file_id is required")
		file_json, ok := bridge_bootstrap_fileset_file_json(rec.agent_instance_id, file_id)
		if !ok do return bridge_local_response_error(request_id, "not_found", "unknown bootstrap file_id for this instance")
		return bridge_local_response_data(request_id, file_json)
	}
	if method == "wrapper.pane_capture.result" {
		command_id := bridge_local_extract_json_string(params,"command_id","")
		req_id := bridge_local_extract_json_string(params,"pane_capture_request_id","")
		pending,pending_ok := bridge_pane_capture_remove_pending(command_id, req_id)
		if !pending_ok do return bridge_local_response_error(request_id,"not_found","pane capture request is no longer pending")
		ok := strings.contains(params,"\"ok\":true")
		line_count := bridge_local_extract_json_int(params,"line_count",0)
		truncated := strings.contains(params,"\"truncated\":true")
		if ok {
			output := bridge_local_extract_json_string(params,"output","")
			bridge_pane_capture_enqueue_result(bridge_pane_capture_result_json(pending,true,"","",output,line_count,truncated), command_id)
		} else {
			error_code := bridge_local_extract_json_string(params,"error_code","capture_failed")
			message := bridge_local_extract_json_string(params,"message","")
			bridge_pane_capture_enqueue_result(bridge_pane_capture_result_json(pending,false,error_code,message,"",line_count,truncated), command_id)
		}
		return bridge_local_response_data(request_id,"{\"accepted\":true}")
	}
	return bridge_local_response_error(request_id, "forbidden", "wrapper method is not allowlisted")
}

bridge_local_handle_agent_method :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	bridge_runtime_touch_liveness(rec.agent_instance_id)
	if method == "agent.activity.report" {
		activity := bridge_local_extract_json_string(params, "status", "unknown")
		source := bridge_local_extract_json_string(params, "source", "agent_extension")
		bridge_runtime_note_agent_activity(rec.agent_instance_id, activity, source)
		if inst, got := bridge_runtime_instance_snapshot(rec.agent_instance_id); got {
			b := strings.builder_make()
			strings.write_string(&b, "{\"accepted\":true,\"agent_instance_id\":\""); bridge_runtime_write_json_string(&b, inst.agent_instance_id)
			strings.write_string(&b, "\",\"runtime_status\":\""); bridge_runtime_write_json_string(&b, inst.runtime_status)
			strings.write_string(&b, "\",\"activity_status\":\""); bridge_runtime_write_json_string(&b, inst.activity_status)
			strings.write_string(&b, "\",\"activity_source\":\""); bridge_runtime_write_json_string(&b, inst.activity_source)
			strings.write_string(&b, "\",\"state_seq\":"); strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
			strings.write_string(&b, "}")
			return bridge_local_response_data(request_id, strings.to_string(b))
		}
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "agent.extension.event" || method == "agent.extension.status" {
		// ham.ext.v1 ingest: identity is rec (token-verified), never the payload.
		return bridge_ext_handle_rpc(request_id, method, params, rec)
	}
	if method == "agent.extension.permission.cancel" {
		return bridge_ext_permission_cancel_rpc(request_id, params, rec)
	}
	if method == "agent.extension.permission" {
		// Blocking: relays a ham.ext.v1 permission.request to the hub and waits for
		// the user's allow/deny; "none" on timeout (the provider prompts in its TUI).
		return bridge_ext_permission_handle_rpc(request_id, params, rec)
	}
	if method == "agent.permission.request" {
		// Blocking: registers the request, mirrors it to the wrapper/UI push channel,
		// and waits for a decision (or fail-safe deny on timeout).
		decision, reason := bridge_permission_handle_request(rec.agent_instance_id, params)
		b := strings.builder_make()
		strings.write_string(&b, "{\"request_id\":\""); bridge_local_write_json_string(&b, bridge_local_extract_json_string(params, "request_id", ""))
		strings.write_string(&b, "\",\"decision\":\""); bridge_local_write_json_string(&b, decision)
		strings.write_string(&b, "\",\"reason\":\""); bridge_local_write_json_string(&b, reason)
		strings.write_string(&b, "\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	if method == "agent.permission.reply" {
		// Local resolution path: a wrapper/UI at the TTY answers an outstanding
		// permission request for this instance. Resolves any waiting request.request.
		req_id := bridge_local_extract_json_string(params, "request_id", "")
		decision := bridge_local_extract_json_string(params, "decision", "deny")
		reason := bridge_local_extract_json_string(params, "reason", "")
		resolved := bridge_permission_resolve(rec.agent_instance_id, req_id, decision, reason)
		b := strings.builder_make()
		strings.write_string(&b, "{\"accepted\":"); strings.write_string(&b, "true" if resolved else "false")
		strings.write_string(&b, ",\"request_id\":\""); bridge_local_write_json_string(&b, req_id)
		strings.write_string(&b, "\"}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	if method == "agent.rest.request" {
		if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
		relay := bridge_local_relay_rest_request(params, rec)
		if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub REST relay failed")
		if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
		if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
		return bridge_local_response_data(request_id, relay.body)
	}
	if method == "agent.start_success" {
		accepted, _ := bridge_startup_accept(rec, bridge_runtime_now_ms())
		if !accepted do return bridge_local_response_error(request_id, "stale_launch", "Startup signal does not belong to an active launch")
		bridge_startup_worker_ensure_started()
		key := bridge_startup_receipt_key(rec)
        defer delete(key)
        budget := bridge_retry_status(key)
        if budget.state == .Waiting_Repair || budget.state == .Exhausted || budget.state == .Cancelled {
            return bridge_local_response_error(request_id, "startup_reconciliation_stopped", fmt.tprintf("Startup reconciliation %v after %d attempts (code=%v class=%v)", budget.state, budget.attempts, budget.code, budget.class))
        }
        return bridge_local_response_data(request_id, fmt.tprintf("{{\"accepted\":true,\"reconcile\":\"%v\",\"attempts\":%d}}", budget.state, budget.attempts))
	}

	// Agent API v2: everything else resolves through the single route table.
	route := bridge_agent_route(method, params)
	if route.kind == .Local {
		return bridge_local_handle_agent_local_op(request_id, route.local_op, params, rec)
	}
	if route.kind == .Envelope {
		if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
		if !sync.atomic_load(&bridge_hub_runtime_up) do return bridge_local_response_error(request_id, "hub_unreachable", "Hub is unreachable; the request was not sent")
		eff_params := bridge_agent_rewrite_params(method, params)
		relay := bridge_local_relay_agent_envelope(route.path, method, eff_params, rec)
		if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
		if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
		if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
		return bridge_local_response_data(request_id, relay.body)
	}
	if route.kind == .Raw {
		if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
		if !sync.atomic_load(&bridge_hub_runtime_up) do return bridge_local_response_error(request_id, "hub_unreachable", "Hub is unreachable; the request was not sent")
		body := ""
		if route.send_body { body = strings.trim_space(params); if body == "" do body = "{}" }
		relay := bridge_local_relay_raw(route.http_method, route.path, route.query, body, rec)
		if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
		if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
		if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
		return bridge_local_response_data(request_id, relay.body)
	}
	if route.kind == .Bad_Request {
		// Method is known but required params are missing — return the specific
		// "which params are needed" message instead of a confusing wrong-shape body.
		return bridge_local_response_error(request_id, "bad_request", route.message)
	}
	// .Unknown: method not in the allowlist.
	return bridge_local_response_error(request_id, "bad_request", strings.concatenate({"unknown or malformed agent method: ", method}))
}

// bridge_local_relay_agent_envelope wraps params in the agent-actions envelope
// {method, agent_instance_id, params} and POSTs it, with AC-5 retry. params must
// be a JSON object (or empty): it is parsed, never spliced, so an agent cannot
// smuggle extra envelope keys into the request.
bridge_local_relay_agent_envelope :: proc(path: []string, method, params: string, rec: Bridge_Local_Agent_Token_Record, timeout_ms: int = httpc.LONG_TRANSFER_TIMEOUT_MS) -> Bridge_Local_Relay_Result {
	envelope, valid := bridge_local_agent_relay_envelope(method, params, rec.agent_instance_id)
	if !valid do return bridge_local_relay_invalid_params()
	credential := bridge_credential_snapshot()
	defer delete(credential)
	headers := [?]httpc.Header{httpc.bearer(credential), {name = "X-Heimdall-Instance-Token", value = rec.instance_token}}
	resp, err := bridge_http_request_retry({
		method = .POST, url = bridge_hub_url(), path = path, headers = headers[:],
		body = httpc.json_body(envelope), timeout_ms = timeout_ms,
		connect_timeout_ms = httpc.DEFAULT_TIMEOUT_MS, stall_timeout_ms = httpc.DEFAULT_STALL_TIMEOUT_MS,
	})
	defer httpc.response_destroy(&resp)
	return bridge_local_relay_result(resp, err)
}

// bridge_local_relay_raw issues a direct REST call with the instance token
// header, with AC-5 retry. body is the agent's own JSON params, forwarded
// verbatim for writes ("" = no body).
bridge_local_relay_raw :: proc(http_method: httpc.Method, path: []string, query: []httpc.Query_Param, body: string, rec: Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
	credential := bridge_credential_snapshot()
	defer delete(credential)
	headers := [?]httpc.Header{httpc.bearer(credential), {name = "X-Heimdall-Instance-Token", value = rec.instance_token}}
	req := httpc.Request{
		method = http_method, url = bridge_hub_url(), path = path, query = query, headers = headers[:],
		timeout_ms = httpc.LONG_TRANSFER_TIMEOUT_MS, connect_timeout_ms = httpc.DEFAULT_TIMEOUT_MS,
		stall_timeout_ms = httpc.DEFAULT_STALL_TIMEOUT_MS,
	}
	if body != "" do req.body = httpc.relay_json_body(body)
	resp, err := bridge_http_request_retry(req)
	defer httpc.response_destroy(&resp)
	return bridge_local_relay_result(resp, err)
}

// bridge_local_relay_rest_request forwards agent.rest.request: the agent names
// an HTTP method, an origin-form hub target ("/api/v1/...?...") and an optional
// JSON body. The target is validated by httpc (relay_target) and resolved under
// the hub base URL; it is never concatenated here.
bridge_local_relay_rest_request :: proc(params: string, rec: Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
	http_method := bridge_local_extract_json_string(params, "http_method", "")
	if http_method == "" do http_method = bridge_local_extract_json_string(params, "method", "POST")
	method, method_ok := httpc.method_parse(http_method)
	if !method_ok do return Bridge_Local_Relay_Result{status = 0, ok = false}
	path := bridge_local_extract_json_string(params, "path", "")
	if path == "" do return Bridge_Local_Relay_Result{status = 0, ok = false}
	body := bridge_local_extract_json_string(params, "body", "")
	if body == "" do body = bridge_local_extract_json_object(params, "body")
	if body == "{}" && !strings.contains(params, "\"body\"") do body = ""

	credential := bridge_credential_snapshot()
	defer delete(credential)
	headers := [?]httpc.Header{httpc.bearer(credential), {name = "X-Heimdall-Instance-Token", value = rec.instance_token}}
	req := httpc.Request{
		method = method, url = bridge_hub_url(), relay_target = path, headers = headers[:],
		timeout_ms = httpc.LONG_TRANSFER_TIMEOUT_MS, connect_timeout_ms = httpc.DEFAULT_TIMEOUT_MS,
		stall_timeout_ms = httpc.DEFAULT_STALL_TIMEOUT_MS,
	}
	if body != "" && method != .GET && method != .HEAD do req.body = httpc.relay_json_body(body)
	resp, err := bridge_hub_http_send_alloc(req)
	defer httpc.response_destroy(&resp)
	return bridge_local_relay_result(resp, err)
}

// bridge_local_relay_result copies what the local RPC answer needs (the body is
// a heap clone owned by the caller, as before).
bridge_local_relay_result :: proc(resp: httpc.Response, err: httpc.Error) -> Bridge_Local_Relay_Result {
	if err != .None do return Bridge_Local_Relay_Result{status = 0, ok = false}
	return Bridge_Local_Relay_Result{status = resp.status, body = strings.clone(httpc.text(resp)), ok = true}
}

// bridge_local_relay_invalid_params answers an envelope whose params are not a
// JSON object without contacting the hub.
bridge_local_relay_invalid_params :: proc() -> Bridge_Local_Relay_Result {
	return Bridge_Local_Relay_Result{status = 400, ok = true, body = strings.clone(`{"error":{"code":"validation_failed","message":"params must be a JSON object"}}`)}
}

// Bridge_Agent_Relay_Envelope is the agent-actions request body.
Bridge_Agent_Relay_Envelope :: struct {
	method:            string     `json:"method"`,
	agent_instance_id: string     `json:"agent_instance_id"`,
	params:            json.Value `json:"params"`,
}

// bridge_local_agent_relay_envelope parses params (a JSON object, "" = {}) into
// the envelope. The parsed value is temp-allocated.
bridge_local_agent_relay_envelope :: proc(method, params, agent_instance_id: string) -> (Bridge_Agent_Relay_Envelope, bool) {
	value: json.Value = json.Object{}
	if text := strings.trim_space(params); text != "" {
		parsed, perr := json.parse_string(text, .JSON, parse_integers = true, allocator = context.temp_allocator)
		if perr != .None do return {}, false
		if _, is_object := parsed.(json.Object); !is_object do return {}, false
		value = parsed
	}
	return Bridge_Agent_Relay_Envelope{method = method, agent_instance_id = agent_instance_id, params = value}, true
}

// bridge_local_agent_relay_body renders the envelope as JSON text (tests and
// logs); "" when params is not a JSON object.
bridge_local_agent_relay_body :: proc(method, params, agent_instance_id: string) -> string {
	envelope, valid := bridge_local_agent_relay_envelope(method, params, agent_instance_id)
	if !valid do return ""
	data, err := json.marshal(envelope, allocator = context.allocator)
	if err != nil do return ""
	return string(data)
}

bridge_local_response_data :: proc(id, data_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"")
	bridge_local_write_json_string(&b, id)
	strings.write_string(&b, "\",\"ok\":true,\"data\":")
	if strings.trim_space(data_json) == "" {
		strings.write_string(&b, "{}")
	} else {
		strings.write_string(&b, data_json)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

bridge_local_response_error :: proc(id, code, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"")
	bridge_local_write_json_string(&b, id)
	strings.write_string(&b, "\",\"ok\":false,\"error\":{\"code\":\"")
	bridge_local_write_json_string(&b, code)
	strings.write_string(&b, "\",\"message\":\"")
	bridge_local_write_json_string(&b, message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_local_extract_json_string :: proc(json, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(json, key, fallback, false, allocator)
}

bridge_local_extract_json_object :: proc(json, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_object(json, key, false, allocator)
	if !ok do return "{}"
	return res
}

bridge_local_extract_json_bool :: proc(json, key: string, default: bool) -> bool {
	return jsonx.extract_bool(json, key, default)
}

bridge_local_extract_json_int :: proc(json, key: string, default: int) -> int {
	return jsonx.extract_int(json, key, default)
}

bridge_local_json_escaped :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge_local_write_json_string(&b, value)
	return strings.to_string(b)
}

bridge_local_write_json_string :: proc(builder: ^strings.Builder, value: string) {
	logged_ctrl := false
	for i in 0..<len(value) {
		ch := value[i]
		switch ch {
		case '"': strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				if !logged_ctrl {
					fmt.eprintln("bridge_local_write_json_string: escaping control char(s); first=", fmt.tprintf("\\u%04x", u32(ch)), "in payload len=", len(value))
					logged_ctrl = true
				}
				strings.write_string(builder, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_byte(builder, ch)
			}
		}
	}
}
