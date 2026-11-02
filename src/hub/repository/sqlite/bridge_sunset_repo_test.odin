#+private file
// REQ-3: "register new and sunset one" is ONE admission transaction, and its durable
// receipt (migration 178) is consumed by THE pending-row rollback. These tests
// assert on the rows themselves (bridge status, every token's revoked_at), not on the
// returned error alone: a refusal or a failed COMMIT must leave the sunset bridge and
// its credentials exactly as they were, and a restore must revive exactly the
// credentials the sunset revoked and nothing else.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import "core:fmt"
import "core:testing"

SUNSET_OWNER :: "user_sunset_owner"
SUNSET_OTHER :: "user_sunset_other"
SUNSET_SEED_AT :: "2026-10-30T09:00:00Z"
SUNSET_AT :: "2026-10-31T12:00:00Z"
SUNSET_LATER :: "2026-10-31T12:10:00Z"
SUNSET_PENDING_UNTIL :: "2099-01-01T00:00:00Z"

Sunset_Fixture :: struct {
	conn:      Conn,
	repo_impl: Bridge_Repo_SQLite,
	repo:      iface.Bridge_Repository,
}

sunset_open :: proc(t: ^testing.T, f: ^Sunset_Fixture) -> bool {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return false
	f.conn = conn
	f.repo_impl = Bridge_Repo_SQLite{conn = &f.conn}
	f.repo = new_bridge_repository(&f.repo_impl, &f.conn)
	return true
}

sunset_seed_bridge :: proc(t: ^testing.T, f: ^Sunset_Fixture, bridge_id, owner: string, pending_until := "", revoked_at := "") {
	_, ok, _ := iface.bridge_save_bridge(&f.repo, domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = domain.User_ID(owner),
		label = bridge_id,
		machine_hostname = "box",
		capabilities_json = "{}",
		status = .Revoked if revoked_at != "" else .Online,
		created_at = SUNSET_SEED_AT,
		updated_at = SUNSET_SEED_AT,
		revoked_at = revoked_at,
		enrollment_pending_until = pending_until,
	})
	testing.expectf(t, ok, "seeded bridge %s", bridge_id)
}

sunset_seed_token :: proc(t: ^testing.T, f: ^Sunset_Fixture, bridge_id, token_id: string, revoked_at := "") {
	_, ok, _ := iface.bridge_save_token(&f.repo, domain.Bridge_Token{
		token_id = token_id,
		bridge_id = bridge_id,
		kind = .Access,
		token_hash = fmt.tprintf("hash_%s", token_id),
		family_id = fmt.tprintf("fam_%s", token_id),
		generation = 1,
		scope = "bridge:runtime",
		issued_at = SUNSET_SEED_AT,
		expires_at = "2099-01-01T00:00:00Z",
		family_expires_at = "2099-01-01T00:00:00Z",
		revoked_at = revoked_at,
	})
	testing.expectf(t, ok, "seeded token %s", token_id)
}

// An enrolled, online bridge with two live credentials and one that theft detection
// revoked earlier AT THE SAME INSTANT the sunset will use — a restore that matched
// tokens by revoked_at instead of by the receipt's ids would wrongly revive it.
sunset_seed_victim :: proc(t: ^testing.T, f: ^Sunset_Fixture, bridge_id: string) {
	sunset_seed_bridge(t, f, bridge_id, SUNSET_OWNER)
	sunset_seed_token(t, f, bridge_id, fmt.tprintf("%s_tok_a", bridge_id))
	sunset_seed_token(t, f, bridge_id, fmt.tprintf("%s_tok_b", bridge_id))
	sunset_seed_token(t, f, bridge_id, fmt.tprintf("%s_tok_stolen", bridge_id), SUNSET_AT)
}

replacement :: proc(bridge_id: string, owner := SUNSET_OWNER, pending := true) -> domain.Bridge {
	return domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = domain.User_ID(owner),
		label = bridge_id,
		machine_hostname = "newbox",
		capabilities_json = "{}",
		status = .Offline,
		created_at = SUNSET_AT,
		updated_at = SUNSET_AT,
		enrollment_pending_until = SUNSET_PENDING_UNTIL if pending else "",
	}
}

Bridge_Snapshot :: struct {
	found:      bool,
	status:     domain.Bridge_Status,
	revoked_at: string,
	pending:    string,
}

snapshot :: proc(f: ^Sunset_Fixture, bridge_id: string) -> Bridge_Snapshot {
	b, found, _ := iface.bridge_get_bridge(&f.repo, bridge_id)
	if !found do return {}
	defer domain.bridge_destroy(&b)
	return Bridge_Snapshot{
		found = true,
		status = b.status,
		revoked_at = fmt.tprintf("%s", b.revoked_at),
		pending = fmt.tprintf("%s", b.enrollment_pending_until),
	}
}

token_revoked_at :: proc(f: ^Sunset_Fixture, token_id: string) -> string {
	tok, found, _ := iface.bridge_get_token(&f.repo, token_id)
	if !found do return "<missing>"
	defer domain.bridge_token_destroy(&tok)
	return fmt.tprintf("%s", tok.revoked_at)
}

owner_count :: proc(f: ^Sunset_Fixture, owner := SUNSET_OWNER) -> int {
	n, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID(owner))
	return n
}

// expect_victim_untouched: the bridge is still enrolled, online, and both live tokens
// are still live — i.e. the refused/failed transaction wrote nothing to it.
expect_victim_untouched :: proc(t: ^testing.T, f: ^Sunset_Fixture, bridge_id: string, loc := #caller_location) {
	s := snapshot(f, bridge_id)
	testing.expect(t, s.found, "sunset bridge still exists", loc = loc)
	testing.expect_value(t, s.status, domain.Bridge_Status.Online, loc = loc)
	testing.expect_value(t, s.revoked_at, "", loc = loc)
	testing.expect_value(t, token_revoked_at(f, fmt.tprintf("%s_tok_a", bridge_id)), "", loc = loc)
	testing.expect_value(t, token_revoked_at(f, fmt.tprintf("%s_tok_b", bridge_id)), "", loc = loc)
}

// Receipt_Snapshot is the durable receipt keyed by a replacement (migration 178);
// sunset_id is "" when there is no receipt row. tokens are sorted.
Receipt_Snapshot :: struct {
	sunset_id:  string,
	revoked_at: string,
	tokens:     [dynamic]string,
}

receipt_of :: proc(f: ^Sunset_Fixture, replacement_id: string) -> Receipt_Snapshot {
	out := Receipt_Snapshot{tokens = make([dynamic]string, context.temp_allocator)}
	{
		stmt: sqlite3_stmt
		q := "SELECT sunset_bridge_id, revoked_at FROM bridge_sunset_receipts WHERE replacement_bridge_id = ?;"
		if sqlite3_prepare_v2(f.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return out
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, replacement_id)
		if sqlite3_step(stmt) == SQLITE_ROW {
			out.sunset_id = fmt.tprintf("%s", column_text_unowned(stmt, 0))
			out.revoked_at = fmt.tprintf("%s", column_text_unowned(stmt, 1))
		}
	}
	stmt: sqlite3_stmt
	q := "SELECT token_id FROM bridge_sunset_receipt_tokens WHERE replacement_bridge_id = ? ORDER BY token_id;"
	if sqlite3_prepare_v2(f.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return out
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, replacement_id)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out.tokens, fmt.tprintf("%s", column_text_unowned(stmt, 0)))
	return out
}

expect_no_receipt :: proc(t: ^testing.T, f: ^Sunset_Fixture, replacement_id: string, loc := #caller_location) {
	r := receipt_of(f, replacement_id)
	testing.expect_value(t, r.sunset_id, "", loc = loc)
	testing.expect_value(t, len(r.tokens), 0, loc = loc)
}

sunset :: proc(bridge_id: string) -> iface.Bridge_Sunset {
	return iface.Bridge_Sunset{bridge_id = bridge_id, revoked_at = SUNSET_AT}
}

@(test)
test_sunset_on_full_plan_revokes_and_creates_in_one_transaction :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_sun_old")
	testing.expect_value(t, owner_count(&f), 1)

	// max_bridges = 1 and the plan is full: only the slot the sunset frees admits it.
	saved, ok, err := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_sun_new"), 1, sunset("brg_sun_old"))
	testing.expect(t, ok, "full plan admits the replacement when it sunsets a bridge")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, saved.bridge_id, "brg_sun_new")

	old := snapshot(&f, "brg_sun_old")
	testing.expect_value(t, old.status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, old.revoked_at, SUNSET_AT)
	testing.expect_value(t, token_revoked_at(&f, "brg_sun_old_tok_a"), SUNSET_AT)
	testing.expect_value(t, token_revoked_at(&f, "brg_sun_old_tok_b"), SUNSET_AT)
	testing.expect(t, snapshot(&f, "brg_sun_new").found, "replacement row inserted")
	testing.expect_value(t, owner_count(&f), 1)

	// The durable receipt, keyed by the pending replacement, names exactly the two
	// credentials this sunset revoked (not the one revoked earlier at the same time).
	receipt := receipt_of(&f, "brg_sun_new")
	testing.expect_value(t, receipt.sunset_id, "brg_sun_old")
	testing.expect_value(t, receipt.revoked_at, SUNSET_AT)
	testing.expect_value(t, len(receipt.tokens), 2)
	if len(receipt.tokens) == 2 {
		testing.expect_value(t, receipt.tokens[0], "brg_sun_old_tok_a")
		testing.expect_value(t, receipt.tokens[1], "brg_sun_old_tok_b")
	}
	testing.expect(t, exec(&f.conn, "BEGIN; COMMIT;"), "no transaction left open")
}

@(test)
test_sunset_also_runs_transactionally_on_an_unlimited_plan :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_unl_old")
	_, ok, _ := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_unl_new"), -1, sunset("brg_unl_old"))
	testing.expect(t, ok, "unlimited plan admits")
	testing.expect_value(t, snapshot(&f, "brg_unl_old").status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, len(receipt_of(&f, "brg_unl_new").tokens), 2)
}

@(test)
test_sunset_refuses_foreign_absent_revoked_and_pending_bridges_without_writing :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_ref_mine")
	sunset_seed_bridge(t, &f, "brg_ref_foreign", SUNSET_OTHER)
	sunset_seed_token(t, &f, "brg_ref_foreign", "brg_ref_foreign_tok")
	sunset_seed_bridge(t, &f, "brg_ref_revoked", SUNSET_OWNER, revoked_at = SUNSET_SEED_AT)
	sunset_seed_bridge(t, &f, "brg_ref_pending", SUNSET_OWNER, pending_until = SUNSET_PENDING_UNTIL)

	Case :: struct {
		sunset_id: string,
		code:      domain.Error_Code,
	}
	cases := [?]Case{
		// absent, foreign and already-revoked share one answer (no enumeration oracle)
		{"brg_ref_absent", .Not_Found},
		{"brg_ref_foreign", .Not_Found},
		{"brg_ref_revoked", .Not_Found},
		// the owner's own still-enrolling row is not a bridge yet
		{"brg_ref_pending", .Validation_Failed},
	}
	for c, i in cases {
		new_id := fmt.tprintf("brg_ref_new_%d", i)
		// An unlimited plan, so a refusal can only come from the sunset checks.
		_, ok, err := iface.bridge_create_limited_with_sunset(&f.repo, replacement(new_id), -1, sunset(c.sunset_id))
		testing.expectf(t, !ok, "sunset of %s refused", c.sunset_id)
		testing.expect_value(t, err.code, c.code)
		testing.expectf(t, !snapshot(&f, new_id).found, "no replacement inserted when sunsetting %s", c.sunset_id)
		expect_no_receipt(t, &f, new_id)
	}
	// Nothing was touched by any refusal.
	expect_victim_untouched(t, &f, "brg_ref_mine")
	foreign_row := snapshot(&f, "brg_ref_foreign")
	testing.expect_value(t, foreign_row.status, domain.Bridge_Status.Online)
	testing.expect_value(t, token_revoked_at(&f, "brg_ref_foreign_tok"), "")
	testing.expect_value(t, snapshot(&f, "brg_ref_revoked").revoked_at, SUNSET_SEED_AT)
	testing.expect_value(t, snapshot(&f, "brg_ref_pending").pending, SUNSET_PENDING_UNTIL)
	testing.expect(t, exec(&f.conn, "BEGIN; COMMIT;"), "no transaction left open")
}

@(test)
test_sunset_rolls_back_when_the_plan_is_still_full_after_it :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	// Three live bridges on a two-bridge plan (e.g. after a downgrade): retiring one
	// still leaves two, so the replacement is refused AND the sunset must not stick.
	sunset_seed_victim(t, &f, "brg_cap_old")
	sunset_seed_bridge(t, &f, "brg_cap_b", SUNSET_OWNER)
	sunset_seed_bridge(t, &f, "brg_cap_c", SUNSET_OWNER)
	_, ok, err := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_cap_new"), 2, sunset("brg_cap_old"))
	testing.expect(t, !ok, "plan still full after the sunset")
	testing.expect_value(t, err.code, domain.Error_Code.Plan_Limit_Reached)
	expect_victim_untouched(t, &f, "brg_cap_old")
	testing.expect(t, !snapshot(&f, "brg_cap_new").found, "no replacement inserted")
	testing.expect_value(t, owner_count(&f), 3)
	expect_no_receipt(t, &f, "brg_cap_new")
}

@(test)
test_sunset_rolls_back_when_the_replacement_insert_fails :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_dup_old")
	// The replacement INSERT fails for real (a trigger RAISE(ABORT)s) after the sunset
	// statements already ran inside the transaction.
	testing.expect(t, exec(&f.conn, "CREATE TRIGGER sunset_fail_insert BEFORE INSERT ON bridges WHEN NEW.bridge_id = 'brg_dup_new' BEGIN SELECT RAISE(ABORT, 'insert refused'); END;"), "trigger installed")
	_, ok, _ := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_dup_new"), -1, sunset("brg_dup_old"))
	testing.expect(t, !ok, "failed insert reported")
	testing.expect(t, !snapshot(&f, "brg_dup_new").found, "no replacement row")
	expect_no_receipt(t, &f, "brg_dup_new")
	expect_victim_untouched(t, &f, "brg_dup_old")
}

fail_commit_for_sunset_test :: proc(bridge_id: string) -> bool {
	return bridge_id != "brg_hook_new"
}

@(test)
test_sunset_rolls_back_when_the_admission_commit_fails :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_hook_old")
	bridge_create_limited_test_hook = fail_commit_for_sunset_test
	_, ok, err := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_hook_new"), 1, sunset("brg_hook_old"))
	bridge_create_limited_test_hook = nil
	testing.expect(t, !ok, "injected COMMIT failure reported")
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	expect_victim_untouched(t, &f, "brg_hook_old")
	testing.expect(t, !snapshot(&f, "brg_hook_new").found, "replacement rolled back")
	expect_no_receipt(t, &f, "brg_hook_new")
	testing.expect(t, exec(&f.conn, "BEGIN; COMMIT;"), "no transaction left open")
}

@(test)
test_sunset_requires_a_revocation_time :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_time_old")
	_, ok, err := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_time_new"), -1, iface.Bridge_Sunset{bridge_id = "brg_time_old"})
	testing.expect(t, !ok, "refused")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	expect_victim_untouched(t, &f, "brg_time_old")
}

// sunset_then runs a successful sunset of old_id for pending replacement new_id.
sunset_then :: proc(t: ^testing.T, f: ^Sunset_Fixture, old_id, new_id: string, max_bridges: int) {
	sunset_seed_victim(t, f, old_id)
	_, ok, _ := iface.bridge_create_limited_with_sunset(&f.repo, replacement(new_id), max_bridges, sunset(old_id))
	testing.expect(t, ok, "sunset admitted")
}

rollback :: proc(f: ^Sunset_Fixture, new_id: string, max_bridges: int, restore_allowed := true) -> (iface.Sunset_Rollback_Outcome, domain.Domain_Error) {
	return iface.bridge_delete_pending_restoring_sunset(&f.repo, new_id, max_bridges, restore_allowed, SUNSET_LATER)
}

// expect_victim_still_sunset: the rollback left the sunset bridge and its two
// sunset-revoked credentials exactly as the sunset made them.
expect_victim_still_sunset :: proc(t: ^testing.T, f: ^Sunset_Fixture, bridge_id: string, revoked_at := SUNSET_AT, loc := #caller_location) {
	s := snapshot(f, bridge_id)
	testing.expect_value(t, s.status, domain.Bridge_Status.Revoked, loc = loc)
	testing.expect_value(t, s.revoked_at, revoked_at, loc = loc)
	testing.expect_value(t, token_revoked_at(f, fmt.tprintf("%s_tok_a", bridge_id)), SUNSET_AT, loc = loc)
	testing.expect_value(t, token_revoked_at(f, fmt.tprintf("%s_tok_b", bridge_id)), SUNSET_AT, loc = loc)
}

@(test)
test_sunset_rollback_deletes_replacement_and_revives_exactly_the_receipt_tokens :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_rs_old", "brg_rs_new", 1)

	out, err := rollback(&f, "brg_rs_new", 1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.replacement_deleted, "pending replacement deleted")
	testing.expect(t, out.had_sunset, "receipt found")
	testing.expect(t, out.restored, "sunset bridge restored")
	testing.expect(t, !snapshot(&f, "brg_rs_new").found, "replacement gone")
	old := snapshot(&f, "brg_rs_old")
	// Restored as offline: its socket was closed when it was sunset.
	testing.expect_value(t, old.status, domain.Bridge_Status.Offline)
	testing.expect_value(t, old.revoked_at, "")
	testing.expect_value(t, token_revoked_at(&f, "brg_rs_old_tok_a"), "")
	testing.expect_value(t, token_revoked_at(&f, "brg_rs_old_tok_b"), "")
	// Revoked earlier with the same timestamp but not by this sunset: stays dead.
	testing.expect_value(t, token_revoked_at(&f, "brg_rs_old_tok_stolen"), SUNSET_AT)
	testing.expect_value(t, owner_count(&f), 1)
	expect_no_receipt(t, &f, "brg_rs_new")

	// The receipt was consumed: a second rollback (e.g. the sweep after the approval's
	// own rollback) finds nothing to do.
	again, again_err := rollback(&f, "brg_rs_new", 1)
	testing.expect_value(t, again_err.code, domain.Error_Code.None)
	testing.expect(t, !again.replacement_deleted && !again.had_sunset && !again.restored, "second rollback is a no-op")
	testing.expect(t, exec(&f.conn, "BEGIN; COMMIT;"), "no transaction left open")
}

@(test)
test_sunset_rollback_after_enrollment_commit_keeps_the_sunset :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_cm_old", "brg_cm_new", 1)
	// The replacement's pending credential, then the REAL commit transaction.
	_, tok_ok, _ := iface.bridge_save_token(&f.repo, domain.Bridge_Token{
		token_id = "brg_cm_new_tok", bridge_id = "brg_cm_new", kind = .Access,
		token_hash = "hash_brg_cm_new_tok", family_id = "fam_brg_cm_new", generation = 1,
		scope = "bridge:enroll", issued_at = SUNSET_AT,
		expires_at = "2099-01-01T00:00:00Z", family_expires_at = "2099-01-01T00:00:00Z",
	})
	testing.expect(t, tok_ok, "pending credential seeded")
	outcome, commit_ok, _ := iface.bridge_commit_enrollment(&f.repo, "brg_cm_new", "fam_brg_cm_new", "bridge:enroll", "bridge:runtime", false, SUNSET_LATER)
	testing.expect(t, commit_ok, "commit ran")
	testing.expect_value(t, outcome, iface.Enrollment_Commit_Outcome.Committed)
	// The commit transaction dropped the receipt: the sunset is final now.
	expect_no_receipt(t, &f, "brg_cm_new")

	// A late rollback (the sweep listing the replacement just before the commit).
	out, err := rollback(&f, "brg_cm_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, !out.replacement_deleted, "committed replacement kept")
	testing.expect(t, !out.restored, "sunset not revived next to a live replacement")
	testing.expect(t, snapshot(&f, "brg_cm_new").found, "replacement kept")
	expect_victim_still_sunset(t, &f, "brg_cm_old")
}

@(test)
test_sunset_rollback_refuses_restore_when_the_replacement_is_no_longer_pending :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_rc_old", "brg_rc_new", 1)
	// Belt and braces for a row that left pending without the commit path (receipt
	// still present): the row owns the slot, so the receipt is consumed unused.
	testing.expect(t, exec(&f.conn, "UPDATE bridges SET enrollment_pending_until = '' WHERE bridge_id = 'brg_rc_new';"), "commit replacement")

	out, err := rollback(&f, "brg_rc_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.had_sunset, "receipt was there")
	testing.expect(t, !out.restored, "a committed replacement keeps the slot")
	testing.expect(t, !out.replacement_deleted, "committed replacement not deleted")
	testing.expect(t, snapshot(&f, "brg_rc_new").found, "replacement kept")
	expect_victim_still_sunset(t, &f, "brg_rc_old")
	expect_no_receipt(t, &f, "brg_rc_new")
}

@(test)
test_sunset_rollback_leaves_a_bridge_revoked_again_since :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_rr_old", "brg_rr_new", -1)
	// An operator revoke after the sunset stamps its own time: the receipt no longer
	// describes the row, so the restore must not undo the operator's decision.
	testing.expect(t, exec(&f.conn, "UPDATE bridges SET revoked_at = '2026-10-31T12:05:00Z' WHERE bridge_id = 'brg_rr_old';"), "operator revoke")

	out, err := rollback(&f, "brg_rr_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, !out.restored, "re-revoked bridge stays revoked")
	testing.expect(t, out.replacement_deleted, "pending replacement still removed")
	expect_victim_still_sunset(t, &f, "brg_rr_old", "2026-10-31T12:05:00Z")
	expect_no_receipt(t, &f, "brg_rr_new")
}

@(test)
test_sunset_rollback_respects_the_plan_when_the_slot_was_taken :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_rp_old", "brg_rp_new", 1)
	// Another live bridge appeared while the replacement was pending (e.g. a plan
	// reconcile re-enabled one): reviving the sunset bridge would exceed the plan.
	sunset_seed_bridge(t, &f, "brg_rp_other", SUNSET_OWNER)

	out, err := rollback(&f, "brg_rp_new", 1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.replacement_deleted, "replacement still deleted")
	testing.expect(t, !out.restored, "restoring would exceed the plan")
	expect_victim_still_sunset(t, &f, "brg_rp_old")
	testing.expect_value(t, owner_count(&f), 1)
	expect_no_receipt(t, &f, "brg_rp_new")
}

@(test)
test_sunset_rollback_fails_closed_when_the_plan_is_unknown :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_fc_old", "brg_fc_new", -1)
	// restore_allowed = false: the caller could not read the owner's plan.
	out, err := rollback(&f, "brg_fc_new", -1, restore_allowed = false)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.replacement_deleted, "replacement deleted regardless")
	testing.expect(t, out.had_sunset && !out.restored, "sunset bridge left revoked")
	testing.expect(t, !snapshot(&f, "brg_fc_new").found, "replacement gone")
	expect_victim_still_sunset(t, &f, "brg_fc_old")
	expect_no_receipt(t, &f, "brg_fc_new")
}

@(test)
test_sunset_rollback_still_deletes_the_replacement_when_the_sunset_row_is_gone :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_gone_old", "brg_gone_new", -1)
	testing.expect(t, exec(&f.conn, "DELETE FROM bridges WHERE bridge_id = 'brg_gone_old';"), "sunset row removed")
	out, err := rollback(&f, "brg_gone_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.replacement_deleted, "replacement deleted, not left for the sweep")
	testing.expect(t, !out.restored, "nothing to restore")
	testing.expect(t, !snapshot(&f, "brg_gone_new").found, "replacement gone")
	expect_no_receipt(t, &f, "brg_gone_new")
}

@(test)
test_sunset_rollback_does_not_revive_a_receipt_token_revoked_again_since :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_tk_old", "brg_tk_new", -1)
	testing.expect(t, exec(&f.conn, "UPDATE bridge_tokens SET revoked_at = '2026-10-31T12:07:00Z' WHERE token_id = 'brg_tk_old_tok_b';"), "token revoked again")
	out, err := rollback(&f, "brg_tk_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, out.restored, "bridge restored")
	testing.expect_value(t, token_revoked_at(&f, "brg_tk_old_tok_a"), "")
	testing.expect_value(t, token_revoked_at(&f, "brg_tk_old_tok_b"), "2026-10-31T12:07:00Z")
	testing.expect_value(t, token_revoked_at(&f, "brg_tk_old_tok_stolen"), SUNSET_AT)
}

@(test)
test_sunset_rollback_failure_rolls_back_delete_restore_and_receipt_together :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_then(t, &f, "brg_at_old", "brg_at_new", -1)
	// The token restore fails for real AFTER the replacement delete and the row restore
	// already ran inside the rollback transaction.
	testing.expect(t, exec(&f.conn, "CREATE TRIGGER sunset_fail_restore BEFORE UPDATE ON bridge_tokens WHEN OLD.bridge_id = 'brg_at_old' AND NEW.revoked_at = '' BEGIN SELECT RAISE(ABORT, 'restore refused'); END;"), "trigger installed")
	_, err := rollback(&f, "brg_at_new", -1)
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	// Nothing changed: the sweep can retry the whole thing later.
	testing.expect(t, snapshot(&f, "brg_at_new").found, "replacement still pending")
	expect_victim_still_sunset(t, &f, "brg_at_old")
	testing.expect_value(t, receipt_of(&f, "brg_at_new").sunset_id, "brg_at_old")
	testing.expect(t, exec(&f.conn, "BEGIN; COMMIT;"), "no transaction left open")
}

@(test)
test_sunset_with_a_non_pending_replacement_is_final_and_writes_no_receipt :: proc(t: ^testing.T) {
	f: Sunset_Fixture
	if !sunset_open(t, &f) do return
	defer close(&f.conn)
	sunset_seed_victim(t, &f, "brg_np_old")
	_, ok, _ := iface.bridge_create_limited_with_sunset(&f.repo, replacement("brg_np_new", pending = false), 1, sunset("brg_np_old"))
	testing.expect(t, ok, "admitted")
	expect_no_receipt(t, &f, "brg_np_new")
	out, err := rollback(&f, "brg_np_new", 1)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, !out.replacement_deleted && !out.had_sunset, "an enrolled replacement has no rollback")
	expect_victim_still_sunset(t, &f, "brg_np_old")
}
