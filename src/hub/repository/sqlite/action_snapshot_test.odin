package sqlite
import "core:testing"
import "core:os"
import "core:fmt"
import "core:time"
import "core:thread"
import "core:strconv"
import domain "odin_test:hub/domain"

Action_Snapshot_Writer :: struct { conn: ^Conn, failed: bool }
action_snapshot_writer :: proc(data: rawptr) {
    w := (^Action_Snapshot_Writer)(data)
    for _ in 0..<100 {
        if !exec(w.conn, "UPDATE actions SET prompt_text=CAST((SELECT revision+1 FROM action_schedule_revision WHERE singleton=1) AS TEXT) WHERE id='a';") { w.failed = true; return }
        time.sleep(time.Millisecond)
    }
}
@(test)
action_snapshot_private_reader_is_coherent_during_commits :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/action-snapshot-%d.db", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    conn, ok, _ := open(path)
    if !testing.expect(t, ok) do return
    defer { close(&conn); _ = os.remove(path) }
    testing.expect(t, exec(&conn, "PRAGMA journal_mode=WAL;"))
    migrated, _ := run_migrations(&conn)
    if !testing.expect(t, migrated) do return
    impl: Action_Repo_SQLite
    repo := new_action_repository(&impl, &conn)
    reader_ok, _ := open_action_snapshot_conn(&impl, path)
    if !testing.expect(t, reader_ok) do return
    defer close(&impl.snapshot_conn)
    _, saved, err := repo.save(repo.ctx, domain.Action{id="a",owner_user_id="u",target_bridge_id="b",prompt_text="1"})
    if !testing.expect(t, saved && err.code == .None) do return
    w := Action_Snapshot_Writer{conn=&conn}
    worker := thread.create_and_start_with_data(&w, action_snapshot_writer)
    for _ in 0..<150 {
        revision, rows, unchanged, err := repo.snapshot(repo.ctx, "b", -1)
        testing.expect(t, err.code == .None && !unchanged && len(rows) == 1)
        if len(rows) == 1 {
            value, valid := strconv.parse_i64(rows[0].prompt_text)
            testing.expect(t, valid && value == revision, "rows and revision share the same committed snapshot")
        }
        time.sleep(time.Millisecond)
    }
    thread.join(worker); thread.destroy(worker)
    testing.expect(t, !w.failed)
    revision, _ := repo.revision(repo.ctx)
    _, rows, unchanged, err2 := repo.snapshot(repo.ctx, "b", revision)
    testing.expect(t, unchanged && len(rows) == 0 && err2.code == .None)
    _, other_rows, _, err3 := repo.snapshot(repo.ctx, "other", -1)
    testing.expect(t, len(other_rows) == 0 && err3.code == .None)
    testing.expect(t, exec(&conn, "DELETE FROM actions WHERE id='a';"))
    later, _ := repo.revision(repo.ctx)
    testing.expect(t, later > revision)
}

@(test)
agent_save_busy_is_retriable_but_generation_mismatch_is_conflict :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/agent-cas-%d.db", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    conn, ok, _ := open(path)
    if !testing.expect(t, ok) do return
    defer { close(&conn); _ = os.remove(path) }
    migrated, _ := run_migrations(&conn)
    if !testing.expect(t, migrated) do return
    testing.expect(t, exec(&conn, "PRAGMA foreign_keys=OFF;"))
    writer, writer_ok, _ := open(path)
    if !testing.expect(t, writer_ok) do return
    defer close(&writer)
    testing.expect(t, exec(&writer, "BEGIN IMMEDIATE;"))
    impl: Agent_Repo_SQLite
    repo := new_agent_repository(&impl, &conn)
    instance := domain.Agent_Instance{agent_instance_id="i",agent_id="a",owner_user_id="u",bridge_id="b"}
    _, saved, err := repo.save_instance(repo.ctx, instance)
    testing.expect(t, !saved)
    testing.expect_value(t, err.code, domain.Error_Code.Bridge_Busy)
    testing.expect(t, exec(&writer, "ROLLBACK;"))
    persisted, saved2, err2 := repo.save_instance(repo.ctx, instance)
    if !testing.expect(t, saved2 && err2.code == .None) do return
    persisted.run_count = -1
    _, saved3, err3 := repo.save_instance(repo.ctx, persisted)
    testing.expect(t, !saved3)
    testing.expect_value(t, err3.code, domain.Error_Code.Conflict)
}
