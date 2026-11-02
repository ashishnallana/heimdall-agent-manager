package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

// Tests hold bridge_test_config_mutex and restore every process global.
hub_pause_test_reset :: proc() {
    sync.atomic_store(&bridge_hub_traffic_stopped, false)
    bridge_hub_traffic_final = false
    bridge_hub_traffic_config_path = ""
}

hub_pause_fetch_count: int
hub_pause_fetch :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
    hub_pause_fetch_count += 1
    return hub_test_response(500, `{"error":{"code":"internal_error","cause":"bridge_sunset_pending","message":"pending"}}`), .None
}

@(test)
test_hub_pause_blocks_http_retries_refresh_and_reconnect :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    hub_pause_test_reset()
    defer hub_pause_test_reset()
    hub_pause_fetch_count = 0
    saved_config := bridge_config
    defer { bridge_config = saved_config }
    bridge_config = {daemon_url = "https://fixture.example", daemon_id = "brg_paused", bridge_token = "fixture"}
    resp, err := bridge_hub_http_send_using({}, hub_pause_fetch)
    httpc.response_destroy(&resp)
    testing.expect_value(t, err, httpc.Error.None)
    testing.expect(t, sync.atomic_load(&bridge_hub_traffic_stopped))
    for i in 0..<5 {
        blocked, blocked_err := bridge_hub_http_send_using({}, hub_pause_fetch)
        testing.expect_value(t, blocked_err, httpc.Error.Aborted)
        testing.expect(t, !blocked.may_have_sent)
    }
    testing.expect_value(t, hub_pause_fetch_count, 1)
    // Production paths: even a malformed URL cannot reach libcurl; the error is
    // Aborted, not Invalid_Url. The worker returns before constructing/dialing WS.
    _, actual_err := bridge_hub_http_send({})
    testing.expect_value(t, actual_err, httpc.Error.Aborted)
    bridge_hub_runtime_worker()
    recovery: Bridge_Refresh_Recovery
    refreshed, refresh_err := bridge_refresh_recovery_step(&recovery, "", "", "", "", "", "", {}, 1000)
    testing.expect(t, !refreshed && refresh_err.code == .Bridge_Offline)
    // A delayed successful renewal never re-opens the fence.
    sync.atomic_store(&bridge_credential_reauth_pending, true)
    c: ws.Connection
    bridge_credential_reauth_drain(&c)
    testing.expect(t, sync.atomic_load(&bridge_hub_traffic_stopped))
}

@(test)
test_hub_pause_is_durable_and_only_temporary_pause_resumes :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    hub_pause_test_reset()
    defer hub_pause_test_reset()
    saved_config := bridge_config
    defer { bridge_config = saved_config }
    dir := fmt.tprintf("%s/.cache/heimdall-tests/hub-pause-%d-%d", os.get_env("HOME", context.temp_allocator), os.get_pid(), time.to_unix_nanoseconds(time.now()))
    defer os.remove_all(dir)
    config := fmt.tprintf("%s/config.toml", dir)
    testing.expect(t, bridge_retry_atomic_write(config, transmute([]byte)string("fixture")))
    bridge_config = {daemon_url = "https://fixture.example", daemon_id = "brg_test_paused"}
    bridge_hub_traffic_config_path = config
    bridge_hub_stop_traffic(false)
    pause, exists, valid := bridge_hub_pause_read(config)
    testing.expect(t, exists && valid && !pause.final && pause.bridge_id == bridge_config.daemon_id)
    when ODIN_OS != .Windows {
        alias := fmt.tprintf("%s/alias.toml", dir)
        testing.expect(t, os.symlink(config, alias) == nil)
        testing.expect_value(t, bridge_hub_pause_path(alias), bridge_hub_pause_path(config))
    }
    bytes, _ := os.read_entire_file(bridge_hub_pause_path(config), context.temp_allocator)
    testing.expect(t, !strings.contains(string(bytes), "token"), "marker contains identity only")
    // Rollback alone cannot clear the on-disk fence. A restart sees it too.
    testing.expect(t, os.exists(bridge_hub_pause_path(config)))
    wrong := bridge_config; wrong.daemon_id = "brg_other"
    testing.expect(t, !bridge_hub_resume_sunset(wrong, config))
    testing.expect(t, bridge_hub_resume_sunset(bridge_config, config))
    testing.expect(t, sync.atomic_load(&bridge_hub_traffic_stopped), "activation requires a fresh process")
    // A final notice upgrades a temporary suspension and cannot be undone by
    // a late temporary notice or the sunset recovery command.
    bridge_hub_stop_traffic(true)
    bridge_hub_stop_traffic(false)
    pause, exists, valid = bridge_hub_pause_read(config)
    testing.expect(t, exists && valid && pause.final)
    testing.expect(t, !bridge_hub_resume_sunset(bridge_config, config))
    testing.expect(t, bridge_hub_pause_clear_enrolled(config), "successful enrollment clears even final pause")
    testing.expect(t, bridge_retry_atomic_write(bridge_hub_pause_path(config), transmute([]byte)string("corrupt")))
    _, exists, valid = bridge_hub_pause_read(config)
    testing.expect(t, exists && !valid)
    testing.expect(t, !bridge_hub_resume_sunset(bridge_config, config))
}

Hub_Pause_Writer :: struct {conn: ^ws.Connection, entered, done, sent: bool}
hub_pause_waiting_writer :: proc(th: ^thread.Thread) {
    s := (^Hub_Pause_Writer)(th.data)
    sync.atomic_store(&s.entered, true)
    s.sent = ws.send_text(s.conn, "must not arrive")
    sync.atomic_store(&s.done, true)
}

@(test)
test_hub_pause_fences_waiting_ws_writer_and_session_frames :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    hub_pause_test_reset()
    defer hub_pause_test_reset()
    listener, le := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, le == nil) do return
    defer net.close(listener)
    endpoint, _ := net.bound_endpoint(listener)
    peer, pe := net.dial_tcp(endpoint)
    if !testing.expect(t, pe == nil) do return
    defer net.close(peer)
    sock, _, ae := net.accept_tcp(listener)
    if !testing.expect(t, ae == nil) do return
    c := ws.Connection{socket = sock, connected = true, send_disabled = &bridge_hub_traffic_stopped}
    defer ws.close(&c)
    reader := ws.reader_make()
    defer ws.reader_destroy(&reader)
    testing.expect(t, ws.send_text(&c, "before pause"))
    _, before, got := ws.read_frame(peer, &reader, 100 * time.Millisecond)
    testing.expect(t, got && before == "before pause")
    delete(before)
    sync.mutex_lock(&c.send_mu)
    writer := Hub_Pause_Writer{conn = &c}
    th := thread.create(hub_pause_waiting_writer)
    th.data = &writer
    thread.start(th)
    for !sync.atomic_load(&writer.entered) { time.sleep(time.Millisecond) }
    testing.expect(t, bridge_hub_session_frame("bridge_error", `{"payload":{"code":"bridge_sunset_pending","message":"pending"}}`))
    sync.mutex_unlock(&c.send_mu)
    thread.join(th); thread.destroy(th)
    testing.expect(t, !writer.sent)
    testing.expect(t, !ws.send_binary(&c, []byte{1, 2, 3}))
    _ = bridge_hub_send_connect_heartbeat(&c)
    _, after, arrived := ws.read_frame(peer, &reader, 30 * time.Millisecond)
    delete(after)
    testing.expect(t, !arrived, "no text, binary or heartbeat bytes after detection")
    testing.expect(t, bridge_hub_session_frame("bridge_reauth_result", `{"payload":{"ok":false,"code":"bridge_credential_revoked"}}`))
    testing.expect(t, bridge_hub_traffic_final)
}
