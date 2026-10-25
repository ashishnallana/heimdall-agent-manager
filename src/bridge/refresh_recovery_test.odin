package main
import "core:testing"
import http "odin_test:lib/http_client"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "core:sync"
import contracts "odin_test:contracts"

refresh_test_exchanges: int
refresh_test_commits: int
refresh_test_exchange :: proc(api, token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    refresh_test_exchanges += 1
    return {access_token = "new-access", refresh_token = "new-refresh"}, true, {}, false
}
refresh_test_save :: proc(path: string, pending: Bridge_Refresh_Pending) -> bool { return true }
refresh_test_commit :: proc(path, refresh_path, api, bridge_id: string, cred: Bridge_Enroll_Credential) -> bool {
    refresh_test_commits += 1
    return false
}
@(test)
refresh_local_persistence_failure_never_reexchanges_spent_token :: proc(t: ^testing.T) {
    refresh_test_exchanges = 0; refresh_test_commits = 0
    recovery: Bridge_Refresh_Recovery
    budget: Bridge_Operation_Budget
    for now: i64 = 1000; now < 3_601_000; now += 1000 {
        if !bridge_operation_reserve(&budget, now) do continue
        ok, err := bridge_refresh_recovery_step(&recovery, "pending", "access", "refresh", "api", "bridge", "old-refresh", budget, 1000, refresh_test_exchange, refresh_test_save, refresh_test_commit)
        bridge_operation_finish(&budget, now, ok, err, base_ms = 5000)
    }
    testing.expect_value(t, refresh_test_exchanges, 1)
    testing.expect_value(t, refresh_test_commits, 6)
    testing.expect_value(t, budget.state, Bridge_Operation_State.Exhausted)
}

@(test)
refresh_pending_pair_survives_disk_restart_and_preserves_parent_budget :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    path := fmt.tprintf("%s/pending-refresh-%d/rotation.json", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    pending := Bridge_Refresh_Pending{version=1,key="refresh:api:b",api_base="api",bridge_id="b",first_ms=1000,
        credential={access_token="hba_new.secret",refresh_token="hbf_new.secret"}}
    testing.expect(t, bridge_refresh_pending_save(path, pending))
    recovered, valid := bridge_refresh_pending_load(path, pending.key, "api", "b")
    testing.expect(t, valid && recovered.has_pair && recovered.pending.credential.refresh_token == "hbf_new.secret")
    _, wrong_scope := bridge_refresh_pending_load(path, pending.key, "other", "b")
    testing.expect(t, !wrong_scope)
    bridge_retry_journal = {}
    b, reserved := bridge_retry_reserve(pending.key, 1000)
    testing.expect(t, reserved)
    bridge_retry_finish(pending.key, 1001, false, contracts.wire_error(.Bridge_Timeout), base_ms=5000)
    // Recreate the restart fence after a later reservation; the durable pair
    // permits LOCAL commit recovery, preserving count and original deadline.
    sync.mutex_lock(&bridge_retry_journal_mutex)
    slot := bridge_retry_journal_get_locked(pending.key)
    slot.state = .Waiting_Repair
    sync.mutex_unlock(&bridge_retry_journal_mutex)
    testing.expect(t, bridge_retry_resume_pending_rotation(pending.key, pending.first_ms))
    resumed := bridge_retry_status(pending.key)
    testing.expect_value(t, resumed.attempts, b.attempts)
    testing.expect_value(t, resumed.deadline_ms, b.deadline_ms)
    _ = os.remove(path)
}

refresh_test_sent: bool
refresh_test_unknown_exchanges: int
refresh_test_transport_failure :: proc(api, token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    refresh_test_unknown_exchanges += 1
    return bridge_refresh_response_classify(http.Response{may_have_sent=refresh_test_sent}, false, "http://localhost")
}

// A lost or unusable reply is an UNKNOWN outcome: the hub may have rotated. It used
// to park the receipt as Waiting_Repair after ONE attempt, persisted, so every later
// start stopped renewal without sending anything (incident, 2026-10-25). It is now
// retried, bounded, with the same request id.
@(test)
refresh_unknown_outcome_retries_instead_of_parking :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    for sent in ([]bool{false, true}) {
        key := "refresh:unknown:sent" if sent else "refresh:unknown:unsent"
        recovery: Bridge_Refresh_Recovery
        recovery.request_id = "rrq_0123456789abcdef"
        refresh_test_unknown_exchanges = 0; refresh_test_sent = sent
        for now: i64 = 1000; now < 3_601_000; now += 1000 {
            budget, reserved := bridge_retry_reserve(key, now)
            if !reserved do continue
            ok, err := bridge_refresh_recovery_step(&recovery, "pending", "access", "refresh", "http://localhost", "b", "old", budget, 1000, refresh_test_transport_failure, refresh_test_save, refresh_test_commit)
            bridge_retry_finish(key, now, ok, err)
        }
        testing.expect_value(t, refresh_test_unknown_exchanges, 6)
        final := bridge_retry_status(key)
        testing.expect_value(t, final.state, Bridge_Operation_State.Exhausted)
        // ...and an exhausted retriable budget reopens (restart / after the pause).
        testing.expect(t, bridge_refresh_terminal_is_retriable(final))
        testing.expect(t, bridge_retry_reopen_retriable(key))
        _, reserved := bridge_retry_reserve(key, 4_000_000)
        testing.expect(t, reserved, "a fresh bounded budget after reopening")
    }
}

refresh_test_request_ids: [dynamic]string
refresh_test_lost_exchanges: int
refresh_test_lost_then_ok :: proc(api, token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    refresh_test_lost_exchanges += 1
    append(&refresh_test_request_ids, request_id)
    if refresh_test_lost_exchanges == 1 {
        // The hub rotated, but the reply never arrived intact.
        return bridge_refresh_response_classify(http.Response{status = 200, body = "{\"data\":", may_have_sent = true}, true, "http://localhost")
    }
    return {access_token = "hba_btk_2.new", refresh_token = "hbf_btk_3.new", expires_in = 3600}, true, {}, false
}
refresh_test_commit_ok :: proc(path, refresh_path, api, bridge_id: string, cred: Bridge_Enroll_Credential) -> bool { return true }

@(test)
refresh_lost_reply_is_recovered_by_a_retry_with_the_same_request_id :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    refresh_test_lost_exchanges = 0
    refresh_test_request_ids = make([dynamic]string)
    defer delete(refresh_test_request_ids)
    recovery: Bridge_Refresh_Recovery
    recovery.request_id = "rrq_0123456789abcdef"
    done := false
    for now: i64 = 1000; now < 200_000 && !done; now += 1000 {
        budget, reserved := bridge_retry_reserve("refresh:lost", now)
        if !reserved do continue
        ok, err := bridge_refresh_recovery_step(&recovery, "pending", "access", "refresh", "http://localhost", "b", "hbf_btk_1.old", budget, 1000, refresh_test_lost_then_ok, refresh_test_save, refresh_test_commit_ok)
        if !ok do testing.expect_value(t, err.code, contracts.Error_Code.Internal_Error) // a protocol error, not Bridge_Timeout
        bridge_retry_finish("refresh:lost", now, ok, err)
        done = ok
    }
    testing.expect(t, done, "the retry recovered the rotation without re-enrollment")
    testing.expect_value(t, refresh_test_lost_exchanges, 2)
    testing.expect(t, len(refresh_test_request_ids) == 2 && refresh_test_request_ids[0] == refresh_test_request_ids[1] && refresh_test_request_ids[0] != "")
    testing.expect_value(t, bridge_retry_status("refresh:lost").state, Bridge_Operation_State.Succeeded)
    testing.expect_value(t, recovery.pending.credential.refresh_token, "hbf_btk_3.new")
}

// The incident's persisted receipt: Waiting_Repair, Bridge_Timeout, retriable,
// attempts=1, and a crash-converted In_Flight. A restart must get a fresh budget
// for both; a refused (Unauthenticated) receipt must stay stopped.
@(test)
refresh_restart_after_retriable_terminal_receipt_retries :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    dir := fmt.tprintf("%s/.cache/heimdall-tests/refresh-journal-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(dir)
    path := fmt.tprintf("%s/retry-journal-v1.json", dir)
    journal := `{"version":1,"receipts":[` +
        `{"key":"refresh:https://hub:brg_a","budget":{"state":4,"attempts":1,"code":8,"class":0,"first_ms":1000,"deadline_ms":121000,"last_wall_ms":1000,"next_ms":0},"target_instance_id":""},` +
        `{"key":"refresh:https://hub:brg_b","budget":{"state":1,"attempts":1,"code":0,"class":0,"first_ms":1000,"deadline_ms":121000,"last_wall_ms":1000,"next_ms":0},"target_instance_id":""},` +
        `{"key":"refresh:https://hub:brg_c","budget":{"state":4,"attempts":1,"code":1,"class":1,"first_ms":1000,"deadline_ms":121000,"last_wall_ms":1000,"next_ms":0},"target_instance_id":""}]}`
    testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)journal))
    j: Bridge_Retry_Journal
    if !testing.expect(t, bridge_retry_journal_load(&j, path), "incident journal loads") do return
    // Merge (unique keys) rather than replace: other tests share the global journal.
    sync.mutex_lock(&bridge_retry_journal_mutex)
    if !bridge_retry_journal.loaded { bridge_retry_journal.loaded = true; bridge_retry_journal.version = 1 }
    for r in j.receipts do append(&bridge_retry_journal.receipts, r)
    sync.mutex_unlock(&bridge_retry_journal_mutex)
    a := bridge_retry_status("refresh:https://hub:brg_a")
    testing.expect_value(t, a.state, Bridge_Operation_State.Waiting_Repair)
    testing.expect_value(t, a.class, contracts.Bridge_Error_Class.retriable)
    testing.expect_value(t, bridge_retry_status("refresh:https://hub:brg_b").state, Bridge_Operation_State.Waiting_Repair)
    testing.expect(t, bridge_retry_reopen_retriable("refresh:https://hub:brg_a"), "a retriable Waiting_Repair reopens")
    testing.expect(t, bridge_retry_reopen_retriable("refresh:https://hub:brg_b"), "a crash-interrupted attempt reopens")
    testing.expect(t, !bridge_retry_reopen_retriable("refresh:https://hub:brg_c"), "a refused refresh token stays stopped")
    _, reserved := bridge_retry_reserve("refresh:https://hub:brg_a", 5000)
    testing.expect(t, reserved, "renewal sends again after restart")
    testing.expect(t, !bridge_retry_reopen_retriable("sync:https://hub:brg_a"), "only refresh receipts are reopened")
}

@(test)
refresh_request_id_is_durable_and_scoped :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    dir := fmt.tprintf("%s/.cache/heimdall-tests/refresh-request-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(dir)
    path := bridge_refresh_request_path(fmt.tprintf("%s/credential", dir))
    first, ok1 := bridge_refresh_request_ensure(path, "refresh:h:b", "h", "b")
    again, ok2 := bridge_refresh_request_ensure(path, "refresh:h:b", "h", "b")
    testing.expect(t, ok1 && ok2 && first == again && bridge_refresh_request_id_valid(first), "a restart reuses the rotation's request id")
    other, ok3 := bridge_refresh_request_ensure(path, "refresh:h:other", "h", "other")
    testing.expect(t, ok3 && other != first, "another bridge's record is not reused")
}

@(test)
refresh_200_with_an_unusable_body_is_a_protocol_error_not_a_timeout :: proc(t: ^testing.T) {
    for body in ([]string{"{}", "", "{\"data\":", "<html>"}) {
        _, ok, err, unknown := bridge_refresh_response_classify(http.Response{status = 200, body = body}, true, "http://localhost")
        testing.expect(t, !ok && unknown && err.class == .retriable)
        testing.expect(t, err.code != .Bridge_Timeout, "a 200 the bridge cannot use is reported as what it is")
        testing.expect_value(t, err.cause, "refresh_reply_undecodable")
    }
    good := `{"data":{"access_token":"hba_btk_1.s","refresh_token":"hbf_btk_2.s","bridge_id":"brg_x","token_type":"Bearer","expires_in":3600,"refresh_expires_in":2592000},"meta":{"request_id":"r","server_time":""}}`
    cred, ok, _, _ := bridge_refresh_response_classify(http.Response{status = 200, body = good}, true, "http://localhost")
    defer { delete(cred.bridge_id); delete(cred.access_token); delete(cred.refresh_token) }
    testing.expect(t, ok && cred.access_token == "hba_btk_1.s" && cred.refresh_token == "hbf_btk_2.s" && cred.expires_in == 3600)
}
