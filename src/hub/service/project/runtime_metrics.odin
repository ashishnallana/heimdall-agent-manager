package project

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import metrics "odin_test:lib/metrics"

// Fleet / WebSocket metric families (hub telemetry plan 3.1, 3.4). They live in
// this package because both the HTTP layer and the bridge_runtime service
// instrument them, and project_service is the common dependency.
//
// Cardinality rules enforced here:
//   - per-bridge series carry ONLY bridge_id; `owner` appears solely on
//     heimdall_bridge_info, which is tombstoned on disconnect/revoke;
//   - `type`, `command`, `reason`, `kind`, `result` values come from the fixed
//     mappers below (unknown -> "other") so a peer can never mint series;
//   - `type` is never combined with bridge_id (frames_total is fleet-wide).
Fleet_Metrics :: struct {
	bridge_info:              ^metrics.Family, // {bridge_id, owner, version, os, arch}
	bridge_ws_connects:       ^metrics.Family, // {bridge_id, result}
	bridge_ws_disconnects:    ^metrics.Family, // {reason}
	bridge_session_duration:  ^metrics.Series,
	bridge_last_heartbeat:    ^metrics.Family, // {bridge_id}
	bridge_ws_bytes:          ^metrics.Family, // {bridge_id, direction}
	bridge_ws_frames:         ^metrics.Family, // {direction, type}
	bridge_frames_rejected:   ^metrics.Family, // {reason}
	bridge_command_duration:  ^metrics.Family, // {command}
	bridge_command_errors:    ^metrics.Family, // {command, code}
	bridge_updates:           ^metrics.Family, // {result}
	limit_rejections:         ^metrics.Family, // {limit}
	agent_instances_reconciled_gone: ^metrics.Series,
	agent_instance_starts:    ^metrics.Family, // {status}
	agent_instance_exits:     ^metrics.Family, // {status}

	ws_connections:           ^metrics.Family, // {kind}
	ws_connections_total:     ^metrics.Family, // {kind, result}
	ws_disconnects_total:     ^metrics.Family, // {kind, reason}
	ws_connection_duration:   ^metrics.Family, // {kind}
	ws_bytes:                 ^metrics.Family, // {kind, direction, bridge_id}
	ws_write_errors:          ^metrics.Family, // {kind, reason}

	// Bridge host resources pushed in the heartbeat `stats` object (plan 3.2).
	bridge_process_resident:  ^metrics.Family, // {bridge_id, process}
	bridge_process_cpu:       ^metrics.Family, // {bridge_id, process} counter, value pushed
	bridge_host_memory:       ^metrics.Family, // {bridge_id, kind}
	bridge_host_load1:        ^metrics.Family, // {bridge_id}
	bridge_disk_free:         ^metrics.Family, // {bridge_id}
	instance_resident:        ^metrics.Family, // {bridge_id, provider}
	instance_cpu:             ^metrics.Family, // {bridge_id, provider} counter, value pushed

	// Bridge error-event relay (bridge_logs plan v2 §4.1/§4.2). `code` and
	// `level` come from the shared enum (unknown code -> "other"); the
	// per-bridge family carries bridge_id ONLY.
	bridge_errors:            ^metrics.Family, // {code, level}
	bridge_errors_by_bridge:  ^metrics.Family, // {bridge_id}
	bridge_log_entries:       ^metrics.Series, // accepted entries (sum of count)
	bridge_log_dropped:       ^metrics.Series, // bridge-reported ring drops
	bridge_log_queue_dropped: ^metrics.Series, // hub writer queue overflow
	bridge_log_rows_written:  ^metrics.Series, // rows the writer inserted
	log_push_failures:        ^metrics.Series, // optional backend push failures

	// Reliability (REQ-ERR-PROTO-B). `errors` counts the hub's own API error answers;
	// the bridge_* families are cumulative bridge counters pushed in each heartbeat
	// (they reset when the bridge restarts) and are removed on disconnect.
	errors:                   ^metrics.Family, // {code, class}
	bridge_dispatch:          ^metrics.Family, // {bridge_id, outcome} counter, value pushed
	bridge_recovery: ^metrics.Family,
	bridge_http_retries:      ^metrics.Family, // {bridge_id, outcome} counter, value pushed
	bridge_breakers_open:     ^metrics.Family, // {bridge_id}
	bridge_breaker_trips:     ^metrics.Family, // {bridge_id} counter, value pushed

	// bridge_diagnostics frames (minimal heartbeat plan §4.3, T5). Freshness is a
	// hub-receive timestamp per bounded family (age = time() - value); restarts count
	// accepted process_epoch changes. Both are removed on disconnect.
	bridge_diagnostics_last_sample: ^metrics.Family, // {bridge_id, family}
	bridge_diagnostics_restarts:    ^metrics.Family, // {bridge_id}
}

fleet_metrics: Fleet_Metrics

SESSION_DURATION_BUCKETS := [?]f64{60, 300, 900, 1800, 3600, 14400, 43200, 86400}
COMMAND_RTT_BUCKETS := [?]f64{0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30}

// The collector reads the registry through this pointer (not a captured ctx):
// tests build and destroy many graphs in one process, and a collector holding
// a pointer into a destroyed graph would be a use-after-free at scrape time.
@(private = "file")
collected_registry: ^Bridge_Runtime_Registry
@(private = "file")
collector_registered: bool

// fleet_metrics_set_registry points the scrape collector at the live registry
// (build_graph) or detaches it (shutdown_graph / destroy).
fleet_metrics_set_registry :: proc(r: ^Bridge_Runtime_Registry) {
	sync.atomic_store(&collected_registry, r)
}

fleet_metrics_detach_registry :: proc(r: ^Bridge_Runtime_Registry) {
	_, _ = sync.atomic_compare_exchange_strong(&collected_registry, r, nil)
}

fleet_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	m := &fleet_metrics
	m.bridge_info = metrics.new_gauge(reg, "heimdall_bridge_info", "Connected bridge identity (value 1); the only series carrying owner. Removed on disconnect/revoke.", {"bridge_id", "owner", "version", "os", "arch"})
	m.bridge_ws_connects = metrics.new_counter(reg, "heimdall_bridge_ws_connects_total", "Bridge WebSocket connection attempts by outcome.", {"bridge_id", "result"})
	m.bridge_ws_disconnects = metrics.new_counter(reg, "heimdall_bridge_ws_disconnects_total", "Bridge WebSocket teardowns by reason.", {"reason"})
	m.bridge_session_duration = metrics.with(metrics.new_histogram_seconds(reg, "heimdall_bridge_session_duration_seconds", "Lifetime of bridge WebSocket connections.", {}, SESSION_DURATION_BUCKETS[:]))
	m.bridge_last_heartbeat = metrics.new_gauge(reg, "heimdall_bridge_last_heartbeat_timestamp_seconds", "Unix time of the last bridge_heartbeat frame. Removed on disconnect.", {"bridge_id"})
	m.bridge_ws_bytes = metrics.new_counter(reg, "heimdall_bridge_ws_bytes_total", "WebSocket payload bytes exchanged with each bridge.", {"bridge_id", "direction"})
	m.bridge_ws_frames = metrics.new_counter(reg, "heimdall_bridge_ws_frames_total", "Bridge WebSocket frames by direction and frame family (fleet-wide).", {"direction", "type"})
	m.bridge_frames_rejected = metrics.new_counter(reg, "heimdall_bridge_frames_rejected_total", "Bridge frames the hub refused.", {"reason"})
	m.bridge_command_duration = metrics.new_histogram_seconds(reg, "heimdall_bridge_command_duration_seconds", "Round trip of hub->bridge commands that wait for a result.", {"command"}, COMMAND_RTT_BUCKETS[:])
	m.bridge_command_errors = metrics.new_counter(reg, "heimdall_bridge_command_errors_total", "Hub->bridge commands that failed, by command family and error code.", {"command", "code"})
	m.bridge_updates = metrics.new_counter(reg, "heimdall_bridge_updates_total", "Bridge self-update outcomes reported to the hub.", {"result"})
	m.limit_rejections = metrics.new_counter(reg, "heimdall_limit_rejections_total", "Admissions refused by a configured runtime limit.", {"limit"})
	m.agent_instances_reconciled_gone = metrics.with(metrics.new_counter(reg, "heimdall_agent_instances_reconciled_gone_total", "Agent instances the hub marked gone because the bridge no longer reported them."))

	m.agent_instance_starts = metrics.new_counter(reg, "heimdall_agent_instance_starts_total", "Agent instances entering an active runtime state (from new or terminal), by the status they entered.", {"status"})
	m.agent_instance_exits = metrics.new_counter(reg, "heimdall_agent_instance_exits_total", "Active agent instances entering a terminal runtime state, by that status.", {"status"})
	m.ws_connections = metrics.new_gauge(reg, "heimdall_ws_connections", "Open WebSocket connections by kind.", {"kind"})
	m.ws_connections_total = metrics.new_counter(reg, "heimdall_ws_connections_total", "WebSocket upgrade attempts by kind and outcome.", {"kind", "result"})
	m.ws_disconnects_total = metrics.new_counter(reg, "heimdall_ws_disconnects_total", "WebSocket teardowns by kind and reason.", {"kind", "reason"})
	m.ws_connection_duration = metrics.new_histogram_seconds(reg, "heimdall_ws_connection_duration_seconds", "Lifetime of browser/bridge WebSocket connections.", {"kind"}, SESSION_DURATION_BUCKETS[:])
	m.ws_bytes = metrics.new_counter(reg, "heimdall_ws_bytes_total", "WebSocket payload bytes by kind and direction (bridge_id only for agent_stream/shell).", {"kind", "direction", "bridge_id"})
	m.ws_write_errors = metrics.new_counter(reg, "heimdall_ws_write_errors_total", "Failed WebSocket writes by kind and reason.", {"kind", "reason"})
	m.bridge_process_resident = metrics.new_gauge(reg, "heimdall_bridge_process_resident_bytes", "Resident memory of bridge-side processes as reported in the heartbeat. Removed on disconnect.", {"bridge_id", "process"})
	m.bridge_process_cpu = metrics.new_counter(reg, "heimdall_bridge_process_cpu_seconds_total", "Cumulative CPU seconds of bridge-side processes (pushed value; resets when the bridge restarts). Removed on disconnect.", {"bridge_id", "process"}, 2)
	m.bridge_host_memory = metrics.new_gauge(reg, "heimdall_bridge_host_memory_bytes", "Bridge host memory as reported in the heartbeat. Removed on disconnect.", {"bridge_id", "kind"})
	m.bridge_host_load1 = metrics.new_gauge(reg, "heimdall_bridge_host_load1", "Bridge host 1-minute load average. Removed on disconnect.", {"bridge_id"}, 2)
	m.bridge_disk_free = metrics.new_gauge(reg, "heimdall_bridge_disk_free_bytes", "Free bytes on the bridge's scratch filesystem. Removed on disconnect.", {"bridge_id"})
	m.instance_resident = metrics.new_gauge(reg, "heimdall_instance_resident_bytes", "Resident memory of agent instance process trees per provider (summed on the bridge). Removed on disconnect.", {"bridge_id", "provider"})
	m.instance_cpu = metrics.new_counter(reg, "heimdall_instance_cpu_seconds_total", "Cumulative CPU seconds of agent instance process trees per provider (pushed value). Removed on disconnect.", {"bridge_id", "provider"}, 2)
	m.bridge_errors = metrics.new_counter(reg, "heimdall_bridge_errors_total", "Bridge warn/error events relayed over the bridge WebSocket, by code and level (fleet-wide; count-weighted).", {"code", "level"})
	m.bridge_errors_by_bridge = metrics.new_counter(reg, "heimdall_bridge_errors_by_bridge_total", "Bridge warn/error events per bridge (count-weighted). One series per bridge, no code.", {"bridge_id"})
	m.bridge_log_entries = metrics.with(metrics.new_counter(reg, "heimdall_bridge_log_entries_total", "bridge_log entries the hub accepted (count-weighted)."))
	m.bridge_log_dropped = metrics.with(metrics.new_counter(reg, "heimdall_bridge_log_dropped_total", "Entries bridges reported dropping from their own ring before shipping."))
	m.bridge_log_queue_dropped = metrics.with(metrics.new_counter(reg, "heimdall_bridge_log_queue_dropped_total", "Accepted entries the hub dropped because the writer queue was full."))
	m.bridge_log_rows_written = metrics.with(metrics.new_counter(reg, "heimdall_bridge_log_rows_written_total", "bridge_log_events rows inserted by the writer thread."))
	m.log_push_failures = metrics.with(metrics.new_counter(reg, "heimdall_log_push_failures_total", "Failed pushes of bridge events to the optional log backend (--log-push-url)."))
	m.errors = metrics.new_counter(reg, "heimdall_errors_total", "API error answers by error code and class (retriable/recoverable/fatal).", {"code", "class"})
	m.bridge_dispatch = metrics.new_counter(reg, "heimdall_bridge_dispatch_total", "Hub commands the bridge dispatcher accepted, shed under load, completed, or dropped past their deadline (pushed value; resets when the bridge restarts). Removed on disconnect.", {"bridge_id", "outcome"})
	m.bridge_recovery = metrics.new_gauge(reg, "heimdall_bridge_recovery_receipts", "Finite operation receipts by bounded operation, state and wire error. Removed on disconnect.", {"bridge_id", "operation", "state", "code", "class"})
    m.bridge_http_retries = metrics.new_counter(reg, "heimdall_bridge_http_retries_total", "Bridge->hub HTTP retries and how retried requests ended (pushed value; resets when the bridge restarts). Removed on disconnect.", {"bridge_id", "outcome"})
	m.bridge_breakers_open = metrics.new_gauge(reg, "heimdall_bridge_breakers_open", "Bridge dependency circuit breakers currently open. Removed on disconnect.", {"bridge_id"})
	m.bridge_breaker_trips = metrics.new_counter(reg, "heimdall_bridge_breaker_trips_total", "Times a bridge dependency circuit breaker opened (pushed value; resets when the bridge restarts). Removed on disconnect.", {"bridge_id"})
	m.bridge_diagnostics_last_sample = metrics.new_gauge(reg, "heimdall_bridge_diagnostics_last_sample_timestamp_seconds", "Unix time the hub last applied each bridge_diagnostics family (frame = any accepted snapshot). A family absent from later snapshots keeps its old timestamp. Removed on disconnect.", {"bridge_id", "family"})
	m.bridge_diagnostics_restarts = metrics.new_counter(reg, "heimdall_bridge_diagnostics_process_restarts_total", "bridge_diagnostics snapshots accepted from a new Bridge process (process_epoch changed), whose cumulative counters restart. Removed on disconnect.", {"bridge_id"})
	// Pre-create the per-kind gauges so a zero is exposed from the first scrape.
	for kind in ([]string{"bridge", "user", "agent_stream", "shell", "lsp"}) do metrics.with(m.ws_connections, kind)
	if !collector_registered {
		collector_registered = true
		metrics.registry_add_collector(reg, nil, runtime_registry_collect)
	}
}

// fleet_metrics_tombstone_bridge removes every per-bridge gauge for a bridge
// that is no longer connected (bridge_info, heartbeat; M3 resource gauges hook
// in here too). Counters stay: their history is still meaningful.
fleet_metrics_tombstone_bridge :: proc(bridge_id: string) {
	m := &fleet_metrics
	metrics.remove_where(m.bridge_info, 0, bridge_id)
	metrics.remove_where(m.bridge_last_heartbeat, 0, bridge_id)
	metrics.remove_where(m.bridge_process_resident, 0, bridge_id)
	metrics.remove_where(m.bridge_process_cpu, 0, bridge_id)
	metrics.remove_where(m.bridge_host_memory, 0, bridge_id)
	metrics.remove_where(m.bridge_host_load1, 0, bridge_id)
	metrics.remove_where(m.bridge_disk_free, 0, bridge_id)
	metrics.remove_where(m.instance_resident, 0, bridge_id)
	metrics.remove_where(m.instance_cpu, 0, bridge_id)
	metrics.remove_where(m.bridge_dispatch, 0, bridge_id)
	metrics.remove_where(m.bridge_recovery, 0, bridge_id)
	metrics.remove_where(m.bridge_http_retries, 0, bridge_id)
	metrics.remove_where(m.bridge_breakers_open, 0, bridge_id)
	metrics.remove_where(m.bridge_breaker_trips, 0, bridge_id)
	metrics.remove_where(m.bridge_diagnostics_last_sample, 0, bridge_id)
	metrics.remove_where(m.bridge_diagnostics_restarts, 0, bridge_id)
	bridge_diagnostics_forget(bridge_id)
	for hook in bridge_tombstone_hooks do hook(bridge_id)
}

// Additional per-bridge tombstone hooks (e.g. heartbeat resource gauges) are
// registered here by the packages that own those families.
bridge_tombstone_hooks: [dynamic]proc(bridge_id: string)

fleet_metrics_add_tombstone_hook :: proc(hook: proc(bridge_id: string)) {
	append(&bridge_tombstone_hooks, hook)
}

// ---------------------------------------------------------------------------
// Enum mappers. Every label value passes through one of these.

// bridge_frame_kind buckets a frame/command `type` into a fixed family.
bridge_frame_kind :: proc(frame_type: string) -> string {
	switch {
	case frame_type == "bridge_heartbeat":                 return "heartbeat"
	case frame_type == "bridge_diagnostics":               return "diagnostics"
	case frame_type == "agent_instance_status":            return "agent_status"
	case frame_type == "command_result":                   return "command_result"
	case frame_type == "shell_pty_output":                 return "shell_pty_output"
	case frame_type == "shell_pty_input":                  return "shell_pty_input"
	case strings.has_prefix(frame_type, "shell_"):         return "shell"
	case strings.has_prefix(frame_type, "pane_"):          return "pane"
	case strings.has_prefix(frame_type, "fs_"):            return "fs"
	case strings.has_prefix(frame_type, "vcs_"):           return "vcs"
	case strings.has_prefix(frame_type, "lsp_"):           return "lsp"
	case strings.has_prefix(frame_type, "proxy_"):         return "proxy"
	case strings.has_prefix(frame_type, "tunnel_"):        return "tunnel"
	case strings.has_prefix(frame_type, "provider_"):      return "provider"
	case strings.has_prefix(frame_type, "bridge_vault") || strings.has_prefix(frame_type, "bridge_unseal"): return "vault"
	case strings.has_prefix(frame_type, "bridge_update"):  return "update"
	case strings.has_prefix(frame_type, "task_chain_search"): return "search"
	case strings.has_prefix(frame_type, "project_path_validation"): return "path_validation"
	case strings.has_prefix(frame_type, "instance_") || strings.has_prefix(frame_type, "agent_"): return "instance"
	case frame_type == "set_telemetry":                    return "telemetry"
	case frame_type == "bridge_log":                       return "log"
	case frame_type == "chunk":                            return "chunk"
	case frame_type == "ping" || frame_type == "pong" || frame_type == "bridge_ready" || frame_type == "connection_replaced": return "control"
	}
	return "other"
}

// provider_enum maps a bridge-reported provider/program name onto the hub's
// provider catalog ids; anything else is "other".
provider_enum :: proc(provider: string) -> string {
	switch provider {
	case "claude", "codex", "copilot", "antigravity", "gemini":
		return provider
	}
	return "other"
}

// bridge_command_error_code maps a domain error code name onto a fixed set.
bridge_command_error_code :: proc(code: string) -> string {
	switch code {
	case "Bridge_Offline", "Bridge_Timeout", "Bridge_Busy", "Bridge_Revoked", "Validation_Failed", "Not_Found", "Internal_Error", "Forbidden", "Conflict", "Vault_Locked", "Rate_Limited":
		return code
	}
	return "other"
}

// ws_kind_from_route picks the ws_connections `kind` for a stream kind name.
WS_KIND_BRIDGE :: "bridge"
WS_KIND_USER :: "user"
WS_KIND_AGENT_STREAM :: "agent_stream"
WS_KIND_SHELL :: "shell"
WS_KIND_LSP :: "lsp"

// ws_track_open increments the open gauge + connects counter for a stream kind.
// Returns the connect tick so ws_track_close can observe the duration.
ws_track_open :: proc(kind: string) -> time.Tick {
	m := &fleet_metrics
	metrics.gauge_inc(metrics.with(m.ws_connections, kind))
	metrics.counter_inc(metrics.with(m.ws_connections_total, kind, "ok"))
	return time.tick_now()
}

// ws_track_rejected counts an upgrade that never became a connection.
ws_track_rejected :: proc(kind, result: string) {
	metrics.counter_inc(metrics.with(fleet_metrics.ws_connections_total, kind, ws_result_enum(result)))
}

// ws_track_close decrements the gauge and records reason + duration.
ws_track_close :: proc(kind: string, opened: time.Tick, reason: string) {
	m := &fleet_metrics
	metrics.gauge_dec(metrics.with(m.ws_connections, kind))
	metrics.counter_inc(metrics.with(m.ws_disconnects_total, kind, ws_reason_enum(reason)))
	metrics.observe_duration(metrics.with(m.ws_connection_duration, kind), time.tick_since(opened))
}

ws_result_enum :: proc(result: string) -> string {
	switch result {
	case "ok", "auth_failed", "not_found", "bad_request", "limit", "bridge_offline", "conflict":
		return result
	}
	return "other"
}

ws_reason_enum :: proc(reason: string) -> string {
	switch reason {
	case "clean_close", "read_deadline", "fatal_frame", "recv_error", "connection_replaced", "frame_rejected", "write_failed", "stream_closed", "bridge_offline", "revoked", "shutdown", "error", "eof", "timeout", "replaced":
		return reason
	}
	return "other"
}

// ---------------------------------------------------------------------------
// Scrape-time collector over the runtime registry: online bridges and agent
// instances per bridge/status. Snapshots under the registry lock, formats
// outside it. provider is not part of runtime state, so it is omitted here.

@(private = "file")
Instance_Count :: struct {
	bridge_id: string,
	status:    string,
	count:     int,
}

runtime_registry_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	r := sync.atomic_load(&collected_registry)
	if r == nil do return
	reg := metrics.global()
	a := reg.allocator
	counts := make([dynamic]Instance_Count, a)
	defer {
		for c in counts {
			delete(c.bridge_id, a)
			delete(c.status, a)
		}
		delete(counts)
	}
	live := 0
	sync.lock(&r.metadata_mutex)
	for _, c in r.connections {
		if sync.atomic_load(&c.retired) do continue
		live += 1
		connection_state_lock(c)
		for _, st in c.instances {
			if !st.active do continue
			status := runtime_status_enum(st.runtime_status)
			found := false
			for &ic in counts {
				if ic.bridge_id == c.bridge_id && ic.status == status { ic.count += 1; found = true; break }
			}
			if !found do append(&counts, Instance_Count{bridge_id = strings.clone(c.bridge_id, a), status = strings.clone(status, a), count = 1})
		}
		connection_state_unlock(c)
	}
	sync.unlock(&r.metadata_mutex)

	metrics.expo_header(e, "heimdall_bridges_online", "Bridges with a live WebSocket connection.", .Gauge)
	metrics.expo_sample_i64(e, "heimdall_bridges_online", nil, nil, i64(live))
	if len(counts) > 0 {
		metrics.expo_header(e, "heimdall_agent_instances", "Active agent instances per bridge and runtime status (populated combinations only).", .Gauge)
		for c in counts {
			metrics.expo_sample_i64(e, "heimdall_agent_instances", {"bridge_id", "status"}, {c.bridge_id, c.status}, i64(c.count))
		}
	}
}

runtime_status_enum :: proc(status: string) -> string {
	switch status {
	case "launching", "starting", "running", "idle", "busy", "blocked", "stopping", "stopped", "exited", "unreachable", "crashed", "failed":
		return status
	}
	return "other"
}

// ---------------------------------------------------------------------------
// bridge_diagnostics snapshots (minimal heartbeat plan §4.3, T5).
//
// The HTTP layer parses and fully validates a frame into a Bridge_Diagnostics_Snapshot
// (nothing is mutated while parsing); bridge_diagnostics_commit then orders it and
// applies it under one mutex, so ordering state and the series it guards always move
// together. Per-family outcome: Absent leaves the family's series and freshness
// untouched; Invalid rejects only that family (counted); Valid replaces it.

Bridge_Diagnostics_Family :: enum u8 {
	Command_Dispatch,
	Dependency_Breakers,
	Http_Retries,
	Operation_Recovery,
	Stats,
}

BRIDGE_DIAGNOSTICS_FAMILY_LABELS := [Bridge_Diagnostics_Family]string{
	.Command_Dispatch    = "command_dispatch",
	.Dependency_Breakers = "dependency_breakers",
	.Http_Retries        = "http_retries",
	.Operation_Recovery  = "operation_recovery",
	.Stats               = "stats",
}

Bridge_Diagnostics_Part :: enum u8 {
	Absent,
	Valid,
	Invalid,
}

// Optional stats gauges a Bridge may declare unavailable. host_mem_total and
// host_mem_avail are one gauge pair (kept together, plan §3.2).
Bridge_Diagnostics_Gauge :: enum u8 {
	Pty_Host_Rss,
	Host_Memory,
	Load1,
	Disk_Free,
}

Bridge_Diagnostics_Recovery_Row :: struct {
	operation, state, code, class: string,
	receipts:                      i64,
}

Bridge_Diagnostics_Provider :: struct {
	provider: string, // already mapped through provider_enum
	rss:      u64,
	cpu_cs:   u64,
}

BRIDGE_DIAGNOSTICS_MAX_PROVIDERS :: 16
BRIDGE_DIAGNOSTICS_EPOCH_MAX :: 64

Bridge_Diagnostics_Snapshot :: struct {
	process_epoch:   string,
	sample_seq:      u64,
	collected_at_ms: u64,
	parts:           [Bridge_Diagnostics_Family]Bridge_Diagnostics_Part,
	// command_dispatch: accepted, rejected (exported as "shed"), completed, deadline_expired
	dispatch:        [4]u64,
	breakers_open:   u64,
	breakers_opened: u64,
	// http_retries: retry, recovered, gave_up, deferred
	http_retries:    [4]u64,
	recovery_rows:   []Bridge_Diagnostics_Recovery_Row, // caller-owned; read during commit only
	// stats; a gauge in `unavailable` carries no value and is cleared on apply.
	rss, pty_host_rss, cpu_cs, host_mem_total, host_mem_avail, load1_cs, disk_free: u64,
	unavailable:     bit_set[Bridge_Diagnostics_Gauge],
	providers:       [BRIDGE_DIAGNOSTICS_MAX_PROVIDERS]Bridge_Diagnostics_Provider,
	n_providers:     int,
}

Bridge_Diagnostics_Commit_Result :: enum u8 {
	Applied,
	Stale,      // same process_epoch, sample_seq not greater than the last applied
	Superseded, // from a connection generation older than one already seen / current
}

// Rejection reasons (heimdall_bridge_frames_rejected_total{reason}); a fixed set.
DIAGNOSTICS_REJECT_BAD_JSON           :: "diagnostics_bad_json"
DIAGNOSTICS_REJECT_OVERSIZE           :: "diagnostics_oversize"
DIAGNOSTICS_REJECT_ENVELOPE           :: "diagnostics_envelope"
DIAGNOSTICS_REJECT_STALE              :: "diagnostics_stale"
DIAGNOSTICS_REJECT_SUPERSEDED         :: "diagnostics_superseded"
DIAGNOSTICS_REJECT_INVALID_OBJECT     :: "diagnostics_invalid_object"
DIAGNOSTICS_REJECT_COUNTER_REGRESSION :: "diagnostics_counter_regression"

// Per-bridge ordering state and the last applied cumulative counters (for the
// same-epoch regression check). Lives until the bridge's per-bridge series are
// tombstoned (no live generation), so a replacement connection from the same or a
// new process is ordered against what the hub already exposes.
@(private = "file")
Diagnostics_State :: struct {
	key:             string, // the map key (runtime heap)
	generation:      int,
	epoch:           [BRIDGE_DIAGNOSTICS_EPOCH_MAX]u8,
	epoch_len:       int,
	sample_seq:      u64,
	has_dispatch:    bool,
	dispatch:        [4]u64,
	has_http:        bool,
	http_retries:    [4]u64,
	has_breakers:    bool,
	breakers_opened: u64,
	has_cpu:         bool,
	cpu_cs:          u64,
}

@(private = "file")
diagnostics_mutex: sync.Mutex
@(private = "file")
diagnostics_states: map[string]^Diagnostics_State // keys/values: runtime heap

// bridge_diagnostics_owns_generation: a bridge_diagnostics frame has been accepted
// on this connection generation, so the Bridge reports diagnostics there and a
// heartbeat's legacy diagnostic members (if any) must not overwrite those series.
bridge_diagnostics_owns_generation :: proc(bridge_id: string, generation: int) -> bool {
	sync.lock(&diagnostics_mutex)
	defer sync.unlock(&diagnostics_mutex)
	st, found := diagnostics_states[bridge_id]
	return found && st.generation == generation
}

// bridge_diagnostics_forget drops the ordering state with the per-bridge series
// (fleet_metrics_tombstone_bridge). The next accepted snapshot is a fresh baseline:
// with no series left there is nothing to compare against or to count a restart for.
bridge_diagnostics_forget :: proc(bridge_id: string) {
	sync.lock(&diagnostics_mutex)
	defer sync.unlock(&diagnostics_mutex)
	st, found := diagnostics_states[bridge_id]
	if !found do return
	delete_key(&diagnostics_states, bridge_id)
	heap := runtime.heap_allocator()
	delete(st.key, heap)
	free(st, heap)
}

// bridge_diagnostics_commit orders and applies one validated snapshot.
//   - generation older than the newest seen, or no longer the registry's current
//     generation (registry may be nil in unit tests) -> Superseded, nothing applied;
//   - no prior state -> baseline (not a restart);
//   - different process_epoch -> new process: counters are applied as a reset
//     (counter_set accepts the lower absolutes) and restarts_total is incremented;
//   - same epoch, sample_seq <= last -> Stale (duplicate/reordered), nothing applied;
//   - same epoch, a cumulative counter lower than last applied -> that family is
//     rejected (counted), the others apply.
// stats_enabled=false (owner telemetry "disabled") clears every stats series and
// ignores any stats the frame carries; reliability families apply regardless.
bridge_diagnostics_commit :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int, snap: ^Bridge_Diagnostics_Snapshot, stats_enabled: bool, now_unix_s: i64 = 0) -> Bridge_Diagnostics_Commit_Result {
	m := &fleet_metrics
	now := now_unix_s if now_unix_s != 0 else time.now()._nsec / 1_000_000_000
	sync.lock(&diagnostics_mutex)
	defer sync.unlock(&diagnostics_mutex)

	// Barrier against a late frame from a connection that has been replaced while
	// it was being parsed: re-check under the same lock that publishes the series.
	if r != nil && bridge_runtime_registry_generation(r, bridge_id) != generation {
		reject_reason(DIAGNOSTICS_REJECT_SUPERSEDED)
		return .Superseded
	}
	st, found := diagnostics_states[bridge_id]
	restarted := false
	if found {
		if generation < st.generation {
			reject_reason(DIAGNOSTICS_REJECT_SUPERSEDED)
			return .Superseded
		}
		same_epoch := string(st.epoch[:st.epoch_len]) == snap.process_epoch
		if same_epoch && snap.sample_seq <= st.sample_seq {
			reject_reason(DIAGNOSTICS_REJECT_STALE)
			return .Stale
		}
		if !same_epoch {
			restarted = true
			st.has_dispatch, st.has_http, st.has_breakers, st.has_cpu = false, false, false, false
		}
	} else {
		// The state outlives any one test/request allocator: runtime heap, like the
		// metrics registry it mirrors.
		heap := runtime.heap_allocator()
		if diagnostics_states == nil do diagnostics_states = make(map[string]^Diagnostics_State, heap)
		st = new(Diagnostics_State, heap)
		st.key = strings.clone(bridge_id, heap)
		diagnostics_states[st.key] = st
	}
	st.generation = generation
	st.epoch_len = copy(st.epoch[:], snap.process_epoch)
	st.sample_seq = snap.sample_seq
	if restarted do metrics.counter_inc(metrics.with(m.bridge_diagnostics_restarts, bridge_id))

	parts := snap.parts
	if parts[.Command_Dispatch] == .Valid && st.has_dispatch && counters_regressed(snap.dispatch[:], st.dispatch[:]) do parts[.Command_Dispatch] = .Invalid
	if parts[.Http_Retries] == .Valid && st.has_http && counters_regressed(snap.http_retries[:], st.http_retries[:]) do parts[.Http_Retries] = .Invalid
	if parts[.Dependency_Breakers] == .Valid && st.has_breakers && snap.breakers_opened < st.breakers_opened do parts[.Dependency_Breakers] = .Invalid
	// Only the Bridge process's own CPU is monotonic within an epoch; per-provider
	// CPU is a sum over live instances and legitimately drops when one exits.
	if parts[.Stats] == .Valid && stats_enabled && st.has_cpu && snap.cpu_cs < st.cpu_cs do parts[.Stats] = .Invalid
	for family in Bridge_Diagnostics_Family {
		if parts[family] != .Invalid do continue
		reason := DIAGNOSTICS_REJECT_INVALID_OBJECT
		if snap.parts[family] == .Valid do reason = DIAGNOSTICS_REJECT_COUNTER_REGRESSION
		reject_reason(reason)
	}

	if parts[.Command_Dispatch] == .Valid {
		metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "accepted"), snap.dispatch[0])
		metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "shed"), snap.dispatch[1])
		metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "completed"), snap.dispatch[2])
		metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "deadline_expired"), snap.dispatch[3])
		st.dispatch, st.has_dispatch = snap.dispatch, true
	}
	if parts[.Http_Retries] == .Valid {
		metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "retry"), snap.http_retries[0])
		metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "recovered"), snap.http_retries[1])
		metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "gave_up"), snap.http_retries[2])
		metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "deferred"), snap.http_retries[3])
		st.http_retries, st.has_http = snap.http_retries, true
	}
	if parts[.Dependency_Breakers] == .Valid {
		metrics.gauge_set(metrics.with(m.bridge_breakers_open, bridge_id), i64(snap.breakers_open))
		metrics.counter_set(metrics.with(m.bridge_breaker_trips, bridge_id), snap.breakers_opened)
		st.breakers_opened, st.has_breakers = snap.breakers_opened, true
	}
	if parts[.Operation_Recovery] == .Valid {
		// Full replacement: rows no longer reported (or an empty list) are tombstoned.
		// Duplicate label tuples are summed so no reported receipt is lost.
		metrics.remove_where(m.bridge_recovery, 0, bridge_id)
		for row in snap.recovery_rows do metrics.gauge_add(metrics.with(m.bridge_recovery, bridge_id, row.operation, row.state, row.code, row.class), row.receipts)
	}
	if !stats_enabled {
		// Opt-out is explicit (owner switch), never inferred from an absent object.
		diagnostics_clear_stats(bridge_id)
		st.has_cpu = false
		parts[.Stats] = .Absent
	} else if parts[.Stats] == .Valid {
		diagnostics_apply_stats(bridge_id, snap)
		st.cpu_cs, st.has_cpu = snap.cpu_cs, true
	}

	metrics.gauge_set(metrics.with(m.bridge_diagnostics_last_sample, bridge_id, "frame"), now)
	for family in Bridge_Diagnostics_Family {
		if parts[family] == .Valid do metrics.gauge_set(metrics.with(m.bridge_diagnostics_last_sample, bridge_id, BRIDGE_DIAGNOSTICS_FAMILY_LABELS[family]), now)
	}
	return .Applied
}

@(private = "file")
counters_regressed :: proc(next, last: []u64) -> bool {
	for v, i in next do if v < last[i] do return true
	return false
}

@(private = "file")
reject_reason :: proc(reason: string) {
	metrics.counter_inc(metrics.with(fleet_metrics.bridge_frames_rejected, reason))
}

@(private = "file")
diagnostics_clear_stats :: proc(bridge_id: string) {
	m := &fleet_metrics
	metrics.remove_where(m.bridge_process_resident, 0, bridge_id)
	metrics.remove_where(m.bridge_process_cpu, 0, bridge_id)
	metrics.remove_where(m.bridge_host_memory, 0, bridge_id)
	metrics.remove_where(m.bridge_host_load1, 0, bridge_id)
	metrics.remove_where(m.bridge_disk_free, 0, bridge_id)
	metrics.remove_where(m.instance_resident, 0, bridge_id)
	metrics.remove_where(m.instance_cpu, 0, bridge_id)
	metrics.remove(m.bridge_diagnostics_last_sample, bridge_id, BRIDGE_DIAGNOSTICS_FAMILY_LABELS[.Stats])
}

@(private = "file")
diagnostics_apply_stats :: proc(bridge_id: string, snap: ^Bridge_Diagnostics_Snapshot) {
	m := &fleet_metrics
	metrics.gauge_set(metrics.with(m.bridge_process_resident, bridge_id, "bridge"), i64(snap.rss))
	metrics.counter_set(metrics.with(m.bridge_process_cpu, bridge_id, "bridge"), snap.cpu_cs)
	if .Pty_Host_Rss in snap.unavailable {
		metrics.remove(m.bridge_process_resident, bridge_id, "pty_host")
	} else {
		metrics.gauge_set(metrics.with(m.bridge_process_resident, bridge_id, "pty_host"), i64(snap.pty_host_rss))
	}
	if .Host_Memory in snap.unavailable {
		metrics.remove_where(m.bridge_host_memory, 0, bridge_id)
	} else {
		metrics.gauge_set(metrics.with(m.bridge_host_memory, bridge_id, "total"), i64(snap.host_mem_total))
		metrics.gauge_set(metrics.with(m.bridge_host_memory, bridge_id, "available"), i64(snap.host_mem_avail))
	}
	if .Load1 in snap.unavailable {
		metrics.remove_where(m.bridge_host_load1, 0, bridge_id)
	} else {
		metrics.gauge_set(metrics.with(m.bridge_host_load1, bridge_id), i64(snap.load1_cs))
	}
	if .Disk_Free in snap.unavailable {
		metrics.remove_where(m.bridge_disk_free, 0, bridge_id)
	} else {
		metrics.gauge_set(metrics.with(m.bridge_disk_free, bridge_id), i64(snap.disk_free))
	}
	// Full replacement of the provider aggregates; a valid empty list tombstones all.
	metrics.remove_where(m.instance_resident, 0, bridge_id)
	metrics.remove_where(m.instance_cpu, 0, bridge_id)
	for p in snap.providers[:snap.n_providers] {
		metrics.gauge_set(metrics.with(m.instance_resident, bridge_id, p.provider), i64(p.rss))
		metrics.counter_set(metrics.with(m.instance_cpu, bridge_id, p.provider), p.cpu_cs)
	}
}
