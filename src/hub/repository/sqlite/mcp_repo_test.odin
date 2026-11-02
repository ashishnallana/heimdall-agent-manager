package sqlite

import "core:testing"

@(test)
test_mcp_metadata_migration_embedded_upgrade_and_repeat :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=open(":memory:")
	testing.expect(t,opened)
	if !opened do return
	defer close(&conn)
	const_name:="175_mcp_delegated_credentials.sql"
	ok,err:=run_migrations(&conn,"/missing-embedded-migration-test",const_name)
	testing.expectf(t,ok,"baseline migrations: %s",err.message)
	testing.expect(t,!sqlite_object_exists(&conn,"mcp_records"))
	upgraded,uerr:=run_migrations(&conn,"/missing-embedded-migration-test")
	testing.expectf(t,upgraded,"embedded MCP upgrade: %s",uerr.message)
	testing.expect(t,sqlite_object_exists(&conn,"mcp_records") && migration_applied(&conn,const_name))
	testing.expect(t,sqlite_object_exists(&conn,"mcp_epoch_wraps") && migration_applied(&conn,"176_mcp_epoch_wraps.sql"))
	testing.expect(t,exec(&conn,`INSERT INTO mcp_records(kind,id,owner_user_id,metadata_json) VALUES('client','survives','','{}');`))
	again,aerr:=run_migrations(&conn,"/missing-embedded-migration-test")
	testing.expectf(t,again,"repeat migration: %s",aerr.message)
	stmt:sqlite3_stmt
	rc:=sqlite3_prepare_v2(conn.db,"SELECT COUNT(*) FROM mcp_records WHERE id='survives';",-1,&stmt,nil)
	testing.expect(t,rc==SQLITE_OK)
	if rc!=SQLITE_OK do return
	defer sqlite3_finalize(stmt)
	testing.expect(t,sqlite3_step(stmt)==SQLITE_ROW && sqlite3_column_int64(stmt,0)==1)
}

// A deployed 0.5.33 database already has MCP 175–177. Setup must append its
// receipt schema without replaying or replacing those migrations.
@(test)
test_setup_receipt_upgrade_preserves_current_main_mcp :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	missing_dir := "/missing-embedded-setup-integration-test"
	ok, err := run_migrations(&conn, missing_dir, "178_bridge_sunset_receipts.sql")
	if !testing.expectf(t, ok, "current main schema: %s", err.message) do return
	testing.expect(t, migration_applied(&conn, "177_extension_version_sync_0_5_33.sql"))
	testing.expect(t, !sqlite_object_exists(&conn, "bridge_sunset_receipts"))
	if !testing.expect(t, exec(&conn, `INSERT INTO mcp_records(kind,id,owner_user_id,metadata_json) VALUES('client','setup-survivor','','{}');`)) do return
	for pass in 0..<2 {
		upgraded, upgrade_err := run_migrations(&conn, missing_dir)
		if !testing.expectf(t, upgraded, "setup upgrade/repeat %d: %s", pass, upgrade_err.message) do return
		testing.expect(t, migration_applied(&conn, "178_bridge_sunset_receipts.sql"))
		testing.expect(t, sqlite_object_exists(&conn, "bridge_sunset_receipts"))
		testing.expect(t, sqlite_object_exists(&conn, "bridge_sunset_receipt_tokens"))
		testing.expect(t, sqlite_object_exists(&conn, "mcp_epoch_wraps"))
	}
	stmt: sqlite3_stmt
	rc := sqlite3_prepare_v2(conn.db, "SELECT COUNT(*) FROM mcp_records WHERE id='setup-survivor';", -1, &stmt, nil)
	if !testing.expect(t, rc == SQLITE_OK) do return
	defer sqlite3_finalize(stmt)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) == 1)
}
