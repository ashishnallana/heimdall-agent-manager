package main

// BR-3: ham-pty-host event subscription loop.
//
// The daemon multiplexes per-instance events on any attached connection: the
// bridge opens ONE long-lived connection, subscribes (Attach) to instances it
// launches, and reads the framed reply/event stream. Each event maps onto the
// bridge's existing status/activity surface (the same procs the wrapper endpoint
// called), so the hub sees identical semantics with no wrapper in the loop:
//
//   ChildExited   -> bridge_pty_host_apply_child_exited   (status stopped)
//   StartupReady  -> bridge_pty_host_apply_startup_ready  (liveness, stays starting)
//   StartupBlocked-> bridge_pty_host_apply_startup_blocked (status blocked)
//   ScreenChanged -> capture a burst + classify -> apply_activity (pane_diff)
//
// ScreenChanged is a cheap dirty signal (a content hash). On it the bridge
// captures a short burst of rendered screens (host.capture) a few hundred ms apart
// and runs the ported spinner-masking classifier, so a ticking footer/spinner does
// not read as false-active. This keeps the daemon dumb (raw hash) and the policy
// in the bridge, exactly as the design requires.

import local_socket "odin_test:lib/local_socket"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Burst shape for ScreenChanged-triggered classification. Mirrors the wrapper's
// stateless burst detector: a few frames captured a short gap apart so a slow
// token stream visibly grows (=> active) while a quiet pane's masked frames stay
// identical (=> idle).
PTY_HOST_BURST_FRAMES :: 3
PTY_HOST_BURST_GAP_MS :: 400

pty_host_events_started: bool
pty_host_events_lock: sync.Mutex

// Activity-classification work queue (BR-3): ScreenChanged handling is blocking
// (~800ms of burst captures), so it MUST NOT run in the read loop. The read loop
// enqueues (instance, socket) here and a dedicated worker drains it. The queue is
// COALESCED per instance — a pending instance is not duplicated — so a burst of
// ScreenChanged for one agent collapses to a single reclassification, bounding the
// backlog regardless of how chatty an agent is.
pty_host_activity_queue: [dynamic]string
pty_host_activity_socket: string
pty_host_activity_lock: sync.Mutex

// bridge_pty_host_events_ensure starts the single event-subscription worker AND
// the activity-classification worker once (idempotent). Called after the first
// successful spawn so there is a daemon to attach to. Safe to call repeatedly.
//
// Per-child liveness is delivered by the daemon's pushed Host_Heartbeat digest on
// the event connection (see bridge_pty_host_dispatch_event); the read loop stays
// tight (offloading blocking activity work below) so heartbeats/exits are always
// drained promptly.
bridge_pty_host_events_ensure :: proc() {
	sync.mutex_lock(&pty_host_events_lock)
	defer sync.mutex_unlock(&pty_host_events_lock)
	if pty_host_events_started do return
	pty_host_events_started = true
	pty_host_activity_queue = make([dynamic]string)
	thread.run(bridge_pty_host_events_worker)
	thread.run(bridge_pty_host_activity_worker)
}

// bridge_pty_host_enqueue_screen_changed queues an instance for activity
// reclassification, coalescing duplicates so the queue never grows unbounded under
// a chatty agent. Called from the read loop; returns immediately.
bridge_pty_host_enqueue_screen_changed :: proc(socket, instance: string) {
	if strings.trim_space(instance) == "" do return
	sync.mutex_lock(&pty_host_activity_lock)
	defer sync.mutex_unlock(&pty_host_activity_lock)
	if pty_host_activity_socket == "" do pty_host_activity_socket = strings.clone(socket)
	for id in pty_host_activity_queue do if id == instance do return
	append(&pty_host_activity_queue, strings.clone(instance))
}

// bridge_pty_host_activity_worker drains the activity queue, running the blocking
// burst-capture classification OFF the read loop so it never stalls heartbeat/exit
// delivery. It sleeps briefly when the queue is empty.
bridge_pty_host_activity_worker :: proc() {
	for {
		instance := ""
		socket := ""
		sync.mutex_lock(&pty_host_activity_lock)
		if len(pty_host_activity_queue) > 0 {
			instance = pty_host_activity_queue[0]
			ordered_remove(&pty_host_activity_queue, 0)
			socket = pty_host_activity_socket
		}
		sync.mutex_unlock(&pty_host_activity_lock)
		if instance == "" {
			time.sleep(100 * time.Millisecond)
			continue
		}
		bridge_pty_host_handle_screen_changed(socket, instance)
		delete(instance)
	}
}

// bridge_pty_host_events_worker is the long-lived reader. It (re)dials the daemon,
// subscribes to all currently-registered instances, and reads the event stream,
// dispatching each event. On disconnect it backs off and reconnects; the daemon
// (and its children) outlive a bridge reconnect.
//
// Every connection after the first is followed by an exit sweep (REQ-BR-3): any
// ChildExited broadcast while we were not subscribed — the gap between losing one
// connection and opening the next, or the whole life of a daemon we were not
// watching — is otherwise lost for good.
bridge_pty_host_events_worker :: proc() {
	connected_before := false
	for {
		socket := pty_host_socket_path()
		if bridge_pty_host_events_run_once(socket, sweep_after_subscribe = connected_before) {
			connected_before = true
		} else {
			time.sleep(500 * time.Millisecond)
		}
		delete(socket)
	}
}

// How often the read loop wakes with nothing to read, to check whether the daemon it
// is attached to is still the one serving the socket.
PTY_HOST_EVENTS_POLL_MS :: 1000
// A connection that has delivered nothing at all for this long is presumed dead and
// re-dialled. The daemon pushes Host_Heartbeat every 30s, so this is three missed beats.
PTY_HOST_EVENTS_SILENCE_LIMIT :: 90 * time.Second

// Pty_Host_Events_Daemon_Mark is what the event connection remembers about the daemon
// it dialled: the bridge's start counter and the socket's identity at that moment.
Pty_Host_Events_Daemon_Mark :: struct {
	generation: u64,
	identity:   Pty_Host_Daemon_Identity,
	has_id:     bool,
}

bridge_pty_host_events_daemon_mark :: proc(socket: string) -> Pty_Host_Events_Daemon_Mark {
	id, has_id := bridge_pty_host_daemon_identity(socket)
	return {generation = sync.atomic_load(&pty_host_daemon_generation), identity = id, has_id = has_id}
}

// bridge_pty_host_events_should_redial is REQ-BR-3's decision, kept pure so it can be
// tested without a daemon. Re-dial when:
//   * the bridge started a daemon since we dialled (generation moved), or
//   * the socket path now names a different socket (another daemon bound it), or
//   * the connection has been silent past PTY_HOST_EVENTS_SILENCE_LIMIT.
// The second rule is the one the incident needed: the replacement daemon unlinked and
// re-bound the socket while the old daemon — and our connection to it — stayed alive
// and kept sending heartbeats, so neither EOF nor silence ever came. A socket that is
// momentarily missing is NOT a reason: that is a daemon mid-restart, and the dial would
// just fail.
bridge_pty_host_events_should_redial :: proc(at_dial, now: Pty_Host_Events_Daemon_Mark, silent_for: time.Duration) -> bool {
	if now.generation != at_dial.generation do return true
	if at_dial.has_id && now.has_id && now.identity != at_dial.identity do return true
	return silent_for >= PTY_HOST_EVENTS_SILENCE_LIMIT
}

// bridge_pty_host_events_run_once opens one connection, attaches to every known
// instance, then reads+dispatches until the connection drops OR the daemon it is
// attached to is no longer the one serving the socket. Returns false on a failed dial
// so the caller backs off. sweep_after_subscribe runs an exit sweep once subscribed.
bridge_pty_host_events_run_once :: proc(socket: string, sweep_after_subscribe := false) -> bool {
	// Marked BEFORE the dial: a daemon replaced between the two then reads as a change
	// and costs one spurious re-dial, rather than being adopted as "ours" unnoticed.
	at_dial := bridge_pty_host_events_daemon_mark(socket)
	fd, ok := pty_host_dial(socket)
	if !ok do return false
	defer local_socket.close(fd)

	// Subscribe to host-level events (WatchEvents) instead of Attaching. The daemon
	// then delivers all bridge-relevant frames — HostHeartbeat, ChildExited,
	// ScreenChanged, StartupReady/Blocked — for ALL agents on this one connection,
	// WITHOUT the raw per-instance PTY Output flood that Attach would add. That
	// Output flood previously stalled this single-threaded read loop and delayed
	// heartbeat/exit processing, falsely reaping idle agents. Output stays
	// Attach-gated for the UI live-pane path only.
	{
		frame := pty_host_encode_watch_events()
		defer delete(frame)
		if !pty_host_send_all(fd, frame) do return true
	}
	// Subscribed: from here on no exit is missed, so sweeping now catches every exit
	// that happened while we were not listening.
	if sweep_after_subscribe do thread.run(bridge_shell_session_sweep_now)

	last_frame := time.tick_now()
	last_check := last_frame
	for {
		ready, poll_ok := local_socket.poll_readable(fd, PTY_HOST_EVENTS_POLL_MS)
		if !poll_ok do return true
		if ready {
			// Readable, or hung up/errored — the read then fails and we reconnect.
			payload, pok := pty_host_read_frame(fd)
			if !pok do return true // clean disconnect; caller will reconnect
			last_frame = time.tick_now()
			reply, dok := pty_host_decode_reply(payload)
			delete(payload)
			if dok {
				bridge_pty_host_dispatch_event(socket, reply)
				pty_host_reply_delete(reply)
			}
		}
		// At most once per poll interval, however busy the stream is.
		if time.tick_since(last_check) < PTY_HOST_EVENTS_POLL_MS * time.Millisecond do continue
		last_check = time.tick_now()
		now := bridge_pty_host_events_daemon_mark(socket)
		if bridge_pty_host_events_should_redial(at_dial, now, time.tick_since(last_frame)) {
			fmt.println("bridge pty-host events: the daemon serving", socket, "changed (or went silent); re-dialling")
			return true
		}
	}
}

// bridge_pty_host_dispatch_event routes one decoded event to the status/activity
// surface. Output/Screen/Pong/ack replies are ignored here (control-plane replies
// are consumed by their request callers); this loop cares about async events.
bridge_pty_host_dispatch_event :: proc(socket: string, reply: Pty_Host_Reply) {
	#partial switch reply.kind {
	case .Child_Exited:
		bridge_pty_host_apply_child_exited(reply.instance, reply.code)
	case .Startup_Ready:
		bridge_pty_host_apply_startup_ready(reply.instance)
	case .Startup_Blocked:
		bridge_pty_host_apply_startup_blocked(reply.instance, reply.reason_code, reply.message)
	case .Screen_Changed:
		// Do NOT run the burst-capture classification inline: it blocks ~800ms+
		// (3 captures * 400ms gaps) and would stall the single-threaded read loop,
		// starving Host_Heartbeat / Child_Exited frames that pile up unread behind
		// it — which caused idle agents to be falsely reaped while a busy agent's
		// ScreenChanged stream monopolized the loop. Hand off to the activity worker
		// (coalesced per instance) and keep reading.
		bridge_pty_host_enqueue_screen_changed(socket, reply.instance)
	case .Host_Heartbeat:
		// Per-child liveness digest pushed by the daemon on a fixed cadence:
		// refresh last_seen for every child the daemon reports alive. A dead child
		// reports alive=false (or drops from the roster) and stops being touched,
		// so it is still correctly reaped; ChildExited remains the instant path.
		for a in reply.heartbeat_agents {
			if a.alive {
				bridge_runtime_touch_liveness(a.instance_id, true)
			} else {
				bridge_runtime_set_pty_process_alive(a.instance_id, false)
			}
		}
	}
}

// bridge_pty_host_handle_screen_changed captures a short burst of rendered screens
// for instance and classifies activity from it (spinner-masked), then reports to
// the hub. The dirty signal only tells us SOMETHING changed; the burst + masking
// decide whether that is genuine work or just a ticking footer/spinner.
bridge_pty_host_handle_screen_changed :: proc(socket, instance: string) {
	frames := make([]string, PTY_HOST_BURST_FRAMES)
	got := 0
	for i in 0..<PTY_HOST_BURST_FRAMES {
		if text, ok := bridge_pty_host_capture_text(socket, instance); ok {
			frames[got] = text
			got += 1
		}
		if i < PTY_HOST_BURST_FRAMES - 1 do time.sleep(PTY_HOST_BURST_GAP_MS * time.Millisecond)
	}
	defer {
		for i in 0..<got do delete(frames[i])
		delete(frames)
	}
	if got == 0 do return
	sample := bridge_activity_burst_status(frames[:got])
	bridge_pty_host_apply_activity(instance, sample)
}

// bridge_pty_host_capture_text requests one screen snapshot and joins its lines
// into a single frame string. Caller owns the returned string.
bridge_pty_host_capture_text :: proc(socket, instance: string) -> (string, bool) {
	frame := pty_host_encode_capture(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return "", false
	defer pty_host_reply_delete(reply)
	if reply.kind != .Screen do return "", false
	return bridge_activity_screen_to_text(reply.screen.lines), true
}
