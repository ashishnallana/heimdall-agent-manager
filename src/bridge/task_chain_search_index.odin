package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"

// Task-chain search plaintext is deliberately confined to this in-memory SQLite
// database. The Hub remains a ciphertext source and relay; closing this handle on
// vault lock makes the searchable plaintext unreachable without leaving a file.
foreign import task_chain_search_sqlite "system:sqlite3"

Task_Chain_Search_SQLite :: distinct rawptr
Task_Chain_Search_Stmt :: distinct rawptr

TASK_CHAIN_SEARCH_SQLITE_OK :: 0
TASK_CHAIN_SEARCH_SQLITE_ROW :: 100
TASK_CHAIN_SEARCH_SQLITE_DONE :: 101
TASK_CHAIN_SEARCH_SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention="c")
foreign task_chain_search_sqlite {
	sqlite3_open :: proc(filename: cstring, db: [^]Task_Chain_Search_SQLite) -> c.int ---
	sqlite3_close :: proc(db: Task_Chain_Search_SQLite) -> c.int ---
	sqlite3_exec :: proc(db: Task_Chain_Search_SQLite, sql: cstring, callback, arg: rawptr, errmsg: [^]cstring) -> c.int ---
	sqlite3_free :: proc(ptr: rawptr) ---
	sqlite3_prepare_v2 :: proc(db: Task_Chain_Search_SQLite, sql: cstring, bytes: c.int, stmt: [^]Task_Chain_Search_Stmt, tail: [^]cstring) -> c.int ---
	sqlite3_finalize :: proc(stmt: Task_Chain_Search_Stmt) -> c.int ---
	sqlite3_step :: proc(stmt: Task_Chain_Search_Stmt) -> c.int ---
	sqlite3_bind_text :: proc(stmt: Task_Chain_Search_Stmt, index: c.int, value: cstring, bytes: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int :: proc(stmt: Task_Chain_Search_Stmt, index: c.int, value: c.int) -> c.int ---
	sqlite3_column_text :: proc(stmt: Task_Chain_Search_Stmt, column: c.int) -> cstring ---
	sqlite3_column_bytes :: proc(stmt: Task_Chain_Search_Stmt, column: c.int) -> c.int ---
	sqlite3_column_double :: proc(stmt: Task_Chain_Search_Stmt, column: c.int) -> c.double ---
}

Task_Chain_Search_Document :: struct {
	chain_id: string,
	project_id: string,
	status: string,
	source_revision: i64,
	updated_at: string,
	title: string,
	description: string,
}

Task_Chain_Search_Hit :: struct {
	chain_id: string,
	project_id: string,
	status: string,
	updated_at: string,
	title: string,
	description_snippet: string,
	score: f64,
}

Task_Chain_Search_Change :: struct {
	operation: string,
	document: Task_Chain_Search_Document,
	chain_id: string,
	revision: i64,
}

Task_Chain_Search_Index :: struct {
	db: Task_Chain_Search_SQLite,
	indexed_revision: i64,
}

Task_Chain_Search_State :: struct {
	mutex: sync.RW_Mutex,
	index: Task_Chain_Search_Index,
	ready: bool,
	stale: bool,
	vault_generation: i64,
}

bridge_task_chain_search_state: Task_Chain_Search_State

TASK_CHAIN_SEARCH_SCHEMA :: `
PRAGMA journal_mode=MEMORY;
PRAGMA synchronous=OFF;
PRAGMA temp_store=MEMORY;
CREATE TABLE task_chain_search_docs (
  rowid INTEGER PRIMARY KEY,
  chain_id TEXT NOT NULL UNIQUE,
  project_id TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  source_revision INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL
);
CREATE VIRTUAL TABLE task_chain_search_fts USING fts5(
  title,
  description,
  content='task_chain_search_docs',
  content_rowid='rowid',
  tokenize='unicode61'
);
CREATE TRIGGER task_chain_search_docs_ai AFTER INSERT ON task_chain_search_docs BEGIN
  INSERT INTO task_chain_search_fts(rowid, title, description)
  VALUES (new.rowid, new.title, new.description);
END;
CREATE TRIGGER task_chain_search_docs_ad AFTER DELETE ON task_chain_search_docs BEGIN
  INSERT INTO task_chain_search_fts(task_chain_search_fts, rowid, title, description)
  VALUES ('delete', old.rowid, old.title, old.description);
END;
CREATE TRIGGER task_chain_search_docs_au AFTER UPDATE ON task_chain_search_docs BEGIN
  INSERT INTO task_chain_search_fts(task_chain_search_fts, rowid, title, description)
  VALUES ('delete', old.rowid, old.title, old.description);
  INSERT INTO task_chain_search_fts(rowid, title, description)
  VALUES (new.rowid, new.title, new.description);
END;
`

task_chain_search_exec :: proc(index: ^Task_Chain_Search_Index, sql: string) -> bool {
	if index == nil || index.db == nil do return false
	err_msg: cstring
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	rc := sqlite3_exec(index.db, c_sql, nil, nil, &err_msg)
	if rc == TASK_CHAIN_SEARCH_SQLITE_OK do return true
	if err_msg != nil {
		fmt.eprintln("task-chain search sqlite error:", string(err_msg))
		sqlite3_free(rawptr(err_msg))
	}
	return false
}

task_chain_search_index_open :: proc() -> (Task_Chain_Search_Index, bool) {
	index: Task_Chain_Search_Index
	path := strings.clone_to_cstring(":memory:", context.temp_allocator)
	if sqlite3_open(path, &index.db) != TASK_CHAIN_SEARCH_SQLITE_OK {
		task_chain_search_index_close(&index)
		return Task_Chain_Search_Index{}, false
	}
	if !task_chain_search_exec(&index, TASK_CHAIN_SEARCH_SCHEMA) {
		task_chain_search_index_close(&index)
		return Task_Chain_Search_Index{}, false
	}
	return index, true
}

task_chain_search_index_close :: proc(index: ^Task_Chain_Search_Index) {
	if index == nil do return
	if index.db != nil do _ = sqlite3_close(index.db)
	index^ = Task_Chain_Search_Index{}
}

task_chain_search_bind_text :: proc(stmt: Task_Chain_Search_Stmt, index: int, value: string) -> bool {
	c_value := strings.clone_to_cstring(value, context.temp_allocator)
	return sqlite3_bind_text(stmt, c.int(index), c_value, c.int(len(value)), TASK_CHAIN_SEARCH_SQLITE_TRANSIENT) == TASK_CHAIN_SEARCH_SQLITE_OK
}

task_chain_search_column_text :: proc(stmt: Task_Chain_Search_Stmt, column: int) -> string {
	value := sqlite3_column_text(stmt, c.int(column))
	if value == nil do return ""
	n := int(sqlite3_column_bytes(stmt, c.int(column)))
	if n <= 0 do return ""
	bytes := ([^]byte)(rawptr(value))[:n]
	return strings.clone(string(bytes), runtime.default_allocator())
}

task_chain_search_index_upsert :: proc(index: ^Task_Chain_Search_Index, document: Task_Chain_Search_Document) -> bool {
	if index == nil || index.db == nil || strings.trim_space(document.chain_id) == "" do return false
	query := `INSERT INTO task_chain_search_docs
    (chain_id, project_id, status, source_revision, updated_at, title, description)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(chain_id) DO UPDATE SET
      project_id=excluded.project_id,
      status=excluded.status,
      source_revision=excluded.source_revision,
      updated_at=excluded.updated_at,
      title=excluded.title,
      description=excluded.description
    WHERE excluded.source_revision >= task_chain_search_docs.source_revision;`
	stmt: Task_Chain_Search_Stmt
	c_query := strings.clone_to_cstring(query, context.temp_allocator)
	if sqlite3_prepare_v2(index.db, c_query, -1, &stmt, nil) != TASK_CHAIN_SEARCH_SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if !task_chain_search_bind_text(stmt, 1, document.chain_id) ||
	   !task_chain_search_bind_text(stmt, 2, document.project_id) ||
	   !task_chain_search_bind_text(stmt, 3, document.status) ||
	   !task_chain_search_bind_text(stmt, 4, fmt.tprintf("%d", document.source_revision)) ||
	   !task_chain_search_bind_text(stmt, 5, document.updated_at) ||
	   !task_chain_search_bind_text(stmt, 6, document.title) ||
	   !task_chain_search_bind_text(stmt, 7, document.description) {
		return false
	}
	if sqlite3_step(stmt) != TASK_CHAIN_SEARCH_SQLITE_DONE do return false
	if document.source_revision > index.indexed_revision do index.indexed_revision = document.source_revision
	return true
}

task_chain_search_index_delete :: proc(index: ^Task_Chain_Search_Index, chain_id: string, source_revision: i64) -> bool {
	if index == nil || index.db == nil || strings.trim_space(chain_id) == "" do return false
	query := "DELETE FROM task_chain_search_docs WHERE chain_id = ? AND source_revision <= ?;"
	stmt: Task_Chain_Search_Stmt
	c_query := strings.clone_to_cstring(query, context.temp_allocator)
	if sqlite3_prepare_v2(index.db, c_query, -1, &stmt, nil) != TASK_CHAIN_SEARCH_SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if !task_chain_search_bind_text(stmt, 1, chain_id) ||
	   !task_chain_search_bind_text(stmt, 2, fmt.tprintf("%d", source_revision)) {
		return false
	}
	if sqlite3_step(stmt) != TASK_CHAIN_SEARCH_SQLITE_DONE do return false
	if source_revision > index.indexed_revision do index.indexed_revision = source_revision
	return true
}

// Treat user text as literal prefix terms, not as FTS syntax. This both avoids
// MATCH parse errors and makes incremental typing useful without exposing a rich
// query language through the encrypted RPC.
task_chain_search_match_query :: proc(query: string) -> string {
	parts := strings.fields(query)
	defer delete(parts)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	written := 0
	for part in parts {
		term := strings.trim_space(part)
		if term == "" do continue
		if written > 0 do strings.write_string(&b, " AND ")
		strings.write_byte(&b, '"')
		for ch in term {
			if ch == '"' do strings.write_byte(&b, '"')
			strings.write_rune(&b, ch)
		}
		strings.write_string(&b, `"*`)
		written += 1
	}
	if written == 0 do return ""
	return strings.clone(strings.to_string(b))
}

task_chain_search_index_query :: proc(index: ^Task_Chain_Search_Index, query, project_id, status: string, limit: int) -> ([]Task_Chain_Search_Hit, bool) {
	out := make([dynamic]Task_Chain_Search_Hit, runtime.default_allocator())
	if index == nil || index.db == nil do return out[:], false
	match_query := task_chain_search_match_query(query)
	defer delete(match_query)
	if match_query == "" do return out[:], true
	bounded_limit := limit
	if bounded_limit <= 0 do bounded_limit = 20
	if bounded_limit > 50 do bounded_limit = 50
	sql := `SELECT d.chain_id, d.project_id, d.status, d.updated_at, d.title,
      snippet(task_chain_search_fts, 1, '[', ']', '…', 12),
      -bm25(task_chain_search_fts, 10.0, 1.0)
    FROM task_chain_search_fts
    JOIN task_chain_search_docs d ON d.rowid = task_chain_search_fts.rowid
    WHERE task_chain_search_fts MATCH ?
      AND (? = '' OR d.project_id = ?)
      AND (? = '' OR d.status = ?)
    ORDER BY bm25(task_chain_search_fts, 10.0, 1.0), d.updated_at DESC, d.chain_id ASC
    LIMIT ?;`
	stmt: Task_Chain_Search_Stmt
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	if sqlite3_prepare_v2(index.db, c_sql, -1, &stmt, nil) != TASK_CHAIN_SEARCH_SQLITE_OK do return out[:], false
	defer sqlite3_finalize(stmt)
	if !task_chain_search_bind_text(stmt, 1, match_query) ||
	   !task_chain_search_bind_text(stmt, 2, project_id) ||
	   !task_chain_search_bind_text(stmt, 3, project_id) ||
	   !task_chain_search_bind_text(stmt, 4, status) ||
	   !task_chain_search_bind_text(stmt, 5, status) ||
	   sqlite3_bind_int(stmt, 6, c.int(bounded_limit)) != TASK_CHAIN_SEARCH_SQLITE_OK {
		return out[:], false
	}
	for sqlite3_step(stmt) == TASK_CHAIN_SEARCH_SQLITE_ROW {
		append(&out, Task_Chain_Search_Hit{
			chain_id = task_chain_search_column_text(stmt, 0),
			project_id = task_chain_search_column_text(stmt, 1),
			status = task_chain_search_column_text(stmt, 2),
			updated_at = task_chain_search_column_text(stmt, 3),
			title = task_chain_search_column_text(stmt, 4),
			description_snippet = task_chain_search_column_text(stmt, 5),
			score = f64(sqlite3_column_double(stmt, 6)),
		})
	}
	return out[:], true
}

task_chain_search_hits_destroy :: proc(hits: []Task_Chain_Search_Hit) {
	for hit in hits {
		delete(hit.chain_id, runtime.default_allocator())
		delete(hit.project_id, runtime.default_allocator())
		delete(hit.status, runtime.default_allocator())
		delete(hit.updated_at, runtime.default_allocator())
		delete(hit.title, runtime.default_allocator())
		delete(hit.description_snippet, runtime.default_allocator())
	}
	delete(hits, runtime.default_allocator())
}

// Rebuild off to the side and swap only after every document is indexed. A failed
// refresh therefore cannot destroy the last valid searchable snapshot.
bridge_task_chain_search_rebuild :: proc(documents: []Task_Chain_Search_Document, revision: i64, expected_generation: i64 = -1) -> bool {
	next, ok := task_chain_search_index_open()
	if !ok do return false
	if !task_chain_search_exec(&next, "BEGIN IMMEDIATE;") {
		task_chain_search_index_close(&next)
		return false
	}
	for document in documents {
		if !task_chain_search_index_upsert(&next, document) {
			_ = task_chain_search_exec(&next, "ROLLBACK;")
			task_chain_search_index_close(&next)
			return false
		}
	}
	if !task_chain_search_exec(&next, "COMMIT;") {
		task_chain_search_index_close(&next)
		return false
	}
	next.indexed_revision = revision
	sync.rw_mutex_lock(&bridge_task_chain_search_state.mutex)
	if expected_generation >= 0 && bridge_task_chain_search_state.vault_generation != expected_generation {
		sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
		task_chain_search_index_close(&next)
		return false
	}
	old := bridge_task_chain_search_state.index
	bridge_task_chain_search_state.index = next
	bridge_task_chain_search_state.ready = true
	bridge_task_chain_search_state.stale = false
	sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
	task_chain_search_index_close(&old)
	return true
}

bridge_task_chain_search_lock :: proc() {
	sync.rw_mutex_lock(&bridge_task_chain_search_state.mutex)
	bridge_task_chain_search_state.vault_generation += 1
	old := bridge_task_chain_search_state.index
	bridge_task_chain_search_state.index = Task_Chain_Search_Index{}
	bridge_task_chain_search_state.ready = false
	bridge_task_chain_search_state.stale = false
	sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
	task_chain_search_index_close(&old)
}

bridge_task_chain_search_generation :: proc() -> i64 {
	sync.rw_mutex_shared_lock(&bridge_task_chain_search_state.mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_task_chain_search_state.mutex)
	return bridge_task_chain_search_state.vault_generation
}

bridge_task_chain_search_mark_stale :: proc() {
	sync.rw_mutex_lock(&bridge_task_chain_search_state.mutex)
	bridge_task_chain_search_state.stale = bridge_task_chain_search_state.ready
	sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
}

bridge_task_chain_search_apply_changes :: proc(documents: []Task_Chain_Search_Document, deleted_chain_ids: []string, revision: i64) -> bool {
	sync.rw_mutex_lock(&bridge_task_chain_search_state.mutex)
	defer sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
	if !bridge_task_chain_search_state.ready || bridge_task_chain_search_state.index.db == nil do return false
	index := &bridge_task_chain_search_state.index
	if !task_chain_search_exec(index, "BEGIN IMMEDIATE;") do return false
	for document in documents {
		if !task_chain_search_index_upsert(index, document) {
			_ = task_chain_search_exec(index, "ROLLBACK;")
			bridge_task_chain_search_state.stale = true
			return false
		}
	}
	for chain_id in deleted_chain_ids {
		if !task_chain_search_index_delete(index, chain_id, revision) {
			_ = task_chain_search_exec(index, "ROLLBACK;")
			bridge_task_chain_search_state.stale = true
			return false
		}
	}
	if !task_chain_search_exec(index, "COMMIT;") {
		bridge_task_chain_search_state.stale = true
		return false
	}
	index.indexed_revision = revision
	bridge_task_chain_search_state.stale = false
	return true
}

// Applies feed entries in revision order. This matters when a chain is deleted and
// recreated within one page: grouping upserts and tombstones would let the older
// operation win even though the feed itself is correctly ordered.
bridge_task_chain_search_apply_ordered_changes :: proc(changes: []Task_Chain_Search_Change, revision: i64, expected_generation: i64 = -1) -> bool {
	sync.rw_mutex_lock(&bridge_task_chain_search_state.mutex)
	defer sync.rw_mutex_unlock(&bridge_task_chain_search_state.mutex)
	if expected_generation >= 0 && bridge_task_chain_search_state.vault_generation != expected_generation do return false
	if !bridge_task_chain_search_state.ready || bridge_task_chain_search_state.index.db == nil do return false
	index := &bridge_task_chain_search_state.index
	if !task_chain_search_exec(index, "BEGIN IMMEDIATE;") do return false
	for change in changes {
		ok := task_chain_search_index_upsert(index, change.document) if change.operation == "upsert" else task_chain_search_index_delete(index, change.chain_id, change.revision)
		if !ok {
			_ = task_chain_search_exec(index, "ROLLBACK;")
			bridge_task_chain_search_state.stale = true
			return false
		}
	}
	if !task_chain_search_exec(index, "COMMIT;") {
		bridge_task_chain_search_state.stale = true
		return false
	}
	index.indexed_revision = revision
	bridge_task_chain_search_state.stale = false
	return true
}

bridge_task_chain_search_status :: proc() -> (ready, stale: bool, revision: i64) {
	sync.rw_mutex_shared_lock(&bridge_task_chain_search_state.mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_task_chain_search_state.mutex)
	return bridge_task_chain_search_state.ready, bridge_task_chain_search_state.stale, bridge_task_chain_search_state.index.indexed_revision
}

bridge_task_chain_search_query :: proc(query, project_id, status: string, limit: int) -> ([]Task_Chain_Search_Hit, bool, bool, i64) {
	sync.rw_mutex_shared_lock(&bridge_task_chain_search_state.mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_task_chain_search_state.mutex)
	if !bridge_task_chain_search_state.ready do return nil, false, false, 0
	hits, ok := task_chain_search_index_query(&bridge_task_chain_search_state.index, query, project_id, status, limit)
	return hits, ok, bridge_task_chain_search_state.stale, bridge_task_chain_search_state.index.indexed_revision
}
