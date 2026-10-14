package shell_session

// Shell telemetry (hub telemetry plan 3.5).
//
//   heimdall_shell_sessions{bridge_id,state}      collector, DB-backed, cached 60 s
//   heimdall_shell_viewers{bridge_id}             collector, in-memory viewer registry
//   heimdall_shell_output_bytes_total{bridge_id}  pty output arriving from the bridge
//   heimdall_shell_fanout_bytes_total             bytes written to viewers (fleet)
//   heimdall_shell_input_bytes_total              keystrokes forwarded to bridges (fleet)
//   heimdall_shell_viewer_detaches_total{reason}  Shell_Viewer_Detach_Reason
//   heimdall_shell_first_frame_latency_seconds    attach -> first frame on the wire
//
// Label discipline: per-bridge series carry ONLY bridge_id; `state` and `reason`
// come from fixed mappers (unknown -> "other"). Never a session id.
//
// Allocator discipline: everything the collector keeps between scrapes is
// allocated with the registry allocator, never context.allocator — the hot paths
// that call into here run on per-request arenas and pane writer threads.

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"

Shell_Metrics :: struct {
	output_bytes:        ^metrics.Family, // {bridge_id}
	fanout_bytes:        ^metrics.Series,
	input_bytes:         ^metrics.Series,
	viewer_detaches:     ^metrics.Family, // {reason}
	first_frame_latency: ^metrics.Series,
}

shell_metrics: Shell_Metrics

FIRST_FRAME_BUCKETS := [?]f64{0.05, 0.1, 0.25, 0.5, 1, 2, 5}

// SHELL_SESSIONS_CACHE_TTL bounds how often a scrape may hit the shell_sessions
// table (plan 3.8: DB-backed collectors are cached 60 s).
SHELL_SESSIONS_CACHE_TTL :: 60 * time.Second

// SHELL_SESSIONS_COLLECT_MAX_BRIDGES caps the per-scrape row set, mirroring the
// reaper's REAPER_LIVE_BRIDGE_IDS_MAX intent: a runaway backstop, not pagination.
SHELL_SESSIONS_COLLECT_MAX_BRIDGES :: 1024
SHELL_SESSIONS_COLLECT_MAX_ROWS :: 1024

// The collector reads the live service through this pointer, NOT a captured ctx:
// tests build and destroy many services per process, and a collector holding a
// pointer into a freed service would be a use-after-free at scrape time.
@(private = "file")
collected_service: ^Shell_Session_Service
@(private = "file")
collector_registered: bool

@(private = "file")
Shell_Session_Count :: struct {
	bridge_id: string, // registry allocator
	state:     string, // literal from shell_session_state_enum
	count:     int,
}

@(private = "file")
Shell_Sessions_Cache :: struct {
	mu:         sync.Mutex,
	have:       bool,
	fetched_at: time.Tick,
	counts:     [dynamic]Shell_Session_Count,
	for_svc:    ^Shell_Session_Service,
}

@(private = "file")
shell_sessions_cache: Shell_Sessions_Cache

// shell_metrics_set_service points the scrape collector at the live service
// (build_graph) or detaches it (shutdown_graph).
shell_metrics_set_service :: proc(svc: ^Shell_Session_Service) {
	sync.atomic_store(&collected_service, svc)
}

shell_metrics_detach_service :: proc(svc: ^Shell_Session_Service) {
	_, _ = sync.atomic_compare_exchange_strong(&collected_service, svc, nil)
}

shell_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	m := &shell_metrics
	m.output_bytes = metrics.new_counter(reg, "heimdall_shell_output_bytes_total", "PTY output payload bytes (base64 as carried on the wire) received from each bridge.", {"bridge_id"})
	m.fanout_bytes = metrics.with(metrics.new_counter(reg, "heimdall_shell_fanout_bytes_total", "Frame bytes written to shell/agent pane viewers (fleet-wide)."))
	m.input_bytes = metrics.with(metrics.new_counter(reg, "heimdall_shell_input_bytes_total", "Shell input payload bytes forwarded to bridges (fleet-wide)."))
	m.viewer_detaches = metrics.new_counter(reg, "heimdall_shell_viewer_detaches_total", "Pane viewers removed from a session's fan-out, by reason.", {"reason"})
	m.first_frame_latency = metrics.with(metrics.new_histogram_seconds(reg, "heimdall_shell_first_frame_latency_seconds", "Time from a session's 0->1 viewer attach to the first data frame reaching the wire.", {}, FIRST_FRAME_BUCKETS[:]))
	// Pre-create the detach reasons so dashboards see zeros from the first scrape.
	for r in ([]Shell_Viewer_Detach_Reason{.Unspecified, .Stream_Closed, .Peer_Gone, .Desynchronised}) {
		metrics.with(m.viewer_detaches, shell_viewer_detach_reason_string(r))
	}
	if !collector_registered {
		collector_registered = true
		metrics.registry_add_collector(reg, nil, shell_metrics_collect)
	}
}

// ---------------------------------------------------------------------------
// Hot-path helpers. All nil-safe (families stay nil when metrics are off).

shell_metrics_note_output :: proc(bridge_id: string, n: int) {
	if bridge_id == "" || n <= 0 do return
	metrics.counter_add(metrics.with(shell_metrics.output_bytes, bridge_id), u64(n))
}

// shell_metrics_note_output_for_session resolves the bridge for a session when the
// caller has none, reading session_bridges under svc.mu so the id cannot be freed
// underneath the clone metrics.with performs.
shell_metrics_note_output_for_session :: proc(svc: ^Shell_Session_Service, session_id, source_bridge_id: string, n: int) {
	if n <= 0 do return
	if source_bridge_id != "" {
		shell_metrics_note_output(source_bridge_id, n)
		return
	}
	if svc == nil do return
	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	if b, ok := svc.session_bridges[session_id]; ok do shell_metrics_note_output(b, n)
}

shell_metrics_note_fanout :: proc(n: int) {
	if n <= 0 do return
	metrics.counter_add(shell_metrics.fanout_bytes, u64(n))
}

shell_metrics_note_input :: proc(n: int) {
	if n <= 0 do return
	metrics.counter_add(shell_metrics.input_bytes, u64(n))
}

shell_metrics_note_detach :: proc(reason: Shell_Viewer_Detach_Reason) {
	metrics.counter_inc(metrics.with(shell_metrics.viewer_detaches, shell_viewer_detach_reason_string(reason)))
}

shell_metrics_note_first_frame :: proc(latency: time.Duration) {
	metrics.observe_duration(shell_metrics.first_frame_latency, latency)
}

// ws_write_reason_string maps a frame write result onto the fixed
// heimdall_ws_write_errors_total{reason} vocabulary. Ok is never a reason.
ws_write_reason_string :: proc(res: ws.Text_Write_Result) -> string {
	switch res {
	case .Ok:             return "other"
	case .Too_Large:      return "too_large"
	case .Peer_Gone:      return "peer_gone"
	case .Desynchronised: return "desync"
	}
	return "other"
}

// shell_session_state_enum buckets a persisted session status into the fixed
// `state` label set.
shell_session_state_enum :: proc(status: string) -> string {
	switch status {
	case domain.Shell_Session_Status_Starting: return domain.Shell_Session_Status_Starting
	case domain.Shell_Session_Status_Running:  return domain.Shell_Session_Status_Running
	case domain.Shell_Session_Status_Exited:   return domain.Shell_Session_Status_Exited
	case domain.Shell_Session_Status_Killed:   return domain.Shell_Session_Status_Killed
	case domain.Shell_Session_Status_Failed:   return domain.Shell_Session_Status_Failed
	}
	return "other"
}

// ---------------------------------------------------------------------------
// Scrape-time collector.

@(private = "file")
Viewer_Count :: struct {
	bridge_id: string,
	count:     int,
}

shell_metrics_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	svc := sync.atomic_load(&collected_service)
	if svc == nil do return
	a := metrics.global().allocator

	// --- shell_viewers{bridge_id}: snapshot under svc.mu, format outside it.
	viewers := make([dynamic]Viewer_Count, a)
	defer {
		for v in viewers do delete(v.bridge_id, a)
		delete(viewers)
	}
	sync.mutex_lock(&svc.mu)
	for _, w in svc.viewer_writers {
		if w == nil do continue
		found := false
		for &v in viewers {
			if v.bridge_id == w.bridge_id { v.count += 1; found = true; break }
		}
		if !found do append(&viewers, Viewer_Count{bridge_id = strings.clone(w.bridge_id, a), count = 1})
	}
	sync.mutex_unlock(&svc.mu)

	if len(viewers) > 0 {
		metrics.expo_header(e, "heimdall_shell_viewers", "Attached pane viewers per bridge.", .Gauge)
		for v in viewers {
			metrics.expo_sample_i64(e, "heimdall_shell_viewers", {"bridge_id"}, {v.bridge_id}, i64(v.count))
		}
	}

	// --- shell_sessions{bridge_id,state}: DB-backed, refreshed at most every TTL.
	c := &shell_sessions_cache
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	stale := !c.have || c.for_svc != svc || time.tick_since(c.fetched_at) >= SHELL_SESSIONS_CACHE_TTL
	if stale do shell_sessions_cache_refresh_locked(c, svc, a)
	if len(c.counts) > 0 {
		metrics.expo_header(e, "heimdall_shell_sessions", "Live shell sessions per bridge and state (populated combinations only).", .Gauge)
		for sc in c.counts {
			metrics.expo_sample_i64(e, "heimdall_shell_sessions", {"bridge_id", "state"}, {sc.bridge_id, sc.state}, i64(sc.count))
		}
	}
}

@(private = "file")
shell_sessions_cache_clear_locked :: proc(c: ^Shell_Sessions_Cache, a: mem.Allocator) {
	for sc in c.counts do delete(sc.bridge_id, a)
	if c.counts != nil do clear(&c.counts)
}

@(private = "file")
shell_sessions_cache_refresh_locked :: proc(c: ^Shell_Sessions_Cache, svc: ^Shell_Session_Service, a: mem.Allocator) {
	if c.counts == nil do c.counts = make([dynamic]Shell_Session_Count, a)
	shell_sessions_cache_clear_locked(c, a)
	c.have = true
	c.for_svc = svc
	c.fetched_at = time.tick_now()
	repo := svc.repo
	if repo == nil || repo.list_live_bridge_ids == nil || repo.list_live_by_bridge == nil do return

	ids, ids_err := iface.shell_session_list_live_bridge_ids(repo, SHELL_SESSIONS_COLLECT_MAX_BRIDGES)
	defer {
		for id in ids do delete(id)
		delete(ids)
	}
	if ids_err.code != .None do return
	for id in ids {
		rows, err := iface.shell_session_list_live_by_bridge(repo, id, SHELL_SESSIONS_COLLECT_MAX_ROWS)
		if err.code != .None {
			domain.shell_sessions_destroy(rows)
			continue
		}
		for s in rows {
			state := shell_session_state_enum(s.status)
			found := false
			for &sc in c.counts {
				if sc.bridge_id == id && sc.state == state { sc.count += 1; found = true; break }
			}
			if !found do append(&c.counts, Shell_Session_Count{bridge_id = strings.clone(id, a), state = state, count = 1})
		}
		domain.shell_sessions_destroy(rows)
	}
}

// shell_metrics_invalidate_sessions_cache forces the next scrape to re-read the
// table. Tests use it; production relies on the TTL.
shell_metrics_invalidate_sessions_cache :: proc() {
	c := &shell_sessions_cache
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	c.have = false
}
