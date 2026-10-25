package http
import "core:testing"
import "core:fmt"
import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import "core:strings"

@(private = "file")
snapshot_actions_enabled :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
    out := make([dynamic]domain.Experiment)
    append(&out, domain.Experiment{owner_user_id = strings.clone(owner_user_id), key = strings.clone(domain.ACTIONS_EXPERIMENT_KEY), enabled = true, updated_at = strings.clone("2026-10-25T00:00:00Z")})
    return out, {}
}

@(test)
action_snapshot_server_validator_scope_errors_and_restart_epoch :: proc(t: ^testing.T) {
    f := wire_setup(t, "action_snapshot")
    defer wire_teardown(f)
    impl: sqlite.Action_Repo_SQLite
    repo := sqlite.new_action_repository(&impl, &f.conn)
    _, saved, save_err := repo.save(repo.ctx, domain.Action{id="snapshot_action", owner_user_id=f.owner, target_bridge_id=domain.Bridge_ID(f.bridge_pin), prompt_text="one"})
    if !testing.expect(t, saved && save_err.code == .None) do return
    // The owner opted into Actions (REQ-EXP-GATE-4); the gate itself is covered in action_gate_test.odin.
    exp_repo := iface.Experiment_Repository{list_by_owner = snapshot_actions_enabled}
    h := Action_Handlers{repo = &repo, bridges = &f.br_svc, experiments = &exp_repo}
    req := wire_agent_request(f, "unused", "")
    req.method = "GET"; req.path = "/api/v1/bridge/actions"
    first := bridge_list_actions_handler(&h, req)
    testing.expect_value(t, first.status, 200)
    wire: struct { snapshot: struct {epoch: string, revision: i64, etag: string}, data: []json.Value }
    testing.expect(t, json.unmarshal_string(first.body, &wire) == nil)
    testing.expect(t, wire.snapshot.epoch != "" && wire.snapshot.etag != "")
    headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
    append(&headers, ..req.headers)
    append(&headers, contracts.HTTP_Header{name = "If-None-Match", value = wire.snapshot.etag})
    req.headers = headers[:]
    headers[len(headers)-1].value = fmt.tprintf("\"%s:%d\"", wire.snapshot.epoch, wire.snapshot.revision)
    noncanonical := bridge_list_actions_handler(&h, req)
    testing.expect_value(t, noncanonical.status, 200)
    full: struct { data: []json.Value }
    testing.expect(t, json.unmarshal_string(noncanonical.body, &full) == nil && len(full.data) == 1)
    headers[len(headers)-1].value = wire.snapshot.etag
    unchanged := bridge_list_actions_handler(&h, req)
    testing.expect_value(t, unchanged.status, 304)
    // Direct SQL writers bump the transactionally read revision, including
    // a bridge membership transfer; status-only heartbeats do not.
    before, _ := repo.revision(repo.ctx)
    testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET runtime_status=runtime_status;"))
    same, _ := repo.revision(repo.ctx)
    testing.expect_value(t, before, same)
    testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET bridge_id='other';"))
    changed, _ := repo.revision(repo.ctx)
    testing.expect(t, changed > same)
    updated := bridge_list_actions_handler(&h, req)
    testing.expect_value(t, updated.status, 200)
    // A prior boot validator is never a match, even for a lower revision.
    headers[len(headers)-1].value = `W/"retired-epoch:0"`
    testing.expect_value(t, bridge_list_actions_handler(&h, req).status, 200)
    testing.expect(t, sqlite.exec(&f.conn, "DROP TABLE action_schedule_revision;"))
    failed := bridge_list_actions_handler(&h, req)
    testing.expect_value(t, failed.status, 500)
    req.headers = nil
    testing.expect_value(t, bridge_list_actions_handler(&h, req).status, 401)
}
