// Regression coverage for the task/agent-instance UPDATE jam (search FTS index
// drift). Migrations 029/030 index text with external-content fts5 vtables whose
// AFTER UPDATE/DELETE triggers use the external-content 'delete' op. If a bad manual
// rebuild leaves a base row unindexed, that op raises SQLITE_CORRUPT and rolls back
// every UPDATE to the row — while INSERTs (delete-free AI trigger) still succeed.
//
// This proves: (1) the asymmetry (a drifted row's UPDATE fails while INSERT works),
// (2) repair_fts_indexes() re-syncs and unsticks the row, (3) the repo save path
// self-heals + retries so an UPDATE succeeds through the drift, and (4) drift-only
// reconcile skips healthy indexes. Also guards FTS_INDEX_TABLES vs the search
// providers so the repair set can't silently drift from migration 030.
package hub_fts_repair_test

import "core:fmt"
import "core:testing"
import "core:os"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

TS :: "2026-01-01T00:00:00Z"

run :: proc(conn: ^sqlite.Conn, sql: string) {
	check(sqlite.exec(conn, sql), fmt.tprintf("exec failed: %s", sql))
}

tasks_index_drifted :: proc(conn: ^sqlite.Conn) -> bool {
	drift, known := sqlite.fts_index_has_drift(conn, sqlite.Fts_Index{base = "tasks", fts = "tasks_fts"})
	check(known, "drift must be determinable for tasks_fts (docsize shadow present)")
	return drift
}

@(test)
test_hub_fts_repair_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/hub_fts_repair.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	check(sqlite.fts5_available(&conn), "FTS5 must be available")
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	check(sqlite.sqlite_object_exists(&conn, "tasks_fts"), "migration 030 must create tasks_fts")

	fts_index_tables_cover_providers()

	// A chain to satisfy the task's parentage, then a task via the repo CREATE path
	// (INSERT => tasks_fts AI trigger indexes it, so there is no drift yet).
	run(&conn, "INSERT INTO task_chains(chain_id,owner_user_id,title,kind,status,coordinator_agent_instance_id,created_at,updated_at) VALUES('ch1','u','Chain','ticket','active','','x','x');")
	repo_impl: sqlite.Taskchain_Repo_SQLite
	repo := sqlite.new_taskchain_repository(&repo_impl, &conn)
	task := domain.Task{
		task_id       = domain.Task_ID("t_fts"),
		chain_id      = domain.Task_Chain_ID("ch1"),
		owner_user_id = domain.User_ID("u"),
		title         = "Deploy prod",
		description   = "ship it",
		publish_state = .Published,
		state         = .In_Progress,
		kind          = .Task,
		priority      = .P2,
		brief_json    = "{}",
		created_at = TS, updated_at = TS,
	}
	_, created, cerr := iface.taskchain_save_task(&repo, task)
	check(created, fmt.tprintf("create task: %s", cerr.message))
	check(!tasks_index_drifted(&conn), "freshly created task must be indexed (no drift)")

	// Simulate a bad manual rebuild that drops the row's postings from the index.
	run(&conn, "DELETE FROM tasks_fts;")
	check(tasks_index_drifted(&conn), "wiping tasks_fts must register as drift")

	// (1) ASYMMETRY: a raw UPDATE of the drifted row fails (the AU trigger's 'delete'
	// op hits missing postings => SQLITE_CORRUPT), while an INSERT of a NEW row still
	// succeeds (the AI trigger never runs 'delete').
	update_ok := sqlite.exec(&conn, "UPDATE tasks SET state='in_review' WHERE task_id='t_fts';")
	check(!update_ok, "a drifted row's raw UPDATE must fail (SQLITE_CORRUPT), reproducing the jam")
	insert_ok := sqlite.exec(&conn, "INSERT INTO tasks(task_id,chain_id,owner_user_id,title,description,publish_state,state,kind,priority,brief_json,created_at,updated_at,published_at,started_at,completed_at) VALUES('t_fts2','ch1','u','Another','x','published','ready','task','p2','{}','t','t','','','');")
	check(insert_ok, "INSERT of a new row must still succeed while a drifted row's UPDATE fails")

	// (2) RECOVERY: repair_fts_indexes() re-syncs via the supported 'rebuild' op and
	// unsticks the row — the previously-failing raw UPDATE now succeeds.
	rebuilt, repair_ok, repair_err := sqlite.repair_fts_indexes(&conn)
	check(repair_ok, fmt.tprintf("repair_fts_indexes: %s", repair_err.message))
	check(rebuilt >= 1, "repair must rebuild at least the drifted tasks_fts")
	check(!tasks_index_drifted(&conn), "after repair the tasks index must be in sync")
	check(sqlite.exec(&conn, "UPDATE tasks SET state='in_review' WHERE task_id='t_fts';"), "after repair the row's UPDATE must succeed")

	// (3) SELF-HEAL WRITE: re-drift, then update through the repo save path. It hits
	// the corruption, re-syncs, retries once, and reports success — the update lands.
	run(&conn, "DELETE FROM tasks_fts;")
	check(tasks_index_drifted(&conn), "re-wipe must drift again")
	task.state = .Done
	task.updated_at = "2026-01-02T00:00:00Z"
	_, saved, serr := iface.taskchain_save_task(&repo, task)
	check(saved, fmt.tprintf("save through drift must self-heal + succeed: %s", serr.message))
	landed, _ := sqlite.scalar_count(&conn, "SELECT count(*) FROM tasks WHERE task_id='t_fts' AND state='done';")
	check(landed == 1, "the self-healed save must actually update the row")
	check(!tasks_index_drifted(&conn), "self-heal must leave the index in sync")

	// (4) DRIFT-ONLY RECONCILE: a no-op when healthy; rebuilds only when drifted.
	healthy_rebuilt, ok2, _ := sqlite.repair_fts_indexes(&conn, true)
	check(ok2 && healthy_rebuilt == 0, "drift-only reconcile must skip healthy indexes")
	run(&conn, "DELETE FROM tasks_fts;")
	drifted_rebuilt, ok3, _ := sqlite.repair_fts_indexes(&conn, true)
	check(ok3 && drifted_rebuilt >= 1, "drift-only reconcile must rebuild the drifted index")
	check(!tasks_index_drifted(&conn), "drift-only reconcile must clear the drift")

	fmt.println("PASS: hub FTS repair (asymmetry + repair recovery + self-healing write + drift-only reconcile)")
}

// fts_index_tables_cover_providers guards the repair set: every searchable provider
// (migration 030) must have its fts vtable in FTS_INDEX_TABLES so repair/reconcile
// can never silently skip a table.
fts_index_tables_cover_providers :: proc() {
	for provider in sqlite.FTS_PROVIDERS {
		found := false
		for idx in sqlite.FTS_INDEX_TABLES do if idx.fts == provider.fts do found = true
		check(found, fmt.tprintf("FTS_INDEX_TABLES is missing provider index %s (migration drift)", provider.fts))
	}
}
