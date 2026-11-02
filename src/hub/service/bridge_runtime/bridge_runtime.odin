package bridge_runtime

import "base:runtime"
import "core:net"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"
import jsonx "odin_test:lib/jsonx"
import metrics "odin_test:lib/metrics"
import "odin_test:contracts"

// new_bridge_connection_closer builds the REQ-IMPL-3 / audit-F6 teardown seam: the
// thing revoke_bridge calls to terminate a revoked bridge's LIVE control
// WebSocket, rather than only flipping a DB row and leaving a connected bridge
// fully operational until it chooses to reconnect.
//
// IT LIVES HERE, in the one package that already joins the services to the runtime
// registry, so that the app wiring and the tests share EXACTLY this path. A test
// that built its own one-line closure would prove the registry works and prove
// nothing about what production actually wires up — which, for a revocation
// control, is the difference between a test and a reassurance.
new_bridge_connection_closer :: proc(registry: ^project_service.Bridge_Runtime_Registry) -> bridge_service.Bridge_Connection_Closer {
	return bridge_service.Bridge_Connection_Closer{ctx = rawptr(registry), close_bridge_connection = close_bridge_connection, close_with_reason = close_bridge_connection_with_reason}
}

close_bridge_connection_with_reason :: proc(ctx: rawptr, bridge_id, code: string) -> bool {
    registry := (^project_service.Bridge_Runtime_Registry)(ctx)
    connection := project_service.bridge_runtime_connection_acquire(registry, bridge_id)
    if connection == nil do return false
    defer project_service.bridge_runtime_connection_release(registry, connection)
    project_service.bridge_runtime_connection_lock_writer(connection)
    defer sync.unlock(&connection.writer_mutex)
    if sync.atomic_load(&connection.retired) || connection.socket == net.TCP_Socket(0) do return false
    sync.atomic_store(&connection.credential_revoked, true)
    payload, err := json.marshal(struct {
        type: string,
        payload: struct {code, message: string},
    }{type = "bridge_error", payload = {code = code, message = "bridge retired; stop Hub traffic until explicitly activated"}}, allocator = context.temp_allocator)
    if err == nil do _ = ws.write_server_text(connection.socket, string(payload), false)
    // Only wake: the transport reader owns close on every exit path.
    _ = net.shutdown(net.Any_Socket(connection.socket), .Both)
    return true
}

// close_bridge_connection shuts down a live bridge control socket. See
// project_service.bridge_runtime_registry_shutdown_command_socket for why this
// SHUTS DOWN rather than closes, and why that distinction is load-bearing.
close_bridge_connection :: proc(ctx: rawptr, bridge_id: string) -> bool {
	return project_service.bridge_runtime_registry_shutdown_command_socket((^project_service.Bridge_Runtime_Registry)(ctx), bridge_id)
}

new_bridge_command_sink :: proc(registry: ^project_service.Bridge_Runtime_Registry) -> project_service.Bridge_Command_Sink {
	return project_service.Bridge_Command_Sink{ctx = rawptr(registry), validate_project_path = validate_project_path, send_runtime_command = send_runtime_command, send_runtime_command_wait = send_runtime_command_wait, send_runtime_binary = send_runtime_binary}
}

send_runtime_command :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	registry := (^project_service.Bridge_Runtime_Registry)(ctx)
	if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id) do return false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	connection := project_service.bridge_runtime_connection_acquire(registry, command.bridge_id)
	if connection == nil do return false, domain.domain_error(.Bridge_Offline, "bridge connection retired")
	defer project_service.bridge_runtime_connection_release(registry, connection)
	// The writer lock is per durable Bridge id. A slow socket cannot stall command
	// delivery or heartbeat acknowledgements for every other connected Bridge.
	wrote := write_ws_command_on_connection(connection, command.body_json)
	if wrote == .Not_Connected do return false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	if wrote != .Ok do return false, command_write_error(wrote)
	bridge_command_track_sent(connection, command.body_json)
	return true, domain.Domain_Error{}
}

// send_runtime_binary writes one hub->bridge BINARY frame under the connection's writer
// lock (REQ-PTY-NET-3). Never chunked — the chunker is a text envelope — and bounded by
// the 16-bit arm our bridge reader accepts; a pty input frame is <= 8 KiB + header, far
// below the hub->bridge per-message cap. Nothing is registered anywhere: there is no
// command_id, so no result is expected and no waiter can hang on it.
send_runtime_binary :: proc(ctx: rawptr, bridge_id: string, frame: []byte) -> (bool, domain.Domain_Error) {
	registry := (^project_service.Bridge_Runtime_Registry)(ctx)
	if len(frame) > contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES + 4096 do return false, domain.domain_error(.Validation_Failed, "binary bridge frame exceeds the hub->bridge per-message cap")
	if !project_service.bridge_runtime_registry_has_live(registry, bridge_id) do return false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	connection := project_service.bridge_runtime_connection_acquire(registry, bridge_id)
	if connection == nil do return false, domain.domain_error(.Bridge_Offline, "bridge connection retired")
	defer project_service.bridge_runtime_connection_release(registry, connection)
	// A keystroke is a single-frame writer: it goes out between the chunks of a large
	// command instead of waiting behind the whole sequence (REQ-ERR-PROTO-C).
	project_service.bridge_runtime_connection_lock_writer(connection)
	defer sync.unlock(&connection.writer_mutex)
	socket := connection.socket
	if socket == net.TCP_Socket(0) || sync.atomic_load(&connection.retired) do return false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	if connection_refuse_if_expired(connection, socket) do return false, command_write_error(.Auth_Expired)
	result := ws.write_server_opcode(socket, 0x2, string(frame), false)
	if result == .Peer_Gone || result == .Desynchronised do _ = net.shutdown(net.Any_Socket(socket), .Both)
	if result != .Ok do return false, command_write_error(.Send_Failed if result != .Too_Large else .Too_Large)
	metrics.counter_add(connection.tx_bytes, u64(len(frame)))
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "tx", "shell_pty_input"))
	return true, domain.Domain_Error{}
}

// bridge_command_track_sent records one hub->bridge frame on the connection's
// cached byte series and the fleet-wide frames counter. The `type` key sits at
// the front of every command body, so the extraction is cheap; the result is
// mapped onto a fixed enum before it becomes a label.
bridge_command_track_sent :: proc(connection: ^project_service.Bridge_Runtime_Connection, body_json: string) -> string {
	metrics.counter_add(connection.tx_bytes, u64(len(body_json)))
	frame_type := jsonx.extract_string(body_json, "type")
	defer delete(frame_type)
	kind := project_service.bridge_frame_kind(frame_type)
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_frames, "tx", kind))
	return kind
}

send_runtime_command_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	registry := cast(^project_service.Bridge_Runtime_Registry)ctx
	if !project_service.bridge_runtime_registry_has_live(registry, command.bridge_id) do return "", false, domain.domain_error(.Bridge_Offline, "bridge is not connected")
	connection := project_service.bridge_runtime_connection_acquire(registry, command.bridge_id)
	if connection == nil do return "", false, domain.domain_error(.Bridge_Offline, "bridge connection retired")
	defer project_service.bridge_runtime_connection_release(registry, connection)
	generation := connection.generation
	// The write takes the writer lock per frame and releases it before the poll
	// below — holding it across the wait would stall the loop's heartbeat/state acks
	// and could deadlock command delivery.
	body := runtime_command_with_timeout(command.body_json, timeout_ms)
	wrote := write_ws_command_on_connection(connection, body)
	if wrote == .Not_Connected do return "", false, domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	if wrote != .Ok do return "", false, command_write_error(wrote)
	command_kind := bridge_command_track_sent(connection, body)
	started := time.tick_now()
	result_text, result_ok, result_err := send_runtime_command_wait_result(registry, connection, command, generation, timeout_ms)
	metrics.observe_duration(metrics.with(project_service.fleet_metrics.bridge_command_duration, command_kind), time.tick_since(started))
	if !result_ok {
		code_name := fmt.tprint(result_err.code)
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_command_errors, command_kind, project_service.bridge_command_error_code(code_name)))
	}
	return result_text, result_ok, result_err
}

// runtime_command_with_timeout tells the bridge how long the hub will wait for this
// command (REQ-ERR-PROTO-B), so a command still queued on the bridge when the hub has
// given up is dropped there instead of run for nobody. The bridge takes the smaller
// of this and its own per-command cap. Only the TOP-LEVEL timeout_ms counts: one the
// body already carries is lowered to the hub's wait (never raised), and a timeout_ms
// nested in params or quoted in content is ignored. Temp-allocated when it changes
// the body.
runtime_command_with_timeout :: proc(body_json: string, timeout_ms: int) -> string {
	body := strings.trim_right_space(body_json)
	if timeout_ms <= 0 || len(body) < 2 || body[0] != '{' || body[len(body) - 1] != '}' do return body_json
	value_start, value_end, found := json_top_level_value_span(body, "timeout_ms")
	if !found {
		if strings.trim_space(body[1:len(body) - 1]) == "" do return fmt.tprintf("{{\"timeout_ms\":%d}}", timeout_ms)
		return fmt.tprintf("%s,\"timeout_ms\":%d}}", body[:len(body) - 1], timeout_ms)
	}
	existing, ok := strconv.parse_int(body[value_start:value_end])
	if ok && existing > 0 && existing <= timeout_ms do return body_json
	return fmt.tprintf("%s%d%s", body[:value_start], timeout_ms, body[value_end:])
}

// json_top_level_value_span finds `key` among the members of the object `body` (not
// inside nested objects/arrays or string values) and returns the byte span of its
// scalar value.
@(private = "file")
json_top_level_value_span :: proc(body, key: string) -> (start, end: int, found: bool) {
	depth := 0
	expect_key := false
	i := 0
	for i < len(body) {
		c := body[i]
		switch c {
		case '{', '[':
			depth += 1
			expect_key = c == '{' && depth == 1
			i += 1
		case '}', ']':
			depth -= 1
			i += 1
		case ',':
			if depth == 1 do expect_key = true
			i += 1
		case '"':
			j := i + 1
			for j < len(body) && body[j] != '"' {
				if body[j] == '\\' do j += 1
				j += 1
			}
			if j >= len(body) do return 0, 0, false
			if depth == 1 && expect_key {
				expect_key = false
				if body[i + 1:j] == key {
					k := j + 1
					for k < len(body) && (body[k] == ' ' || body[k] == '\t' || body[k] == '\n' || body[k] == '\r' || body[k] == ':') do k += 1
					e := k
					for e < len(body) && body[e] != ',' && body[e] != '}' && body[e] != ' ' && body[e] != '\n' && body[e] != '\r' && body[e] != '\t' do e += 1
					return k, e, true
				}
			}
			i = j + 1
		case:
			i += 1
		}
	}
	return 0, 0, false
}

// send_runtime_command_wait_result is the wait half of send_runtime_command_wait,
// split out so the round trip can be timed and classified in one place.
send_runtime_command_wait_result :: proc(registry: ^project_service.Bridge_Runtime_Registry, connection: ^project_service.Bridge_Runtime_Connection, command: project_service.Runtime_Command, generation: int, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	// The generated command id may come from a per-thread temporary ring. Keep an
	// owned copy stable while the condition wait releases this thread.
	wait_id := strings.clone(command.command_id)
	defer delete(wait_id)
	cached, ok := runtime_command_wait_terminal(registry, command.bridge_id, generation, wait_id, time.Duration(timeout_ms) * time.Millisecond, require_connection = true)
	if !ok {
		if sync.atomic_load(&connection.retired) do return "", false, domain.domain_error(.Bridge_Offline, "bridge connection ended before its command result")
		return "", false, domain.domain_error(.Bridge_Timeout, "bridge websocket command timed out")
	}
	// A failed command_result is a typed refusal (REQ-ERR-PROTO-A): surface it as the
	// bridge's own code/class/cause. Data-carrying replies (fs/vcs/shell/search/pane
	// results) go back to the caller, which relays or maps their typed error itself.
	if bridge_reply_type_is(cached, "command_result") {
		if werr, found := contracts.wire_error_parse(cached, context.temp_allocator); found {
			delete(cached, runtime.default_allocator())
			return "", false, bridge_wire_domain_error(werr)
		}
	}
	return cached, true, domain.Domain_Error{}
}

// bridge_wire_domain_error turns a bridge's wire error into the domain error the API
// answers with. Overload keeps its Retry-After floor and scope in details.
bridge_wire_domain_error :: proc(werr: contracts.Wire_Error) -> domain.Domain_Error {
	err := domain.domain_error_from_wire(werr)
	if werr.retry_after_ms > 0 || werr.scope != "" {
		err.details_json = fmt.tprintf("{\"retry_after_ms\":%d,\"overload_scope\":\"%s\"}", werr.retry_after_ms, werr.scope)
	}
	return err
}

// bridge_reply_type_is reports whether a reply frame's top-level type is want.
bridge_reply_type_is :: proc(reply, want: string) -> bool {
	got := jsonx.extract_string(reply, "type", "", true, context.temp_allocator)
	return got == want
}

validate_project_path :: proc(ctx: rawptr, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	if command.type != "validate_project_path" do return {}, false, domain.domain_error(.Internal_Error, "unexpected bridge command type")
	data, encode_err := json.marshal(command)
	if encode_err != nil do return {}, false, domain.domain_error(.Internal_Error, "failed to encode path validation")
	defer delete(data)
	reply, received, err := send_runtime_command_wait(ctx, project_service.Runtime_Command{bridge_id = command.bridge_id, command_id = command.command_id, body_json = string(data)}, 15000)
	if !received do return {}, false, err
	defer delete(reply)
	return parse_validation_result(command, reply), true, {}
}

parse_validation_result :: proc(command: project_service.Validate_Project_Path_Command, text: string) -> project_service.Project_Path_Validation_Result {
	if json_bool(text, "ok") do return validation_result(command, true, "", "")
	// The fine-grained cause (path_not_found, git_root_not_found, ...) is what the
	// path row records; the message is display text.
	werr, _ := contracts.wire_error_parse(text, context.temp_allocator)
	code := werr.cause if werr.cause != "" else "validation_failed"
	return validation_result(command, false, code, werr.message)
}

// bridge_runtime_json_escaped_temp JSON-escapes a bridge-supplied string for embedding
// in a hand-built object (the message may quote a path); temp-allocated.
bridge_runtime_json_escaped_temp :: proc(value: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	contracts.write_json_string(&b, value)
	return strings.to_string(b)
}

validation_result :: proc(command: project_service.Validate_Project_Path_Command, ok: bool, error_code, message: string) -> project_service.Project_Path_Validation_Result {
	details: string
	validation_error := ""
	if ok {
		details = strings.concatenate({"{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"bridge_id\":\"", command.bridge_id, "\",\"vcs_kind\":\"", command.vcs_kind, "\",\"command_id\":\"", command.command_id, "\"}"})
	} else {
		validation_error = strings.clone(message)
		details = strings.concatenate({"{\"transport\":\"bridge_ws\",\"command\":\"validate_project_path\",\"bridge_id\":\"", command.bridge_id, "\",\"command_id\":\"", command.command_id, "\",\"error\":{\"code\":\"", bridge_runtime_json_escaped_temp(error_code), "\",\"message\":\"", bridge_runtime_json_escaped_temp(message), "\"}}"})
	}
	return project_service.Project_Path_Validation_Result{type = "project_path_validation_result", command_id = command.command_id, project_id = command.project_id, path = command.path, ok = ok, validation_error = validation_error, details_json = details}
}

// Command_Write_Result says WHICH failure happened, because "this frame cannot be
// encoded" and "this socket is gone" are different conditions with different recovery
// and a bool cannot tell them apart. REQ-SHELL-36: collapsing them is exactly what made
// an oversized command surface as .Bridge_Offline — an operator chasing "bridge offline"
// looks at the bridge, the network and the token long before they look at a frame size.
Command_Write_Result :: enum {
	Ok,
	// The payload cannot be carried even chunked: it exceeds the reassembly caps the
	// bridge enforces. A statement about THIS COMMAND, never about the connection.
	Too_Large,
	// The socket write failed or could not complete. The bridge really has stopped
	// taking bytes, so .Bridge_Offline is the honest mapping for this one.
	Send_Failed,
	// The connection was retired or has no socket (write_ws_command_on_connection).
	Not_Connected,
	// The session's credential has expired: no command is delivered to it, and its
	// reader is woken to close it (see Bridge_Runtime_Connection.auth_expires_unix_ms).
	Auth_Expired,
}

// connection_refuse_if_expired is the outbound half of the session credential
// bound: nothing is sent on a session whose token has expired, so work cannot leak
// through between the reader's checks. The reader is WOKEN with shutdown(.Receive)
// and closes the socket itself (AGENTS.md: the reader owns the fd). Caller holds
// writer_mutex, so the socket is still the connection's.
connection_refuse_if_expired :: proc(connection: ^project_service.Bridge_Runtime_Connection, socket: net.TCP_Socket) -> bool {
	if !project_service.bridge_runtime_connection_auth_expired(connection) do return false
	_ = net.shutdown(net.Any_Socket(socket), .Receive)
	return true
}

// write_ws_command writes one hub->bridge command, CHUNKING it when it does not fit in
// a single 16-bit-length WS frame. This is the hub->bridge half of the protocol whose
// bridge->hub half has existed since REQ-SHELL-32; see hub_command_chunk.odin for why
// chunking rather than a 64-bit length arm, and for the frame shape.
//
// >>> THE CALLER MUST HOLD THE REGISTRY COMMAND LOCK ACROSS THIS CALL. <<<
// Production sends go through write_ws_command_on_connection, which keeps the
// sequence-level guarantee below with chunk_sequence_mutex and takes the writer lock
// per frame (REQ-ERR-PROTO-C); this proc remains for single-socket callers and tests.
// The rule exists for a reason that got stricter when chunking landed. The lock
// used to buy only BYTE-level serialisation: the runtime loop's ack writes must not
// interleave bytes inside one frame. It now also buys SEQUENCE-level serialisation:
// the bridge reassembles by chunk_id, so another command's CHUNKS must not appear
// between this sequence's chunks. Whole non-chunk frames landing between two chunks are
// fine and always were — the bridge passes those straight through while a reassembly is
// in flight — but a second interleaved SEQUENCE would have both streams open at once and
// is what the lock now prevents. This is the same pairing the bridge side documents on
// _bridge_hub_send_mu, reached from the other direction.
//
// ACK-LESS, deliberately, matching the other direction: this channel has no chunk_ack
// path, and a single ordered connection with the lock held means the bridge sees the
// chunks in order anyway, so per-chunk acks would be pure latency.
write_ws_command :: proc(socket: net.TCP_Socket, text: string) -> Command_Write_Result {
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
	// Fits whole. Nothing to reassemble, so the bridge never sees a chunk frame for the
	// overwhelming majority of commands. Same condition hub_command_chunk_frames uses to
	// return nil, tested here so the two branches below are explicit.
	if len(text) <= payload {
		if ws.write_server_text(socket, text, false) != .Ok do return .Send_Failed
		return .Ok
	}
	// REFUSED BEFORE THE FRAMES ARE BUILT, and the order is the point: an over-cap
	// command is rejected without allocating anything. Checking after the split would
	// have built and immediately discarded thousands of frames for a payload that was
	// never deliverable (at 6000 bytes a chunk, the 16 MB byte cap is ~2731 frames and
	// the 4096-chunk cap is ~24.5 MB) — wasteful on the exact path where the payload is
	// already known to be enormous. Placed after the fits-whole test above so the caps
	// bound what must actually be REASSEMBLED rather than every command.
	if !hub_command_is_chunkable(text, payload) do return .Too_Large
	frames := hub_command_chunk_frames(text, payload)
	if frames == nil do return .Send_Failed // unreachable: len(text) > payload > 0
	defer {
		for f in frames do delete(f)
		delete(frames)
	}
	// Stop on the first failed write but keep freeing (the defer above owns that).
	// A half-sent sequence is a dropped command, not a corrupted one: the bridge holds
	// an incomplete reassembly that never dispatches and expires on its own.
	for f in frames {
		if ws.write_server_text(socket, f, false) != .Ok do return .Send_Failed
	}
	return .Ok
}

// write_ws_command_on_connection is write_ws_command with the locking done for the
// caller (REQ-ERR-PROTO-C). A command that fits one frame is written under
// writer_mutex like any frame. A CHUNKED command holds chunk_sequence_mutex for the
// whole sequence (sequences never interleave, see write_ws_command) but takes
// writer_mutex only per frame, so acks, pongs, stop_agent and small commands go out
// between its chunks instead of waiting behind up to ~2,700 frames of a large file
// write. A failed write shuts the socket down, as before.
// CHUNK_YIELD_MAX bounds how long a chunked command defers each chunk to waiting
// single-frame writers (REQ-ERR-PROTO-C).
CHUNK_YIELD_MAX :: 5 * time.Millisecond

write_ws_command_on_connection :: proc(connection: ^project_service.Bridge_Runtime_Connection, text: string) -> Command_Write_Result {
	payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
	if len(text) <= payload {
		project_service.bridge_runtime_connection_lock_writer(connection)
		defer sync.unlock(&connection.writer_mutex)
		socket := connection.socket
		if socket == net.TCP_Socket(0) || sync.atomic_load(&connection.retired) do return .Not_Connected
		if connection_refuse_if_expired(connection, socket) do return .Auth_Expired
		wrote := write_ws_command(socket, text)
		if wrote == .Send_Failed do _ = net.shutdown(net.Any_Socket(socket), .Both)
		return wrote
	}
	if !hub_command_is_chunkable(text, payload) do return .Too_Large
	frames := hub_command_chunk_frames(text, payload)
	if frames == nil do return .Send_Failed
	defer {
		for f in frames do delete(f)
		delete(frames)
	}
	sync.lock(&connection.chunk_sequence_mutex)
	defer sync.unlock(&connection.chunk_sequence_mutex)
	sync.lock(&connection.writer_mutex)
	socket := connection.socket
	expired := socket != net.TCP_Socket(0) && connection_refuse_if_expired(connection, socket)
	sync.unlock(&connection.writer_mutex)
	if socket == net.TCP_Socket(0) || sync.atomic_load(&connection.retired) do return .Not_Connected
	if expired do return .Auth_Expired
	for f, i in frames {
		// Let waiting single-frame writers (acks, pongs, small commands) go first, but
		// only for CHUNK_YIELD_MAX: a steady stream of small frames must not starve the
		// sequence. After that the chunk competes for the lock like any writer.
		yield_started := time.tick_now()
		for sync.atomic_load(&connection.writer_waiters) > 0 && time.tick_since(yield_started) < CHUNK_YIELD_MAX do thread.yield()
		sync.lock(&connection.writer_mutex)
		// Retired, or the socket was cleared, mid-sequence: the rest goes nowhere. The
		// bridge's partial reassembly expires on its own (see write_ws_command).
		if connection.socket != socket || sync.atomic_load(&connection.retired) {
			sync.unlock(&connection.writer_mutex)
			return .Not_Connected if i == 0 else .Send_Failed
		}
		ok := ws.write_server_text(socket, f, false) == .Ok
		if !ok do _ = net.shutdown(net.Any_Socket(socket), .Both)
		sync.unlock(&connection.writer_mutex)
		if !ok do return .Send_Failed
	}
	return .Ok
}

// write_ws_text_frame writes ONE unmasked FIN+text frame, 16-bit length only,
// delegating to the unified ws.write_server_text implementation.
write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
	return ws.write_server_text(socket, text, false) == .Ok
}

// command_write_error maps a write result onto the domain error the API returns.
//
// AC1 LIVES HERE. .Too_Large becomes .Validation_Failed, which is HTTP 422 with code
// string "validation_failed"; .Send_Failed keeps .Bridge_Offline, which is HTTP 409 with
// "bridge_offline". Different status AND different code string, so the two are
// distinguishable in a log line rather than only in prose — which is the whole point,
// since the defect was an operator being pointed at a healthy bridge.
command_write_error :: proc(result: Command_Write_Result) -> domain.Domain_Error {
	switch result {
	case .Ok:
		return domain.Domain_Error{}
	case .Too_Large:
		return domain.domain_error(.Validation_Failed, "bridge command payload exceeds the chunked-delivery limit for the hub->bridge channel; the bridge is NOT offline")
	case .Send_Failed:
		return domain.domain_error(.Bridge_Offline, "bridge websocket command send failed")
	case .Not_Connected:
		return domain.domain_error(.Bridge_Offline, "bridge websocket command path is not connected")
	case .Auth_Expired:
		return domain.domain_error(.Bridge_Offline, "bridge credential has expired; its session is closing")
	}
	return domain.domain_error(.Internal_Error, "unknown bridge command write result")
}

json_string :: proc(body, key: string) -> string {
	return jsonx.extract_string(body, key)
}

json_bool :: proc(body, key: string) -> bool {
	return jsonx.extract_bool(body, key)
}
