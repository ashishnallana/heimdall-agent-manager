package shell_session

// REQ-PTY-NET-4 — single repaint on attach.
//
// Every attach used to produce TWO full-screen repaints for the viewer that triggered the
// bridge attach: the pty-host catch-up (broadcast by the bridge as an OUTPUT|SNAPSHOT
// sequence) and the hub's own `shell_get_pane` capture (a bridge round-trip answered with
// SCREEN frames to that one socket). The hub now remembers the most recent repaint per
// session — whichever source produced it — and a viewer's first-resize snapshot is served
// from that memory:
//
//   - the viewer that already received the catch-up broadcast gets NOTHING more
//     (.Already_Painted): it has a full screen, REQ-SHELL-61's intent is met once;
//   - a late joiner gets the cached repaint written to its socket alone (.Serve), with no
//     bridge round-trip, when the cache is fresh (< SHELL_SNAPSHOT_CACHE_FRESH) or was
//     captured at the geometry it asked for;
//   - otherwise (.Miss) the caller falls back to the capture round-trip and STORES the
//     result here, so the next joiner is served from it.
//
// What is cached is the exact viewer frames that went (or will go) on the wire — plaintext
// or vault ciphertext, the hub cannot tell and does not need to — so serving is a replay
// of bytes, not a re-encode. An encrypted catch-up replayed to a second viewer reuses the
// same ciphertext under the same nonce, which is fine: nothing new is encrypted.
//
// Bounds: SHELL_SNAPSHOT_CACHE_MAX_BYTES per session (a larger repaint is simply not
// cached); evicted when the session's last viewer leaves, when the stream closes/exits,
// and on service teardown. Protected by svc.mu like the other per-session maps.

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import ws "odin_test:lib/ws"

SHELL_SNAPSHOT_CACHE_MAX_BYTES :: 1024 * 1024
SHELL_SNAPSHOT_CACHE_FRESH     :: 2 * time.Second
// A catch-up smaller than this cannot be a full screen (REQ-SHELL-61's "carries little or
// nothing" case — e.g. a bare cursor-positioning escape); it neither paints a viewer nor
// serves a joiner, so the capture round-trip still happens for that attach.
SHELL_SNAPSHOT_CACHE_MIN_CATCHUP_BYTES :: 16

Shell_Snapshot_Cache_Entry :: struct {
	frames:   [dynamic][]byte,          // ready-to-write viewer frames, in order (heap)
	bytes:    int,
	at:       time.Tick,
	cols:     int,                      // -1 when unknown (pty-host catch-up)
	rows:     int,
	catchup:  bool,                     // from the bridge broadcast (else a hub capture)
	open:     bool,                     // a catch-up sequence is still being appended
	oversize: bool,                     // exceeded the cap; frames dropped
	painted:  [dynamic]net.TCP_Socket,  // viewers that already received these frames
}

Shell_Snapshot_Decision :: enum {
	Miss,
	Already_Painted,
	Serve,
}

@(private = "file")
_snapshot_entry_free :: proc(e: ^Shell_Snapshot_Cache_Entry, heap: runtime.Allocator) {
	for f in e.frames do delete(f, heap)
	delete(e.frames)
	delete(e.painted)
	free(e, heap)
}

@(private = "file")
_snapshot_entry_new :: proc(heap: runtime.Allocator) -> ^Shell_Snapshot_Cache_Entry {
	e := new(Shell_Snapshot_Cache_Entry, heap)
	e.frames = make([dynamic][]byte, heap)
	e.painted = make([dynamic]net.TCP_Socket, heap)
	e.cols, e.rows = -1, -1
	e.at = time.tick_now()
	return e
}

// _snapshot_cache_evict_locked removes the session's entry. Caller holds svc.mu.
_snapshot_cache_evict_locked :: proc(svc: ^Shell_Session_Service, session_id: string) {
	heap := runtime.heap_allocator()
	for key, e in svc.snapshot_cache {
		if key == session_id {
			delete_key(&svc.snapshot_cache, key)
			_snapshot_entry_free(e, heap)
			delete(key, heap)
			break
		}
	}
}

// _snapshot_cache_forget_viewer_locked drops `socket` from the session's painted set.
// A socket is an OS fd, and the OS reuses a closed fd for the next connection, so a
// detached viewer must not stay "painted": a new viewer that happens to get the same fd
// would be told Already_Painted and left with a blank pane. Called on every detach and
// on every attach. Caller holds svc.mu.
_snapshot_cache_forget_viewer_locked :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket) {
	e, have := svc.snapshot_cache[session_id]
	if !have do return
	for i := len(e.painted) - 1; i >= 0; i -= 1 {
		if e.painted[i] == socket do unordered_remove(&e.painted, i)
	}
}

shell_session_snapshot_cache_evict :: proc(svc: ^Shell_Session_Service, session_id: string) {
	if svc == nil || session_id == "" do return
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	_snapshot_cache_evict_locked(svc, session_id)
}

_snapshot_cache_free_all_locked :: proc(svc: ^Shell_Session_Service) {
	heap := runtime.heap_allocator()
	for key, e in svc.snapshot_cache {
		delete(key, heap)
		_snapshot_entry_free(e, heap)
	}
	delete(svc.snapshot_cache)
	svc.snapshot_cache = nil
}

@(private = "file")
_snapshot_entry_append_locked :: proc(e: ^Shell_Snapshot_Cache_Entry, frame: []byte, heap: runtime.Allocator) {
	if e.oversize do return
	if e.bytes + len(frame) > SHELL_SNAPSHOT_CACHE_MAX_BYTES {
		for f in e.frames do delete(f, heap)
		clear(&e.frames)
		e.bytes = 0
		e.oversize = true
		return
	}
	copied := make([]byte, len(frame), heap)
	copy(copied, frame)
	append(&e.frames, copied)
	e.bytes += len(frame)
}

// shell_session_snapshot_cache_note_output is called by the fan-out for EVERY output
// frame. A snapshot frame that follows a non-snapshot frame (or nothing) starts a new
// catch-up entry; further snapshot frames extend it; a non-snapshot frame closes it.
// `sockets` are the viewers the frame was fanned out to — they are painted by it.
shell_session_snapshot_cache_note_output :: proc(svc: ^Shell_Session_Service, session_id: string, frame: []byte, is_snapshot: bool, sockets: []net.TCP_Socket) {
	if svc == nil || session_id == "" do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if svc.snapshot_cache == nil do svc.snapshot_cache = make(map[string]^Shell_Snapshot_Cache_Entry, heap)
	e, have := svc.snapshot_cache[session_id]
	if !is_snapshot {
		if have do e.open = false
		return
	}
	if !have || !e.open {
		if have do _snapshot_cache_evict_locked(svc, session_id)
		e = _snapshot_entry_new(heap)
		e.catchup = true
		e.open = true
		svc.snapshot_cache[strings.clone(session_id, heap)] = e
	}
	e.at = time.tick_now()
	_snapshot_entry_append_locked(e, frame, heap)
	for s in sockets {
		seen := false
		for p in e.painted do if p == s { seen = true; break }
		if !seen do append(&e.painted, s)
	}
}

// shell_session_snapshot_cache_store_capture remembers a hub capture (SCREEN frames) that
// was just written to `painted_socket` at cols x rows. Replaces any previous entry.
shell_session_snapshot_cache_store_capture :: proc(svc: ^Shell_Session_Service, session_id: string, frames: [][]byte, cols, rows: int, painted_socket: net.TCP_Socket) {
	if svc == nil || session_id == "" || len(frames) == 0 do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if svc.snapshot_cache == nil do svc.snapshot_cache = make(map[string]^Shell_Snapshot_Cache_Entry, heap)
	_snapshot_cache_evict_locked(svc, session_id)
	e := _snapshot_entry_new(heap)
	e.cols, e.rows = cols, rows
	for f in frames do _snapshot_entry_append_locked(e, f, heap)
	if painted_socket != net.TCP_Socket(0) do append(&e.painted, painted_socket)
	svc.snapshot_cache[strings.clone(session_id, heap)] = e
}

// shell_session_snapshot_cache_decide answers a viewer's first-resize snapshot request.
shell_session_snapshot_cache_decide :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket, cols, rows: int) -> Shell_Snapshot_Decision {
	if svc == nil || session_id == "" do return .Miss
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	e, have := svc.snapshot_cache[session_id]
	if !have || e.oversize || len(e.frames) == 0 do return .Miss
	if e.catchup && e.bytes < SHELL_SNAPSHOT_CACHE_MIN_CATCHUP_BYTES do return .Miss
	for p in e.painted do if p == socket do return .Already_Painted
	fresh := time.tick_since(e.at) < SHELL_SNAPSHOT_CACHE_FRESH
	same_geometry := e.cols == cols && e.rows == rows && cols > 0
	if fresh || same_geometry do return .Serve
	return .Miss
}

// shell_session_snapshot_cache_serve replays the cached frames to ONE socket under the
// session write lock (the same atomicity rule as a chunked capture) and marks it painted.
shell_session_snapshot_cache_serve :: proc(svc: ^Shell_Session_Service, session_id: string, socket: net.TCP_Socket) -> bool {
	if svc == nil || session_id == "" do return false
	heap := runtime.heap_allocator()
	// Copy the frames out under svc.mu; the write lock below must not nest inside it.
	frames: [dynamic][]byte
	frames = make([dynamic][]byte, heap)
	defer { for f in frames do delete(f, heap); delete(frames) }
	sync.mutex_lock(&svc.mu)
	e, have := svc.snapshot_cache[session_id]
	if !have || e.oversize || len(e.frames) == 0 { sync.mutex_unlock(&svc.mu); return false }
	for f in e.frames {
		c := make([]byte, len(f), heap)
		copy(c, f)
		append(&frames, c)
	}
	append(&e.painted, socket)
	sync.mutex_unlock(&svc.mu)

	write_mu := shell_session_viewer_write_lock(svc, session_id)
	if write_mu != nil do sync.mutex_lock(write_mu)
	defer if write_mu != nil { sync.mutex_unlock(write_mu); shell_session_viewer_write_release(svc, session_id) }
	for f in frames {
		if pane_viewer_enqueue(svc, socket, string(f), 0x2) != ws.Text_Write_Result.Ok do return false
	}
	return true
}

// shell_session_snapshot_cache_has reports whether a usable entry exists (tests/diagnostics).
shell_session_snapshot_cache_has :: proc(svc: ^Shell_Session_Service, session_id: string) -> bool {
	if svc == nil do return false
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	e, have := svc.snapshot_cache[session_id]
	return have && !e.oversize && len(e.frames) > 0
}
