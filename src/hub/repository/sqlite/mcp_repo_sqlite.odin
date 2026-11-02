package sqlite

import "core:encoding/json"
import "core:sync"
import "core:strings"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
repo_err :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, msg)
}
@(private = "file")
prepare :: proc(conn: ^Conn, query: string) -> (sqlite3_stmt, bool) {
	stmt: sqlite3_stmt
	q := strings.clone_to_cstring(query, context.temp_allocator)
	rc := sqlite3_prepare_v2(conn.db, q, -1, &stmt, nil)
	return stmt, rc == SQLITE_OK
}

MCP_Repo_SQLite :: struct {
	conn: Conn,
	mutex: sync.Mutex,
}

// Expiry is enforced by the service independently of deletion. Cleanup runs at
// startup and each reaper pass; offline backups may retain old ciphertext, which
// is still inaccessible without the client-held parent credential.
mcp_cleanup :: proc(impl: ^MCP_Repo_SQLite, now_ms: i64) -> domain.Domain_Error {
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	stmt, ok := prepare(&impl.conn, "UPDATE mcp_records SET metadata_json=json_set(metadata_json,'$.retry_capsule','') WHERE kind='refresh' AND json_extract(metadata_json,'$.retry_capsule') != '' AND json_extract(metadata_json,'$.retry_deadline_ms') <= ?;")
	if !ok do return repo_err("failed to prepare MCP cleanup")
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt,1,now_ms)
	if sqlite3_step(stmt)!=SQLITE_DONE do return repo_err("failed to expire MCP retry capsules")
	old, old_ok := prepare(&impl.conn,"DELETE FROM mcp_records WHERE kind IN ('code','access','pending') AND json_extract(metadata_json,'$.expires_ms') <= ?;")
	if !old_ok do return repo_err("failed to prepare MCP expiry cleanup")
	defer sqlite3_finalize(old)
	sqlite3_bind_int64(old,1,now_ms)
	if sqlite3_step(old)!=SQLITE_DONE do return repo_err("failed to expire MCP metadata")
	return {}
}

// Dedicated connection: an unrelated request must never join this transaction
// through the Hub's shared autocommit handle. The caller closes conn on shutdown.
open_mcp_repository :: proc(impl: ^MCP_Repo_SQLite, path: string) -> (iface.MCP_Repository, domain.Domain_Error) {
	conn, ok, err := open(path)
	if !ok do return {}, err
	impl.conn = conn
	if !exec(&impl.conn, "PRAGMA busy_timeout = 5000;") {
		close(&impl.conn)
		return {}, repo_err("failed to configure MCP persistence")
	}
	return {ctx = impl, transaction = mcp_transaction_sqlite}, {}
}

mcp_transaction_sqlite :: proc(ctx: rawptr, run: iface.MCP_Transaction_Proc, run_ctx: rawptr) -> domain.Domain_Error {
	impl := (^MCP_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	if !exec(&impl.conn, "BEGIN IMMEDIATE;") do return repo_err("failed to begin MCP transaction")
	committed := false
	defer if !committed do _ = exec(&impl.conn, "ROLLBACK;")
	tx := iface.MCP_Transaction{ctx = &impl.conn, get = mcp_get_sqlite, put = mcp_put_sqlite, remove = mcp_remove_sqlite, list = mcp_list_sqlite}
	err := run(tx, run_ctx)
	if err.code != .None do return err
	if !exec(&impl.conn, "COMMIT;") do return repo_err("failed to commit MCP transaction")
	committed = true
	return {}
}

mcp_record_kind_ok :: proc(kind: string) -> bool {
	return kind == "wrap" || kind == "client" || kind == "pending" || kind == "grant" || kind == "code" || kind == "access" || kind == "refresh" || kind == "family"
}
mcp_table :: proc(kind:string)->string {return "mcp_epoch_wraps" if kind=="wrap" else "mcp_records"}
mcp_get_sqlite :: proc(ctx: rawptr, kind, id: string) -> (domain.MCP_Record, bool, domain.Domain_Error) {
	conn := (^Conn)(ctx)
	stmt, ok := prepare(conn, fmt.tprintf("SELECT metadata_json FROM %s WHERE kind = ? AND id = ?;",mcp_table(kind)))
	if !ok do return {}, false, repo_err("failed to read MCP metadata")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, kind); bind_text(stmt, 2, id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.Domain_Error{}
	if rc != SQLITE_ROW do return {}, false, repo_err("failed to read MCP metadata")
	row: domain.MCP_Record
	if json.unmarshal(transmute([]byte)column_text(stmt, 0), &row, .JSON, context.temp_allocator) != nil || row.kind != kind || row.id != id do return {}, false, repo_err("invalid MCP metadata")
	return row, true, domain.Domain_Error{}
}
mcp_put_sqlite :: proc(ctx: rawptr, row: domain.MCP_Record) -> domain.Domain_Error {
	if !mcp_record_kind_ok(row.kind) || row.id == "" do return domain.domain_error(.Validation_Failed, "invalid MCP metadata kind")
	data, err := json.marshal(row, allocator = context.temp_allocator)
	if err != nil do return repo_err("failed to encode MCP metadata")
	stmt, ok := prepare((^Conn)(ctx), fmt.tprintf("INSERT INTO %s(kind,id,owner_user_id,metadata_json) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET owner_user_id=excluded.owner_user_id, metadata_json=excluded.metadata_json;",mcp_table(row.kind)))
	if !ok do return repo_err("failed to prepare MCP metadata write")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, row.kind); bind_text(stmt, 2, row.id); bind_text(stmt, 3, row.owner); bind_text(stmt, 4, string(data))
	if sqlite3_step(stmt) != SQLITE_DONE do return repo_err("failed to write MCP metadata")
	return {}
}
mcp_remove_sqlite :: proc(ctx: rawptr, kind, id: string) -> domain.Domain_Error {
	stmt, ok := prepare((^Conn)(ctx), fmt.tprintf("DELETE FROM %s WHERE kind = ? AND id = ?;",mcp_table(kind)))
	if !ok do return repo_err("failed to prepare MCP metadata removal")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, kind); bind_text(stmt, 2, id)
	if sqlite3_step(stmt) != SQLITE_DONE do return repo_err("failed to remove MCP metadata")
	return {}
}
mcp_list_sqlite :: proc(ctx: rawptr, kind, owner: string) -> ([]domain.MCP_Record, domain.Domain_Error) {
	stmt, ok := prepare((^Conn)(ctx), fmt.tprintf("SELECT metadata_json FROM %s WHERE kind = ? AND owner_user_id = ? ORDER BY id;",mcp_table(kind)))
	if !ok do return nil, repo_err("failed to list MCP metadata")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, kind); bind_text(stmt, 2, owner)
	rows := make([dynamic]domain.MCP_Record, context.temp_allocator)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, repo_err("failed to list MCP metadata")
		row: domain.MCP_Record
		if json.unmarshal(transmute([]byte)column_text(stmt, 0), &row, .JSON, context.temp_allocator) != nil || row.kind != kind || row.owner != owner do return nil, repo_err("invalid MCP metadata")
		append(&rows, row)
	}
	return rows[:], {}
}
