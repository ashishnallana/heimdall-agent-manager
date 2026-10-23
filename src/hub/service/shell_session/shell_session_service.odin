package shell_session

// Hub-side shell session service: WS fan-out registry (T7) + CRUD operations,
// bridge command dispatch, preview token store (T5).

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import contracts "odin_test:contracts"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"
import jsonx "odin_test:lib/jsonx"

// Preview_Tunnel_Stream is an in-flight hub-side tunnel stream.
// Chunks are signalled via cond as they arrive; the proxy handler wakes and relays them.
Preview_Tunnel_Stream :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	chunks: [dynamic][]byte,
	closed: bool,
}

Shell_Session_Service :: struct {
	entitlements: domain.Entitlement_Lookup,
	// WS fan-out registry (T7) — protected by mu.
	mu:      sync.Mutex,
	viewers: map[string][dynamic]net.TCP_Socket, // session_id → attached WS client sockets
	// One write lock per session, guarding the VIEWER SOCKETS of that session against
	// interleaved writes — see shell_session_viewer_write_lock. The map itself is
	// protected by mu; the mutexes it holds are taken WITHOUT mu.
	viewer_write_mu: map[string]^sync.Mutex,
	viewer_writers: map[net.TCP_Socket]^Pane_Viewer_Writer,
	viewer_write_refs: map[string]int,
	user_viewer_counts: map[string]int, // user_id -> reserved PTY streams, protected by mu
	pane_poll_budgets: map[string]Pane_Poll_Budget,
	pane_poll_now: proc(ctx: rawptr) -> time.Tick, // optional monotonic test clock
	pane_poll_clock_ctx: rawptr,
	pane_bridge_bytes: map[string]int,
	// REQ-PTY-NET-4: last repaint per session, see shell_snapshot_cache.odin. Under mu.
	snapshot_cache: map[string]^Shell_Snapshot_Cache_Entry,
	// CRUD layer (T5) — session_owners and session_bridges also protected by mu.
	repo:                ^iface.Shell_Session_Repository,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	events:              ^events.User_Event_Bus,
	// Resolves the token-owned conversation binding; never writes messages.
	content:             ^content_service.Content_Service,
	ids:                 ^platform.ID_Generator,
	clock:               ^platform.Clock,
	session_owners:      map[string]string, // session_id → owner_user_id (heap strings)
	session_bridges:     map[string]string, // session_id → bridge_id (heap strings)
	kill_replay_bridges: [dynamic]string, // active paced replay, protected by mu
	kill_replay_workers: int, // detached workers still referencing this service
	kill_replay_shutdown: bool,
	kill_replay_cond: sync.Cond,
	// Tunnel stream registry (T8) — protected by tunnel_mu.
	tunnel_streams: map[string]^Preview_Tunnel_Stream, // stream_id → live stream
	tunnel_mu:      sync.Mutex,
	// Task System v2 (§4d): optional hook notified when an unobserved terminal
	// status is landed on a live row by inventory absence or gone-bridge reap
	// (_reap_inventory_absent) so verify Run sessions still get a verify facet
	// with exit_code = -1.
	on_unobserved_terminal:     proc(ctx: rawptr, session: domain.Shell_Session),
	on_unobserved_terminal_ctx: rawptr,
	live_agents: ^agent_service.Agent_Service,
}

new_shell_session_service :: proc(
	repo:                ^iface.Shell_Session_Repository = nil,
	bridge_command_sink: project_service.Bridge_Command_Sink = {},
	event_bus:           ^events.User_Event_Bus = nil,
	ids:                 ^platform.ID_Generator = nil,
	clock:               ^platform.Clock = nil,
	content:             ^content_service.Content_Service = nil,
) -> Shell_Session_Service {
	heap := runtime.heap_allocator()
	return Shell_Session_Service{
		viewers        = make(map[string][dynamic]net.TCP_Socket, heap),
		viewer_write_mu = make(map[string]^sync.Mutex, heap),
		viewer_writers = make(map[net.TCP_Socket]^Pane_Viewer_Writer, heap),
		viewer_write_refs = make(map[string]int, heap),
		user_viewer_counts = make(map[string]int, heap),
		pane_bridge_bytes = make(map[string]int, heap),
		repo            = repo,
		bridge_command_sink = bridge_command_sink,
		events          = event_bus,
		ids             = ids,
		clock           = clock,
		content         = content,
		session_owners  = make(map[string]string, heap),
		session_bridges = make(map[string]string, heap),
		kill_replay_bridges = make([dynamic]string, heap),
		tunnel_streams  = make(map[string]^Preview_Tunnel_Stream, heap),
	}
}

shell_session_service_free :: proc(svc: ^Shell_Session_Service) {
	if svc == nil do return
	pane_viewers_stop_all(svc)
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	// Replay workers are detached because reconnect must never block the WebSocket
	// reader. Service teardown is different: it must wait until no worker can still
	// dereference the maps below.
	svc.kill_replay_shutdown = true
	for svc.kill_replay_workers > 0 do sync.cond_wait(&svc.kill_replay_cond, &svc.mu)
	for k, viewers in svc.viewers {
		delete(k, heap)
		delete(viewers)
	}
	delete(svc.viewers)
	// Shutdown has drained readers and sequencing leases.
	for k, write_mu in svc.viewer_write_mu {
		delete(k, heap)
		free(write_mu, heap)
	}
	delete(svc.viewer_write_mu)
	delete(svc.viewer_write_refs)
	for user_id in svc.user_viewer_counts do delete(user_id, heap)
	delete(svc.user_viewer_counts)
	for user_id in svc.pane_poll_budgets do delete(user_id, heap)
	delete(svc.pane_poll_budgets)
	for k, v in svc.session_owners { delete(k, heap); delete(v, heap) }
	delete(svc.session_owners)
	for k, v in svc.session_bridges { delete(k, heap); delete(v, heap) }
	delete(svc.session_bridges)
	for bridge_id in svc.kill_replay_bridges do delete(bridge_id, heap)
	delete(svc.kill_replay_bridges)
	_snapshot_cache_free_all_locked(svc)
	sync.mutex_lock(&svc.tunnel_mu)
	defer sync.mutex_unlock(&svc.tunnel_mu)
	for k, stream in svc.tunnel_streams {
		delete(k, heap)
		for chunk in stream.chunks do delete(chunk, heap)
		delete(stream.chunks)
		free(stream, heap)
	}
	delete(svc.tunnel_streams)
}

// --- WS attach/detach (Attach-gated streaming, REQ-STREAM-IMPL-2) ---

Attach_Status :: enum { Attached, Late_Join, Rejected_Limit, Rejected }
Attach_Result :: struct { status: Attach_Status, err: domain.Domain_Error }

// Late_Join means this socket joined a session that ALREADY had viewers.
// Equivalently: whether this attach did NOT trigger a bridge attach. Reported from under
// the lock rather than inferred from a later viewer count, which would race a second
// viewer attaching concurrently.
//
// REQ-SHELL-29 introduced it to decide who needs a screen snapshot, on the reasoning that
// the 0->1 viewer is already served by the bridge's pty-host catchup
// (pty_host_stream_worker.odin .Screen case) and could be left alone.
//
// REQ-SHELL-61 RETIRED THAT USE AND THE REASONING BEHIND IT: the catchup is not a reliable
// paint for viewer #1 — it is skipped entirely when the bridge already has a live stream
// worker for the session (bridge_pty_stream_worker_start returns early without sending a
// fresh Attach), and a viewer #1 that gets no snapshot then has NO screen source at all.
// The snapshot is therefore sent to every attaching viewer; see
// shell_stream_should_send_screen_snapshot for the gate and why serving viewer #1 is safe.
// The value is still returned and still means exactly what it says — it is a truthful fact
// about the attach, useful for diagnostics, and its test still holds. It is simply no
// longer a gate.
//
// ws_kind is the heimdall_ws_* `kind` label for this viewer socket (telemetry only):
// project_service.WS_KIND_SHELL for the shells pane, WS_KIND_AGENT_STREAM for the
// agent pane. Pass one of those constants — the value is retained uncloned.
shell_session_attach :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket, bridge_id: string = "", ws_kind: string = project_service.WS_KIND_SHELL, user_id: string = "") -> Attach_Result {
	if svc == nil || session_id == "" do return {.Rejected, domain.domain_error(.Internal_Error, "PTY viewer service is unavailable")}
	parameters := domain.unlimited_entitlements()
	if user_id != "" {
		lookup_err: domain.Domain_Error
		parameters, lookup_err = domain.lookup_entitlements(svc.entitlements, user_id)
		if lookup_err.code != .None do return {.Rejected, lookup_err}
	}
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	if existing, exists := svc.viewer_writers[socket]; exists && (existing.session_id != session_id || existing.user_id != user_id) {
		sync.mutex_unlock(&svc.mu)
		return {.Rejected, domain.domain_error(.Conflict, "PTY viewer is already attached to another identity")}
	}
	if _, exists := svc.viewer_writers[socket]; !exists {
		current := svc.user_viewer_counts[user_id]
		if user_id != "" && parameters.max_concurrent_streams >= 0 && current >= parameters.max_concurrent_streams {
			sync.mutex_unlock(&svc.mu)
			return {.Rejected_Limit, domain.entitlement_limit_error(svc.entitlements, user_id, "max_concurrent_streams", parameters.max_concurrent_streams, current)}
		}
		same_bridge := 0
		for _, w in svc.viewer_writers { if w.bridge_id == bridge_id do same_bridge += 1 }
		if len(svc.viewer_writers) >= PANE_VIEWER_LIMIT || same_bridge >= PANE_VIEWERS_PER_BRIDGE {
			sync.mutex_unlock(&svc.mu)
			fmt.eprintln("ham-hub WARN pane viewer admission rejected: active viewer quota")
			return {.Rejected, domain.domain_error(.Rate_Limited, "PTY viewer capacity reached")}
		}
	}

	if _, ok := svc.viewers[session_id]; !ok {
		svc.viewers[strings.clone(session_id, heap)] = make([dynamic]net.TCP_Socket, heap)
	}
	prev_count := len(svc.viewers[session_id])
	already_present := false
	for s in svc.viewers[session_id] {
		if s == socket {
			already_present = true
			break
		}
	}
	if !already_present {
		if !pane_viewer_start_locked(svc, socket, bridge_id, session_id, ws_kind, user_id) {
			pane_sequence_collect_locked(svc, session_id)
			sync.mutex_unlock(&svc.mu)
			return {.Rejected, domain.domain_error(.Internal_Error, "Could not start PTY viewer")}
		}
		if user_id != "" {
			if svc.user_viewer_counts == nil do svc.user_viewer_counts = make(map[string]int, heap)
			if _, exists := svc.user_viewer_counts[user_id]; !exists do svc.user_viewer_counts[strings.clone(user_id, heap)] = 0
			svc.user_viewer_counts[user_id] += 1
		}
		// A new attach is never "already painted", even on a reused fd number.
		_snapshot_cache_forget_viewer_locked(svc, session_id, socket)
		append(&svc.viewers[session_id], socket)
	}

	// REQ-SHELL-1 §7: there is no DB fallback here any more. The key is
	// (bridge_id, session_id), so a by-session-id-alone lookup cannot be resolved
	// without guessing a bridge — and it never needed to be: every production
	// caller already passes one it read off an owner-scoped row
	// (shell_session_handlers.odin:110 passes session.bridge_id;
	// agent_instance_handlers.odin:152 passes inst.bridge_id). The in-memory map
	// still answers a re-attach for a session this process started.
	resolved_bridge := bridge_id
	if resolved_bridge == "" {
		if b, ok := svc.session_bridges[session_id]; ok do resolved_bridge = b
	}
	if resolved_bridge != "" {
		if old_bridge, ok := svc.session_bridges[session_id]; !ok {
			svc.session_bridges[strings.clone(session_id, heap)] = strings.clone(resolved_bridge, heap)
		} else if old_bridge != resolved_bridge {
			delete(old_bridge, heap)
			svc.session_bridges[session_id] = strings.clone(resolved_bridge, heap)
		}
	}

	should_attach := false
	target_bridge := ""
	if prev_count == 0 && resolved_bridge != "" {
		should_attach = true
		target_bridge = strings.clone(resolved_bridge, context.temp_allocator)
	}
	// REQ-SHELL-41 (P0 addendum): this is the 0->1 viewer transition, so arm the
	// first-frame log. The question it answers is "did ANY output actually reach the
	// browser after it attached" — which is the first thing to establish for a session
	// that renders nothing, and which no log line could answer before.
	if prev_count == 0 do shell_first_frame_arm(session_id)
	sync.mutex_unlock(&svc.mu)

	if should_attach && target_bridge != "" {
		cmd_id := ""
		if svc.ids != nil {
			cmd_id = platform.generate_id(svc.ids, "cmd_sh_attach_")
		}
		cmd_json := _shell_stream_attach_command_json(cmd_id, session_id)
		defer delete(cmd_json)
		_, _ = project_service.bridge_command_send_runtime(
			svc.bridge_command_sink,
			project_service.Runtime_Command{
				bridge_id  = target_bridge,
				command_id = cmd_id,
				body_json  = cmd_json,
			},
		)
	}
	return {.Late_Join if prev_count > 0 else .Attached, {}}
}

shell_session_detach :: proc(
	svc: ^Shell_Session_Service,
	session_id: string,
	socket: net.TCP_Socket,
	bridge_id: string = "",
	reason: Shell_Viewer_Detach_Reason = .Unspecified,
) {
	if svc == nil || session_id == "" do return
	sync.mutex_lock(&svc.mu)
	viewers, ok := &svc.viewers[session_id]
	if !ok {
		sync.mutex_unlock(&svc.mu)
		return
	}
	removed := false
	for i := 0; i < len(viewers); i += 1 {
		if viewers[i] == socket {
			ordered_remove(viewers, i)
			removed = true
			break
		}
	}

	should_detach := false
	target_bridge := ""
	if removed && len(viewers^) == 0 {
		should_detach = true
		if b, b_ok := svc.session_bridges[session_id]; b_ok {
			target_bridge = strings.clone(b, context.temp_allocator)
		} else if bridge_id != "" {
			target_bridge = strings.clone(bridge_id, context.temp_allocator)
		}
		// No by-session-id DB fallback — see the note in shell_session_attach.
	}
	remaining := len(viewers^)
	writer := svc.viewer_writers[socket]
	if removed {
		delete_key(&svc.viewer_writers, socket)
		if writer != nil && writer.user_id != "" {
			svc.user_viewer_counts[writer.user_id] -= 1
			if svc.user_viewer_counts[writer.user_id] == 0 {
				for key in svc.user_viewer_counts {
					if key == writer.user_id { delete_key(&svc.user_viewer_counts, key); delete(key, runtime.heap_allocator()); break }
				}
			}
		}
	}
	// The fd may be reused for the next viewer; it must not stay "painted".
	if removed do _snapshot_cache_forget_viewer_locked(svc, session_id, socket)
	if remaining == 0 do pane_sequence_collect_locked(svc, session_id)
	sync.mutex_unlock(&svc.mu)
	if removed && writer != nil do pane_viewer_stop(writer)

	// REQ-SHELL-41 (P0 addendum): EVERY detach, with the reason. This proc used to say
	// nothing at all, which is why a silently unsubscribed viewer — the REQ-SHELL-33
	// failure mode — left no trace whatsoever. Bounded by the viewer count, not by the
	// frame rate, so it is not per-frame logging.
	//
	// `viewer=` is the socket fd: the only stable identifier a viewer has here, and
	// enough to follow one viewer across its attach/detach pair in a log.
	// `bridge_detach=` records whether this was the LAST viewer, so the hub also told
	// the bridge to stop streaming — the difference between one browser tab closing and
	// the session's output actually being shut off.
	if removed {
		shell_metrics_note_detach(reason)
		fmt.println(
			"shell viewer detach", "session=", session_id,
			"viewer=", int(socket),
			"reason=", shell_viewer_detach_reason_string(reason),
			"remaining_viewers=", remaining,
			"bridge_detach=", should_detach)
	}

	if should_detach && target_bridge != "" {
		cmd_id := ""
		if svc.ids != nil {
			cmd_id = platform.generate_id(svc.ids, "cmd_sh_detach_")
		}
		cmd_json := _shell_stream_detach_command_json(cmd_id, session_id)
		defer delete(cmd_json)
		_, _ = project_service.bridge_command_send_runtime(
			svc.bridge_command_sink,
			project_service.Runtime_Command{
				bridge_id  = target_bridge,
				command_id = cmd_id,
				body_json  = cmd_json,
			},
		)
	}
}

shell_session_viewer_count :: proc(svc: ^Shell_Session_Service, session_id: string) -> int {
	if svc == nil || session_id == "" do return 0
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if viewers, ok := svc.viewers[session_id]; ok {
		count := 0
		for socket in viewers {
			if w, exists := svc.viewer_writers[socket]; exists { sync.mutex_lock(&w.mu); if !w.stopped do count += 1; sync.mutex_unlock(&w.mu) }
		}
		return count
	}
	return 0
}

// Acquire a sequencing-lock lease. It protects queue insertion, never network
// writes. Release with shell_session_viewer_write_release after unlocking.
shell_session_viewer_write_lock :: proc(svc: ^Shell_Session_Service, session_id: string) -> ^sync.Mutex {
	if svc == nil || session_id == "" do return nil
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if svc.viewer_write_refs == nil do svc.viewer_write_refs = make(map[string]int, heap)
	if existing, ok := svc.viewer_write_mu[session_id]; ok { svc.viewer_write_refs[session_id] += 1; return existing }
	created := new(sync.Mutex, heap)
	owned := strings.clone(session_id, heap)
	svc.viewer_write_mu[owned] = created
	svc.viewer_write_refs[owned] = 1
	return created
}

// shell_session_write_viewer_frame writes ONE frame to one viewer socket under that
// session's write lock. Use it for any single frame; for a multi-frame sequence take
// shell_session_viewer_write_lock yourself and hold it across the whole sequence.
// `opcode` is 0x1 for a JSON control frame, 0x2 for a pty_wire viewer frame.
shell_session_write_viewer_frame :: proc(
	svc: ^Shell_Session_Service,
	session_id: string,
	socket: net.TCP_Socket,
	text: string,
	opcode: u8 = 0x1,
) -> ws.Text_Write_Result {
	write_mu := shell_session_viewer_write_lock(svc, session_id)
	if write_mu == nil do return _write_ws_frame(socket, opcode, text)
	sync.mutex_lock(write_mu)
	defer { sync.mutex_unlock(write_mu); shell_session_viewer_write_release(svc, session_id) }
	return pane_viewer_enqueue(svc, socket, text, opcode)
}

// shell_session_write_viewer_binary writes one pty_wire viewer frame (REQ-PTY-NET-2).
shell_session_write_viewer_binary :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket, frame: []byte) -> ws.Text_Write_Result {
	return shell_session_write_viewer_frame(svc, session_id, socket, string(frame), 0x2)
}

// shell_session_broadcast_output fans PTY output to all WS clients attached to
// session_id as ONE binary viewer frame per call (REQ-PTY-NET-2): `payload` is the raw
// bytes, or nonce|tag|ciphertext when `is_encrypted` — exactly as the bridge sent it,
// never re-encoded.
shell_session_broadcast_output :: proc(svc: ^Shell_Session_Service, session_id: string, payload: []byte, is_encrypted: bool = false, is_snapshot: bool = false, source_bridge_id: string = "") {
	if svc == nil || session_id == "" do return
	if source_bridge_id != "" && !shell_session_bridge_owns_stream(svc, session_id, source_bridge_id) do return
	// heimdall_shell_output_bytes_total{bridge_id}: counted on arrival, before the
	// viewer check, so output for an unviewed session is still visible. The bridge id
	// is the caller's when it has one, else the session's recorded bridge. Payload
	// bytes, not envelope bytes.
	shell_metrics_note_output_for_session(svc, session_id, source_bridge_id, len(payload))
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_OUTPUT, contracts.pty_wire_flags(is_snapshot, is_encrypted), payload)
	defer delete(frame)
	// REQ-PTY-NET-4: remember the catch-up so a later joiner can be served from it and
	// the viewers painted by it are never repainted by the hub capture. Noted BEFORE the
	// fan-out so a first-resize that races the broadcast sees the entry.
	shell_session_snapshot_cache_note_output(svc, session_id, frame, is_snapshot, sockets)
	for sock in sockets {
		// The write happens under the session write lock; the detach deliberately does
		// NOT — it takes svc.mu, and nothing may hold the write lock while doing that.
		result := shell_session_write_viewer_binary(svc, session_id, sock, frame)
		_log_viewer_write("output", session_id, result, len(frame))
		if _viewer_write_ends_session(result) {
			// The queue/worker has already woken the reader. It owns detach.
			continue
		}

	}
}

// shell_session_broadcast_status fans a status-change event to all attached clients.
shell_session_broadcast_status :: proc(svc: ^Shell_Session_Service, session_id, status: string, exit_code: int, exit_code_set: bool) {
	if svc == nil || session_id == "" do return
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := _status_frame_json(status, exit_code, exit_code_set)
	defer delete(frame)
	for sock in sockets {
		result := shell_session_write_viewer_frame(svc, session_id, sock, frame)
		_log_viewer_write("status", session_id, result, len(frame))
		if _viewer_write_ends_session(result) {
			// The queue/worker has already woken the reader. It owns detach.
		}
	}
}

// shell_session_broadcast_stream_ready relays stream_ready to all attached WebSocket viewers (REQ-STREAM-EVENT-3).
// bridge_boot_id is the bridge's unseal boot id from its shell_pty_stream_ready event;
// viewers bind it into PTY v2 input frames (a restarted bridge refuses older ones).
shell_session_broadcast_stream_ready :: proc(svc: ^Shell_Session_Service, session_id: string, bridge_boot_id := "") {
	if svc == nil || session_id == "" do return
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := stream_ready_frame_json(session_id, bridge_boot_id)
	defer delete(frame)
	for sock in sockets {
		result := shell_session_write_viewer_frame(svc, session_id, sock, frame)
		_log_viewer_write("stream_ready", session_id, result, len(frame))
		if _viewer_write_ends_session(result) {
			// The queue/worker has already woken the reader. It owns detach.
		}
	}
}

// shell_session_broadcast_stream_closed relays stream_closed to all attached WebSocket viewers (REQ-STREAM-EVENT-3).
shell_session_broadcast_stream_closed :: proc(svc: ^Shell_Session_Service, session_id: string, exit_code: int, exit_code_set: bool) {
	if svc == nil || session_id == "" do return
	// REQ-PTY-NET-4: a closed stream's last repaint is history, not a screen to serve.
	shell_session_snapshot_cache_evict(svc, session_id)
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := _stream_closed_frame_json(session_id, exit_code, exit_code_set)
	defer delete(frame)
	for sock in sockets {
		result := shell_session_write_viewer_frame(svc, session_id, sock, frame)
		_log_viewer_write("stream_closed", session_id, result, len(frame))
		if _viewer_write_ends_session(result) {
			// The queue/worker has already woken the reader. It owns detach.
		}
	}
}

// shell_session_broadcast_vault_locked relays a bridge's typed `shell_pty_vault_locked`
// signal (T10, REQ-T10-3) to every viewer of the pane as
//   {"type":"error","code":"vault_locked","bridge_id":…,"session_id":…,"message":…}
// so agent and shell panes switch to their locked overlay without parsing the banner.
// Same ownership check as output: a bridge may only speak for streams it owns.
shell_session_broadcast_vault_locked :: proc(svc: ^Shell_Session_Service, session_id, source_bridge_id: string) {
	if svc == nil || session_id == "" || source_bridge_id == "" do return
	if !shell_session_bridge_owns_stream(svc, session_id, source_bridge_id) do return
	sockets := _copy_viewers(svc, session_id)
	defer delete(sockets)
	if len(sockets) == 0 do return
	frame := _vault_locked_frame_json(session_id, source_bridge_id)
	defer delete(frame)
	for sock in sockets {
		result := shell_session_write_viewer_frame(svc, session_id, sock, frame)
		_log_viewer_write("vault_locked", session_id, result, len(frame))
		if _viewer_write_ends_session(result) {
			// The queue/worker has already woken the reader. It owns detach.
		}
	}
}

// _publish_start_refused is the exit event the started-event comment in
// shell_session_create promises: the `starting` trace published before the bridge
// round trip is corrected on the same channel when the start fails, rather than
// left looking live until the next list refresh. A typed refusal (vault_locked)
// carries its code; anything else is a plain failed exit.
_publish_start_refused :: proc(svc: ^Shell_Session_Service, owner, session_id: string, err: domain.Domain_Error, bridge_id: string) {
	if svc == nil || svc.events == nil do return
	code := domain.VAULT_LOCKED_ERROR_CODE if err.code == .Vault_Locked else ""
	evt := _shell_exited_event_json(session_id, domain.Shell_Session_Status_Failed, 0, false, code, bridge_id)
	events.publish_owned(svc.events, owner, evt)
}

// _vault_locked_frame_json is the viewer-facing typed error frame. `message` keeps the
// shape older clients already render for {type:"error"}; `code` is what new ones match.
_vault_locked_frame_json :: proc(session_id, bridge_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"error\",\"code\":\"")
	strings.write_string(&b, domain.VAULT_LOCKED_ERROR_CODE)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	contracts.write_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"message\":\"")
	contracts.write_json_string(&b, domain.VAULT_LOCKED_MESSAGE)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// --- CRUD service procs (T5) ---

Shell_Session_Create_Input :: struct {
	bridge_id:         string,
	kind:              string, // "run" | "shell" | "server" (domain.Shell_Session_Kind)
	cmd:               string,
	cwd:               string,
	label:             string,
	project_id:        string,
	chain_id:          string,
	agent_instance_id: string,
	conversation_id:   string,
	server_port:       int,
	// background — kind=run only. The caller's EXPLICIT intent (ham-ctl's --bg).
	// REQ-SHELL-2 deleted the 15s rule that used to infer this from elapsed time,
	// so there is no path by which a foreground run becomes background without
	// somebody asking.
	background:        bool,
	enc_spec:          string,
	// session_id — optional, chosen by the caller (finding N1): the browser / ham-ctl
	// seals it into enc_spec so the bridge can bind the spec to this one session. It
	// must be "sh_" + 32 lowercase hex (128 random bits) and must not exist yet;
	// empty means the hub assigns one (such a start carries no bindable enc_spec and
	// a bridge refuses it).
	session_id:        string,
}

SHELL_SESSION_CLIENT_ID_HEX :: 32

// shell_session_client_id_valid: "sh_" + 32 lowercase hex. The length keeps a
// client-chosen id disjoint from hub-generated ones ("sh_" + hex nanoseconds).
shell_session_client_id_valid :: proc(id: string) -> bool {
	if len(id) != 3 + SHELL_SESSION_CLIENT_ID_HEX || !strings.has_prefix(id, "sh_") do return false
	for c in transmute([]u8)id[3:] {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

// _shell_session_starter_from_auth derives WHO is asking to start a process, for
// the domain.SHELL_SESSION_STARTER_RULES check. It is shared by every entry point
// that spawns one — shell_session_create and shell_session_restart (REQ-SHELL-24)
// — so the two cannot drift: if the rules table gains a kind or changes a
// permission, both paths follow it without being edited.
//
// The starter is read from the AUTH KIND and from nothing else. An Instance_Token
// is an agent; everything else that authenticates is a user. Deriving it from a
// request body field instead would let a user simply claim to be an agent.
_shell_session_starter_from_auth :: proc(auth: contracts.Auth_Context) -> domain.Shell_Session_Starter {
	if auth.kind == .Instance_Token do return .Agent
	return .User
}

// User-authenticated shell operations consume the shells capability. Agent run
// and serve automation bypass billing, including entitlement lookup failures.
shell_session_require_shells :: proc(source: domain.Entitlement_Lookup, auth: contracts.Auth_Context) -> domain.Domain_Error {
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy do return {}
	entitlements, err := domain.lookup_entitlements(source, auth.user_id)
	if err.code != .None do return err
	if !entitlements.shells_enabled do return domain.entitlement_limit_error(source, auth.user_id, "shells_enabled", 0, 1)
	return {}
}

// shell_session_create creates a hub row with status=starting, sends shell_start to
// the bridge, and updates the row to running/failed based on the bridge reply.
shell_session_create :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, input: Shell_Session_Create_Input) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	if input.bridge_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")

	// N3: an omitted kind used to default to `run`, which no user can legitimately
	// start. validate_scope then refused with "agent_instance_id is required for
	// kind run" — a 400 telling a plain REST caller about an agent field it never
	// mentioned, for a kind it could never have meant.
	//
	// It now defaults to `shell`, the kind a person opening a session means, which
	// is also what ham-ctl has always defaulted to (shell_cmds.odin). Chosen over
	// requiring an explicit kind because it cannot break a caller that works today:
	// every existing caller sends one (the UI always does, ham-ctl always does, and
	// the run/serve verbs below always do), so nothing is silently re-pointed at a
	// different kind. An AGENT that omits kind now gets "a shell session may only
	// be started by a user; pass kind=run or kind=server" from the starter rule
	// below — which names the kinds it can actually use, instead of a scope error
	// about a column.
	kind := input.kind
	if kind == "" do kind = domain.Shell_Session_Kind_Shell
	kind_enum, known := domain.shell_session_kind_from_string(kind)
	if !known {
		return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("unknown shell session kind %q (expected run, shell or server)", kind))
	}

	// WHO may start this kind (REQ-SHELL-2 §1). `run` is AGENT-ONLY and the
	// description is explicit that this must be enforced at the API, not only in
	// the UI — so it is enforced HERE, in the service, which every transport goes
	// through. The REST handler is not the gate; it cannot be, because the same
	// service backs any other caller that is added later.
	//
	// shell_session_restart applies this SAME rule (REQ-SHELL-24) — a restart is a
	// start — which is why the starter derivation lives in the shared helper rather
	// than here. See _shell_session_starter_from_auth for why it reads the auth kind
	// and nothing the caller can put in a body.
	starter := _shell_session_starter_from_auth(auth)
	if !domain.shell_session_kind_may_start(kind_enum, starter) {
		return {}, false, domain.domain_error(.Forbidden, fmt.tprintf(
			"a %q session may only be started by %s", kind, domain.shell_session_starters_string(kind_enum)))
	}

	if kind_enum == .Shell || kind_enum == .Server {
		if plan_err := shell_session_require_shells(svc.entitlements, auth); plan_err.code != .None {
			return {}, false, plan_err
		}
	}

	// An agent's run is scoped to the agent that started it, and the hub knows
	// which agent that is from the token. Filling it from the auth context rather
	// than the body means a run cannot be attributed to a different agent instance
	// by asking, and an agent never has to name itself to start its own run.
	input := input
	if starter == .Agent && auth.agent_instance_id != "" {
		if kind_enum == .Run do input.agent_instance_id = auth.agent_instance_id
		// Keep the operational session bound to the token-owned conversation.
		// This lookup is read-only; live tools never write conversation markers.
		if kind_enum == .Run && svc.content != nil {
			if c, conv_ok, _ := content_service.get_conversation_by_instance(svc.content, auth, auth.agent_instance_id); conv_ok {
				input.conversation_id = c.conversation_id
			} else {
				// Discard an unverified body binding when no conversation exists.
				input.conversation_id = ""
			}
		}
	}
	// A `shell` may omit cmd; the bridge falls back to $SHELL. Every other kind needs an
	// explicit command. A client start carries cmd and cwd ONLY inside the sealed
	// enc_spec (the hub never sees them in clear; the bridge enforces "missing cmd");
	// a hub-built start without an enc_spec still needs its plaintext cmd here.
	if input.cmd == "" && input.enc_spec == "" && kind != domain.Shell_Session_Kind_Shell do return {}, false, domain.domain_error(.Validation_Failed, "cmd is required")

	// THE HUB CLOCK IS AUTHORITATIVE (REQ-SHELL-1 §8). This `now` is the one
	// started_at for this session: it is what the row stores, and it is sent to the
	// bridge in the shell_start spec so the bridge's own retention window measures
	// age against the SAME value rather than against its local clock. Before this
	// there were two started_at values for one fact — the hub's, which the 1-day
	// server reap reads, and the bridge's, which the output-retention sweep reads —
	// and clock skew made them disagree about how old a session was. Bridge-local
	// timestamps still exist (Bridge_Shell_Session.started_unix_ms) but are
	// diagnostic only and must never drive a lifecycle decision.
	now := platform.clock_now(svc.clock)
	session_id := input.session_id
	if session_id != "" {
		if !shell_session_client_id_valid(session_id) {
			return {}, false, domain.domain_error(.Validation_Failed, "session_id must be sh_ followed by 32 lowercase hex characters")
		}
		// Never adopt an id that already names a session: neither a stored row on this
		// bridge nor a live one tracked in memory (which is keyed by session_id alone).
		_, exists, get_err := iface.shell_session_get_by_id(svc.repo, input.bridge_id, session_id)
		if get_err.code != .None do return {}, false, get_err
		sync.mutex_lock(&svc.mu)
		_, tracked := svc.session_owners[session_id]
		sync.mutex_unlock(&svc.mu)
		if exists || tracked do return {}, false, domain.domain_error(.Conflict, "session_id is already in use")
	} else {
		session_id = platform.generate_id(svc.ids, "sh_")
	}

	session := domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = string(owner),
		bridge_id         = input.bridge_id,
		project_id        = input.project_id,
		chain_id          = input.chain_id,
		agent_instance_id = input.agent_instance_id,
		kind              = kind,
		label             = input.label,
		cmd               = input.cmd,
		cwd               = input.cwd,
		status            = domain.Shell_Session_Status_Starting,
		server_port       = input.server_port,
		conversation_id   = input.conversation_id,
		// Only a run has a foreground form, so only a run can be born background.
		// A shell or a server carrying this flag would be describing nothing.
		background        = input.background && kind_enum == .Run,
		started_at        = now,
		created_at        = now,
		last_activity_at  = now,
	}

	// Per-kind scope enforcement (REQ-SHELL-1 §5). Validated BEFORE the row is
	// written and before the bridge is asked to spawn anything, so a kind missing
	// its scope columns is rejected rather than silently stored. The rule itself
	// lives in the domain — this is the enforcement point, not a second copy of it.
	if col, missing, scope_ok := domain.shell_session_validate_scope(session); !scope_ok {
		if missing {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("%s is required for kind %q", col, kind))
		}
		return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("%s must be empty for kind %q", col, kind))
	}

	// PORT CONFLICT (REQ-SHELL-2 §10). Detected AT CREATE and refused, naming the
	// session that already holds the port. Before this the second server silently
	// lost the bind, or the preview pointed at whichever process happened to win —
	// a failure with no error anywhere in the system and nothing to read afterwards.
	//
	// Checked for ANY kind that declares a port, not only `server`. A port may be
	// declared for any kind (XM-8/XM-12) and a `shell` someone started a server
	// inside contends for the bind exactly the same way; restricting the check to
	// servers would leave the cheapest way to reproduce the bug wide open.
	//
	// Only LIVE sessions hold a port — a terminal one has released it — and "live"
	// here is the domain's terminal-status set inverted, the same definition the
	// `live` filter uses.
	if session.server_port > 0 {
		holder, held, port_err := iface.shell_session_find_live_by_port(svc.repo, input.bridge_id, session.server_port)
		if port_err.code != .None do return {}, false, port_err
		if held {
			// THE MESSAGE IS ASYMMETRIC ON PURPOSE — do not collapse these two branches
			// back into one. The LOOKUP is deliberately owner-unscoped (a TCP port is a
			// host resource, so a cross-tenant conflict is a real conflict and hiding it
			// would resurface as an unexplained failed bind), but the ANSWER must not
			// leak across tenants.
			//
			// Naming the holder is useful precisely when the caller can act on it, and
			// telling someone to "kill" a session they cannot and must not be able to
			// touch is both a disclosure of another tenant's session id and kind, and
			// advice they cannot follow.
			if holder.owner_user_id == string(owner) {
				return {}, false, domain.domain_error(.Conflict, fmt.tprintf(
					"port %d is already held on this bridge by session %s (%s); kill it or choose another port",
					session.server_port, holder.session_id, holder.kind))
			}
			// Different owner: the conflict is reported, the holder is not. No session
			// id, no kind, no owner, no hint who holds it.
			return {}, false, domain.domain_error(.Conflict, fmt.tprintf(
				"port %d is already in use on this bridge; choose another port", session.server_port))
		}
	}

	// CAPS (REQ-SHELL-2 §11). A runaway backstop, not a scheduling policy: nothing
	// bounded how many sessions an agent or a chain could spawn, so a loop that
	// starts one per iteration could exhaust the host's pids and output disk with
	// no refusal anywhere. Each cap's SCOPE follows that kind's own scope rule
	// rather than being chosen separately — runs are agent-scoped so the cap is per
	// agent instance, servers are chain-scoped so it is per chain.
	if cap_err, over := _shell_session_check_cap(svc, string(owner), kind_enum, session); over {
		return {}, false, cap_err
	}

	_, upsert_err := iface.shell_session_upsert(svc.repo, session)
	if upsert_err.code != .None do return {}, false, upsert_err

	// Track owner and bridge for handle_exited and attach-gating (heap-allocated keys + values).
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	svc.session_owners[strings.clone(session_id, heap)] = strings.clone(string(owner), heap)
	svc.session_bridges[strings.clone(session_id, heap)] = strings.clone(input.bridge_id, heap)
	sync.mutex_unlock(&svc.mu)

	// Notify the operational session lists for all three kinds before the bridge
	// round trip. A refused start is corrected by the terminal event below.
	if svc.events != nil {
		evt := _shell_session_started_event_json(session_id, session.kind, session.status, session.chain_id)
		// `owner` is a User_ID here, unlike the exited path where it has already been
		// read back out of svc.session_owners as a plain string.
		events.publish_owned(svc.events, string(owner), evt)
	}

	// Send shell_start to bridge and wait for reply.
	// cmd_id is NOT freed here, and must not be. platform.generate_id returns
	// fmt.tprintf memory — the PER-THREAD TEMP ALLOCATOR — so delete()ing it is a bad
	// free against context.allocator, not a reclaim. The same applies to the cmd_id in
	// every other command helper in this file; none of them free it.
	//
	// Nothing needs freeing: the value is consumed within this request (the send path
	// copies it) and the temp arena is reclaimed wholesale, so simply not deleting is
	// the whole fix. A clone would also work but would be strictly more code for no
	// gain — clone only when you intend to OWN the value, e.g. when it must outlive the
	// request (see the wire_id clone in lsp_session_handlers.odin).
	cmd_id := platform.generate_id(svc.ids, "cmd_sh_start_")
	cmd_json := _shell_start_command_json(cmd_id, session_id, kind, input.cmd, input.cwd, input.label, input.project_id, input.chain_id, input.agent_instance_id, string(owner), now, input.server_port, input.background, session.run_seq, input.enc_spec)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{
			bridge_id  = input.bridge_id,
			command_id = cmd_id,
			body_json  = cmd_json,
		},
		30_000,
	)

	// REQ-SHELL-16 D2: a start failure is a TERMINAL row, so it must carry a finish
	// time. Both branches below set Failed; neither stamped finished_at, which left
	// exactly one row in the table terminal with no finish time (sh_18d97f993089313f)
	// and made anything that reasons over terminal rows by finished_at skip it silently.
	// The clock string is temp-allocated and that is correct here — it is consumed by
	// the upsert inside this request, the same as last_activity_at a few lines below.
	//
	// exit_code IS DELIBERATELY LEFT UNSET, and not as a style preference: this is one
	// of the SYNTHESIZED terminals that domain/shell_session.odin:356-392 names by name
	// ("shell_session_create's failure path"). That invariant requires a synthesized
	// terminal never to set exit_code_set, because shell_session_terminal_is_observed
	// uses it as the discriminator — stamping a fabricated code here would make the hub
	// call a guess an observation, and a later real exit from the bridge would stop
	// being allowed to supersede it, with no test failing. There was no process, so
	// there is no code to record.
	if !reply_ok {
		session.status      = domain.Shell_Session_Status_Failed
		session.finished_at = platform.clock_now(svc.clock)
		_, _ = iface.shell_session_upsert(svc.repo, session)
		_publish_start_refused(svc, string(owner), session_id, reply_err, session.bridge_id)
		return session, false, reply_err
	}
	defer delete(reply)

	if !_json_bool(reply, "ok") {
		session.status      = domain.Shell_Session_Status_Failed
		session.finished_at = platform.clock_now(svc.clock)
		_, _ = iface.shell_session_upsert(svc.repo, session)
		start_err := _bridge_failure(reply, "bridge failed to start shell session", session.bridge_id)
		_publish_start_refused(svc, string(owner), session_id, start_err, session.bridge_id)
		return session, false, start_err
	}

	session.pid             = _json_int(reply, "pid", 0)
	session.last_activity_at = platform.clock_now(svc.clock)

	// KILL BEFORE START (REQ-SHELL-3 work item 5b). A kill can be accepted while this
	// start is still in flight: the row exists with status='starting' and pid=0, so
	// there was nothing to signal yet, and naively the session would spawn and run
	// forever carrying an intent nobody ever applied.
	//
	// Re-read the row rather than trusting the `session` value built before the bridge
	// round trip. That local copy is now up to 30 seconds stale — it predates the
	// shell_start send — so it cannot answer either of the two questions below.
	//
	// The re-read is owner-scoped like every other read on this path, and a failed
	// re-read falls through to the plain Running write: the bridge half of 5b
	// (bridge_hub_handle_shell_start consuming its pending intent at spawn time) still
	// applies the kill, so a re-read that cannot be done degrades to the bridge's
	// guarantee rather than to silence.
	if current, still_there, reread_err := iface.shell_session_get(svc.repo, string(owner), session_id); still_there && reread_err.code == .None {
		// (1) Do not resurrect a row that already went terminal. A shell_exited for a
		// session killed this early can land while we are still holding the start reply,
		// and writing Running over it would report a dead process as live — with no
		// further event coming to correct it.
		if domain.shell_session_is_terminal(current) {
			return current, true, domain.Domain_Error{}
		}
		// (2) Apply an intent that arrived during the start. The pid exists now, so the
		// kill has something to act on; re-dispatching is safe because the bridge no-ops
		// a redelivered kill, and it is necessary because the kill the user asked for may
		// have reached a bridge that had never heard of this session.
		if domain.shell_session_kill_intent_pending(current) {
			session.status           = domain.Shell_Session_Status_Running
			session.kill_requested_at = current.kill_requested_at
			_, _ = iface.shell_session_upsert(svc.repo, session)
			_ = _shell_session_dispatch_kill(svc, session.bridge_id, session_id, session.run_seq)
			return session, true, domain.Domain_Error{}
		}
	}

	session.status          = domain.Shell_Session_Status_Running
	if _, up_err := iface.shell_session_upsert(svc.repo, session); up_err.code == .None do _shell_session_publish_changed(svc, session, "running")
	return session, true, domain.Domain_Error{}
}

// Shell_Session_Kill_Outcome classifies an ACCEPTED kill (REQ-SHELL-3). Both values
// are successes; they differ in whether the process is already being torn down.
//
// This exists because "we killed it" and "we wrote down that you want it killed"
// are different facts and the caller acts on them differently. Before it, both
// returned a bare `true` and the handler answered a flat {"ok":true}, so a user
// could click kill, see success, and watch the shell keep running — and the whole
// durability guarantee was unobservable from outside the hub.
//
// A named outcome enum rather than a second bool, matching device_auth.Poll_Status
// and push.Push_Send_Class: the caller switches on a value that says what happened
// instead of decoding a pair of booleans.
Shell_Session_Kill_Outcome :: enum {
	// Delivered — the shell_kill command reached the bridge. The process is being
	// torn down now (SIGTERM, then SIGKILL after the bridge's 5s grace window).
	Delivered,
	// Queued — the bridge could not be reached, so the intent is DURABLE on the row
	// and will be delivered when that bridge's WS reconnects. The process is still
	// running, and if the bridge never returns it keeps running: see REQ-SHELL-14,
	// which owns landing a terminal status for a bridge that never comes back.
	Queued,
}

// shell_session_kill_outcome_string is the wire spelling, so the transport and the
// CLI name an outcome with the service's vocabulary rather than their own.
shell_session_kill_outcome_string :: proc(outcome: Shell_Session_Kill_Outcome) -> string {
	switch outcome {
	case .Delivered: return "delivered"
	case .Queued:    return "queued"
	}
	return "delivered"
}

// shell_session_kill_outcome_message is the human sentence for an outcome — what
// the CLI prints and the UI can show verbatim. It lives here, with the enum, so the
// two spellings cannot drift apart across the transport boundary.
shell_session_kill_outcome_message :: proc(outcome: Shell_Session_Kill_Outcome) -> string {
	switch outcome {
	case .Delivered: return "kill delivered to the bridge"
	case .Queued:    return "kill queued; bridge offline, will apply on reconnect"
	}
	return ""
}

// shell_session_kill accepts a kill for a session and reports whether it was
// DELIVERED or QUEUED (REQ-SHELL-3).
//
// WHAT CHANGED AND WHY. This was fire-and-forget: it sent shell_kill and, when the
// bridge was offline, bridge_command_send_runtime returned Bridge_Offline and this
// returned that error having PERSISTED NOTHING. There was no pending intent, no
// outbox and no replay, so nothing re-issued the kill when the bridge came back and
// the process ran forever. The user's requirement is the opposite: "we should be
// able to kill shells reliably even if the bridge is disconnected; the next time it
// is connected the shell should be killed if it is still running."
//
// ORDER IS THE WHOLE FIX: persist the intent, THEN dispatch. Dispatching first and
// persisting only on failure would lose the intent to a crash in between, and would
// make durability depend on the delivery path failing in the expected way.
//
// AN OFFLINE BRIDGE IS A SUCCESS, NOT AN ERROR. The intent is durable and the
// delivery is asynchronous, so the accept succeeds and the outcome says `Queued`.
// The caller is told plainly which happened — a queued kill must never be
// indistinguishable from a delivered one, or a user sees success while the shell
// keeps running.
//
// A TERMINAL SESSION IS STILL A CONFLICT. Nothing is signalled and no intent is
// written for a session that has already finished: there is no process to kill, and
// its pid may by now belong to something else. That is the pre-existing contract of
// this call and it is deliberately unchanged — the idempotency REQ-SHELL-3 requires
// is about DELIVERY (the bridge no-ops a redelivered kill) and about re-requesting a
// kill that is already pending (below), not about resurrecting a finished session.
//
// A SECOND KILL WHILE ONE IS PENDING is a success, not a conflict. The repository
// write is first-writer-wins so the original timestamp stands, and the command is
// re-dispatched because redelivery is a no-op on the bridge — that is cheaper and
// more robust than deciding here that the first attempt must have worked.
shell_session_kill :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (Shell_Session_Kill_Outcome, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return .Queued, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return .Queued, false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return .Queued, false, repo_err
	if !found do return .Queued, false, domain.domain_error(.Not_Found, "session not found")
	if domain.shell_session_is_terminal(session) do return .Queued, false, domain.domain_error(.Conflict, "session has already terminated")

	// RE-DISPATCH ON AN ALREADY-PENDING INTENT IS DELIBERATE HERE, and is the one
	// behaviour this path does NOT share with the REQ-SHELL-9 reaps that call the same
	// helper below. A human clicking kill a second time means "try again"; a sweep
	// running for the 4320th time today means nothing new. Same recording, different
	// skip rule — see shell_session_reap.odin, which states the other half.
	return _shell_session_record_and_dispatch_kill(svc, string(owner), session_id, session.bridge_id, session.run_seq)
}

// _shell_session_record_and_dispatch_kill is the REQ-SHELL-3 sequence itself: make the
// intent durable, then try to deliver it. It is the ONE definition of that order, shared
// by the user-facing accept path above and by the REQ-SHELL-9 chain and age reaps, so a
// reap cannot drift back into the fire-and-forget send REQ-SHELL-3 exists to replace.
//
// It takes an OWNER STRING rather than an Auth_Context on purpose: the reaps have no
// authenticated user at all (the age sweep runs on the reaper thread), and the owner they
// pass comes off the row or the chain they already read. Authorisation is the caller's —
// this proc records an already-decided kill and must not be reached from a handler that
// has not established who is asking.
//
// The `pending` bool is checked, not discarded: it reports that the row exists for this
// owner and now carries an intent. It can be false even though the caller's read
// succeeded — the row can be deleted between the two — and returning success then would
// be the exact lie this whole change exists to remove: an accepted kill with nothing
// persisted and nothing to replay.
//
// clock_now is BORROWED, not freed: it is a temp allocation (platform/clock.odin
// format_rfc3339_utc -> fmt.tprintf), and set_kill_requested binds it as SQLite text,
// which copies at bind time. Nothing here needs it to outlive the call.
_shell_session_record_and_dispatch_kill :: proc(
	svc:        ^Shell_Session_Service,
	owner:      string,
	session_id: string,
	bridge_id:  string,
	run_seq:    int,
) -> (Shell_Session_Kill_Outcome, bool, domain.Domain_Error) {
	pending, intent_err := iface.shell_session_set_kill_requested(svc.repo, owner, session_id, platform.clock_now(svc.clock))
	if intent_err.code != .None do return .Queued, false, intent_err
	if !pending do return .Queued, false, domain.domain_error(.Not_Found, "session not found")

	outcome := _shell_session_dispatch_kill(svc, bridge_id, session_id, run_seq)
	return outcome, true, domain.Domain_Error{}
}

// _shell_session_dispatch_kill sends one shell_kill and classifies the result. It is
// the ONE place the send is interpreted, shared by the accept path above and the
// reconnect replay below, so "what counts as delivered" cannot differ between them.
//
// Every send failure is Queued, not only Bridge_Offline. The intent is already
// durable by the time this runs, so a failure of any kind leaves exactly the state
// Queued describes — the kill has not been delivered and the replay will retry it on
// the next reconnect. Reporting a transient send failure as delivered would be the
// one dishonest answer available here.
_shell_session_dispatch_kill :: proc(svc: ^Shell_Session_Service, bridge_id, session_id: string, run_seq: int) -> Shell_Session_Kill_Outcome {
	// Stable across reconnect replay: the Bridge can deduplicate a kill that was
	// delivered before the socket dropped without repeating the side effect. The
	// run sequence prevents an old cached kill from suppressing a later kill after
	// this durable session has been restarted.
	cmd_id := fmt.aprintf("cmd_shell_kill_%s_%d", session_id, run_seq)
	defer delete(cmd_id)
	cmd_json := _shell_kill_command_json(cmd_id, session_id)
	defer delete(cmd_json)
	sent, _ := project_service.bridge_command_send_runtime(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	return sent ? .Delivered : .Queued
}

// SHELL_SESSION_KILL_REPLAY_MAX bounds one reconnect's replay. It is a runaway
// backstop, not pagination: the outstanding set on one bridge is normally empty and
// is bounded in practice by the live-session caps (REQ-SHELL-2 §11), so this only
// ever caps a pathological database. Anything beyond it is picked up by the next
// reconnect, since the intents stay on their rows until delivered and cleared.
SHELL_SESSION_KILL_REPLAY_MAX :: 256
SHELL_SESSION_KILL_REPLAY_WINDOW :: 8
SHELL_SESSION_KILL_REPLAY_MAX_ATTEMPTS :: 4
SHELL_SESSION_KILL_REPLAY_BASE_BACKOFF_MS :: 100

Shell_Kill_Replay_Work :: struct {
	svc: ^Shell_Session_Service,
	bridge_id: string,
}

shell_session_kill_replay_delay_ms :: proc(attempt: int, retry_after_ms: int, bridge_id: string) -> int {
	base := SHELL_SESSION_KILL_REPLAY_BASE_BACKOFF_MS
	for _ in 1..<attempt do base = min(base * 2, 2000)
	if retry_after_ms > base do base = min(retry_after_ms, 2000)
	seed := 0
	for ch in transmute([]u8)bridge_id do seed = (seed * 33 + int(ch)) % 97
	return min(base + seed, 2500)
}

_shell_session_dispatch_kill_wait :: proc(svc: ^Shell_Session_Service, bridge_id, session_id: string, run_seq: int) -> (outcome: Shell_Session_Kill_Outcome, busy: bool, retry_after_ms: int) {
	if svc.bridge_command_sink.send_runtime_command_wait == nil {
		return _shell_session_dispatch_kill(svc, bridge_id, session_id, run_seq), false, 0
	}
	cmd_id := fmt.aprintf("cmd_shell_kill_%s_%d", session_id, run_seq)
	defer delete(cmd_id)
	cmd_json := _shell_kill_command_json(cmd_id, session_id)
	defer delete(cmd_json)
	result, sent, err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = cmd_json},
		5000,
	)
	defer if result != "" do delete(result)
	if sent do return .Delivered, false, 0
	if err.code == .Bridge_Busy {
		return .Queued, true, jsonx.extract_int(err.details_json, "retry_after_ms", 1000)
	}
	return .Queued, false, 0
}

shell_session_replay_kill_intents_paced :: proc(svc: ^Shell_Session_Service, bridge_id: string) -> (delivered: int, outstanding: int) {
	if svc == nil || svc.repo == nil || bridge_id == "" do return 0, 0
	sessions, list_err := iface.shell_session_list_pending_kills(svc.repo, bridge_id, SHELL_SESSION_KILL_REPLAY_MAX)
	if list_err.code != .None do return 0, 0
	defer domain.shell_sessions_destroy(sessions)

	// Count the whole obligation before sending. If replay stops on overload or a
	// disconnect, callers must still see every intent that remains outstanding,
	// including rows later in this bounded batch.
	for session in sessions {
		if domain.shell_session_kill_intent_pending(session) do outstanding += 1
	}

	produced := 0
	for session in sessions {
		if !domain.shell_session_kill_intent_pending(session) do continue
		delivered_this := false
		for attempt in 1..=SHELL_SESSION_KILL_REPLAY_MAX_ATTEMPTS {
			outcome, busy, retry_after_ms := _shell_session_dispatch_kill_wait(svc, bridge_id, session.session_id, session.run_seq)
			if outcome == .Delivered {
				delivered += 1
				produced += 1
				delivered_this = true
				break
			}
			if !busy do return delivered, outstanding
			time.sleep(time.Duration(shell_session_kill_replay_delay_ms(attempt, retry_after_ms, bridge_id)) * time.Millisecond)
		}
		// Four consecutive busy responses are a saturation signal, not permission to
		// move on and enqueue the rest of the reconnect backlog.
		if !delivered_this do return delivered, outstanding
		if produced > 0 && produced % SHELL_SESSION_KILL_REPLAY_WINDOW == 0 {
			time.sleep(time.Duration(shell_session_kill_replay_delay_ms(produced / SHELL_SESSION_KILL_REPLAY_WINDOW, 0, bridge_id)) * time.Millisecond)
		}
	}
	return delivered, outstanding
}

shell_session_kill_replay_worker :: proc(data: rawptr) {
	work := (^Shell_Kill_Replay_Work)(data)
	if work == nil do return
	dbt.scope_begin(.Shell)
	delivered, outstanding := shell_session_replay_kill_intents_paced(work.svc, work.bridge_id)
	dbt.scope_end_background()
	if outstanding > 0 {
		fmt.println("shell kill replay", "bridge=", work.bridge_id, "outstanding=", outstanding, "delivered=", delivered)
	}
	if delivered < outstanding {
		fmt.println("shell kill replay SHORTFALL: outstanding kills were not delivered to the bridge", "bridge=", work.bridge_id, "undelivered=", outstanding - delivered)
	}
	heap := runtime.heap_allocator()
	sync.mutex_lock(&work.svc.mu)
	for bridge_id, i in work.svc.kill_replay_bridges {
		if bridge_id != work.bridge_id do continue
		delete(bridge_id, heap)
		ordered_remove(&work.svc.kill_replay_bridges, i)
		break
	}
	work.svc.kill_replay_workers -= 1
	sync.cond_broadcast(&work.svc.kill_replay_cond)
	sync.mutex_unlock(&work.svc.mu)
	delete(work.bridge_id, heap)
	free(work, heap)
}

// Reconnect replay is deliberately detached from the WebSocket accept/reader
// path. One active producer per Bridge emits bounded windows and honors Bridge
// overload feedback with capped exponential backoff and deterministic jitter.
shell_session_schedule_kill_replay :: proc(svc: ^Shell_Session_Service, bridge_id: string) -> bool {
	if svc == nil || bridge_id == "" do return false
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	if svc.kill_replay_shutdown {
		sync.mutex_unlock(&svc.mu)
		return false
	}
	for active in svc.kill_replay_bridges {
		if active == bridge_id {
			sync.mutex_unlock(&svc.mu)
			return false
		}
	}
	append(&svc.kill_replay_bridges, strings.clone(bridge_id, heap))
	svc.kill_replay_workers += 1
	sync.mutex_unlock(&svc.mu)
	work := new(Shell_Kill_Replay_Work, heap)
	work.svc = svc
	work.bridge_id = strings.clone(bridge_id, heap)
	// Heap-allocate the Thread record as well (see bridge_proxy_relay): the caller
	// is the bridge WS handshake, whose allocator is reclaimed before this worker ends.
	context.allocator = heap
	_ = thread.create_and_start_with_data(rawptr(work), shell_session_kill_replay_worker)
	return true
}

// shell_session_replay_kill_intents delivers this bridge's OUTSTANDING kills. It is
// called from the bridge-WS accept path once the command socket is registered, and
// it returns how many kills it delivered.
//
// PUSH, HUB -> BRIDGE, rather than a pull as part of the bridge's reconcile pass.
// The task allowed either; this is the choice with its reasoning.
//   - The intent lives in the hub DB, so the hub already knows the whole answer. A
//     pull would need a new bridge->hub request and a new hub endpoint to answer it,
//     to move data the hub could simply have sent.
//   - Decisively: the bridge's reconcile pass (bridge_shell_session_reconcile_now)
//     returns WITHOUT TOUCHING ANYTHING when the pty-host daemon is unreachable,
//     because without a daemon roster it cannot tell a live session from a dead one.
//     A kill riding that pass would then be silently deferred to the next reconnect
//     while appearing to work — which is the failure mode this task exists to remove,
//     reintroduced one layer down.
// It is NOT a poller either way: it runs once per reconnect, on an event, and adds no
// interval or sleep loop anywhere (AC5).
//
// Idempotency is the bridge's, and deliberately so: a redelivered kill hits a session
// the bridge already marked terminal and is a no-op there. Replaying a kill the bridge
// already actioned is therefore harmless, which is what makes it safe to replay the
// whole outstanding set on every reconnect without tracking what was delivered before.
//
// IT REPORTS OUTSTANDING AS WELL AS DELIVERED (REQ-SHELL-23 AC3), and the second
// number is the one that matters. This procedure used to return only `delivered`, and
// both call sites had no use for it — the bridge-WS one discarded it outright
// (`_ = ...`). A replay that found work and delivered NONE of it was therefore
// indistinguishable, at every call site and in every log, from a reconnect with
// nothing to do. That silence is why REQ-SHELL-3 shipped accepting kills it never
// delivered and why it took a hand-run reproduction to notice: the one place that
// knew a kill was outstanding threw the number away. `outstanding` is the count that
// passed the domain predicate, i.e. the kills this call was obliged to deliver, so
// `delivered < outstanding` at a call site is exactly the condition worth shouting
// about.
shell_session_replay_kill_intents :: proc(svc: ^Shell_Session_Service, bridge_id: string) -> (delivered: int, outstanding: int) {
	if svc == nil || svc.repo == nil || bridge_id == "" do return 0, 0

	// Owner-unscoped, bridge-scoped: this runs from the bridge-WS accept path, which
	// authenticates a BRIDGE and has no authenticated user to scope by.
	sessions, list_err := iface.shell_session_list_pending_kills(svc.repo, bridge_id, SHELL_SESSION_KILL_REPLAY_MAX)
	if list_err.code != .None do return 0, 0
	defer domain.shell_sessions_destroy(sessions)

	for session in sessions {
		// The repository query already excludes terminal rows; this re-asks with the
		// domain's own predicate so the rule is enforced by the definition rather than
		// by trusting the SQL to have encoded it. A spent intent must never be
		// re-delivered — the pid it named may since have been recycled.
		if !domain.shell_session_kill_intent_pending(session) do continue
		outstanding += 1
		if _shell_session_dispatch_kill(svc, bridge_id, session.session_id, session.run_seq) == .Delivered do delivered += 1
	}
	return delivered, outstanding
}

// shell_session_signal sends shell_signal to the bridge (fire-and-forget).
//
// SIGNAL STAYS BEST-EFFORT WHILE KILL BECOMES DURABLE (REQ-SHELL-3 work item 6),
// and this is a decision rather than an oversight. A kill is a request about a
// session's LIFECYCLE — "this must not be running any more" — which stays true
// however long the bridge is away, and is idempotent to re-deliver because its
// target state is terminal. An arbitrary signal is an interactive act aimed at a
// process AS IT IS NOW: SIGWINCH, SIGINT, SIGUSR1 mean something to a program at a
// moment, and replaying one minutes later against a process that has moved on — or,
// after a restart, against a different process under the same session — is not the
// same request being completed, it is a new and unasked-for one. There is also no
// durable state to converge on: "signal was requested" has no terminal condition to
// clear it, so it could only ever be an unbounded outbox.
// So a signal that cannot be delivered now is reported as failed, which is the
// honest answer, and the caller decides whether to ask again.
shell_session_signal :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, signal: int) -> (bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return false, repo_err
	if !found do return false, domain.domain_error(.Not_Found, "session not found")

	cmd_json := _shell_signal_command_json(session_id, signal)
	defer delete(cmd_json)
	sent, send_err := project_service.bridge_command_send_runtime(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// shell_session_restart sends shell_restart to the bridge and updates the row.
shell_session_restart :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	// REQ-SHELL-24: WHO MAY START THIS KIND, enforced here too.
	//
	// A restart spawns a fresh OS process, so it is a start and carries the same
	// authorization as one. Ownership — the only check above — cannot catch this:
	// a user legitimately OWNS their own agent's run row (per-kind scope is
	// structural, not authz, and nothing may hide a user's own runs from them), so
	// the one check that passed is the one that could never have refused. Without
	// this gate a user-authenticated restart of an AGENT-ONLY `run` respawned it,
	// with the UI's verb gate as the only thing standing in the way — and the start
	// path's own comment says why that is not enough: the rule "must be enforced at
	// the API, not only in the UI".
	//
	// The rule itself is NOT restated here. It is read from
	// domain.SHELL_SESSION_STARTER_RULES through shell_session_kind_may_start, the
	// same table and predicate shell_session_start uses, via the same
	// _shell_session_starter_from_auth helper. One source of truth: a second
	// hardcoded `kind == .Run` list here is precisely how the two entry points
	// would drift apart.
	//
	// Note the parse: start gets its enum from the caller's INPUT, but a restart
	// has only the STORED row, whose kind is a string. An unparseable kind FAILS
	// CLOSED. A row whose kind the hub cannot name is not a row it can authorize a
	// respawn of, and the alternative — treating unknown as permitted — would
	// reintroduce this hole for exactly the rows that are already malformed.
	//
	// Placed above next_run_seq and above every bridge send on purpose: a refusal
	// that still delivered shell_restart would be a worse bug than the one this
	// fixes, and gating here leaves REQ-SHELL-4's run_seq ordering untouched.
	kind_enum, kind_known := domain.shell_session_kind_from_string(session.kind)
	if !kind_known {
		return {}, false, domain.domain_error(.Forbidden, fmt.tprintf(
			"session %q has unknown kind %q and cannot be restarted", session_id, session.kind))
	}
	if !domain.shell_session_kind_may_start(kind_enum, _shell_session_starter_from_auth(auth)) {
		return {}, false, domain.domain_error(.Forbidden, fmt.tprintf(
			"a %q session may only be restarted by %s", session.kind, domain.shell_session_starters_string(kind_enum)))
	}

	if kind_enum == .Shell || kind_enum == .Server {
		if plan_err := shell_session_require_shells(svc.entitlements, auth); plan_err.code != .None {
			return {}, false, plan_err
		}
	}

	// REQ-SHELL-4: a restart begins a NEW RUN, and the new run's number is sent to the
	// bridge before it is persisted here — but ADOPTED BY NEITHER SIDE unless the
	// respawn actually succeeds. That ordering is what makes every failure mode safe:
	//
	//   restart FAILS (offline bridge, spawn error) -> the hub returns below without
	//     writing, and the bridge adopts the value only after a successful spawn. Both
	//     sides stay on the old run, so the old run's exits still apply. Advancing the
	//     row first would have stranded exactly this case: the still-live old process
	//     would report an exit the hub then discarded as stale, leaving the row running
	//     forever.
	//   restart SUCCEEDS, hub CRASHES before the upsert -> the bridge is on next, the
	//     row is still on next-1. Handled by the comparison in shell_session_handle_exited
	//     being STRICTLY LESS THAN rather than not-equal: a bridge that is AHEAD is a hub
	//     that lost a write, and its exits are about a run at least as current as the
	//     one the row knows about, so they apply.
	//
	// The close-then-spawn inside the bridge's restart handler makes the old run emit
	// its own exit, which arrives stamped with the OLD number and is correctly
	// discarded — a user who restarted a session does not want the previous run's exit
	// landing on it.
	next_run_seq := session.run_seq + 1

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_restart_")
	cmd_json := _shell_restart_command_json(cmd_id, session_id, next_run_seq)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)

	if !reply_ok do return session, false, reply_err
	defer delete(reply)

	if !_json_bool(reply, "ok") do return session, false, _bridge_failure(reply, "bridge failed to restart shell session", session.bridge_id)

	session.status           = domain.Shell_Session_Status_Running
	session.pid              = _json_int(reply, "pid", session.pid)
	session.run_seq          = next_run_seq
	session.finished_at      = ""
	session.last_activity_at = platform.clock_now(svc.clock)
	if _, up_err := iface.shell_session_upsert(svc.repo, session); up_err.code == .None do _shell_session_publish_changed(svc, session, "restarted")
	return session, true, domain.Domain_Error{}
}

// Shell_Session_Max_Port is the highest TCP port a session may declare.
Shell_Session_Max_Port :: 65535

// Shell_Session_Set_Port_Timeout_Ms bounds the bridge round trip shell_session_set_port
// blocks an HTTP handler on. See the call site for why it is shorter than the 30s the
// spawn paths use.
Shell_Session_Set_Port_Timeout_Ms :: 10_000

// shell_session_set_port declares (or, with port 0, clears) the server port of a
// session that is ALREADY RUNNING — the XM-9 case where you open a terminal and
// only then decide to run a server in it.
//
// It updates the bridge BEFORE the hub row, and persists only on a successful
// bridge reply. That ordering is the point of the whole change: the bridge
// re-validates server_port against its own copy of the session when a tunnel is
// opened (bridge_hub_handle_tunnel_open), so a hub row updated on its own would
// advertise a port the bridge then refused. Going bridge-first also means a
// success returned here is "reachable now", not "reachable once something
// catches up" — which is what makes changing an already-set port take effect
// immediately rather than racing a stale copy.
//
// The port is still never read from a dial-time request; this changes only how
// the session RECORD gets its value.
shell_session_set_port :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	if server_port < 0 || server_port > Shell_Session_Max_Port {
		return {}, false, domain.domain_error(.Validation_Failed, "server_port must be between 1 and 65535, or 0 to clear it")
	}

	// Owner-scoped lookup: a session belonging to someone else is Not_Found
	// rather than Forbidden, so this does not disclose that it exists.
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")
	if domain.shell_session_is_terminal(session) {
		return session, false, domain.domain_error(.Conflict, "session has already terminated")
	}

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_set_port_")
	cmd_json := _shell_set_port_command_json(cmd_id, session_id, server_port)
	defer delete(cmd_json)

	// 10s, not the 30s the spawn/restart paths use. A bridge is offline as an
	// ordinary matter, and this call blocks an HTTP handler, so the wait has to be
	// bounded tightly: setting a field on a live in-memory record is a round trip,
	// not a process spawn, so anything near 10s already means the bridge is gone.
	// The wait is bounded by the sink itself and an unreachable bridge fails
	// IMMEDIATELY (Bridge_Offline, before the wait starts) rather than burning the
	// full timeout — see send_runtime_command_wait.
	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		Shell_Session_Set_Port_Timeout_Ms,
	)

	if !reply_ok {
		// Offline and timed-out both arrive as Bridge_Offline; keep that code — it is
		// the vocabulary the rest of the shell surface already uses — but say plainly
		// that NOTHING changed, which is the fact the caller needs in order to act.
		// Nothing has been written at this point: the hub row still holds whatever it
		// held, so a retry is safe and the session's reachability is unaltered.
		return session, false, domain.domain_error(reply_err.code, _set_port_unreachable_message(reply_err))
	}
	defer delete(reply)

	if !_json_bool(reply, "ok") {
		// The bridge answers with the shared refusal vocabulary
		// (session_not_found / session_not_running); surface it rather than a
		// generic failure, so the reason is the same word end to end.
		// Boy-scout (REQ-SHELL-16): the delete here was UNCONDITIONAL, which is a bad
		// free whenever the bridge replies without an `error` field — _json_str returns a
		// non-allocated "" literal in that case. Guarded, and the generic fallback now
		// carries the reason like the other four sites instead of dropping a refusal
		// word this branch simply did not recognise.
		return session, false, _bridge_failure(reply, "bridge failed to set the shell session port", session.bridge_id)
	}

	// Not an upsert: it keeps the existing port when the new one is 0, so
	// clearing would silently do nothing. See Shell_Session_Set_Server_Port_Proc.
	written, write_err := iface.shell_session_set_server_port(svc.repo, string(owner), session_id, server_port)
	if write_err.code != .None do return session, false, write_err
	if !written do return session, false, domain.domain_error(.Not_Found, "session not found")

	session.server_port = server_port
	_shell_session_publish_changed(svc, session, "port_changed")
	return session, true, domain.Domain_Error{}
}

// shell_session_get returns a session owned by the authenticated user.
shell_session_get :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	session, found, repo_err := iface.shell_session_get(svc.repo, string(owner), session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")
	return session, true, domain.Domain_Error{}
}

// shell_session_list_by_bridge lists sessions on a specific bridge owned by the caller.
shell_session_list_by_bridge :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_bridge(svc.repo, string(owner), bridge_id, status_filter, cursor, limit)
}

// shell_session_list_by_project lists sessions for a specific project owned by the caller.
shell_session_list_by_project :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_project(svc.repo, string(owner), project_id, status_filter, cursor, limit)
}

// shell_session_list_by_chain lists sessions for a specific task chain owned by the caller.
shell_session_list_by_chain :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_chain(svc.repo, string(owner), chain_id, status_filter, cursor, limit)
}

// shell_session_list lists sessions the caller owns across ALL bridges, with
// optional AND-ed narrowing. Passing an all-empty filter is the owner-wide
// default: every shell the caller has, anywhere. Ownership still comes from the
// auth context, so this widens the scope, never the tenancy.
shell_session_list :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, filter: iface.Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, "", domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, "", err
	return iface.shell_session_list_by_owner(svc.repo, string(owner), filter, cursor, limit)
}

Shell_Session_Log_Result :: struct {
	lines_raw:   string, // raw JSON array (caller must delete)
	truncated:   bool,
	total_lines: int,
}

// shell_session_get_log fetches log lines from the bridge for the session.
shell_session_get_log :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string, offset, limit_val: int, grep: string) -> (Shell_Session_Log_Result, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return {}, false, err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	lim := limit_val
	if lim <= 0 do lim = 100

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_logs_")
	cmd_json := _shell_logs_command_json(cmd_id, session_id, offset, lim, grep)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)

	if !reply_ok do return {}, false, reply_err
	defer delete(reply)

	// Three outcomes, three DISTINCT domain errors, which is the point of REQ-SHELL-8
	// AC3 (before it, all three arrived as an empty log):
	//   reply never came      -> reply_err above, .Bridge_Offline. The bridge is gone.
	//   output was reclaimed  -> .Gone. The bridge is fine; retention took the file.
	//   ok, zero lines        -> success. The command genuinely printed nothing.
	if !_json_bool(reply, "ok") {
		return {}, false, _bridge_failure(reply, "bridge failed to retrieve shell logs", session.bridge_id)
	}

	lines_raw   := _json_array_raw(reply, "lines")
	truncated   := _json_bool(reply, "truncated")
	total_lines := _json_int(reply, "total_lines", 0)
	return Shell_Session_Log_Result{lines_raw = lines_raw, truncated = truncated, total_lines = total_lines}, true, domain.Domain_Error{}
}

Shell_Session_Capture_Result :: struct {
	content: string, // caller must delete
	rows:    int,
	cols:    int,
}

// shell_session_capture requests a PTY screen snapshot from the bridge.
shell_session_capture :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (Shell_Session_Capture_Result, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return {}, false, err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_capture_")
	cmd_json := _shell_capture_command_json(cmd_id, session_id)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		30_000,
	)

	if !reply_ok do return {}, false, reply_err
	defer delete(reply)

	if !_json_bool(reply, "ok") do return {}, false, _bridge_failure(reply, "bridge failed to capture shell session", session.bridge_id)

	content := _json_str(reply, "content")
	rows    := _json_int(reply, "rows", 24)
	cols    := _json_int(reply, "cols", 80)
	return Shell_Session_Capture_Result{content = content, rows = rows, cols = cols}, true, domain.Domain_Error{}
}

// shell_session_pane_terminal_status reports whether a session has reached a terminal
// state, in which case there is nothing live to capture and the pane must not cost a
// bridge round trip. Mirrors the agent pane's stopped/failed short-circuit
// (agent_service.get_instance_pane).
shell_session_pane_terminal_status :: proc(status: string) -> bool {
	return status == "exited" || status == "killed" || status == "failed"
}

// shell_session_get_pane returns a polled screen snapshot for an interactive shell
// session (REQ-PTY-STREAM-1), diffed against since_hash by the bridge so an idle screen
// costs an empty reply. This is the shell twin of agent_service.get_instance_pane and
// returns the identical payload shape {ok,unchanged,hash,output,line_count,truncated}.
//
// Owner scoping runs through shell_session_get (owner_from_auth + owner-keyed repo
// lookup), the same auth-scoped getter every other shell endpoint uses.
//
// The 5s bridge timeout is deliberate and differs from shell_session_capture's 30s: this
// command is polled twice a second while a pane is open, so a long timeout would let
// pending commands pile up under bridge slowness.
shell_session_get_pane :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id, since_hash: string, width, line_limit: int) -> (string, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return "", false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	session, found, err := shell_session_get(svc, auth, session_id)
	if err.code != .None do return "", false, err
	if !found do return "", false, domain.domain_error(.Not_Found, "session not found")

	// Terminal session: answer locally, never touch the bridge.
	if shell_session_pane_terminal_status(session.status) {
		b := strings.builder_make()
		strings.write_string(&b, "{\"ok\":true,\"status\":\"")
		contracts.write_json_string(&b, session.status)
		strings.write_string(&b, "\",\"unchanged\":true,\"hash\":\"\",\"output\":\"\"}")
		return strings.to_string(b), true, domain.Domain_Error{}
	}

	if strings.trim_space(session.bridge_id) == "" {
		return "", false, domain.domain_error(.Bridge_Offline, "shell session has no bridge")
	}

	w := width
	if w <= 0 do w = 80
	limit := line_limit
	if limit <= 0 do limit = 120

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_pane_")
	cmd_json := _shell_get_pane_command_json(cmd_id, session_id, since_hash, w, limit)
	defer delete(cmd_json)

	reply, reply_ok, reply_err := project_service.bridge_command_send_runtime_wait(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = cmd_json},
		5_000,
	)

	if !reply_ok do return "", false, reply_err
	return reply, true, domain.Domain_Error{}
}

// SHELL_SESSION_RUN_SEQ_UNSTATED marks a shell_exited report that carries no
// run_seq. It is NOT 0: 0 is a real run (the first one), so conflating the two would
// make every unstamped report look like it belonged to run 0 and be discarded for
// any session that had ever been restarted — stranding it as running forever.
SHELL_SESSION_RUN_SEQ_UNSTATED :: -1

// shell_session_handle_exited is called by bridge_handlers when a shell_exited event
// arrives from the bridge. It updates the hub DB row and publishes a push event.
//
// bridge_id is the authenticated id of the bridge the event arrived on. It is
// required: the row is only touched when it belongs to that same bridge, so a
// bridge cannot terminate the record of a session running on another bridge
// (and so, in practice, of another user). See the check below the lookup.
// run_seq (REQ-SHELL-4) names WHICH RUN of the session this exit is about — see
// domain.Shell_Session.run_seq. SHELL_SESSION_RUN_SEQ_UNSTATED means the report did
// not carry one, which is applied rather than discarded (see the comparison below).
//
// Returns whether the exit was APPLIED. Callers use it to avoid fanning out a report
// the hub itself decided to ignore: a discarded or duplicate exit must not reach
// viewers either, or the UI shows a status the row does not have.
shell_session_handle_exited :: proc(
	svc: ^Shell_Session_Service,
	session_id, bridge_id, status: string,
	exit_code: int,
	exit_code_set: bool,
	run_seq: int = SHELL_SESSION_RUN_SEQ_UNSTATED,
) -> bool {
	if svc == nil || svc.repo == nil || session_id == "" || bridge_id == "" do return false

	// Remove the entry from session_owners and session_bridges under the lock, capturing the heap strings.
	// ALLOCATOR: session_owners/session_bridges keys and values are allocated from the
	// HEAP allocator in shell_session_create (`strings.clone(..., heap)`), and
	// shell_session_service_free releases them the same way. These frees must match.
	//
	// They did not: they used the implicit context.allocator. In production that
	// happens to be the heap allocator, so the mismatch was invisible — but under the
	// test tracking allocator every one of them reports a bad free, which is what a
	// mismatched free IS, and any context running with a non-default allocator would
	// have made it a genuine one. Surfaced by the first test to exercise create followed
	// by handle_exited (REQ-SHELL-5); fixed here rather than left as a trap.
	exited_heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	map_key: string
	map_val: string
	found_entry := false
	for k in svc.session_owners {
		if k == session_id {
			map_key = k
			map_val = svc.session_owners[k]
			delete_key(&svc.session_owners, k)
			found_entry = true
			break
		}
	}
	// ORDER MATTERS, and it was wrong here. The original freed the KEY and then used
	// that same freed string to look the VALUE up (`delete(k)` followed by
	// `svc.session_bridges[k]`) — a use-after-free that the context allocator's
	// free-list happened to survive, and that faults outright once the free actually
	// releases the memory. Capture both, unlink, then free.
	for k in svc.session_bridges {
		if k == session_id {
			bridge_key := k
			bridge_val := svc.session_bridges[k]
			delete_key(&svc.session_bridges, k)
			delete(bridge_key, exited_heap)
			delete(bridge_val, exited_heap)
			break
		}
	}
	sync.mutex_unlock(&svc.mu)

	// Fast path frees remain exactly as before; they only apply when the map hit.
	defer if found_entry do delete(map_key, exited_heap)
	defer if found_entry do delete(map_val, exited_heap) // map_val is the owner_user_id

	owner:    string
	session:  domain.Shell_Session
	found:    bool
	repo_err: domain.Domain_Error

	if found_entry {
		owner = map_val
		session, found, repo_err = iface.shell_session_get(svc.repo, owner, session_id)
	} else {
		// session_owners is in-memory only and is never rehydrated from the DB,
		// so it is empty for every session created before the current hub
		// process. Dropping the event here left those rows stuck at "running"
		// forever — an unkillable ghost in the UI (REQ-RECON-5). Fall back to an
		// unscoped lookup to recover the owner from the row itself.
		//
		// Safe here and only here: the caller is a trusted bridge event with no
		// authenticated user to scope by. User-facing handlers keep using the
		// owner-scoped shell_session_get.
		//
		// It is unscoped by OWNER, not by bridge (REQ-SHELL-1 §7). bridge_id is the
		// bridge that reported the event, and it is part of the primary key, so this
		// resolves only within the reporting bridge — strictly narrower than the
		// session-id-alone lookup it replaced, which a colliding id from another
		// bridge could have satisfied.
		session, found, repo_err = iface.shell_session_get_by_id(svc.repo, bridge_id, session_id)
		if found do owner = session.owner_user_id
	}
	if !found || repo_err.code != .None || owner == "" do return false

	// Bridge scoping. Losing the owner check on the by-id path would otherwise let
	// ANY connected bridge terminate ANY user's session record by emitting
	// shell_exited with that session_id — session_owners used to make that
	// unreachable by accident, and the fallback above removes that accident. The
	// row names the bridge it runs on, so require the event to come from it.
	// Applied to both paths: a bridge has no business reporting an exit for a
	// session that is not its own either way.
	if session.bridge_id != bridge_id do return false

	// REQ-SHELL-4 §2 — WHICH RUN is this exit about?
	//
	// A session_id is not a run. shell_session_restart re-spawns under the same
	// session_id, so once the exit queue became durable an exit could outlive the run
	// it describes: run N exits while the bridge is offline, the session is restarted
	// and is genuinely alive, the bridge reconnects and delivers run N's exit. Applying
	// it would mark a LIVE session terminal — the divergence this chain exists to
	// remove, manufactured by the durability mechanism itself.
	//
	// STRICTLY LESS THAN, not "not equal", and the asymmetry is deliberate:
	//   older  (report < row) -> STALE. It is about a run that no longer exists.
	//                            Discarded, not failed: it is a truthful answer to a
	//                            question nobody is asking any more, and there is
	//                            nothing for the bridge to retry.
	//   newer  (report > row) -> the BRIDGE IS AHEAD, which means the hub lost a
	//                            restart's write (it crashed between the bridge's
	//                            successful respawn and its own upsert —
	//                            shell_session_restart explains the window). The
	//                            report is about a run at least as current as the one
	//                            the row knows about, so discarding it would strand
	//                            the session as running forever. Applied.
	// UNSTATED -> applied. A report that does not name a run cannot be shown to be
	// stale, and the safe direction for an unprovable claim is to converge rather than
	// to leave a row live forever.
	if run_seq != SHELL_SESSION_RUN_SEQ_UNSTATED && run_seq < session.run_seq do return false

	// REQ-SHELL-4 §2/§3: IDEMPOTENT APPLY, and ordering safety, in one guard.
	//
	// The bridge's outbox is at-least-once by construction — it removes an exit's
	// envelope only after the frame is sent, so a crash in that window replays it —
	// and it makes no ordering promise across a restart. Both hazards land here as
	// the same shape: a shell_exited for a row that is ALREADY terminal.
	//
	//   - the duplicate delivery of an exit that was already applied, which without
	//     this guard wrote the row a second time and published a second event to the
	//     owner, fanning one exit out twice;
	//   - a stale exit overtaken by a more accurate terminal status. A session the
	//     user killed is `killed`; a late `exited` replayed from a restarted bridge's
	//     outbox would overwrite that with the weaker truth, and slide finished_at
	//     forward to the moment of the replay.
	//
	// So among BRIDGE-REPORTED exits the rule is first-writer-wins, and returning
	// before the upsert AND before the publish is what makes the second application a
	// true no-op rather than a quieter version of the first.
	//
	// ONE EXCEPTION, and it is not a weakening of the above: a SYNTHESIZED terminal
	// status may be superseded by a bridge-reported exit. REQ-SHELL-14 lands a
	// terminal status on the sessions of a bridge judged never to be coming back —
	// necessarily a guess, made without seeing any process end. If that bridge does
	// come back and reports the genuine exit (which is exactly what a durable outbox
	// makes likely — that is this task), a flat first-terminal-wins would discard the
	// real exit and leave the guess standing forever, with a fabricated exit_code the
	// user has no way to correct. A guess must not outrank an observation.
	// See domain.shell_session_terminal_is_observed for how the two are told apart
	// and what REQ-SHELL-14 owes that predicate.
	//
	// EXACTLY ONCE, structurally rather than by a counter: superseding requires the
	// INCOMING event to be observed (exit_code_set), and applying it makes the row
	// observed too — so the very next delivery takes the first-writer-wins branch
	// above. AC3 is unchanged: bridge-reported still never overwrites
	// bridge-reported.
	//
	// This does not weaken convergence. A row still RUNNING is still updated by the
	// first exit that reaches it, whenever it reaches it, which is the whole point of
	// making the outbox durable.
	if domain.shell_session_is_terminal(session) {
		if domain.shell_session_terminal_is_observed(session) do return false
		if !exit_code_set do return false
	}

	now := platform.clock_now(svc.clock)
	effective_status := status
	if effective_status == "" do effective_status = domain.Shell_Session_Status_Exited

	session.status           = effective_status
	session.finished_at      = now
	session.last_activity_at = now
	if exit_code_set {
		session.exit_code     = exit_code
		session.exit_code_set = true
	}

	_, exit_up_err := iface.shell_session_upsert(svc.repo, session)

	// REQ-2: announce only a terminal state the row actually holds.
	if svc.events != nil && exit_up_err.code == .None {
		evt := _shell_exited_event_json(session_id, effective_status, exit_code, exit_code_set)
		events.publish_owned(svc.events, owner, evt)
	}

	// REQ-SHELL-5 §1 — NOTIFY THE OWNING AGENT, background runs only.
	_shell_session_notify_run_finished(svc, session, effective_status)
	return true
}

// _shell_session_notify_run_finished delivers a run's completion notice to the agent
// that started it (REQ-SHELL-5 §1).
//
// WHY IT LIVES AT THE TAIL OF handle_exited. That is the single point at which a
// bridge-reported terminal status is actually APPLIED to a row, which makes it the one
// place both notifiable outcomes pass through: a run that finishes on its own and a run
// that is killed both reach the hub as a shell_exited carrying `exited` / `killed` /
// `failed`. One call site, both outcomes, no second path to keep in step.
//
// It sits BELOW the idempotency guard on purpose, not merely by position. That guard
// returns early for an exit that has already been applied — the duplicate delivery an
// at-least-once outbox is expected to produce — so a replayed exit cannot notify a
// second time. "Notify exactly once" is inherited from "apply exactly once" rather than
// being a separate promise with its own bugs.
//
// BACKGROUND ONLY, and this is the condition most likely to be lost in a later edit.
// A FOREGROUND run returns its result inline to the caller that is still blocked on it
// (REQ-SHELL-2 owns that return path) and must send NOTHING — a notification would be
// the same answer delivered twice, once to a caller that already has it. The whole of
// the distinction is the `background` flag: REQ-SHELL-2 deleted the implicit 15s
// auto-background rule, so the flag is set only by an explicit --bg at start or by the
// user converting a live run, never inferred. A converted run carries background=true by
// the time it exits, so it notifies — which is AC3.
//
// This delivers a TRANSIENT NUDGE and inserts NOTHING into any conversation, matching
// what the original design intended ("delivers a transient nudge; no chat/conversation
// message is ever inserted", agent_action_handlers.odin). The run's one conversation
// entry was written at create; there is no second message here and no output anywhere on
// this path — the notice names the session and its status, and the agent reads the log
// from the bridge on demand.
_shell_session_notify_run_finished :: proc(svc: ^Shell_Session_Service, session: domain.Shell_Session, status: string) {
	if svc == nil do return
	if svc.bridge_command_sink.send_runtime_command == nil && svc.bridge_command_sink.send_runtime_command_wait == nil do return

	kind, known := domain.shell_session_kind_from_string(session.kind)
	if !known || kind != .Run do return
	if !session.background do return
	// The notice is addressed to an agent on a bridge. Without either id there is
	// nobody to deliver to; a run always has both, so this is a guard, not a case.
	if session.agent_instance_id == "" || session.bridge_id == "" do return

	cmd_id := platform.generate_id(svc.ids, "cmd_sh_run_")
	body := _shell_run_notify_command_json(cmd_id, session.session_id, session.agent_instance_id, status, session.exit_code, session.exit_code_set)
	defer delete(body)

	cmd := project_service.Runtime_Command{bridge_id = session.bridge_id, command_id = cmd_id, body_json = body}
	// Fire-and-forget. A nudge the bridge misses is not worth failing or retrying an
	// already-applied exit over: the row is terminal and authoritative, and the agent
	// can always read the session. Deliberately NOT durable — this is a wake-up, not
	// the record. The record is the row.
	if svc.bridge_command_sink.send_runtime_command != nil {
		_, _ = project_service.bridge_command_send_runtime(svc.bridge_command_sink, cmd)
		return
	}
	_, _, _ = project_service.bridge_command_send_runtime_wait(svc.bridge_command_sink, cmd, 1000)
}

// _shell_run_notify_command_json builds the notify_shell_run runtime command.
//
// It carries the SESSION ID above all else (REQ-SHELL-5 §1: "the notification must
// carry the shell session id, since that is what the agent was handed when the run was
// backgrounded"), plus the status and exit code so the notice can be read without a
// follow-up call. It carries NO OUTPUT — output never leaves the bridge, and this
// command is travelling toward the bridge anyway. Caller owns the returned string.
_shell_run_notify_command_json :: proc(cmd_id, session_id, agent_instance_id, status: string, exit_code: int, exit_code_set: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"notify_shell_run","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","session_id":"`)
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, `","status":"`)
	contracts.write_json_string(&b, status)
	strings.write_string(&b, `"`)
	if exit_code_set {
		strings.write_string(&b, `,"exit_code":`)
		strings.write_string(&b, fmt.tprintf("%d", exit_code))
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// --- Tunnel stream registry (T8) ---

// shell_session_tunnel_register creates and registers a new in-flight tunnel stream.
// The returned pointer is valid until shell_session_tunnel_unregister is called.
shell_session_tunnel_register :: proc(svc: ^Shell_Session_Service, stream_id: string) -> ^Preview_Tunnel_Stream {
	heap := runtime.heap_allocator()
	stream := new(Preview_Tunnel_Stream, heap)
	stream.chunks = make([dynamic][]byte, heap)
	stream.closed = false
	sync.mutex_lock(&svc.tunnel_mu)
	svc.tunnel_streams[strings.clone(stream_id, heap)] = stream
	sync.mutex_unlock(&svc.tunnel_mu)
	return stream
}

// shell_session_tunnel_deliver appends a data chunk to a live tunnel stream.
// No-op if the stream is already closed or not found.
// tunnel_mu is held through the stream.mu section so that tunnel_unregister cannot
// free the stream between the map lookup and the stream.mu lock (UAF guard).
shell_session_tunnel_deliver :: proc(svc: ^Shell_Session_Service, stream_id: string, data: []byte) {
	if svc == nil || len(data) == 0 do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.tunnel_mu)
	stream, ok := svc.tunnel_streams[stream_id]
	if ok {
		chunk := make([]byte, len(data), heap)
		copy(chunk, data)
		sync.mutex_lock(&stream.mu)
		if !stream.closed {
			append(&stream.chunks, chunk)
			sync.cond_signal(&stream.cond)
		} else {
			delete(chunk, heap)
		}
		sync.mutex_unlock(&stream.mu)
	}
	sync.mutex_unlock(&svc.tunnel_mu)
}

// shell_session_tunnel_close_stream marks a tunnel stream as closed (all data delivered).
// tunnel_mu is held through stream.mu for the same UAF-safety reason as deliver.
shell_session_tunnel_close_stream :: proc(svc: ^Shell_Session_Service, stream_id: string) {
	if svc == nil do return
	sync.mutex_lock(&svc.tunnel_mu)
	stream, ok := svc.tunnel_streams[stream_id]
	if ok {
		sync.mutex_lock(&stream.mu)
		stream.closed = true
		sync.cond_signal(&stream.cond)
		sync.mutex_unlock(&stream.mu)
	}
	sync.mutex_unlock(&svc.tunnel_mu)
}

// shell_session_tunnel_unregister removes a tunnel stream and frees its resources.
// Must be called after the proxy handler has finished reading all chunks.
shell_session_tunnel_unregister :: proc(svc: ^Shell_Session_Service, stream_id: string) {
	if svc == nil do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.tunnel_mu)
	stream: ^Preview_Tunnel_Stream
	found := false
	for k in svc.tunnel_streams {
		if k == stream_id {
			stream = svc.tunnel_streams[k]
			delete_key(&svc.tunnel_streams, k)
			delete(k, heap)
			found = true
			break
		}
	}
	sync.mutex_unlock(&svc.tunnel_mu)
	if !found do return
	for chunk in stream.chunks do delete(chunk, heap)
	delete(stream.chunks)
	free(stream, heap)
}

// --- private helpers ---

_copy_viewers :: proc(svc: ^Shell_Session_Service, session_id: string) -> []net.TCP_Socket {
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	viewers, ok := svc.viewers[session_id]
	if !ok || len(viewers) == 0 do return nil
	out := make([]net.TCP_Socket, len(viewers))
	copy(out, viewers[:])
	return out
}

_status_frame_json :: proc(status: string, exit_code: int, exit_code_set: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"status\",\"status\":\"")
	contracts.write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if exit_code_set {
		strings.write_string(&b, fmt.tprintf(",\"exit_code\":%d", exit_code))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// stream_ready_frame_json is the viewer's stream_ready control frame. A non-empty
// bridge_boot_id rides along (see shell_session_broadcast_stream_ready).
stream_ready_frame_json :: proc(session_id: string, bridge_boot_id := "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"stream_ready\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	if bridge_boot_id != "" {
		strings.write_string(&b, "\",\"bridge_boot_id\":\"")
		contracts.write_json_string(&b, bridge_boot_id)
	}
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_stream_closed_frame_json :: proc(session_id: string, exit_code: int, exit_code_set: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"stream_closed\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"")
	if exit_code_set {
		strings.write_string(&b, fmt.tprintf(",\"exit_code\":%d", exit_code))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// _write_ws_text writes one frame to a VIEWER socket. Every peer on this registry is a
// browser, so the 64-bit length arm is correct here — see write_server_text for why the
// bridge channel gets the opposite answer.
//
// It returns the typed result rather than a bool on purpose (REQ-SHELL-33): its callers
// decide whether to DETACH the viewer, and a bool made "I could not encode this frame"
// indistinguishable from "this socket is dead". See _viewer_write_ends_session.
_write_ws_frame :: proc(socket: net.TCP_Socket, opcode: u8, text: string) -> ws.Text_Write_Result {
	return ws.write_server_opcode(socket, opcode, text, true)
}

// _viewer_write_ends_session answers the only question the broadcast loop actually asks:
// is this VIEWER finished? A frame the hub could not encode says nothing about the socket
// — not one byte of it was written — so the viewer stays attached and the session goes on.
//
// This is the (b) half of REQ-SHELL-33, and it is why the result is a type and not a bool.
// The old code detached on every falsey return, so one oversized frame SILENTLY
// UNSUBSCRIBED a live, healthy viewer, which then saw nothing further and had no way to
// find out. A dropped frame costs one repaint; a detach costs the session.
//
// Desynchronised DOES end it: half a frame is already on the wire and that client will
// misparse every byte after it. Ending a corrupt stream is the recovery, not the failure.
_viewer_write_ends_session :: proc(result: ws.Text_Write_Result) -> bool {
	switch result {
	case .Ok, .Too_Large:
		return false
	case .Peer_Gone, .Desynchronised:
		return true
	}
	return true
}

// _detach_reason_for_write maps a session-ending write result onto the detach reason, so
// the detach line names the WRITE outcome that forced it rather than just "unspecified".
_detach_reason_for_write :: proc(result: ws.Text_Write_Result) -> Shell_Viewer_Detach_Reason {
	switch result {
	case .Peer_Gone:      return .Peer_Gone
	case .Desynchronised: return .Desynchronised
	case .Ok, .Too_Large: return .Unspecified // neither ends the session
	}
	return .Unspecified
}

// _log_viewer_write reports EVERY non-Ok write outcome. Ok is silent, and must stay that
// way: this path carries PTY output at ~11KB every 25ms, so logging success would be its
// own defect (REQ-SHELL-41 AC3).
//
// IT USED TO REPORT ONLY Too_Large, and the asymmetry was the bug. Too_Large keeps the
// viewer attached, so it was reasoned to be the case that "otherwise leaves no trace" —
// but Peer_Gone and Desynchronised DETACH A LIVE VIEWER, and the detach itself logged
// nothing either, so the two loudest outcomes were the two silent ones. Both are now
// reported here, and the detach that follows is reported by shell_session_detach.
_log_viewer_write :: proc(kind, session_id: string, result: ws.Text_Write_Result, size: int) {
	switch result {
	case .Ok:
		// Deliberately silent — see above.
	case .Too_Large:
		fmt.eprintfln(
			"ham-hub WARN shell ws %s frame too large to encode session=%s bytes=%d limit=%d (viewer KEPT attached)",
			kind,
			session_id,
			size,
			ws.WS_MAX_SERVER_PAYLOAD,
		)
	case .Peer_Gone:
		fmt.eprintfln(
			"ham-hub WARN shell ws %s write found the peer gone session=%s bytes=%d (viewer WILL BE DETACHED)",
			kind, session_id, size)
	case .Desynchronised:
		fmt.eprintfln(
			"ham-hub WARN shell ws %s write left a PARTIAL frame on the wire session=%s bytes=%d (stream unparseable; viewer WILL BE DETACHED)",
			kind, session_id, size)
	}
}

// _shell_session_check_cap enforces the per-kind live-session cap. Returns the
// refusal and true when the create is over cap.
//
// Built FROM the domain: the cap constants and the scope column both come from
// there, so the kind/scope pairing is not restated here — adding a cap for a new
// kind means adding it beside its scope rule, not editing this switch into a
// second table of which kind is scoped by what.
//
// A kind with no cap (a `shell`) simply falls through: an interactive terminal is
// opened by a person, one at a time, and there is no runaway shape to bound.
_shell_session_check_cap :: proc(svc: ^Shell_Session_Service, owner: string, kind: domain.Shell_Session_Kind, session: domain.Shell_Session) -> (domain.Domain_Error, bool) {
	cap_value := 0
	scope_col: domain.Shell_Session_Scope_Column
	scope_label := ""
	switch kind {
	case .Run:
		cap_value   = domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT
		scope_col   = .Agent_Instance
		scope_label = "agent instance"
	case .Server:
		cap_value   = domain.SHELL_SESSION_MAX_LIVE_SERVERS_PER_CHAIN
		scope_col   = .Chain
		scope_label = "task chain"
	case .Shell:
		return domain.Domain_Error{}, false
	}
	if cap_value <= 0 do return domain.Domain_Error{}, false

	scope_value := domain.shell_session_scope_column_value(session, scope_col)
	if scope_value == "" do return domain.Domain_Error{}, false

	live, count_err := iface.shell_session_count_live(svc.repo, owner, session.kind, domain.shell_session_scope_column_name(scope_col), scope_value)
	if count_err.code != .None do return count_err, true
	if live >= cap_value {
		return domain.domain_error(.Conflict, fmt.tprintf(
			"this %s already has %d live %s sessions (cap %d); kill some before starting another",
			scope_label, live, session.kind, cap_value)), true
	}
	return domain.Domain_Error{}, false
}

// shell_session_set_background converts a LIVE FOREGROUND run to a background one
// (REQ-SHELL-2 §3) — the transition the user drives from the UI, and the one the
// agent-liveness hook drives when a run's owning agent goes unreachable.
//
// It does two things, in this order and for a reason: it writes the row FIRST so
// the state is durable even if the bridge is momentarily unreachable, then asks
// the bridge to release the blocked caller and start notifying. A bridge that
// never gets the command leaves a run whose row correctly says background, which
// reconcile and the notification path both read — whereas signalling first and
// failing to persist would release a caller with a promise of notification the
// hub had not recorded.
//
// ONE-WAY, enforced by domain.shell_session_run_may_background: a run already
// background, or already terminal, is refused rather than re-signalled, so a
// repeated conversion cannot release a second waiter or re-arm a notification.
shell_session_set_background :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return {}, false, err
	return _shell_session_set_background_for_owner(svc, string(owner), session_id)
}

// _shell_session_set_background_for_owner is the owner-string form, for the
// INTERNAL liveness path where the trigger is a bridge/reaper event and there is
// no authenticated caller to derive an owner from. The owner still scopes every
// read and write — this bypasses authentication, never ownership, exactly as
// shell_session_get_by_id does on the bridge-event path.
_shell_session_set_background_for_owner :: proc(svc: ^Shell_Session_Service, owner: string, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "shell session service is not configured")
	if owner == "" do return {}, false, domain.domain_error(.Forbidden, "owner is required")
	session, found, repo_err := iface.shell_session_get(svc.repo, owner, session_id)
	if repo_err.code != .None do return {}, false, repo_err
	if !found do return {}, false, domain.domain_error(.Not_Found, "session not found")

	if may, reason := domain.shell_session_run_may_background(session); !may {
		return session, false, domain.domain_error(.Conflict, reason)
	}

	session.background       = true
	session.last_activity_at = platform.clock_now(svc.clock)
	if _, up_err := iface.shell_session_upsert(svc.repo, session); up_err.code != .None do return session, false, up_err
	_shell_session_publish_changed(svc, session, "backgrounded")

	cmd_json := _shell_background_command_json(session_id)
	defer delete(cmd_json)
	// Fire-and-forget: a delivery failure does not undo the row. The run is already
	// background as far as the hub is concerned, and the bridge re-reads that from
	// the spec it saved at spawn once it reconnects.
	_, _ = project_service.bridge_command_send_runtime(
		svc.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = cmd_json},
	)
	return session, true, domain.Domain_Error{}
}

// shell_session_background_runs_for_agent is the AGENT-LIVENESS hook
// (REQ-SHELL-2 §9): every live FOREGROUND run owned by an agent instance that has
// gone unreachable is converted to background. Returns how many were converted.
//
// WHY CONVERT RATHER THAN KILL — the description offered either, and this is the
// choice with its reasoning, because the difference is destructive.
//
// The hub's unreachability signals are not proof the agent's work is worthless.
// mark_bridge_instances_unreachable fires on BRIDGE disconnect and marks EVERY
// instance on that bridge unreachable at once; the agent processes are usually
// alive and well, and only the hub link dropped. Killing on that signal would
// destroy a twenty-minute build because a WebSocket blipped — and the hub could
// not deliver the kill to a bridge it had just lost anyway.
//
// Converting satisfies the actual requirement, which is that a foreground run must
// not survive as an untracked foreground run: a converted run stays tracked, stays
// addressable by its id, stays killable, stays reapable by reconcile, stays under
// the 30-minute process cap, and now notifies on completion instead of returning
// to a caller that is gone. Nothing is orphaned and nothing is destroyed.
//
// It is also ONE rule for every liveness signal (bridge-wide disconnect, the
// per-instance heartbeat reconcile, and the reaper's staleness sweep), so there is
// no "which signal fired?" branch whose wrong answer throws away work.
shell_session_background_runs_for_agent :: proc(svc: ^Shell_Session_Service, owner_user_id, agent_instance_id: string) -> int {
	if svc == nil || svc.repo == nil || owner_user_id == "" || agent_instance_id == "" do return 0

	filter := iface.Shell_Session_List_Filter{
		agent_instance_id = agent_instance_id,
		status            = domain.Shell_Session_Status_Group_Live,
	}
	// Bounded by the per-agent run cap: an agent cannot have more live runs than
	// that, so one page is the whole set and there is no cursor to follow.
	sessions, next_cursor, list_err := iface.shell_session_list_by_owner(svc.repo, owner_user_id, filter, "", domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT)
	if list_err.code != .None do return 0
	defer domain.shell_sessions_destroy(sessions)
	defer delete(next_cursor)

	converted := 0
	for session in sessions {
		// Only a FOREGROUND run has a caller to strand; a background run is already
		// in the state this hook would move it to, and the one-way rule in
		// _shell_session_set_background_for_owner refuses it anyway. Skipping here
		// keeps the returned count meaningful rather than counting no-ops.
		if session.background do continue
		if _, done, _ := _shell_session_set_background_for_owner(svc, owner_user_id, session.session_id); done do converted += 1
	}
	return converted
}

// --- bridge command JSON builders ---

// started_at is the HUB-assigned timestamp (REQ-SHELL-1 §8), sent so the bridge
// records the hub's value on its spec instead of stamping its own. One clock owns
// every age decision on both sides.
_shell_start_command_json :: proc(cmd_id, session_id, kind, cmd, cwd, label, project_id, chain_id, agent_instance_id, owner_user_id, started_at: string, server_port: int, background: bool, run_seq: int, enc_spec: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_start\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	contracts.write_json_string(&b, kind)
	strings.write_string(&b, "\",\"cmd\":\"")
	contracts.write_json_string(&b, cmd)
	strings.write_string(&b, "\",\"cwd\":\"")
	contracts.write_json_string(&b, cwd)
	strings.write_string(&b, "\",\"label\":\"")
	contracts.write_json_string(&b, label)
	strings.write_string(&b, "\",\"project_id\":\"")
	contracts.write_json_string(&b, project_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	contracts.write_json_string(&b, chain_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	contracts.write_json_string(&b, agent_instance_id)
	strings.write_string(&b, "\",\"owner_user_id\":\"")
	contracts.write_json_string(&b, owner_user_id)
	strings.write_string(&b, "\",\"started_at\":\"")
	contracts.write_json_string(&b, started_at)
	strings.write_string(&b, "\",\"server_port\":")
	strings.write_int(&b, server_port)
	strings.write_string(&b, ",\"background\":")
	strings.write_string(&b, background ? "true" : "false")
	// run_seq (REQ-SHELL-4) rides the start spec the same way started_at does: the hub
	// assigns it, the bridge echoes it back on every exit it reports. A bridge that
	// predates this key parses it as 0, which is the first run.
	strings.write_string(&b, ",\"run_seq\":")
	strings.write_int(&b, run_seq)
	if enc_spec != "" {
		strings.write_string(&b, ",\"enc_spec\":\"")
		contracts.write_json_string(&b, enc_spec)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// _shell_background_command_json asks the bridge to convert a live foreground run
// to background (REQ-SHELL-2 §3). Fire-and-forget, like kill and signal: the
// bridge persists the flag and releases the blocked caller, and there is no reply
// the hub needs.
_shell_background_command_json :: proc(session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_background\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_kill_command_json :: proc(command_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_kill\",\"command_id\":\"")
	contracts.write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"timeout_ms\":10000,\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_signal_command_json :: proc(session_id: string, signal: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_signal\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"signal\":")
	strings.write_int(&b, signal)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_restart_command_json :: proc(cmd_id, session_id: string, run_seq: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_restart\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	// The run_seq the restarted session is to carry FROM NOW ON (REQ-SHELL-4). The
	// hub has already incremented it, so everything the bridge reports after this
	// point is stamped with the new run and the previous run's queued exits — which
	// may still be sitting in the bridge's durable outbox — no longer match the row.
	strings.write_string(&b, "\",\"run_seq\":")
	strings.write_int(&b, run_seq)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_stream_attach_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_stream_attach\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_stream_detach_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_stream_detach\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// _set_port_unreachable_message turns the sink's own wording into one sentence the
// caller can act on, keeping the original cause visible. Deliberately not a new error
// code: Bridge_Offline already means "the bridge could not be reached", and inventing
// a second code for the same condition is how two vocabularies start.
_set_port_unreachable_message :: proc(err: domain.Domain_Error) -> string {
	cause := err.message
	if cause == "" do cause = "bridge unreachable"
	return fmt.tprintf("the bridge did not apply the port, so nothing changed (%s)", cause)
}

_shell_set_port_command_json :: proc(cmd_id, session_id: string, server_port: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_set_port\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"server_port\":")
	strings.write_int(&b, server_port)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_logs_command_json :: proc(cmd_id, session_id: string, offset, limit_val: int, grep: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_logs\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"offset\":")
	strings.write_int(&b, offset)
	strings.write_string(&b, ",\"limit\":")
	strings.write_int(&b, limit_val)
	strings.write_string(&b, ",\"grep\":\"")
	contracts.write_json_string(&b, grep)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

_shell_get_pane_command_json :: proc(cmd_id, session_id, since_hash: string, width, line_limit: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_get_pane\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"since_hash\":\"")
	contracts.write_json_string(&b, since_hash)
	strings.write_string(&b, "\",\"width\":")
	strings.write_int(&b, width)
	strings.write_string(&b, ",\"line_limit\":")
	strings.write_int(&b, line_limit)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_capture_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_capture\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// --- bridge reply JSON parsers ---

_json_str :: proc(body, key: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, allocator = allocator)
}

// REQ-SHELL-16 D1b: a bridge refusal must arrive carrying its reason.
//
// Every `if !_json_bool(reply, "ok")` site used to answer with a constant string while
// the bridge's own `error` field sat unread in `reply`. The effect was that the cause of
// a user-visible failure was recoverable from nowhere: not the session row, not the
// bridge journal (which logged nothing before D1a), and not the hub's error. The shape
// here is lifted from the ONE site that already did it right — the set_server_port
// branch, which maps the shared refusal vocabulary and only then falls back.
//
// OWNERSHIP, which this file has already been bitten by twice: `_json_str` returns
// BUILDER-HEAP memory, and `domain_error` (domain/errors.odin:46) does NOT clone its
// message — it stores the string it is handed. So the reason is freed here and the
// returned message lives in the PER-REQUEST TEMP ARENA via fmt.tprintf, the same
// discipline as the port-conflict error above and the cmd_id note in shell_session_create.
//
// The guard on the delete is not defensive noise: `_json_str` returns a non-allocated ""
// literal when the key is absent, so an unconditional delete is a bad free on exactly the
// case this proc exists to handle — a bridge reply with no `error` field at all.
//
// T10 (REQ-T10-2): a refusal that names a known `error_code` (today: `vault_locked`)
// becomes the TYPED error for it — HTTP 423 with details.bridge_id — instead of the
// generic 500, so the client can tell "locked" from a crash. Unknown codes and replies
// with no code keep the 500 below.
//
// REQ-ERR-PROTO-A: the reply's typed error decides the outcome. Its code picks the
// status (session_not_running -> 409, session_not_found -> 404, output_reclaimed ->
// 410, ...), its class and cause ride along, and the message is display only. A
// reply with no typed error is a contract violation and stays a 500.
_bridge_failure :: proc(reply, fallback: string, bridge_id := "") -> domain.Domain_Error {
	werr, found := contracts.wire_error_parse(reply, context.temp_allocator)
	if !found do return domain.domain_error(.Internal_Error, fallback)
	if werr.code == .Vault_Locked do return domain.vault_locked_error(bridge_id)
	err := domain.domain_error_from_wire(werr)
	err.message = fmt.tprintf("%s: %s", fallback, err.message)
	return err
}

_json_int :: proc(body, key: string, default_value: int) -> int {
	return jsonx.extract_int(body, key, default_value)
}

_json_bool :: proc(body, key: string) -> bool {
	return jsonx.extract_bool(body, key, false)
}

_json_array_raw :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_array(body, key, allocator = allocator)
	if !ok do return strings.clone("[]", allocator)
	return res
}

// _shell_session_publish_changed (REQ-2) announces a non-terminal row change the
// shell list shows - running/pid, restart (run_seq), port, background - as a
// resource_changed/shell_session the UI already invalidates on. Called only after
// the write succeeded.
_shell_session_publish_changed :: proc(svc: ^Shell_Session_Service, session: domain.Shell_Session, change: string) {
	if svc == nil || svc.events == nil || session.owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"status\":\"")
	contracts.write_json_string(&b, session.status)
	fmt.sbprintf(&b, "\",\"pid\":%d,\"port\":%d,\"run_seq\":%d,\"background\":%v,\"chain_id\":\"", session.pid, session.server_port, session.run_seq, session.background)
	contracts.write_json_string(&b, session.chain_id)
	strings.write_string(&b, "\"}")
	events.publish_resource_changed(svc.events, session.owner_user_id, "shell_session", session.session_id, change, strings.to_string(b))
}

// _shell_session_started_event_json builds the CREATION counterpart of
// _shell_exited_event_json. REQ-SHELL-6 §6 removed every poller and made the shell UI
// purely push-driven, but the only publish in this file was the terminal one below —
// so a session existed in the DB from the moment it was created and the UI heard about
// it for the first time when it DIED. A foreground run was therefore invisible for its
// whole life and then appeared already-terminal, which also hid the live-only controls
// (the spinner and the §3 Background toggle) for the entire window in which they are
// the only thing that can be clicked.
//
// `chain_id` is carried because the client invalidates by session AND by chain
// (wsInvalidation.ts, invalidateShellSession) so that a `server` repaints the chain
// summary's active-server list on the same frame. It is omitted when empty rather than
// sent as "" to match the exited event's treatment of an absent exit_code.
_shell_session_started_event_json :: proc(session_id, kind, status, chain_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_session_started\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	contracts.write_json_string(&b, kind)
	strings.write_string(&b, "\",\"status\":\"")
	contracts.write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if chain_id != "" {
		strings.write_string(&b, ",\"chain_id\":\"")
		contracts.write_json_string(&b, chain_id)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"ts\":")
	strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

_shell_exited_event_json :: proc(session_id, status: string, exit_code: int, exit_code_set: bool, error_code := "", bridge_id := "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_session_exited\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"status\":\"")
	contracts.write_json_string(&b, status)
	strings.write_string(&b, "\"")
	// T10 (REQ-T10-2/3): a start the bridge REFUSED names why on the user-WS channel
	// too, so a client that only hears events can still show the locked overlay.
	if error_code != "" {
		strings.write_string(&b, ",\"error_code\":\"")
		contracts.write_json_string(&b, error_code)
		strings.write_string(&b, "\",\"bridge_id\":\"")
		contracts.write_json_string(&b, bridge_id)
		strings.write_string(&b, "\"")
	}
	if exit_code_set {
		strings.write_string(&b, ",\"exit_code\":")
		strings.write_int(&b, exit_code)
	}
	strings.write_string(&b, ",\"ts\":")
	strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// shell_session_get_row is the TRUSTED by-id lookup for hub-internal consumers
// of a bridge event that was already applied (Task System v2 verify facets):
// scoped by the reporting bridge like handle_exited's fallback, never by user.
shell_session_get_row :: proc(svc: ^Shell_Session_Service, bridge_id, session_id: string) -> (domain.Shell_Session, bool) {
	if svc == nil || svc.repo == nil || session_id == "" do return {}, false
	session, found, err := iface.shell_session_get_by_id(svc.repo, bridge_id, session_id)
	if !found || err.code != .None do return {}, false
	return session, true
}
