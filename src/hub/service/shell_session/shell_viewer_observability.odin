package shell_session

import "core:sync"
import "core:time"

// REQ-SHELL-41 (P0 addendum): SHELL VIEWER OBSERVABILITY.
//
// WHY. The coordinator's P0 note pinned the cost precisely: a viewer being silently
// unsubscribed is a KNOWN failure mode of this subsystem — it is what REQ-SHELL-33
// fixed — and shell_session_detach logged nothing, so if it happened again there would
// be no trace at all. In shell_session_broadcast_output the two branches were
// asymmetric: a non-ending write result was logged by _log_viewer_write, while the
// branch that actually DETACHED A LIVE VIEWER fell through to shell_session_detach and
// said nothing. The louder event was the silent one.
//
// WHAT IS DELIBERATELY NOT LOGGED: the Ok result on a viewer write. That path carries
// PTY output at roughly 11KB every 25ms, so logging it would be a defect in its own
// right (REQ-SHELL-41 AC3). Only non-Ok results, detaches, and the single first frame
// after a 0->1 viewer transition are recorded — all of them bounded per session, none
// of them per frame.

// Shell_Viewer_Detach_Reason names WHY a viewer was removed from a session's fan-out.
// The distinction that matters is ORDINARY (the viewer's own stream handler returned)
// versus FORCED (the hub dropped a live viewer because a write failed) — conflating
// those is what made REQ-SHELL-33's silent unsubscribe so expensive to find.
Shell_Viewer_Detach_Reason :: enum {
	// No reason supplied. Reachable only from callers that have not been updated, and
	// rendered as "unspecified" so it reads as a gap rather than as something benign.
	Unspecified,
	// The viewer's own WS stream handler returned and detached on its way out. The
	// ordinary case, and the only one that is not a symptom.
	Stream_Closed,
	// A write found the client gone. The viewer did not ask to leave.
	Peer_Gone,
	// A write left a partial frame on the wire, so the stream is unparseable from here
	// on and ending it IS the recovery. Still a forced detach, and still worth a line.
	Desynchronised,
}

shell_viewer_detach_reason_string :: proc(reason: Shell_Viewer_Detach_Reason) -> string {
	switch reason {
	case .Unspecified:    return "unspecified"
	case .Stream_Closed:  return "stream_closed"
	case .Peer_Gone:      return "peer_gone"
	case .Desynchronised: return "desynchronised"
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// First-frame tracking for the 0->1 viewer transition.
// ---------------------------------------------------------------------------
//
// The P0 note asks for the FIRST frame emitted after a session gains its first viewer,
// with session id and byte count — the line that answers "did anything ever actually
// reach the browser" for a session that renders nothing. That needs one bit of state
// per session, remembered between the attach and the next output frame.
//
// A FIXED SLOT TABLE, NOT A MAP, AND THE REASON IS SPECIFIC. The service's existing
// per-session maps (session_owners, session_bridges) own heap-cloned keys, and their
// removal path carries a documented use-after-free hazard around freeing a key while
// still indexing by it (shell_session_service.odin:1419). Adding a fourth map of the
// same shape would mean joining that discipline for one bit of diagnostic state. This
// table stores ids inline instead, so it allocates nothing, frees nothing, and cannot
// participate in that hazard. An entry left behind by a session that never emitted a
// frame is reclaimed by eviction, not by bookkeeping.
SHELL_FIRST_FRAME_SLOTS :: 64
SHELL_FIRST_FRAME_ID_MAX :: 64

Shell_First_Frame_Slot :: struct {
	id:       [SHELL_FIRST_FRAME_ID_MAX]byte,
	id_len:   int,
	armed:    bool,
	seq:      u64, // insertion order, so eviction can pick the stalest slot
	armed_at: time.Tick, // when the 0->1 attach happened; feeds first_frame_latency_seconds
}

Shell_First_Frame_Tracker :: struct {
	mu:    sync.Mutex,
	next:  u64,
	slots: [SHELL_FIRST_FRAME_SLOTS]Shell_First_Frame_Slot,
}

// Process-wide and zero-value usable: a mutex and a fixed array need no initialisation,
// so tests that build a bare Shell_Session_Service{} (several do) are unaffected.
shell_first_frame_tracker: Shell_First_Frame_Tracker

// shell_first_frame_arm marks a session as awaiting its first post-attach frame. Called
// on the 0->1 viewer transition only.
shell_first_frame_arm :: proc(session_id: string) {
	if session_id == "" do return
	tr := &shell_first_frame_tracker
	sync.mutex_lock(&tr.mu)
	defer sync.mutex_unlock(&tr.mu)
	key_len := min(len(session_id), SHELL_FIRST_FRAME_ID_MAX)

	free_idx := -1
	oldest_idx := 0
	for i in 0 ..< SHELL_FIRST_FRAME_SLOTS {
		s := &tr.slots[i]
		if s.id_len == key_len && string(s.id[:s.id_len]) == session_id[:key_len] {
			tr.next += 1
			s.armed = true
			s.seq = tr.next
			s.armed_at = time.tick_now()
			return
		}
		if s.id_len == 0 && free_idx < 0 do free_idx = i
		if s.seq < tr.slots[oldest_idx].seq do oldest_idx = i
	}
	idx := free_idx if free_idx >= 0 else oldest_idx
	s := &tr.slots[idx]
	copy(s.id[:], session_id[:key_len])
	s.id_len = key_len
	tr.next += 1
	s.armed = true
	s.seq = tr.next
	s.armed_at = time.tick_now()
}

// shell_first_frame_take returns true EXACTLY ONCE per arming — the frame that gets
// logged — and false for every frame after it. That once-only contract is what keeps
// this off the per-frame path.
shell_first_frame_take :: proc(session_id: string) -> bool {
	fired, _ := shell_first_frame_take_latency(session_id)
	return fired
}

// shell_first_frame_take_latency is shell_first_frame_take plus the elapsed time
// since the arming attach, so the one-shot also feeds
// heimdall_shell_first_frame_latency_seconds. latency is 0 when fired is false.
shell_first_frame_take_latency :: proc(session_id: string) -> (fired: bool, latency: time.Duration) {
	if session_id == "" do return false, 0
	tr := &shell_first_frame_tracker
	sync.mutex_lock(&tr.mu)
	defer sync.mutex_unlock(&tr.mu)
	key_len := min(len(session_id), SHELL_FIRST_FRAME_ID_MAX)
	for i in 0 ..< SHELL_FIRST_FRAME_SLOTS {
		s := &tr.slots[i]
		if s.id_len == key_len && string(s.id[:s.id_len]) == session_id[:key_len] {
			if !s.armed do return false, 0
			s.armed = false
			return true, time.tick_since(s.armed_at)
		}
	}
	return false, 0
}
