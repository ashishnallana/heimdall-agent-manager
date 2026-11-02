package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// E2EE artifact transfer storage (docs/plans/mcp-large-artifact-transfers.md §11).
// Chunk rows hold CIPHERTEXT bytes of one vault v2 token (ASCII); the artifact
// created at commit gets exactly the concatenated staged bytes as its content, built
// inside SQLite so the Hub never assembles a second full-size copy in a buffer.

Transfer_Repo_SQLite :: struct { conn: ^Conn }

new_transfer_repository :: proc(impl: ^Transfer_Repo_SQLite, conn: ^Conn) -> iface.Transfer_Repository {
	impl.conn = conn
	return iface.Transfer_Repository{
		ctx = rawptr(impl), insert = xfr_insert, get = xfr_get, get_by_request = xfr_get_by_request, get_by_token = xfr_get_by_token,
		rotate_token = xfr_rotate_token, append_chunk = xfr_append_chunk, visit_chunks = xfr_visit_chunks, set_state = xfr_set_state,
		mark_sealed = xfr_mark_sealed, commit = xfr_commit, count_fetch = xfr_count_fetch, mark_opened = xfr_mark_opened,
		owner_usage = xfr_owner_usage, global_staged_bytes = xfr_global_staged_bytes, expire = xfr_expire, purge = xfr_purge,
		delete_receipt = xfr_delete_receipt, get_receipt = xfr_get_receipt, read_artifact_window = xfr_read_artifact_window,
	}
}

@(private = "file")
XFR_COLUMNS :: "transfer_id,owner_user_id,client_id,grant_id,family_id,direction,state,error,token_sha256,artifact_id,artifact_revision,request_id,request_digest,kind,content_type,ext,associations,vault_id,epoch,received_bytes,ciphertext_bytes,ciphertext_sha256,fetches,seal_statement,seal_signature,seal_device_id,name_token,description_token,attestation_token,open_statement,open_signature,open_device_id,open_verified,created_at,touched_at,expires_at"

@(private = "file")
xerr :: proc(msg: string) -> domain.Domain_Error { return domain.domain_error(.Internal_Error, msg) }

@(private = "file")
xprep :: proc(impl: ^Transfer_Repo_SQLite, q: string) -> (sqlite3_stmt, bool) {
	stmt: sqlite3_stmt
	rc := sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil)
	return stmt, rc == SQLITE_OK
}

@(private = "file")
bind_i64 :: proc(s: sqlite3_stmt, i: int, v: i64) { sqlite3_bind_int64(s, c.int(i), v) }

@(private = "file")
xfr_from_stmt :: proc(s: sqlite3_stmt) -> domain.Mcp_Transfer {
	t := column_text
	i := proc(s: sqlite3_stmt, k: int) -> i64 { return sqlite3_column_int64(s, c.int(k)) }
	return domain.Mcp_Transfer{
		transfer_id = t(s, 0), owner_user_id = t(s, 1), client_id = t(s, 2), grant_id = t(s, 3), family_id = t(s, 4),
		direction = t(s, 5), state = t(s, 6), error = t(s, 7), token_sha256 = t(s, 8), artifact_id = t(s, 9), artifact_revision = t(s, 10),
		request_id = t(s, 11), request_digest = t(s, 12), kind = t(s, 13), content_type = t(s, 14), ext = t(s, 15), associations = t(s, 16),
		vault_id = t(s, 17), epoch = i(s, 18), received_bytes = i(s, 19), ciphertext_bytes = i(s, 20), ciphertext_sha256 = t(s, 21),
		fetches = i(s, 22), seal_statement = t(s, 23), seal_signature = t(s, 24), seal_device_id = t(s, 25), name_token = t(s, 26),
		description_token = t(s, 27), attestation_token = t(s, 28), open_statement = t(s, 29), open_signature = t(s, 30),
		open_device_id = t(s, 31), open_verified = i(s, 32) != 0, created_at = t(s, 33), touched_at = t(s, 34), expires_at = t(s, 35),
	}
}

@(private = "file")
xfr_insert :: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> domain.Domain_Error {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "INSERT INTO mcp_transfers (" + XFR_COLUMNS + ") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);")
	if !ok do return xerr("failed to prepare transfer insert")
	defer sqlite3_finalize(stmt)
	texts := []string{x.transfer_id, x.owner_user_id, x.client_id, x.grant_id, x.family_id, x.direction, x.state, x.error, x.token_sha256,
		x.artifact_id, x.artifact_revision, x.request_id, x.request_digest, x.kind, x.content_type, x.ext, x.associations, x.vault_id}
	for v, k in texts do bind_text(stmt, k + 1, v)
	bind_i64(stmt, 19, x.epoch); bind_i64(stmt, 20, x.received_bytes); bind_i64(stmt, 21, x.ciphertext_bytes)
	bind_text(stmt, 22, x.ciphertext_sha256); bind_i64(stmt, 23, x.fetches)
	rest := []string{x.seal_statement, x.seal_signature, x.seal_device_id, x.name_token, x.description_token, x.attestation_token, x.open_statement, x.open_signature, x.open_device_id}
	for v, k in rest do bind_text(stmt, 24 + k, v)
	bind_i64(stmt, 33, x.open_verified ? 1 : 0)
	bind_text(stmt, 34, x.created_at); bind_text(stmt, 35, x.touched_at); bind_text(stmt, 36, x.expires_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "transfer could not be created")
	return {}
}

@(private = "file")
xfr_get_where :: proc(impl: ^Transfer_Repo_SQLite, where_clause: string, args: []string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error) {
	stmt, ok := xprep(impl, strings.concatenate({"SELECT ", XFR_COLUMNS, " FROM mcp_transfers WHERE ", where_clause, ";"}, context.temp_allocator))
	if !ok do return {}, false, xerr("failed to prepare transfer lookup")
	defer sqlite3_finalize(stmt)
	for v, k in args do bind_text(stmt, k + 1, v)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, {}
	if rc != SQLITE_ROW do return {}, false, xerr("transfer lookup failed")
	return xfr_from_stmt(stmt), true, {}
}

@(private = "file")
xfr_get :: proc(ctx: rawptr, id: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error) {
	return xfr_get_where((^Transfer_Repo_SQLite)(ctx), "transfer_id=?", {id})
}
@(private = "file")
xfr_get_by_request :: proc(ctx: rawptr, owner, client_id, request_id: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error) {
	return xfr_get_where((^Transfer_Repo_SQLite)(ctx), "owner_user_id=? AND client_id=? AND request_id=?", {owner, client_id, request_id})
}
@(private = "file")
xfr_get_by_token :: proc(ctx: rawptr, token_sha256: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error) {
	if len(token_sha256) != 64 do return {}, false, {}
	return xfr_get_where((^Transfer_Repo_SQLite)(ctx), "token_sha256=?", {token_sha256})
}

@(private = "file")
xfr_exec_changes :: proc(impl: ^Transfer_Repo_SQLite, q: string, texts: []string, ints: []i64 = nil, int_first := false) -> (int, domain.Domain_Error) {
	stmt, ok := xprep(impl, q)
	if !ok do return 0, xerr("failed to prepare transfer update")
	defer sqlite3_finalize(stmt)
	k := 1
	if int_first do for v in ints { bind_i64(stmt, k, v); k += 1 }
	for v in texts { bind_text(stmt, k, v); k += 1 }
	if !int_first do for v in ints { bind_i64(stmt, k, v); k += 1 }
	rc, changed := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return 0, xerr("transfer update failed")
	return changed, {}
}

@(private = "file")
xfr_rotate_token :: proc(ctx: rawptr, id, token_sha256, touched_at: string) -> domain.Domain_Error {
	_, err := xfr_exec_changes((^Transfer_Repo_SQLite)(ctx), "UPDATE mcp_transfers SET token_sha256=?,touched_at=? WHERE transfer_id=?;", {token_sha256, touched_at, id})
	return err
}

// The transaction helpers hold the connection mutex across BEGIN..COMMIT so no other
// statement on the shared connection interleaves with the transfer transaction.
@(private = "file")
xfr_tx_begin :: proc(impl: ^Transfer_Repo_SQLite) -> (rawptr, bool) {
	mu := sqlite3_db_mutex(impl.conn.db)
	sqlite3_mutex_enter(mu)
	if !exec(impl.conn, "BEGIN IMMEDIATE;") {
		sqlite3_mutex_leave(mu)
		return nil, false
	}
	return mu, true
}
@(private = "file")
xfr_tx_end :: proc(impl: ^Transfer_Repo_SQLite, mu: rawptr, commit: bool) -> bool {
	ok := exec(impl.conn, commit ? "COMMIT;" : "ROLLBACK;")
	if commit && !ok do exec(impl.conn, "ROLLBACK;")
	sqlite3_mutex_leave(mu)
	return ok
}

@(private = "file")
xfr_append_chunk :: proc(ctx: rawptr, id: string, offset: i64, bytes: []byte, touched_at, expires_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	if len(bytes) == 0 do return false, domain.domain_error(.Validation_Failed, "empty chunk")
	mu, began := xfr_tx_begin(impl)
	if !began do return false, xerr("failed to begin transfer append")
	upd, uok := xprep(impl, "UPDATE mcp_transfers SET received_bytes=received_bytes+?,touched_at=?,expires_at=CASE WHEN ?<expires_at THEN ? ELSE expires_at END WHERE transfer_id=? AND state='receiving' AND direction='upload' AND received_bytes=?;")
	if !uok {
		xfr_tx_end(impl, mu, false)
		return false, xerr("failed to prepare transfer append")
	}
	bind_i64(upd, 1, i64(len(bytes))); bind_text(upd, 2, touched_at); bind_text(upd, 3, expires_at); bind_text(upd, 4, expires_at)
	bind_text(upd, 5, id); bind_i64(upd, 6, offset)
	urc, changed := step_changes(impl.conn.db, upd)
	sqlite3_finalize(upd)
	if urc != SQLITE_DONE || changed != 1 {
		xfr_tx_end(impl, mu, false)
		return false, urc != SQLITE_DONE ? xerr("transfer append failed") : domain.Domain_Error{}
	}
	stmt, ok := xprep(impl, "INSERT INTO mcp_transfer_chunks (transfer_id,chunk_index,byte_offset,bytes) VALUES (?,(SELECT COUNT(*) FROM mcp_transfer_chunks WHERE transfer_id=?),?,CAST(? AS BLOB));")
	if !ok {
		xfr_tx_end(impl, mu, false)
		return false, xerr("failed to prepare chunk insert")
	}
	bind_text(stmt, 1, id); bind_text(stmt, 2, id); bind_i64(stmt, 3, offset)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(bytes)), c.int(len(bytes)), SQLITE_TRANSIENT)
	rc := sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	if rc != SQLITE_DONE {
		xfr_tx_end(impl, mu, false)
		return false, xerr("chunk insert failed")
	}
	if !xfr_tx_end(impl, mu, true) do return false, xerr("transfer append commit failed")
	return true, {}
}

@(private = "file")
xfr_visit_chunks :: proc(ctx: rawptr, id: string, user: rawptr, visit: iface.Transfer_Chunk_Visitor) -> domain.Domain_Error {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "SELECT bytes FROM mcp_transfer_chunks WHERE transfer_id=? ORDER BY chunk_index;")
	if !ok do return xerr("failed to prepare chunk scan")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, id)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do return {}
		if rc != SQLITE_ROW do return xerr("chunk scan failed")
		b := transmute([]byte)column_text_unowned(stmt, 0)
		if !visit(user, b) do return {}
	}
}

@(private = "file")
xfr_set_state :: proc(ctx: rawptr, id, from, to, error, touched_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	mu, began := xfr_tx_begin(impl)
	if !began do return false, xerr("failed to begin transfer state change")
	changed, err := xfr_exec_changes(impl, "UPDATE mcp_transfers SET state=?,error=?,touched_at=? WHERE transfer_id=? AND state=?;", {to, error, touched_at, id, from})
	if err.code == .None && changed == 1 && to != domain.MCP_TRANSFER_SEALED && to != domain.MCP_TRANSFER_RECEIVING {
		_, err = xfr_exec_changes(impl, "DELETE FROM mcp_transfer_chunks WHERE transfer_id=?;", {id})
	}
	commit := err.code == .None && changed == 1
	if !xfr_tx_end(impl, mu, commit) && commit do return false, xerr("transfer state commit failed")
	return commit, err
}

@(private = "file")
xfr_mark_sealed :: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "UPDATE mcp_transfers SET state='sealed',ciphertext_sha256=?,seal_statement=?,seal_signature=?,seal_device_id=?,name_token=?,description_token=?,attestation_token=?,touched_at=?,ciphertext_bytes=? WHERE transfer_id=? AND state='receiving' AND received_bytes=?;")
	if !ok do return false, xerr("failed to prepare seal")
	defer sqlite3_finalize(stmt)
	texts := []string{x.ciphertext_sha256, x.seal_statement, x.seal_signature, x.seal_device_id, x.name_token, x.description_token, x.attestation_token, x.touched_at}
	for v, k in texts do bind_text(stmt, k + 1, v)
	bind_i64(stmt, 9, x.ciphertext_bytes); bind_text(stmt, 10, x.transfer_id); bind_i64(stmt, 11, x.ciphertext_bytes)
	rc, n := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, xerr("seal failed")
	return n == 1, {}
}

@(private = "file")
xfr_commit :: proc(ctx: rawptr, id: string, cm: domain.Mcp_Transfer_Commit) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	mu, began := xfr_tx_begin(impl)
	if !began do return false, xerr("failed to begin transfer commit")
	fail :: proc(impl: ^Transfer_Repo_SQLite, mu: rawptr, err: domain.Domain_Error) -> (bool, domain.Domain_Error) {
		xfr_tx_end(impl, mu, false)
		return false, err
	}
	changed, err := xfr_exec_changes(impl, "UPDATE mcp_transfers SET state='committed',touched_at=? WHERE transfer_id=? AND state='sealed' AND direction='upload';", {cm.artifact.updated_at, id})
	if err.code != .None do return fail(impl, mu, err)
	if changed != 1 do return fail(impl, mu, {})
	// Plain INSERT (no upsert): a reserved id that already exists must fail, never
	// overwrite another artifact.
	a := cm.artifact
	a.content = ""
	stmt, ok := xprep(impl, "INSERT INTO artifacts (artifact_id, owner_user_id, kind, name, description, content_type, size_bytes, blob_ref, content, agent_id, agent_instance_id, chain_id, task_id, project_id, mime, ext, sha256, origin_kind, origin_ref, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
	if !ok do return fail(impl, mu, xerr("failed to prepare artifact insert"))
	bind_artifact(stmt, a)
	rc := sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	if rc != SQLITE_DONE do return fail(impl, mu, domain.domain_error(.Conflict, "reserved artifact id is already in use"))
	// Content = the staged ciphertext, concatenated in chunk order inside SQLite.
	n2, e2 := xfr_exec_changes(impl, "UPDATE artifacts SET content=(SELECT COALESCE(group_concat(CAST(bytes AS TEXT),''),'') FROM (SELECT bytes FROM mcp_transfer_chunks WHERE transfer_id=? ORDER BY chunk_index)) WHERE artifact_id=? AND owner_user_id=?;", {id, a.artifact_id, string(a.owner_user_id)})
	if e2.code != .None || n2 != 1 do return fail(impl, mu, e2.code != .None ? e2 : xerr("artifact content assembly failed"))
	n3, e3 := xfr_exec_changes(impl, "INSERT INTO artifact_transfer_receipts (artifact_id,owner_user_id,statement,signature,device_id,attestation_token,ciphertext_sha256,created_at) SELECT artifact_id,owner_user_id,seal_statement,seal_signature,seal_device_id,attestation_token,ciphertext_sha256,? FROM mcp_transfers WHERE transfer_id=?;", {cm.receipt_created_at, id})
	if e3.code != .None || n3 != 1 do return fail(impl, mu, e3.code != .None ? e3 : xerr("receipt insert failed"))
	if _, e4 := xfr_exec_changes(impl, "DELETE FROM mcp_transfer_chunks WHERE transfer_id=?;", {id}); e4.code != .None do return fail(impl, mu, e4)
	if !xfr_tx_end(impl, mu, true) do return false, xerr("transfer commit failed")
	return true, {}
}

@(private = "file")
xfr_count_fetch :: proc(ctx: rawptr, id: string, max_fetches: i64, touched_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "UPDATE mcp_transfers SET fetches=fetches+1,touched_at=? WHERE transfer_id=? AND direction='download' AND state IN ('ready','delivered') AND fetches<?;")
	if !ok do return false, xerr("failed to prepare fetch count")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, touched_at); bind_text(stmt, 2, id); bind_i64(stmt, 3, max_fetches)
	rc, n := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, xerr("fetch count failed")
	return n == 1, {}
}

@(private = "file")
xfr_mark_opened :: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> (bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "UPDATE mcp_transfers SET state='delivered',open_statement=?,open_signature=?,open_device_id=?,open_verified=?,touched_at=? WHERE transfer_id=? AND direction='download' AND state='ready';")
	if !ok do return false, xerr("failed to prepare open receipt")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, x.open_statement); bind_text(stmt, 2, x.open_signature); bind_text(stmt, 3, x.open_device_id)
	bind_i64(stmt, 4, x.open_verified ? 1 : 0); bind_text(stmt, 5, x.touched_at); bind_text(stmt, 6, x.transfer_id)
	rc, n := step_changes(impl.conn.db, stmt)
	if rc != SQLITE_DONE do return false, xerr("open receipt failed")
	return n == 1, {}
}

@(private = "file")
xfr_owner_usage :: proc(ctx: rawptr, owner, direction: string) -> (int, i64, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "SELECT COUNT(*),COALESCE(SUM(received_bytes),0) FROM mcp_transfers WHERE owner_user_id=? AND direction=? AND state IN ('receiving','sealed','ready','delivered');")
	if !ok do return 0, 0, xerr("failed to prepare usage")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner); bind_text(stmt, 2, direction)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, 0, xerr("usage failed")
	return int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1), {}
}

@(private = "file")
xfr_global_staged_bytes :: proc(ctx: rawptr) -> (i64, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "SELECT COALESCE(SUM(received_bytes),0) FROM mcp_transfers WHERE direction='upload' AND state IN ('receiving','sealed');")
	if !ok do return 0, xerr("failed to prepare staged usage")
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, xerr("staged usage failed")
	return sqlite3_column_int64(stmt, 0), {}
}

@(private = "file")
xfr_expire :: proc(ctx: rawptr, now, idle_before: string) -> (int, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	mu, began := xfr_tx_begin(impl)
	if !began do return 0, xerr("failed to begin transfer expiry")
	n, err := xfr_exec_changes(impl, "UPDATE mcp_transfers SET state='expired',error='transfer_expired',touched_at=? WHERE state IN ('receiving','sealed','ready','delivered') AND (expires_at<=? OR touched_at<=?);", {now, now, idle_before})
	if err.code == .None {
		_, err = xfr_exec_changes(impl, "DELETE FROM mcp_transfer_chunks WHERE transfer_id IN (SELECT transfer_id FROM mcp_transfers WHERE state IN ('committed','cancelled','expired','failed'));", {})
	}
	xfr_tx_end(impl, mu, err.code == .None)
	return n, err
}

@(private = "file")
xfr_purge :: proc(ctx: rawptr, before: string) -> (int, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	mu, began := xfr_tx_begin(impl)
	if !began do return 0, xerr("failed to begin transfer purge")
	_, err := xfr_exec_changes(impl, "DELETE FROM mcp_transfer_chunks WHERE transfer_id IN (SELECT transfer_id FROM mcp_transfers WHERE state IN ('committed','cancelled','expired','failed') AND touched_at<=?);", {before})
	n := 0
	if err.code == .None do n, err = xfr_exec_changes(impl, "DELETE FROM mcp_transfers WHERE state IN ('committed','cancelled','expired','failed') AND touched_at<=?;", {before})
	xfr_tx_end(impl, mu, err.code == .None)
	return n, err
}

@(private = "file")
xfr_delete_receipt :: proc(ctx: rawptr, artifact_id, owner: string) -> domain.Domain_Error {
	_, err := xfr_exec_changes((^Transfer_Repo_SQLite)(ctx), "DELETE FROM artifact_transfer_receipts WHERE artifact_id=? AND owner_user_id=?;", {artifact_id, owner})
	return err
}

@(private = "file")
xfr_get_receipt :: proc(ctx: rawptr, artifact_id, owner: string) -> (string, string, string, string, string, bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "SELECT statement,signature,device_id,attestation_token,ciphertext_sha256 FROM artifact_transfer_receipts WHERE artifact_id=? AND owner_user_id=?;")
	if !ok do return "", "", "", "", "", false, xerr("failed to prepare receipt lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, artifact_id); bind_text(stmt, 2, owner)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return "", "", "", "", "", false, {}
	if rc != SQLITE_ROW do return "", "", "", "", "", false, xerr("receipt lookup failed")
	return column_text(stmt, 0), column_text(stmt, 1), column_text(stmt, 2), column_text(stmt, 3), column_text(stmt, 4), true, {}
}

// xfr_read_artifact_window copies one window of an artifact's stored value with
// substr() so SQLite materialises at most len(dst) bytes for the caller (same
// owner/live predicates as artifact_bounded.odin).
@(private = "file")
xfr_read_artifact_window :: proc(ctx: rawptr, artifact_id, owner: string, offset: i64, dst: []byte) -> (int, i64, bool, domain.Domain_Error) {
	impl := (^Transfer_Repo_SQLite)(ctx)
	stmt, ok := xprep(impl, "SELECT substr(CAST(content AS BLOB),?+1,?),length(CAST(content AS BLOB)) FROM artifacts WHERE artifact_id=? AND owner_user_id=? AND COALESCE(deleted_at,'')='' AND COALESCE(blob_ref,'')='';")
	if !ok do return 0, 0, false, xerr("failed to prepare artifact window")
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, offset); bind_i64(stmt, 2, i64(len(dst))); bind_text(stmt, 3, artifact_id); bind_text(stmt, 4, owner)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return 0, 0, false, {}
	if rc != SQLITE_ROW do return 0, 0, false, xerr("artifact window failed")
	window := column_text_unowned(stmt, 0)
	n := copy(dst, window)
	return n, sqlite3_column_int64(stmt, 1), true, {}
}

// debug_query_text returns the first column of the first row as text (tests and
// diagnostics only; never used on a request path).
debug_query_text :: proc(conn: ^Conn, q: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(q, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return "<prepare failed>"
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return "<no row>"
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}
