#+private file
// REQ-EA-2/8: the enrollment commit is ONE transaction. The failure-path tests make
// the second statement fail for real — a SQL trigger that RAISE(ABORT)s — and assert
// the first one was rolled back with it, not merely that the proc reported an error.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import "core:fmt"
import "core:testing"
import "core:thread"
import "core:time"

ENROLL_SCOPE :: "bridge:enroll"
RUNTIME_SCOPE :: "bridge:runtime"
NOW :: "2026-10-16T15:00:00Z"

Commit_Fixture :: struct {
	conn:      Conn,
	repo_impl: Bridge_Repo_SQLite,
	repo:      iface.Bridge_Repository,
}

fixture_open :: proc(t: ^testing.T, f: ^Commit_Fixture) -> bool {
	conn, mig_ok := tmpl_clone_migrated(t)
	if !mig_ok do return false
	f.conn = conn
	f.repo_impl = Bridge_Repo_SQLite{conn = &f.conn}
	f.repo = new_bridge_repository(&f.repo_impl, &f.conn)
	return mig_ok
}

seed_bridge :: proc(t: ^testing.T, f: ^Commit_Fixture, bridge_id, pending_until: string) {
	_, ok, _ := iface.bridge_save_bridge(&f.repo, domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = domain.User_ID("user_ea_commit"),
		label = "ea",
		machine_hostname = "box",
		capabilities_json = "{}",
		status = .Offline,
		created_at = NOW,
		updated_at = NOW,
		enrollment_pending_until = pending_until,
	})
	testing.expect(t, ok, "bridge seeded")
}

seed_family :: proc(t: ^testing.T, f: ^Commit_Fixture, bridge_id, family_id, scope: string) {
	for kind, i in ([2]domain.Bridge_Token_Kind{.Access, .Refresh}) {
		_, ok, _ := iface.bridge_save_token(&f.repo, domain.Bridge_Token{
			token_id = fmt.tprintf("%s_%d", family_id, i),
			bridge_id = bridge_id,
			kind = kind,
			token_hash = fmt.tprintf("hash_%s_%d", family_id, i),
			family_id = family_id,
			generation = 1,
			scope = scope,
			issued_at = NOW,
			expires_at = "2026-10-16T16:00:00Z",
			family_expires_at = "2026-11-16T15:00:00Z",
		})
		testing.expect(t, ok, "token seeded")
	}
}

// family_state reports how many of a family's rows are live, and in which scope.
family_state :: proc(f: ^Commit_Fixture, family_id: string) -> (live_enroll, live_runtime, revoked: int) {
	tokens, _ := iface.bridge_list_tokens_by_family(&f.repo, family_id)
	defer {
		for &tok in tokens do domain.bridge_token_destroy(&tok)
		delete(tokens)
	}
	for tok in tokens {
		if tok.revoked_at != "" {
			revoked += 1
		} else if tok.scope == ENROLL_SCOPE {
			live_enroll += 1
		} else if tok.scope == RUNTIME_SCOPE {
			live_runtime += 1
		}
	}
	return
}

pending_until_of :: proc(f: ^Commit_Fixture, bridge_id: string) -> string {
	b, ok, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	if !ok do return "<missing>"
	defer domain.bridge_destroy(&b)
	return fmt.tprintf("%s", b.enrollment_pending_until)
}

@(test)
test_enroll_commit_new_bridge_promotes_and_clears_pending_and_is_idempotent :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_new", "2026-10-16T15:05:00Z")
	seed_family(t, &f, "brg_new", "fam_new", ENROLL_SCOPE)

	outcome, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_new", "fam_new", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	testing.expect(t, ok, "commit ran")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Committed)
	e, r, _ := family_state(&f, "fam_new")
	testing.expect_value(t, e, 0)
	testing.expect_value(t, r, 2)
	testing.expect_value(t, pending_until_of(&f, "brg_new"), "")

	// A duplicate ok:true for the committed family: success, and nothing changes.
	again, again_ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_new", "fam_new", ENROLL_SCOPE, RUNTIME_SCOPE, true, NOW)
	testing.expect(t, again_ok, "duplicate commit ran")
	testing.expect_value(t, again, iface.Enrollment_Commit_Outcome.Already_Committed)
	_, r2, rev2 := family_state(&f, "fam_new")
	testing.expect_value(t, r2, 2)
	testing.expect_value(t, rev2, 0)
}

@(test)
test_enroll_commit_refuses_a_rolled_back_family :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_rb", "2026-10-16T15:05:00Z")
	seed_family(t, &f, "brg_rb", "fam_rb", ENROLL_SCOPE)
	_, _, _ = iface.bridge_revoke_token_family(&f.repo, "fam_rb", NOW)

	outcome, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_rb", "fam_rb", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	testing.expect(t, ok, "commit ran")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Not_Pending)
	e, r, _ := family_state(&f, "fam_rb")
	testing.expect_value(t, e + r, 0)
	testing.expect_value(t, pending_until_of(&f, "brg_rb"), "2026-10-16T15:05:00Z")
}

@(test)
test_enroll_commit_attach_swaps_credentials_atomically :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_att", "")
	seed_family(t, &f, "brg_att", "fam_old", RUNTIME_SCOPE)
	seed_family(t, &f, "brg_att", "fam_new", ENROLL_SCOPE)

	outcome, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_att", "fam_new", ENROLL_SCOPE, RUNTIME_SCOPE, true, NOW)
	testing.expect(t, ok, "commit ran")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Committed)
	_, new_rt, _ := family_state(&f, "fam_new")
	_, old_rt, old_rev := family_state(&f, "fam_old")
	testing.expect_value(t, new_rt, 2)
	testing.expect_value(t, old_rt, 0)
	testing.expect_value(t, old_rev, 2)
}

@(test)
test_enroll_commit_failure_in_the_swap_rolls_back_the_promote_new_bridge :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_fail", "2026-10-16T15:05:00Z")
	seed_family(t, &f, "brg_fail", "fam_fail", ENROLL_SCOPE)
	testing.expect(t, exec(&f.conn, "CREATE TRIGGER ea_inject BEFORE UPDATE OF enrollment_pending_until ON bridges BEGIN SELECT RAISE(ABORT, 'injected'); END;"), "trigger installed")

	_, ok, err := iface.bridge_commit_enrollment(&f.repo, "brg_fail", "fam_fail", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	testing.expect(t, !ok, "the injected failure is reported")
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	// The promote ran before the failing statement; the transaction must undo it.
	e, r, _ := family_state(&f, "fam_fail")
	testing.expect_value(t, e, 2)
	testing.expect_value(t, r, 0)
	testing.expect_value(t, pending_until_of(&f, "brg_fail"), "2026-10-16T15:05:00Z")

	// And the connection is usable again: no transaction was left open.
	testing.expect(t, exec(&f.conn, "DROP TRIGGER ea_inject;"), "trigger dropped")
	outcome, retry_ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_fail", "fam_fail", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	testing.expect(t, retry_ok, "a retry after the failure commits")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Committed)
}

@(test)
test_enroll_commit_failure_in_the_swap_rolls_back_the_promote_attach :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_af", "")
	seed_family(t, &f, "brg_af", "fam_old", RUNTIME_SCOPE)
	seed_family(t, &f, "brg_af", "fam_new", ENROLL_SCOPE)
	testing.expect(t, exec(&f.conn, "CREATE TRIGGER ea_inject BEFORE UPDATE OF revoked_at ON bridge_tokens BEGIN SELECT RAISE(ABORT, 'injected'); END;"), "trigger installed")

	_, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_af", "fam_new", ENROLL_SCOPE, RUNTIME_SCOPE, true, NOW)
	testing.expect(t, !ok, "the injected failure is reported")
	// Neither half happened: the new family is still pending, the old one still live.
	new_e, new_rt, _ := family_state(&f, "fam_new")
	_, old_rt, old_rev := family_state(&f, "fam_old")
	testing.expect_value(t, new_e, 2)
	testing.expect_value(t, new_rt, 0)
	testing.expect_value(t, old_rt, 2)
	testing.expect_value(t, old_rev, 0)
}

// ===== Isolation and concurrency on the dedicated connection =====
//
// Production wiring: one shared request connection plus the enrollment commit's own
// (Bridge_Enroll_Commit_Conn), on a FILE database — a second connection cannot open
// an in-memory one.

File_Fixture :: struct {
	path:   string,
	main:   Conn,
	commit: Bridge_Enroll_Commit_Conn,
	impl:   Bridge_Repo_SQLite,
	repo:   iface.Bridge_Repository,
}

file_fixture_open :: proc(t: ^testing.T, f: ^File_Fixture, tag: string) -> bool {
	conn, path, mig_ok := tmpl_clone_migrated_into_file(t, tag)
	f.path = fmt.aprintf("%s", path)
	if !mig_ok {
		tmpl_remove_db(f.path)
		return false
	}
	f.main = conn
	testing.expect(t, exec(&f.main, "PRAGMA busy_timeout = 5000;"), "busy_timeout on the request connection, as wiring sets it")
	c_ok, _ := open_bridge_enroll_commit_conn(&f.commit, f.path)
	testing.expect(t, c_ok, "commit connection opens")
	f.impl = Bridge_Repo_SQLite{conn = &f.main, commit = &f.commit}
	f.repo = new_bridge_repository(&f.impl, &f.main)
	f.impl.commit = &f.commit
	return mig_ok && c_ok
}

file_fixture_close :: proc(f: ^File_Fixture) {
	close(&f.commit.conn)
	close(&f.main)
	tmpl_remove_db(f.path)
	delete(f.path)
}

// as_commit_fixture lets the seed helpers above (which take a Commit_Fixture) seed
// through the request connection.
seed_on :: proc(t: ^testing.T, f: ^File_Fixture, bridge_id, family_id, scope, pending_until: string) {
	cf := Commit_Fixture{repo = f.repo}
	if pending_until != "-" do seed_bridge(t, &cf, bridge_id, pending_until)
	seed_family(t, &cf, bridge_id, family_id, scope)
}

state_on :: proc(f: ^File_Fixture, family_id: string) -> (live_enroll, live_runtime, revoked: int) {
	cf := Commit_Fixture{repo = f.repo}
	return family_state(&cf, family_id)
}

// --- an unrelated write during an enrollment transaction is not part of it ---

Unrelated_Writer :: struct {
	repo: ^iface.Bridge_Repository,
	ok:   bool,
	err:  string,
}

g_unrelated: ^Unrelated_Writer
g_unrelated_thread: ^thread.Thread

unrelated_write :: proc(w: ^Unrelated_Writer) {
	_, ok, err := iface.bridge_save_bridge(w.repo, domain.Bridge{
		bridge_id = "brg_unrelated", owner_user_id = domain.User_ID("someone_else"), label = "u",
		capabilities_json = "{}", status = .Offline, created_at = NOW, updated_at = NOW,
	})
	w.ok = ok
	w.err = err.message
}

// The commit hook is one global and the tests run in parallel, so every test installs
// this same dispatcher and never clears it; each case acts only on its own bridge_id.
commit_hook_dispatch :: proc(bridge_id: string) {
	switch bridge_id {
	case "brg_iso":
		hook_start_unrelated_write()
	case "brg_race_rb":
		hook_start_rollback_revoke()
	}
}

// Runs INSIDE the enrollment transaction, between promote and swap: start a request
// on the shared connection, and give it time to reach SQLite.
hook_start_unrelated_write :: proc() {
	g_unrelated_thread = thread.create_and_start_with_poly_data(g_unrelated, unrelated_write)
	time.sleep(150 * time.Millisecond)
}

@(test)
test_enroll_commit_is_isolated_from_a_concurrent_unrelated_write :: proc(t: ^testing.T) {
	f: File_Fixture
	if !file_fixture_open(t, &f, "iso") do return
	defer file_fixture_close(&f)
	seed_on(t, &f, "brg_iso", "fam_iso", ENROLL_SCOPE, "2026-10-16T15:05:00Z")
	// Make the enrollment transaction fail AFTER its promote, so it rolls back.
	testing.expect(t, exec(&f.main, "CREATE TRIGGER ea_inject BEFORE UPDATE OF enrollment_pending_until ON bridges BEGIN SELECT RAISE(ABORT, 'injected'); END;"), "trigger installed")

	w := Unrelated_Writer{repo = &f.repo}
	g_unrelated = &w
	bridge_enroll_commit_test_hook = commit_hook_dispatch
	_, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_iso", "fam_iso", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	thread.join(g_unrelated_thread)
	thread.destroy(g_unrelated_thread)

	testing.expect(t, !ok, "the injected failure rolls the enrollment back")
	e, r, _ := state_on(&f, "fam_iso")
	testing.expect_value(t, e, 2)
	testing.expect_value(t, r, 0)
	// On a shared connection the unrelated write would have run inside the
	// enrollment transaction and been rolled back with it.
	testing.expectf(t, w.ok, "the unrelated write succeeded (%s)", w.err)
	u, u_ok, _ := iface.bridge_get_bridge(&f.repo, "brg_unrelated")
	defer domain.bridge_destroy(&u)
	testing.expect(t, u_ok, "the unrelated write is durable, not rolled back with the enrollment")
}

// --- simultaneous commits do not corrupt each other ---

Commit_Racer :: struct {
	repo:      ^iface.Bridge_Repository,
	bridge_id: string,
	family_id: string,
	outcome:   iface.Enrollment_Commit_Outcome,
	ok:        bool,
}

commit_racer :: proc(r: ^Commit_Racer) {
	r.outcome, r.ok, _ = iface.bridge_commit_enrollment(r.repo, r.bridge_id, r.family_id, ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
}

@(test)
test_enroll_commit_simultaneous_commits_serialize :: proc(t: ^testing.T) {
	f: File_Fixture
	if !file_fixture_open(t, &f, "race") do return
	defer file_fixture_close(&f)
	seed_on(t, &f, "brg_r1", "fam_r1", ENROLL_SCOPE, "2026-10-16T15:05:00Z")
	seed_on(t, &f, "brg_r2", "fam_r2", ENROLL_SCOPE, "2026-10-16T15:05:00Z")

	// Four racers: two on the SAME family (one must win, one must see it committed),
	// and two on different bridges (both must commit).
	racers := [4]Commit_Racer{
		{repo = &f.repo, bridge_id = "brg_r1", family_id = "fam_r1"},
		{repo = &f.repo, bridge_id = "brg_r1", family_id = "fam_r1"},
		{repo = &f.repo, bridge_id = "brg_r2", family_id = "fam_r2"},
		{repo = &f.repo, bridge_id = "brg_r2", family_id = "fam_r2"},
	}
	threads: [4]^thread.Thread
	for i in 0..<4 do threads[i] = thread.create_and_start_with_poly_data(&racers[i], commit_racer)
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for pair in ([2][2]int{{0, 1}, {2, 3}}) {
		a, b := racers[pair[0]], racers[pair[1]]
		testing.expect(t, a.ok && b.ok, "every racer's transaction completed without a storage error")
		won := int(a.outcome == .Committed) + int(b.outcome == .Committed)
		dup := int(a.outcome == .Already_Committed) + int(b.outcome == .Already_Committed)
		testing.expectf(t, won == 1 && dup == 1, "exactly one winner and one duplicate per family, got %v / %v", a.outcome, b.outcome)
	}
	for fam in ([2]string{"fam_r1", "fam_r2"}) {
		e, r, rev := state_on(&f, fam)
		testing.expect_value(t, e, 0)
		testing.expect_value(t, r, 2)
		testing.expect_value(t, rev, 0)
	}
	// The request connection is not stuck in a transaction afterwards.
	testing.expect(t, exec(&f.main, "BEGIN; COMMIT;"), "the request connection has no transaction left open")
}

// --- the rollback's revoke cannot kill a family the commit just promoted ---

@(test)
test_scoped_family_revoke_only_matches_the_given_scope :: proc(t: ^testing.T) {
	f: Commit_Fixture
	if !fixture_open(t, &f) do return
	defer close(&f.conn)
	seed_bridge(t, &f, "brg_scoped", "")
	seed_family(t, &f, "brg_scoped", "fam_scoped_rt", RUNTIME_SCOPE)
	seed_family(t, &f, "brg_scoped", "fam_scoped_en", ENROLL_SCOPE)

	n, ok, _ := iface.bridge_revoke_token_family_in_scope(&f.repo, "fam_scoped_rt", ENROLL_SCOPE, NOW)
	testing.expect(t, ok, "scoped revoke runs")
	testing.expect_value(t, n, 0)
	_, r, rv := family_state(&f, "fam_scoped_rt")
	testing.expect_value(t, r, 2)
	testing.expect_value(t, rv, 0)

	n, ok, _ = iface.bridge_revoke_token_family_in_scope(&f.repo, "fam_scoped_en", ENROLL_SCOPE, NOW)
	testing.expect(t, ok, "scoped revoke runs")
	testing.expect_value(t, n, 2)
	e, _, rv2 := family_state(&f, "fam_scoped_en")
	testing.expect_value(t, e, 0)
	testing.expect_value(t, rv2, 2)
}

Rollback_Revoker :: struct {
	repo:    ^iface.Bridge_Repository,
	changed: int,
	ok:      bool,
}

g_rollback: ^Rollback_Revoker
g_rollback_thread: ^thread.Thread

rollback_revoke :: proc(r: ^Rollback_Revoker) {
	r.changed, r.ok, _ = iface.bridge_revoke_token_family_in_scope(r.repo, "fam_race_rb", ENROLL_SCOPE, NOW)
}

// Runs INSIDE the commit transaction, after the promote: a rollback (cancel or the
// reaper) arrives on the request connection. Its revoke blocks on the write lock
// until the commit finishes, then must find nothing left in the enroll scope.
hook_start_rollback_revoke :: proc() {
	g_rollback_thread = thread.create_and_start_with_poly_data(g_rollback, rollback_revoke)
	time.sleep(150 * time.Millisecond)
}

@(test)
test_enroll_rollback_racing_a_commit_leaves_the_committed_family_live :: proc(t: ^testing.T) {
	f: File_Fixture
	if !file_fixture_open(t, &f, "race_rb") do return
	defer file_fixture_close(&f)
	seed_on(t, &f, "brg_race_rb", "fam_race_rb", ENROLL_SCOPE, "2026-10-16T15:05:00Z")

	rb := Rollback_Revoker{repo = &f.repo}
	g_rollback = &rb
	bridge_enroll_commit_test_hook = commit_hook_dispatch
	outcome, ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_race_rb", "fam_race_rb", ENROLL_SCOPE, RUNTIME_SCOPE, false, NOW)
	thread.join(g_rollback_thread)
	thread.destroy(g_rollback_thread)

	testing.expect(t, ok, "the commit succeeds")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Committed)
	testing.expect(t, rb.ok, "the racing revoke ran (after the commit released the lock)")
	testing.expect_value(t, rb.changed, 0)
	_, r, rv := state_on(&f, "fam_race_rb")
	testing.expect_value(t, r, 2)
	testing.expect_value(t, rv, 0)
}
