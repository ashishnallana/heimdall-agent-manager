package sqlite

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"

// FTS index recovery for the search feature (SEARCH BUG: task/agent-instance UPDATE
// jam). Migrations 029/030 index text via per-table EXTERNAL-CONTENT fts5 vtables
// kept in sync by AFTER INSERT/UPDATE/DELETE triggers. The UPDATE/DELETE triggers
// issue fts5's external-content 'delete' op (INSERT INTO <x>_fts(<x>_fts,rowid,...)
// VALUES('delete', old.rowid, ...)). That op requires the row's postings to be
// PRESENT in the index; if a bad manual rebuild left a base row unindexed (e.g. a
// raw `DELETE FROM <x>_fts` or a partial/interrupted rebuild instead of the
// supported 'rebuild' op), the next UPDATE/DELETE of that row raises SQLITE_CORRUPT
// ("database disk image is malformed") and rolls back the whole write — so every
// UPDATE to the affected row fails while INSERTs (which only run the delete-free AI
// trigger) still succeed. repair_fts_indexes() re-syncs the indexes with the ONLY
// supported rebuild op and unsticks those rows; step_write_healing() self-heals the
// same drift at write time.

// Fts_Index pairs an fts5 index vtable with the base table it mirrors.
Fts_Index :: struct {
	base: string,
	fts:  string,
}

// FTS_INDEX_TABLES is the canonical set of external-content fts5 indexes the hub
// maintains. Keep it in lockstep with migrations 029 (task_comments) and 030 (the
// rest); test_fts_index_tables_cover_providers guards against drift from the search
// providers.
FTS_INDEX_TABLES := [?]Fts_Index{
	{base = "task_comments", fts = "task_comments_fts"},
	{base = "chat_messages", fts = "chat_messages_fts"},
	{base = "chat_conversations", fts = "chat_conversations_fts"},
	{base = "agents", fts = "agents_fts"},
	{base = "agent_instances", fts = "agent_instances_fts"},
	{base = "task_chains", fts = "task_chains_fts"},
	{base = "tasks", fts = "tasks_fts"},
	{base = "projects", fts = "projects_fts"},
	{base = "artifacts", fts = "artifacts_fts"},
	{base = "memories", fts = "memories_fts"},
}

// repair_fts_indexes re-syncs the fts5 indexes to their base rows using the ONLY
// supported external-content rebuild op — INSERT INTO <x>_fts(<x>_fts) VALUES
// ('rebuild') — inside a single transaction. This is the recovery (re-sync) path
// for FTS index drift; it is idempotent and safe to run repeatedly, and a no-op
// (ok) when FTS5 is not compiled in. When only_drifted is true it rebuilds just the
// indexes whose posting count no longer matches their base table (cheap boot-time
// reconcile); when false it rebuilds every existing index (used to self-heal after
// a corruption is observed). Returns the number of indexes rebuilt.
repair_fts_indexes :: proc(conn: ^Conn, only_drifted := false) -> (rebuilt: int, ok: bool, err: domain.Domain_Error) {
	if conn == nil || conn.db == nil do return 0, false, domain.domain_error(.Internal_Error, "database connection is not open")
	if !fts5_available(conn) do return 0, true, domain.Domain_Error{}
	tx_start := time.tick_now()
	kind := conn_kind_of(conn.db)
	if !exec(conn, "BEGIN IMMEDIATE;") {
		tx_observe(kind, .Fts_Repair, true, .Begin_Failed, tx_start)
		return 0, false, domain.domain_error(.Internal_Error, "failed to begin fts repair transaction")
	}
	for idx in FTS_INDEX_TABLES {
		if !sqlite_object_exists(conn, idx.fts) do continue
		if only_drifted {
			// Skip indexes we can confirm are in sync; rebuild when drifted or when
			// drift can't be determined (be conservative and re-sync).
			if drift, known := fts_index_has_drift(conn, idx); known && !drift do continue
		}
		if !fts_rebuild_one(conn, idx.fts) {
			exec(conn, "ROLLBACK;")
			tx_observe(kind, .Fts_Repair, true, .Rollback, tx_start)
			return rebuilt, false, domain.domain_error(.Internal_Error, "fts index rebuild failed")
		}
		rebuilt += 1
	}
	if !exec(conn, "COMMIT;") {
		exec(conn, "ROLLBACK;")
		tx_observe(kind, .Fts_Repair, true, .Commit_Failed, tx_start)
		return rebuilt, false, domain.domain_error(.Internal_Error, "failed to commit fts repair transaction")
	}
	tx_observe(kind, .Fts_Repair, true, .Commit, tx_start)
	return rebuilt, true, domain.Domain_Error{}
}

// fts_index_has_drift reports whether an fts index is missing postings for some
// base rows — its %_docsize shadow holds fewer docs than the base table has rows.
// That is exactly the state that makes the sync triggers' 'delete' op corrupt. ok
// is false when the counts can't be read (e.g. no docsize shadow), leaving the
// caller to decide conservatively.
fts_index_has_drift :: proc(conn: ^Conn, idx: Fts_Index) -> (drift: bool, ok: bool) {
	base_n, base_ok := scalar_count(conn, fmt.tprintf("SELECT count(*) FROM %s;", idx.base))
	idx_n, idx_ok := scalar_count(conn, fmt.tprintf("SELECT count(*) FROM %s_docsize;", idx.fts))
	if !base_ok || !idx_ok do return false, false
	return base_n != idx_n, true
}

// fts_rebuild_one re-syncs a single fts index to its base table via the supported
// 'rebuild' op. Never repair with a raw `DELETE FROM <x>_fts` or a partial
// re-backfill — those leave rows unindexed and reintroduce the corruption.
fts_rebuild_one :: proc(conn: ^Conn, fts: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("INSERT INTO %s(%s) VALUES('rebuild');", fts, fts)
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_DONE
}

// scalar_count runs a `SELECT count(*) ...` query and returns (n, ok).
scalar_count :: proc(conn: ^Conn, query: string) -> (int, bool) {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), c.int(-1), &stmt, nil) != SQLITE_OK do return 0, false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, false
	return int_v(column_text(stmt, 0)), true
}

// step_write_healing steps a write statement and self-heals a drifted FTS index: if
// the step fails with SQLITE_CORRUPT — an external-content fts5 sync trigger hit a
// base row missing from its index — it re-syncs the indexes and retries the write
// exactly ONCE (bounded; never loops). Returns the final sqlite step code, so the
// caller can distinguish a genuine save conflict (SQLITE handled) from residual
// index corruption (still SQLITE_CORRUPT) and report an accurate error.
//
// Assumes autocommit (no caller-open transaction): repair_fts_indexes opens its own
// BEGIN IMMEDIATE, which the repo save procs satisfy (they step in autocommit). If
// ever called inside an outer transaction the repair is a no-op and the accurate
// error surfaces; the boot reconcile remains the backstop.
//
// `loc` is forwarded so both steps (and the retry) are charged to the caller's
// telemetry site, not to this helper.
step_write_healing :: proc(conn: ^Conn, stmt: sqlite3_stmt, loc := #caller_location) -> c.int {
	rc := sqlite3_step(stmt, loc)
	if rc == SQLITE_CORRUPT {
		repair_fts_indexes(conn) // full re-sync; the retry surfaces any residual failure
		sqlite3_reset(stmt)
		rc = sqlite3_step(stmt, loc)
	}
	return rc
}
