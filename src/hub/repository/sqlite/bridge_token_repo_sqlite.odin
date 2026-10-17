// bridge_tokens persistence (REQ-IMPL-3): the expiring `hba_`/`hbf_` pair and the
// rotation lineage that makes refresh-token reuse detectable.
//
// GENERATION IS BOUND AND READ AS TEXT, which looks wrong next to the column's
// INTEGER declaration and is deliberate: conn.odin binds no sqlite3_column_int (see
// the shell-session repo test, which made the same call and says so), and adding the
// first int binding for one column on the authentication path is a worse trade than
// relying on SQLite's INTEGER column affinity, which converts the bound text to an
// integer on write. So the stored value really is an integer — ORDER BY generation
// sorts numerically — and only the transport in and out of it is text.
package sqlite

import "core:strconv"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

BRIDGE_TOKEN_COLUMNS :: "token_id, bridge_id, kind, token_hash, family_id, generation, scope, issued_at, expires_at, family_expires_at, rotated_at, revoked_at"

bridge_save_token_sqlite :: proc(ctx: rawptr, token: domain.Bridge_Token) -> (domain.Bridge_Token, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	// The UPDATE half intentionally touches ONLY the two lifecycle stamps and
	// expires_at. token_hash, family_id, generation and bridge_id are immutable once
	// written: a save that could rewrite a token's hash or move it between families
	// would let a bug relabel a credential instead of issuing one, and rotation
	// already works by INSERTing the next generation rather than mutating this row.
	query := "INSERT INTO bridge_tokens (" + BRIDGE_TOKEN_COLUMNS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(token_id) DO UPDATE SET expires_at=excluded.expires_at, rotated_at=excluded.rotated_at, revoked_at=excluded.revoked_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge_Token{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge token save")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, token.token_id)
	bind_text(stmt, 2, token.bridge_id)
	bind_text(stmt, 3, domain.bridge_token_kind_string(token.kind))
	bind_text(stmt, 4, token.token_hash)
	bind_text(stmt, 5, token.family_id)
	gen_buf: [24]byte
	bind_text(stmt, 6, strconv.write_int(gen_buf[:], i64(token.generation), 10))
	bind_text(stmt, 7, token.scope if token.scope != "" else "bridge:runtime")
	bind_text(stmt, 8, token.issued_at)
	bind_text(stmt, 9, token.expires_at)
	bind_text(stmt, 10, token.family_expires_at)
	bind_text(stmt, 11, token.rotated_at)
	bind_text(stmt, 12, token.revoked_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.Bridge_Token{}, false, domain.domain_error(.Conflict, "bridge token could not be saved")
	return token, true, domain.Domain_Error{}
}

bridge_get_token_sqlite :: proc(ctx: rawptr, token_id: string) -> (domain.Bridge_Token, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT " + BRIDGE_TOKEN_COLUMNS + " FROM bridge_tokens WHERE token_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return domain.Bridge_Token{}, false, domain.domain_error(.Internal_Error, "failed to prepare bridge token lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, token_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Bridge_Token{}, false, domain.domain_error(.Not_Found, "bridge token not found")
	return bridge_token_from_stmt(stmt), true, domain.Domain_Error{}
}

// bridge_list_tokens_by_family_sqlite orders by generation then kind so a caller
// reading a lineage sees it oldest-first and deterministically — the reuse-detection
// path compares a presented token against the newest generation and a stable order
// is what makes "newest" mean one thing.
bridge_list_tokens_by_family_sqlite :: proc(ctx: rawptr, family_id: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT " + BRIDGE_TOKEN_COLUMNS + " FROM bridge_tokens WHERE family_id = ? ORDER BY generation ASC, kind ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge token family lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, family_id)
	out := make([dynamic]domain.Bridge_Token)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, bridge_token_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

// bridge_revoke_token_family_sqlite is the reuse-detection hammer (§7.4.3): one
// UPDATE revokes every generation of a lineage, both kinds.
//
// `revoked_at = ''` IN THE WHERE CLAUSE makes this idempotent AND makes the returned
// count meaningful: revoking an already-revoked family reports 0 changed rows rather
// than re-stamping a new timestamp over the original revocation time, which is the
// value an audit actually wants.
bridge_revoke_token_family_sqlite :: proc(ctx: rawptr, family_id, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if family_id == "" || revoked_at == "" do return 0, false, domain.domain_error(.Validation_Failed, "family_id and revoked_at are required")
	stmt: sqlite3_stmt = nil
	query := "UPDATE bridge_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, false, domain.domain_error(.Internal_Error, "failed to prepare bridge token family revoke")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, revoked_at)
	bind_text(stmt, 2, family_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return 0, false, domain.domain_error(.Internal_Error, "bridge token family could not be revoked")
	return row_changes, true, domain.Domain_Error{}
}

// bridge_revoke_token_family_in_scope_sqlite revokes a family's live rows only while
// they still carry `scope` (REQ-EA-3). The scope test is in the same UPDATE, so it
// is atomic with the commit's promote: whichever takes the write lock first wins,
// and a promoted family matches 0 rows here.
bridge_revoke_token_family_in_scope_sqlite :: proc(ctx: rawptr, family_id, scope, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if family_id == "" || scope == "" || revoked_at == "" do return 0, false, domain.domain_error(.Validation_Failed, "family_id, scope and revoked_at are required")
	stmt: sqlite3_stmt = nil
	query := "UPDATE bridge_tokens SET revoked_at = ? WHERE family_id = ? AND scope = ? AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, false, domain.domain_error(.Internal_Error, "failed to prepare scoped bridge token family revoke")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, revoked_at)
	bind_text(stmt, 2, family_id)
	bind_text(stmt, 3, scope)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return 0, false, domain.domain_error(.Internal_Error, "bridge token family could not be revoked")
	return row_changes, true, domain.Domain_Error{}
}

// bridge_revoke_tokens_for_bridge_sqlite is per-MACHINE revocation (§11.7.2): the
// operator revokes a bridge, and every credential of that bridge dies — including
// families from an earlier enrollment of the same machine. Keyed on bridge_id, so a
// different bridge of the same owner is untouched by construction.
bridge_revoke_tokens_for_bridge_sqlite :: proc(ctx: rawptr, bridge_id, revoked_at: string) -> (int, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if bridge_id == "" || revoked_at == "" do return 0, false, domain.domain_error(.Validation_Failed, "bridge_id and revoked_at are required")
	stmt: sqlite3_stmt = nil
	query := "UPDATE bridge_tokens SET revoked_at = ? WHERE bridge_id = ? AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return 0, false, domain.domain_error(.Internal_Error, "failed to prepare bridge token revoke")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, revoked_at)
	bind_text(stmt, 2, bridge_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return 0, false, domain.domain_error(.Internal_Error, "bridge tokens could not be revoked")
	return row_changes, true, domain.Domain_Error{}
}

// bridge_mark_token_rotated_sqlite spends a refresh token.
//
// `AND rotated_at = ''` IS THE SINGLE-USE ENFORCEMENT, and it is here rather than in
// the service on purpose: two concurrent refreshes presenting the same token both
// pass a service-level read-then-check, but only one of them changes a row here. The
// caller treats 0 changed rows as "someone else already spent it", which is exactly
// the reuse signal — so the race resolves into the detection path instead of minting
// two live generations from one token.
bridge_mark_token_rotated_sqlite :: proc(ctx: rawptr, token_id, rotated_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if token_id == "" || rotated_at == "" do return false, domain.domain_error(.Validation_Failed, "token_id and rotated_at are required")
	stmt: sqlite3_stmt = nil
	query := "UPDATE bridge_tokens SET rotated_at = ? WHERE token_id = ? AND rotated_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false, domain.domain_error(.Internal_Error, "failed to prepare bridge token rotate")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, rotated_at)
	bind_text(stmt, 2, token_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE do return false, domain.domain_error(.Internal_Error, "bridge token could not be marked rotated")
	return row_changes > 0, domain.Domain_Error{}
}

// bridge_commit_enrollment_sqlite is the enrollment COMMIT (REQ-EA-2/8), in ONE
// transaction:
//
//   1. promote the family from_scope -> to_scope. The `scope = from_scope` guard makes
//      it a compare-and-set: a revoked or already-promoted family changes 0 rows.
//   2. attach: revoke every OTHER live family of the bridge (the old device);
//      new bridge: clear enrollment_pending_until, so the sweep never deletes a row
//      whose credential is now live.
//
// Either both happen or neither does. A 0-row promote is told apart: a family that
// is already live in to_scope is a duplicate result (Already_Committed, nothing
// changes), anything else was rolled back (Not_Pending).
//
// BEGIN IMMEDIATE takes the write lock up front, as billing_repo_sqlite does, so a
// concurrent sweep cannot revoke the family between the read and the write.
bridge_commit_enrollment_sqlite :: proc(ctx: rawptr, bridge_id, family_id, from_scope, to_scope: string, attach: bool, now: string) -> (iface.Enrollment_Commit_Outcome, bool, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	if bridge_id == "" || family_id == "" || from_scope == "" || to_scope == "" || now == "" {
		return .Not_Pending, false, domain.domain_error(.Validation_Failed, "bridge_id, family_id, scopes and now are required")
	}
	if impl.commit != nil {
		sync.mutex_lock(&impl.commit.mutex)
		defer sync.mutex_unlock(&impl.commit.mutex)
		return bridge_commit_enrollment_on(&impl.commit.conn, bridge_id, family_id, from_scope, to_scope, attach, now)
	}
	// No dedicated connection: only an in-memory database, which a second connection
	// cannot open. Single-connection use (tests) has nothing to interleave with.
	return bridge_commit_enrollment_on(impl.conn, bridge_id, family_id, from_scope, to_scope, attach, now)
}

// bridge_enroll_commit_test_hook runs between the promote and the swap, inside the
// transaction. Test-only: it lets a test act on ANOTHER connection mid-transaction.
// It is handed the bridge_id so a test acts only on its own commit: tests run in
// parallel, and this is a package global.
bridge_enroll_commit_test_hook: proc(bridge_id: string)

@(private = "file")
bridge_commit_enrollment_on :: proc(conn: ^Conn, bridge_id, family_id, from_scope, to_scope: string, attach: bool, now: string) -> (iface.Enrollment_Commit_Outcome, bool, domain.Domain_Error) {
	fail :: proc(msg: string) -> (iface.Enrollment_Commit_Outcome, bool, domain.Domain_Error) {
		return .Not_Pending, false, domain.domain_error(.Internal_Error, msg)
	}
	if !exec(conn, "BEGIN IMMEDIATE;") do return fail("failed to begin the enrollment commit")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")

	promoted := 0
	{
		stmt: sqlite3_stmt = nil
		query := "UPDATE bridge_tokens SET scope = ? WHERE family_id = ? AND bridge_id = ? AND scope = ? AND revoked_at = '';"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return fail("failed to prepare the enrollment promote")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, to_scope)
		bind_text(stmt, 2, family_id)
		bind_text(stmt, 3, bridge_id)
		bind_text(stmt, 4, from_scope)
		step_rc, row_changes := step_changes(conn.db, stmt)
		if step_rc != SQLITE_DONE do return fail("the enrollment family could not be promoted")
		promoted = row_changes
	}
	when ODIN_TEST {
		if bridge_enroll_commit_test_hook != nil do bridge_enroll_commit_test_hook(bridge_id)
	}
	if promoted == 0 {
		stmt: sqlite3_stmt = nil
		query := "SELECT COUNT(*) FROM bridge_tokens WHERE family_id = ? AND bridge_id = ? AND scope = ? AND revoked_at = '';"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return fail("failed to prepare the enrollment state read")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, family_id)
		bind_text(stmt, 2, bridge_id)
		bind_text(stmt, 3, to_scope)
		if sqlite3_step(stmt) != SQLITE_ROW do return fail("the enrollment state could not be read")
		live := int(sqlite3_column_int64(stmt, 0))
		// Nothing was written; the deferred ROLLBACK ends the read transaction.
		return (.Already_Committed if live > 0 else .Not_Pending), true, domain.Domain_Error{}
	}
	{
		stmt: sqlite3_stmt = nil
		query := "UPDATE bridge_tokens SET revoked_at = ? WHERE bridge_id = ? AND family_id != ? AND revoked_at = '';" if attach else "UPDATE bridges SET enrollment_pending_until = '' WHERE bridge_id = ?;"
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return fail("failed to prepare the enrollment swap")
		defer sqlite3_finalize(stmt)
		if attach {
			bind_text(stmt, 1, now)
			bind_text(stmt, 2, bridge_id)
			bind_text(stmt, 3, family_id)
		} else {
			bind_text(stmt, 1, bridge_id)
		}
		if sqlite3_step(stmt) != SQLITE_DONE do return fail("the enrollment swap failed; nothing was committed")
	}
	if !exec(conn, "COMMIT;") do return fail("failed to commit the enrollment")
	committed = true
	return .Committed, true, domain.Domain_Error{}
}

// bridge_list_live_tokens_by_scope_sqlite returns every unrevoked token of a scope:
// the pending-enrollment sweep (REQ-EA-3) reads BRIDGE_ENROLL_TOKEN_SCOPE through it.
bridge_list_live_tokens_by_scope_sqlite :: proc(ctx: rawptr, scope: string) -> ([]domain.Bridge_Token, domain.Domain_Error) {
	impl := (^Bridge_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt = nil
	query := "SELECT " + BRIDGE_TOKEN_COLUMNS + " FROM bridge_tokens WHERE scope = ? AND revoked_at = '';"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed to prepare bridge token scope list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, scope)
	out := make([dynamic]domain.Bridge_Token)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, bridge_token_from_stmt(stmt))
	return out[:], domain.Domain_Error{}
}

bridge_token_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Bridge_Token {
	// An unrecognised kind decodes as `.Access` with ok=false. The row is returned
	// anyway — with its kind preserved as the SAFER of the two is not possible, so the
	// service checks `kind` against what it expects on every path and refuses a
	// mismatch. See verify_access_token / refresh_bridge_token.
	kind, _ := domain.bridge_token_kind_from_string(column_text_unowned(stmt, 2))
	generation, _ := strconv.parse_int(column_text_unowned(stmt, 5), 10)
	return domain.Bridge_Token{
		token_id = column_text(stmt, 0),
		bridge_id = column_text(stmt, 1),
		kind = kind,
		token_hash = column_text(stmt, 3),
		family_id = column_text(stmt, 4),
		generation = generation,
		scope = column_text(stmt, 6),
		issued_at = column_text(stmt, 7),
		expires_at = column_text(stmt, 8),
		family_expires_at = column_text(stmt, 9),
		rotated_at = column_text(stmt, 10),
		revoked_at = column_text(stmt, 11),
	}
}
