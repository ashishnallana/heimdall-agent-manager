#+private file
// REQ-EA-2/8: the enrollment commit is ONE transaction. The failure-path tests make
// the second statement fail for real — a SQL trigger that RAISE(ABORT)s — and assert
// the first one was rolled back with it, not merely that the proc reported an error.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import "core:fmt"
import "core:testing"

ENROLL_SCOPE :: "bridge:enroll"
RUNTIME_SCOPE :: "bridge:runtime"
NOW :: "2026-10-16T15:00:00Z"

Commit_Fixture :: struct {
	conn:      Conn,
	repo_impl: Bridge_Repo_SQLite,
	repo:      iface.Bridge_Repository,
}

fixture_open :: proc(t: ^testing.T, f: ^Commit_Fixture) -> bool {
	conn, ok, _ := open(":memory:")
	if !ok do return false
	f.conn = conn
	mig_ok, _ := run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
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
