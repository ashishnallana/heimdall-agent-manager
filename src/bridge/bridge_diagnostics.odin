package main

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

// bridge_diagnostics sender (minimal heartbeat plan §4.3, T6). Once a connection's
// bridge_ready advertised diagnostics_frame_v1, the diagnostics that used to ride
// every heartbeat travel in their own full snapshot frame:
//
//   {"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_…","sample_seq":N,
//    "collected_at_ms":T,"command_dispatch":{…},"dependency_breakers":{…},
//    "http_retries":{…},"operation_recovery":{"rows":[…]},"stats":{…},
//    "unavailable":[…]}
//
// Only consumed members are written (the legacy heartbeat builders keep theirs).
// `stats` and `unavailable` are present only while resource stats are enabled
// (bridge_ready/set_telemetry heartbeat_stats) and a `ps` sample succeeded; the four
// reliability families are unconditional, as in the legacy heartbeat (decision D4).
//
// Ordering: process_epoch is generated once per Bridge process and kept across
// reconnects; sample_seq starts at 1 and only grows. A runtime restart is a new
// process and therefore a new epoch, which is how the hub tells a counter reset from
// a malformed regression.
//
// Liveness: collection forks `ps` and reads /proc, which can stall. It never runs on
// the hub WS loop. The loop only REQUESTS a snapshot (a flag, never a queue) and
// later sends whichever finished snapshot is waiting; one long-lived collector thread
// does the work. A stalled collection therefore delays only diagnostics: further
// requests coalesce into one, heartbeats keep their cadence, and nothing grows.
//
// Ownership / shutdown: the collector thread is started on first use and lives for
// the process, like the Bridge's other process-lifetime workers; it is never joined
// (process exit ends it). The ready frame is owned by the slot under
// bridge_diagnostics_mutex until bridge_diagnostics_take moves it to the caller, who
// sends and deletes it. A frame replaced before it was sent is freed by the
// replacer; sample_seq stays monotonic because only the collector assigns it.

BRIDGE_DIAGNOSTICS_SCHEMA :: 1

@(private = "file")
bridge_diagnostics_epoch_once: sync.Once
@(private = "file")
bridge_diagnostics_epoch: string
@(private = "file")
bridge_diagnostics_seq: u64

bridge_diagnostics_mutex: sync.Mutex
@(private = "file")
bridge_diagnostics_cond: sync.Cond
@(private = "file")
bridge_diagnostics_requested: bool
@(private = "file")
bridge_diagnostics_ready: string
@(private = "file")
bridge_diagnostics_worker_once: sync.Once

// bridge_diagnostics_sample_stats is the slow part of a snapshot (forks `ps`, reads
// /proc, asks the pty host). A variable so tests can substitute or stall it; tests
// that do hold bridge_diagnostics_test_mutex (bridge_diagnostics_test.odin).
bridge_diagnostics_sample_stats: proc(allocator: runtime.Allocator) -> Heartbeat_Stats = bridge_diagnostics_sample_stats_default

bridge_diagnostics_sample_stats_default :: proc(allocator: runtime.Allocator) -> Heartbeat_Stats {
	return heartbeat_stats_collect(allocator)
}

// bridge_diagnostics_process_epoch is this process's opaque epoch: "pe_" + 16 hex
// digits of start time + 16 random hex digits (printable ASCII, < 64 bytes).
bridge_diagnostics_process_epoch :: proc() -> string {
	sync.once_do(&bridge_diagnostics_epoch_once, proc() {
		bridge_diagnostics_epoch = fmt.aprintf("pe_%016x%016x", u64(time.to_unix_nanoseconds(time.now())), rand.uint64(), allocator = runtime.heap_allocator())
	})
	return bridge_diagnostics_epoch
}

// bridge_diagnostics_snapshot_json collects and serializes one snapshot with the
// next sample_seq. Runs on the collector thread (or directly in tests). The caller
// owns the string.
bridge_diagnostics_snapshot_json :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	// Stats first: the slow part, and the one that is most worth timestamping.
	// The telemetry switch is read per snapshot, so set_telemetry applies from the
	// next one; a failed `ps` omits the family (the hub keeps the previous series).
	stats_b := strings.builder_make(context.temp_allocator)
	unavailable: string
	stats_ok := false
	if bridge_heartbeat_stats_enabled() {
		st := bridge_diagnostics_sample_stats(context.temp_allocator)
		if st.ok {
			unavailable = heartbeat_stats_diagnostics_write(&stats_b, st)
			stats_ok = true
		}
	}
	seq := sync.atomic_add(&bridge_diagnostics_seq, 1) + 1
	fmt.sbprintf(&b, `{{"type":"bridge_diagnostics","schema":%d,"process_epoch":"%s","sample_seq":%d,"collected_at_ms":%d`,
		BRIDGE_DIAGNOSTICS_SCHEMA, bridge_diagnostics_process_epoch(), seq, time.to_unix_nanoseconds(time.now()) / 1_000_000)
	strings.write_string(&b, `,"command_dispatch":`)
	bridge_command_dispatch_diagnostics_write(&b)
	strings.write_string(&b, `,"dependency_breakers":`)
	bridge_dependency_breaker_diagnostics_write(&b)
	strings.write_string(&b, `,"http_retries":`)
	bridge_http_retry_diagnostics_write(&b)
	strings.write_string(&b, `,"operation_recovery":`)
	bridge_recovery_diagnostics_write(&b)
	if stats_ok {
		strings.write_string(&b, `,"stats":`)
		strings.write_string(&b, strings.to_string(stats_b))
		if unavailable != "" {
			strings.write_string(&b, `,"unavailable":`)
			strings.write_string(&b, unavailable)
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// bridge_diagnostics_request asks the collector for a fresh snapshot. Never blocks
// on collection: a request while one is pending or running coalesces.
bridge_diagnostics_request :: proc() {
	sync.once_do(&bridge_diagnostics_worker_once, proc() {
		// Process-lifetime thread: never owned by a caller's (e.g. a test's)
		// allocator, and it runs on a fresh default context (below).
		context.allocator = runtime.heap_allocator()
		thread.create_and_start(bridge_diagnostics_worker, runtime.default_context())
	})
	sync.mutex_lock(&bridge_diagnostics_mutex)
	bridge_diagnostics_requested = true
	sync.mutex_unlock(&bridge_diagnostics_mutex)
	sync.cond_signal(&bridge_diagnostics_cond)
}

// bridge_diagnostics_take moves the finished snapshot (if any) to the caller, who
// releases it with bridge_diagnostics_frame_free.
bridge_diagnostics_take :: proc() -> (frame: string, ok: bool) {
	sync.mutex_lock(&bridge_diagnostics_mutex)
	defer sync.mutex_unlock(&bridge_diagnostics_mutex)
	if bridge_diagnostics_ready == "" do return "", false
	frame = bridge_diagnostics_ready
	bridge_diagnostics_ready = ""
	return frame, true
}

// bridge_diagnostics_frame_free releases a frame from bridge_diagnostics_take. Slot
// frames always live on the heap allocator, whichever thread frees them.
bridge_diagnostics_frame_free :: proc(frame: string) {
	delete(frame, runtime.heap_allocator())
}

// bridge_diagnostics_discard drops a finished snapshot nobody will send (the
// connection that requested it went away without the flag on the next one).
bridge_diagnostics_discard :: proc() {
	if frame, ok := bridge_diagnostics_take(); ok do bridge_diagnostics_frame_free(frame)
}

@(private = "file")
bridge_diagnostics_worker :: proc() {
	// Own context: the thread-local temp arena it frees after every snapshot must be
	// this thread's, never the creating thread's.
	context = runtime.default_context()
	for {
		sync.mutex_lock(&bridge_diagnostics_mutex)
		for !bridge_diagnostics_requested do sync.cond_wait(&bridge_diagnostics_cond, &bridge_diagnostics_mutex)
		bridge_diagnostics_requested = false
		sync.mutex_unlock(&bridge_diagnostics_mutex)

		frame := bridge_diagnostics_snapshot_json(runtime.heap_allocator())
		free_all(context.temp_allocator)

		sync.mutex_lock(&bridge_diagnostics_mutex)
		if bridge_diagnostics_ready != "" do bridge_diagnostics_frame_free(bridge_diagnostics_ready)
		bridge_diagnostics_ready = frame
		sync.mutex_unlock(&bridge_diagnostics_mutex)
	}
}

// bridge_diagnostics_negotiated reports whether this connection may send the frame.
bridge_diagnostics_negotiated :: proc() -> bool {
	return BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE && sync.atomic_load(&bridge_hub_diagnostics_frame_v1)
}

// Bridge_Diagnostics_Cadence is the per-connection diagnostics timer, independent of
// the heartbeat's anchor so diagnostics can never move a beat.
Bridge_Diagnostics_Cadence :: struct {
	last_request_ns: i64,
}

// bridge_diagnostics_connect requests the connect-time snapshot right after
// bridge_ready (when negotiated) and anchors the periodic cadence there. A leftover
// snapshot from a previous connection is still sent: it is a valid, ordered sample.
bridge_diagnostics_connect :: proc(cadence: ^Bridge_Diagnostics_Cadence, now_ns: i64) {
	cadence.last_request_ns = now_ns
	if !bridge_diagnostics_negotiated() {
		bridge_diagnostics_discard()
		return
	}
	bridge_diagnostics_request()
}

// bridge_diagnostics_tick runs once per hub loop iteration: it requests a snapshot
// every heartbeat interval and sends a finished one. It never collects.
bridge_diagnostics_tick :: proc(conn: ^ws.Connection, cadence: ^Bridge_Diagnostics_Cadence, now_ns, interval_ns: i64) {
	if !bridge_diagnostics_negotiated() do return
	if bridge_hub_heartbeat_due(&cadence.last_request_ns, now_ns, interval_ns) do bridge_diagnostics_request()
	if frame, ok := bridge_diagnostics_take(); ok {
		_ = ws.send_text(conn, frame)
		bridge_diagnostics_frame_free(frame)
	}
}
