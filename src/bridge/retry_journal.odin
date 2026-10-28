package main

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

BRIDGE_RETRY_JOURNAL_CAP :: 4096
BRIDGE_RETRY_JOURNAL_MAX_BYTES :: 2 * 1024 * 1024
Bridge_Retry_Receipt :: struct { key: string, budget: Bridge_Operation_Budget, target_instance_id: string }
// Disk schema uses integers because Odin JSON does not marshal enum fields.
Bridge_Retry_Disk_Budget :: struct {
    state, attempts, code, class: int,
    first_ms, deadline_ms, last_wall_ms, next_ms: i64,
}
Bridge_Retry_Disk_Receipt :: struct { key: string, budget: Bridge_Retry_Disk_Budget, target_instance_id: string }
Bridge_Retry_Disk :: struct { version: int, receipts: [dynamic]Bridge_Retry_Disk_Receipt }
Bridge_Retry_Journal :: struct {
    version: int,
    receipts: [dynamic]Bridge_Retry_Receipt,
    failed: bool,
    loaded: bool,
}
bridge_retry_journal_mutex: sync.Mutex
bridge_retry_journal: Bridge_Retry_Journal

bridge_retry_journal_path :: proc() -> string {
    tokens := bridge_agent_token_store_path()
    defer delete(tokens)
    return strings.concatenate({tokens[:strings.last_index_byte(tokens, '/')], "/retry-journal-v1.json"})
}
bridge_retry_journal_load :: proc(j: ^Bridge_Retry_Journal, path: string) -> bool {
    context.allocator = runtime.heap_allocator()
    j.loaded = true; j.version = 1
    if !os.exists(path) {
        if os.exists(strings.concatenate({path, ".initialized"}, context.temp_allocator)) { j.failed = true; return false }
        return true
    }
    info, stat_err := os.stat(path, context.temp_allocator)
    forbidden := os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
    // Windows has no POSIX mode bits: os.stat reports every file as
    // read/write-all, so the group/other check would reject every journal.
    when ODIN_OS == .Windows do forbidden = {}
    if stat_err != nil || info.type != .Regular || info.size > BRIDGE_RETRY_JOURNAL_MAX_BYTES || info.mode & forbidden != {} {
        j.failed = true; return false
    }
    raw, read_err := os.read_entire_file(path, context.allocator)
    if read_err != nil { j.failed = true; return false }
    defer delete(raw)
    disk: Bridge_Retry_Disk
    if json.unmarshal(raw, &disk) != nil || disk.version != 1 || len(disk.receipts) > BRIDGE_RETRY_JOURNAL_CAP {
        j.failed = true; return false
    }
    for r in disk.receipts {
        b := r.budget
        if b.state < 0 || b.state > int(Bridge_Operation_State.Cancelled) ||
           b.code < 0 || b.code > int(max(contracts.Error_Code)) ||
           b.class < 0 || b.class > int(max(contracts.Bridge_Error_Class)) {
            j.failed = true; return false
        }
        append(&j.receipts, Bridge_Retry_Receipt{key = r.key, target_instance_id = r.target_instance_id, budget = {
            state = Bridge_Operation_State(b.state), attempts = b.attempts,
            first_ms = b.first_ms, deadline_ms = b.deadline_ms, last_wall_ms = b.last_wall_ms, next_ms = b.next_ms,
            code = contracts.Error_Code(b.code), class = contracts.Bridge_Error_Class(b.class),
        }})
    }
    j.loaded = true
    // Persisted flags never override validation; a corrupt failure fence parks.
    if j.failed do return false
    for &r, i in j.receipts {
        b := &r.budget
        if r.key == "" || len(r.key) > 512 || b.first_ms < 0 || b.last_wall_ms < 0 ||
            b.state < .Pending || b.state > .Cancelled || b.next_ms < 0 ||
            (b.attempts > 0 && (b.first_ms == 0 || b.last_wall_ms < b.first_ms)) ||
            (b.first_ms == 0 && (b.deadline_ms != 0 || b.attempts != 0 || b.state != .Pending)) ||
            b.attempts < 0 || b.attempts > BRIDGE_OPERATION_ATTEMPTS ||
            (b.first_ms > 0 && (b.deadline_ms <= b.first_ms || b.deadline_ms - b.first_ms > BRIDGE_OPERATION_DEADLINE_MS)) {
            j.failed = true; return false
        }
        for prior in j.receipts[:i] do if prior.key == r.key { j.failed = true; return false }
        // Reservation survived a crash. Idempotent callers may consume only
        // remaining attempts; unsafe side effects use a terminal receipt instead.
        if b.state == .In_Flight {
            if strings.has_prefix(r.key, "slot:") || strings.has_prefix(r.key, "refresh:") { b.state = .Waiting_Repair }
            else { b.state = .Backoff }
        }
    }
    return true
}
bridge_retry_journal_save :: proc(j: ^Bridge_Retry_Journal, path: string) -> bool {
    if j.failed || len(j.receipts) > BRIDGE_RETRY_JOURNAL_CAP do return false
    disk := Bridge_Retry_Disk{version = 1, receipts = make([dynamic]Bridge_Retry_Disk_Receipt, context.temp_allocator)}
    for r in j.receipts {
        b := r.budget
        append(&disk.receipts, Bridge_Retry_Disk_Receipt{key = r.key, target_instance_id = r.target_instance_id, budget = {
            state = int(b.state), attempts = b.attempts, code = int(b.code), class = int(b.class),
            first_ms = b.first_ms, deadline_ms = b.deadline_ms, last_wall_ms = b.last_wall_ms, next_ms = b.next_ms,
        }})
    }
    bytes, err := json.marshal(disk, allocator = context.temp_allocator)
    if err != nil || len(bytes) > BRIDGE_RETRY_JOURNAL_MAX_BYTES do return false
    if !bridge_retry_atomic_write(path, bytes) do return false
    marker := strings.concatenate({path, ".initialized"}, context.temp_allocator)
    if !os.exists(marker) && !bridge_retry_atomic_write(marker, []byte{'1'}) do return false
    return true
}
bridge_retry_atomic_write :: proc(path: string, bytes: []byte) -> bool {
    slash := strings.last_index_byte(path, '/')
    when ODIN_OS == .Windows do slash = max(slash, strings.last_index_byte(path, '\\'))
    if slash <= 0 do return false
    dir := path[:slash]
    if mk := bridge_make_directory_all(dir); mk != nil && !os.exists(dir) do return false
    // On Windows os.chmod opens its target for writing, which fails for a
    // directory, and POSIX mode bits do not apply there anyway.
    when ODIN_OS != .Windows {
        if os.chmod(dir, {.Read_User, .Write_User, .Execute_User}) != nil do return false
    }
    tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
    _ = os.remove(tmp)
    f, open_err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
    if open_err != nil do return false
    n, write_err := os.write(f, bytes)
    sync_err := os.sync(f)
    _ = os.close(f)
    if write_err != nil || n != len(bytes) || sync_err != nil { _ = os.remove(tmp); return false }
    if os.rename(tmp, path) != nil { _ = os.remove(tmp); return false }
    // Flush the containing directory too: reservation must survive power loss.
    when ODIN_OS != .Windows {
        d, open_dir_err := os.open(dir, {.Read})
        if open_dir_err != nil do return false
        dir_sync_err := os.sync(d)
        _ = os.close(d)
        if dir_sync_err != nil do return false
    }
    return true
}
bridge_retry_journal_get_locked :: proc(key: string) -> ^Bridge_Operation_Budget {
    context.allocator = runtime.heap_allocator()
    j := &bridge_retry_journal
    if key == "" || len(key) > 512 do return nil
    when ODIN_TEST {
        // Existing pure runtime fixtures never write real bridge state. Explicit
        // journal tests exercise file load/save with their own isolated path.
        if !j.loaded { j.loaded = true; j.version = 1 }
    } else {
        if !j.loaded {
            path := bridge_retry_journal_path(); defer delete(path)
            if !bridge_retry_journal_load(j, path) do return nil
        }
    }
    if j.failed do return nil
    for &r in j.receipts do if r.key == key do return &r.budget
    if len(j.receipts) >= BRIDGE_RETRY_JOURNAL_CAP do return nil
    append(&j.receipts, Bridge_Retry_Receipt{key = strings.clone(key)})
    return &j.receipts[len(j.receipts)-1].budget
}
bridge_retry_journal_flush_locked :: proc() -> bool {
    when ODIN_TEST { return !bridge_retry_journal.failed }
    else {
        path := bridge_retry_journal_path(); defer delete(path)
        if !bridge_retry_journal_save(&bridge_retry_journal, path) { bridge_retry_journal.failed = true; return false }
        return true
    }
}
bridge_retry_reserve :: proc(key: string, now: i64, duration_ms := BRIDGE_OPERATION_DEADLINE_MS, flush := bridge_retry_journal_flush_locked) -> (Bridge_Operation_Budget, bool) {
    sync.mutex_lock(&bridge_retry_journal_mutex); defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil do return {state = .Waiting_Repair}, false
    previous := b^
    reserved := bridge_operation_reserve(b, now, duration_ms)
    // Persist transitions only; idle ticks/duplicates produce zero local writes.
    if b^ != previous && !flush() {
        b.state = .Waiting_Repair; return b^, false
    }
    return b^, reserved
}
bridge_retry_finish :: proc(key: string, now: i64, success: bool, err: contracts.Wire_Error, base_ms: i64 = 1000, jitter_seed: u64 = 0, park_on_failure := false) -> Bridge_Operation_Budget {
    sync.mutex_lock(&bridge_retry_journal_mutex); defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil do return {state = .Waiting_Repair}
    previous := b.state
    seed := jitter_seed
    when !ODIN_TEST { if seed == 0 do seed = rand.uint64() }
    bridge_operation_finish(b, now, success, err, base_ms, seed)
    if !success && park_on_failure do b.state = .Waiting_Repair
    if previous != b.state && bridge_operation_terminal(b^) {
        identity := bridge_local_hash_token(key)
        fmt.eprintfln("RECOVERY_TRANSITION identity=%s state=%v attempts=%d code=%v class=%v", identity, b.state, b.attempts, b.code, b.class)
        delete(identity)
    }
    if !bridge_retry_journal_flush_locked() do b.state = .Waiting_Repair
    return b^
}

bridge_retry_status :: proc(key: string) -> Bridge_Operation_Budget {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil do return {state = .Waiting_Repair}
    return b^
}

// Only a completed successful operation can begin new scheduled work. Failed
// receipts survive reconnects, credential rotation and duplicate invalidations.
bridge_retry_reopen_success :: proc(key: string) {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b != nil && b.state == .Succeeded {
        b^ = {}
        if !bridge_retry_journal_flush_locked() do b.state = .Waiting_Repair
    }
}

// bridge_retry_reopen_retriable gives a renewal receipt that ended TERMINAL for a
// retriable reason a fresh, bounded budget. Only `refresh:` keys: every refresh
// attempt carries its rotation's request id, which the hub honours for a retry, so
// repeating it cannot mint a second credential. Unauthenticated and cancelled
// receipts are left alone.
bridge_retry_reopen_retriable :: proc(key: string) -> bool {
    if !strings.has_prefix(key, "refresh:") do return false
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil || !(b.state == .Waiting_Repair || b.state == .Exhausted) do return false
    if !(b.class == .retriable || b.code == .None) do return false
    b^ = {}
    if !bridge_retry_journal_flush_locked() { b.state = .Waiting_Repair; return false }
    return true
}

bridge_retry_record_target :: proc(key, target: string) -> bool {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    for &r in bridge_retry_journal.receipts {
        if r.key == key {
            if r.budget.state != .In_Flight || (r.target_instance_id != "" && r.target_instance_id != target) do return false
            delete(r.target_instance_id)
            r.target_instance_id = strings.clone(target, runtime.heap_allocator())
            if !bridge_retry_journal_flush_locked() { r.budget.state = .Waiting_Repair; return false }
            return true
        }
    }
    return false
}

bridge_retry_resume_pending_rotation :: proc(key: string, first_ms: i64) -> bool {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil || b.first_ms != first_ms || first_ms <= 0 do return false
    if b.state == .Succeeded {
        // Both durable writes were already acknowledged; completing their local
        // idempotent replay is safe, but must not exchange a remote token again.
        return true
    } else if b.state == .Waiting_Repair && (b.code == .None || b.class == .retriable) {
        b.state = .Backoff
    } else if b.state != .Backoff { return false }
    return bridge_retry_journal_flush_locked()
}

Bridge_Recovery_Status_Row :: struct {
    operation, state, code, class: string,
    receipts, attempts, remaining: int,
}
bridge_recovery_status_json :: proc() -> string {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    groups := make(map[string]Bridge_Recovery_Status_Row, context.temp_allocator)
    for r in bridge_retry_journal.receipts {
        operation := "readiness"
        if strings.has_prefix(r.key, "sync:") { operation = "sync" }
        else if strings.has_prefix(r.key, "refresh:") { operation = "refresh" }
        else if strings.has_prefix(r.key, "slot:") { operation = "slot" }
        state := fmt.tprintf("%v", r.budget.state)
        code := contracts.error_code_string(r.budget.code)
        class := contracts.bridge_error_class_name(r.budget.class)
        key := fmt.tprintf("%s/%s/%s/%s", operation, state, code, class)
        row := groups[key]
        row.operation = operation; row.state = state; row.code = code; row.class = class
        row.receipts += 1; row.attempts += r.budget.attempts
        if !bridge_operation_terminal(r.budget) do row.remaining += BRIDGE_OPERATION_ATTEMPTS-r.budget.attempts
        groups[key] = row
    }
    rows := make([dynamic]Bridge_Recovery_Status_Row, context.temp_allocator)
    for _, row in groups do append(&rows, row)
    data, err := json.marshal(struct{journal_failed, capacity_exhausted: bool, capacity: int, rows: []Bridge_Recovery_Status_Row}{
        bridge_retry_journal.failed, len(bridge_retry_journal.receipts) >= BRIDGE_RETRY_JOURNAL_CAP, BRIDGE_RETRY_JOURNAL_CAP, rows[:],
    })
    if err != nil do return strings.clone("{}")
    return string(data)
}

// bridge_recovery_diagnostics_write appends the bridge_diagnostics operation_recovery
// family: rows of the five consumed members only, grouped exactly like
// bridge_recovery_status_json (whose legacy object keeps journal_failed,
// capacity_exhausted, capacity and per-row attempts/remaining).
bridge_recovery_diagnostics_write :: proc(b: ^strings.Builder) {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    groups := make(map[string]Bridge_Recovery_Status_Row, context.temp_allocator)
    for r in bridge_retry_journal.receipts {
        operation := "readiness"
        if strings.has_prefix(r.key, "sync:") { operation = "sync" }
        else if strings.has_prefix(r.key, "refresh:") { operation = "refresh" }
        else if strings.has_prefix(r.key, "slot:") { operation = "slot" }
        state := fmt.tprintf("%v", r.budget.state)
        code := contracts.error_code_string(r.budget.code)
        class := contracts.bridge_error_class_name(r.budget.class)
        key := fmt.tprintf("%s/%s/%s/%s", operation, state, code, class)
        row := groups[key]
        row.operation = operation; row.state = state; row.code = code; row.class = class
        row.receipts += 1
        groups[key] = row
    }
    strings.write_string(b, `{"rows":[`)
    first := true
    for _, row in groups {
        if !first do strings.write_byte(b, ',')
        first = false
        strings.write_string(b, `{"operation":"`); bridge_runtime_write_json_string(b, row.operation)
        strings.write_string(b, `","state":"`); bridge_runtime_write_json_string(b, row.state)
        strings.write_string(b, `","code":"`); bridge_runtime_write_json_string(b, row.code)
        strings.write_string(b, `","class":"`); bridge_runtime_write_json_string(b, row.class)
        fmt.sbprintf(b, `","receipts":%d}}`, row.receipts)
    }
    strings.write_string(b, "]}")
}

// Explicit local operator command only; ordinary reconnect/version/token events
// never call this. Corrupt journals and unknown side-effect slots stay fenced.
bridge_retry_operator_resume_sync :: proc(key: string, refresh := false) -> bool {
    if !strings.has_prefix(key, "refresh:" if refresh else "sync:") do return false
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b == nil || b.state == .In_Flight do return false
    b^ = {}
    return bridge_retry_journal_flush_locked()
}
bridge_retry_credential_repaired :: proc(key: string) {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if strings.has_prefix(key, "sync:") && b != nil && b.state == .Waiting_Repair && b.code == .Unauthenticated && b.class == .recoverable {
        b.state = .Backoff
        if !bridge_retry_journal_flush_locked() do b.state = .Waiting_Repair
    }
}

bridge_retry_cancel :: proc(key: string) {
    sync.mutex_lock(&bridge_retry_journal_mutex)
    defer sync.mutex_unlock(&bridge_retry_journal_mutex)
    b := bridge_retry_journal_get_locked(key)
    if b != nil {
        b.state = .Cancelled
        if !bridge_retry_journal_flush_locked() do b.state = .Waiting_Repair
    }
}
