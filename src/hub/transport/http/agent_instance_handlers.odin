package http

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

// POST /api/v1/agent-instances/{id}/input
// Streams interactive keystrokes and raw terminal input to a running agent instance.
agent_instance_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send instance input"), req.request_id)
	}

	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)

	data := json_string(req.body, "data")
	defer delete(data)

	sent, err := agent_service.agent_service_send_pty_input(h.agents, auth_ctx, instance_id, data, wait_for_result = true)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_agent_instance_input_handler :: agent_instance_input_handler

// POST /api/v1/agent-instances/{id}/resize
// Updates the PTY terminal window size (rows and cols) for an agent instance.
agent_instance_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send instance resize"), req.request_id)
	}

	instance_id := path_part(req.path, 4)
	if strings.contains(instance_id, "/") do return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)

	rows := json_int(req.body, "rows", 0)
	if rows <= 0 {
		str_val := json_string(req.body, "rows")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do rows = int(parsed)
	}

	cols := json_int(req.body, "cols", 0)
	if cols <= 0 {
		str_val := json_string(req.body, "cols")
		defer delete(str_val)
		if parsed, ok_parse := strconv.parse_int(str_val); ok_parse do cols = int(parsed)
	}

	if rows < 1 || cols < 1 {
		return respond_error(domain.domain_error(.Validation_Failed, "rows and cols must be at least 1"), req.request_id)
	}

	if rows > 65535 do rows = 65535
	if cols > 65535 do cols = 65535

	sent, err := agent_service.agent_service_send_pty_resize(h.agents, auth_ctx, instance_id, rows, cols)
	if !sent do return respond_error(err, req.request_id)

	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

post_agent_instance_resize_handler :: agent_instance_resize_handler

// GET /api/v1/agent-instances/{id}/stream — WS upgrade; streaming terminal pane for agent instances (REQ-STREAM-IMPL-4).
agent_instance_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Agent_Handlers)(ctx)

	auth_ctx: contracts.Auth_Context
	ticket := query_value(req.query, "ticket")
	if ticket != "" {
		if h.ws_tickets == nil {
			project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
			write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "ticket store not configured"), req.request_id))
			return
		}
		c, ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
		if !ok {
			project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
			write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired"), req.request_id))
			return
		}
		auth_ctx = c
	} else if h.auth != nil {
		c, ok, resp := require_auth(h.auth, req)
		if !ok {
			project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
			write_stream_error(client, resp)
			return
		}
		auth_ctx = c
	} else {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
		write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "authentication required for agent instance stream"), req.request_id))
		return
	}

	// Experiment gate (REQ-STREAM-IMPL-4): with the flag off the route refuses.
	if !shell_stream_experiment_enabled(h.experiments, auth_ctx.user_id) {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
		write_stream_error(client, respond_error(domain.domain_error(.Forbidden, "the streaming_terminal_pane experiment is not enabled for this user"), req.request_id))
		return
	}

	instance_id := path_part(req.path, 4)
	if instance_id == "" || strings.contains(instance_id, "/") {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "not_found")
		write_stream_error(client, respond_error(domain.domain_error(.Not_Found, "agent instance not found"), req.request_id))
		return
	}

	if h.agents == nil || h.agents.agents == nil {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "other")
		write_stream_error(client, respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id))
		return
	}

	inst, got, err := iface.agent_get_instance(h.agents.agents, instance_id)
	if !got || err.code != .None {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "not_found")
		write_stream_error(client, respond_error(domain.domain_error(.Not_Found, "agent instance not found"), req.request_id))
		return
	}

	if string(inst.owner_user_id) != auth_ctx.user_id {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "auth_failed")
		write_stream_error(client, respond_error(domain.domain_error(.Forbidden, "not the instance owner"), req.request_id))
		return
	}

	if strings.trim_space(inst.bridge_id) == "" {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "bridge_offline")
		write_stream_error(client, respond_error(domain.domain_error(.Bridge_Offline, "agent instance has no bridge"), req.request_id))
		return
	}

	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "bad_request")
		write_stream_error(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
		return
	}
	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) {
		project_service.ws_track_rejected(project_service.WS_KIND_AGENT_STREAM, "other")
		return
	}

	// Telemetry (plan 3.4): open from here to handler return. tx bytes are counted by
	// the pane viewer writer, which owns every write to this socket; rx bytes and the
	// close reason are counted here.
	ws_opened := project_service.ws_track_open(project_service.WS_KIND_AGENT_STREAM)
	ws_close_reason := "error"
	defer project_service.ws_track_close(project_service.WS_KIND_AGENT_STREAM, ws_opened, ws_close_reason)
	ws_rx := ws_bytes_series(project_service.WS_KIND_AGENT_STREAM, "rx", inst.bridge_id)

	// REQ-SHELL-29: same late-join hole as the shells pane — both consume the identical
	// `screen` frame and both funnel through shell_session_attach. See the shells handler.
	late_join := false
	screen_sent := false
	if h.shell_sessions != nil {
		late_join = shell_session_svc.shell_session_attach(h.shell_sessions, instance_id, client, inst.bridge_id, project_service.WS_KIND_AGENT_STREAM)
	}
	defer {
		if h.shell_sessions != nil {
			// REQ-SHELL-41: ordinary detach on the stream handler's way out.
			shell_session_svc.shell_session_detach(h.shell_sessions, instance_id, client, inst.bridge_id, .Stream_Closed)
		}
	}

	// Send ready frame.
	boot_id := stream_bridge_boot_id(h.agents.bridge_runtime_registry if h.agents != nil else nil, inst.bridge_id)
	defer delete(boot_id)
	ready_b := strings.builder_make()
	strings.write_string(&ready_b, "{\"type\":\"ready\",\"agent_instance_id\":\"")
	write_handler_json_string(&ready_b, instance_id)
	strings.write_string(&ready_b, "\",\"session_id\":\"")
	write_handler_json_string(&ready_b, instance_id)
	if boot_id != "" {
		strings.write_string(&ready_b, "\",\"bridge_boot_id\":\"")
		write_handler_json_string(&ready_b, boot_id)
	}
	strings.write_string(&ready_b, "\"}")
	ready_json := strings.to_string(ready_b)
	_ = shell_session_svc.shell_session_write_viewer_frame(h.shell_sessions, instance_id, client, ready_json)
	delete(ready_json)

	// Send initial status frame if known.
	if string(inst.runtime_status) != "" {
		st_b := strings.builder_make()
		strings.write_string(&st_b, "{\"type\":\"status\",\"status\":\"")
		write_handler_json_string(&st_b, string(inst.runtime_status))
		strings.write_string(&st_b, "\"}")
		st_json := strings.to_string(st_b)
		_ = shell_session_svc.shell_session_write_viewer_frame(h.shell_sessions, instance_id, client, st_json)
		delete(st_json)
	}

	// REQ-STREAM-EVENT-3: If late_join is true, stream is already running; emit stream_ready directly to this viewer.
	if late_join {
		sr_json := shell_session_svc.stream_ready_frame_json(instance_id, boot_id)
		_ = shell_session_svc.shell_session_write_viewer_frame(h.shell_sessions, instance_id, client, sr_json)
		delete(sr_json)
	}

	reader := bridge_ws_reader_make(client)
	reader.control_context = rawptr(h.shell_sessions)
	reader.control_writer = pane_reader_write_pong
	defer bridge_ws_reader_destroy(&reader)

	for {
		// Same read as read_ws_text_blocking; the reason feeds ws_disconnects_total only.
		text, ok, why := bridge_ws_read_frame(&reader, 120 * time.Second)
		if !ok {
			ws_close_reason = bridge_ws_reason_string(why)
			return
		}
		ws_note_rx(ws_rx, len(text))

		// REQ-PTY-NET-3: same binary, ack-less input relay as the shells pane — the agent
		// pane shares the pipeline and the bridge keys on shell_id == instance_id.
		if reader.last_opcode == 0x2 {
			kind, flags, payload, _, _, bin_ok := contracts.pty_wire_decode_viewer_frame(transmute([]byte)text)
			if !bin_ok || kind != contracts.PTY_WIRE_KIND_INPUT {
				fmt.eprintfln("ham-hub WARN agent pane input frame dropped instance_id=%s reason=not_a_pty_input_frame bytes=%d", instance_id, len(text))
			} else if len(payload) > 0 {
				shell_session_svc.shell_metrics_note_input(len(payload))
				_, _ = agent_service.agent_service_send_pty_input_binary(h.agents, auth_ctx, instance_id, payload, contracts.pty_wire_is_encrypted(flags))
			}
			delete(text)
			continue
		}

		frame_type := json_string(text, "type")

		switch frame_type {
		case "resize":
			rows := json_int(text, "rows", 0)
			cols := json_int(text, "cols", 0)
			if rows >= 1 && cols >= 1 {
				agent_service.agent_service_send_pty_resize(h.agents, auth_ctx, instance_id, rows, cols)
				// REQ-SHELL-29: the agent pane's SIGWINCH micro-nudge (useAgentStream.ts:194-206)
				// only repaints FULL-SCREEN programs; a shell sitting at a prompt is not
				// covered by it, so the snapshot is still required here.
				// REQ-SHELL-61: same gate as the shells pane, and it carried the same defect —
				// the first viewer got no snapshot. Both panes now share the one predicate so
				// they cannot drift apart again.
				if shell_stream_should_send_screen_snapshot(late_join, screen_sent, rows, cols) {
					screen_sent = true
					_ = shell_stream_send_agent_screen_snapshot(h.agents, h.shell_sessions, auth_ctx, instance_id, client, rows, cols, late_join)
				}
			}
		case "heartbeat":
			// Keepalive
		}
		delete(frame_type)
		delete(text)
	}
}

