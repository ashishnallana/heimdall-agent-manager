package main

// REQ-EXP-GATE-4: an authoritative Actions disable suspends cached schedules BEFORE any
// launch, wake or prompt; re-enable restores schedules without replaying missed fires.
// Fakes stand in for the Hub (fetch), launch (resolve) and execute; no network, no sleeps.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import http "odin_test:lib/http_client"

// action_sched_test_mutex serializes tests that drive the process-global scheduler
// state (bridge_action_sched_state, bridge_retry_journal); the runner is threaded.
action_sched_test_mutex: sync.Mutex

@(private = "file")
DISABLED_BODY :: `{"error":{"code":"forbidden","message":"Actions is experimental. Enable it in Settings > Experimental to use it.","details":{"code":"experimental_feature_disabled","feature":"actions"}}}`

@(private = "file") gate_fetch_status: int
@(private = "file") gate_fetch_calls: int
@(private = "file") gate_fetch_body: string
@(private = "file") gate_mints: int
@(private = "file") gate_executes: int
@(private = "file") gate_execute_status: int

@(private = "file")
gate_fetch :: proc(method, base_url, path, body: string, headers: []http.Header, timeout_ms: int) -> (http.Response, bool) {
    gate_fetch_calls += 1
    switch gate_fetch_status {
    case 403: return {status = 403, body = strings.clone(DISABLED_BODY)}, true
    case 304: return {status = 304}, true
    }
    return {status = 200, body = strings.clone(gate_fetch_body)}, true
}

@(private = "file")
gate_resolve :: proc(due: Action_Queue_Item, now: i64) -> (string, bool) {
    gate_mints += 1
    return "inst_minted", true
}

@(private = "file")
gate_execute :: proc(action_id, next_target_run_at: string, instance_id: string = "", last_spawned_instance_id: string = "") -> (bool, int, string) {
    gate_executes += 1
    if gate_execute_status == 403 do return false, 403, strings.clone(DISABLED_BODY)
    return true, 200, strings.clone(`{"ok":true}`)
}

// A validated, fresh installed snapshot holding one due agent-target action.
@(private = "file")
gate_fresh_state :: proc(now: i64) {
    bridge_action_scheduler_init(); bridge_retry_journal = {}
    s := &bridge_action_sched_state
    s.known_actions_version = 0; s.synced_actions_version = 0
    s.wanted_epoch = strings.clone("e.on1"); s.installed_epoch = strings.clone("e.on1")
    s.last_etag = strings.clone(`W/"e.on1:0"`)
    s.sync_state = .Succeeded; s.last_full_reconcile_ms = now; s.validated_ms = now
    append(&s.queue, action_queue_item_clone(Action_Queue_Item{id = "act_gate", target_agent_id = "agent", instance_strategy = "reuse", state = "active", interval = "60s", interval_seconds = 60, target_run_at_ms = now - 1000}))
    gate_fetch_calls = 0; gate_mints = 0; gate_executes = 0; gate_execute_status = 200
}

@(test)
test_action_gate_prelaunch_denial_suspends_without_launch :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    gate_fetch_status = 403
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 0)
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
    s := &bridge_action_sched_state
    testing.expect(t, s.suspended, "authoritative disable suspends")
    testing.expect_value(t, len(s.queue), 0)
    testing.expect(t, !bridge_action_scheduler_fresh_locked(now))
    // Later ticks neither launch nor poll the 403 every second.
    calls := gate_fetch_calls
    for offset: i64 = 1000; offset <= 30_000; offset += 1000 do bridge_action_scheduler_tick(now + offset, gate_fetch, gate_execute, gate_resolve)
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
    testing.expect_value(t, gate_fetch_calls, calls)
}

@(test)
test_action_gate_prelaunch_revalidation_passes_enabled_owner :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    gate_fetch_status = 304
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 1)
    testing.expect_value(t, gate_fetch_calls, 1)
    testing.expect_value(t, gate_mints, 1)
    testing.expect_value(t, gate_executes, 1)
    testing.expect(t, !bridge_action_sched_state.suspended)
}

@(test)
test_action_gate_changed_or_failed_revalidation_fails_closed :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    gate_fetch_status = 500
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 0)
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
    testing.expect_value(t, bridge_action_sched_state.synced_actions_version, -1)
    testing.expect_value(t, len(bridge_action_sched_state.queue), 1)
}

@(test)
test_action_gate_execute_denial_suspends_cached_queue :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    gate_fetch_status = 304
    gate_execute_status = 403 // disabled between revalidation and execute
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 0)
    testing.expect_value(t, gate_executes, 1)
    testing.expect(t, bridge_action_sched_state.suspended)
    testing.expect_value(t, len(bridge_action_sched_state.queue), 0)
}

@(test)
test_action_gate_heartbeat_token_change_stops_cached_fires :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    // Hub folds the disable into the epoch: cached snapshot is no longer fresh, and the
    // resync answers 403, so nothing launches even before any revalidation.
    bridge_action_scheduler_notify_snapshot("e.off", 0, now)
    testing.expect(t, !bridge_action_scheduler_fresh_locked(now))
    gate_fetch_status = 403
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 0)
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
    testing.expect(t, bridge_action_sched_state.suspended)
}

@(test)
test_action_gate_reenable_restores_without_replaying_missed_fires :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    now := bridge_runtime_now_ms()
    gate_fresh_state(now)
    gate_fetch_status = 403
    bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve)
    testing.expect(t, bridge_action_sched_state.suspended)

    // Re-enable after both slots fell due: the hub still holds the old target_run_at.
    later := now + 600_000
    since := action_scheduler_format_rfc3339_utc(later - 1000) // temp arena
    missed := action_scheduler_format_rfc3339_utc(now - 1000)
    gate_fetch_body = strings.concatenate({
        `{"snapshot":{"epoch":"e.on2","revision":0,"etag":"W/\"e.on2:0\"","eligible_since":"`, since, `"},"data":[`,
        `{"id":"act_gate","target_agent_id":"agent","state":"active","interval":"60s","target_run_at":"`, missed, `","blackout_dates":[]},`,
        `{"id":"act_once","target_agent_id":"agent","state":"active","target_run_at":"`, missed, `","blackout_dates":[]}]}`,
    })
    defer delete(gate_fetch_body)
    gate_fetch_status = 200
    bridge_action_scheduler_notify_snapshot("e.on2", 0, later)
    testing.expect_value(t, bridge_action_scheduler_tick(later, gate_fetch, gate_execute, gate_resolve), 0)
    s := &bridge_action_sched_state
    testing.expect(t, !s.suspended, "re-enable installs the snapshot")
    // Definition restored and rolled to the next future slot; the missed one-shot dropped.
    testing.expect_value(t, len(s.queue), 1)
    if len(s.queue) == 1 {
        testing.expect_value(t, s.queue[0].id, "act_gate")
        testing.expect(t, s.queue[0].target_run_at_ms > later, "missed interval slot rolled forward")
    }
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
}

// REQ-EXP-GATE-4: eligible_since is floored to the Hub's one-second clock. A slot that
// fell due inside a sub-second disable (same second as the re-enable) is still a missed
// fire and must roll forward, not stay due for the next tick.
@(test)
test_action_gate_reenable_skips_fire_missed_within_eligible_second :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    base := bridge_runtime_now_ms()
    gate_fresh_state(base)
    gate_fetch_status = 403
    bridge_action_scheduler_tick(base, gate_fetch, gate_execute, gate_resolve)
    testing.expect(t, bridge_action_sched_state.suspended)

    second := (base / 1000 + 120) * 1000 // whole second, as the Hub stamps updated_at
    since := action_scheduler_format_rfc3339_utc(second) // temp arena
    missed_ms := second + 400 // fell due while disabled, inside the re-enable second
    missed := action_scheduler_format_rfc3339_utc(missed_ms)
    now := second + 900
    gate_fetch_body = strings.concatenate({
        `{"snapshot":{"epoch":"e.on3","revision":0,"etag":"W/\"e.on3:0\"","eligible_since":"`, since, `"},"data":[`,
        `{"id":"act_gate","target_agent_id":"agent","state":"active","interval":"60s","target_run_at":"`, missed, `","blackout_dates":[]}]}`,
    })
    defer delete(gate_fetch_body)
    gate_fetch_status = 200
    bridge_action_scheduler_notify_snapshot("e.on3", 0, now)
    testing.expect_value(t, bridge_action_scheduler_tick(now, gate_fetch, gate_execute, gate_resolve), 0)
    s := &bridge_action_sched_state
    testing.expect(t, !s.suspended, "re-enable installs the snapshot")
    testing.expect_value(t, len(s.queue), 1)
    if len(s.queue) == 1 do testing.expect(t, s.queue[0].target_run_at_ms > now, "slot missed inside the eligible second rolled forward")
    testing.expect_value(t, gate_mints, 0)
    testing.expect_value(t, gate_executes, 0)
}
