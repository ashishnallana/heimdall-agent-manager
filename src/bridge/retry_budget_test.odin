package main
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import http "odin_test:lib/http_client"

@(test)
retry_budget_duplicate_storm_is_finite :: proc(t: ^testing.T) {
    b: Bridge_Operation_Budget
    count := 0
    for ms: i64 = 1000; ms < 3_601_000; ms += 1000 {
        if bridge_operation_reserve(&b, ms) {
            count += 1
            testing.expect(t, !bridge_operation_reserve(&b, ms))
            bridge_operation_finish(&b, ms, false, contracts.wire_error(.Bridge_Timeout))
        }
    }
    testing.expect_value(t, count, 6)
    testing.expect_value(t, b.state, Bridge_Operation_State.Exhausted)
}

@(test)
retry_budget_typed_authority_and_server_floor :: proc(t: ^testing.T) {
    for class in contracts.Bridge_Error_Class {
        b: Bridge_Operation_Budget
        testing.expect(t, bridge_operation_reserve(&b, 1000))
        err := contracts.wire_error(.Bridge_Busy, retry_after_ms = 120_000)
        err.class = class
        bridge_operation_finish(&b, 1000, false, err)
        testing.expect_value(t, b.state, Bridge_Operation_State.Exhausted if class == .retriable else Bridge_Operation_State.Waiting_Repair)
        testing.expect(t, !bridge_operation_reserve(&b, 200000))
    }
    err := bridge_operation_http_error(http.Response{status = 503, body = `{"error":{"code":"provider_unavailable","class":"recoverable"}}`}, true)
    testing.expect_value(t, err.class, contracts.Bridge_Error_Class.recoverable)
}

@(test)
retry_budget_monotonic_deadline_and_backward_wall :: proc(t: ^testing.T) {
    start := time.Tick{_nsec = 1}
    after := time.Tick{_nsec = 1 + i64(121*time.Second)}
    b: Bridge_Operation_Budget
    testing.expect(t, bridge_operation_reserve(&b, 1000, tick = start))
    bridge_operation_finish(&b, 1000, false, contracts.wire_error(.Bridge_Timeout), tick = after)
    testing.expect_value(t, b.state, Bridge_Operation_State.Exhausted)
    b = {}
    testing.expect(t, bridge_operation_reserve(&b, 1000, tick = start))
    bridge_operation_finish(&b, 999, false, contracts.wire_error(.Bridge_Timeout), tick = start)
    testing.expect_value(t, b.state, Bridge_Operation_State.Waiting_Repair)
}
