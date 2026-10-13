#+private file
// Behavioral tests for shell_session SQLite repository.
package sqlite
import domain "odin_test:hub/domain"
import "core:fmt"
import iface "odin_test:hub/repository/iface"
import "core:os"
import "core:testing"
// --- Consolidated from shell_session_repo_test.odin ---
@(private = "file")
shell_test_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}
@(private = "file")
shell_test_session :: proc(session_id, owner, bridge, kind: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = kind,
		cmd              = "echo hi",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}
@(private = "file")
shell_test_scalar :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return column_text(stmt, 0)
}
// --- §4: migration over a pre-048 table holding every old kind ---------------
//
// Builds the 041-era schema by hand (bare session_id PRIMARY KEY, old kind
// vocabulary), seeds one row per old kind, then runs the migrator and checks the
// rows survived with the new vocabulary — and that the dead `agent` row is gone
// rather than remapped onto a kind that would misdescribe it.
@(test)
test_shell_sessions_migration_rewrites_every_old_kind :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "migrate")
	if !ok do return
	defer close(&conn)
	// The 041 schema verbatim, so this is a genuine upgrade rather than a fresh bootstrap.
	testing.expect(t, exec(&conn, MIGRATION_041_SHELL_SESSIONS), "041-era table created")
	seed := `INSERT INTO shell_sessions (session_id, owner_user_id, bridge_id, kind, cmd, status, started_at, created_at) VALUES
	  ('sh_cmd',  'user_a', 'brg_1', 'command',     'echo cmd',  'exited',  '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_int',  'user_a', 'brg_1', 'interactive', 'zsh',       'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_srv',  'user_a', 'brg_1', 'server',      'serve',     'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z'),
	  ('sh_agt',  'user_a', 'brg_1', 'agent',       'claude',    'running', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');`
	testing.expect(t, exec(&conn, seed), "seeded one row of every old kind")
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok over a pre-048 table")
	// command -> run, interactive -> shell, server untouched.
	k_cmd := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_cmd';")
	k_int := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_int';")
	k_srv := shell_test_scalar(&conn, "SELECT kind FROM shell_sessions WHERE session_id='sh_srv';")
	defer delete(k_cmd); defer delete(k_int); defer delete(k_srv)
	testing.expect_value(t, k_cmd, domain.Shell_Session_Kind_Run)
	testing.expect_value(t, k_int, domain.Shell_Session_Kind_Shell)
	testing.expect_value(t, k_srv, domain.Shell_Session_Kind_Server)
	// The agent row is dropped, and no other row was lost with it.
	n_agent := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE kind='agent';")
	n_total := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions;")
	defer delete(n_agent); defer delete(n_total)
	testing.expect_value(t, n_agent, "0")
	testing.expect_value(t, n_total, "3")
	// Payload survived the table rebuild, not just the kind column.
	cmd_col := shell_test_scalar(&conn, "SELECT cmd FROM shell_sessions WHERE session_id='sh_int';")
	defer delete(cmd_col)
	testing.expect_value(t, cmd_col, "zsh")
	// Re-running is a no-op rather than a second rebuild.
	mig_ok2, _ := run_migrations(&conn)
	testing.expect(t, mig_ok2, "migrations are idempotent")
	n_total2 := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions;")
	defer delete(n_total2)
	testing.expect_value(t, n_total2, "3")
}
// --- §7: (bridge_id, session_id) primary key --------------------------------
//
// The regression this guards: session ids are minted per-bridge and carry no
// bridge or owner qualifier, so under the old bare session_id PRIMARY KEY a
// second bridge upserting the same id OVERWROTE the first bridge's row — across
// tenants, since the two rows can belong to different owners.
@(test)
test_shell_session_cross_bridge_id_collision_does_not_clobber :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "collide")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)
	// The SAME session_id on two different bridges, owned by two different users.
	a := shell_test_session("shl_collision", "user_a", "brg_1", domain.Shell_Session_Kind_Shell)
	b := shell_test_session("shl_collision", "user_b", "brg_2", domain.Shell_Session_Kind_Shell)
	b.cmd = "bash"
	ok_a, err_a := iface.shell_session_upsert(&repo, a)
	ok_b, err_b := iface.shell_session_upsert(&repo, b)
	testing.expect(t, ok_a && err_a.code == .None, "bridge 1 row stored")
	testing.expect(t, ok_b && err_b.code == .None, "bridge 2 row stored alongside it")
	// Two rows, not one overwritten row.
	n := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE session_id='shl_collision';")
	defer delete(n)
	testing.expect_value(t, n, "2")
	// Each owner still sees their own, unmodified.
	got_a, found_a, _ := iface.shell_session_get(&repo, "user_a", "shl_collision")
	testing.expect(t, found_a, "user_a's row survives")
	testing.expect_value(t, got_a.bridge_id, "brg_1")
	testing.expect_value(t, got_a.cmd, "echo hi")
	domain.shell_session_destroy(got_a)
	got_b, found_b, _ := iface.shell_session_get(&repo, "user_b", "shl_collision")
	testing.expect(t, found_b, "user_b's row survives")
	testing.expect_value(t, got_b.bridge_id, "brg_2")
	testing.expect_value(t, got_b.cmd, "bash")
	domain.shell_session_destroy(got_b)
	// The bridge-event lookup resolves within the REPORTING bridge only, so a
	// bridge cannot reach another bridge's identically-named session.
	by_id, found_by_id, _ := iface.shell_session_get_by_id(&repo, "brg_2", "shl_collision")
	testing.expect(t, found_by_id, "get_by_id resolves the reporting bridge's row")
	testing.expect_value(t, by_id.owner_user_id, "user_b")
	domain.shell_session_destroy(by_id)
	_, found_wrong, _ := iface.shell_session_get_by_id(&repo, "brg_absent", "shl_collision")
	testing.expect(t, !found_wrong, "get_by_id finds nothing for a bridge that has no such session")
}
// --- §7 (coordinator ruling U2): UNIQUE(owner_user_id, session_id) ------------
//
// The composite PK and this unique index stop two DIFFERENT failures, and neither
// implies the other. The PK stops a CROSS-TENANT clobber (the test above). This
// one keeps the OWNER-SCOPED read single-row: shell_session_get_sqlite is
// `WHERE owner_user_id = ? AND session_id = ? LIMIT 1` and backs kill, attach,
// signal, restart, set_port and log, so two same-owner rows on two bridges would
// make every one of those act on an arbitrarily chosen session, silently.
//
// The ruling accepts the trade knowingly: this converts a bad READ into a failed
// INSERT. A failed insert can orphan a process the bridge is running and the hub
// does not track — but that lands in REQ-SHELL-10's convergence net, whereas a
// wrong-row read lands in no net at all.
@(test)
test_shell_session_same_owner_id_collision_fails_at_insert :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "uniqowner")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)
	// Same owner, same session_id, two different bridges.
	first  := shell_test_session("shl_dup", "user_a", "brg_1", domain.Shell_Session_Kind_Shell)
	second := shell_test_session("shl_dup", "user_a", "brg_2", domain.Shell_Session_Kind_Shell)
	second.cmd = "bash"
	ok1, err1 := iface.shell_session_upsert(&repo, first)
	testing.expect(t, ok1 && err1.code == .None, "the first row stores normally")
	// LOUD, not silent. The composite PK does not catch this — the bridge differs,
	// so ON CONFLICT(bridge_id, session_id) sees no conflict and would happily
	// insert a second row for this owner. The unique index is what refuses it.
	ok2, err2 := iface.shell_session_upsert(&repo, second)
	testing.expect(t, !ok2, "a same-owner session_id collision across bridges FAILS at insert")
	testing.expect(t, err2.code != .None, "and reports an error rather than succeeding quietly")
	// Exactly one row, and it is the original — not half-overwritten by the reject.
	n := shell_test_scalar(&conn, "SELECT COUNT(*) FROM shell_sessions WHERE session_id='shl_dup';")
	defer delete(n)
	testing.expect_value(t, n, "1")
	got, found, _ := iface.shell_session_get(&repo, "user_a", "shl_dup")
	testing.expect(t, found, "the owner-scoped read still resolves")
	testing.expect_value(t, got.bridge_id, "brg_1")
	testing.expect_value(t, got.cmd, "echo hi")
	domain.shell_session_destroy(got)
}
// The index is UNIQUE, not merely present — a plain index would satisfy a name
// check while enforcing nothing, which is exactly the gap the ruling closed.
@(test)
test_shell_sessions_owner_session_index_is_unique :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "uniqidx")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	is_unique := shell_test_scalar(&conn, "SELECT \"unique\" FROM pragma_index_list('shell_sessions') WHERE name='shell_sessions_owner_session';")
	defer delete(is_unique)
	testing.expect_value(t, is_unique, "1")
}
// --- §5/§6: per-kind scope enforced in the query layer ----------------------
//
// The concrete leak this closes: list_by_chain(owner, "") used to bind chain_id=''
// and nothing else, so a caller asking about a chain got back every agent-scoped
// run and bridge-scoped shell, all of which legitimately have an empty chain_id.
@(test)
test_shell_session_list_respects_per_kind_scope :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "scope")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)
	owner := "user_scope"
	run := shell_test_session("sh_run", owner, "brg_1", domain.Shell_Session_Kind_Run)
	run.agent_instance_id = "inst_1"
	shell := shell_test_session("sh_shell", owner, "brg_1", domain.Shell_Session_Kind_Shell)
	server := shell_test_session("sh_server", owner, "brg_1", domain.Shell_Session_Kind_Server)
	server.chain_id = "chain_1"
	for s in ([]domain.Shell_Session{run, shell, server}) {
		up_ok, _ := iface.shell_session_upsert(&repo, s)
		testing.expect(t, up_ok, "seed upsert ok")
	}
	// A by-chain listing returns ONLY servers: chain is not a scope key for run or
	// shell, so neither may appear under a chain-narrowed query.
	by_chain, c_cursor, _ := iface.shell_session_list_by_chain(&repo, owner, "chain_1", "", "", 50)
	testing.expect_value(t, len(by_chain), 1)
	if len(by_chain) == 1 do testing.expect_value(t, by_chain[0].kind, domain.Shell_Session_Kind_Server)
	domain.shell_sessions_destroy(by_chain)
	delete(c_cursor)
	// The negative that used to leak: an EMPTY chain filter must not hand back the
	// run and the shell just because their chain_id column is empty.
	empty_chain, e_cursor, _ := iface.shell_session_list_by_chain(&repo, owner, "", "", "", 50)
	testing.expect_value(t, len(empty_chain), 0)
	domain.shell_sessions_destroy(empty_chain)
	delete(e_cursor)
	// Bridge is a scope key for shell and server, but NOT for run (run is agent
	// scoped), so a by-bridge listing returns exactly those two.
	by_bridge, b_cursor, _ := iface.shell_session_list_by_bridge(&repo, owner, "brg_1", "", "", 50)
	testing.expect_value(t, len(by_bridge), 2)
	saw_run := false
	for s in by_bridge do if s.kind == domain.Shell_Session_Kind_Run do saw_run = true
	testing.expect(t, !saw_run, "a by-bridge listing does not return agent-scoped runs")
	domain.shell_sessions_destroy(by_bridge)
	delete(b_cursor)
	// Agent is the scope key for run alone.
	by_agent, a_cursor, _ := iface.shell_session_list_by_owner(&repo, owner, iface.Shell_Session_List_Filter{agent_instance_id = "inst_1"}, "", 50)
	testing.expect_value(t, len(by_agent), 1)
	if len(by_agent) == 1 do testing.expect_value(t, by_agent[0].kind, domain.Shell_Session_Kind_Run)
	domain.shell_sessions_destroy(by_agent)
	delete(a_cursor)
	// An unfiltered owner-wide listing is unchanged: it names no scope column, so
	// it narrows by no kind and still returns everything the owner has.
	all, all_cursor, _ := iface.shell_session_list_by_owner(&repo, owner, iface.Shell_Session_List_Filter{}, "", 50)
	testing.expect_value(t, len(all), 3)
	domain.shell_sessions_destroy(all)
	delete(all_cursor)
}
// --- §5: the domain scope validator, including every negative ---------------
@(test)
test_shell_session_scope_validation :: proc(t: ^testing.T) {
	// Positive: each kind with exactly the columns its rule requires.
	good_run := shell_test_session("s1", "u", "brg_1", domain.Shell_Session_Kind_Run)
	good_run.agent_instance_id = "inst_1"
	_, _, run_ok := domain.shell_session_validate_scope(good_run)
	testing.expect(t, run_ok, "run with an agent_instance_id is valid")
	good_shell := shell_test_session("s2", "u", "brg_1", domain.Shell_Session_Kind_Shell)
	_, _, shell_ok := domain.shell_session_validate_scope(good_shell)
	testing.expect(t, shell_ok, "shell with a bridge_id alone is valid")
	good_server := shell_test_session("s3", "u", "brg_1", domain.Shell_Session_Kind_Server)
	good_server.chain_id = "chain_1"
	_, _, server_ok := domain.shell_session_validate_scope(good_server)
	testing.expect(t, server_ok, "server with chain + bridge is valid")
	// Negative: a required scope column missing.
	bad_run := shell_test_session("s4", "u", "brg_1", domain.Shell_Session_Kind_Run)
	col, missing, ok4 := domain.shell_session_validate_scope(bad_run)
	testing.expect(t, !ok4 && missing, "run without an agent_instance_id is rejected")
	testing.expect_value(t, col, "agent_instance_id")
	bad_server := shell_test_session("s5", "u", "brg_1", domain.Shell_Session_Kind_Server)
	col5, missing5, ok5 := domain.shell_session_validate_scope(bad_server)
	testing.expect(t, !ok5 && missing5, "server without a chain_id is rejected")
	testing.expect_value(t, col5, "chain_id")
	// A shell MAY carry a chain_id (optional scope column), so it stays valid.
	chain_shell := shell_test_session("s6", "u", "brg_1", domain.Shell_Session_Kind_Shell)
	chain_shell.chain_id = "chain_1"
	_, _, chain_shell_ok := domain.shell_session_validate_scope(chain_shell)
	testing.expect(t, chain_shell_ok, "shell carrying an optional chain_id is valid")
	// Negative: a forbidden scope column populated with noise instead of left empty.
	noisy_shell := shell_test_session("s6b", "u", "brg_1", domain.Shell_Session_Kind_Shell)
	noisy_shell.agent_instance_id = "inst_1"
	col6, missing6, ok6 := domain.shell_session_validate_scope(noisy_shell)
	testing.expect(t, !ok6 && !missing6, "shell carrying an agent_instance_id is rejected")
	testing.expect_value(t, col6, "agent_instance_id")
	noisy_server := shell_test_session("s7", "u", "brg_1", domain.Shell_Session_Kind_Server)
	noisy_server.chain_id = "chain_1"
	noisy_server.agent_instance_id = "inst_1"
	col7, missing7, ok7 := domain.shell_session_validate_scope(noisy_server)
	testing.expect(t, !ok7 && !missing7, "server carrying an agent_instance_id is rejected")
	testing.expect_value(t, col7, "agent_instance_id")
	// Negative: bridge_id backs the primary key, so no kind may omit it.
	no_bridge := shell_test_session("s8", "u", "", domain.Shell_Session_Kind_Shell)
	col8, missing8, ok8 := domain.shell_session_validate_scope(no_bridge)
	testing.expect(t, !ok8 && missing8, "a session without a bridge_id is rejected")
	testing.expect_value(t, col8, "bridge_id")
	// Negative: a retired kind spelling is not silently accepted.
	retired := shell_test_session("s9", "u", "brg_1", "interactive")
	_, _, ok9 := domain.shell_session_validate_scope(retired)
	testing.expect(t, !ok9, "a retired kind spelling is rejected, not aliased")
}
// --- REQ-SHELL-10: the convergence diff's row set ----------------------------
//
// shell_session_list_live_by_bridge decides WHICH ROWS an incoming inventory is
// allowed to reason about, and the diff reads "live here, absent from the inventory"
// as death. So this query being wrong in either direction is a real failure: return
// another bridge's rows and one bridge's reconnect terminates another's sessions;
// return terminal rows and the diff revives finished ones.
//
// Asserted against real SQL rather than only through the service's fake, because the
// terminal set here is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES — a binding
// that a hand-written fake cannot get wrong and the SQL can.
@(test)
test_shell_session_list_live_by_bridge_is_scoped_and_live_only :: proc(t: ^testing.T) {
	conn, ok := shell_test_db(t, "livebybridge")
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	impl := Shell_Session_Repo_SQLite{}
	repo := new_shell_session_repository(&impl, &conn)
	seed :: proc(repo: ^iface.Shell_Session_Repository, id, owner, bridge, status: string) {
		s := shell_test_session(id, owner, bridge, domain.Shell_Session_Kind_Shell)
		s.status = status
		_, _ = iface.shell_session_upsert(repo, s)
	}
	seed(&repo, "shl_live_1",  "user_a", "brg_1", domain.Shell_Session_Status_Running)
	seed(&repo, "shl_live_2",  "user_a", "brg_1", domain.Shell_Session_Status_Starting)
	seed(&repo, "shl_exited",  "user_a", "brg_1", domain.Shell_Session_Status_Exited)
	seed(&repo, "shl_killed",  "user_a", "brg_1", domain.Shell_Session_Status_Killed)
	seed(&repo, "shl_failed",  "user_a", "brg_1", domain.Shell_Session_Status_Failed)
	// Another bridge AND another owner: the query is owner-unscoped by design, so the
	// bridge filter is the only thing keeping this row out.
	seed(&repo, "shl_other",   "user_b", "brg_2", domain.Shell_Session_Status_Running)
	rows, err := iface.shell_session_list_live_by_bridge(&repo, "brg_1", 100)
	testing.expect(t, err.code == .None, "live listing succeeds")
	defer domain.shell_sessions_destroy(rows)
	testing.expect_value(t, len(rows), 2)
	for row in rows {
		testing.expect_value(t, row.bridge_id, "brg_1")
		testing.expect(t, !domain.shell_session_is_terminal(row), "a terminal row must not be listed as live")
	}
	// A bridge with nothing live gets an empty set, not an error and not everyone
	// else's rows — the case a bridge that restarted clean hits on every reconnect.
	none, none_err := iface.shell_session_list_live_by_bridge(&repo, "brg_unknown", 100)
	testing.expect(t, none_err.code == .None, "an unknown bridge is not an error")
	defer domain.shell_sessions_destroy(none)
	testing.expect_value(t, len(none), 0)
}
// --- Consolidated from shell_session_req2_repo_test.odin ---
@(private = "file")
req2_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}
@(private = "file")
req2_session :: proc(session_id, owner, bridge, kind: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = kind,
		cmd              = "serve",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}
// --- AC13: a port is held while live and RELEASED when terminal --------------
@(test)
test_req2_port_is_held_while_live_and_released_when_terminal :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "port")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	holder := req2_session("sh_holder", "owner_a", "brg_1", domain.Shell_Session_Kind_Server)
	holder.chain_id = "chain_1"
	holder.server_port = 8111
	_, err := iface.shell_session_upsert(&repo, holder)
	testing.expect(t, err.code == .None, "holder stored")
	found, held, ferr := iface.shell_session_find_live_by_port(&repo, "brg_1", 8111)
	testing.expect(t, ferr.code == .None, "lookup ok")
	testing.expect(t, held, "a LIVE session holds its port")
	testing.expect_value(t, found.session_id, "sh_holder")
	// A different bridge is a different host: the same port number there is not a
	// conflict, which is why the lookup is bridge-scoped.
	_, other_bridge, _ := iface.shell_session_find_live_by_port(&repo, "brg_2", 8111)
	testing.expect(t, !other_bridge, "a port on another bridge is not this bridge's conflict")
	// RELEASE. The holder exits; the port must become free — "live" is the domain's
	// terminal-status set inverted, so this follows from the same rule that makes a
	// session terminal anywhere else.
	holder.status = domain.Shell_Session_Status_Exited
	holder.finished_at = "2026-09-28T01:00:00Z"
	_, _ = iface.shell_session_upsert(&repo, holder)
	_, still_held, _ := iface.shell_session_find_live_by_port(&repo, "brg_1", 8111)
	testing.expect(t, !still_held, "a terminal session releases its port")
}
// The lookup is owner-UNSCOPED on purpose: a TCP port belongs to the host, so a
// conflict across tenants is a real conflict. (The MESSAGE the caller sees is
// asymmetric — see the service tests — but the detection must not be.)
@(test)
test_req2_port_conflict_is_detected_across_owners :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "portcross")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	holder := req2_session("sh_tenant_b", "owner_b", "brg_1", domain.Shell_Session_Kind_Server)
	holder.chain_id = "chain_b"
	holder.server_port = 9000
	_, _ = iface.shell_session_upsert(&repo, holder)
	found, held, _ := iface.shell_session_find_live_by_port(&repo, "brg_1", 9000)
	testing.expect(t, held, "another tenant's live hold is still a conflict on this host")
	testing.expect_value(t, found.owner_user_id, "owner_b")
}
// --- AC14: the counts the caps are built on ---------------------------------
@(test)
test_req2_live_counts_are_per_kind_and_per_scope :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "counts")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	for i in 0 ..< 3 {
		run := req2_session(fmt.tprintf("sh_run_%d", i), "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
		run.agent_instance_id = "inst_a"
		_, _ = iface.shell_session_upsert(&repo, run)
	}
	// A different agent's run must not count against inst_a's cap.
	other := req2_session("sh_run_other", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	other.agent_instance_id = "inst_b"
	_, _ = iface.shell_session_upsert(&repo, other)
	n, cerr := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "agent_instance_id", "inst_a")
	testing.expect(t, cerr.code == .None, "count ok")
	testing.expect_value(t, n, 3)
	// Terminal sessions do not count: the cap bounds what is LIVE, so finished runs
	// never accumulate into a permanent lockout.
	done := req2_session("sh_run_0", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	done.agent_instance_id = "inst_a"
	done.status = domain.Shell_Session_Status_Exited
	done.finished_at = "2026-09-28T01:00:00Z"
	_, _ = iface.shell_session_upsert(&repo, done)
	n2, _ := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "agent_instance_id", "inst_a")
	testing.expect_value(t, n2, 2)
	// Servers are counted per chain, and a run never counts as a server.
	srv := req2_session("sh_srv_1", "owner_a", "brg_1", domain.Shell_Session_Kind_Server)
	srv.chain_id = "chain_1"
	_, _ = iface.shell_session_upsert(&repo, srv)
	sn, _ := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Server, "chain_id", "chain_1")
	testing.expect_value(t, sn, 1)
}
// The scope column is a CLOSED SET taken from the domain, never free text, so the
// concatenated identifier cannot become an injection point.
@(test)
test_req2_live_count_refuses_an_unknown_scope_column :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "badcol")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	_, err := iface.shell_session_count_live(&repo, "owner_a", domain.Shell_Session_Kind_Run, "cmd; DROP TABLE shell_sessions", "x")
	testing.expect(t, err.code != .None, "an unrecognised scope column is refused, not interpolated")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions"), "and the table is still there")
}
// --- AC9: output is NEVER in the hub DB -------------------------------------
// AC9's "assert the no-DB property". Asserted against the SCHEMA rather than a
// code path, because that is the form the property actually takes: if there is
// nowhere to put output, no future code path can start putting it there. Output
// is streamed or read on demand from the bridge and lives only on that host.
@(test)
test_req2_the_hub_schema_has_nowhere_to_store_output :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "nooutput")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	for column in ([]string{"output", "stdout", "stderr", "log", "output_tail", "log_text"}) {
		testing.expect(t, !table_column_exists(&conn, "shell_sessions", column),
			fmt.tprintf("shell_sessions must have no %q column: output never enters the hub DB", column))
	}
}
// --- migration 049 -----------------------------------------------------------
@(test)
test_req2_migration_049_adds_its_columns_and_is_idempotent :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "mig049")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "background"), "background column added")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "conversation_id"), "conversation_id column added")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_conversation"), "the delivery lookup index exists")
	// The self-heal twin must be safe to re-run. SQLite has no ALTER TABLE ADD
	// COLUMN IF NOT EXISTS, so a naive re-exec is a hard "duplicate column name"
	// error that would abort startup migrations — this is the guard against that.
	testing.expect(t, upgrade_shell_sessions_background_schema(&conn), "the self-heal twin is idempotent")
	testing.expect(t, upgrade_shell_sessions_background_schema(&conn), "and still idempotent on a third run")
	// Re-running the whole migrator is likewise a no-op rather than a failure.
	again, _ := run_migrations(&conn)
	testing.expect(t, again, "migrations are re-runnable")
}
// background round-trips, and — the part that matters — a bridge-event upsert
// carrying the default false does NOT clear a run the user has already
// backgrounded. That is what the MAX() in the upsert is for.
@(test)
test_req2_background_is_one_way_through_the_upsert :: proc(t: ^testing.T) {
	conn, ok := req2_db(t, "bgcol")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	run := req2_session("sh_bg", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	run.agent_instance_id = "inst_a"
	run.conversation_id = "chat_1"
	run.background = true
	_, _ = iface.shell_session_upsert(&repo, run)
	stored, found, _ := iface.shell_session_get(&repo, "owner_a", "sh_bg")
	testing.expect(t, found, "stored")
	testing.expect(t, stored.background, "background round-trips")
	testing.expect_value(t, stored.conversation_id, "chat_1")
	// A bridge exit report carries background=false by default. It must not undo the
	// user's conversion.
	exit_report := req2_session("sh_bg", "owner_a", "brg_1", domain.Shell_Session_Kind_Run)
	exit_report.agent_instance_id = "inst_a"
	exit_report.status = domain.Shell_Session_Status_Exited
	exit_report.background = false
	_, _ = iface.shell_session_upsert(&repo, exit_report)
	after, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_bg")
	testing.expect(t, after.background, "a default-carrying upsert cannot clear an explicit backgrounding")
	testing.expect_value(t, after.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, after.conversation_id, "chat_1")
}
// --- Consolidated from shell_session_req3_repo_test.odin ---
@(private = "file")
req3_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	return conn, true
}
@(private = "file")
req3_session :: proc(session_id, owner, bridge: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = owner,
		bridge_id        = bridge,
		kind             = domain.Shell_Session_Kind_Shell,
		cmd              = "zsh",
		status           = domain.Shell_Session_Status_Running,
		started_at       = "2026-09-28T00:00:00Z",
		created_at       = "2026-09-28T00:00:00Z",
		last_activity_at = "2026-09-28T00:00:00Z",
	}
}
@(private = "file")
req3_repo :: proc(t: ^testing.T, conn: ^Conn, impl: ^Shell_Session_Repo_SQLite) -> (iface.Shell_Session_Repository, bool) {
	migrated, _ := run_migrations(conn)
	if !testing.expect(t, migrated, "migrations ran") do return {}, false
	return new_shell_session_repository(impl, conn), true
}
// --- AC1 + AC3: the intent persists, and a second request keeps the first time --
@(test)
test_req3_kill_intent_persists_and_is_first_writer_wins :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "persist")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	_, err := iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	testing.expect(t, err.code == .None, "session stored")
	// A fresh session carries no intent.
	before, found, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect(t, found, "session readable")
	testing.expect_value(t, before.kill_requested_at, "")
	testing.expect(t, !domain.shell_session_kill_intent_pending(before), "nothing pending yet")
	// AC1: accepting a kill writes the intent, and it reads back.
	set, set_err := iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	testing.expect(t, set_err.code == .None, "intent write ok")
	testing.expect(t, set, "intent reported outstanding")
	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
	testing.expect(t, domain.shell_session_kill_intent_pending(stored), "intent is pending on a live session")
	// AC3, the hub half: a SECOND kill is a success and does NOT move the
	// timestamp. "Pending since" must be when the user first asked, or a retried
	// kill would look newer than it is forever.
	again, again_err := iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T11:30:00Z")
	testing.expect(t, again_err.code == .None, "second intent write ok")
	testing.expect(t, again, "second request still reports outstanding — a retry is not a failure")
	after, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, after.kill_requested_at, "2026-09-28T10:00:00Z")
}
// A kill intent cannot be written for someone else's session: the write is
// owner-scoped, so a wrong owner matches no row and reports false rather than
// touching it.
@(test)
test_req3_kill_intent_write_is_owner_scoped :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "owner")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	set, _ := iface.shell_session_set_kill_requested(&repo, "owner_b", "sh_1", "2026-09-28T10:00:00Z")
	testing.expect(t, !set, "another owner cannot request a kill on this session")
	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "")
}
// --- §5: a terminal status clears the intent, through the upsert ---------------
// The intent must be retired the moment the session is over, and it must happen in
// the upsert rather than in a caller: a spent intent left set would be re-delivered
// on the next reconnect, and the pid it named may by then belong to another process.
@(test)
test_req3_terminal_status_clears_the_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "clear")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	// The shape a bridge shell_exited upsert has: a terminal status, and
	// kill_requested_at left at its zero value because the bridge never sets it.
	exited := req3_session("sh_1", "owner_a", "brg_1")
	exited.status      = domain.Shell_Session_Status_Killed
	exited.finished_at = "2026-09-28T10:00:05Z"
	_, exit_err := iface.shell_session_upsert(&repo, exited)
	testing.expect(t, exit_err.code == .None, "exit upsert ok")
	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Killed)
	testing.expect_value(t, stored.kill_requested_at, "")
	testing.expect(t, !domain.shell_session_kill_intent_pending(stored), "a spent intent is not pending")
	// Every terminal status clears it, not just "killed" — the set comes from
	// domain.SHELL_SESSION_TERMINAL_STATUSES, so this holds for whatever is in it.
	for terminal_status in domain.SHELL_SESSION_TERMINAL_STATUSES {
		live := req3_session("sh_loop", "owner_a", "brg_1")
		_, _ = iface.shell_session_upsert(&repo, live)
		_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_loop", "2026-09-28T10:00:00Z")
		pending, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_loop")
		testing.expect(t, pending.kill_requested_at != "", "intent set before the terminal write")
		done := req3_session("sh_loop", "owner_a", "brg_1")
		done.status = terminal_status
		_, _ = iface.shell_session_upsert(&repo, done)
		cleared, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_loop")
		testing.expect(t, cleared.kill_requested_at == "",
			fmt.tprintf("terminal status %q must clear the intent", terminal_status))
		_, _ = iface.shell_session_delete(&repo, "owner_a", "sh_loop")
	}
}
// The other direction, and the one a careless CASE would break: an upsert that is
// NOT terminal and carries no intent must LEAVE a pending one alone. Every
// bridge-event write has exactly that shape, so getting this wrong would drop the
// pending kill on the next status ping.
@(test)
test_req3_a_non_terminal_upsert_does_not_drop_a_pending_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "keep")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	ping := req3_session("sh_1", "owner_a", "brg_1")
	ping.last_activity_at = "2026-09-28T10:00:09Z"
	_, _ = iface.shell_session_upsert(&repo, ping)
	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
}
// --- the replay query --------------------------------------------------------
// The reconnect replay must see exactly the OUTSTANDING kills on ITS bridge:
// oldest first, no spent intents, no other bridge's sessions, nothing without an
// intent at all.
@(test)
test_req3_pending_kill_listing_is_outstanding_only_and_bridge_scoped :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "list")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	// Two outstanding on brg_1, requested in a known order.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_newer", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_newer", "2026-09-28T10:05:00Z")
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_older", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_older", "2026-09-28T10:00:00Z")
	// No intent at all.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_quiet", "owner_a", "brg_1"))
	// Intent that was spent — the session terminated. Written as a kill request
	// followed by a terminal upsert, i.e. exactly how a real one is spent.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_done", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_done", "2026-09-28T09:00:00Z")
	done := req3_session("sh_done", "owner_a", "brg_1")
	done.status = domain.Shell_Session_Status_Exited
	_, _ = iface.shell_session_upsert(&repo, done)
	// Another bridge's outstanding kill, which this bridge must never be handed.
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_elsewhere", "owner_a", "brg_2"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_elsewhere", "2026-09-28T08:00:00Z")
	pending, list_err := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	testing.expect(t, list_err.code == .None, "listing ok")
	defer domain.shell_sessions_destroy(pending)
	if !testing.expect_value(t, len(pending), 2) do return
	// Oldest first: the longest-waiting kill is delivered first.
	testing.expect_value(t, pending[0].session_id, "sh_older")
	testing.expect_value(t, pending[1].session_id, "sh_newer")
	for s in pending {
		testing.expect(t, domain.shell_session_kill_intent_pending(s), "every listed intent is outstanding")
	}
}
// A session whose status is terminal but which somehow still carries an intent (a
// row written before the auto-clear existed, or edited by hand) is excluded by the
// QUERY as well as by the domain predicate. Belt and braces on purpose: replaying a
// spent kill is how a signal reaches a recycled pid.
@(test)
test_req3_pending_kill_listing_excludes_a_terminal_row_that_still_carries_an_intent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "stale")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo, ready := req3_repo(t, &conn, &impl)
	if !ready do return
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	// Force the state the upsert would never leave behind, bypassing it entirely.
	testing.expect(t, exec(&conn, "UPDATE shell_sessions SET status='exited' WHERE session_id='sh_1';"),
		"status forced terminal behind the upsert's back")
	stored, _, _ := iface.shell_session_get(&repo, "owner_a", "sh_1")
	testing.expect(t, stored.kill_requested_at != "", "the stale intent is really still there")
	testing.expect(t, !domain.shell_session_kill_intent_pending(stored), "but it is not OUTSTANDING")
	pending, _ := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	defer domain.shell_sessions_destroy(pending)
	testing.expect_value(t, len(pending), 0)
}
// --- migration 050 -----------------------------------------------------------
@(test)
test_req3_migration_050_adds_its_objects_and_is_idempotent :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "mig050")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "kill_requested_at column added")
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "the replay lookup index exists")
	testing.expect(t, upgrade_shell_sessions_kill_intent_schema(&conn), "the self-heal twin is idempotent")
	testing.expect(t, upgrade_shell_sessions_kill_intent_schema(&conn), "and still idempotent on a third run")
	again, _ := run_migrations(&conn)
	testing.expect(t, again, "migrations are re-runnable")
}
// THE PARTIAL-APPLY CASE (REQ-SHELL-13 N1), which is why 050's skip guard is keyed
// on the INDEX — the last object it creates — rather than on the column.
//
// run_migrations is not transactional, so a pass that added the column and died
// before the index is a reachable state, and on a database that reached 050 through
// the pre-ledger recovery path there is no ledger row to fall back on either. A guard
// keyed on the column would declare that database finished and the replay lookup
// would have no index, forever.
//
// Simulated exactly: drop the index AND the ledger row, leaving the column. Then the
// whole migrator must (a) not report it as already applied, (b) not die on the
// duplicate column the migration file would re-add, and (c) end with both objects
// present. (b) is the reason the guard has a repair branch rather than only a skip:
// the self-heal twins run after the loop, so a fall-through here would abort startup
// on the very state the guard exists to catch.
@(test)
test_req3_migration_050_guard_catches_and_repairs_a_partial_apply :: proc(t: ^testing.T) {
	conn, ok := req3_db(t, "partial")
	if !ok do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations ran") do return
	testing.expect(t, exec(&conn, "DROP INDEX IF EXISTS shell_sessions_pending_kill;"), "index dropped")
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='050_shell_sessions_kill_intent.sql';"),
		"ledger row removed — the pre-ledger recovery path has none either")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "the column is still there")
	testing.expect(t, !sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "…and the index is not")
	// (a) Keyed on the last object, this half-applied database does NOT read back as
	// applied. A column-keyed check would have said it did.
	testing.expect(t, !migration_applied(&conn, "050_shell_sessions_kill_intent.sql"),
		"a half-applied 050 must not read back as applied")
	// (b) + (c) The migrator repairs it instead of dying on the duplicate column.
	repaired, rerr := run_migrations(&conn)
	testing.expect(t, repaired, fmt.tprintf("the migrator must repair a half-applied 050, not fail: %s", rerr.message))
	testing.expect(t, sqlite_object_exists(&conn, "shell_sessions_pending_kill"), "index restored")
	testing.expect(t, table_column_exists(&conn, "shell_sessions", "kill_requested_at"), "column untouched")
	testing.expect(t, migration_applied(&conn, "050_shell_sessions_kill_intent.sql"), "and now it is applied")
	// The repaired index really is the one the replay lookup needs: a pending-kill
	// listing works against it.
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	_, _ = iface.shell_session_upsert(&repo, req3_session("sh_1", "owner_a", "brg_1"))
	_, _ = iface.shell_session_set_kill_requested(&repo, "owner_a", "sh_1", "2026-09-28T10:00:00Z")
	pending, _ := iface.shell_session_list_pending_kills(&repo, "brg_1", 100)
	defer domain.shell_sessions_destroy(pending)
	testing.expect_value(t, len(pending), 1)
}
// --- Consolidated from shell_session_req9_repo_test.odin ---
@(private = "file")
t9_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}
@(private = "file")
t9_row :: proc(session_id, kind, chain_id, agent_id, status, started_at: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = "usr_t9",
		bridge_id         = "brg_t9",
		chain_id          = chain_id,
		agent_instance_id = agent_id,
		kind              = kind,
		cmd               = "npm run dev",
		status            = status,
		started_at        = started_at,
		created_at        = "2026-09-29T09:00:00Z",
		last_activity_at  = "2026-09-29T09:00:00Z",
	}
}
@(private = "file")
t9_ids :: proc(rows: [dynamic]domain.Shell_Session) -> [dynamic]string {
	out := make([dynamic]string)
	for r in rows do append(&out, r.session_id)
	return out
}
@(private = "file")
t9_has :: proc(rows: [dynamic]domain.Shell_Session, want: string) -> bool {
	for r in rows do if r.session_id == want do return true
	return false
}
// list_live_by_kind returns live rows of the asked-for kind only, from every owner and
// every bridge, and it returns them OLDEST FIRST.
@(test)
test_t9_live_by_kind_filters_and_orders :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "kind")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)
	// Inserted in a deliberately scrambled order so a passing ORDER BY cannot be an
	// accident of insertion order.
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_mid",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_old",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-27T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_new",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T11:00:00Z"))
	// Must NOT appear: wrong kind, and terminal.
	_, _ = iface.shell_session_upsert(&repo, t9_row("run_1",     domain.Shell_Session_Kind_Run,    "",        "inst_1", domain.Shell_Session_Status_Running, "2026-09-20T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("shell_1",   domain.Shell_Session_Kind_Shell,  "",        "",       domain.Shell_Session_Status_Running, "2026-09-20T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_dead",  domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Exited,  "2026-09-20T08:00:00Z"))
	rows, err := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 100)
	defer domain.shell_sessions_destroy(rows)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 3)
	// Oldest first, exactly.
	ids := t9_ids(rows); defer delete(ids)
	testing.expect_value(t, ids[0], "srv_old")
	testing.expect_value(t, ids[1], "srv_mid")
	testing.expect_value(t, ids[2], "srv_new")
	testing.expect(t, !t9_has(rows, "run_1"),    "a run must never be a candidate")
	testing.expect(t, !t9_has(rows, "shell_1"),  "a shell must never be a candidate")
	testing.expect(t, !t9_has(rows, "srv_dead"), "a terminal server is not live")
}
// THE ORDER IS WHAT MAKES THE CAP SAFE. With a limit of one, the row returned must be the
// OLDEST — the one most likely to need reaping. Newest-first would let a cap starve the
// oldest servers indefinitely, which is the one failure an age reap must not have.
@(test)
test_t9_live_by_kind_limit_keeps_the_oldest :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "limit")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_new", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-29T11:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_old", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-27T08:00:00Z"))
	rows, _ := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 1)
	defer domain.shell_sessions_destroy(rows)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].session_id, "srv_old")
}
// The terminal set is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES rather than
// spelled in the SQL, so every terminal status is excluded without this query naming any
// of them. Asserted by walking the domain's own table, which means a fourth terminal
// status added there is covered by this test the day it is added.
@(test)
test_t9_live_by_kind_excludes_every_terminal_status :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "terminal")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)
	for status, i in domain.SHELL_SESSION_TERMINAL_STATUSES {
		id := fmt.tprintf("srv_term_%d", i)
		_, _ = iface.shell_session_upsert(&repo, t9_row(id, domain.Shell_Session_Kind_Server, "chain_1", "", status, "2026-09-20T08:00:00Z"))
	}
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_live", domain.Shell_Session_Kind_Server, "chain_1", "", domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	rows, _ := iface.shell_session_list_live_by_kind(&repo, domain.Shell_Session_Kind_Server, 100)
	defer domain.shell_sessions_destroy(rows)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].session_id, "srv_live")
}
// AC3 IN ITS STRONGEST FORM. The chain reap's candidate query is list_by_chain, which
// AND-s in a kind clause derived from domain.SHELL_SESSION_SCOPE_RULES. Server keys on
// .Chain and a shell may optionally carry it, so a run CANNOT be returned — even one
// wrongly carrying a chain_id, which is what is seeded here — while a chain-attached
// shell is listed (the reap's _reap_kill_if_eligible still kills servers only).
@(test)
test_t9_by_chain_never_returns_runs :: proc(t: ^testing.T) {
	conn, ok := t9_db(t, "scope")
	if !ok { close(&conn); return }
	defer close(&conn)
	impl := Shell_Session_Repo_SQLite{conn = &conn}
	repo := new_shell_session_repository(&impl, &conn)
	_, _ = iface.shell_session_upsert(&repo, t9_row("srv_1",   domain.Shell_Session_Kind_Server, "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	// Mis-scoped on purpose: a real run never carries a chain_id, and the point is that
	// even one that did could not be reached through a by-chain listing.
	_, _ = iface.shell_session_upsert(&repo, t9_row("run_1",   domain.Shell_Session_Kind_Run,    "chain_1", "inst_1", domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	_, _ = iface.shell_session_upsert(&repo, t9_row("shell_1", domain.Shell_Session_Kind_Shell,  "chain_1", "",       domain.Shell_Session_Status_Running, "2026-09-29T08:00:00Z"))
	rows, _, err := iface.shell_session_list_by_chain(&repo, "usr_t9", "chain_1", domain.Shell_Session_Status_Group_Live, "", 100)
	defer domain.shell_sessions_destroy(rows)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, t9_has(rows, "srv_1"),    "a by-chain listing returns the chain's server")
	testing.expect(t, t9_has(rows, "shell_1"),  "a by-chain listing returns a chain-attached shell")
	testing.expect(t, !t9_has(rows, "run_1"),   "a by-chain listing must never return a run")
}
// --- Consolidated from shell_session_req12_repo_test.odin ---
@(private = "file")
t12_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}
@(private = "file")
t12_row :: proc(session_id, bridge_id: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_t12",
		bridge_id        = bridge_id,
		kind             = "run",
		cmd              = "echo hi",
		status           = "running",
		started_at       = "2026-09-29T09:00:00Z",
		created_at       = "2026-09-29T09:00:00Z",
		last_activity_at = "2026-09-29T09:00:00Z",
	}
}
// t12_make_ambiguous forces the state the unique index normally forbids: two rows,
// same (owner_user_id, session_id), different bridge_id. The index is dropped first
// because it would otherwise reject the second insert; the composite PK is left
// intact and the differing bridge_id satisfies it.
@(private = "file")
t12_make_ambiguous :: proc(t: ^testing.T, conn: ^Conn, repo: ^iface.Shell_Session_Repository, session_id: string) -> bool {
	a_ok, _ := iface.shell_session_upsert(repo, t12_row(session_id, "brg_a"))
	if !testing.expect(t, a_ok, "first row inserted") do return false
	if !testing.expect(t, exec(conn, "DROP INDEX IF EXISTS shell_sessions_owner_session;"), "unique index dropped") do return false
	b_ok, _ := iface.shell_session_upsert(repo, t12_row(session_id, "brg_b"))
	if !testing.expect(t, b_ok, "second row inserted once the index is gone") do return false
	// Prove the fixture actually produced TWO rows. Without this the ambiguity tests
	// below could pass for the wrong reason — an upsert that silently overwrote row A
	// would leave one row, and "no conflict raised" would then look like a bug in the
	// code under test rather than a broken fixture.
	stmt: sqlite3_stmt = nil
	count_sql := cstring("SELECT COUNT(*) FROM shell_sessions WHERE owner_user_id = 'usr_t12' AND session_id = ?;")
	if !testing.expect(t, sqlite3_prepare_v2(conn.db, count_sql, -1, &stmt, nil) == SQLITE_OK, "count prepared") do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, session_id)
	if !testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW, "count stepped") do return false
	// Read the count as TEXT: conn.odin binds no sqlite3_column_int, and adding one
	// for a test assertion would be a change to the shared binding surface for no
	// gain. SQLite converts the integer for us and "2" is as checkable as 2.
	n := column_text_unowned(stmt, 0)
	return testing.expectf(t, n == "2", "fixture must produce exactly 2 rows, got %s", n)
}
// (a) THE NORMAL READ IS UNCHANGED. The whole risk of this change is that LIMIT 2 plus
// a second step breaks the ordinary single-row path, so that path is asserted first and
// in full rather than assumed.
@(test)
test_req12_single_row_read_is_unchanged :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "single")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	up_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_solo", "brg_a"))
	if !testing.expect(t, up_ok, "row inserted") do return
	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_solo")
	defer domain.shell_session_destroy(session)
	testing.expect(t, found, "unambiguous session is found")
	testing.expectf(t, err.code == .None, "no error on the normal path, got %v", err.code)
	testing.expectf(t, session.session_id == "sh_solo", "session_id round-trips, got %q", session.session_id)
	testing.expectf(t, session.bridge_id == "brg_a", "bridge_id round-trips, got %q", session.bridge_id)
	testing.expectf(t, session.cmd == "echo hi", "cmd round-trips, got %q", session.cmd)
	testing.expectf(t, session.status == "running", "status round-trips, got %q", session.status)
}
// A MISSING SESSION IS STILL A PLAIN MISS, not a conflict. This is the boundary that
// makes the conflict code meaningful: if absence also raised .Conflict, callers could
// not use the code to tell corruption from an ordinary 404.
@(test)
test_req12_absent_session_is_not_a_conflict :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "absent")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_nope")
	defer domain.shell_session_destroy(session)
	testing.expect(t, !found, "absent session is not found")
	testing.expectf(t, err.code == .None, "absence is not an error, got %v", err.code)
}
// (b) THE CORE ASSERTION. Two rows: the read must return the CONFLICT and MUST NOT
// return a row. Both halves are asserted — "raised an error" alone would still permit
// handing back a row alongside it, and a caller that checks `found` before `err` would
// then act on an arbitrary match anyway.
@(test)
test_req12_ambiguous_read_refuses_and_returns_no_row :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "ambig")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return
	session, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_dup")
	defer domain.shell_session_destroy(session)
	testing.expectf(t, err.code == .Conflict, "ambiguous read raises .Conflict, got %v (%s)", err.code, err.message)
	testing.expect(t, !found, "ambiguous read reports NOT found, so a found-first caller cannot act on a guess")
	testing.expectf(t, session.session_id == "", "ambiguous read returns NO row, got session_id %q", session.session_id)
	testing.expectf(t, session.bridge_id == "", "ambiguous read leaks no row fields, got bridge_id %q", session.bridge_id)
}
// AMBIGUITY IS SCOPED TO THE OWNER AND ID THAT ARE ACTUALLY DUPLICATED. A corrupt row
// pair must not poison unrelated reads — otherwise the refusal would take out the whole
// table rather than the one id it cannot resolve.
@(test)
test_req12_conflict_does_not_leak_to_other_ids_or_owners :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "scope")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return
	clean_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_clean", "brg_a"))
	if !testing.expect(t, clean_ok, "unrelated row inserted") do return
	clean, found, err := iface.shell_session_get(&repo, "usr_t12", "sh_clean")
	defer domain.shell_session_destroy(clean)
	testing.expect(t, found, "a different id is still readable")
	testing.expectf(t, err.code == .None, "a different id raises no conflict, got %v", err.code)
	other, other_found, other_err := iface.shell_session_get(&repo, "usr_other", "sh_dup")
	defer domain.shell_session_destroy(other)
	testing.expect(t, !other_found, "another owner does not see the duplicated id")
	testing.expectf(t, other_err.code == .None, "another owner gets a plain miss, not a conflict, got %v", other_err.code)
}
// get_by_id IS DELIBERATELY UNCHANGED and this pins that decision. Its key
// (bridge_id, session_id) IS the composite PK T1 installed, so it is single-row by the
// PK itself rather than by LIMIT 1 — the two rows above differ in bridge_id precisely
// because the PK forces them to, which means each is individually resolvable here.
// If someone later "makes this consistent" by adding a conflict branch, this fails and
// says why.
@(test)
test_req12_get_by_id_stays_resolvable_under_owner_ambiguity :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "byid")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return
	a, a_found, a_err := iface.shell_session_get_by_id(&repo, "brg_a", "sh_dup")
	defer domain.shell_session_destroy(a)
	testing.expect(t, a_found, "bridge A resolves its own row")
	testing.expectf(t, a_err.code == .None, "bridge-qualified read is not ambiguous, got %v", a_err.code)
	testing.expectf(t, a.bridge_id == "brg_a", "bridge A got ITS row, not bridge B's, got %q", a.bridge_id)
	b, b_found, b_err := iface.shell_session_get_by_id(&repo, "brg_b", "sh_dup")
	defer domain.shell_session_destroy(b)
	testing.expect(t, b_found, "bridge B resolves its own row")
	testing.expectf(t, b_err.code == .None, "bridge-qualified read is not ambiguous, got %v", b_err.code)
	testing.expectf(t, b.bridge_id == "brg_b", "bridge B got ITS row, got %q", b.bridge_id)
}
// THE SECOND INSTANCE OF THE DEFECT SHAPE: set_kill_requested's read-back.
//
// BE PRECISE ABOUT WHAT THIS ASSERTS. The boolean this returned was already invariant
// under ambiguity — the UPDATE it follows hits EVERY matching row, so a non-empty
// kill_requested_at was true of all of them. This test does not claim a wrong answer
// was being returned. It asserts that the call now REFUSES to report success for a
// session it cannot identify, which matters because the reap path
// (shell_session_reap.odin:202) reaches this without passing through the get above.
@(test)
test_req12_kill_intent_readback_refuses_when_ambiguous :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "kill")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	if !t12_make_ambiguous(t, &conn, &repo, "sh_dup") do return
	pending, err := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_dup", "2026-09-29T09:05:00Z")
	testing.expectf(t, err.code == .Conflict, "ambiguous kill read-back raises .Conflict, got %v (%s)", err.code, err.message)
	testing.expect(t, !pending, "ambiguous kill read-back does not report success")
}
// The same call on an UNAMBIGUOUS session still works, including the idempotent second
// kill the read-back exists to make succeed. Without this, the conflict branch above
// could be passing because the whole procedure broke.
@(test)
test_req12_kill_intent_readback_unchanged_when_unambiguous :: proc(t: ^testing.T) {
	conn, ok := t12_db(t, "killok")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	up_ok, _ := iface.shell_session_upsert(&repo, t12_row("sh_solo", "brg_a"))
	if !testing.expect(t, up_ok, "row inserted") do return
	first, err1 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_solo", "2026-09-29T09:05:00Z")
	testing.expectf(t, err1.code == .None, "first kill raises no error, got %v", err1.code)
	testing.expect(t, first, "first kill reports the intent pending")
	// The idempotent retry: first-writer-wins on the column, success on the read-back.
	second, err2 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_solo", "2026-09-29T09:06:00Z")
	testing.expectf(t, err2.code == .None, "second kill raises no error, got %v", err2.code)
	testing.expect(t, second, "second kill still reports pending")
	// A session that does not exist for this owner is still a plain false, not a conflict.
	missing, err3 := iface.shell_session_set_kill_requested(&repo, "usr_t12", "sh_nope", "2026-09-29T09:05:00Z")
	testing.expectf(t, err3.code == .None, "absent session is not an error, got %v", err3.code)
	testing.expect(t, !missing, "absent session reports false")
}
// --- Consolidated from shell_session_req14_repo_test.odin ---
@(private = "file")
t14_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}
@(private = "file")
t14_row :: proc(session_id, bridge_id, status: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_t14",
		bridge_id        = bridge_id,
		kind             = domain.Shell_Session_Kind_Shell,
		cmd              = "zsh",
		status           = status,
		started_at       = "2026-09-28T09:00:00Z",
		created_at       = "2026-09-28T09:00:00Z",
		last_activity_at = "2026-09-28T09:00:00Z",
	}
}
@(private = "file")
t14_has :: proc(ids: [dynamic]string, want: string) -> bool {
	for id in ids {
		if id == want do return true
	}
	return false
}
// The discriminating case: five bridges, only two of which hold anything live. A query
// that returned every bridge mentioned in the table would pass a weaker test and would
// make the sweep read every bridge ever enrolled on every tick — the cost the shape was
// chosen to avoid.
//
// EVERY terminal status is represented, and each on its OWN bridge, so a status missing
// from the bound set shows up as an extra candidate rather than being masked by a live
// sibling on the same bridge.
@(test)
test_req14_live_bridge_ids_lists_only_bridges_with_live_sessions :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "live")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	for row in ([]domain.Shell_Session{
		t14_row("shl_run",      "brg_live_a", domain.Shell_Session_Status_Running),
		t14_row("shl_starting", "brg_live_b", domain.Shell_Session_Status_Starting),
		t14_row("shl_exited",   "brg_dead_x", domain.Shell_Session_Status_Exited),
		t14_row("shl_killed",   "brg_dead_y", domain.Shell_Session_Status_Killed),
		t14_row("shl_failed",   "brg_dead_z", domain.Shell_Session_Status_Failed),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}
	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "candidate listing succeeded")
	testing.expectf(t, len(ids) == 2, "only the two bridges with LIVE rows are candidates, got %d", len(ids))
	testing.expect(t, t14_has(ids, "brg_live_a"), "a running session makes its bridge a candidate")
	testing.expect(t, t14_has(ids, "brg_live_b"), "a starting session makes its bridge a candidate")
	// A bridge whose every session already ended needs no reaping, and reading it would
	// be pure waste on a 20-second loop.
	testing.expect(t, !t14_has(ids, "brg_dead_x"), "exited-only bridge is not a candidate")
	testing.expect(t, !t14_has(ids, "brg_dead_y"), "killed-only bridge is not a candidate")
	testing.expect(t, !t14_has(ids, "brg_dead_z"), "failed-only bridge is not a candidate")
}
// DISTINCT, and a mixed bridge. Three live rows on one bridge must yield ONE candidate —
// the sweep does a bridge read per returned id, so duplicates would multiply that read
// by the number of sessions. The mixed bridge also pins the direction of the predicate:
// one live row is enough to make a bridge a candidate even though terminal rows sit
// beside it, which is what makes the sweep able to finish a partially-ended bridge.
@(test)
test_req14_live_bridge_ids_are_distinct :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "distinct")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	for row in ([]domain.Shell_Session{
		t14_row("shl_1", "brg_busy",  domain.Shell_Session_Status_Running),
		t14_row("shl_2", "brg_busy",  domain.Shell_Session_Status_Running),
		t14_row("shl_3", "brg_busy",  domain.Shell_Session_Status_Starting),
		t14_row("shl_4", "brg_mixed", domain.Shell_Session_Status_Exited),
		t14_row("shl_5", "brg_mixed", domain.Shell_Session_Status_Running),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}
	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "candidate listing succeeded")
	testing.expectf(t, len(ids) == 2, "three live rows on one bridge is ONE candidate, got %d", len(ids))
	testing.expect(t, t14_has(ids, "brg_busy"), "the busy bridge appears exactly once")
	testing.expect(t, t14_has(ids, "brg_mixed"), "one live row among terminals still makes a candidate")
}
// Empty table: no candidates, no error. This is the steady state on a quiet host and the
// path the sweep takes on most of its ticks, so it must be boring rather than an error
// the reaper swallows.
@(test)
test_req14_live_bridge_ids_is_empty_when_nothing_is_live :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "empty")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	ids, err := iface.shell_session_list_live_bridge_ids(&repo, 100)
	defer { for id in ids do delete(id); delete(ids) }
	testing.expect(t, err.code == .None, "an empty table is not an error")
	testing.expect_value(t, len(ids), 0)
}
// The limit is a runaway backstop, so it must actually bound the result — and with the
// ORDER BY it must bound it to a STABLE prefix. An arbitrary subset that rotated between
// ticks would make a gone bridge reachable on some sweeps and not others, which is a far
// worse failure than a truncated list: it would be intermittent.
@(test)
test_req14_live_bridge_ids_limit_bounds_a_stable_prefix :: proc(t: ^testing.T) {
	conn, ok := t14_db(t, "limit")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	for row in ([]domain.Shell_Session{
		t14_row("shl_a", "brg_a", domain.Shell_Session_Status_Running),
		t14_row("shl_b", "brg_b", domain.Shell_Session_Status_Running),
		t14_row("shl_c", "brg_c", domain.Shell_Session_Status_Running),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}
	first, err1 := iface.shell_session_list_live_bridge_ids(&repo, 2)
	defer { for id in first do delete(id); delete(first) }
	testing.expect(t, err1.code == .None, "limited listing succeeded")
	testing.expectf(t, len(first) == 2, "limit must bound the result, got %d", len(first))
	testing.expect(t, t14_has(first, "brg_a") && t14_has(first, "brg_b"), "ORDER BY bridge_id makes the prefix the two lowest ids")
	second, err2 := iface.shell_session_list_live_bridge_ids(&repo, 2)
	defer { for id in second do delete(id); delete(second) }
	testing.expect(t, err2.code == .None, "repeat listing succeeded")
	testing.expect(t, t14_has(second, "brg_a") && t14_has(second, "brg_b"), "the same prefix every tick, not a rotating subset")
}
// --- Consolidated from shell_session_retention_test.odin ---
@(private = "file")
retention_db :: proc(t: ^testing.T, tag: string) -> (Conn, bool) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return conn, false
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return conn, false
	return conn, true
}
@(private = "file")
retention_row :: proc(session_id, status, finished_at: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id       = session_id,
		owner_user_id    = "usr_ret",
		bridge_id        = "brg_ret",
		kind             = domain.Shell_Session_Kind_Run,
		cmd              = "echo hi",
		status           = status,
		started_at       = "2026-01-01T00:00:00Z",
		created_at       = "2026-01-01T00:00:00Z",
		last_activity_at = finished_at,
		finished_at      = finished_at,
	}
}
@(private = "file")
retention_count :: proc(conn: ^Conn) -> string {
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM shell_sessions;"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return column_text(stmt, 0)
}
@(private = "file")
retention_exists :: proc(conn: ^Conn, session_id: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT 1 FROM shell_sessions WHERE session_id = '%s';", session_id)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}
// AC7, both halves in one table so the delete has to DISCRIMINATE rather than
// merely run: four rows of identical vintage, only the terminal ones eligible.
//
// The running and starting rows are the ones that matter. A server legitimately runs
// for weeks, so an age-only sweep would delete the row of a process that is still
// alive — the row whose loss is least recoverable, since the session then exists on
// the bridge with nothing on the hub describing it.
@(test)
test_shell_session_row_retention_spares_live_rows :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "live")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	old := "2026-01-02T00:00:00Z" // ancient, by any window
	for row in ([]domain.Shell_Session{
		retention_row("shl_exited", domain.Shell_Session_Status_Exited, old),
		retention_row("shl_killed", domain.Shell_Session_Status_Killed, old),
		retention_row("shl_failed", domain.Shell_Session_Status_Failed, old),
		retention_row("shl_running", domain.Shell_Session_Status_Running, old),
		retention_row("shl_starting", domain.Shell_Session_Status_Starting, old),
	}) {
		saved, err := iface.shell_session_upsert(&repo, row)
		testing.expect(t, saved && err.code == .None, "row seeded")
	}
	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-06-01T00:00:00Z")
	testing.expect(t, err.code == .None, "retention sweep succeeded")
	testing.expectf(t, deleted == 3, "only the three TERMINAL rows went, got %d", deleted)
	testing.expect(t, !retention_exists(&conn, "shl_exited"), "exited row reclaimed")
	testing.expect(t, !retention_exists(&conn, "shl_killed"), "killed row reclaimed")
	testing.expect(t, !retention_exists(&conn, "shl_failed"), "failed row reclaimed")
	testing.expect(t, retention_exists(&conn, "shl_running"), "a RUNNING row is never removed, whatever its age")
	testing.expect(t, retention_exists(&conn, "shl_starting"), "a STARTING row is never removed, whatever its age")
}
// The boundary itself: the same terminal row survives a cutoff before it and goes at
// a cutoff after it. Without this, a sweep that deleted every terminal row would pass
// the test above.
@(test)
test_shell_session_row_retention_respects_the_cutoff :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "cutoff")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	row := retention_row("shl_boundary", domain.Shell_Session_Status_Exited, "2026-03-10T00:00:00Z")
	saved, serr := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved && serr.code == .None, "row seeded")
	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-03-01T00:00:00Z")
	testing.expect(t, err.code == .None && deleted == 0, "a row that ended AFTER the cutoff is kept")
	testing.expect(t, retention_exists(&conn, "shl_boundary"), "still there")
	deleted2, err2 := iface.shell_session_delete_terminal_before(&repo, "2026-03-20T00:00:00Z")
	testing.expect(t, err2.code == .None && deleted2 == 1, "the same row past the cutoff is removed")
	testing.expect(t, !retention_exists(&conn, "shl_boundary"), "and is gone")
}
// A terminal row with no finished_at must still age out. Terminal status can be
// INFERRED — a bridge that never returned, a reconcile reaping an orphan — and such a
// row carries no end time. Without the COALESCE fallback it would compare against
// NULL, match nothing, and become immortal: the exact unbounded growth this exists to
// stop, hiding in the rows least likely to be noticed.
@(test)
test_shell_session_row_retention_handles_missing_finished_at :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "nofinish")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	row := retention_row("shl_nofinish", domain.Shell_Session_Status_Failed, "")
	row.last_activity_at = ""
	row.started_at = "2026-01-05T00:00:00Z"
	saved, serr := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved && serr.code == .None, "row seeded")
	deleted, err := iface.shell_session_delete_terminal_before(&repo, "2026-06-01T00:00:00Z")
	testing.expect(t, err.code == .None, "sweep succeeded")
	testing.expectf(t, deleted == 1, "a terminal row with no end time ages out on started_at, got %d", deleted)
}
// An empty cutoff is a caller that failed to read a clock. It must be REFUSED, not
// treated as "delete nothing" and certainly not as a comparison that could match:
// a silent no-op would hide a broken sweep for as long as nobody looked at row counts.
@(test)
test_shell_session_row_retention_refuses_an_empty_cutoff :: proc(t: ^testing.T) {
	conn, ok := retention_db(t, "nocutoff")
	if !ok do return
	defer close(&conn)
	impl: Shell_Session_Repo_SQLite
	repo := new_shell_session_repository(&impl, &conn)
	row := retention_row("shl_safe", domain.Shell_Session_Status_Exited, "2026-01-02T00:00:00Z")
	saved, _ := iface.shell_session_upsert(&repo, row)
	testing.expect(t, saved, "row seeded")
	deleted, err := iface.shell_session_delete_terminal_before(&repo, "")
	testing.expect(t, err.code == .Validation_Failed, "an empty cutoff is refused, not silently ignored")
	testing.expect(t, deleted == 0, "and nothing was deleted")
	testing.expect(t, retention_exists(&conn, "shl_safe"), "the row is untouched")
	// column_text allocates; the count is compared and then freed so the suite's
	// memory tracking stays clean.
	count := retention_count(&conn)
	defer delete(count)
	testing.expect(t, count == "1", "the table is intact")
}
