package main
import "core:testing"
import "core:fmt"
import http "odin_test:lib/http_client"
import "base:runtime"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

@(test)
action_snapshot_candidate_rejects_partial_or_duplicate_rows :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    valid := `{"snapshot":{"epoch":"e","revision":0,"etag":"W/\"e:0\""},"data":[{"id":"a","target_instance_id":"inst","state":"active","target_run_at":"2026-10-24T01:00:00Z","blackout_dates":[]}]}`
    metadata, queue, ok := action_snapshot_candidate(valid, 1000)
    testing.expect(t, ok)
    if !ok do return
    defer { for &q in queue do action_queue_item_free(&q); delete(queue) }
    testing.expect_value(t, metadata.revision, i64(0))
    testing.expect_value(t, len(queue), 1)
    clone := action_queue_item_clone(queue[0])
    defer action_queue_item_free(&clone)
    testing.expect_value(t, clone.target_instance_id, "inst")
    cases := []string{
        `{"snapshot":{"epoch":"e","revision":0,"etag":"W/\"e:0\""},"data":[7]}`,
        `{"snapshot":{"epoch":"e","revision":0,"etag":"W/\"e:0\""},"data":[{"id":"a","state":"active","target_instance_id":"inst","target_run_at":"bad"}]}`,
        valid[:len(valid)-1],
        `{"snapshot":{"epoch":"e","revision":0,"etag":"wrong"},"data":[]}`,
        `{"snapshot":{"epoch":"e","revision":0,"etag":"W/\"e:0\""}}`,
    }
    for body in cases {
        _, _, parsed := action_snapshot_candidate(body, 1000)
        testing.expect(t, !parsed)
    }
}

@(test)
action_snapshot_heartbeat_freshness_and_failed_budget_survive_reconnect :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    bridge_action_scheduler_init()
    bridge_retry_journal = {}
    s := &bridge_action_sched_state
    s.installed_epoch = strings.clone("new")
    s.installed_revision = 0
    bridge_action_scheduler_notify_snapshot("new", 0, 1000)
    testing.expect(t, bridge_action_scheduler_fresh_locked(1000))
    bridge_action_scheduler_notify_snapshot("new", 1, 2000)
    testing.expect(t, !bridge_action_scheduler_fresh_locked(2000))
    bridge_retry_reserve("sync:test", 1000)
    bridge_retry_finish("sync:test", 1000, false, contracts.wire_error(.Unauthenticated))
    for n in 0..<100 {
        bridge_action_scheduler_connection_changed()
        bridge_action_scheduler_notify_snapshot("new", i64(n), 3000)
        bridge_retry_reopen_success("sync:test")
        _, granted := bridge_retry_reserve("sync:test", 4000)
        testing.expect(t, !granted)
    }
    testing.expect_value(t, bridge_retry_status("sync:test").attempts, 1)
}

snapshot_test_calls: int
snapshot_test_status: int
snapshot_test_invalidations: bool
snapshot_test_fetch :: proc(method, base_url, path, body: string, headers: []http.Header, timeout_ms: int) -> (http.Response, bool) {
    snapshot_test_calls += 1
    if snapshot_test_status == 401 do return {status = 401, body = strings.clone(`{"error":{"code":"unauthenticated","class":"recoverable"}}`)}, true
    for h in headers {
        if h.name == "If-None-Match" && !snapshot_test_invalidations do return {status = 304}, true
    }
    if snapshot_test_invalidations do bridge_action_scheduler_notify_snapshot("e", 1, bridge_runtime_now_ms())
    return {status = 200, body = strings.clone(`{"snapshot":{"epoch":"e","revision":0,"etag":"W/\"e:0\""},"data":[]}`)}, true
}
@(test)
action_sync_idle_day_has_only_initial_and_daily_get :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    bridge_action_scheduler_init(); bridge_retry_journal = {}
    snapshot_test_calls = 0; snapshot_test_status = 200; snapshot_test_invalidations = false
    first := bridge_runtime_now_ms()
    bridge_action_scheduler_notify_snapshot("e", 0, first)
    for offset: i64 = 0; offset <= ACTION_SCHEDULER_RECONCILE_INTERVAL_MS; offset += 1000 {
        if offset % 45_000 == 0 do bridge_action_scheduler_notify_snapshot("e", 0, first + offset)
        bridge_action_scheduler_tick(first + offset, snapshot_test_fetch)
    }
    testing.expect_value(t, snapshot_test_calls, 2)
}
@(test)
action_sync_permanent_error_survives_invalidation_storm_and_operator_resume :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    bridge_action_scheduler_init(); bridge_retry_journal = {}
    snapshot_test_calls = 0; snapshot_test_status = 401
    now := bridge_runtime_now_ms()
    for offset: i64 = 0; offset < 3_600_000; offset += 1000 {
        bridge_action_scheduler_notify_snapshot("e", offset, now+offset)
        bridge_action_scheduler_tick(now+offset, snapshot_test_fetch)
    }
    testing.expect_value(t, snapshot_test_calls, 1)
    key := bridge_action_scheduler_sync_key()
    defer delete(key)
    testing.expect_value(t, bridge_retry_status(key).attempts, 1)
    testing.expect(t, bridge_retry_operator_resume_sync(key))
    testing.expect(t, !bridge_retry_operator_resume_sync("slot:unsafe"))
}
@(test)
action_sync_fetch_keeps_newer_wanted_revision_pending :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    bridge_action_scheduler_init(); bridge_retry_journal = {}
    snapshot_test_calls = 0; snapshot_test_status = 200; snapshot_test_invalidations = true
    defer snapshot_test_invalidations = false
    now := bridge_runtime_now_ms()
    bridge_action_scheduler_notify_snapshot("e", 0, now)
    testing.expect(t, bridge_action_scheduler_sync(snapshot_test_fetch))
    testing.expect_value(t, bridge_action_sched_state.installed_revision, i64(0))
    testing.expect_value(t, bridge_action_sched_state.wanted_revision, i64(1))
    testing.expect(t, !bridge_action_scheduler_fresh_locked(now))
}
slot_test_executes: int
slot_test_mints: int
slot_test_execute :: proc(action_id, next_target_run_at: string, instance_id: string = "", last_spawned_instance_id: string = "") -> (bool, int, string) {
    slot_test_executes += 1
    return false, 0, ""
}
slot_test_revalidate :: proc(fetch: Action_Scheduler_Fetch) -> bool { return true }
slot_test_resolve :: proc(due: Action_Queue_Item, now: i64) -> (string, bool) {
    slot_test_mints += 1
    return "chosen", true
}
@(test)
action_unknown_execute_cannot_repost_or_remint_after_lease_expiry :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&action_sched_test_mutex)
    defer sync.mutex_unlock(&action_sched_test_mutex)
    bridge_action_scheduler_init(); bridge_retry_journal = {}
    s := &bridge_action_sched_state
    now := bridge_runtime_now_ms()
    s.known_actions_version = 0; s.synced_actions_version = 0
    s.wanted_epoch = strings.clone("e"); s.installed_epoch = strings.clone("e")
    s.sync_state = .Succeeded; s.last_full_reconcile_ms = now
    append(&s.queue, action_queue_item_clone(Action_Queue_Item{id="slot-a",target_agent_id="agent",instance_strategy="fresh_per_run",state="active",target_run_at_ms=now-1000}))
    slot_test_executes = 0; slot_test_mints = 0
    for _ in 0..<100 {
        s.validated_ms = bridge_runtime_now_ms()
        if len(s.queue) > 0 { s.queue[0].leased_at_ms = 0; s.queue[0].in_flight = false }
        bridge_action_scheduler_tick(execute = slot_test_execute, resolve = slot_test_resolve, revalidate = slot_test_revalidate)
    }
    testing.expect_value(t, slot_test_executes, 1)
    testing.expect_value(t, slot_test_mints, 1)
    key := fmt.aprintf("slot:slot-a:%d", now-1000)
    defer delete(key)
    testing.expect_value(t, bridge_retry_status(key).state, Bridge_Operation_State.Waiting_Repair)
    for r in bridge_retry_journal.receipts do if r.key == key do testing.expect_value(t, r.target_instance_id, "chosen")
}
