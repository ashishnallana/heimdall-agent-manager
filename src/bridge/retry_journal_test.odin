package main
import "core:testing"
import "core:strings"
import "core:os"
import "core:fmt"
import "core:time"
import contracts "odin_test:contracts"

@(test)
retry_atomic_write_windows_native_credential_path :: proc(t: ^testing.T) {
    when ODIN_OS == .Windows {
        dir := fmt.tprintf("%s/ham-credential-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
        defer os.remove(dir)
        path, _ := strings.replace_all(fmt.tprintf("%s/bridge-token.pending", dir), "/", "\\", context.temp_allocator)
        defer os.remove(path)
        testing.expect(t, bridge_write_secret_file(path, "hba_test.first"), "stage credential in a new directory")
        testing.expect(t, bridge_write_secret_file(path, "hba_test.second"), "replace staged credential atomically")
        data, err := os.read_entire_file(path, context.temp_allocator)
        testing.expect(t, err == nil && string(data) == "hba_test.second\n", "credential must round-trip")
        testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)))
    }
}

@(test)
retry_journal_disk_reservations_and_unsafe_crash_fence :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/retry-journal-%d/receipts.json", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    j := Bridge_Retry_Journal{version = 1, loaded = true}
    append(&j.receipts, Bridge_Retry_Receipt{key = "ready:launch", budget = {}})
    append(&j.receipts, Bridge_Retry_Receipt{key = "slot:action:time", budget = {}})
    append(&j.receipts, Bridge_Retry_Receipt{key = "refresh:family", budget = {}})
    for &r in j.receipts do testing.expect(t, bridge_operation_reserve(&r.budget, 1000))
    testing.expect(t, bridge_retry_journal_save(&j, path))
    restored: Bridge_Retry_Journal
    testing.expect(t, bridge_retry_journal_load(&restored, path))
    testing.expect_value(t, restored.receipts[0].budget.attempts, 1)
    testing.expect_value(t, restored.receipts[0].budget.state, Bridge_Operation_State.Backoff)
    testing.expect_value(t, restored.receipts[1].budget.state, Bridge_Operation_State.Waiting_Repair)
    testing.expect_value(t, restored.receipts[2].budget.state, Bridge_Operation_State.Waiting_Repair)
    testing.expect(t, !restored.receipts[0].budget.clock_started)
    testing.expect(t, !bridge_operation_reserve(&restored.receipts[0].budget, 999))
    testing.expect(t, os.write_entire_file_from_string(path, "{bad") == nil)
    corrupt: Bridge_Retry_Journal
    testing.expect(t, !bridge_retry_journal_load(&corrupt, path))
    testing.expect(t, corrupt.failed)
    _ = os.remove(path)
    _ = os.remove(strings.concatenate({path, ".initialized"}, context.temp_allocator))
}

@(test)
retry_journal_invalid_schema_and_write_failure_park :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/retry-journal-bad-%d/receipts.json", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    j := Bridge_Retry_Journal{version = 1, loaded = true}
    append(&j.receipts, Bridge_Retry_Receipt{key = "ready:bad", budget = {attempts = 2}})
    testing.expect(t, bridge_retry_journal_save(&j, path))
    restored: Bridge_Retry_Journal
    testing.expect(t, !bridge_retry_journal_load(&restored, path))
    testing.expect(t, !bridge_retry_journal_save(&j, "/dev/null/receipts"))
    _ = os.remove(path)
    _ = os.remove(strings.concatenate({path, ".initialized"}, context.temp_allocator))
}

journal_test_failed_flush :: proc() -> bool { return false }
@(test)
retry_reservation_persistence_failure_forbids_io_and_missing_journal_is_fenced :: proc(t: ^testing.T) {
    bridge_retry_journal = {}
    requests := 0
    for _ in 0..<100 {
        if _, reserved := bridge_retry_reserve("ready:persist-fail", 1000, flush = journal_test_failed_flush); reserved do requests += 1
    }
    testing.expect_value(t, requests, 0)
    testing.expect_value(t, bridge_retry_status("ready:persist-fail").state, Bridge_Operation_State.Waiting_Repair)
    path := fmt.tprintf("%s/retry-missing-%d/journal.json", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    j := Bridge_Retry_Journal{version=1}
    testing.expect(t, bridge_retry_journal_save(&j, path))
    _ = os.remove(path)
    recovered: Bridge_Retry_Journal
    testing.expect(t, !bridge_retry_journal_load(&recovered, path))
    _ = os.remove(strings.concatenate({path, ".initialized"}, context.temp_allocator))
}
