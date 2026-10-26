package main

import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"

BRIDGE_OPERATION_ATTEMPTS :: 6
BRIDGE_OPERATION_DEADLINE_MS :: i64(120_000)
Bridge_Operation_State :: enum { Pending, In_Flight, Backoff, Succeeded, Waiting_Repair, Exhausted, Cancelled }
Bridge_Operation_Budget :: struct {
    state: Bridge_Operation_State,
    attempts: int,
    first_ms, deadline_ms, last_wall_ms, next_ms: i64,
    code: contracts.Error_Code,
    class: contracts.Bridge_Error_Class,
    // Process-local anchor; never restore a monotonic tick from another boot.
    clock_started: bool `json:"-"`,
    clock_tick: time.Tick `json:"-"`,
    clock_wall_ms: i64 `json:"-"`,

}

bridge_operation_terminal :: proc(b: Bridge_Operation_Budget) -> bool {
    return b.state == .Succeeded || b.state == .Waiting_Repair || b.state == .Exhausted || b.state == .Cancelled
}
bridge_operation_now :: proc(b: ^Bridge_Operation_Budget, wall_ms: i64, tick: time.Tick) -> i64 {
    current := tick
    if current == {} do current = time.tick_now()
    if !b.clock_started {
        b.clock_started = true; b.clock_tick = current; b.clock_wall_ms = wall_ms
    }
    return max(wall_ms, b.clock_wall_ms + i64(time.tick_diff(b.clock_tick, current) / time.Millisecond))
}
bridge_operation_reserve :: proc(b: ^Bridge_Operation_Budget, wall_ms: i64, duration_ms := BRIDGE_OPERATION_DEADLINE_MS, tick: time.Tick = {}) -> bool {
    if bridge_operation_terminal(b^) || b.state == .In_Flight do return false
    if wall_ms < b.last_wall_ms { b.state = .Waiting_Repair; return false }
    now := bridge_operation_now(b, wall_ms, tick)
    if b.first_ms == 0 {
        if now <= 0 || duration_ms <= 0 { b.state = .Waiting_Repair; return false }
        b.first_ms = now; b.deadline_ms = now + min(duration_ms, BRIDGE_OPERATION_DEADLINE_MS)
    }
    if now < b.last_wall_ms { b.state = .Waiting_Repair; return false }
    if now >= b.deadline_ms || b.attempts >= BRIDGE_OPERATION_ATTEMPTS { b.state = .Exhausted; return false }
    if now < b.next_ms do return false
    b.last_wall_ms = wall_ms
    b.attempts += 1
    b.state = .In_Flight
    return true
}
bridge_operation_finish :: proc(b: ^Bridge_Operation_Budget, wall_ms: i64, success: bool, err: contracts.Wire_Error, base_ms: i64 = 1000, jitter_seed: u64 = 0, tick: time.Tick = {}) {
    if b.state != .In_Flight do return
    if wall_ms < b.last_wall_ms { b.state = .Waiting_Repair; return }
    now := bridge_operation_now(b, wall_ms, tick)
    b.last_wall_ms = wall_ms
    b.code = err.code; b.class = err.class
    if success { b.state = .Succeeded; return }
    if err.class != .retriable { b.state = .Waiting_Repair; return }
    if b.attempts >= BRIDGE_OPERATION_ATTEMPTS || now >= b.deadline_ms { b.state = .Exhausted; return }
    delay := max(bridge_backoff_delay_ms({base_ms = base_ms, max_ms = 30_000, jitter_pct = 20}, b.attempts, jitter_seed), err.retry_after_ms)
    if delay >= b.deadline_ms - now { b.state = .Exhausted; return }
    b.next_ms = now + delay
    b.state = .Backoff
}
bridge_operation_timeout_ms :: proc(b: Bridge_Operation_Budget, wall_ms: i64, tick: time.Tick = {}) -> int {
    copy := b
    now := bridge_operation_now(&copy, wall_ms, tick)
    return int(max(0, min(10_000, b.deadline_ms - now)))
}
// Retain the hub's typed class, even when it differs from the HTTP status class.
// Strings from the error body remain caller-owned and are never journalled.
bridge_operation_http_error :: proc(resp: httpc.Response, ok: bool) -> contracts.Wire_Error {
    if ok {
        if err, found := contracts.wire_error_parse(httpc.text(resp), context.temp_allocator); found do return err
    }
    err := contracts.wire_error(.Bridge_Timeout)
    if ok {
        err = contracts.wire_error(.Internal_Error)
        err.class = contracts.bridge_error_http_class(resp.status)
        if resp.status == 401 do err.code = .Unauthenticated
        if resp.status == 403 do err.code = .Forbidden
        // Malformed successful responses are protocol failures with finite retry.
        if resp.status < 400 do err.class = .retriable
    }
    return err
}
bridge_operation_monotonic_finish_ms :: proc(start_ms: i64, started: time.Tick) -> i64 {
    return start_ms + i64(time.tick_since(started) / time.Millisecond)
}
