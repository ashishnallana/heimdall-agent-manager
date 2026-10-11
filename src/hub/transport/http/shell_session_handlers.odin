package http

// T7: Hub WS attach/stream endpoint + HTTP input/resize fallback.
// REQ-SH-CONTRACT §2 row 12, §7 (terminal view).

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import iface "odin_test:hub/repository/iface"
import shell_session_svc "odin_test:hub/service/shell_session"
import project_service "odin_test:hub/service/project"

Shell_Session_Stream_Handlers :: struct {
	auth:                ^auth_service.Auth_Service,
	ws_tickets:          ^User_WS_Ticket_Store,
	bridges:             ^bridge_service.Bridge_Service,
	shell_sessions:      ^shell_session_svc.Shell_Session_Service,
	shell_repo:          ^iface.Shell_Session_Repository,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	experiments:         ^iface.Experiment_Repository,
	preview_origin:      string,
	preview_legacy_path: bool,
}

shell_stream_experiment_enabled :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> bool {
	if repo == nil || repo.list_by_owner == nil || owner_user_id == "" do return false
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	if err.code != .None do return false
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	for exp in exps {
		if exp.key == domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY do return exp.enabled
	}
	return false
}

write_stream_error :: proc(client: net.TCP_Socket, resp: Response) {
	write_http_response(client, resp)
	delete(resp.body)
}

// GET /api/v1/shells/{session_id}/stream — WS upgrade; §2 row 12.
shell_session_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Shell_Session_Stream_Handlers)(ctx)

	auth_ctx: contracts.Auth_Context
	ticket := query_value(req.query, "ticket")
	if ticket != "" {
		c, ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
		if !ok {
			write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired"), req.request_id))
			return
		}
		auth_ctx = c
	} else if h.auth != nil {
		c, ok, resp := require_auth(h.auth, req)
		if !ok {
			write_stream_error(client, resp)
			return
		}
		auth_ctx = c
	} else {
		write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket required for shell stream"), req.request_id))
		return
	}

	// Experiment gate (REQ-STREAM-IMPL-2): with the flag off the route refuses.
	if !shell_stream_experiment_enabled(h.experiments, auth_ctx.user_id) {
		write_stream_error(client, respond_error(domain.domain_error(.Forbidden, "the streaming_terminal_pane experiment is not enabled for this user"), req.request_id))
		return
	}

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		write_stream_error(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}

	session, found, repo_err := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	// A REPOSITORY ERROR IS NOT A MISSING SESSION (REQ-SHELL-12). This used to collapse
	// both into Not_Found, which was survivable while the only error was Internal_Error
	// but is actively misleading now that the read can refuse an AMBIGUOUS id: "no such
	// session" tells the operator to stop looking, when the true answer is that the
	// database holds two rows for this id and the hub will not guess between them.
	// Surfacing repo_err verbatim gives that case its own 409 (respond.odin:46) and
	// leaves the genuine miss below as the only thing reported as Not_Found.
	if repo_err.code != .None {
		write_stream_error(client, respond_error(repo_err, req.request_id))
		return
	}
	if !found {
		write_stream_error(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}
	defer domain.shell_session_destroy(session)
	if session.owner_user_id != auth_ctx.user_id {
		write_stream_error(client, respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id))
		return
	}

	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		write_stream_error(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
		return
	}
	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return

	// REQ-SHELL-29: a viewer joining a session that already had viewers triggers no bridge
	// attach, so the pty-host's catchup screen never fires for it. Remember that here and
	// repaint it from a pane capture on its first resize frame (below).
	// REQ-SHELL-61: `late_join` is now only carried for the record — the snapshot is sent to
	// EVERY attaching viewer. It is still read from the attach (rather than inferred later)
	// because it remains the one race-free answer to "did this socket trigger a bridge
	// attach", which is what the first-frame diagnostic below is interpreted against.
	late_join := shell_session_svc.shell_session_attach(h.shell_sessions, session_id, client, session.bridge_id)
	// REQ-SHELL-41: the ORDINARY detach — this viewer's own stream handler is returning.
	defer shell_session_svc.shell_session_detach(h.shell_sessions, session_id, client, session.bridge_id, .Stream_Closed)
	screen_sent := false

	// Send ready frame.
	ready_b := strings.builder_make()
	strings.write_string(&ready_b, "{\"type\":\"ready\",\"session_id\":\"")
	write_handler_json_string(&ready_b, session_id)
	strings.write_string(&ready_b, "\"}")
	ready_json := strings.to_string(ready_b)
	_ = shell_session_svc.shell_session_write_viewer_frame(h.shell_sessions, session_id, client, ready_json)
	delete(ready_json)

	// REQ-STREAM-EVENT-3: If late_join is true, stream is already running; emit stream_ready directly to this viewer.
	if late_join {
		sr_b := strings.builder_make()
		strings.write_string(&sr_b, "{\"type\":\"stream_ready\",\"session_id\":\"")
		write_handler_json_string(&sr_b, session_id)
		strings.write_string(&sr_b, "\"}")
		sr_json := strings.to_string(sr_b)
		_ = shell_session_svc.shell_session_write_viewer_frame(h.shell_sessions, session_id, client, sr_json)
		delete(sr_json)
	}

	reader := bridge_ws_reader_make(client)
	reader.control_context = rawptr(h.shell_sessions)
	reader.control_writer = pane_reader_write_pong
	defer bridge_ws_reader_destroy(&reader)

	sink_override := h.bridge_command_sink
	for {
		text, ok := read_ws_text_blocking(&reader, 120 * time.Second)
		if !ok do return

		frame_type := json_string(text, "type")

		switch frame_type {
		case "input":
			// REQ-PANE-INPUT-1/5: the wire contract is decoded by the ONE shared decoder in
			// shell_stream_input_frame.odin, which the agent pane consults too. It used to be
			// spelled out here only, and the agent pane's divergent copy understood neither
			// `vault:v1:` nor `enc_b64` — a total input outage while the vault was unlocked.
			frame := shell_stream_decode_input_frame(text)
			defer shell_stream_input_destroy(&frame)
			switch frame.kind {
			case .Armored:
				// The Hub has no vault key; the bridge decrypts or rejects-and-logs.
				bridge_service.send_shell_input(h.bridges, auth_ctx, session.bridge_id, session_id, "", frame.armored, sink_override)
			case .Plain:
				bridge_service.send_shell_input(h.bridges, auth_ctx, session.bridge_id, session_id, frame.plain, "", sink_override)
			case .Undecodable:
				// REQ-PANE-INPUT-3: a dropped keystroke is never silent. This site used to
				// discard an undecodable data_b64 without a word.
				fmt.eprintfln(
					"ham-hub WARN shell input frame dropped session_id=%s reason=%s",
					session_id,
					frame.reason,
				)
			case .Empty:
				// No payload on the frame — nothing to forward.
			}
		case "resize":
			rows := json_int(text, "rows", 0)
			cols := json_int(text, "cols", 0)
			if rows >= 1 && cols >= 1 {
				bridge_service.send_shell_resize(h.bridges, auth_ctx, session.bridge_id, session_id, rows, cols, sink_override)
				// REQ-SHELL-29: capture on the FIRST resize, not on `ready` — this frame
				// carries the viewer's real geometry (useShellStream.ts sendGeometry), and a
				// capture rendered at a guessed 80 columns would re-wrap the screen.
				// REQ-SHELL-61: the gate lives in shell_stream_should_send_screen_snapshot,
				// which takes `late_join` and deliberately ignores it — the first viewer of a
				// session needs the snapshot too. See that proc for why serving it is safe.
				if shell_stream_should_send_screen_snapshot(late_join, screen_sent, rows, cols) {
					screen_sent = true
					_ = shell_stream_send_shell_screen_snapshot(h.shell_sessions, auth_ctx, session_id, client, rows, cols)
				}
			}
		}
		delete(frame_type)
		delete(text)
	}
}

// POST /api/v1/shells/{session_id}/input — HTTP fallback; §2 row 10.
shell_session_input_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Stream_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell input"), req.request_id)
	}

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	// REQ-SHELL-12: propagate the repository error instead of discarding it. An
	// ambiguous session id must not read as "no such session" here either — see the
	// stream handler above for the argument, which does not depend on which route it is.
	session, found, repo_err := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	if repo_err.code != .None {
		return respond_error(repo_err, req.request_id)
	}
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}
	if session.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id)
	}

	data := json_string(req.body, "data")
	defer delete(data)
	enc_b64 := json_string(req.body, "enc_b64")
	defer delete(enc_b64)

	sink_override: project_service.Bridge_Command_Sink = {}
	sent, err := bridge_service.send_shell_input(h.bridges, auth_ctx, session.bridge_id, session_id, data, enc_b64, sink_override)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/resize — HTTP fallback; §2 row 11.
shell_session_resize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Stream_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge cannot send shell resize"), req.request_id)
	}

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	// REQ-SHELL-12: propagate the repository error instead of discarding it. An
	// ambiguous session id must not read as "no such session" here either — see the
	// stream handler above for the argument, which does not depend on which route it is.
	session, found, repo_err := iface.shell_session_get(h.shell_repo, auth_ctx.user_id, session_id)
	if repo_err.code != .None {
		return respond_error(repo_err, req.request_id)
	}
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}
	if session.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the session owner"), req.request_id)
	}

	rows := json_int(req.body, "rows", 0)
	cols := json_int(req.body, "cols", 0)
	if rows < 1 || cols < 1 {
		return respond_error(domain.domain_error(.Validation_Failed, "rows and cols must each be at least 1"), req.request_id)
	}

	sink_override: project_service.Bridge_Command_Sink = {}
	sent, err := bridge_service.send_shell_resize(h.bridges, auth_ctx, session.bridge_id, session_id, rows, cols, sink_override)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// Idle timeout for the preview streaming relay: if no bytes arrive from the upstream
// server for this duration the tunnel is torn down.  A response can be arbitrarily long
// or slow; only a complete absence of activity triggers this.
PREVIEW_IDLE_TIMEOUT :: 120 * time.Second
// Heartbeat interval for WebSocket tunnels.  On each wake the relay checks bridge
// liveness; an idle but healthy socket keeps going, an orphaned one is cleaned up.
PREVIEW_WS_HEARTBEAT :: 30 * time.Second

// ANY /api/v1/preview/{session_id}/**  — preview tunnel proxy; REQ-SH-CONTRACT §6.
// Registered as an upgrade route so the handler owns the raw TCP socket and can relay
// bytes to the client as they arrive rather than buffering the full response.
// XM-2: when the request carries Upgrade: websocket a second goroutine pumps bytes from
// the client socket to the bridge for full bidirectionality (HMR, WS backends, etc.).
preview_origin_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	// The preview host has exactly one public namespace. In particular, Hub API,
	// health and static paths are deliberately unreachable on this Host.
	if !strings.has_prefix(req.path, "/p/") {
		write_http_response(client, Response{status = 404, content_type = "text/plain", body = "not found"})
		return
	}
	session_id := path_part(req.path, 2)
	if session_id == "" {
		write_http_response(client, Response{status = 404, content_type = "text/plain", body = "not found"})
		return
	}
	prefix := strings.concatenate({"/p/", session_id}, context.temp_allocator)
	if req.path == prefix {
		write_http_response(client, Response{
			status = 301,
			content_type = "text/plain",
			body = "redirecting",
			headers = []contracts.HTTP_Header{{name = "Location", value = strings.concatenate({prefix, "/"}, context.temp_allocator)}},
		})
		return
	}
	if !strings.has_prefix(req.path, strings.concatenate({prefix, "/"}, context.temp_allocator)) {
		write_http_response(client, Response{status = 404, content_type = "text/plain", body = "not found"})
		return
	}
	shell_session_preview_proxy_handler(ctx, req, client)
}

preview_legacy_path_allowed :: proc(preview_origin: string, enabled: bool) -> bool {
	return preview_origin == "" || enabled
}

preview_owner_allowed :: proc(session_owner, user_id: string) -> bool {
	return session_owner == user_id
}

shell_session_preview_proxy_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Shell_Session_Stream_Handlers)(ctx)
	heap := runtime.heap_allocator()
	is_preview_origin := strings.has_prefix(req.path, "/p/")
	if !is_preview_origin && !preview_legacy_path_allowed(h.preview_origin, h.preview_legacy_path) {
		write_upgrade_error(client, respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id))
		return
	}

	// Preview-host identity comes only from the trusted reverse proxy, leaving an
	// application's own Authorization header untouched for its upstream.
	auth_ctx: contracts.Auth_Context
	auth_ok: bool
	auth_resp: Response
	if is_preview_origin {
		auth_ctx, auth_ok, auth_resp = require_trusted_proxy_auth(h.auth, req)
	} else {
		auth_ctx, auth_ok, auth_resp = require_auth(h.auth, req)
	}
	if !auth_ok { write_upgrade_error(client, auth_resp); return }

	session_id := path_part(req.path, 2 if is_preview_origin else 4)
	if session_id == "" {
		write_upgrade_error(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}

	// XM-8: resolve session — must be running with a declared server_port>0.  kind is
	// deliberately NOT part of this decision: any session that declared a port at start
	// is reachable, so an interactive shell started with --port 3000 works too.  The port
	// still comes from the SESSION RECORD, never the request, which is the SSRF fence.
	// REQ-SHELL-12: as above — a repository error is not a missing session, and on this
	// path the distinction decides whether an operator goes looking at the database.
	session, found, repo_err := iface.shell_session_get(h.shell_repo, string(auth_ctx.user_id), session_id)
	if repo_err.code != .None {
		write_upgrade_error(client, respond_error(repo_err, req.request_id))
		return
	}
	if !found {
		write_upgrade_error(client, respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id))
		return
	}
	defer domain.shell_session_destroy(session)
	if !preview_owner_allowed(session.owner_user_id, string(auth_ctx.user_id)) {
		write_upgrade_error(client, Response{status = 403, content_type = "application/json", body = "{\"error\":\"session is owned by another user\"}"})
		return
	}
	if session.status != "running" {
		write_upgrade_error(client, Response{status = 409, content_type = "application/json", body = "{\"error\":\"session is not running\"}"})
		return
	}
	if session.server_port <= 0 {
		write_upgrade_error(client, Response{status = 409, content_type = "application/json", body = "{\"error\":\"session has no server port\"}"})
		return
	}

	// XM-2: detect WebSocket upgrade for bidirectional relay.
	is_ws_upgrade := ascii_equal_fold(header_value(req.headers, "Upgrade"), "websocket")

	// ws_ctrl is non-nil only for WS upgrades; guards one-shot tunnel_close send.
	// XM-2: pump goroutine state allocation happens inside the is_ws_upgrade branch below.
	// Both declared at function scope so deferred teardown fires on all exit paths.
	ws_ctrl: ^Preview_Ws_Ctrl
	defer if ws_ctrl != nil do _preview_ws_ctrl_release(ws_ctrl)
	// XM-2: pump thread handle for join-based fd-safety (LIFO: fires before ws_ctrl
	// release above).  This is the JOIN variant of the rule in AGENTS.md, "Socket lifetime
	// across threads" — valid here because this handler thread can afford to block on the
	// join.  Copying it to a teardown that runs on a WebSocket reader thread is wrong; the
	// bridge uses the reader-owns-close variant for exactly that reason.  Either way the fd
	// must never be closed by a thread other than the one that reads it.
	//
	// Joining before handler return means handle_client's deferred
	// net.close(client) cannot fire while the pump is inside recv_tcp — preventing the
	// fd from being reused by an incoming connection whose bytes would then flow into
	// this session's tunnel.  SO_RCVTIMEO (5 s) makes the pump's recv_tcp periodic so
	// it exits within one timeout after ws_ctrl.closed is set, even on platforms where
	// SHUT_RD does not wake a blocked recv in another thread.
	// Allocate stream_id on the heap before the pump_thread defer so the defer can reference
	// it.  heap-allocation is required for long-lived WS connections: fmt.tprintf uses the
	// per-thread temp-allocator ring, which wraps as the relay loop keeps allocating over
	// minutes.  Once wrapped, the ring reuses the bytes that back stream_id in place —
	// corrupting every tunnel_data/tunnel_close frame sent after that point.
	stream_id := strings.clone(fmt.tprintf("st_%x", time.to_unix_nanoseconds(time.now())), heap)
	defer delete(stream_id, heap)

	pump_thread: ^thread.Thread
	defer if pump_thread != nil {
		// Structural stop signal: ensure the pump is told to stop regardless of which
		// relay exit path ran.  The three relay exits call _preview_ws_ctrl_try_close
		// themselves, so those paths get a no-op false return here.  A future relay exit
		// that forgets try_close gets a safety-net send instead of a permanently hung
		// thread (the join would otherwise block until the pump's 5 s SO_RCVTIMEO fires,
		// which could repeat indefinitely on a live socket).
		// The true-getter owns the tunnel_close obligation; "done" is used as the fallback
		// reason because the precise reason was already sent by a normal exit path.
		if ws_ctrl != nil && _preview_ws_ctrl_try_close(ws_ctrl) {
			close_json := _preview_tunnel_close_json(stream_id, "done")
			project_service.bridge_command_send_runtime(
				h.bridge_command_sink,
				project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = close_json},
			)
			delete(close_json)
		}
		thread.join(pump_thread)
		thread.destroy(pump_thread)
	}

	// Register tunnel stream BEFORE sending tunnel_open to bridge. (unchanged)
	stream := shell_session_svc.shell_session_tunnel_register(h.shell_sessions, stream_id)
	defer shell_session_svc.shell_session_tunnel_unregister(h.shell_sessions, stream_id)

	// Compute forwarded path using the active public namespace.
	session_prefix := strings.concatenate({"/p/" if is_preview_origin else "/api/v1/preview/", session_id})
	defer delete(session_prefix)
	forwarded_path := req.path[len(session_prefix):]
	if forwarded_path == "" do forwarded_path = "/"

	// Send tunnel_open to bridge (fire-and-forget). (unchanged)
	open_json := _preview_tunnel_open_json(stream_id, session_id, req.remote_addr)
	defer delete(open_json)
	project_service.bridge_command_send_runtime(
		h.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = open_json},
	)

	// Build and send raw HTTP request as tunnel_data frames (≤48KB base64 chunks).
	// XM-2: pass is_ws_upgrade so WebSocket headers are forwarded and Connection:close suppressed.
	client_addr := _preview_client_addr(req.remote_addr)
	defer delete(client_addr)
	forward_context := Preview_Forward_Context{
		prefix      = session_prefix,
		host        = header_value(req.headers, "Host"),
		// The public preview route is HTTPS in supported deployments; no hub config
		// currently carries the external request scheme.
		proto       = "https",
		client_addr = client_addr,
		forward_cookies = is_preview_origin,
		add_referrer_policy = is_preview_origin,
	}
	raw_req := _preview_build_http_request(req.method, forwarded_path, req.query, req.headers, req.body, session.server_port, forward_context, is_ws_upgrade)
	defer delete(raw_req)
	raw_bytes := transmute([]byte)raw_req
	// CHUNK_SIZE IS A RAW-BYTE FIGURE AND IT DOES *NOT* FIT ONE WS FRAME. THAT IS FINE
	// NOW, AND IT WAS FATAL BEFORE REQ-SHELL-36 -- READ THIS BEFORE "FIXING" IT.
	//
	// The arithmetic looks like a live bug and is not: 49152 is divisible by 3, so base64
	// adds no padding and expands it to EXACTLY 65536 chars, one byte over the 65535-byte
	// 16-bit WS frame cap, before _preview_tunnel_data_json adds its wrapper (~65618 on
	// the wire). Until REQ-SHELL-36 the writer could only emit a single 16-bit frame, so
	// every FULL chunk was refused and the refusal was reported as Bridge_Offline -- a
	// size cliff at 48 KiB that blamed a healthy bridge.
	//
	// It is harmless now because framing is no longer this loop's concern:
	// write_ws_command (bridge_runtime.odin:204) splits any command that does not fit,
	// gating on LENGTH ALONE with nothing keyed off the command type, and it is the only
	// route to the bridge command socket. So this slice size no longer decides what goes
	// on the wire -- BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES (6000, contracts/
	// bridge.odin:120) does, and a 48 KiB slice is simply re-framed into ~11 chunks.
	//
	// RESIZING THIS TO "FIT ONE FRAME" WOULD BUY NOTHING: at a 6000-byte chunk payload
	// anything above 6000 raw is chunked anyway, so there is no value for which this loop
	// emits exactly one frame and still moves useful volume. Left at 48 KiB deliberately.
	//
	// WHAT WOULD MAKE IT MATTER AGAIN: a path to the bridge that writes a command WITHOUT
	// going through write_ws_command, or a write_ws_command that stops chunking. Either
	// makes this an over-cap frame again. Pinned by
	// preview_chunk_size_req54_test.odin (REQ-SHELL-54).
	CHUNK_SIZE :: 48 * 1024
	seq := 0
	off := 0
	for {
		end := off + CHUNK_SIZE
		if end > len(raw_bytes) do end = len(raw_bytes)
		chunk := raw_bytes[off:end]
		is_last := end >= len(raw_bytes)
		encoded := base64.encode(chunk)
		data_json := _preview_tunnel_data_json(stream_id, string(encoded), seq, is_last)
		delete(encoded)
		project_service.bridge_command_send_runtime(
			h.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = data_json},
		)
		delete(data_json)
		seq += 1
		off = end
		if is_last do break
	}

	// XM-2: start the client→bridge pump goroutine for WebSocket upgrades.
	// For plain HTTP the client sends no data after the initial request.
	//
	// ws_ctrl guards one-shot tunnel_close: whichever goroutine (relay or pump) detects
	// end-of-stream first calls _preview_ws_ctrl_try_close; the returning-true caller
	// sends tunnel_close and the other skips it.  Each goroutine holds one ref; the
	// struct is freed by the last release.
	if is_ws_upgrade {
		ws_ctrl = new(Preview_Ws_Ctrl, heap)
		ws_ctrl.refs = 2
		pump_data := new(Preview_Pump_Data, heap)
		pump_data^ = Preview_Pump_Data{
			client              = client,
			stream_id           = strings.clone(stream_id, heap),
			bridge_id           = strings.clone(session.bridge_id, heap),
			bridge_command_sink = h.bridge_command_sink,
			shell_sessions      = h.shell_sessions,
			ws_ctrl             = ws_ctrl,
		}
		// 5 s recv timeout: wakes a blocked recv_tcp periodically so the pump can
		// detect ws_ctrl.closed and exit within one timeout after the relay signals done.
		_ = net.set_option(client, .Receive_Timeout, 5 * time.Second)
		// Thread struct must be heap-allocated (MEM-4 pattern): the pump outlives this
		// handler, but an arena-backed Thread is freed when the arena is destroyed —
		// while the OS thread is still running → SIGSEGV.
		saved_alloc := context.allocator
		context.allocator = heap
		pump_thread = thread.create_and_start_with_data(rawptr(pump_data), _preview_client_to_bridge_pump, self_cleanup = false)
		context.allocator = saved_alloc
	}

	// Streaming relay: forward upstream bytes to client as they arrive.
	// cond_wait / cond_wait_with_timeout blocks efficiently until tunnel_deliver/close_stream
	// signals stream.cond; no sleep-poll and no full-response buffer.
	response_head_pending := make([dynamic]byte, 0, 4096, heap)
	defer delete(response_head_pending)
	response_head_done := false
	for {
		sync.mutex_lock(&stream.mu)
		for len(stream.chunks) == 0 && !stream.closed {
			if is_ws_upgrade {
				// XM-2: heartbeat for bridge-death detection.  An idle-but-healthy WebSocket
				// must not be torn down, but a socket orphaned by a bridge disconnect must not
				// hold a thread and registry entry forever.  Wake every 30 s and check bridge
				// liveness via the DB; if the bridge is offline, close the tunnel.
				signaled := sync.cond_wait_with_timeout(&stream.cond, &stream.mu, PREVIEW_WS_HEARTBEAT)
				if !signaled && len(stream.chunks) == 0 && !stream.closed {
					sync.mutex_unlock(&stream.mu)
					if bridge, bridge_found, _ := bridge_service.get_bridge(h.bridges, auth_ctx, session.bridge_id); !bridge_found || bridge.status == .Offline {
						// Bridge is gone — tear down the orphaned socket.
						if _preview_ws_ctrl_try_close(ws_ctrl) {
							orphan_close := _preview_tunnel_close_json(stream_id, "bridge_offline")
							project_service.bridge_command_send_runtime(
								h.bridge_command_sink,
								project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = orphan_close},
							)
							delete(orphan_close)
						}
						return
					}
					// Bridge is alive — just an idle socket; re-lock and keep waiting.
					sync.mutex_lock(&stream.mu)
				}
			} else {
				signaled := sync.cond_wait_with_timeout(&stream.cond, &stream.mu, PREVIEW_IDLE_TIMEOUT)
				if !signaled && len(stream.chunks) == 0 && !stream.closed {
					// Re-checked predicate after timeout: truly idle.  Tear the tunnel down.
					sync.mutex_unlock(&stream.mu)
					idle_close := _preview_tunnel_close_json(stream_id, "idle_timeout")
					project_service.bridge_command_send_runtime(
						h.bridge_command_sink,
						project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = idle_close},
					)
					delete(idle_close)
					return
				}
			}
		}
		// Drain available chunks under the lock, then release before writing.
		// Ownership transfers to to_write; unregister's free loop is a no-op for these.
		to_write := make([][]byte, len(stream.chunks))
		copy(to_write, stream.chunks[:])
		clear(&stream.chunks)
		done := stream.closed
		sync.mutex_unlock(&stream.mu)

		// Buffer the first response head so security-sensitive headers are filtered even
		// when CRLFCRLF is split across tunnel chunks. This includes WS handshakes.
		write_ok := true
		head_overflow := false
		for chunk in to_write {
			if write_ok && !head_overflow {
				if response_head_done {
					write_ok = _preview_write_all(client, chunk)
				} else {
					filtered, complete, overflow := _preview_response_head_feed(
						&response_head_pending, chunk, session_prefix, session.server_port, forward_context.add_referrer_policy,
					)
					if overflow {
						head_overflow = true
						write_ok = _preview_write_all(client, transmute([]byte)filtered)
						delete(filtered, runtime.heap_allocator())
					} else if complete {
						response_head_done = true
						write_ok = _preview_write_all(client, transmute([]byte)filtered)
						delete(filtered, runtime.heap_allocator())
					}
				}
			}
			delete(chunk)
		}
		delete(to_write)

		if !write_ok || head_overflow {
			// Tear down on a client write failure or an oversized upstream head.
			if is_ws_upgrade {
				// XM-2: close-once — the pump goroutine may have already sent tunnel_close.
				if _preview_ws_ctrl_try_close(ws_ctrl) {
					disc_close := _preview_tunnel_close_json(stream_id, "client_disconnect")
					project_service.bridge_command_send_runtime(
						h.bridge_command_sink,
						project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = disc_close},
					)
					delete(disc_close)
				}
			} else {
				disc_close := _preview_tunnel_close_json(stream_id, "client_disconnect")
				project_service.bridge_command_send_runtime(
					h.bridge_command_sink,
					project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = disc_close},
				)
				delete(disc_close)
			}
			return
		}

		if done {
			// A non-empty head cut off by EOF is malformed and may contain unfiltered
			// security-sensitive headers. Never forward it to the browser.
			if !response_head_done {
				eof_response := _preview_response_head_eof(response_head_pending[:])
				if eof_response != "" {
					write_ok := _preview_write_all(client, transmute([]byte)eof_response)
					delete(eof_response, runtime.heap_allocator())
					if !write_ok do return
				}
				clear(&response_head_pending)
			}
			break
		}
	}

	// Normal completion: upstream closed the connection.
	if is_ws_upgrade {
		// XM-2: close-once — the pump goroutine may have already sent tunnel_close
		// (e.g. the client hung up at the same instant the upstream closed).
		if _preview_ws_ctrl_try_close(ws_ctrl) {
			close_json := _preview_tunnel_close_json(stream_id, "done")
			project_service.bridge_command_send_runtime(
				h.bridge_command_sink,
				project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = close_json},
			)
			delete(close_json)
		}
	} else {
		close_json := _preview_tunnel_close_json(stream_id, "done")
		project_service.bridge_command_send_runtime(
			h.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = close_json},
		)
		delete(close_json)
	}
}

// --- preview tunnel helpers ---

PREVIEW_RESPONSE_HEAD_MAX :: 64 * 1024
PREVIEW_BAD_GATEWAY_RESPONSE :: "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

_preview_rewrite_location :: proc(value, prefix: string, server_port: int) -> string {
	if value == prefix || strings.has_prefix(value, strings.concatenate({prefix, "/"}, context.temp_allocator)) {
		return strings.clone(value, runtime.heap_allocator())
	}
	local_hosts := []string{"127.0.0.1", "localhost"}
	schemes := []string{"http", "https"}
	for host in local_hosts {
		for scheme in schemes {
			base := fmt.tprintf("%s://%s:%d", scheme, host, server_port)
			if len(value) >= len(base) && strings.equal_fold(value[:len(base)], base) {
				rest := value[len(base):]
				if rest == "" || rest[0] == '/' || rest[0] == '?' || rest[0] == '#' {
					return strings.concatenate({prefix, rest}, runtime.heap_allocator())
				}
			}
		}
	}
	if strings.has_prefix(value, "/") && !strings.has_prefix(value, "//") {
		return strings.concatenate({prefix, value}, runtime.heap_allocator())
	}
	return strings.clone(value, runtime.heap_allocator())
}

_preview_filter_set_cookie :: proc(value, prefix: string) -> string {
	parts := strings.split(value, ";")
	defer delete(parts)
	b := strings.builder_make(runtime.heap_allocator())
	if len(parts) > 0 do strings.write_string(&b, strings.trim_space(parts[0]))
	found_path := false
	for part in parts[1:] {
		attr := strings.trim_space(part)
		name := attr
		if eq := strings.index_byte(attr, '='); eq >= 0 do name = strings.trim_space(attr[:eq])
		if strings.equal_fold(name, "domain") do continue
		strings.write_string(&b, "; ")
		if strings.equal_fold(name, "path") {
			strings.write_string(&b, "Path=")
			strings.write_string(&b, prefix)
			strings.write_byte(&b, '/')
			found_path = true
		} else {
			strings.write_string(&b, attr)
		}
	}
	if !found_path {
		strings.write_string(&b, "; Path=")
		strings.write_string(&b, prefix)
		strings.write_byte(&b, '/')
	}
	return strings.to_string(b)
}

_preview_filter_response_head :: proc(head, prefix: string, server_port: int, add_referrer_policy := false) -> string {
	lines := strings.split(head, "\n")
	defer delete(lines)
	b := strings.builder_make(runtime.heap_allocator())
	has_referrer_policy := false
	for raw_line in lines {
		line := raw_line
		if strings.has_suffix(line, "\r") do line = line[:len(line)-1]
		if line == "" do break
		colon := strings.index_byte(line, ':')
		name := line
		if colon >= 0 do name = line[:colon]
		if colon >= 0 && strings.equal_fold(name, "service-worker-allowed") do continue
		if colon >= 0 && strings.equal_fold(name, "referrer-policy") do has_referrer_policy = true
		if colon >= 0 && strings.equal_fold(name, "set-cookie") {
			filtered := _preview_filter_set_cookie(strings.trim_space(line[colon+1:]), prefix)
			strings.write_string(&b, line[:colon+1]); strings.write_byte(&b, ' '); strings.write_string(&b, filtered); delete(filtered, runtime.heap_allocator())
		} else if colon >= 0 && strings.equal_fold(name, "location") {
			filtered := _preview_rewrite_location(strings.trim_space(line[colon+1:]), prefix, server_port)
			strings.write_string(&b, line[:colon+1]); strings.write_byte(&b, ' '); strings.write_string(&b, filtered); delete(filtered, runtime.heap_allocator())
		} else {
			strings.write_string(&b, line)
		}
		strings.write_string(&b, "\r\n")
	}
	if add_referrer_policy && !has_referrer_policy do strings.write_string(&b, "Referrer-Policy: same-origin\r\n")
	strings.write_string(&b, "\r\n")
	return strings.to_string(b)
}

_preview_response_token_byte :: proc(b: byte) -> bool {
	if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' do return true
	switch b {
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

_preview_response_head_status_code :: proc(head: string) -> (int, bool) {
	// Validate bytes and line framing before interpreting any header names.
	for b, i in transmute([]byte)head {
		if b == '\r' && (i+1 >= len(head) || head[i+1] != '\n') do return 0, false
		if b == 0x7f || (b < 0x20 && b != '\t' && b != '\r' && b != '\n') do return 0, false
	}
	line_end := strings.index_byte(head, '\n')
	if line_end < 0 do return 0, false
	line := head[:line_end]
	if strings.has_suffix(line, "\r") do line = line[:len(line)-1]
	if len(line) < 12 do return 0, false
	if line[:8] != "HTTP/1.0" && line[:8] != "HTTP/1.1" do return 0, false
	if line[8] != ' ' do return 0, false
	i := 9
	if line[i] < '0' || line[i] > '9' || line[i+1] < '0' || line[i+1] > '9' || line[i+2] < '0' || line[i+2] > '9' do return 0, false
	if len(line) > 12 && line[12] != ' ' do return 0, false

	lines := strings.split(head, "\n")
	defer delete(lines)
	saw_end := false
	for raw_header in lines[1:] {
		header := raw_header
		if strings.has_suffix(header, "\r") do header = header[:len(header)-1]
		if header == "" {
			saw_end = true
			break
		}
		if header[0] == ' ' || header[0] == '\t' do return 0, false
		colon := strings.index_byte(header, ':')
		if colon <= 0 do return 0, false
		for b in transmute([]byte)header[:colon] {
			if !_preview_response_token_byte(b) do return 0, false
		}
	}
	if !saw_end do return 0, false
	code := int(line[i]-'0')*100 + int(line[i+1]-'0')*10 + int(line[i+2]-'0')
	return code, true
}

_preview_response_head_end :: proc(data: string) -> int {
	lf_end := strings.index(data, "\n\n")
	mixed_end := strings.index(data, "\n\r\n")
	if lf_end >= 0 && (mixed_end < 0 || lf_end < mixed_end) do return lf_end + 2
	if mixed_end >= 0 do return mixed_end + 3
	return -1
}

_preview_response_head_eof :: proc(pending: []byte) -> string {
	if len(pending) == 0 do return ""
	return strings.clone(PREVIEW_BAD_GATEWAY_RESPONSE, runtime.heap_allocator())
}

_preview_response_head_feed :: proc(pending: ^[dynamic]byte, chunk: []byte, prefix: string, server_port: int, add_referrer_policy := false) -> (string, bool, bool) {
	append(pending, ..chunk)
	all := string(pending[:])
	cursor := 0
	final_head_end := -1
	interim_count := 0
	for {
		end := _preview_response_head_end(all[cursor:])
		if end < 0 do break
		head_end := cursor + end
		if head_end > PREVIEW_RESPONSE_HEAD_MAX {
			return strings.clone(PREVIEW_BAD_GATEWAY_RESPONSE, runtime.heap_allocator()), false, true
		}
		status_code, valid := _preview_response_head_status_code(all[cursor:head_end])
		if !valid {
			return strings.clone(PREVIEW_BAD_GATEWAY_RESPONSE, runtime.heap_allocator()), false, true
		}
		if status_code < 100 || status_code >= 200 || status_code == 101 {
			final_head_end = head_end
			break
		}
		interim_count += 1
		if interim_count > 5 {
			return strings.clone(PREVIEW_BAD_GATEWAY_RESPONSE, runtime.heap_allocator()), false, true
		}
		cursor = head_end
	}
	if final_head_end < 0 {
		if len(pending) > PREVIEW_RESPONSE_HEAD_MAX {
			return strings.clone(PREVIEW_BAD_GATEWAY_RESPONSE, runtime.heap_allocator()), false, true
		}
		return "", false, false
	}
	b := strings.builder_make(runtime.heap_allocator())
	cursor = 0
	for cursor < final_head_end {
		end := _preview_response_head_end(all[cursor:])
		head_end := cursor + end
		filtered := _preview_filter_response_head(all[cursor:head_end], prefix, server_port, add_referrer_policy && head_end == final_head_end)
		strings.write_string(&b, filtered)
		delete(filtered, runtime.heap_allocator())
		cursor = head_end
	}
	strings.write_string(&b, all[final_head_end:])
	result := strings.to_string(b)
	clear(pending)
	return result, true, false
}

_preview_tunnel_open_json :: proc(stream_id, session_id, client_ip: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_open\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\",\"client_ip\":\"")
	write_handler_json_string(&b, client_ip)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_preview_tunnel_data_json :: proc(stream_id, data_b64: string, seq: int, last: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_data\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	write_handler_json_string(&b, data_b64)
	strings.write_string(&b, "\",\"seq\":")
	strings.write_int(&b, seq)
	strings.write_string(&b, ",\"last\":")
	strings.write_string(&b, "true" if last else "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_preview_tunnel_close_json :: proc(stream_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"tunnel_close\",\"stream_id\":\"")
	write_handler_json_string(&b, stream_id)
	strings.write_string(&b, "\",\"reason\":\"")
	write_handler_json_string(&b, reason)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

Preview_Forward_Context :: struct {
	prefix:      string,
	host:        string,
	proto:       string,
	client_addr: string,
	forward_cookies: bool,
	add_referrer_policy: bool,
}

_preview_filter_cookie_header :: proc(value: string) -> string {
	b := strings.builder_make()
	first := true
	remaining := value
	for part in strings.split_iterator(&remaining, ";") {
		cookie := strings.trim_space(part)
		name := cookie
		if eq := strings.index_byte(cookie, '='); eq >= 0 do name = strings.trim_space(cookie[:eq])
		if strings.has_prefix(strings.to_lower(name, context.temp_allocator), "authentik_") do continue
		if !first do strings.write_string(&b, "; ")
		strings.write_string(&b, cookie)
		first = false
	}
	return strings.to_string(b)
}

// _preview_client_addr removes a transport port without truncating an unbracketed IPv6
// address. The HTTP server normally supplies an address-only value, but tests and
// alternate callers may provide host:port.
_preview_client_addr :: proc(remote_addr: string, allocator := context.allocator) -> string {
	if len(remote_addr) > 0 && remote_addr[0] == '[' {
		if closing := strings.index_byte(remote_addr, ']'); closing > 0 {
			return strings.clone(remote_addr[1:closing], allocator)
		}
	}
	if strings.count(remote_addr, ":") == 1 {
		if colon := strings.last_index_byte(remote_addr, ':'); colon >= 0 {
			return strings.clone(remote_addr[:colon], allocator)
		}
	}
	return strings.clone(remote_addr, allocator)
}

// XM-2: is_ws_upgrade=true suppresses the hardcoded "Connection: close" and passes
// through the WebSocket negotiation headers so the upstream can issue a valid 101.
_preview_build_http_request :: proc(method, fwd_path, query: string, headers: []contracts.HTTP_Header, body: string, server_port: int, forward: Preview_Forward_Context = {}, is_ws_upgrade: bool = false) -> string {
	b := strings.builder_make()
	strings.write_string(&b, method)
	strings.write_byte(&b, ' ')
	strings.write_string(&b, fwd_path)
	if query != "" {
		strings.write_byte(&b, '?')
		strings.write_string(&b, query)
	}
	strings.write_string(&b, " HTTP/1.1\r\nHost: 127.0.0.1:")
	strings.write_int(&b, server_port)
	strings.write_string(&b, "\r\n")
	if !is_ws_upgrade {
		strings.write_string(&b, "Connection: close\r\n")
	}
	forward_headers := []struct{name, value: string}{
		{"X-Forwarded-Host", forward.host},
		{"X-Forwarded-Proto", forward.proto},
		{"X-Forwarded-Prefix", forward.prefix},
		{"X-Forwarded-For", forward.client_addr},
	}
	for hdr in forward_headers {
		if hdr.value == "" do continue
		strings.write_string(&b, hdr.name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, hdr.value)
		strings.write_string(&b, "\r\n")
	}
	for hdr in headers {
		lower := strings.to_lower(hdr.name)
		defer delete(lower)
		pass := false
		switch lower {
		case "accept", "accept-encoding", "accept-language", "content-type", "content-length",
		     "cache-control", "range", "if-none-match", "if-modified-since", "if-match",
		     "if-unmodified-since", "content-encoding", "user-agent", "referer", "origin",
		     "x-csrf-token", "x-csrftoken", "x-xsrf-token", "x-requested-with":
			pass = true
		// Shared-origin hub auth consumes Bearer credentials before this builder runs,
		// so this currently benefits non-Bearer schemes such as Basic only.
		case "authorization":
			pass = true
		// Never forward hub credentials or identity assertions into an untrusted preview.
		case "cookie":
			if forward.forward_cookies {
				filtered_cookie := _preview_filter_cookie_header(hdr.value)
				if filtered_cookie != "" {
					strings.write_string(&b, hdr.name)
					strings.write_string(&b, ": ")
					strings.write_string(&b, filtered_cookie)
					strings.write_string(&b, "\r\n")
				}
				delete(filtered_cookie)
			}
			pass = false
		// XM-2: WebSocket negotiation headers must reach the upstream verbatim so it can
		// compute Sec-WebSocket-Accept and issue a valid 101 Switching Protocols.
		case "upgrade", "connection",
		     "sec-websocket-key", "sec-websocket-version",
		     "sec-websocket-protocol", "sec-websocket-extensions":
			pass = is_ws_upgrade
		}
		if strings.has_prefix(lower, "x-authentik-") do pass = false
		if pass {
			strings.write_string(&b, hdr.name)
			strings.write_string(&b, ": ")
			strings.write_string(&b, hdr.value)
			strings.write_string(&b, "\r\n")
		}
	}
	strings.write_string(&b, "\r\n")
	if body != "" do strings.write_string(&b, body)
	return strings.to_string(b)
}

// _preview_write_all writes all of data to client, looping on short writes.
// Returns false if the client socket is gone.
_preview_write_all :: proc(client: net.TCP_Socket, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		n, err := net.send_tcp(client, remaining)
		if err != nil || n <= 0 do return false
		remaining = remaining[n:]
	}
	return true
}

// --- XM-2: WebSocket bidirectional pump helpers ---

// Preview_Ws_Ctrl coordinates a single tunnel_close send and ref-counts goroutine
// lifetimes for a WebSocket-upgraded preview tunnel.  The main relay goroutine and the
// client→bridge pump goroutine each hold one ref; the struct is freed on the last release.
Preview_Ws_Ctrl :: struct {
	mu:     sync.Mutex,
	closed: bool, // true once tunnel_close has been sent
	refs:   int,
}

// _preview_ws_ctrl_try_close marks closed and returns true exactly once.
// The caller that receives true MUST send tunnel_close; all subsequent callers skip it.
_preview_ws_ctrl_try_close :: proc(ctrl: ^Preview_Ws_Ctrl) -> bool {
	if ctrl == nil do return false
	sync.mutex_lock(&ctrl.mu)
	defer sync.mutex_unlock(&ctrl.mu)
	if ctrl.closed do return false
	ctrl.closed = true
	return true
}

// _preview_ws_ctrl_release decrements the ref count and frees the struct at zero.
_preview_ws_ctrl_release :: proc(ctrl: ^Preview_Ws_Ctrl) {
	if ctrl == nil do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&ctrl.mu)
	ctrl.refs -= 1
	should_free := ctrl.refs == 0
	sync.mutex_unlock(&ctrl.mu)
	if should_free do free(ctrl, heap)
}

// Preview_Pump_Data carries the state for _preview_client_to_bridge_pump.
// Heap-allocated by the proxy handler; the pump goroutine frees it on exit.
Preview_Pump_Data :: struct {
	client:              net.TCP_Socket,
	stream_id:           string, // heap-cloned; owned by pump goroutine
	bridge_id:           string, // heap-cloned; owned by pump goroutine
	bridge_command_sink: project_service.Bridge_Command_Sink,
	shell_sessions:      ^shell_session_svc.Shell_Session_Service,
	ws_ctrl:             ^Preview_Ws_Ctrl,
}

// _preview_client_to_bridge_pump reads bytes from the client socket and forwards them as
// tunnel_data frames to the bridge for the lifetime of a WebSocket-upgraded tunnel.
//
// Safety invariant: this proc never holds a ^Preview_Tunnel_Stream pointer directly.
// All stream access goes through stream_id lookups in the service map (which is mutex-
// guarded), so main's tunnel_unregister + free of the stream struct cannot cause a UAF
// even if this goroutine is still alive when the main relay goroutine has already exited.
//
// Lifetime: the main relay goroutine joins this thread (thread.join) before returning,
// so handle_client's deferred net.close(client) cannot fire while recv_tcp is blocked here.
// A 5 s SO_RCVTIMEO is set before the pump starts so recv_tcp wakes periodically; once
// ws_ctrl.closed is true (relay has signaled shutdown) the post-loop path skips tunnel_close
// and the goroutine exits, unblocking the join within one timeout period.
_preview_client_to_bridge_pump :: proc(data_ptr: rawptr) {
	d := (^Preview_Pump_Data)(data_ptr)
	heap := runtime.heap_allocator()
	defer {
		_preview_ws_ctrl_release(d.ws_ctrl)
		delete(d.stream_id, heap)
		delete(d.bridge_id, heap)
		free(d, heap)
	}

	buf: [4096]byte
	seq := 0
	for {
		n, recv_err := net.recv_tcp(d.client, buf[:])
		if recv_err == .Would_Block {
			// SO_RCVTIMEO periodic wake.  Exit only if relay has signaled shutdown;
			// an idle-but-healthy WebSocket must not be killed by the timeout.
			sync.mutex_lock(&d.ws_ctrl.mu)
			shutting_down := d.ws_ctrl.closed
			sync.mutex_unlock(&d.ws_ctrl.mu)
			if shutting_down do break
			continue
		}
		if recv_err != nil || n <= 0 do break
		encoded := base64.encode(buf[:n])
		frame_json := _preview_tunnel_data_json(d.stream_id, string(encoded), seq, false)
		delete(encoded)
		project_service.bridge_command_send_runtime(
			d.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = d.bridge_id, body_json = frame_json},
		)
		delete(frame_json)
		seq += 1
	}

	// Wake the main relay goroutine so it exits its cond_wait cleanly.
	// Safe even if the stream was already unregistered (lookup returns false → no-op).
	shell_session_svc.shell_session_tunnel_close_stream(d.shell_sessions, d.stream_id)

	// Send tunnel_close exactly once — guarded by ws_ctrl so the main relay goroutine
	// cannot double-send if it reaches its own cleanup at the same time.
	if _preview_ws_ctrl_try_close(d.ws_ctrl) {
		close_json := _preview_tunnel_close_json(d.stream_id, "client_disconnect")
		project_service.bridge_command_send_runtime(
			d.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = d.bridge_id, body_json = close_json},
		)
		delete(close_json)
	}
}
