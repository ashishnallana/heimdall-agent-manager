package main

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import ws "odin_test:lib/ws"

@(private = "file")
Transient_Status_Test :: struct { id: string, writes: int }

@(private = "file")
transient_status_drain_to_hub :: proc(t: ^testing.T, conn: ^ws.Connection, peer: net.TCP_Socket, reader: ^ws.Frame_Reader, svc: ^agent_service.Agent_Service, id: string) -> int {
    bridge_runtime_drain_status_pushes(conn)
    frames := 0
    for {
        _, raw, got := ws.read_frame(peer, reader, 2 * time.Millisecond)
        if !got do break
        defer delete(raw)
        if extract_json_string(raw, "type", "", context.temp_allocator) != "agent_instance_status" do continue
        if extract_json_string(raw, "agent_instance_id", "", context.temp_allocator) != id do continue
        frames += 1
        // This is the same reducer reached by bridge_apply_validated_status.
        // The wire goes through the real outgoing queue and WebSocket sender.
        facts := make([dynamic]agent_service.Lifecycle_Fact)
        saved, applied, err := agent_service.apply_bridge_status_report(
            svc, "brg_transient", id, extract_json_int(raw, "state_seq", 0),
            extract_json_string(raw, "runtime_status", "", context.temp_allocator),
            extract_json_string(raw, "activity_status", "", context.temp_allocator),
            owner_user_id = "owner",
            launch_epoch = extract_json_string(raw, "launch_epoch", "", context.temp_allocator),
            facts = &facts)
        testing.expect(t, applied && err.code == .None, "emitted status reaches hub save")
        domain.agent_instance_destroy(&saved)
        agent_service.lifecycle_facts_destroy(&facts)
    }
    return frames
}

@(test)
test_transient_activity_ingestion_has_zero_outgoing_status_or_hub_saves :: proc(t: ^testing.T) {
    id := "inst_transient_status_writes"
    fixture := Transient_Status_Test{id = id}
    repo := iface.Agent_Repository{ctx = &fixture,
        get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
            f := (^Transient_Status_Test)(ctx)
            return domain.Agent_Instance{
                agent_instance_id = strings.clone(id), owner_user_id = domain.User_ID(strings.clone("owner")),
                bridge_id = strings.clone("brg_transient"), runtime_status = strings.clone("running"),
                activity_status = strings.clone("idle"),
            }, id == f.id, {}
        },
        save_instance = proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
            (^Transient_Status_Test)(ctx).writes += 1
            return inst, true, {}
        }}
    clock := platform.real_clock()
    svc := agent_service.Agent_Service{agents = &repo, clock = &clock}
    listener, le := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    if le != nil do testing.fail_now(t, "listen")
    defer net.close(listener)
    bound, _ := net.bound_endpoint(listener)
    peer, pe := net.dial_tcp(bound)
    if pe != nil do testing.fail_now(t, "dial")
    defer net.close(peer)
    sock, _, ae := net.accept_tcp(listener)
    if ae != nil do testing.fail_now(t, "accept")
    defer net.close(sock)
    conn := ws.Connection{socket = sock, connected = true}
    reader := ws.reader_make()
    defer ws.reader_destroy(&reader)
    // Positive control: the normal explicit lifecycle path still saves.
    bridge_runtime_mark_start_success(id)
    testing.expect_value(t, transient_status_drain_to_hub(t, &conn, peer, &reader, &svc, id), 1)
    testing.expect_value(t, fixture.writes, 1)
    fixture.writes = 0
    for i in 0..<100 {
        state := "active" if i % 2 == 0 else "idle"
        raw := strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"1","event":"activity","session_id":"s","payload":{"state":"`, state, `"}}`}, context.temp_allocator)
        result := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "fixture", role = .Agent}, raw, bridge_runtime_now_ms())
        testing.expect_value(t, result.accepted, 1)
        bridge_ext_ingest_result_destroy(&result)
        local, found := bridge_runtime_instance_snapshot(id)
        testing.expect(t, found)
        testing.expect_value(t, local.activity_status, state)
        // Drain after EVERY transition: coalescing a burst cannot hide a leak.
        testing.expect_value(t, transient_status_drain_to_hub(t, &conn, peer, &reader, &svc, id), 0)
    }
    bridge_runtime_note_agent_activity(id, "active", bridge_ext_activity_source("claude"))
    bridge_runtime_note_agent_activity(id, "waiting_user", bridge_ext_activity_source("claude"))
    testing.expect_value(t, transient_status_drain_to_hub(t, &conn, peer, &reader, &svc, id), 0)
    testing.expect_value(t, fixture.writes, 0)
    // Independent lifecycle changes continue to pass through after native events.
    sync.mutex_lock(&bridge_runtime_mutex)
    bridge_runtime_set_status_locked(id, "stopped", "idle", bridge_runtime_now_ms(), true)
    sync.mutex_unlock(&bridge_runtime_mutex)
    testing.expect_value(t, transient_status_drain_to_hub(t, &conn, peer, &reader, &svc, id), 1)
    testing.expect_value(t, fixture.writes, 1)
}

@(test)
test_transient_extension_rediscovery_does_not_enqueue_status :: proc(t: ^testing.T) {
    id := "inst_transient_rediscovery"
    sync.mutex_lock(&bridge_runtime_mutex)
    bridge_runtime_set_status_with_source_locked(id, "starting", "active", "codex_extension", bridge_runtime_now_ms(), true, false)
    queued := false
    for pending in bridge_runtime_status_outgoing do if pending == id do queued = true
    sync.mutex_unlock(&bridge_runtime_mutex)
    testing.expect(t, !queued)
    local, found := bridge_runtime_instance_snapshot(id)
    testing.expect(t, found)
    testing.expect_value(t, local.activity_status, "active")
}
