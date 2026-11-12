package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
seed_agent :: proc(t: ^testing.T, repo: ^iface.Agent_Repository, id, owner: string) {
	agent := domain.Agent{agent_id = id, owner_user_id = domain.User_ID(owner), name = id, slug = id, template_id = "empty", state = .Active, created_at = "2026-11-12T00:00:00Z", updated_at = "2026-11-12T00:00:00Z"}
	_, saved, err := iface.agent_save(repo, agent)
	testing.expect(t, saved, err.message)
}

@(private = "file")
pref_payload :: proc(conn: ^Conn, owner: string) -> string {
	stmt: sqlite3_stmt = nil
	q := "SELECT payload_json FROM user_conversation_launch_preferences WHERE owner_user_id = ?;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return column_text(stmt, 0)
}

@(private = "file")
row_count :: proc(conn: ^Conn, q: cstring) -> int {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, q, -1, &stmt, nil) != SQLITE_OK do return -1
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return -1
	return int(sqlite3_column_int64(stmt, 0))
}

// Every reference clause runs against the real migrated schema (a renamed table or
// column fails the prepare), counts what refers to the agent, and blocks the delete.
@(test)
test_agent_usage_counts_references_and_blocks_delete :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, ok := tmpl_clone_migrated(t)
	if !testing.expect(t, ok, "migrated template db") do return
	defer close(&conn)
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)
	seed_agent(t, &repo, "agt_used", "owner")

	usage, err := iface.agent_usage(&repo, "agt_used")
	testing.expect(t, err.code == .None, err.message)
	testing.expect_value(t, domain.agent_usage_total(usage), 0)

	// A memory targeted at it (JSON array) and a review it wrote (plain column).
	testing.expect(t, exec(&conn, `INSERT INTO memories (memory_id, owner_user_id, status, body, created_at, updated_at, agent_ids) VALUES ('mem_1','owner','active','b','t','t','["agt_used"]');`))
	testing.expect(t, exec(&conn, `INSERT INTO task_reviews (task_id, chain_id, owner_user_id, attempt_no, role, reviewer_kind, reviewer_agent_id, verdict, created_at) VALUES ('tsk_1','chn_1','owner',1,'reviewer','agent','agt_used','approve','t');`))
	// A longer id that merely starts with the same text is not a reference.
	testing.expect(t, exec(&conn, `INSERT INTO memories (memory_id, owner_user_id, status, body, created_at, updated_at, agent_ids) VALUES ('mem_2','owner','active','b','t','t','["agt_used_other"]');`))

	usage, err = iface.agent_usage(&repo, "agt_used")
	testing.expect(t, err.code == .None, err.message)
	testing.expect_value(t, usage.memories, 1)
	testing.expect_value(t, usage.tasks, 1)
	testing.expect_value(t, domain.agent_usage_total(usage), 2)

	deleted, del_err := iface.agent_delete_unused(&repo, "agt_used", "owner")
	testing.expect(t, del_err.code == .None, del_err.message)
	testing.expect(t, !deleted, "an agent still referred to must not be deleted")
	_, still_there, _ := iface.agent_get(&repo, "agt_used")
	testing.expect(t, still_there, "agent row survives a refused delete")
}

// An unused agent is deleted with its support rows, title counter and launch
// preferences; another owner's call deletes nothing.
@(test)
test_agent_delete_unused_removes_agent_and_its_leftovers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, ok := tmpl_clone_migrated(t)
	if !testing.expect(t, ok, "migrated template db") do return
	defer close(&conn)
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)
	seed_agent(t, &repo, "agt_gone", "owner")
	seed_agent(t, &repo, "agt_keep", "owner")

	testing.expect(t, exec(&conn, `INSERT INTO users (user_id, name, display_name, status, created_at, updated_at) VALUES ('owner','o','o','active','t','t');`))
	testing.expect(t, exec(&conn, `INSERT INTO agent_bridge_support (agent_id, bridge_id, owner_user_id, created_at, updated_at) VALUES ('agt_gone','brg_1','owner','t','t');`))
	testing.expect(t, exec(&conn, `INSERT INTO agent_title_counters (agent_id, owner_user_id, counter) VALUES ('agt_gone','owner',3);`))
	testing.expect(t, exec(&conn, `INSERT INTO user_conversation_launch_preferences (owner_user_id, payload_json) VALUES ('owner','{"agent_id":"agt_gone","project_id":"p","favorite_agent_ids":["agt_keep","agt_gone"],"pinned_agent_ids":["agt_gone"]}');`))

	deleted, err := iface.agent_delete_unused(&repo, "agt_gone", "intruder")
	testing.expect(t, err.code == .None, err.message)
	testing.expect(t, !deleted, "another owner cannot delete it")

	deleted, err = iface.agent_delete_unused(&repo, "agt_gone", "owner")
	testing.expect(t, err.code == .None, err.message)
	testing.expect(t, deleted, "an unused agent is deleted")
	_, found, _ := iface.agent_get(&repo, "agt_gone")
	testing.expect(t, !found, "agent row is gone")
	_, kept, _ := iface.agent_get(&repo, "agt_keep")
	testing.expect(t, kept, "other agents are untouched")

	testing.expect_value(t, row_count(&conn, "SELECT COUNT(*) FROM agent_bridge_support WHERE agent_id = 'agt_gone';"), 0)
	testing.expect_value(t, row_count(&conn, "SELECT COUNT(*) FROM agent_title_counters WHERE agent_id = 'agt_gone';"), 0)

	payload := pref_payload(&conn, "owner")
	testing.expect(t, !strings.contains(payload, "agt_gone"), payload)
	testing.expect(t, strings.contains(payload, `"favorite_agent_ids":["agt_keep"]`), payload)
	testing.expect(t, strings.contains(payload, `"pinned_agent_ids":[]`), payload)
	testing.expect(t, strings.contains(payload, `"project_id":"p"`), payload)
}

@(test)
test_memory_delete_is_owner_scoped_and_spares_system_memories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, ok := tmpl_clone_migrated(t)
	if !testing.expect(t, ok, "migrated template db") do return
	defer close(&conn)
	impl: Content_Repo_SQLite
	repo := new_content_repository(&impl, &conn)
	testing.expect(t, exec(&conn, `INSERT INTO memories (memory_id, owner_user_id, status, body, created_at, updated_at) VALUES ('mem_mine','owner','archived','secret','t','t'), ('mem_sys','system','active','s','t','t');`))

	deleted, err := iface.content_delete_memory(&repo, "mem_mine", "intruder")
	testing.expect(t, !deleted, "another owner deletes nothing")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)

	deleted, err = iface.content_delete_memory(&repo, "mem_sys", "system")
	testing.expect(t, !deleted, "system memories are never deleted")

	deleted, err = iface.content_delete_memory(&repo, "mem_mine", "owner")
	testing.expect(t, deleted, err.message)
	_, found, _ := iface.content_get_memory(&repo, "mem_mine")
	testing.expect(t, !found, "memory row is gone")
	// The FTS delete trigger took the body out of search too.
	testing.expect_value(t, row_count(&conn, "SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH 'secret';"), 0)
}
