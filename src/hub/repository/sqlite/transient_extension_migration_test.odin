package sqlite

import "core:testing"

@(test)
test_transient_extension_upgrade_removes_populated_history :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    conn, path, opened := tmpl_open_file_prod(t, "transient_extension")
    defer tmpl_remove_db(path)
    if !opened do return
    defer close(&conn)
    ok, err := run_migrations(&conn, stop_before = "124_transient_extension_signals.sql")
    if !testing.expect(t, ok, err.message) do return
    testing.expect(t, exec(&conn, `INSERT INTO agent_extension_events(instance_id,seq,event,payload,created_at) VALUES('inst_x',1,'tool.end','{"secret":"old"}','2026-01-01');`))
    testing.expect(t, sqlite_object_exists(&conn, "agent_extension_events"))
    ok, err = run_migrations(&conn)
    testing.expect(t, ok, err.message)
    testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events"))
    testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events_instance_seq"))
    testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events_instance_agent"))
    ok, err = run_migrations(&conn)
    testing.expect(t, ok, err.message)
    testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events"))
}
