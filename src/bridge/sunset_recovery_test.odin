package main

// REQ-3: real hub persistence and handler -> real bridge decoder, retry budget,
// credential files and restart journal. No live enrollment or OS keychain is used.
import "core:fmt"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import hub "odin_test:hub/service/bridge"
import transport "odin_test:hub/transport/http"
import httpc "odin_test:lib/httpc"
import bridgesvc "odin_test:lib/bridgesvc"

@(private = "file")
sunset_recovery_service: ^hub.Bridge_Service

@(private = "file")
sunset_recovery_exchange :: proc(api, token, request_id: string, timeout_ms: int) -> (Bridge_Enroll_Credential, bool, contracts.Wire_Error, bool) {
    h := transport.Bridge_Handlers{bridges = sunset_recovery_service}
    response := transport.bridge_refresh_handler(&h, transport.Request{
        headers = []contracts.HTTP_Header{
            {name = "Authorization", value = fmt.tprintf("Bearer %s", token)},
            {name = hub.BRIDGE_REFRESH_REQUEST_ID_HEADER, value = request_id},
        },
    })
    return bridge_refresh_response_classify(httpc.Response{status = response.status, body = transmute([]byte)response.body}, true, api)
}

@(test)
test_sunset_pending_refresh_and_session_survive_restart_then_rollback :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    hub_pause_test_reset()
    defer hub_pause_test_reset()
    dir := fmt.tprintf("%s/.cache/heimdall-tests/sunset-client-%d-%d", os.get_env("HOME", context.temp_allocator), os.get_pid(), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(dir)
    config := fmt.tprintf("%s/config.toml", dir)
    path := fmt.tprintf("%s/credential", dir)
    refresh_path := bridge_enroll_refresh_file_for(path, context.temp_allocator)
    pending_path := fmt.tprintf("%s/pending.json", dir)
    request_path := bridge_refresh_request_path(path)
    defer delete(request_path)
    journal_path := fmt.tprintf("%s/retry.json", dir)
    api := "https://sunset-fixture.example"
    key := "refresh:https://sunset-fixture.example:old"

    conn, opened, _ := sqlite.open(":memory:")
    if !testing.expect(t, opened) do return
    defer sqlite.close(&conn)
    migrated, _ := sqlite.run_migrations(&conn)
    if !testing.expect(t, migrated) do return
    impl: sqlite.Bridge_Repo_SQLite
    repo := sqlite.new_bridge_repository(&impl, &conn)
    clock := platform.real_clock()
    ids := platform.real_id_generator()
    svc := hub.new_bridge_service(&repo, &clock, &ids)
    sunset_recovery_service = &svc
    defer { sunset_recovery_service = nil }
    old, old_ok, old_err := hub.enroll_bridge_from_device_grant(&svc, {bridge_public_key = "04aabb", owner_user_id = "sunset_client_owner"})
    if !testing.expect(t, old_ok, old_err.message) do return
    testing.expect(t, bridge_write_credential_file(path, api, old.bridge.bridge_id, old.bridge_token))
    testing.expect(t, bridge_retry_atomic_write(refresh_path, transmute([]byte)old.refresh_token))
    request_id, request_ok := bridge_refresh_request_ensure(request_path, key, api, old.bridge.bridge_id)
    testing.expect(t, request_ok)
    replacement, replaced, replace_err := hub.enroll_bridge_from_device_grant(&svc, {
        bridge_public_key = "04aabb", owner_user_id = "sunset_client_owner", pending = true, sunset_bridge_id = old.bridge.bridge_id,
    })
    if !testing.expect(t, replaced, replace_err.message) do return
    token_id, _, _ := hub.split_credential(hub.ACCESS_TOKEN_PREFIX, old.bridge_token)
    testing.expect_value(t, hub.session_credential_state(&svc, token_id), hub.Session_Credential_State.Pending_Sunset)
    frame := transport.bridge_ws_session_error_payload(transport.BRIDGE_WS_SUNSET_PENDING_CODE, "pending", context.temp_allocator)
    testing.expect(t, bridge_hub_session_frame("bridge_error", frame))
    testing.expect(t, sync.atomic_load(&bridge_hub_traffic_stopped))
    // The old regression exercised bounded retry persistence while suspended.
    // Those attempts are now forbidden; exercise preservation before explicitly
    // modelling operator activation below instead.

    recovery := Bridge_Refresh_Recovery{request_id = request_id, pending = {version = 1, key = key, api_base = api, bridge_id = old.bridge.bridge_id}}
    budget: Bridge_Operation_Budget
    last_err: contracts.Wire_Error
    for now: i64 = 1000; now < 200_000; now += 1000 {
        if !bridge_operation_reserve(&budget, now) do continue
        ok, err := bridge_refresh_recovery_step(&recovery, pending_path, path, refresh_path, api, old.bridge.bridge_id, old.refresh_token, budget, 1000, sunset_recovery_exchange)
        testing.expect(t, !ok, "pending sunset never rotates")
        testing.expect_value(t, err.class, contracts.Bridge_Error_Class.retriable)
        last_err = err
        bridge_operation_finish(&budget, now, ok, err)
    }
    testing.expect_value(t, budget.state, Bridge_Operation_State.Exhausted)
    testing.expect(t, !bridge_refresh_apply_rejection(config, api, old.bridge.bridge_id, path, refresh_path, request_path, last_err))
    a, a_err := os.read_entire_file(path, context.temp_allocator)
    r, r_err := os.read_entire_file(refresh_path, context.temp_allocator)
    testing.expect(t, a_err == nil && strings.contains(string(a), old.bridge_token))
    testing.expect(t, r_err == nil && string(r) == old.refresh_token)
    _, marker := bridgesvc.read_reenroll_marker(dir)
    testing.expect(t, !marker, "temporary refresh/session rejection never parks the profile")

    // Simulate a process restart: reload the actual durable budget and request id.
    j := Bridge_Retry_Journal{version = 1}
    defer delete(j.receipts)
    append(&j.receipts, Bridge_Retry_Receipt{key = key, budget = budget})
    testing.expect(t, bridge_retry_journal_save(&j, journal_path))
    restored: Bridge_Retry_Journal
    testing.expect(t, bridge_retry_journal_load(&restored, journal_path))
    defer {
        for receipt in restored.receipts do delete(receipt.key, runtime.heap_allocator())
        delete(restored.receipts)
    }
    if !testing.expect_value(t, len(restored.receipts), 1) do return
    testing.expect(t, bridge_refresh_terminal_is_retriable(restored.receipts[0].budget))
    same_request, same_ok := bridge_refresh_request_ensure(request_path, key, api, old.bridge.bridge_id)
    testing.expect(t, same_ok && same_request == request_id)
    _, removed, rollback_err := hub.rollback_pending_enrollment(&svc, replacement.bridge.bridge_id, replacement.family_id)
    testing.expect(t, removed && rollback_err.code == .None)
    testing.expect_value(t, hub.session_credential_state(&svc, token_id), hub.Session_Credential_State.Valid)
    _, access_ok, _ := hub.verify_bridge_token(&svc, old.bridge_token)
    testing.expect(t, access_ok, "same persisted access token reconnects")
    hub_pause_test_reset() // fresh process after explicit local activation
    // Reopen a bounded budget as the worker does after a retriable exhaustion.
    budget = {}
    testing.expect(t, bridge_operation_reserve(&budget, 300_000))
    recovery = Bridge_Refresh_Recovery{request_id = same_request, pending = {version = 1, key = key, api_base = api, bridge_id = old.bridge.bridge_id}}
    renewed, renew_err := bridge_refresh_recovery_step(&recovery, pending_path, path, refresh_path, api, old.bridge.bridge_id, string(r), budget, 1000, sunset_recovery_exchange)
    testing.expect(t, renewed, renew_err.message)
    fresh, fresh_err := os.read_entire_file(refresh_path, context.temp_allocator)
    testing.expect(t, fresh_err == nil && string(fresh) != old.refresh_token, "renewal persists a fresh pair")
    _, marker = bridgesvc.read_reenroll_marker(dir)
    testing.expect(t, !marker)
}

@(test)
test_sunset_final_refresh_refusal_still_marks_reenrollment :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    hub_pause_test_reset()
    defer hub_pause_test_reset()
    dir := fmt.tprintf("%s/.cache/heimdall-tests/sunset-final-%d-%d", os.get_env("HOME", context.temp_allocator), os.get_pid(), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(dir)
    path := fmt.tprintf("%s/credential", dir)
    refresh := fmt.tprintf("%s/refresh", dir)
    request := fmt.tprintf("%s/request", dir)
    testing.expect(t, bridge_retry_atomic_write(path, transmute([]byte)string("access")))
    testing.expect(t, bridge_retry_atomic_write(refresh, transmute([]byte)string("refresh")))
    testing.expect(t, bridge_retry_atomic_write(request, transmute([]byte)string("request")))
    testing.expect(t, bridge_refresh_apply_rejection(fmt.tprintf("%s/config.toml", dir), "https://hub", "brg_final", path, refresh, request, contracts.wire_error(.Unauthenticated)))
    testing.expect(t, !os.exists(path) && !os.exists(refresh) && !os.exists(request))
    _, marker := bridgesvc.read_reenroll_marker(dir)
    testing.expect(t, marker, "final revocation still parks the profile")
}
