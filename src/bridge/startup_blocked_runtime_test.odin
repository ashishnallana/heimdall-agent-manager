package main

import "core:testing"

// AE-5 regression tests: a startup probe that classifies the pane as blocked must
// surface as a distinct "blocked" runtime state that is active-but-not-ready.
//
// The bridge_runtime_* registry is process-global and shared by the parallel test
// runner, so every test below uses a UNIQUE agent_instance_id to avoid cross-test
// interference.

@(test)
startup_blocked_sets_active_but_not_ready :: proc(t: ^testing.T) {
	id := "inst_ae5_blocked_basic"
	bridge_runtime_set_status(id, "starting", "idle")
	bridge_runtime_set_status(id, "blocked", "idle")
	snap, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok, "instance snapshot must exist after blocked report")
	testing.expect(t, snap.runtime_status == "blocked", "runtime_status must be blocked")
	testing.expect(t, !snap.start_success_seen, "blocked must NOT be treated as start-success (not ready)")
	testing.expect(t, snap.start_deadline_unix_ms == 0, "blocked must clear the start-success deadline so the reaper never fires")
	// Blocked counts as active for heartbeat and liveness-reconcile purposes.
	testing.expect(t, bridge_runtime_status_active("blocked"), "blocked must be an active runtime status")
}

@(test)
startup_blocked_survives_wrapper_liveness_ping :: proc(t: ^testing.T) {
	// The core resurrection guard: a !start_success_seen instance is normally
	// forced back to "starting" on every wrapper liveness/activity ping. A blocked
	// instance must instead STAY blocked, otherwise the very next ping erases it.
	id := "inst_ae5_blocked_liveness"
	bridge_runtime_set_status(id, "starting", "idle")
	bridge_runtime_set_status(id, "blocked", "idle")
	// Simulate the wrapper's periodic liveness ping / activity report.
	bridge_runtime_note_wrapper_signal(id, "idle")
	bridge_runtime_note_agent_activity(id, "active", "pane_diff")
	snap, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok, "instance must still exist")
	testing.expect(t, snap.runtime_status == "blocked", "blocked must survive wrapper liveness + activity pings, not revert to starting")
}

@(test)
startup_blocked_cleared_by_start_success :: proc(t: ^testing.T) {
	// Recovery path: if the agent eventually calls start-success (e.g. the operator
	// dismissed the prompt), the blocked state must clear to running/ready.
	id := "inst_ae5_blocked_recover"
	bridge_runtime_set_status(id, "starting", "idle")
	bridge_runtime_set_status(id, "blocked", "idle")
	bridge_runtime_mark_start_success(id)
	snap, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok, "instance must exist")
	testing.expect(t, snap.runtime_status == "running", "start-success must clear blocked -> running")
	testing.expect(t, snap.start_success_seen, "start-success must mark start_success_seen")
	// A subsequent liveness ping must keep it running (not downgrade).
	bridge_runtime_note_wrapper_signal(id, "idle")
	snap2, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, snap2.runtime_status == "running", "post-start-success liveness must keep running")
}

@(test)
startup_blocked_appears_in_heartbeat_digest :: proc(t: ^testing.T) {
	// Blocked must ship upstream: it is an active status so it appears in the
	// heartbeat's active_instance_ids and the per-instance runtime_status list.
	id := "inst_ae5_blocked_heartbeat"
	bridge_runtime_set_status(id, "blocked", "idle")
	digest := bridge_hub_heartbeat_json()
	testing.expect(t, contains_substr(digest, id), "heartbeat must include the blocked instance id")
	testing.expect(t, contains_substr(digest, "\"runtime_status\":\"blocked\""), "heartbeat must carry runtime_status=blocked upstream")
}

@(test)
startup_blocked_normal_starting_to_ready_intact :: proc(t: ^testing.T) {
	// Guard against regressing the normal happy path: a starting instance that gets
	// a wrapper liveness ping stays starting, and a real start-success makes it
	// running/ready — the blocked branch must not interfere.
	id := "inst_ae5_normal_ready"
	bridge_runtime_set_status(id, "starting", "idle")
	bridge_runtime_note_wrapper_signal(id, "idle")
	mid, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, mid.runtime_status == "starting", "liveness on a normal starting instance keeps it starting")
	testing.expect(t, !mid.start_success_seen, "not ready before start-success")
	bridge_runtime_mark_start_success(id)
	fin, _ := bridge_runtime_instance_snapshot(id)
	testing.expect(t, fin.runtime_status == "running" && fin.start_success_seen, "start-success -> running/ready unchanged by AE-5")
}

// contains_substr is a tiny local substring check to avoid importing core:strings
// solely for the heartbeat assertions.
contains_substr :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 do return true
	if len(needle) > len(haystack) do return false
	for i in 0..=(len(haystack) - len(needle)) {
		if haystack[i:i + len(needle)] == needle do return true
	}
	return false
}
