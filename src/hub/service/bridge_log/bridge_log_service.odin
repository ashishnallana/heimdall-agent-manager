package bridge_log

// Bridge error-event writer (bridge_logs plan v2 §4.2).
//
// The bridge-ws reader threads only validate a bridge_log frame and hand the
// accepted, heap-cloned entries to `enqueue`. ONE background thread drains the
// bounded queue every FLUSH_INTERVAL (or as soon as FLUSH_THRESHOLD entries are
// pending) into one multi-row INSERT per batch, enforces the per-bridge row cap
// for the bridges that batch touched, and — when a push sink is installed
// (L3, --log-push-url) — forwards the same batch to the log backend. SQLite is
// never touched from a reader thread: the hub shares one sqlite3* with a
// rollback journal, and 300 reconnecting bridges each doing their own fsync'd
// insert would stall command results.
//
// Ownership: an event accepted by `enqueue` (returns true) belongs to the
// service, which frees it after the flush. On `false` (queue full) the caller
// still owns it and counts heimdall_bridge_log_queue_dropped_total.

import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

QUEUE_CAPACITY :: 8192
FLUSH_INTERVAL :: 1 * time.Second
FLUSH_THRESHOLD :: 512
PER_BRIDGE_CAP :: 500
RETENTION :: 7 * 24 * time.Hour
PRUNE_INTERVAL :: 15 * time.Minute

// Push_Sink receives every batch AFTER it was committed to SQLite. It runs on
// the writer thread and must bound its own time (the L3 HTTP sink uses a 2 s
// deadline and at most one retry).
Push_Sink :: proc(ctx: rawptr, events: []domain.Bridge_Log_Event)

Service :: struct {
	repo:           ^iface.Bridge_Log_Repository,
	mu:             sync.Mutex,
	cond:           sync.Cond,
	queue:          [dynamic]domain.Bridge_Log_Event, // mu
	stop_requested: bool, // mu
	worker:         ^thread.Thread,
	push_sink:      Push_Sink,
	push_ctx:       rawptr,
	// Reaper prune bookkeeping (unix ms); 0 = prune on the first sweep.
	next_prune_ms:  i64,
	per_bridge_cap: int,
	capacity:       int,
}

Flush_Stats :: struct {
	taken:    int,
	inserted: int,
	capped:   int,
	ok:       bool,
}

new_service :: proc(repo: ^iface.Bridge_Log_Repository) -> Service {
	return Service{repo = repo, per_bridge_cap = PER_BRIDGE_CAP, capacity = QUEUE_CAPACITY, queue = make([dynamic]domain.Bridge_Log_Event)}
}

service_free :: proc(svc: ^Service) {
	if svc == nil do return
	stop(svc)
	sync.lock(&svc.mu)
	for &e in svc.queue do domain.bridge_log_event_destroy(&e)
	delete(svc.queue)
	svc.queue = nil
	sync.unlock(&svc.mu)
}

set_push_sink :: proc(svc: ^Service, sink: Push_Sink, ctx: rawptr) {
	svc.push_sink = sink
	svc.push_ctx = ctx
}

// enqueue hands one validated event to the writer. False = queue full; the
// caller keeps ownership.
enqueue :: proc(svc: ^Service, event: domain.Bridge_Log_Event) -> bool {
	if svc == nil do return false
	sync.lock(&svc.mu)
	defer sync.unlock(&svc.mu)
	cap := svc.capacity if svc.capacity > 0 else QUEUE_CAPACITY
	if len(svc.queue) >= cap do return false
	append(&svc.queue, event)
	if len(svc.queue) >= FLUSH_THRESHOLD do sync.cond_signal(&svc.cond)
	return true
}

pending :: proc(svc: ^Service) -> int {
	if svc == nil do return 0
	sync.lock(&svc.mu)
	defer sync.unlock(&svc.mu)
	return len(svc.queue)
}

// flush_once drains everything queued right now into SQLite (one multi-row
// INSERT per 256 rows), caps the touched bridges, forwards to the push sink and
// frees the events. Safe to call from tests without the thread.
flush_once :: proc(svc: ^Service) -> (st: Flush_Stats) {
	if svc == nil do return
	sync.lock(&svc.mu)
	if len(svc.queue) == 0 {
		sync.unlock(&svc.mu)
		st.ok = true
		return
	}
	batch := svc.queue
	svc.queue = make([dynamic]domain.Bridge_Log_Event)
	sync.unlock(&svc.mu)
	defer {
		for &e in batch do domain.bridge_log_event_destroy(&e)
		delete(batch)
	}
	st.taken = len(batch)
	n, err := iface.bridge_log_insert_batch(svc.repo, batch[:])
	st.inserted = n
	if err.code != .None do return
	metrics.counter_add(project_service.fleet_metrics.bridge_log_rows_written, u64(n))

	// Per-bridge cap, amortised: only the bridges in this batch, each once.
	touched := make([dynamic]string, context.temp_allocator)
	outer: for e in batch {
		for t in touched do if t == e.bridge_id do continue outer
		append(&touched, e.bridge_id)
	}
	keep := svc.per_bridge_cap if svc.per_bridge_cap > 0 else PER_BRIDGE_CAP
	for bridge_id in touched {
		if removed, cap_err := iface.bridge_log_cap_bridge(svc.repo, bridge_id, keep); cap_err.code == .None do st.capped += removed
	}
	if svc.push_sink != nil do svc.push_sink(svc.push_ctx, batch[:])
	st.ok = true
	return
}

// maybe_prune runs the 7-day time prune at most once per PRUNE_INTERVAL. The
// reaper's 20 s sweep calls this; the first call after start prunes.
maybe_prune :: proc(svc: ^Service, now_ms: i64) -> (pruned: int, ran: bool) {
	if svc == nil || svc.repo == nil do return 0, false
	if svc.next_prune_ms != 0 && now_ms < svc.next_prune_ms do return 0, false
	svc.next_prune_ms = now_ms + i64(PRUNE_INTERVAL / time.Millisecond)
	n, err := iface.bridge_log_prune_before(svc.repo, now_ms - i64(RETENTION / time.Millisecond))
	if err.code != .None do return 0, true
	return n, true
}

// purge_bridge removes every stored event of a bridge (owner DELETE, revoke).
// Queued-but-unwritten events for that bridge are dropped too, so a purge is
// not undone a second later by the writer.
purge_bridge :: proc(svc: ^Service, bridge_id: string) -> (int, domain.Domain_Error) {
	if svc == nil do return 0, domain.domain_error(.Internal_Error, "bridge log service is not configured")
	sync.lock(&svc.mu)
	i := 0
	for i < len(svc.queue) {
		if svc.queue[i].bridge_id == bridge_id {
			domain.bridge_log_event_destroy(&svc.queue[i])
			ordered_remove(&svc.queue, i)
		} else {
			i += 1
		}
	}
	sync.unlock(&svc.mu)
	return iface.bridge_log_delete_by_bridge(svc.repo, bridge_id)
}

list :: proc(svc: ^Service, bridge_id: string, limit: int, before_id: i64) -> ([]domain.Bridge_Log_Event, domain.Domain_Error) {
	if svc == nil do return nil, domain.domain_error(.Internal_Error, "bridge log service is not configured")
	return iface.bridge_log_list_by_bridge(svc.repo, bridge_id, limit, before_id)
}

// ---- writer thread ----------------------------------------------------------

// start launches the writer. The thread inherits the CALLER's context (with a
// thread-local temp allocator), so the allocator that frees drained events is
// the allocator the hub allocated them with — the process-wide heap in the
// app, the per-test tracking allocator under `odin test` (where a bare heap
// `free` of a tracked pointer is a crash on the writer thread).
start :: proc(svc: ^Service) {
	if svc == nil || svc.worker != nil do return
	svc.stop_requested = false
	// thread-spawn: startup (caller's allocator is the process heap)
	svc.worker = thread.create_and_start_with_data(rawptr(svc), writer_entry, init_context = context)
}

stop :: proc(svc: ^Service) {
	if svc == nil || svc.worker == nil do return
	sync.lock(&svc.mu)
	svc.stop_requested = true
	sync.cond_broadcast(&svc.cond)
	sync.unlock(&svc.mu)
	thread.join(svc.worker)
	thread.destroy(svc.worker)
	svc.worker = nil
	// Final drain so nothing accepted before shutdown is lost.
	_ = flush_once(svc)
}

@(private = "file")
writer_entry :: proc(data: rawptr) {
	svc := (^Service)(data)
	for {
		sync.lock(&svc.mu)
		if !svc.stop_requested && len(svc.queue) < FLUSH_THRESHOLD {
			_ = sync.cond_wait_with_timeout(&svc.cond, &svc.mu, FLUSH_INTERVAL)
		}
		stopping := svc.stop_requested
		sync.unlock(&svc.mu)
		if stopping do return
		_ = flush_once(svc)
		free_all(context.temp_allocator)
	}
}
