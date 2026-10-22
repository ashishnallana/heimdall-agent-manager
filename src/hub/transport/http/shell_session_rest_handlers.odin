package http

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

Shell_Session_Rest_Handlers :: struct {
	entitlements: domain.Entitlement_Lookup,
	auth:           ^auth_service.Auth_Service,
	shell_sessions: ^shell_session_svc.Shell_Session_Service,
	// REQ-SHELL-10 work item 3: the live bridge-connection registry, read ONLY to
	// derive the bridge-offline presentation state below. Nothing on this path writes
	// to it.
	bridge_runtime_registry: ^project_service.Bridge_Runtime_Registry,
	preview_origin: string,
	ui_origin: string,
}

// --- bridge-offline session state (REQ-SHELL-10 work item 3) ------------------
//
// A session whose bridge is disconnected must not be presented as plainly `running`,
// which asserts something we cannot currently see, nor as `failed`/`killed`, which
// assert something we do not know. It needs a third reading: "the bridge that owns
// this is gone; its true status is unknown until it returns". REQ-SHELL-6 §8 renders
// it.
//
// DERIVED AT READ TIME, NOT STORED, and not written on disconnect. This is the design
// decision of this work item, so here is the whole reasoning:
//
//  - NOTHING IS TRIGGERED BY A DISCONNECT. Three call sites in this codebase
//    deliberately choose CONVERT-NOT-KILL when a bridge drops, because a WS drop is
//    usually a transient blip with the processes alive; a status write on disconnect
//    would be a fourth behaviour reintroducing the risk they exist to avoid, and it
//    would have to be undone again moments later on a fast reconnect.
//  - IT IS SELF-CORRECTING IN BOTH DIRECTIONS FOR FREE. The flag simply follows the
//    registry, so it appears the instant the connection drops and disappears the
//    instant it returns, with no teardown racing a reconnect and therefore no
//    connection-generation guard to get right on this path.
//  - IT ADDS NO STATUS VALUE. domain.SHELL_SESSION_TERMINAL_STATUSES and the whole
//    status vocabulary are untouched, so every existing live/finished filter keeps
//    meaning what it meant — and REQ-SHELL-14, whose acceptance forbids a new status
//    value, is unaffected.
//
// The row's `status` is still reported verbatim; this only tells a client how much to
// trust it.

// shell_session_bridge_online answers whether the bridge owning a session is
// connected RIGHT NOW. A nil registry (tests, and only tests, since wiring always
// supplies one) answers "online": the alternative would have every serialization
// without a registry claim every session's status is untrustworthy.
shell_session_bridge_online :: proc(registry: ^project_service.Bridge_Runtime_Registry, s: domain.Shell_Session) -> bool {
	if registry == nil do return true
	return project_service.bridge_runtime_registry_has_live(registry, s.bridge_id)
}

// shell_session_status_unknown is the state itself: the status on this row cannot
// currently be trusted because the only thing that could confirm it is unreachable.
//
// TERMINAL SESSIONS ARE EXCLUDED, which is the whole reason this is a named rule
// rather than `!bridge_online` at the call site. A session that has already ended has
// a FINAL status — it is a fact about the past, and no bridge is needed to vouch for
// it. Only a session the hub believes is still live has a status that depends on a
// bridge we cannot currently reach.
shell_session_status_unknown :: proc(registry: ^project_service.Bridge_Runtime_Registry, s: domain.Shell_Session) -> bool {
	if domain.shell_session_is_terminal(s) do return false
	return !shell_session_bridge_online(registry, s)
}

// --- JSON serialization ---

shell_session_preview_url :: proc(s: domain.Shell_Session, preview_origin, ui_origin: string) -> string {
	if s.server_port <= 0 do return strings.clone("")
	if preview_origin != "" {
		return strings.concatenate({strings.trim_right(preview_origin, "/"), "/p/", s.session_id, "/"})
	}
	base := strings.trim_right(ui_origin, "/")
	return strings.concatenate({base, "/api/v1/preview/", s.session_id, "/"})
}

write_shell_session_json :: proc(b: ^strings.Builder, s: domain.Shell_Session, registry: ^project_service.Bridge_Runtime_Registry = nil, preview_origin: string = "", ui_origin: string = "") {
	strings.write_string(b, "{\"session_id\":\"")
	write_handler_json_string(b, s.session_id)
	strings.write_string(b, "\",\"owner_user_id\":\"")
	write_handler_json_string(b, s.owner_user_id)
	strings.write_string(b, "\",\"bridge_id\":\"")
	write_handler_json_string(b, s.bridge_id)
	strings.write_string(b, "\",\"project_id\":\"")
	write_handler_json_string(b, s.project_id)
	strings.write_string(b, "\",\"chain_id\":\"")
	write_handler_json_string(b, s.chain_id)
	strings.write_string(b, "\",\"agent_instance_id\":\"")
	write_handler_json_string(b, s.agent_instance_id)
	strings.write_string(b, "\",\"kind\":\"")
	write_handler_json_string(b, s.kind)
	strings.write_string(b, "\",\"label\":\"")
	write_handler_json_string(b, s.label)
	strings.write_string(b, "\",\"cmd\":\"")
	write_handler_json_string(b, s.cmd)
	strings.write_string(b, "\",\"cwd\":\"")
	write_handler_json_string(b, s.cwd)
	strings.write_string(b, "\",\"status\":\"")
	write_handler_json_string(b, s.status)
	strings.write_string(b, "\"")
	if s.exit_code_set {
		strings.write_string(b, fmt.tprintf(",\"exit_code\":%d", s.exit_code))
	} else {
		strings.write_string(b, ",\"exit_code\":null")
	}
	strings.write_string(b, fmt.tprintf(",\"pid\":%d", s.pid))
	strings.write_string(b, fmt.tprintf(",\"server_port\":%d", s.server_port))
	preview_url := shell_session_preview_url(s, preview_origin, ui_origin)
	defer delete(preview_url)
	strings.write_string(b, ",\"preview_url\":\"")
	write_handler_json_string(b, preview_url)
	strings.write_string(b, "\"")
	if s.background {
		strings.write_string(b, ",\"background\":true")
	} else {
		strings.write_string(b, ",\"background\":false")
	}
	strings.write_string(b, ",\"conversation_id\":\"")
	write_handler_json_string(b, s.conversation_id)
	strings.write_string(b, "\"")
	// REQ-SHELL-10 work item 3. Both are DERIVED, never stored — see
	// shell_session_status_unknown. `status_unknown` is the one a client should render;
	// `bridge_online` is the raw fact it is derived from, reported so the UI can say
	// WHY (and so the honest kill affordance REQ-SHELL-6 §8 asks for — the request is
	// durable and will be delivered when the bridge returns — has something to key on).
	// The rule lives in one place so nothing recomputes it and drifts.
	if shell_session_bridge_online(registry, s) {
		strings.write_string(b, ",\"bridge_online\":true")
	} else {
		strings.write_string(b, ",\"bridge_online\":false")
	}
	if shell_session_status_unknown(registry, s) {
		strings.write_string(b, ",\"status_unknown\":true")
	} else {
		strings.write_string(b, ",\"status_unknown\":false")
	}
	if s.preview_enabled {
		strings.write_string(b, ",\"preview_enabled\":true")
	} else {
		strings.write_string(b, ",\"preview_enabled\":false")
	}
	strings.write_string(b, ",\"started_at\":\"")
	write_handler_json_string(b, s.started_at)
	strings.write_string(b, "\",\"finished_at\":\"")
	write_handler_json_string(b, s.finished_at)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, s.created_at)
	strings.write_string(b, "\",\"last_activity_at\":\"")
	write_handler_json_string(b, s.last_activity_at)
	strings.write_string(b, "\"}")
}

// --- REST handlers ---

// POST /api/v1/bridges/{bridge_id}/shells
shell_session_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind == .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge token cannot create shell sessions"), req.request_id)
	}

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	input := shell_session_svc.Shell_Session_Create_Input{
		bridge_id         = bridge_id,
		kind              = json_string(req.body, "kind"),
		cmd               = json_string(req.body, "cmd"),
		cwd               = json_string(req.body, "cwd"),
		label             = json_string(req.body, "label"),
		project_id        = json_string(req.body, "project_id"),
		chain_id          = json_string(req.body, "chain_id"),
		agent_instance_id = json_string(req.body, "agent_instance_id"),
		conversation_id   = json_string(req.body, "conversation_id"),
		server_port       = json_int(req.body, "server_port", 0),
		background        = json_bool(req.body, "background"),
		enc_spec          = json_string(req.body, "enc_spec"),
		session_id        = json_string(req.body, "session_id"),
	}
	defer {
		delete(input.kind)
		delete(input.cmd)
		delete(input.cwd)
		delete(input.label)
		delete(input.project_id)
		delete(input.chain_id)
		delete(input.agent_instance_id)
		delete(input.conversation_id)
		delete(input.enc_spec)
		delete(input.session_id)
	}

	session, created, err := shell_session_svc.shell_session_create(h.shell_sessions, auth_ctx, input)
	if !created do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/background
//
// Converts a LIVE FOREGROUND run to a background one (REQ-SHELL-2 §3): the
// blocked caller is released with the session id, and the run starts notifying on
// completion. One-way — a run already background, or already terminal, is a 409
// rather than a silent success, so a double-click cannot release a second waiter.
//
// Deliberately open to BOTH a user and an agent. The user is the one REQ-SHELL-6
// builds the control for, and an agent that decides mid-flight it no longer wants
// to block is asking for exactly the same transition. Ownership is what limits it:
// the service resolves the session owner-scoped, so nobody can background another
// owner's run.
shell_session_background_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "session_id is required"), req.request_id)
	}

	session, done, err := shell_session_svc.shell_session_set_background(h.shell_sessions, auth_ctx, session_id)
	if !done do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/bridges/{bridge_id}/shells
shell_session_list_by_bridge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	status_filter := query_value(req.query, "status")
	cursor        := query_value(req.query, "cursor")
	limit         := query_int(req.query, "limit", 25)

	sessions, next_cursor, err := shell_session_svc.shell_session_list_by_bridge(h.shell_sessions, auth_ctx, bridge_id, status_filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/projects/{project_id}/shells
shell_session_list_by_project_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	project_id    := path_part(req.path, 4)
	status_filter := query_value(req.query, "status")
	cursor        := query_value(req.query, "cursor")
	limit         := query_int(req.query, "limit", 25)

	sessions, next_cursor, err := shell_session_svc.shell_session_list_by_project(h.shell_sessions, auth_ctx, project_id, status_filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells[?bridge_id=&project_id=&chain_id=&agent_instance_id=&status=&limit=&cursor=]
//
// The owner-wide shell list. With NO query parameters it returns every shell the
// caller owns, across every bridge — the product had no such view before, and it
// is the default this route now serves. Each parameter that is present adds one
// AND-ed narrowing clause, so `?bridge_id=X&status=running` means both, not
// either.
//
// chain_id used to be REQUIRED here and 400'd when absent, which is why
// `ham-ctl shell list` could not list shells. It is now just one more optional
// filter; a request that does pass it gets exactly what it got before, since a
// lone chain_id filter is the same query the chain-scoped list ran.
shell_session_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	// Each scope-column filter also narrows by kind, per the domain's per-kind
	// scope rules — the repository applies that, not this handler (REQ-SHELL-1 §5).
	// agent_instance_id is here because it is kind=run's scope key; without it a
	// run has no filter that names its own scope.
	filter := iface.Shell_Session_List_Filter{
		bridge_id         = query_value(req.query, "bridge_id"),
		project_id        = query_value(req.query, "project_id"),
		chain_id          = query_value(req.query, "chain_id"),
		agent_instance_id = query_value(req.query, "agent_instance_id"),
		status            = query_value(req.query, "status"),
	}
	cursor := query_value(req.query, "cursor")
	limit  := query_int(req.query, "limit", 25)

	sessions, next_cursor, err := shell_session_svc.shell_session_list(h.shell_sessions, auth_ctx, filter, cursor, limit)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	body := _shell_session_list_json(sessions[:], next_cursor, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}
shell_session_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, found, err := shell_session_svc.shell_session_get(h.shell_sessions, auth_ctx, session_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// DELETE /api/v1/shells/{session_id} — accepts a kill for the session.
//
// THE OUTCOME IS PART OF THE ANSWER (REQ-SHELL-3). This used to reply a flat
// {"ok":true} whether the kill had reached the bridge or not, which made a QUEUED
// kill byte-identical to a DELIVERED one: a user could click kill, see success, and
// watch the shell keep running. Both are still successes — the intent is durable
// either way — but the caller is told which it got, in three ways that agree:
//   - the status code: 200 delivered, 202 Accepted for queued, which is exactly what
//     202 means ("accepted for processing, not yet acted on");
//   - `outcome`, the machine-readable value the UI switches on;
//   - `message`, the sentence a human reads. ham-ctl prints this response verbatim,
//     so this field is also the CLI's output.
// The service owns both spellings so the transport cannot drift from it.
shell_session_kill_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	outcome, accepted, err := shell_session_svc.shell_session_kill(h.shell_sessions, auth_ctx, session_id)
	if !accepted do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"outcome\":\"")
	write_handler_json_string(&b, shell_session_svc.shell_session_kill_outcome_string(outcome))
	strings.write_string(&b, "\",\"message\":\"")
	write_handler_json_string(&b, shell_session_svc.shell_session_kill_outcome_message(outcome))
	strings.write_string(&b, "\"}")
	status := outcome == .Queued ? 202 : 200
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), status)
}

// POST /api/v1/shells/{session_id}/signal
shell_session_signal_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	signal := json_int(req.body, "signal", 0)
	if signal <= 0 {
		return respond_error(domain.domain_error(.Validation_Failed, "signal must be a positive integer"), req.request_id)
	}

	sent, err := shell_session_svc.shell_session_signal(h.shell_sessions, auth_ctx, session_id, signal)
	if !sent do return respond_error(err, req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/restart
shell_session_restart_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	session, ok2, err := shell_session_svc.shell_session_restart(h.shell_sessions, auth_ctx, session_id)
	if !ok2 do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// POST /api/v1/shells/{session_id}/port — declare or clear the server port of a
// session that is already running (XM-9).
//
// A POST sub-route rather than a PATCH on the session resource: every mutating
// shell endpoint here is either a POST sub-route (/signal, /restart) or a
// DELETE, and there is no partial-update convention in this transport to join.
// Returns the updated session, the same shape /restart returns.
//
// server_port 0 clears the port. It is the sentinel the record already uses for
// "no port declared" everywhere else, so a separate clear verb would add a
// second spelling of a state that already has one.
shell_session_set_port_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	// -1 as the sentinel for "absent", so an explicit 0 (clear) is distinguishable
	// from a body that never mentioned the field.
	server_port := json_int(req.body, "server_port", -1)
	if server_port < 0 {
		return respond_error(domain.domain_error(.Validation_Failed, "server_port is required (1-65535, or 0 to clear)"), req.request_id)
	}

	session, ok2, err := shell_session_svc.shell_session_set_port(h.shell_sessions, auth_ctx, session_id, server_port)
	if !ok2 do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"session\":")
	write_shell_session_json(&b, session, h.bridge_runtime_registry, h.preview_origin, h.ui_origin)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/log
shell_session_log_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	offset    := query_int(req.query, "offset", 0)
	limit_val := query_int(req.query, "limit", 100)
	grep      := query_value(req.query, "grep")

	result, got, err := shell_session_svc.shell_session_get_log(h.shell_sessions, auth_ctx, session_id, offset, limit_val, grep)
	if !got do return respond_error(err, req.request_id)
	defer delete(result.lines_raw)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"lines\":")
	if result.lines_raw != "" do strings.write_string(&b, result.lines_raw)
	else do strings.write_string(&b, "[]")
	if result.truncated {
		strings.write_string(&b, ",\"truncated\":true")
	} else {
		strings.write_string(&b, ",\"truncated\":false")
	}
	strings.write_string(&b, fmt.tprintf(",\"total_lines\":%d}", result.total_lines))
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/capture
shell_session_capture_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	result, got, err := shell_session_svc.shell_session_capture(h.shell_sessions, auth_ctx, session_id)
	if !got do return respond_error(err, req.request_id)
	defer delete(result.content)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"content\":\"")
	write_handler_json_string(&b, result.content)
	strings.write_string(&b, fmt.tprintf("\",\"rows\":%d,\"cols\":%d}", result.rows, result.cols))
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/shells/{session_id}/pane — polled screen snapshot with since_hash diffing
// (REQ-PTY-STREAM-1). Modelled on get_agent_instance_pane_handler and returns the same
// payload shape. Owner scoping goes through shell_session_svc.shell_session_get, the
// auth-scoped getter — deliberately NOT the unscoped get_by_id BUG-8 added for the
// bridge-event path.
shell_session_pane_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Shell_Session_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		return respond_error(domain.domain_error(.Not_Found, "session not found"), req.request_id)
	}

	since_hash := query_value(req.query, "since_hash")
	width := query_int(req.query, "width", 80)
	if width <= 0 do width = 80
	line_limit := query_int(req.query, "line_limit", 120)
	if line_limit <= 0 do line_limit = 120

	reply, got, err := shell_session_svc.shell_session_get_pane(h.shell_sessions, auth_ctx, session_id, since_hash, width, line_limit)
	if !got do return respond_error(err, req.request_id)
	return respond_success(reply, req.request_id, auth_ctx_server_time(req))
}

// --- private ---

_shell_session_list_json :: proc(sessions: []domain.Shell_Session, next_cursor: string, registry: ^project_service.Bridge_Runtime_Registry = nil, preview_origin: string = "", ui_origin: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"sessions\":[")
	for s, i in sessions {
		if i > 0 do strings.write_string(&b, ",")
		write_shell_session_json(&b, s, registry, preview_origin, ui_origin)
	}
	strings.write_string(&b, "],\"next_cursor\":\"")
	write_handler_json_string(&b, next_cursor)
	// has_more is exactly `next_cursor != ""`: the repo sets next_cursor ONLY
	// when a full page came back, so a short page (empty cursor) is precisely
	// "no more rows". Emitted rather than left to the client because every other
	// list envelope here carries it, and both UI consumers already read
	// `data?.has_more ?? <same derivation>` — the new key feeds the branch they
	// already prefer with the value they already computed.
	if next_cursor != "" {
		strings.write_string(&b, "\",\"has_more\":true}")
	} else {
		strings.write_string(&b, "\",\"has_more\":false}")
	}
	return strings.to_string(b)
}
