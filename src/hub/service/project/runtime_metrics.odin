package project

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

	ws_connections:           ^metrics.Family, // {kind}
	ws_connections_total:     ^metrics.Family, // {kind, result}
	ws_disconnects_total:     ^metrics.Family, // {kind, reason}
	ws_connection_duration:   ^metrics.Family, // {kind}
	ws_bytes:                 ^metrics.Family, // {kind, direction, bridge_id}
	ws_write_errors:          ^metrics.Family, // {kind, reason}
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

	m.ws_connections = metrics.new_gauge(reg, "heimdall_ws_connections", "Open WebSocket connections by kind.", {"kind"})
	m.ws_connections_total = metrics.new_counter(reg, "heimdall_ws_connections_total", "WebSocket upgrade attempts by kind and outcome.", {"kind", "result"})
	m.ws_disconnects_total = metrics.new_counter(reg, "heimdall_ws_disconnects_total", "WebSocket teardowns by kind and reason.", {"kind", "reason"})
	m.ws_connection_duration = metrics.new_histogram_seconds(reg, "heimdall_ws_connection_duration_seconds", "Lifetime of browser/bridge WebSocket connections.", {"kind"}, SESSION_DURATION_BUCKETS[:])
	m.ws_bytes = metrics.new_counter(reg, "heimdall_ws_bytes_total", "WebSocket payload bytes by kind and direction (bridge_id only for agent_stream/shell).", {"kind", "direction", "bridge_id"})
	m.ws_write_errors = metrics.new_counter(reg, "heimdall_ws_write_errors_total", "Failed WebSocket writes by kind and reason.", {"kind", "reason"})
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
	case strings.has_prefix(frame_type, "bridge_vault") || strings.has_prefix(frame_type, "bridge_lock") || strings.has_prefix(frame_type, "bridge_unseal"): return "vault"
	case strings.has_prefix(frame_type, "bridge_update"):  return "update"
	case strings.has_prefix(frame_type, "task_chain_search"): return "search"
	case strings.has_prefix(frame_type, "project_path_validation"): return "path_validation"
	case strings.has_prefix(frame_type, "instance_") || strings.has_prefix(frame_type, "agent_"): return "instance"
	case frame_type == "set_telemetry":                    return "telemetry"
	case frame_type == "chunk":                            return "chunk"
	case frame_type == "ping" || frame_type == "pong" || frame_type == "bridge_ready" || frame_type == "connection_replaced": return "control"
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
		sync.lock(&c.state_mutex)
		for _, st in c.instances {
			if !st.active do continue
			status := runtime_status_enum(st.runtime_status)
			found := false
			for &ic in counts {
				if ic.bridge_id == c.bridge_id && ic.status == status { ic.count += 1; found = true; break }
			}
			if !found do append(&counts, Instance_Count{bridge_id = strings.clone(c.bridge_id, a), status = strings.clone(status, a), count = 1})
		}
		sync.unlock(&c.state_mutex)
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
