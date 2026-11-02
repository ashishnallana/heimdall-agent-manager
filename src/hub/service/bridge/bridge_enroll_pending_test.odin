// REQ-EA-2/8: once the enrollment transaction commits, the verdict is COMMITTED —
// even if the later, descriptive row save fails. These tests inject that failure
// (a repository whose save_bridge refuses) and assert the hub neither reports a
// rollback nor leaves an enrolled-without-credential state.
package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
pending_test_counter: int

// REQ-ENROLL-PENDING: a replacement has no pending row, but must be listed
// exactly once and cancellable without disturbing the old runtime credential.
@(test)
test_pending_list_includes_replacement_and_cancel_preserves_existing_bridge :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "visible_attach")
	defer pending_fixture_close(f)
	first, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-old", false))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(first.bridge.bridge_id, context.temp_allocator)
	old_family := strings.clone(first.family_id, context.temp_allocator)
	attach, attached, attach_err := enroll_bridge_from_device_grant(&f.svc, enroll_input(bridge_id, "", true))
	testing.expect(t, attached, attach_err.message)
	new_family := strings.clone(attach.family_id, context.temp_allocator)
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = "ea-owner"}
	rows, list_err := list_pending_enrollments(&f.svc, auth)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].bridge_id, bridge_id)
		testing.expect(t, !domain.bridge_is_pending(rows[0]), "existing bridge remains enrolled")
	}
	for &row in rows do domain.bridge_destroy(&row)
	delete(rows)
	others, other_err := list_pending_enrollments(&f.svc, contracts.Auth_Context{kind = .Internal_User, user_id = "someone-else"})
	testing.expect_value(t, other_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(others), 0)
	for &row in others do domain.bridge_destroy(&row)
	delete(others)
	rolled, removed, cancel_err := cancel_pending_enrollment(&f.svc, bridge_id)
	testing.expect_value(t, cancel_err.code, domain.Error_Code.None)
	testing.expect(t, rolled && !removed, "only the replacement is cancelled")
	testing.expect_value(t, live_scope_count(f, old_family, BRIDGE_TOKEN_SCOPE), 2)
	testing.expect_value(t, live_scope_count(f, new_family, BRIDGE_ENROLL_TOKEN_SCOPE), 0)
	after, after_err := list_pending_enrollments(&f.svc, auth)
	testing.expect_value(t, after_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(after), 0)
	for &row in after do domain.bridge_destroy(&row)
	delete(after)
}

@(test)
test_pending_list_deduplicates_new_bridge_token_pair_and_reports_read_failure :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "visible_new")
	defer pending_fixture_close(f)
	_, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	auth := contracts.Auth_Context{kind = .Internal_User, user_id = "ea-owner"}
	rows, list_err := list_pending_enrollments(&f.svc, auth)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	for &row in rows do domain.bridge_destroy(&row)
	delete(rows)
	broken := f.repo
	broken.list_live_tokens_by_scope = failing_list_scope
	f.svc.repo = &broken
	failed, failed_err := list_pending_enrollments(&f.svc, auth)
	testing.expect(t, failed_err.code != .None, "a failed read is not an empty list")
	testing.expect_value(t, len(failed), 0)
}

@(private = "file")
Pending_Fixture :: struct {
	db_path: string,
	conn:    sqlite.Conn,
	impl:    sqlite.Bridge_Repo_SQLite,
	repo:    iface.Bridge_Repository,
	broken:  iface.Bridge_Repository, // repo, except save_bridge always fails
	clock:   platform.Clock,
	ids:     platform.ID_Generator,
	svc:     Bridge_Service,
	closed:  [dynamic]string,
}

@(private = "file")
pending_closer :: proc(ctx: rawptr, bridge_id: string) -> bool {
	f := (^Pending_Fixture)(ctx)
	append(&f.closed, strings.clone(bridge_id))
	return true
}

@(private = "file")
failing_save :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "injected: row save failed")
}

@(private = "file")
failing_list_family :: proc(ctx: rawptr, family_id: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "injected: family read failed")
}

@(private = "file")
failing_list_scope :: proc(ctx: rawptr, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	return nil, domain.domain_error(.Internal_Error, "injected: scope read failed")
}

@(private = "file")
pending_fixture_open :: proc(t: ^testing.T, tag: string) -> ^Pending_Fixture {
	f := new(Pending_Fixture)
	seq := sync.atomic_add(&pending_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_enroll_pending_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)
	conn, ok, _ := sqlite.open(f.db_path)
	testing.expect(t, ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.repo = sqlite.new_bridge_repository(&f.impl, &f.conn)
	f.broken = f.repo
	f.broken.save_bridge = failing_save
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_bridge_service(&f.repo, &f.clock, &f.ids)
	f.closed = make([dynamic]string)
	with_connection_closer(&f.svc, Bridge_Connection_Closer{ctx = rawptr(f), close_bridge_connection = pending_closer})
	return f
}

@(private = "file")
pending_fixture_close :: proc(f: ^Pending_Fixture) {
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	for s in f.closed do delete(s)
	delete(f.closed)
	free(f)
}

@(private = "file")
enroll_input :: proc(target, label: string, pending: bool) -> Device_Enroll_Input {
	return Device_Enroll_Input{
		owner_user_id = "ea-owner",
		bridge_public_key = "04aabbccdd",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = "ea-host",
		machine_os = "linux",
		target_bridge_id = target,
		new_bridge_label = label,
		pending = pending,
	}
}

@(private = "file")
live_scope_count :: proc(f: ^Pending_Fixture, family_id, scope: string) -> int {
	tokens, _ := iface.bridge_list_tokens_by_family(&f.repo, family_id)
	defer free_bridge_tokens(tokens)
	n := 0
	for tok in tokens do if tok.revoked_at == "" && tok.scope == scope do n += 1
	return n
}

@(test)
test_commit_stays_committed_when_the_row_save_fails_new_bridge :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "save_new")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	family := strings.clone(enrolled.family_id, context.temp_allocator)

	f.svc.repo = &f.broken // the descriptive save after the transaction will fail
	committed, commit_ok, commit_err := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = family})
	defer domain.bridge_destroy(&committed)
	f.svc.repo = &f.repo
	testing.expectf(t, commit_ok, "a committed transaction must be reported committed, got %v", commit_err.message)

	testing.expect_value(t, live_scope_count(f, family, BRIDGE_TOKEN_SCOPE), 2)
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_ENROLL_TOKEN_SCOPE), 0)
	row, row_ok, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	defer domain.bridge_destroy(&row)
	testing.expect(t, row_ok, "the row survives: it is enrolled, not rolled back")
	testing.expect_value(t, row.enrollment_pending_until, "")
	// And the sweep, which would delete a still-pending row, finds nothing.
	rolled := sweep_expired_enrollments(&f.svc)
	defer rolled_back_enrollments_destroy(rolled)
	testing.expect_value(t, len(rolled), 0)
}

@(test)
test_commit_stays_committed_when_the_row_save_fails_attach :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "save_attach")
	defer pending_fixture_close(f)
	first, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-old", false))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(first.bridge.bridge_id, context.temp_allocator)
	old_family := strings.clone(first.family_id, context.temp_allocator)
	attach, attach_ok, attach_err := enroll_bridge_from_device_grant(&f.svc, enroll_input(bridge_id, "", true))
	testing.expect(t, attach_ok, attach_err.message)
	new_family := strings.clone(attach.family_id, context.temp_allocator)
	testing.expect(t, new_family != old_family, "an attach mints a NEW family")

	f.svc.repo = &f.broken
	committed, commit_ok, commit_err := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = new_family})
	defer domain.bridge_destroy(&committed)
	f.svc.repo = &f.repo
	testing.expectf(t, commit_ok, "a committed attach must be reported committed, got %v", commit_err.message)

	testing.expect_value(t, live_scope_count(f, new_family, BRIDGE_TOKEN_SCOPE), 2)
	testing.expect_value(t, live_scope_count(f, old_family, BRIDGE_TOKEN_SCOPE), 0)
	// The old device's socket is retired even though the row save failed.
	retired := false
	for id in f.closed do if id == bridge_id do retired = true
	testing.expect(t, retired, "the old device's connection is closed")
}

@(test)
test_duplicate_commit_is_idempotent_at_the_service :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "dup")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-dup", true))
	testing.expect(t, ok, err.message)
	in_ := Pending_Commit_Input{bridge_id = enrolled.bridge.bridge_id, family_id = enrolled.family_id}
	a, a_ok, _ := commit_pending_enrollment(&f.svc, in_)
	defer domain.bridge_destroy(&a)
	testing.expect(t, a_ok, "first commit")
	b, b_ok, b_err := commit_pending_enrollment(&f.svc, in_)
	defer domain.bridge_destroy(&b)
	testing.expectf(t, b_ok, "a duplicate commit is a success, got %v", b_err.message)
	testing.expect_value(t, live_scope_count(f, enrolled.family_id, BRIDGE_TOKEN_SCOPE), 2)
}

// --- the rollback's verdict: a commit that won the race is NOT reported rolled back ---
//
// Cancel and the reaper gate committed:false, the socket close and the 'rolled back'
// event on this verdict. Calling rollback after the commit is exactly the interleaving
// where the commit takes the write lock between the caller's read and its revoke.

@(test)
test_rollback_after_a_commit_reports_committed_new_bridge :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "rb_after_new")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	family := strings.clone(enrolled.family_id, context.temp_allocator)
	committed, commit_ok, commit_err := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = family})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, commit_ok, commit_err.message)

	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, bridge_id, family)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, !rolled_back, "a committed enrollment must not be reported rolled back")
	testing.expect(t, !removed, "the committed row is kept")
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_TOKEN_SCOPE), 2)
	row, row_ok, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	defer domain.bridge_destroy(&row)
	testing.expect(t, row_ok, "the row survives")
}

@(test)
test_rollback_after_a_commit_reports_committed_attach :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "rb_after_attach")
	defer pending_fixture_close(f)
	first, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-old", false))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(first.bridge.bridge_id, context.temp_allocator)
	attach, attach_ok, attach_err := enroll_bridge_from_device_grant(&f.svc, enroll_input(bridge_id, "", true))
	testing.expect(t, attach_ok, attach_err.message)
	new_family := strings.clone(attach.family_id, context.temp_allocator)
	committed, commit_ok, commit_err := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = new_family})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, commit_ok, commit_err.message)

	rolled_back, _, rb_err := rollback_pending_enrollment(&f.svc, bridge_id, new_family)
	testing.expect_value(t, rb_err.code, domain.Error_Code.None)
	testing.expect(t, !rolled_back, "a committed attach must not be reported rolled back")
	testing.expect_value(t, live_scope_count(f, new_family, BRIDGE_TOKEN_SCOPE), 2)
}

@(test)
test_rollback_before_a_commit_rolls_back_and_is_idempotent :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "rb_before")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	family := strings.clone(enrolled.family_id, context.temp_allocator)

	rolled_back, removed, _ := rollback_pending_enrollment(&f.svc, bridge_id, family)
	testing.expect(t, rolled_back, "a pending enrollment rolls back")
	testing.expect(t, removed, "a new bridge's pending row is deleted")
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_ENROLL_TOKEN_SCOPE), 0)

	again, removed_again, _ := rollback_pending_enrollment(&f.svc, bridge_id, family)
	testing.expect(t, again, "rolling back twice still reads as rolled back")
	testing.expect(t, !removed_again, "nothing left to delete")

	// The commit that loses the race finds nothing to promote.
	committed, commit_ok, _ := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = family})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, !commit_ok, "a rolled-back family cannot be committed")
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_TOKEN_SCOPE), 0)
}

// --- a failed read never produces a verdict (review 3) ---

@(test)
test_rollback_verdict_read_failure_is_an_error_not_rolled_back :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "rb_read_fail")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	family := strings.clone(enrolled.family_id, context.temp_allocator)
	committed, commit_ok, commit_err := commit_pending_enrollment(&f.svc, Pending_Commit_Input{bridge_id = bridge_id, family_id = family})
	defer domain.bridge_destroy(&committed)
	testing.expect(t, commit_ok, commit_err.message)

	// The commit won; now the "is it committed?" read fails.
	broken := f.repo
	broken.list_tokens_by_family = failing_list_family
	f.svc.repo = &broken
	rolled_back, removed, rb_err := rollback_pending_enrollment(&f.svc, bridge_id, family)
	f.svc.repo = &f.repo
	testing.expect(t, rb_err.code != .None, "a failed verdict read must surface as an error")
	testing.expect(t, !rolled_back, "a committed family is never reported rolled back")
	testing.expect(t, !removed, "nothing deleted")
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_TOKEN_SCOPE), 2)
}

@(test)
test_cancel_family_lookup_failure_does_nothing_new_bridge :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "cancel_lookup_new")
	defer pending_fixture_close(f)
	enrolled, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-new", true))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(enrolled.bridge.bridge_id, context.temp_allocator)
	family := strings.clone(enrolled.family_id, context.temp_allocator)

	broken := f.repo
	broken.list_live_tokens_by_scope = failing_list_scope
	f.svc.repo = &broken
	rolled_back, removed, cancel_err := cancel_pending_enrollment(&f.svc, bridge_id)
	f.svc.repo = &f.repo
	testing.expect(t, cancel_err.code != .None, "a failed family lookup must surface as an error")
	testing.expect(t, !rolled_back && !removed, "no verdict and no delete")
	row, row_ok, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	defer domain.bridge_destroy(&row)
	testing.expect(t, row_ok, "the pending row is not deleted out from under its live enroll token")
	testing.expect(t, row.enrollment_pending_until != "", "still pending")
	testing.expect_value(t, live_scope_count(f, family, BRIDGE_ENROLL_TOKEN_SCOPE), 2)
}

@(test)
test_cancel_family_lookup_failure_does_nothing_attach :: proc(t: ^testing.T) {
	f := pending_fixture_open(t, "cancel_lookup_attach")
	defer pending_fixture_close(f)
	first, ok, err := enroll_bridge_from_device_grant(&f.svc, enroll_input("", "ea-old", false))
	testing.expect(t, ok, err.message)
	bridge_id := strings.clone(first.bridge.bridge_id, context.temp_allocator)
	old_family := strings.clone(first.family_id, context.temp_allocator)
	attach, attach_ok, attach_err := enroll_bridge_from_device_grant(&f.svc, enroll_input(bridge_id, "", true))
	testing.expect(t, attach_ok, attach_err.message)
	new_family := strings.clone(attach.family_id, context.temp_allocator)

	broken := f.repo
	broken.list_live_tokens_by_scope = failing_list_scope
	f.svc.repo = &broken
	rolled_back, _, cancel_err := cancel_pending_enrollment(&f.svc, bridge_id)
	f.svc.repo = &f.repo
	testing.expect(t, cancel_err.code != .None, "a failed family lookup must surface as an error")
	testing.expect(t, !rolled_back, "no verdict: a still-pending attach is neither rolled back nor committed")
	testing.expect_value(t, live_scope_count(f, new_family, BRIDGE_ENROLL_TOKEN_SCOPE), 2)
	testing.expect_value(t, live_scope_count(f, old_family, BRIDGE_TOKEN_SCOPE), 2)

	// And with the read healthy again, the same cancel does roll the attach back.
	again, _, again_err := cancel_pending_enrollment(&f.svc, bridge_id)
	testing.expect_value(t, again_err.code, domain.Error_Code.None)
	testing.expect(t, again, "a healthy cancel rolls the attach back")
	testing.expect_value(t, live_scope_count(f, new_family, BRIDGE_ENROLL_TOKEN_SCOPE), 0)
	testing.expect_value(t, live_scope_count(f, old_family, BRIDGE_TOKEN_SCOPE), 2)
}
