package main

import "core:sync"
import "core:testing"

// REQ-LIVENESS-1, REQ-LIVENESS-2, REQ-LIVENESS-3:
// Live agents in ham-pty-host that have signaled start-success are never reaped
// to unreachable or stopped while their PTY process is alive.

@(test)
test_liveness_pty_process_alive_prevents_stale_reap :: proc(t: ^testing.T) {
	id := "inst_test_liveness_preserve"
	bridge_runtime_set_status(id, "running", "idle")
	bridge_runtime_set_pty_process_alive(id, true)

	now := bridge_runtime_now_ms()
	// Simulate last_seen older than BRIDGE_WRAPPER_STALE_MS
	sync.mutex_lock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == id {
			bridge_runtime_instances[i].last_seen_unix_ms = now - BRIDGE_WRAPPER_STALE_MS - 5000
			break
		}
	}
	bridge_runtime_expire_stale_locked(now)
	sync.mutex_unlock(&bridge_runtime_mutex)

	snap, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok, "instance snapshot must exist")
	testing.expect(t, snap.runtime_status == "running", "instance must remain running because pty_process_alive is true")
	testing.expect(t, snap.last_seen_unix_ms == now, "last_seen_unix_ms should be refreshed by pty_process_alive check")
}

@(test)
test_liveness_pty_process_dead_allows_stale_reap :: proc(t: ^testing.T) {
	id := "inst_test_liveness_dead_reap"
	bridge_runtime_set_status(id, "running", "idle")
	bridge_runtime_set_pty_process_alive(id, false)

	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == id {
			bridge_runtime_instances[i].last_seen_unix_ms = now - BRIDGE_WRAPPER_STALE_MS - 5000
			break
		}
	}
	bridge_runtime_expire_stale_locked(now)
	sync.mutex_unlock(&bridge_runtime_mutex)

	snap, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok, "instance snapshot must exist")
	testing.expect(t, snap.runtime_status == "unreachable", "instance without pty_process_alive must be reaped to unreachable")
}

@(test)
test_liveness_touch_unlatches_unreachable_instance :: proc(t: ^testing.T) {
	id := "inst_test_liveness_unlatch"
	bridge_runtime_set_status(id, "running", "idle")
	bridge_runtime_set_status(id, "unreachable", "idle")

	snap1, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, snap1.runtime_status == "unreachable", "initial state is unreachable")
	testing.expect(t, snap1.start_success_seen, "start_success_seen should be preserved")

	// Liveness touch from Host_Heartbeat with pty_process_alive=true
	bridge_runtime_touch_liveness(id, true)

	snap2, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, snap2.runtime_status == "running", "liveness touch must restore unreachable instance to running")
	testing.expect(t, snap2.pty_process_alive, "pty_process_alive must be set to true")
}
