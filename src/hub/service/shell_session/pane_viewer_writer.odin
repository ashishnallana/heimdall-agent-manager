package shell_session

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import metrics "odin_test:lib/metrics"
import contracts "odin_test:contracts"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

// Queues own their strings. Only this worker writes the registered socket;
// the HTTP reader removes the registration, joins the worker, then closes it.
PANE_VIEWER_LIMIT :: 4096
PANE_VIEWERS_PER_BRIDGE :: 256
PANE_VIEWER_QUEUE_BYTES :: 256 * 1024
PANE_VIEWER_QUEUE_FRAMES :: 256
PANE_SNAPSHOT_QUEUE_BYTES :: 2 * 1024 * 1024
PANE_BRIDGE_QUEUE_BYTES :: 8 * 1024 * 1024
PANE_CONTROL_QUEUE_BYTES :: 16 * 1024
PANE_CONTROL_QUEUE_FRAMES :: 8
Pane_Viewer_Frame :: struct { text: string, incremental, control: bool, opcode: u8 }
Pane_Viewer_Writer :: struct {
	mu: sync.Mutex,
	cond: sync.Cond,
	socket: net.TCP_Socket,
	queue: [dynamic]Pane_Viewer_Frame,
	svc: ^Shell_Session_Service,
	bridge_id: string,
	session_id: string,
	incremental_bytes: int,
	control_bytes: int,
	snapshot_bytes: int,
	bytes: int,
	stopped: bool,
	worker: ^thread.Thread,
	// Telemetry (plan 3.4/3.5). ws_kind is the heimdall_ws_* `kind` label this viewer
	// socket belongs to (shell or agent_stream); tx_bytes is the cached
	// heimdall_ws_bytes_total{kind,"tx",bridge_id} series so the write loop only does
	// an atomic add. Both are set once at start and read-only afterwards.
	ws_kind: string,
	tx_bytes: ^metrics.Series,
}

pane_viewer_start_locked :: proc(svc: ^Shell_Session_Service, socket: net.TCP_Socket, bridge_id, session_id: string, ws_kind: string = project_service.WS_KIND_SHELL) -> bool {
	if svc.viewer_writers == nil do svc.viewer_writers = make(map[net.TCP_Socket]^Pane_Viewer_Writer, runtime.heap_allocator())
	if _, exists := svc.viewer_writers[socket]; exists do return true
	w := new(Pane_Viewer_Writer, runtime.heap_allocator())
	w.socket = socket
	w.svc = svc
	w.bridge_id = strings.clone(bridge_id, runtime.heap_allocator())
	w.session_id = strings.clone(session_id, runtime.heap_allocator())
	w.ws_kind = ws_kind
	w.tx_bytes = metrics.with(project_service.fleet_metrics.ws_bytes, ws_kind, "tx", bridge_id)
	if svc.pane_bridge_bytes == nil do svc.pane_bridge_bytes = make(map[string]int, runtime.heap_allocator())
	w.queue = make([dynamic]Pane_Viewer_Frame, runtime.heap_allocator())
	_ = net.set_option(socket, .Send_Timeout, 5 * time.Second)
	context.allocator = runtime.heap_allocator() // the Thread record outlives the caller's arena
	w.worker = thread.create_and_start_with_data(rawptr(w), pane_viewer_writer_run, self_cleanup = false)
	if w.worker == nil {
		delete(w.queue); delete(w.bridge_id, runtime.heap_allocator()); delete(w.session_id, runtime.heap_allocator()); free(w, runtime.heap_allocator()); _ = net.shutdown(socket, .Both); return false
	}
	svc.viewer_writers[socket] = w
	return true
}

pane_viewer_writer_run :: proc(raw: rawptr) {
	context = runtime.default_context()
	w := (^Pane_Viewer_Writer)(raw)
	for {
		sync.mutex_lock(&w.mu)
		for len(w.queue) == 0 && !w.stopped do sync.cond_wait(&w.cond, &w.mu)
		if w.stopped { sync.mutex_unlock(&w.mu); break }
		item := w.queue[0]
		text := item.text
		ordered_remove(&w.queue, 0)
		// Count the in-flight frame until its write completes.
		sync.mutex_unlock(&w.mu)
		result := ws.write_server_opcode(w.socket, item.opcode, text, true)
		if result == .Ok {
			metrics.counter_add(w.tx_bytes, u64(len(text)))
			shell_metrics_note_fanout(len(text))
		} else {
			metrics.counter_inc(metrics.with(project_service.fleet_metrics.ws_write_errors, w.ws_kind, ws_write_reason_string(result)))
		}
		if result == .Ok && !item.control {
			if fired, latency := shell_first_frame_take_latency(w.session_id); fired {
				shell_metrics_note_first_frame(latency)
				fmt.println("shell first frame after attach", "session=", w.session_id, "bytes=", len(text), "viewer=", int(w.socket))
			}
		}
		sync.mutex_lock(&w.svc.mu)
		sync.mutex_lock(&w.mu)
		w.svc.pane_bridge_bytes[w.bridge_id] -= len(text)
		w.bytes -= len(text)
		if item.incremental do w.incremental_bytes -= len(text)
		if item.control do w.control_bytes -= len(text)
		if !item.control && !item.incremental do w.snapshot_bytes -= len(text)
		if result != .Ok do w.stopped = true
		sync.mutex_unlock(&w.mu)
		sync.mutex_unlock(&w.svc.mu)
		delete(text, runtime.heap_allocator())
		if result != .Ok {
			fmt.eprintfln("ham-hub WARN pane viewer disconnected reason=write_failure result=%v viewer=%d", result, int(w.socket))
			_ = net.shutdown(w.socket, .Both)
			break
		}
	}
}

pane_viewer_enqueue :: proc(svc: ^Shell_Session_Service, socket: net.TCP_Socket, text: string, opcode: u8 = 0x1) -> ws.Text_Write_Result {
	if len(text) > ws.WS_MAX_SERVER_PAYLOAD do return .Too_Large
	if svc == nil do return ws.write_server_opcode(socket, opcode, text, true)
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	w, exists := svc.viewer_writers[socket]
	if !exists do return .Peer_Gone
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	if w.stopped do return .Peer_Gone
	// Queue class (REQ-PTY-NET-2): a BINARY frame is pty data — incremental output under
	// the tight bound, snapshot/screen under the larger one; every TEXT frame is a small
	// JSON control frame (ready/status/stream_*/error); anything else (pong) is control.
	incremental := opcode == 0x2 && contracts.pty_wire_viewer_frame_is_incremental_output(transmute([]byte)text)
	control := opcode != 0x2
	data_frames, control_frames := 0, 0
	for item in w.queue { if item.control { control_frames += 1 } else { data_frames += 1 } }
	bridge_limit := PANE_BRIDGE_QUEUE_BYTES + 64 * 1024 if control else PANE_BRIDGE_QUEUE_BYTES
	snapshot := !incremental && !control
	over_bytes := (snapshot && len(text) > PANE_SNAPSHOT_QUEUE_BYTES - w.snapshot_bytes) || (incremental && len(text) > PANE_VIEWER_QUEUE_BYTES - w.incremental_bytes) || (control && len(text) > PANE_CONTROL_QUEUE_BYTES - w.control_bytes) || len(text) > PANE_SNAPSHOT_QUEUE_BYTES + PANE_VIEWER_QUEUE_BYTES + PANE_CONTROL_QUEUE_BYTES - w.bytes
	over_frames := control_frames >= PANE_CONTROL_QUEUE_FRAMES if control else data_frames >= PANE_VIEWER_QUEUE_FRAMES
	if over_bytes || over_frames || len(text) > bridge_limit - svc.pane_bridge_bytes[w.bridge_id] {
		w.stopped = true
		sync.cond_signal(&w.cond)
		// Wake the owner reader; it detaches and joins before closing the fd.
		_ = net.shutdown(w.socket, .Both)
		fmt.eprintfln("ham-hub WARN pane viewer disconnected reason=slow_consumer viewer=%d queued_bytes=%d", int(socket), w.bytes)
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.ws_write_errors, w.ws_kind, "slow_consumer"))
		return .Peer_Gone
	}
	append(&w.queue, Pane_Viewer_Frame{strings.clone(text, runtime.heap_allocator()), incremental, control, opcode})
	if _, present := svc.pane_bridge_bytes[w.bridge_id]; !present { svc.pane_bridge_bytes[strings.clone(w.bridge_id, runtime.heap_allocator())] = 0 }
	svc.pane_bridge_bytes[w.bridge_id] += len(text)
	if incremental do w.incremental_bytes += len(text)
	if control do w.control_bytes += len(text)
	if snapshot do w.snapshot_bytes += len(text)
	w.bytes += len(text)
	sync.cond_signal(&w.cond)
	return .Ok
}

// Caller holds the session sequencing lock when enqueueing snapshot chunks.
shell_session_enqueue_viewer_frame :: proc(svc: ^Shell_Session_Service, socket: net.TCP_Socket, text: string, opcode: u8 = 0x1) -> ws.Text_Write_Result {
	return pane_viewer_enqueue(svc, socket, text, opcode)
}

pane_viewer_stop :: proc(w: ^Pane_Viewer_Writer) {
	sync.mutex_lock(&w.mu)
	w.stopped = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mu)
	_ = net.shutdown(w.socket, .Both)
	thread.join(w.worker)
	thread.destroy(w.worker)
	sync.mutex_lock(&w.svc.mu)
	if _, present := w.svc.pane_bridge_bytes[w.bridge_id]; present {
		w.svc.pane_bridge_bytes[w.bridge_id] -= w.bytes
		if w.svc.pane_bridge_bytes[w.bridge_id] == 0 {
			for key, count in w.svc.pane_bridge_bytes {
				if key == w.bridge_id { delete_key(&w.svc.pane_bridge_bytes, key); delete(key, runtime.heap_allocator()); break }
			}
		}
	}
	sync.mutex_unlock(&w.svc.mu)
	for item in w.queue do delete(item.text, runtime.heap_allocator())
	delete(w.bridge_id, runtime.heap_allocator())
	delete(w.session_id, runtime.heap_allocator())
	delete(w.queue)
	free(w, runtime.heap_allocator())
}

pane_viewers_stop_all :: proc(svc: ^Shell_Session_Service) {
	// Service shutdown happens after request readers have drained.
	for socket, w in svc.viewer_writers {
		pane_viewer_stop(w)
	}
	delete(svc.viewer_writers)
	svc.viewer_writers = nil
	for key, count in svc.pane_bridge_bytes do delete(key, runtime.heap_allocator())
	delete(svc.pane_bridge_bytes)
	svc.pane_bridge_bytes = nil
}

shell_session_viewer_write_release :: proc(svc: ^Shell_Session_Service, session_id: string) {
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	svc.viewer_write_refs[session_id] -= 1
	pane_sequence_collect_locked(svc, session_id)
}

pane_sequence_collect_locked :: proc(svc: ^Shell_Session_Service, session_id: string) {
	if len(svc.viewers[session_id]) != 0 || svc.viewer_write_refs[session_id] != 0 do return
	// REQ-PTY-NET-4: no viewers left — the cached repaint goes with them (the next 0->1
	// attach earns a fresh catch-up from the pty-host anyway).
	_snapshot_cache_evict_locked(svc, session_id)
	for key, mu in svc.viewer_write_mu {
		if key == session_id {
			delete_key(&svc.viewer_write_refs, key)
			delete_key(&svc.viewer_write_mu, key)
			free(mu, runtime.heap_allocator())
			delete(key, runtime.heap_allocator())
			break
		}
	}
	for key, viewers in svc.viewers {
		if key == session_id {
			delete_key(&svc.viewers, key)
			delete(viewers)
			delete(key, runtime.heap_allocator())
			break
		}
	}
}

// Bridge reader requests recovery without performing network writes or joins.
shell_session_resync_viewers :: proc(svc: ^Shell_Session_Service, session_id: string, bridge_id: string = "") {
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if bridge_id != "" && svc.session_bridges[session_id] != bridge_id do return
	for socket in svc.viewers[session_id] {
		w := svc.viewer_writers[socket]
		if w == nil do continue
		sync.mutex_lock(&w.mu)
		w.stopped = true
		sync.cond_signal(&w.cond)
		_ = net.shutdown(w.socket, .Both)
		sync.mutex_unlock(&w.mu)
	}
}

shell_session_bridge_owns_stream :: proc(svc: ^Shell_Session_Service, session_id, bridge_id: string) -> bool {
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	return svc.session_bridges[session_id] == bridge_id
}

shell_session_enqueue_viewer_control :: proc(svc: ^Shell_Session_Service, socket: net.TCP_Socket, opcode: u8, payload: string) -> bool {
	return pane_viewer_enqueue(svc, socket, payload, opcode) == .Ok
}
