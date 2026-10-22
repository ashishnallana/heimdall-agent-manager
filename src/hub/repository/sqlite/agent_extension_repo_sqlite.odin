package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"

// Provider extension (ham.ext.v1) storage. Like bridge_log, each batch is ONE
// multi-row INSERT (an implicit transaction on the shared connection; no
// explicit BEGIN). seq is assigned here: MAX(seq)+1.. per instance. The bridge
// forwards one instance's events from a single thread, so concurrent batches for
// one instance are not expected; the UNIQUE(instance_id, seq) index turns a race
// into a retry instead of duplicate seqs.

// Rows per INSERT statement: 12 binds each, far under SQLITE_MAX_VARIABLE_NUMBER.
AGENT_EXT_INSERT_CHUNK :: 64

@(private = "file")
ext_db :: proc(ctx: rawptr) -> (sqlite3, bool) {
	impl := (^Agent_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, false
	return impl.conn.db, true
}

@(private = "file")
ext_not_open :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "sqlite repository is not open")
}

@(private = "file")
ext_max_seq :: proc(db: sqlite3, instance_id: string) -> (int, bool) {
	stmt: sqlite3_stmt = nil
	query := "SELECT COALESCE(MAX(seq), 0) FROM agent_extension_events WHERE instance_id = ?;"
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, false
	return int(sqlite3_column_int64(stmt, 0)), true
}

@(private = "file")
ext_insert_chunk :: proc(db: sqlite3, instance_id: string, chunk: []domain.Agent_Extension_Event) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "INSERT INTO agent_extension_events (instance_id, seq, event, ts, session_id, agent_id, agent_type, tool_name, tool_use_id, file_path, payload, created_at) VALUES ")
	for _, i in chunk {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "(?,?,?,?,?,?,?,?,?,?,?,?)")
	}
	strings.write_byte(&b, ';')
	query := strings.to_string(b)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	for ev, i in chunk {
		base := i * 12
		bind_text(stmt, base + 1, instance_id)
		sqlite3_bind_int64(stmt, c.int(base + 2), i64(ev.seq))
		bind_text(stmt, base + 3, ev.event)
		bind_text(stmt, base + 4, ev.ts)
		bind_text(stmt, base + 5, ev.session_id)
		bind_text(stmt, base + 6, ev.agent_id)
		bind_text(stmt, base + 7, ev.agent_type)
		bind_text(stmt, base + 8, ev.tool_name)
		bind_text(stmt, base + 9, ev.tool_use_id)
		bind_text(stmt, base + 10, ev.file_path)
		bind_text(stmt, base + 11, "{}" if ev.payload == "" else ev.payload)
		bind_text(stmt, base + 12, ev.created_at)
	}
	return sqlite3_step(stmt) == SQLITE_DONE
}

agent_ext_insert_events_sqlite :: proc(ctx: rawptr, instance_id: string, events: []domain.Agent_Extension_Event, keep: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error) {
	db, ok := ext_db(ctx)
	if !ok do return nil, ext_not_open()
	if strings.trim_space(instance_id) == "" do return nil, domain.domain_error(.Validation_Failed, "instance_id is required")
	if len(events) == 0 do return nil, {}
	stored := make([]domain.Agent_Extension_Event, len(events))
	copy(stored, events)
	for start := 0; start < len(stored); start += AGENT_EXT_INSERT_CHUNK {
		end := min(start + AGENT_EXT_INSERT_CHUNK, len(stored))
		chunk := stored[start:end]
		inserted := false
		// One retry: a concurrent batch for the same instance took our seqs.
		for attempt := 0; attempt < 2 && !inserted; attempt += 1 {
			base, got := ext_max_seq(db, instance_id)
			if !got do break
			for &ev, i in chunk {
				ev.instance_id = instance_id
				ev.seq = base + i + 1
			}
			inserted = ext_insert_chunk(db, instance_id, chunk)
		}
		if !inserted do return nil, domain.domain_error(.Internal_Error, "failed to insert agent extension events")
	}
	if keep > 0 do agent_ext_trim(db, instance_id, keep)
	return stored, {}
}

// agent_ext_trim keeps only the newest `keep` events of one instance (retention).
agent_ext_trim :: proc(db: sqlite3, instance_id: string, keep: int) -> bool {
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM agent_extension_events WHERE instance_id = ?1 AND seq <= (SELECT seq FROM agent_extension_events WHERE instance_id = ?1 ORDER BY seq DESC LIMIT 1 OFFSET ?2);"
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	sqlite3_bind_int64(stmt, 2, i64(keep))
	return sqlite3_step(stmt) == SQLITE_DONE
}

agent_ext_update_instance_sqlite :: proc(ctx: rawptr, instance_id: string, update: domain.Agent_Extension_Instance_Update) -> (bool, domain.Domain_Error) {
	db, ok := ext_db(ctx)
	if !ok do return false, ext_not_open()
	// NULLIF(?, '') keeps the stored value for every field the batch did not set.
	stmt: sqlite3_stmt = nil
	query := "UPDATE agent_instances SET provider_session_id = COALESCE(NULLIF(?1, ''), provider_session_id), provider_transcript_path = COALESCE(NULLIF(?2, ''), provider_transcript_path), extension_provider = COALESCE(NULLIF(?3, ''), extension_provider), extension_version = COALESCE(NULLIF(?4, ''), extension_version), extension_capabilities = COALESCE(NULLIF(?5, ''), extension_capabilities), extension_last_seen_at = COALESCE(NULLIF(?6, ''), extension_last_seen_at) WHERE agent_instance_id = ?7;"
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare agent extension instance update")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, update.provider_session_id)
	bind_text(stmt, 2, update.provider_transcript_path)
	bind_text(stmt, 3, update.extension_provider)
	bind_text(stmt, 4, update.extension_version)
	bind_text(stmt, 5, update.extension_capabilities)
	bind_text(stmt, 6, update.extension_last_seen_at)
	bind_text(stmt, 7, instance_id)
	if sqlite3_step(stmt) != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "failed to update agent extension instance fields")
	return true, {}
}

agent_ext_list_events_sqlite :: proc(ctx: rawptr, instance_id, agent_id: string, after_seq, limit: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error) {
	db, ok := ext_db(ctx)
	if !ok do return nil, ext_not_open()
	lim := limit
	if lim <= 0 || lim > 500 do lim = 100
	query := "SELECT instance_id, seq, event, ts, session_id, agent_id, agent_type, tool_name, tool_use_id, file_path, payload, created_at FROM agent_extension_events WHERE instance_id = ?1 AND seq > ?2 AND (?3 = '' OR agent_id = (CASE WHEN ?3 = 'main' THEN '' ELSE ?3 END)) ORDER BY seq ASC LIMIT ?4;"
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare agent extension event list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	sqlite3_bind_int64(stmt, 2, i64(after_seq))
	bind_text(stmt, 3, agent_id)
	sqlite3_bind_int64(stmt, 4, i64(lim))
	out := make([dynamic]domain.Agent_Extension_Event)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Agent_Extension_Event{
			instance_id = column_text(stmt, 0),
			seq         = int(sqlite3_column_int64(stmt, 1)),
			event       = column_text(stmt, 2),
			ts          = column_text(stmt, 3),
			session_id  = column_text(stmt, 4),
			agent_id    = column_text(stmt, 5),
			agent_type  = column_text(stmt, 6),
			tool_name   = column_text(stmt, 7),
			tool_use_id = column_text(stmt, 8),
			file_path   = column_text(stmt, 9),
			payload     = column_text(stmt, 10),
			created_at  = column_text(stmt, 11),
		})
	}
	return out[:], {}
}

agent_ext_list_subagents_sqlite :: proc(ctx: rawptr, instance_id: string) -> ([]domain.Agent_Subagent_Summary, domain.Domain_Error) {
	db, ok := ext_db(ctx)
	if !ok do return nil, ext_not_open()
	// One row per subagent id, ordered by first appearance. A subagent is
	// "stopped" once a subagent.stop event exists for it.
	query := `SELECT agent_id,
		COALESCE(MAX(NULLIF(agent_type, '')), ''),
		COALESCE((SELECT COALESCE(json_extract(s.payload, '$.description'), '') FROM agent_extension_events s WHERE s.instance_id = e.instance_id AND s.agent_id = e.agent_id AND s.event = 'subagent.start' ORDER BY s.seq ASC LIMIT 1), ''),
		CASE WHEN SUM(event = 'subagent.stop') > 0 THEN 'stopped' ELSE 'running' END,
		COALESCE(MIN(CASE WHEN event = 'subagent.start' THEN COALESCE(NULLIF(ts, ''), created_at) END), MIN(COALESCE(NULLIF(ts, ''), created_at))),
		COALESCE(MAX(CASE WHEN event = 'subagent.stop' THEN COALESCE(NULLIF(ts, ''), created_at) END), ''),
		COUNT(*)
		FROM agent_extension_events e WHERE instance_id = ?1 AND agent_id != ''
		GROUP BY agent_id ORDER BY MIN(seq) ASC;`
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare subagent summary")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	out := make([dynamic]domain.Agent_Subagent_Summary)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Agent_Subagent_Summary{
			agent_id    = column_text(stmt, 0),
			agent_type  = column_text(stmt, 1),
			description = column_text(stmt, 2),
			status      = column_text(stmt, 3),
			started_at  = column_text(stmt, 4),
			stopped_at  = column_text(stmt, 5),
			event_count = int(sqlite3_column_int64(stmt, 6)),
		})
	}
	return out[:], {}
}

agent_ext_list_files_sqlite :: proc(ctx: rawptr, instance_id: string) -> ([]domain.Agent_File_Edit_Summary, domain.Domain_Error) {
	db, ok := ext_db(ctx)
	if !ok do return nil, ext_not_open()
	query := `SELECT g.file_path, g.n, g.last_seq, COALESCE(NULLIF(l.ts, ''), l.created_at), g.agents
		FROM (SELECT file_path, COUNT(*) AS n, MAX(seq) AS last_seq, COALESCE(GROUP_CONCAT(DISTINCT agent_id), '') AS agents
			FROM agent_extension_events WHERE instance_id = ?1 AND event = 'file.edit' AND file_path != ''
			GROUP BY file_path) g
		JOIN agent_extension_events l ON l.instance_id = ?1 AND l.seq = g.last_seq
		ORDER BY g.last_seq DESC;`
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare files-edited summary")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, instance_id)
	out := make([dynamic]domain.Agent_File_Edit_Summary)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Agent_File_Edit_Summary{
			file_path  = column_text(stmt, 0),
			edit_count = int(sqlite3_column_int64(stmt, 1)),
			last_seq   = int(sqlite3_column_int64(stmt, 2)),
			last_at    = column_text(stmt, 3),
			agent_ids  = column_text(stmt, 4),
		})
	}
	return out[:], {}
}
