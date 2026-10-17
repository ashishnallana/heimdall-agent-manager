package taskv2

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import jsonx "odin_test:lib/jsonx"

// ---- shared sqlite fixture ------------------------------------------------------

Fixture :: struct {
	conn:          sqlite.Conn,
	repo_impl:     sqlite.Taskchain_Repo_SQLite,
	repo:          iface.Taskchain_Repository,
	agents_impl:   sqlite.Agent_Repo_SQLite,
	agents:        iface.Agent_Repository,
	bridges_impl:  sqlite.Bridge_Repo_SQLite,
	bridges:       iface.Bridge_Repository,
	repos:         iface.Repositories,
	uow_impl:      sqlite.SQLite_Unit_Of_Work_Factory,
	uow:           iface.Unit_Of_Work_Factory,
	clock:         platform.Clock,
	clock_state:   Fake_Clock,
	ids:           platform.ID_Generator,
	svc:           Service,
	path:          string,
}

Fake_Clock :: struct {
	unix_seconds: i64,
}

fake_clock_now :: proc(ctx: rawptr) -> string {
	fc := (^Fake_Clock)(ctx)
	return platform.format_rfc3339_utc({_nsec = fc.unix_seconds * 1_000_000_000})
}

fixture_advance :: proc(fx: ^Fixture, seconds: i64) {
	fx.clock_state.unix_seconds += seconds
}

test_db_path :: proc(tag: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := fmt.tprintf("%s/.cache/heimdall-tests", home)
	os.make_directory(dir)
	return fmt.aprintf("%s/taskv2_%s_%d.db", dir, tag, os.get_pid())
}

// fixture_open opens a fresh migrated database (or one stopped before `stop_before`).
fixture_open :: proc(t: ^testing.T, tag: string, stop_before := "") -> (^Fixture, bool) {
	fx := new(Fixture)
	fx.path = test_db_path(tag)
	os.remove(fx.path)
	conn, ok, err := sqlite.open(fx.path)
	if !testing.expect(t, ok, fmt.tprintf("open: %s", err.message)) do return fx, false
	fx.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&fx.conn, stop_before = stop_before)
	if !testing.expect(t, mig_ok, fmt.tprintf("migrations: %s", mig_err.message)) do return fx, false
	fixture_wire(fx)
	return fx, true
}

fixture_wire :: proc(fx: ^Fixture) {
	fx.repo = sqlite.new_taskchain_repository(&fx.repo_impl, &fx.conn)
	fx.agents = sqlite.new_agent_repository(&fx.agents_impl, &fx.conn)
	fx.bridges = sqlite.new_bridge_repository(&fx.bridges_impl, &fx.conn)
	fx.repos.taskchains = fx.repo
	fx.repos.agents = fx.agents
	fx.repos.bridges = fx.bridges
	fx.uow = sqlite.new_unit_of_work_factory(&fx.uow_impl, &fx.conn, &fx.repos)
	fx.clock_state = Fake_Clock{unix_seconds = 1_790_000_000}
	fx.clock = platform.Clock{ctx = rawptr(&fx.clock_state), now = fake_clock_now}
	fx.ids = platform.real_id_generator()
	fx.svc = new_service(&fx.repo, &fx.agents, &fx.bridges, &fx.clock, &fx.ids)
	fx.svc.uow_factory = &fx.uow
}

fixture_close :: proc(fx: ^Fixture) {
	sqlite.close(&fx.conn)
	os.remove(fx.path)
	delete(fx.path)
	free(fx)
	if context.allocator.procedure == mem.tracking_allocator_proc && context.allocator.data != nil {
		track := (^mem.Tracking_Allocator)(context.allocator.data)
		clear(&track.allocation_map)
	}
}

exec_ok :: proc(t: ^testing.T, fx: ^Fixture, sql: string) -> bool {
	return testing.expect(t, sqlite.exec(&fx.conn, sql), fmt.tprintf("sql failed: %s", sql))
}

scalar_text :: proc(fx: ^Fixture, sql: string) -> string {
	stmt: sqlite.sqlite3_stmt
	if sqlite.sqlite3_prepare_v2(fx.conn.db, cstring(raw_data(sql)), -1, &stmt, nil) != sqlite.SQLITE_OK do return "<prepare-failed>"
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW do return "<no-row>"
	return strings.clone(string(sqlite.sqlite3_column_text(stmt, 0)), context.temp_allocator)
}

scalar_int :: proc(fx: ^Fixture, sql: string) -> int {
	stmt: sqlite.sqlite3_stmt
	if sqlite.sqlite3_prepare_v2(fx.conn.db, cstring(raw_data(sql)), -1, &stmt, nil) != sqlite.SQLITE_OK do return -1
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW do return -1
	return int(sqlite.sqlite3_column_int64(stmt, 0))
}

// assert_projection_matches_fold is the "cached projection == fold" half of the
// fold property: every task row's state/attempt_no equals a fresh fold of its
// events with deps_done computed from the other rows.
assert_projection_matches_fold :: proc(t: ^testing.T, fx: ^Fixture, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, where_tag: string) {
	tasks, err := iface.taskchain_list_tasks_by_chain(&fx.repo, chain_id, owner)
	if !testing.expect(t, err.code == .None, "list tasks") do return
	deps, _ := iface.taskchain_list_dependencies_by_chain(&fx.repo, chain_id, owner)
	for task in tasks {
		evs, eerr := iface.taskchain_list_events_by_task(&fx.repo, task.task_id, owner)
		testing.expect(t, eerr.code == .None, "list events")
		view := fold_task(evs, fold_input_for_task(task, deps_done_for(task.task_id, tasks, deps)))
		testing.expect(t, view.state == task.state, fmt.tprintf("%s: task %s cached state %v != fold %v", where_tag, task.task_id, task.state, view.state))
		testing.expect(t, view.attempt_no == task.attempt_no, fmt.tprintf("%s: task %s cached attempt %d != fold %d", where_tag, task.task_id, task.attempt_no, view.attempt_no))
		testing.expect(t, view.blocked_on_json == task.blocked_on_json, fmt.tprintf("%s: task %s blocked_on mismatch", where_tag, task.task_id))
	}
}

// ---- migration round trip -------------------------------------------------------

@(private = "file")
LEGACY_SEED :: `
INSERT INTO users(user_id, name, display_name, status, created_at, updated_at) VALUES ('u1','u1','u1','active','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO bridges(bridge_id, owner_user_id, created_at, updated_at) VALUES ('br_1','u1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO agents(agent_id, owner_user_id, name, slug, created_at, updated_at) VALUES ('agt_w','u1','w','w','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'),('agt_r','u1','r','r','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO agent_instances(agent_instance_id, agent_id, owner_user_id, bridge_id, provider, runtime_status, chain_id, created_at, updated_at) VALUES ('inst_coord','agt_w','u1','br_1','p','running','chain_1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z'),('inst_rev','agt_r','u1','br_1','p','running','chain_1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO task_chains(chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at) VALUES ('chain_1','u1','vault:v1:dGl0bGU=','vault:v1:ZGVzYw==','published','active','team_work','inst_coord','[{"type":"agent_instance","agent_instance_id":"inst_rev"}]','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO task_chain_members(chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at) VALUES ('chain_1','inst_coord','agt_w','u1','coordinator','2026-01-01T00:00:00Z');
INSERT INTO task_chain_fleets(task_chain_id, agent_id, created_at, updated_at) VALUES ('chain_1','agt_w','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
INSERT INTO tasks(task_id, chain_id, owner_user_id, title, description, publish_state, status, assignee_ref_json, reviewer_refs_json, created_at, updated_at) VALUES
 ('t_assigned','chain_1','u1','A','vault:v1:ZGVzY3JpcHRpb24=','published','assigned','{"type":"agent_id","agent_id":"agt_w"}','[{"type":"user","user_id":"u1"}]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_queued','chain_1','u1','Q','','published','queued','{"type":"agent_id","agent_id":"agt_w"}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_inprog','chain_1','u1','P','','published','in_progress','{"type":"agent_instance","agent_instance_id":"inst_coord"}','[{"type":"agent_id","agent_id":"agt_r"}]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_inval','chain_1','u1','V','','published','in_validation','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_fin','chain_1','u1','F','','published','finishing','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_pausing','chain_1','u1','Pg','','published','pausing','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_vg','chain_1','u1','VG','','published','validated_good','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_vng','chain_1','u1','VNG','','published','validated_not_good','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_paused','chain_1','u1','Pd','','published','paused','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_done','chain_1','u1','D','','published','completed','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_canc','chain_1','u1','C','','published','cancelled','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_draft','chain_1','u1','Dr','','draft','assigned','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z'),
 ('t_blocked','chain_1','u1','B','','published','assigned','{}','[]','2026-01-01T00:00:00Z','2026-01-02T00:00:00Z');
INSERT INTO task_dependencies(task_id, depends_on_task_id, chain_id, owner_user_id, created_at) VALUES ('t_blocked','t_inprog','chain_1','u1','2026-01-01T00:00:00Z');
INSERT INTO task_votes(task_id, reviewer_agent_instance_id, chain_id, owner_user_id, vote, created_at, updated_at) VALUES ('t_inval','inst_rev','chain_1','u1','lgtm','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
`

// test_migration_round_trip: a fixture DB with EVERY legacy status, a `user`
// reviewer ref, an instance reviewer ref (chain default) and vault-armored text
// migrates to the v2 schema exactly as plan §1 lists, the legacy columns/tables
// are gone, and every task's cached state equals the fold of its events.
@(test)
test_migration_round_trip :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "mig", stop_before = "090_task_v2.sql")
	defer fixture_close(fx)
	if !ok do return
	if !exec_ok(t, fx, LEGACY_SEED) do return
	mig_ok, mig_err := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, mig_ok, fmt.tprintf("087 apply: %s", mig_err.message)) do return

	expect_state := proc(t: ^testing.T, fx: ^Fixture, id, want: string) {
		got := scalar_text(fx, fmt.tprintf("SELECT state FROM tasks WHERE task_id = '%s';", id))
		testing.expect(t, got == want, fmt.tprintf("%s: want %s got %s", id, want, got))
	}
	expect_state(t, fx, "t_assigned", "ready")
	expect_state(t, fx, "t_queued", "ready")
	expect_state(t, fx, "t_inprog", "in_progress")
	expect_state(t, fx, "t_inval", "in_review")
	expect_state(t, fx, "t_fin", "in_progress")
	expect_state(t, fx, "t_pausing", "in_progress")
	expect_state(t, fx, "t_vg", "in_review")
	expect_state(t, fx, "t_vng", "in_progress")
	expect_state(t, fx, "t_paused", "backlog")
	expect_state(t, fx, "t_done", "done")
	expect_state(t, fx, "t_canc", "cancelled")
	expect_state(t, fx, "t_draft", "backlog")
	expect_state(t, fx, "t_blocked", "backlog") // dep on an in_progress task

	// paused → backlog + blocked_on human
	testing.expect(t, strings.contains(scalar_text(fx, "SELECT blocked_on_json FROM tasks WHERE task_id = 't_paused';"), `"kind":"human"`), "paused carries blocked_on human")
	// user reviewer ref → requires_user_approval
	testing.expect_value(t, scalar_int(fx, "SELECT requires_user_approval FROM tasks WHERE task_id = 't_assigned';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT requires_user_approval FROM tasks WHERE task_id = 't_queued';"), 0)
	// brief: goal keeps the armored description verbatim; assignee template resolved from agent_id and from an instance ref
	brief_a := scalar_text(fx, "SELECT brief_json FROM tasks WHERE task_id = 't_assigned';")
	testing.expect(t, jsonx.extract_string(brief_a, "goal", "", true, context.temp_allocator) == "vault:v1:ZGVzY3JpcHRpb24=", "armored goal preserved")
	testing.expect(t, jsonx.extract_string(brief_a, "assignee", "", true, context.temp_allocator) == "agt_w", "assignee from agent_id ref")
	brief_p := scalar_text(fx, "SELECT brief_json FROM tasks WHERE task_id = 't_inprog';")
	testing.expect(t, jsonx.extract_string(brief_p, "assignee", "", true, context.temp_allocator) == "agt_w", "assignee from instance ref resolved to its template")
	roles := jsonx.extract_string_array(brief_p, "review_roles", true, context.temp_allocator)
	testing.expect(t, len(roles) == 1 && roles[0] == "reviewer", "agent reviewer ref → review_roles [reviewer]")
	// chain default reviewer (instance ref) → every task has the reviewer role
	roles_q := jsonx.extract_string_array(scalar_text(fx, "SELECT brief_json FROM tasks WHERE task_id = 't_queued';"), "review_roles", true, context.temp_allocator)
	testing.expect(t, len(roles_q) == 1 && roles_q[0] == "reviewer", "chain default reviewer applies to every task")
	// fleet rows: agt_r gained a reviewer row; agt_w keeps worker; both placed on the chain's effective bridge
	testing.expect(t, scalar_text(fx, "SELECT roles_json FROM task_chain_fleets WHERE agent_id = 'agt_r';") == `["reviewer"]`, "reviewer fleet row")
	testing.expect(t, scalar_text(fx, "SELECT roles_json FROM task_chain_fleets WHERE agent_id = 'agt_w';") == `["worker"]`, "worker fleet row untouched")
	testing.expect(t, scalar_text(fx, "SELECT bridge_id FROM task_chain_fleets WHERE agent_id = 'agt_w';") == "br_1", "fleet row defaults to the chain's effective bridge")
	// chain kind + armored title untouched
	testing.expect(t, scalar_text(fx, "SELECT kind FROM task_chains WHERE chain_id = 'chain_1';") == "ticket", "team_work → ticket")
	testing.expect(t, scalar_text(fx, "SELECT title FROM task_chains WHERE chain_id = 'chain_1';") == "vault:v1:dGl0bGU=", "armored title untouched")
	// attempts: tasks that had run start at attempt 1
	testing.expect_value(t, scalar_int(fx, "SELECT attempt_no FROM tasks WHERE task_id = 't_inprog';"), 1)
	testing.expect_value(t, scalar_int(fx, "SELECT attempt_no FROM tasks WHERE task_id = 't_queued';"), 0)
	// legacy columns + tables are gone; votes dropped
	testing.expect(t, !sqlite.table_column_exists(&fx.conn, "tasks", "status"), "tasks.status dropped")
	testing.expect(t, !sqlite.table_column_exists(&fx.conn, "tasks", "assignee_ref_json"), "assignee_ref_json dropped")
	testing.expect(t, !sqlite.table_column_exists(&fx.conn, "tasks", "reviewer_refs_json"), "reviewer_refs_json dropped")
	testing.expect(t, !sqlite.table_column_exists(&fx.conn, "task_chains", "default_reviewer_refs_json"), "default_reviewer_refs_json dropped")
	testing.expect(t, !sqlite.sqlite_object_exists(&fx.conn, "task_votes"), "task_votes dropped")
	testing.expect(t, !sqlite.sqlite_object_exists(&fx.conn, "task_subscriptions"), "task_subscriptions dropped")
	// one migrated event per task
	testing.expect_value(t, scalar_int(fx, "SELECT COUNT(*) FROM task_events WHERE kind = 'migrated';"), 13)
	// the fold agrees with the cached projection for every task
	assert_projection_matches_fold(t, fx, "chain_1", "u1", "after migration")
	// and the migration is idempotent on re-run (ledger)
	again_ok, _ := sqlite.run_migrations(&fx.conn)
	testing.expect(t, again_ok, "re-running migrations is a no-op")
	testing.expect_value(t, scalar_int(fx, "SELECT COUNT(*) FROM task_events WHERE kind = 'migrated';"), 13)
}

// test_owner_immutable_on_v2_tables: every new table refuses an owner change.
@(test)
test_owner_immutable_on_v2_tables :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "owner")
	defer fixture_close(fx)
	if !ok do return
	now := "2026-01-01T00:00:00Z"
	exec_ok(t, fx, fmt.tprintf("INSERT INTO task_events(task_id, chain_id, owner_user_id, ts_ms, kind) VALUES ('t','c','u1',1,'created');"))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO task_attempts(task_id, attempt_no, chain_id, owner_user_id, started_at) VALUES ('t',1,'c','u1','%s');", now))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO task_attempt_facets(task_id, attempt_no, chain_id, owner_user_id, kind, body_json, writer, written_at) VALUES ('t',1,'c','u1','handoff','{}','agent','%s');", now))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery) VALUES ('l','t','c','u1',1,'i','work','%s','%s','%s','wake');", now, now, now))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO task_reviews(task_id, chain_id, owner_user_id, attempt_no, role, reviewer_kind, verdict, created_at) VALUES ('t','c','u1',1,'reviewer','agent','approve','%s');", now))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO chain_summaries(chain_id, owner_user_id, updated_at) VALUES ('c','u1','%s');", now))
	exec_ok(t, fx, fmt.tprintf("INSERT INTO workflow_definitions(def_id, owner_user_id, name, version, body_json, created_at) VALUES ('d','u1','wf',1,'{}','%s');", now))
	tables := []string{"task_events", "task_attempts", "task_attempt_facets", "task_leases", "task_reviews", "chain_summaries", "workflow_definitions"}
	for table in tables {
		testing.expect(t, !sqlite.exec(&fx.conn, fmt.tprintf("UPDATE %s SET owner_user_id = 'u2';", table)), fmt.tprintf("%s.owner_user_id must be immutable", table))
	}
	// workflow_definitions is append-only
	testing.expect(t, !sqlite.exec(&fx.conn, "UPDATE workflow_definitions SET body_json = '{\"x\":1}';"), "workflow_definitions body is append-only")
	// lease uniques: one lease per holder, one work lease per task
	testing.expect(t, !sqlite.exec(&fx.conn, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery) VALUES ('l2','t2','c','u1',1,'i','work','%s','%s','%s','wake');", now, now, now)), "holder_instance_id UNIQUE")
	testing.expect(t, !sqlite.exec(&fx.conn, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery) VALUES ('l3','t','c','u1',1,'j','work','%s','%s','%s','wake');", now, now, now)), "one work lease per task")
	testing.expect(t, sqlite.exec(&fx.conn, fmt.tprintf("INSERT INTO task_leases(lease_id, task_id, chain_id, owner_user_id, attempt_no, holder_instance_id, kind, granted_at, expires_at, hard_deadline_at, delivery) VALUES ('l4','t','c','u1',1,'k','review','%s','%s','%s','wake');", now, now, now)), "review leases are not limited per task")
}

// ---- engine projection property over real rows ----------------------------------

seed_chain :: proc(t: ^testing.T, fx: ^Fixture, chain_id: string, published: bool) -> domain.Task_Chain {
	now := platform.clock_now(&fx.clock)
	chain := domain.Task_Chain{chain_id = domain.Task_Chain_ID(chain_id), owner_user_id = "u1", title = "c", publish_state = .Published if published else .Draft, status = .Active, kind = domain.CHAIN_KIND_TICKET, defaults_json = "{}", created_at = now, updated_at = now, published_at = now if published else ""}
	_, ok, err := iface.taskchain_save_chain(&fx.repo, chain)
	testing.expect(t, ok, fmt.tprintf("save chain: %s", err.message))
	return chain
}

seed_task :: proc(t: ^testing.T, fx: ^Fixture, chain: domain.Task_Chain, task_id: string, brief := `{"goal":"g","review_roles":[]}`) -> domain.Task {
	now := platform.clock_now(&fx.clock)
	task := domain.Task{task_id = domain.Task_ID(task_id), chain_id = chain.chain_id, owner_user_id = chain.owner_user_id, title = task_id, publish_state = chain.publish_state, state = .Backlog, kind = .Task, priority = .P2, brief_json = brief, created_at = now, updated_at = now}
	saved, ok, err := iface.taskchain_save_task(&fx.repo, task)
	testing.expect(t, ok, fmt.tprintf("save task: %s", err.message))
	return saved
}

@(test)
test_projection_matches_fold_through_engine :: proc(t: ^testing.T) {
	fx, ok := fixture_open(t, "proj")
	defer fixture_close(fx)
	if !ok do return
	chain := seed_chain(t, fx, "chain_p", false)
	a := seed_task(t, fx, chain, "task_a")
	b := seed_task(t, fx, chain, "task_b")
	actor := Actor{kind = ACTOR_USER, id = "u1"}
	testing.expect(t, task_created(&fx.svc, a, actor).code == .None, "created a")
	testing.expect(t, task_created(&fx.svc, b, actor).code == .None, "created b")
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "draft")
	// b depends on a
	_, dok, _ := iface.taskchain_save_dependency(&fx.repo, domain.Task_Dependency{task_id = b.task_id, depends_on_task_id = a.task_id, chain_id = chain.chain_id, owner_user_id = "u1", created_at = platform.clock_now(&fx.clock)})
	testing.expect(t, dok, "dep saved")
	testing.expect(t, dep_added(&fx.svc, b, a.task_id, actor).code == .None, "dep_added")
	// publish the chain → a ready, b backlog (dep)
	chain.publish_state = .Published
	_, _, _ = iface.taskchain_save_chain(&fx.repo, chain)
	ids := []string{"task_a", "task_b"}
	for id in ids {
		row, _, _ := iface.taskchain_get_task(&fx.repo, domain.Task_ID(id))
		row.publish_state = .Published
		_, _, _ = iface.taskchain_save_task(&fx.repo, row)
	}
	testing.expect(t, chain_published(&fx.svc, chain, actor).code == .None, "chain_published")
	ra, _, _ := iface.taskchain_get_task(&fx.repo, a.task_id)
	rb, _, _ := iface.taskchain_get_task(&fx.repo, b.task_id)
	testing.expect_value(t, ra.state, domain.Task_State.Ready)
	testing.expect(t, ra.ready_since != "", "ready_since stamped")
	testing.expect_value(t, rb.state, domain.Task_State.Backlog)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "published")
	// cancel a → b becomes ready (cancelled prerequisite unblocks)
	testing.expect(t, cancel_task(&fx.svc, ra, actor, "scope cut").code == .None, "cancel a")
	ra, _, _ = iface.taskchain_get_task(&fx.repo, a.task_id)
	rb, _, _ = iface.taskchain_get_task(&fx.repo, b.task_id)
	testing.expect_value(t, ra.state, domain.Task_State.Cancelled)
	testing.expect(t, ra.completed_at != "", "completed_at stamped on cancel")
	testing.expect_value(t, rb.state, domain.Task_State.Ready)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "after cancel")
	// chain cancelled → open tasks cancelled
	testing.expect(t, chain_closed(&fx.svc, chain, actor, true).code == .None, "chain_closed")
	rb, _, _ = iface.taskchain_get_task(&fx.repo, b.task_id)
	testing.expect_value(t, rb.state, domain.Task_State.Cancelled)
	assert_projection_matches_fold(t, fx, chain.chain_id, "u1", "after chain close")
	// events are owner-scoped and ordered
	evs, _ := iface.taskchain_list_events_by_task(&fx.repo, b.task_id, "u1")
	testing.expect(t, len(evs) >= 4, "created, dep_added, published, cancelled")
	testing.expect(t, evs[len(evs)-1].kind == EV_CANCELLED, "last event is cancelled")
	none, _ := iface.taskchain_list_events_by_task(&fx.repo, b.task_id, "u2")
	testing.expect_value(t, len(none), 0)
}
