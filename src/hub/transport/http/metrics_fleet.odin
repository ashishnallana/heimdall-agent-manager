package http

import "core:time"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// Bridge WebSocket lifecycle -> fleet metrics glue (plan 3.1 / 4.2). The
// families live in project_service.fleet_metrics; this file only decides WHEN
// and with WHICH enum values they are touched from bridge_handlers.odin.

// BRIDGE_ID_UNKNOWN labels connection attempts that failed before a trusted
// bridge_id existed (bad/revoked token). One shared series, never a client value.
BRIDGE_ID_UNKNOWN :: "unknown"

// bridge_metrics_connect_result counts one bridge WebSocket connection attempt.
// result is one of: ok, replaced, auth_failed, limit, hello_rejected, revoked,
// connect_failed.
bridge_metrics_connect_result :: proc(bridge_id, result: string) {
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_ws_connects, bridge_id, result))
}

// bridge_metrics_connected publishes bridge_info for a fully established
// connection. owner is the only PII-bearing label in the whole catalog and it
// lives here alone; everything else joins on bridge_id.
bridge_metrics_connected :: proc(bridge: domain.Bridge, replaced_existing: bool) {
	m := &project_service.fleet_metrics
	bridge_metrics_connect_result(bridge.bridge_id, "replaced" if replaced_existing else "ok")
	metrics.gauge_inc(metrics.with(m.ws_connections, project_service.WS_KIND_BRIDGE))
	metrics.counter_inc(metrics.with(m.ws_connections_total, project_service.WS_KIND_BRIDGE, "ok"))
	// A reconnect with a new version must not leave the old version's series
	// alive: tombstone first, then (re)create the current tuple.
	metrics.remove_where(m.bridge_info, 0, bridge.bridge_id)
	metrics.gauge_set(metrics.with(m.bridge_info, bridge.bridge_id, string(bridge.owner_user_id), bridge.version, bridge.machine_os, bridge.machine_arch), 1)
	metrics.gauge_set(metrics.with(m.bridge_last_heartbeat, bridge.bridge_id), time.now()._nsec / 1_000_000_000)
}

// bridge_metrics_disconnected records a teardown: reason counter, session
// duration, and — when no live generation remains — the per-bridge tombstones.
// connected_at_ns == 0 means the connection never got past hello and was never
// counted as open, so the open gauge is left alone.
bridge_metrics_disconnected :: proc(reason: Bridge_WS_Disconnect_Reason, connected_at_ns: i64, no_live_generation: bool, bridge_id: string) {
	m := &project_service.fleet_metrics
	reason_label := bridge_ws_reason_string(reason)
	metrics.counter_inc(metrics.with(m.bridge_ws_disconnects, reason_label))
	if connected_at_ns > 0 {
		lifetime := time.Duration(time.now()._nsec - connected_at_ns)
		metrics.observe_duration(m.bridge_session_duration, lifetime)
		metrics.gauge_dec(metrics.with(m.ws_connections, project_service.WS_KIND_BRIDGE))
		metrics.counter_inc(metrics.with(m.ws_disconnects_total, project_service.WS_KIND_BRIDGE, project_service.ws_reason_enum(reason_label)))
		metrics.observe_duration(metrics.with(m.ws_connection_duration, project_service.WS_KIND_BRIDGE), lifetime)
	}
	if no_live_generation do project_service.fleet_metrics_tombstone_bridge(bridge_id)
}
