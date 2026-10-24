package main
import "core:testing"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "core:sync"
import contracts "odin_test:contracts"

refresh_test_exchanges: int
refresh_test_commits: int
refresh_test_exchange :: proc(api, token: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error) {
    refresh_test_exchanges += 1
    return {access_token = "new-access", refresh_token = "new-refresh"}, true, {}
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
