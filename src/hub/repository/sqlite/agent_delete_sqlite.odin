package sqlite

import bootcache "odin_test:hub/bootcache"
import domain "odin_test:hub/domain"

// Agent deletion is allowed only for an agent nothing refers to. Each USE_* clause
// below is one category of durable reference, written against ?1 = agent_id. JSON
// columns are matched on the quoted id ("agt_..."), which never matches a longer id
// and, unlike LIKE, has no wildcard characters to escape.
//
// The same clauses feed both the usage counts the UI shows and the NOT EXISTS
// guards on the DELETE, so the two can never disagree about what "in use" means.

@(private = "file")
QUOTED_ID :: `('"' || ?1 || '"')`

@(private = "file")
USE_INSTANCES :: "SELECT 1 FROM agent_instances WHERE agent_id = ?1"
@(private = "file")
USE_CONVERSATIONS :: "SELECT 1 FROM chat_conversations WHERE agent_id = ?1"
@(private = "file")
USE_MESSAGES :: "SELECT 1 FROM chat_messages WHERE sender_agent_id = ?1"
@(private = "file")
USE_ARTIFACTS :: "SELECT 1 FROM artifacts WHERE agent_id = ?1"
@(private = "file")
USE_CHAINS :: "SELECT task_chain_id FROM task_chain_fleets WHERE agent_id = ?1 UNION SELECT chain_id FROM task_chain_members WHERE agent_id = ?1 UNION SELECT chain_id FROM task_chains WHERE instr(defaults_json, " + QUOTED_ID + ") > 0"
@(private = "file")
USE_TASKS :: "SELECT task_id FROM tasks WHERE instr(brief_json, " + QUOTED_ID + ") > 0 UNION SELECT task_id FROM task_reviews WHERE reviewer_agent_id = ?1 UNION SELECT task_id FROM task_events WHERE instr(payload_json, " + QUOTED_ID + ") > 0"
@(private = "file")
USE_MEMORIES :: "SELECT 1 FROM memories WHERE instr(agent_ids, " + QUOTED_ID + ") > 0"
@(private = "file")
USE_ACTIONS :: "SELECT 1 FROM actions WHERE target_agent_id = ?1"
@(private = "file")
USE_WORKFLOWS :: "SELECT def_id FROM workflow_definitions WHERE instr(body_json, " + QUOTED_ID + ") > 0 UNION ALL SELECT run_id FROM workflow_runs WHERE instr(spec_json, " + QUOTED_ID + ") > 0 OR instr(inputs_json, " + QUOTED_ID + ") > 0"

@(private = "file")
AGENT_USAGE_QUERY :: "SELECT " +
	"(SELECT COUNT(*) FROM (" + USE_INSTANCES + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_CONVERSATIONS + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_MESSAGES + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_ARTIFACTS + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_CHAINS + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_TASKS + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_MEMORIES + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_ACTIONS + ")), " +
	"(SELECT COUNT(*) FROM (" + USE_WORKFLOWS + "));"

// One statement: the guards and the delete run atomically, so an instance launched
// (or a task assigned) between the UI's usage check and this call still wins.
@(private = "file")
AGENT_DELETE_UNUSED_QUERY :: "DELETE FROM agents WHERE agent_id = ?1 AND owner_user_id = ?2" +
	" AND NOT EXISTS (" + USE_INSTANCES + ")" +
	" AND NOT EXISTS (" + USE_CONVERSATIONS + ")" +
	" AND NOT EXISTS (" + USE_MESSAGES + ")" +
	" AND NOT EXISTS (" + USE_ARTIFACTS + ")" +
	" AND NOT EXISTS (" + USE_CHAINS + ")" +
	" AND NOT EXISTS (" + USE_TASKS + ")" +
	" AND NOT EXISTS (" + USE_MEMORIES + ")" +
	" AND NOT EXISTS (" + USE_ACTIONS + ")" +
	" AND NOT EXISTS (" + USE_WORKFLOWS + ");"

// After the agent row is gone: its per-bridge support rows, its title counter, and
// its id in the owner's launch preferences (a stale favorite would hold one of the
// six favorite slots and could become the default launch agent).
@(private = "file")
AGENT_DELETE_CLEANUP_QUERIES := [?]cstring{
	"DELETE FROM agent_bridge_support WHERE agent_id = ?1 AND owner_user_id = ?2;",
	"DELETE FROM agent_title_counters WHERE agent_id = ?1 AND owner_user_id = ?2;",
	"UPDATE user_conversation_launch_preferences SET payload_json = json_set(payload_json, " +
	"'$.favorite_agent_ids', json((SELECT json_group_array(value) FROM json_each(payload_json, '$.favorite_agent_ids') WHERE value <> ?1)), " +
	"'$.pinned_agent_ids', json((SELECT json_group_array(value) FROM json_each(payload_json, '$.pinned_agent_ids') WHERE value <> ?1)), " +
	"'$.agent_id', CASE WHEN json_extract(payload_json, '$.agent_id') = ?1 THEN '' ELSE COALESCE(json_extract(payload_json, '$.agent_id'), '') END) " +
	"WHERE owner_user_id = ?2 AND instr(payload_json, " + QUOTED_ID + ") > 0;",
}

agent_usage_sqlite :: proc(ctx: rawptr, agent_id: string) -> (domain.Agent_Usage, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, AGENT_USAGE_QUERY, -1, &stmt, nil) != SQLITE_OK do return {}, domain.domain_error(.Internal_Error, "failed to prepare agent usage")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, agent_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, domain.domain_error(.Internal_Error, "agent usage could not be read")
	col :: proc(stmt: sqlite3_stmt, i: i32) -> int { return int(sqlite3_column_int64(stmt, i)) }
	return domain.Agent_Usage{
		instances     = col(stmt, 0),
		conversations = col(stmt, 1),
		messages      = col(stmt, 2),
		artifacts     = col(stmt, 3),
		chains        = col(stmt, 4),
		tasks         = col(stmt, 5),
		memories      = col(stmt, 6),
		actions       = col(stmt, 7),
		workflows     = col(stmt, 8),
	}, {}
}

agent_delete_unused_sqlite :: proc(ctx: rawptr, agent_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error) {
	impl := (^Agent_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, AGENT_DELETE_UNUSED_QUERY, -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare agent delete")
	bind_text(stmt, 1, agent_id)
	bind_text(stmt, 2, string(owner_user_id))
	rc, changes := step_changes(impl.conn.db, stmt)
	sqlite3_finalize(stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "agent could not be deleted")
	if changes == 0 do return false, {}
	for query in AGENT_DELETE_CLEANUP_QUERIES {
		cleanup: sqlite3_stmt = nil
		if sqlite3_prepare_v2(impl.conn.db, query, -1, &cleanup, nil) != SQLITE_OK do continue
		bind_text(cleanup, 1, agent_id)
		bind_text(cleanup, 2, string(owner_user_id))
		_ = sqlite3_step(cleanup)
		sqlite3_finalize(cleanup)
	}
	// The agent's identity fragment was part of rendered bootstrap manifests.
	bootcache.bump_content_epoch()
	return true, {}
}
