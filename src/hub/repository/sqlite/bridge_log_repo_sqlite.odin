package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// bridge_log_events repository (bridge_log relay). Called from the single
// writer thread (insert_batch/cap_bridge), the reaper (prune_before) and the
// owner API (list/delete). One multi-row INSERT per batch = one implicit
// transaction = one journal/fsync cycle on the shared connection; no explicit
// BEGIN, so a batch can never swallow another thread's autocommit write.

Bridge_Log_Repo_SQLite :: struct {
	conn: ^Conn,
}

// Rows per INSERT statement: 8 binds each, far under SQLITE_MAX_VARIABLE_NUMBER.
BRIDGE_LOG_INSERT_CHUNK :: 256

new_bridge_log_repository :: proc(impl: ^Bridge_Log_Repo_SQLite, conn: ^Conn) -> iface.Bridge_Log_Repository {
	impl.conn = conn
	return iface.Bridge_Log_Repository{
		ctx              = rawptr(impl),
		insert_batch     = bridge_log_insert_batch_sqlite,
		cap_bridge       = bridge_log_cap_bridge_sqlite,
		prune_before     = bridge_log_prune_before_sqlite,
		list_by_bridge   = bridge_log_list_by_bridge_sqlite,
		delete_by_bridge = bridge_log_delete_by_bridge_sqlite,
		count_by_bridge  = bridge_log_count_by_bridge_sqlite,
	}
}

@(private = "file")
repo_open :: proc(ctx: rawptr) -> (^Bridge_Log_Repo_SQLite, bool) {
	impl := (^Bridge_Log_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, false
	return impl, true
}

@(private = "file")
not_open :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "sqlite repository is not open")
}

bridge_log_insert_batch_sqlite :: proc(ctx: rawptr, events: []domain.Bridge_Log_Event) -> (int, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return 0, not_open()
	inserted := 0
	for start := 0; start < len(events); start += BRIDGE_LOG_INSERT_CHUNK {
		end := min(start + BRIDGE_LOG_INSERT_CHUNK, len(events))
		chunk := events[start:end]
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "INSERT INTO bridge_log_events (bridge_id, ts_ms, received_at, level, code, fields_json, count) VALUES ")
		for _, i in chunk {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "(?,?,?,?,?,?,?)")
		}
		strings.write_byte(&b, ';')
		query := strings.to_string(b)
		stmt: sqlite3_stmt = nil
		c_query := strings.clone_to_cstring(query, context.temp_allocator)
		if sqlite3_prepare_v2(impl.conn.db, c_query, -1, &stmt, nil) != SQLITE_OK {
			return inserted, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events insert")
		}
		for e, i in chunk {
			base := i * 7
			bind_text(stmt, base + 1, e.bridge_id)
			sqlite3_bind_int64(stmt, c.int(base + 2), e.ts_ms)
			sqlite3_bind_int64(stmt, c.int(base + 3), e.received_at)
			bind_text(stmt, base + 4, e.level)
			bind_text(stmt, base + 5, e.code)
			bind_text(stmt, base + 6, e.fields_json if e.fields_json != "" else "{}")
			sqlite3_bind_int(stmt, c.int(base + 7), c.int(max(e.count, 1)))
		}
		rc := sqlite3_step(stmt)
		sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return inserted, domain.domain_error(.Internal_Error, "failed to insert bridge_log_events batch")
		inserted += len(chunk)
	}
	return inserted, domain.Domain_Error{}
}

bridge_log_cap_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string, keep: int) -> (int, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return 0, not_open()
	// Everything older than the keep-th newest row goes. Served by the
	// (bridge_id, id DESC) index on both the subquery and the delete.
	query := "DELETE FROM bridge_log_events WHERE bridge_id = ?1 AND id <= (SELECT id FROM bridge_log_events WHERE bridge_id = ?1 ORDER BY id DESC LIMIT 1 OFFSET ?2);"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events cap")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	sqlite3_bind_int(stmt, 2, c.int(max(keep, 0)))
	if sqlite3_step(stmt) != SQLITE_DONE do return 0, domain.domain_error(.Internal_Error, "failed to cap bridge_log_events")
	return int(sqlite3_changes(impl.conn.db)), domain.Domain_Error{}
}

bridge_log_prune_before_sqlite :: proc(ctx: rawptr, received_at_before_ms: i64) -> (int, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return 0, not_open()
	query := "DELETE FROM bridge_log_events WHERE received_at < ?;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events prune")
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, received_at_before_ms)
	if sqlite3_step(stmt) != SQLITE_DONE do return 0, domain.domain_error(.Internal_Error, "failed to prune bridge_log_events")
	return int(sqlite3_changes(impl.conn.db)), domain.Domain_Error{}
}

bridge_log_list_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string, limit: int, before_id: i64) -> ([]domain.Bridge_Log_Event, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return nil, not_open()
	query := "SELECT id, bridge_id, ts_ms, received_at, level, code, fields_json, count FROM bridge_log_events WHERE bridge_id = ? AND (?2 <= 0 OR id < ?2) ORDER BY id DESC LIMIT ?3;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	sqlite3_bind_int64(stmt, 2, before_id)
	sqlite3_bind_int(stmt, 3, c.int(max(limit, 1)))
	out := make([dynamic]domain.Bridge_Log_Event)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Bridge_Log_Event{
			id          = sqlite3_column_int64(stmt, 0),
			bridge_id   = column_text(stmt, 1),
			ts_ms       = sqlite3_column_int64(stmt, 2),
			received_at = sqlite3_column_int64(stmt, 3),
			level       = column_text(stmt, 4),
			code        = column_text(stmt, 5),
			fields_json = column_text(stmt, 6),
			count       = int(sqlite3_column_int64(stmt, 7)),
		})
	}
	return out[:], domain.Domain_Error{}
}

bridge_log_delete_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return 0, not_open()
	query := "DELETE FROM bridge_log_events WHERE bridge_id = ?;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return 0, domain.domain_error(.Internal_Error, "failed to delete bridge_log_events")
	return int(sqlite3_changes(impl.conn.db)), domain.Domain_Error{}
}

bridge_log_count_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error) {
	impl, ok := repo_open(ctx)
	if !ok do return 0, not_open()
	query := "SELECT COUNT(*) FROM bridge_log_events WHERE bridge_id = ?;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare bridge_log_events count")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "failed to count bridge_log_events")
	return int(sqlite3_column_int64(stmt, 0)), domain.Domain_Error{}
}
