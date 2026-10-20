package http

import "core:fmt"
import "core:sync"
import "core:time"

// REQ-SHELL-41: BRIDGE CONNECTION LIFECYCLE OBSERVABILITY.
//
// WHY THIS FILE EXISTS. Before it, the hub emitted NOTHING about a bridge command
// socket connecting or going away: bridge_ws_upgrade_handler logged only kill-replay
// shortfalls, bridge_ws_disconnect had no print at all, and the runtime loop's
// `if !ok do return` was silent. So "did this bridge reconnect, when, and why" was
// unanswerable from the logs, which is exactly the step REQ-SHELL-32 could not confirm
// and had to ship as "source-derived, not observed".
//
// CONNECTION LIFECYCLE ONLY — NEVER PER-FRAME. The bridge command socket carries PTY
// output frames at roughly 11KB on a 25ms cadence; a log line per frame would itself be
// a defect (and is forbidden by this task's AC3). Everything here fires at most twice
// per TCP connection: once on connect, once on teardown.

// Bridge_WS_Disconnect_Reason names WHY a bridge command-socket connection ended.
//
// THIS TYPE EXISTS BECAUSE THE REASON USED TO BE DESTROYED BEFORE ANY CALLER COULD SEE
// IT. read_ws_text_blocking returned a bare `bool`, and three genuinely different
// outcomes — a fatal/desynced frame, a read-deadline expiry, and a clean peer close —
// all collapsed into the same `false`. No amount of logging at the teardown site could
// have told them apart, so the reason had to be plumbed out of the reader first.
Bridge_WS_Disconnect_Reason :: enum {
	// Not a teardown: the read produced a frame.
	None,
	// The peer sent a WS close frame (opcode 0x8), or the TCP stream reached a
	// graceful FIN (recv returned `0, nil`). An orderly shutdown either way.
	Clean_Close,
	// No frame arrived within the read deadline (120s on the runtime loop, 3s on the
	// hello). The bridge's idle heartbeat cadence is 45s, so this means roughly two
	// missed beats, not a merely slow bridge.
	Read_Deadline,
	// READER DESYNC. An unexpected non-text opcode, or a 64-bit (127) payload length,
	// which this control channel never legitimately uses. The stream cannot be
	// resynchronised, so the connection ends. This is the case that REQ-SHELL-32
	// needed to observe and could not.
	Fatal_Frame,
	// A socket-level receive error that is not a deadline and not a clean close
	// (ECONNRESET and friends).
	Recv_Error,
	// A NEWER connection for this same bridge took over while this one was still in
	// its read loop; this one is being retired in favour of it. Distinguished because
	// it is normal during a bridge restart and alarming at any other time.
	Connection_Replaced,
	// The frame was read and parsed but its application-level dispatch refused it and
	// asked for teardown.
	Frame_Rejected,
	// A write to the command socket failed, so the connection is torn down from the
	// write side rather than the read side.
	//
	// UNREACHABLE TODAY, AND DELIBERATELY KEPT AS A NAMED GAP. This task's description
	// asked for a write-failure/send-deadline reason as one of four cases "that already
	// exist in code as distinct outcomes". It does not: EVERY write to the bridge
	// command socket discards its result (`_ = write_ws_text_frame_locked(...)` at
	// bridge_handlers.odin:1204, :1564, :1655 and :1692), so no write failure has ever
	// torn down a bridge connection and nothing can currently set this reason. Making
	// one do so is a BEHAVIOUR change — a transient write failure would start killing
	// bridge connections — not an observability one, so it is out of this task's scope.
	//
	// It is kept rather than deleted so the gap is visible in the type itself. It must
	// NOT be wired to anything that merely *looks* like a write failure: a reason that
	// can never fire, read as "no writes were abandoned", is precisely the
	// always-zero-counter trap that ws.send_timeouts() set for this chain.
	Write_Failed,
}

// bridge_ws_reason_string maps a reason to a stable, greppable token. Returns a STRING
// LITERAL in every arm — no allocation, which matters because these are logged from
// bridge_ws_runtime_loop, a persistent background loop on the heap rather than a
// per-request arena (AC4).
bridge_ws_reason_string :: proc(reason: Bridge_WS_Disconnect_Reason) -> string {
	switch reason {
	case .None:                return "none"
	case .Clean_Close:         return "clean_close"
	case .Read_Deadline:       return "read_deadline"
	case .Fatal_Frame:         return "fatal_frame_desync"
	case .Recv_Error:          return "recv_error"
	case .Connection_Replaced: return "connection_replaced"
	case .Frame_Rejected:      return "frame_rejected"
	case .Write_Failed:        return "write_failed"
	}
	return "unknown"
}

// ---------------------------------------------------------------------------
// AC5: a reconnect storm must not be able to fill the disk.
// ---------------------------------------------------------------------------
//
// MECHANISM: a per-bridge rolling window that logs the first
// BRIDGE_WS_LOG_BURST connect/disconnect PAIRS in any BRIDGE_WS_LOG_WINDOW and then
// goes quiet, counting what it suppressed. The next event after the window rolls over
// reports the suppressed total, so a flapping bridge costs a bounded handful of lines
// per minute and the flapping is still VISIBLE (you see "suppressed=N") rather than
// silently dropped — the whole point of this task is not to trade one blind spot for
// another.
//
// NO ALLOCATION ANYWHERE IN THIS TABLE, BY CONSTRUCTION (AC4). It is a fixed array of
// slots, and each slot stores the bridge id in an inline byte buffer rather than a
// cloned string. A map keyed by a cloned bridge_id would have been the idiomatic
// choice, and would also have been a permanent leak on a persistent background loop:
// this codebase has a documented history of exactly that (a [dynamic] global binding
// context.allocator in a background loop). A fixed table cannot leak because it never
// owns heap memory.
BRIDGE_WS_LOG_WINDOW :: 60 * time.Second
BRIDGE_WS_LOG_BURST :: 5
// Slots are reclaimed by age, so this bounds only how many bridges can be tracked
// CONCURRENTLY within one window, not how many may ever connect.
BRIDGE_WS_LOG_SLOTS :: 32
// Bridge ids are `brg_` + 16 hex digits today; 64 bytes is generous headroom. An id
// longer than this is truncated for KEYING ONLY (never in the logged output), which
// can at worst make two absurdly-long ids share a rate-limit budget.
BRIDGE_WS_LOG_ID_MAX :: 64

Bridge_WS_Log_Slot :: struct {
	id:              [BRIDGE_WS_LOG_ID_MAX]byte,
	id_len:          int,
	window_start_ns: i64,
	logged:          int,
	suppressed:      int,
}

Bridge_WS_Log_Limiter :: struct {
	mu:    sync.Mutex,
	slots: [BRIDGE_WS_LOG_SLOTS]Bridge_WS_Log_Slot,
}

// bridge_ws_log_limiter is process-wide rather than per-Bridge_Handlers so that the
// budget follows the BRIDGE, which is what floods, and so that adding this needed no
// change to Bridge_Handlers' many construction sites. It is zero-value usable: a
// sync.Mutex and a fixed array both need no initialisation, so there is nothing to
// make and nothing to free.
bridge_ws_log_limiter: Bridge_WS_Log_Limiter

// bridge_ws_log_admit_in is the same decision taken against an EXPLICIT limiter.
// Production always goes through the wrapper above and therefore always uses the
// process-wide global; the limiter is a parameter here purely so that a TEST can own a
// private one.
//
// WHY THIS EXISTS (REQ-SHELL-59). Three asserting tests and five demos used to clear the
// single global table with a bare `bridge_ws_log_limiter.slots = {}` — a whole-struct
// assignment taking NO lock, racing this proc, which holds one for its entire body. At
// ODIN_TEST_THREADS=1 that is harmless because nothing runs concurrently, and the package
// was green. At THREADS>1 one test's clear lands mid-loop inside another's, its slot
// vanishes, the next admit allocates a fresh slot with logged = 1, and the budget
// restarts. The signature is that `allowed` comes back as an exact multiple of
// BRIDGE_WS_LOG_BURST — 10 and 15 were both observed against an expected 5, i.e. one and
// two interfering clears. Giving each test a private limiter removes the sharing outright,
// which is the only fix that also removes the data race; merely ordering the writes would
// leave a torn read of a half-cleared slot possible.
bridge_ws_log_admit_in :: proc(
	lim: ^Bridge_WS_Log_Limiter,
	bridge_id: string,
	now_ns: i64,
) -> (allow: bool, suppressed: int) {
	sync.mutex_lock(&lim.mu)
	defer sync.mutex_unlock(&lim.mu)

	key_len := min(len(bridge_id), BRIDGE_WS_LOG_ID_MAX)
	window := i64(BRIDGE_WS_LOG_WINDOW)

	// Prefer an exact match; otherwise take a free slot, and failing that evict the
	// slot whose window is oldest (it is the least likely to still be flapping).
	free_idx := -1
	oldest_idx := 0
	for i in 0 ..< BRIDGE_WS_LOG_SLOTS {
		s := &lim.slots[i]
		if s.id_len == key_len && string(s.id[:s.id_len]) == bridge_id[:key_len] {
			if now_ns - s.window_start_ns >= window {
				// Window rolled over: reset the budget and hand back whatever the
				// previous window swallowed so the caller can name it.
				carried := s.suppressed
				s.window_start_ns = now_ns
				s.logged = 1
				s.suppressed = 0
				return true, carried
			}
			if s.logged < BRIDGE_WS_LOG_BURST {
				s.logged += 1
				return true, 0
			}
			s.suppressed += 1
			return false, 0
		}
		if s.id_len == 0 && free_idx < 0 do free_idx = i
		if s.window_start_ns < lim.slots[oldest_idx].window_start_ns do oldest_idx = i
	}

	idx := free_idx if free_idx >= 0 else oldest_idx
	s := &lim.slots[idx]
	copy(s.id[:], bridge_id[:key_len])
	s.id_len = key_len
	s.window_start_ns = now_ns
	s.logged = 1
	s.suppressed = 0
	return true, 0
}

// bridge_ws_log_connect records a bridge command socket coming up.
//
// `replaced` is `hello.replaced_existing`, which the hub ALREADY computed and shipped
// to the bridge in bridge_ready_payload and then threw away — this task's AC2 asks for
// precisely that fact, so it is now logged rather than discarded.
//
// NOTE ON remote: behind the edge proxy this is the PROXY's address, not the bridge
// host's. It is still worth logging (it distinguishes a direct connection from a
// proxied one, and separates proxy instances), but do not read it as the bridge's IP.
bridge_ws_log_connect :: proc(bridge_id: string, remote: string, generation: int, replaced: bool) {
	bridge_ws_log_connect_in(&bridge_ws_log_limiter, bridge_id, remote, generation, replaced)
}

// As bridge_ws_log_connect, but against an explicit limiter. See bridge_ws_log_admit_in
// for why a test needs this.
bridge_ws_log_connect_in :: proc(
	lim: ^Bridge_WS_Log_Limiter,
	bridge_id: string,
	remote: string,
	generation: int,
	replaced: bool,
) {
	allow, suppressed := bridge_ws_log_admit_in(lim, bridge_id, time.now()._nsec)
	if !allow do return
	// fmt.println with pre-existing strings and ints only: no intermediate string is
	// built, so there is nothing to free on this path (AC4).
	if suppressed > 0 {
		fmt.println(
			"bridge ws connect", "bridge=", bridge_id, "remote=", remote,
			"generation=", generation, "replaced_existing=", replaced,
			"suppressed_since_last=", suppressed)
		return
	}
	fmt.println(
		"bridge ws connect", "bridge=", bridge_id, "remote=", remote,
		"generation=", generation, "replaced_existing=", replaced)
}

// bridge_ws_log_disconnect records a bridge command socket going away, with the reason
// and how long the connection lasted.
//
// `duration_ms` is derived from a connect timestamp captured in the upgrade handler, so
// it measures the WS connection's life, not the process's.
bridge_ws_log_disconnect :: proc(
	bridge_id: string,
	reason: Bridge_WS_Disconnect_Reason,
	generation: int,
	duration_ms: i64,
	still_current: bool,
) {
	bridge_ws_log_disconnect_in(
		&bridge_ws_log_limiter, bridge_id, reason, generation, duration_ms, still_current)
}

// As bridge_ws_log_disconnect, but against an explicit limiter. See
// bridge_ws_log_admit_in for why a test needs this.
bridge_ws_log_disconnect_in :: proc(
	lim: ^Bridge_WS_Log_Limiter,
	bridge_id: string,
	reason: Bridge_WS_Disconnect_Reason,
	generation: int,
	duration_ms: i64,
	still_current: bool,
) {
	allow, suppressed := bridge_ws_log_admit_in(lim, bridge_id, time.now()._nsec)
	if !allow do return
	// still_current=false means a newer connection already replaced this one, so the
	// durable offline cascade was SKIPPED. Logged because "the bridge disconnected"
	// and "the bridge disconnected and its instances were marked unreachable" are
	// different events, and confusing them has cost this chain time before.
	if suppressed > 0 {
		fmt.println(
			"bridge ws disconnect", "bridge=", bridge_id,
			"reason=", bridge_ws_reason_string(reason),
			"generation=", generation, "duration_ms=", duration_ms,
			"cascaded=", still_current, "suppressed_since_last=", suppressed)
		return
	}
	fmt.println(
		"bridge ws disconnect", "bridge=", bridge_id,
		"reason=", bridge_ws_reason_string(reason),
		"generation=", generation, "duration_ms=", duration_ms,
		"cascaded=", still_current)
}
