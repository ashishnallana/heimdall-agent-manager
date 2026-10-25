package sqlite

import "core:c"
import "core:sync"
import domain "odin_test:hub/domain"
import dbt "odin_test:hub/platform/dbtelemetry"
import iface "odin_test:hub/repository/iface"

// Vault device directory repository (docs/plans/passwordless-vault.md §2 P2).
//
// Every write runs on its OWN connection (as the bridge enrollment commit does,
// see Bridge_Enroll_Commit_Conn): `conn` is shared by every request thread, and a
// BEGIN on it would let another request's autocommit statement join — and be
// committed or rolled back with — this transaction. BEGIN IMMEDIATE on a dedicated
// connection takes the database write lock; `mutex` serializes the writers that
// share that connection. Reads use the shared connection.
//
// Each directory mutation is one transaction whose first statement is
//   UPDATE vault_directories SET version = version + 1 ... WHERE user_id = ? AND version = ?
// 0 rows -> nothing is written and the caller gets Conflict with the current version.

Vault_Directory_Repo_SQLite :: struct {
	conn:  ^Conn,
	write: ^Vault_Directory_Write_Conn,
	mutex: sync.Mutex,
}

Vault_Directory_Write_Conn :: struct {
	conn: Conn,
}

// open_vault_directory_write_conn opens the dedicated write connection. An in-memory
// database cannot have a second connection; the repository then writes on `conn`
// (single-connection use only: tests).
open_vault_directory_write_conn :: proc(w: ^Vault_Directory_Write_Conn, path: string) -> (bool, domain.Domain_Error) {
	conn, ok, err := open(path, .Vault)
	if !ok do return false, err
	w.conn = conn
	if !exec(&w.conn, "PRAGMA busy_timeout = 5000;") {
		close(&w.conn)
		return false, domain.domain_error(.Internal_Error, "failed to configure the vault directory connection")
	}
	return true, domain.Domain_Error{}
}

new_vault_directory_repository :: proc(impl: ^Vault_Directory_Repo_SQLite, conn: ^Conn, write: ^Vault_Directory_Write_Conn = nil) -> iface.Vault_Directory_Repository {
	impl.conn = conn
	impl.write = write
	return iface.Vault_Directory_Repository{
		consume_request_nonce = vault_consume_request_nonce_sqlite,
		ctx                  = rawptr(impl),
		get_directory        = vault_get_directory_sqlite,
		list_devices         = vault_list_devices_sqlite,
		list_epochs          = vault_list_epochs_sqlite,
		list_log             = vault_list_log_sqlite,
		mark_retired         = vault_mark_retired_sqlite,
		get_wrap             = vault_get_wrap_sqlite,
		find_pending_by_lookup = vault_find_pending_by_lookup_sqlite,
		register_pending     = vault_register_pending_sqlite,
		touch_last_seen      = vault_touch_last_seen_sqlite,
		delete_pending       = vault_delete_pending_sqlite,
		create_genesis       = vault_create_genesis_sqlite,
		commit               = vault_commit_sqlite,
		get_reset            = vault_get_reset_sqlite,
		schedule_reset       = vault_schedule_reset_sqlite,
		cancel_reset         = vault_cancel_reset_sqlite,
		list_due_resets      = vault_list_due_resets_sqlite,
		execute_reset        = vault_execute_reset_sqlite,
	}
}

vault_consume_request_nonce_sqlite :: proc(ctx: rawptr, user_id, device_id, nonce: string, now_ms, expires_ms: i64) -> (bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	purge, purge_ok := prepare(conn, "DELETE FROM vault_request_nonces WHERE expires_ms < ?;")
	if !purge_ok do return false, repo_err("failed to prepare nonce expiry")
	sqlite3_bind_int64(purge, 1, now_ms)
	purged := sqlite3_step(purge)
	sqlite3_finalize(purge)
	if purged != SQLITE_DONE do return false, repo_err("failed to expire request nonces")
	// The conditional insert and uniqueness check are atomic across connections.
	query := "INSERT INTO vault_request_nonces(user_id,device_id,nonce,expires_ms) SELECT ?,?,?,? WHERE (SELECT COUNT(*) FROM vault_request_nonces WHERE user_id=? AND device_id=?) < 4096 ON CONFLICT(user_id,device_id,nonce) DO NOTHING;"
	stmt, ok := prepare(conn, query)
	if !ok do return false, repo_err("failed to prepare nonce consumption")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id); bind_text(stmt, 2, device_id); bind_text(stmt, 3, nonce)
	sqlite3_bind_int64(stmt, 4, expires_ms)
	bind_text(stmt, 5, user_id); bind_text(stmt, 6, device_id)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return false, repo_err("failed to consume request nonce")
	return changes == 1, {}
}

@(private = "file")
write_conn :: proc(impl: ^Vault_Directory_Repo_SQLite) -> ^Conn {
	if impl.write != nil do return &impl.write.conn
	return impl.conn
}

@(private = "file")
repo_err :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, msg)
}

@(private = "file")
prepare :: proc(conn: ^Conn, query: string) -> (sqlite3_stmt, bool) {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != SQLITE_OK do return nil, false
	return stmt, true
}

// bind_opt binds NULL for an empty value (nullable columns; the partial UNIQUE index on
// pair_lookup relies on non-pending rows carrying NULL).
@(private = "file")
bind_opt :: proc(stmt: sqlite3_stmt, index: int, value: string) {
	if value == "" {
		sqlite3_bind_null(stmt, c.int(index))
		return
	}
	bind_text(stmt, index, value)
}

DEVICE_COLUMNS :: "device_id, user_id, kind, label, sign_alg, wrap_alg, sign_public_key, ecdh_public_key, fingerprint, bridge_id, status, pair_lookup, code_expires_at, approval_statement, approval_signature, approved_by_device_id, revocation_statement, revocation_signature, revoked_by_device_id, recovery_blob, created_at, approved_at, revoked_at, last_seen_at, retired_at, pair_key_mac, register_statement, pair_mac, pair_salt, pair_hub_origin"

@(private = "file")
device_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Vault_Device {
	status, _ := domain.vault_device_status_from_string(column_text_unowned(stmt, 10))
	return domain.Vault_Device{
		device_id = column_text(stmt, 0),
		user_id = column_text(stmt, 1),
		kind = column_text(stmt, 2),
		label = column_text(stmt, 3),
		sign_alg = column_text(stmt, 4),
		wrap_alg = column_text(stmt, 5),
		sign_public_key = column_text(stmt, 6),
		ecdh_public_key = column_text(stmt, 7),
		fingerprint = column_text(stmt, 8),
		bridge_id = column_text(stmt, 9),
		status = status,
		pair_lookup = column_text(stmt, 11),
		code_expires_at = column_text(stmt, 12),
		approval_statement = column_text(stmt, 13),
		approval_signature = column_text(stmt, 14),
		approved_by_device_id = column_text(stmt, 15),
		revocation_statement = column_text(stmt, 16),
		revocation_signature = column_text(stmt, 17),
		revoked_by_device_id = column_text(stmt, 18),
		recovery_blob = column_text(stmt, 19),
		created_at = column_text(stmt, 20),
		approved_at = column_text(stmt, 21),
		revoked_at = column_text(stmt, 22),
		last_seen_at = column_text(stmt, 23),
		retired_at = column_text(stmt, 24),
		pair_key_mac = column_text(stmt, 25),
		register_statement = column_text(stmt, 26),
		pair_mac = column_text(stmt, 27),
		pair_salt = column_text(stmt, 28),
		pair_hub_origin = column_text(stmt, 29),
	}
}

@(private = "file")
bind_device_insert :: proc(stmt: sqlite3_stmt, d: domain.Vault_Device) {
	bind_text(stmt, 1, d.device_id)
	bind_text(stmt, 2, d.user_id)
	bind_text(stmt, 3, d.kind)
	bind_text(stmt, 4, d.label)
	bind_text(stmt, 5, d.sign_alg)
	bind_text(stmt, 6, d.wrap_alg)
	bind_text(stmt, 7, d.sign_public_key)
	bind_text(stmt, 8, d.ecdh_public_key)
	bind_text(stmt, 9, d.fingerprint)
	bind_text(stmt, 10, d.bridge_id)
	bind_text(stmt, 11, domain.vault_device_status_string(d.status))
	bind_opt(stmt, 12, d.pair_lookup)
	bind_opt(stmt, 13, d.code_expires_at)
	bind_opt(stmt, 14, d.approval_statement)
	bind_opt(stmt, 15, d.approval_signature)
	bind_opt(stmt, 16, d.approved_by_device_id)
	bind_opt(stmt, 17, d.revocation_statement)
	bind_opt(stmt, 18, d.revocation_signature)
	bind_opt(stmt, 19, d.revoked_by_device_id)
	bind_text(stmt, 20, d.recovery_blob)
	bind_text(stmt, 21, d.created_at)
	bind_opt(stmt, 22, d.approved_at)
	bind_opt(stmt, 23, d.revoked_at)
	bind_opt(stmt, 24, d.last_seen_at)
	bind_opt(stmt, 25, d.retired_at)
	bind_opt(stmt, 26, d.pair_key_mac)
	bind_opt(stmt, 27, d.register_statement)
	bind_opt(stmt, 28, d.pair_mac)
	bind_opt(stmt, 29, d.pair_salt)
	bind_opt(stmt, 30, d.pair_hub_origin)
}

@(private = "file")
insert_device_on :: proc(conn: ^Conn, d: domain.Vault_Device) -> bool {
	stmt, ok := prepare(conn, "INSERT INTO vault_devices (" + DEVICE_COLUMNS + ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
	if !ok do return false
	defer sqlite3_finalize(stmt)
	bind_device_insert(stmt, d)
	return sqlite3_step(stmt) == SQLITE_DONE
}

// ── Reads ───────────────────────────────────────────────────────────────────

vault_get_directory_sqlite :: proc(ctx: rawptr, user_id: string) -> (domain.Vault_Directory, bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	return get_directory_on(impl.conn, user_id)
}

@(private = "file")
get_directory_on :: proc(conn: ^Conn, user_id: string) -> (domain.Vault_Directory, bool, domain.Domain_Error) {
	stmt, ok := prepare(conn, "SELECT user_id, version, current_epoch, root_device_id, genesis_statement, genesis_signature, created_at, updated_at, head_hash FROM vault_directories WHERE user_id = ?;")
	if !ok do return {}, false, repo_err("failed to prepare vault directory read")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.Domain_Error{}
	if rc != SQLITE_ROW do return {}, false, repo_err("failed to read vault directory")
	return domain.Vault_Directory{
		user_id = column_text(stmt, 0),
		version = sqlite3_column_int64(stmt, 1),
		current_epoch = sqlite3_column_int64(stmt, 2),
		root_device_id = column_text(stmt, 3),
		genesis_statement = column_text(stmt, 4),
		genesis_signature = column_text(stmt, 5),
		created_at = column_text(stmt, 6),
		updated_at = column_text(stmt, 7),
		head_hash = column_text(stmt, 8),
	}, true, domain.Domain_Error{}
}

vault_list_devices_sqlite :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Device, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	stmt, ok := prepare(impl.conn, "SELECT " + DEVICE_COLUMNS + " FROM vault_devices WHERE user_id = ? ORDER BY created_at, device_id;")
	if !ok do return nil, repo_err("failed to prepare vault device list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	out := make([dynamic]domain.Vault_Device)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, repo_err("failed to list vault devices")
		append(&out, device_from_stmt(stmt))
	}
	return out[:], domain.Domain_Error{}
}

vault_list_epochs_sqlite :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Epoch, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	stmt, ok := prepare(impl.conn, "SELECT user_id, epoch, statement, signature, created_at FROM vault_epochs WHERE user_id = ? ORDER BY epoch;")
	if !ok do return nil, repo_err("failed to prepare vault epoch list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	out := make([dynamic]domain.Vault_Epoch)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, repo_err("failed to list vault epochs")
		append(&out, domain.Vault_Epoch{
			user_id = column_text(stmt, 0),
			epoch = sqlite3_column_int64(stmt, 1),
			statement = column_text(stmt, 2),
			signature = column_text(stmt, 3),
			created_at = column_text(stmt, 4),
		})
	}
	return out[:], domain.Domain_Error{}
}

vault_list_log_sqlite :: proc(ctx: rawptr, user_id: string) -> ([]domain.Vault_Log_Entry, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	stmt, ok := prepare(impl.conn, "SELECT user_id, seq, statement, signature, entry_hash, created_at FROM vault_log WHERE user_id = ? ORDER BY seq;")
	if !ok do return nil, repo_err("failed to prepare vault log list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	out := make([dynamic]domain.Vault_Log_Entry)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, repo_err("failed to list the vault log")
		append(&out, domain.Vault_Log_Entry{
			user_id = column_text(stmt, 0),
			seq = sqlite3_column_int64(stmt, 1),
			statement = column_text(stmt, 2),
			signature = column_text(stmt, 3),
			entry_hash = column_text(stmt, 4),
			created_at = column_text(stmt, 5),
		})
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
insert_log_on :: proc(conn: ^Conn, e: domain.Vault_Log_Entry) -> bool {
	stmt, ok := prepare(conn, "INSERT INTO vault_log (user_id, seq, statement, signature, entry_hash, created_at) VALUES (?, ?, ?, ?, ?, ?);")
	if !ok do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, e.user_id)
	sqlite3_bind_int64(stmt, 2, e.seq)
	bind_text(stmt, 3, e.statement)
	bind_text(stmt, 4, e.signature)
	bind_text(stmt, 5, e.entry_hash)
	bind_text(stmt, 6, e.created_at)
	return sqlite3_step(stmt) == SQLITE_DONE
}

// vault_mark_retired_sqlite sets the retirement hint. It never touches the version,
// the log or the device status (see iface.Vault_Mark_Retired_Proc).
vault_mark_retired_sqlite :: proc(ctx: rawptr, user_id, device_id, bridge_id, now: string) -> (bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	stmt, ok := prepare(conn, "UPDATE vault_devices SET retired_at = ? WHERE device_id = ? AND user_id = ? AND status = 'approved' AND bridge_id = ? AND bridge_id != '' AND retired_at IS NULL;")
	if !ok do return false, repo_err("failed to prepare the retirement hint")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, now)
	bind_text(stmt, 2, device_id)
	bind_text(stmt, 3, user_id)
	bind_text(stmt, 4, bridge_id)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return false, repo_err("the retirement hint failed")
	return changes == 1, domain.Domain_Error{}
}

vault_get_wrap_sqlite :: proc(ctx: rawptr, user_id, device_id: string) -> (domain.Vault_Wrap_Row, bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	stmt, ok := prepare(impl.conn, "SELECT user_id, device_id, directory_version, current_epoch, wrap_json, updated_at FROM vault_wrapped_keyrings WHERE user_id = ? AND device_id = ?;")
	if !ok do return {}, false, repo_err("failed to prepare vault wrap read")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	bind_text(stmt, 2, device_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.Domain_Error{}
	if rc != SQLITE_ROW do return {}, false, repo_err("failed to read vault wrap")
	return domain.Vault_Wrap_Row{
		user_id = column_text(stmt, 0),
		device_id = column_text(stmt, 1),
		directory_version = sqlite3_column_int64(stmt, 2),
		current_epoch = sqlite3_column_int64(stmt, 3),
		wrap_json = column_text(stmt, 4),
		updated_at = column_text(stmt, 5),
	}, true, domain.Domain_Error{}
}

vault_find_pending_by_lookup_sqlite :: proc(ctx: rawptr, user_id, pair_lookup: string) -> (domain.Vault_Device, bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	if pair_lookup == "" do return {}, false, domain.Domain_Error{}
	stmt, ok := prepare(impl.conn, "SELECT " + DEVICE_COLUMNS + " FROM vault_devices WHERE user_id = ? AND pair_lookup = ? AND status = 'pending';")
	if !ok do return {}, false, repo_err("failed to prepare vault pending lookup")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	bind_text(stmt, 2, pair_lookup)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.Domain_Error{}
	if rc != SQLITE_ROW do return {}, false, repo_err("failed to look up pending vault device")
	return device_from_stmt(stmt), true, domain.Domain_Error{}
}

@(private = "file")
find_by_key_on :: proc(conn: ^Conn, user_id, sign_public_key: string) -> (domain.Vault_Device, bool, bool) {
	stmt, ok := prepare(conn, "SELECT " + DEVICE_COLUMNS + " FROM vault_devices WHERE user_id = ? AND sign_public_key = ?;")
	if !ok do return {}, false, false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	bind_text(stmt, 2, sign_public_key)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, true
	if rc != SQLITE_ROW do return {}, false, false
	return device_from_stmt(stmt), true, true
}

@(private = "file")
current_version_on :: proc(conn: ^Conn, user_id: string) -> i64 {
	dir, found, _ := get_directory_on(conn, user_id)
	return dir.version if found else 0
}

// ── Writes ──────────────────────────────────────────────────────────────────

vault_register_pending_sqlite :: proc(ctx: rawptr, device: domain.Vault_Device, now: string) -> (domain.Vault_Device, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	if device.status != .Pending || device.pair_lookup == "" || device.pair_key_mac == "" || device.pair_salt == "" || device.pair_hub_origin == "" || device.register_statement == "" || device.code_expires_at == "" {
		return {}, domain.domain_error(.Validation_Failed, "a registered device must be pending with a pairing lookup")
	}
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, repo_err("failed to begin vault registration")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")

	// Expired pending rows are purged first (an expired same-key row is then simply
	// registered again with a fresh code).
	{
		stmt, ok := prepare(conn, "DELETE FROM vault_devices WHERE user_id = ? AND status = 'pending' AND code_expires_at <= ?;")
		if !ok do return {}, repo_err("failed to prepare pending purge")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, device.user_id)
		bind_text(stmt, 2, now)
		if sqlite3_step(stmt) != SQLITE_DONE do return {}, repo_err("failed to purge expired pending devices")
	}
	existing, found, read_ok := find_by_key_on(conn, device.user_id, device.sign_public_key)
	if !read_ok do return {}, repo_err("failed to read vault device")
	if found {
		// Same key, same user. Approved/revoked rows are returned unchanged. A live
		// pending request (expired ones were purged above) is re-paired only by a
		// strictly newer self-signed register statement (the device drew a new code);
		// anything else, such as a replayed body, leaves it untouched.
		if existing.status != .Pending || !domain.vault_register_supersedes(device.register_statement, existing.register_statement) {
			if !exec(conn, "COMMIT;") do return {}, repo_err("failed to end vault registration")
			committed = true
			return existing, domain.Domain_Error{}
		}
		stmt, ok := prepare(conn, "UPDATE vault_devices SET pair_lookup = ?, pair_key_mac = ?, register_statement = ?, label = ?, code_expires_at = ?, pair_salt = ?, pair_hub_origin = ? WHERE device_id = ? AND user_id = ? AND status = 'pending';")
		if !ok do return {}, repo_err("failed to prepare the pairing refresh")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, device.pair_lookup)
		bind_text(stmt, 2, device.pair_key_mac)
		bind_text(stmt, 3, device.register_statement)
		bind_text(stmt, 4, device.label)
		bind_text(stmt, 5, device.code_expires_at)
		bind_text(stmt, 6, device.pair_salt)
		bind_text(stmt, 7, device.pair_hub_origin)
		bind_text(stmt, 8, existing.device_id)
		bind_text(stmt, 9, existing.user_id)
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return {}, domain.vault_reason_error(.Conflict, "lookup_collision", "pairing lookup collided; retry with a new code")
		if changes != 1 do return {}, repo_err("the pairing refresh changed no row")
		existing.pair_lookup = device.pair_lookup
		existing.pair_key_mac = device.pair_key_mac
		existing.pair_salt = device.pair_salt
		existing.pair_hub_origin = device.pair_hub_origin
		existing.register_statement = device.register_statement
		existing.label = device.label
		existing.code_expires_at = device.code_expires_at
		if !exec(conn, "COMMIT;") do return {}, repo_err("failed to commit vault registration")
		committed = true
		return existing, domain.Domain_Error{}
	}
	{
		stmt, ok := prepare(conn, "SELECT COUNT(*) FROM vault_devices WHERE user_id = ? AND status = 'pending';")
		if !ok do return {}, repo_err("failed to prepare pending count")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, device.user_id)
		if sqlite3_step(stmt) != SQLITE_ROW do return {}, repo_err("failed to count pending devices")
		if sqlite3_column_int64(stmt, 0) >= domain.VAULT_PENDING_PER_USER_MAX {
			return {}, domain.vault_reason_error(.Rate_Limited, "pending_cap", "too many devices are waiting for approval; approve or deny one, or wait for a code to expire")
		}
	}
	if !insert_device_on(conn, device) {
		// UNIQUE(pair_lookup) for a collision, or the global device_id primary key when
		// another account registered this exact key: both refuse without writing.
		return {}, domain.vault_reason_error(.Conflict, "lookup_collision", "device could not be registered; retry with a new code")
	}
	if !exec(conn, "COMMIT;") do return {}, repo_err("failed to commit vault registration")
	committed = true
	return device, domain.Domain_Error{}
}

vault_delete_pending_sqlite :: proc(ctx: rawptr, user_id, device_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	stmt, ok := prepare(conn, "DELETE FROM vault_devices WHERE device_id = ? AND user_id = ? AND status = 'pending';")
	if !ok do return false, repo_err("failed to prepare pending delete")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, device_id)
	bind_text(stmt, 2, user_id)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return false, repo_err("failed to delete pending device")
	return changes == 1, domain.Domain_Error{}
}

// last_seen_at only feeds the Settings -> Devices panel and the revoke confirmation;
// no auth, expiry or prune logic reads it, so hour granularity is enough.
VAULT_LAST_SEEN_THROTTLE_SECONDS :: 3600

vault_touch_last_seen_sqlite :: proc(ctx: rawptr, user_id, device_id, now: string) -> domain.Domain_Error {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	// Presence display is approximate within VAULT_LAST_SEEN_THROTTLE_SECONDS; this
	// is not an auth or expiry clock. Keep one atomic statement on the dedicated writer: no read/cache
	// can race directory mutations. Invalid/regressing clocks retain the old update
	// behavior. Hub timestamps have whole-second precision.
	stmt, ok := prepare(conn, `UPDATE vault_devices SET last_seen_at = ?1
		WHERE device_id = ?2 AND user_id = ?3 AND (
			unixepoch(last_seen_at) IS NULL OR unixepoch(?1) IS NULL OR
			unixepoch(last_seen_at) > unixepoch(?1) OR
			unixepoch(last_seen_at) <= unixepoch(?1) - CAST(?4 AS INTEGER));`)
	if !ok do return repo_err("failed to prepare last_seen update")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, now)
	bind_text(stmt, 2, device_id)
	bind_text(stmt, 3, user_id)
	bind_text(stmt, 4, int_s(VAULT_LAST_SEEN_THROTTLE_SECONDS))
	if sqlite3_step(stmt) != SQLITE_DONE do return repo_err("failed to update last_seen")
	return domain.Domain_Error{}
}

@(private = "file")
insert_epoch_on :: proc(conn: ^Conn, user_id: string, epoch: i64, statement, signature, now: string) -> bool {
	stmt, ok := prepare(conn, "INSERT INTO vault_epochs (user_id, epoch, statement, signature, created_at) VALUES (?, ?, ?, ?, ?);")
	if !ok do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	sqlite3_bind_int64(stmt, 2, epoch)
	bind_text(stmt, 3, statement)
	bind_text(stmt, 4, signature)
	bind_text(stmt, 5, now)
	return sqlite3_step(stmt) == SQLITE_DONE
}

@(private = "file")
upsert_wrap_on :: proc(conn: ^Conn, w: domain.Vault_Wrap_Row) -> bool {
	stmt, ok := prepare(conn, "INSERT INTO vault_wrapped_keyrings (user_id, device_id, directory_version, current_epoch, wrap_json, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(user_id, device_id) DO UPDATE SET directory_version = excluded.directory_version, current_epoch = excluded.current_epoch, wrap_json = excluded.wrap_json, updated_at = excluded.updated_at;")
	if !ok do return false
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, w.user_id)
	bind_text(stmt, 2, w.device_id)
	sqlite3_bind_int64(stmt, 3, w.directory_version)
	sqlite3_bind_int64(stmt, 4, w.current_epoch)
	bind_text(stmt, 5, w.wrap_json)
	bind_text(stmt, 6, w.updated_at)
	return sqlite3_step(stmt) == SQLITE_DONE
}

vault_create_genesis_sqlite :: proc(ctx: rawptr, g: domain.Vault_Genesis) -> domain.Domain_Error {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	if !exec(conn, "BEGIN IMMEDIATE;") do return repo_err("failed to begin vault genesis")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")

	if _, exists, err := get_directory_on(conn, g.directory.user_id); err.code != .None {
		return err
	} else if exists {
		return domain.vault_reason_error(.Conflict, "directory_exists", "a vault directory already exists for this account")
	}
	{
		if g.directory.version != 1 || g.log.seq != 1 || g.log.entry_hash == "" || g.directory.head_hash != g.log.entry_hash || g.log.user_id != g.directory.user_id {
			return domain.domain_error(.Validation_Failed, "genesis must be log seq 1 and the directory head")
		}
		stmt, ok := prepare(conn, "INSERT INTO vault_directories (user_id, version, current_epoch, root_device_id, genesis_statement, genesis_signature, created_at, updated_at, head_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);")
		if !ok do return repo_err("failed to prepare vault genesis")
		defer sqlite3_finalize(stmt)
		d := g.directory
		bind_text(stmt, 1, d.user_id)
		sqlite3_bind_int64(stmt, 2, d.version)
		sqlite3_bind_int64(stmt, 3, d.current_epoch)
		bind_text(stmt, 4, d.root_device_id)
		bind_text(stmt, 5, d.genesis_statement)
		bind_text(stmt, 6, d.genesis_signature)
		bind_text(stmt, 7, d.created_at)
		bind_text(stmt, 8, d.updated_at)
		bind_text(stmt, 9, d.head_hash)
		if sqlite3_step(stmt) != SQLITE_DONE do return domain.vault_reason_error(.Conflict, "directory_exists", "a vault directory already exists for this account")
	}
	// The root may already be registered as pending (register-then-genesis); it is
	// promoted in place. Any other existing row for the key refuses genesis.
	existing, found, read_ok := find_by_key_on(conn, g.device.user_id, g.device.sign_public_key)
	if !read_ok do return repo_err("failed to read vault device")
	if found {
		if existing.status != .Pending || existing.device_id != g.device.device_id do return domain.vault_reason_error(.Conflict, "device_exists", "this device key is already in the directory")
		stmt, ok := prepare(conn, "DELETE FROM vault_devices WHERE device_id = ? AND user_id = ? AND status = 'pending';")
		if !ok do return repo_err("failed to prepare pending cleanup")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, existing.device_id)
		bind_text(stmt, 2, existing.user_id)
		if sqlite3_step(stmt) != SQLITE_DONE do return repo_err("failed to clear the pending root")
	}
	if !insert_device_on(conn, g.device) do return domain.vault_reason_error(.Conflict, "device_exists", "this device key is already registered")
	if !insert_log_on(conn, g.log) do return repo_err("failed to write the genesis log entry")
	if !insert_epoch_on(conn, g.epoch.user_id, g.epoch.epoch, g.epoch.statement, g.epoch.signature, g.epoch.created_at) do return repo_err("failed to write the genesis epoch")
	if !upsert_wrap_on(conn, g.wrap) do return repo_err("failed to write the genesis wrap")
	if !exec(conn, "COMMIT;") do return repo_err("failed to commit vault genesis")
	committed = true
	return domain.Domain_Error{}
}

// vault_commit_test_hook runs inside the transaction right after the CAS. Test-only.
vault_commit_test_hook: proc(user_id: string)

vault_commit_sqlite :: proc(ctx: rawptr, cm: domain.Vault_Directory_Commit) -> (i64, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	if cm.user_id == "" || cm.now == "" || cm.expected_version < 1 do return 0, domain.domain_error(.Validation_Failed, "user_id, now and expected_version are required")
	// The hub never advances the directory without a signed log op.
	if cm.log_statement == "" || cm.log_signature == "" || cm.log_entry_hash == "" || cm.expected_head_hash == "" {
		return 0, domain.domain_error(.Validation_Failed, "a directory commit must append exactly one signed log op")
	}
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	if !exec(conn, "BEGIN IMMEDIATE;") do return 0, repo_err("failed to begin vault directory commit")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")

	conflict :: proc(conn: ^Conn, user_id: string) -> (i64, domain.Domain_Error) {
		return 0, domain.vault_conflict_error(current_version_on(conn, user_id))
	}
	// 1. The CAS. The epoch guard rides on it: a new epoch must be current + 1.
	{
		query := "UPDATE vault_directories SET version = version + 1, head_hash = ?, updated_at = ? WHERE user_id = ? AND version = ? AND head_hash = ?;"
		if cm.new_epoch > 0 do query = "UPDATE vault_directories SET version = version + 1, head_hash = ?, updated_at = ?, current_epoch = ? WHERE user_id = ? AND version = ? AND head_hash = ? AND current_epoch = ?;"
		stmt, ok := prepare(conn, query)
		if !ok do return 0, repo_err("failed to prepare the directory CAS")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.log_entry_hash)
		bind_text(stmt, 2, cm.now)
		if cm.new_epoch > 0 {
			sqlite3_bind_int64(stmt, 3, cm.new_epoch)
			bind_text(stmt, 4, cm.user_id)
			sqlite3_bind_int64(stmt, 5, cm.expected_version)
			bind_text(stmt, 6, cm.expected_head_hash)
			sqlite3_bind_int64(stmt, 7, cm.new_epoch - 1)
		} else {
			bind_text(stmt, 3, cm.user_id)
			sqlite3_bind_int64(stmt, 4, cm.expected_version)
			bind_text(stmt, 5, cm.expected_head_hash)
		}
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return 0, repo_err("the directory CAS failed")
		if changes != 1 do return conflict(conn, cm.user_id)
	}
	// The log op occupies seq = expected_version + 1 (primary key: one op per slot).
	if !insert_log_on(conn, domain.Vault_Log_Entry{user_id = cm.user_id, seq = cm.expected_version + 1, statement = cm.log_statement, signature = cm.log_signature, entry_hash = cm.log_entry_hash, created_at = cm.now}) {
		return conflict(conn, cm.user_id)
	}
	when ODIN_TEST {
		if vault_commit_test_hook != nil do vault_commit_test_hook(cm.user_id)
	}
	// 2. Guarded row writes. Any 0-row guard rolls the whole commit back.
	if cm.approve_device_id != "" {
		stmt, ok := prepare(conn, "UPDATE vault_devices SET status = 'approved', approval_statement = ?, approval_signature = ?, approved_by_device_id = ?, approved_at = ?, pair_mac = ?, pair_lookup = NULL, pair_key_mac = NULL, pair_salt = NULL, pair_hub_origin = NULL, register_statement = NULL, code_expires_at = NULL WHERE device_id = ? AND user_id = ? AND status = 'pending';")
		if !ok do return 0, repo_err("failed to prepare the approval")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.approval_statement)
		bind_text(stmt, 2, cm.approval_signature)
		bind_text(stmt, 3, cm.approved_by_device_id)
		bind_text(stmt, 4, cm.now)
		bind_opt(stmt, 5, cm.approve_pair_mac)
		bind_text(stmt, 6, cm.approve_device_id)
		bind_text(stmt, 7, cm.user_id)
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return 0, repo_err("the approval failed")
		if changes != 1 do return conflict(conn, cm.user_id)
	}
	if cm.hint_retire_device_id != "" {
		stmt, ok := prepare(conn, "UPDATE vault_devices SET retired_at = COALESCE(retired_at, ?) WHERE device_id = ? AND user_id = ? AND status = 'approved' AND bridge_id = ? AND bridge_id != '';")
		if !ok do return 0, repo_err("failed to prepare the bridge retirement")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.now)
		bind_text(stmt, 2, cm.hint_retire_device_id)
		bind_text(stmt, 3, cm.user_id)
		bind_text(stmt, 4, cm.hint_retire_bridge_id)
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return 0, repo_err("the bridge retirement failed")
		if changes != 1 do return conflict(conn, cm.user_id)
	}
	if d, has := cm.insert_device.?; has {
		if d.user_id != cm.user_id || d.status != .Approved do return 0, domain.domain_error(.Validation_Failed, "an inserted device must be approved and belong to the directory owner")
		if !insert_device_on(conn, d) do return 0, domain.vault_reason_error(.Conflict, "device_exists", "this device key is already registered")
	}
	if cm.revoke_device_id != "" {
		stmt, ok := prepare(conn, "UPDATE vault_devices SET status = 'revoked', revocation_statement = ?, revocation_signature = ?, revoked_by_device_id = ?, revoked_at = ? WHERE device_id = ? AND user_id = ? AND status = 'approved';")
		if !ok do return 0, repo_err("failed to prepare the revocation")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.revocation_statement)
		bind_text(stmt, 2, cm.revocation_signature)
		bind_text(stmt, 3, cm.revoked_by_device_id)
		bind_text(stmt, 4, cm.now)
		bind_text(stmt, 5, cm.revoke_device_id)
		bind_text(stmt, 6, cm.user_id)
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return 0, repo_err("the revocation failed")
		if changes != 1 do return conflict(conn, cm.user_id)
	}
	if cm.new_epoch > 0 {
		if !insert_epoch_on(conn, cm.user_id, cm.new_epoch, cm.log_statement, cm.log_signature, cm.now) do return conflict(conn, cm.user_id)
	}
	if cm.label_device_id != "" {
		stmt, ok := prepare(conn, "UPDATE vault_devices SET label = ? WHERE device_id = ? AND user_id = ? AND status = 'approved';")
		if !ok do return 0, repo_err("failed to prepare the relabel")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.label)
		bind_text(stmt, 2, cm.label_device_id)
		bind_text(stmt, 3, cm.user_id)
		rc, changes := step_changes(conn.db, stmt)
		if rc != SQLITE_DONE do return 0, repo_err("the relabel failed")
		if changes != 1 do return conflict(conn, cm.user_id)
	}
	if cm.replace_all_wraps {
		stmt, ok := prepare(conn, "DELETE FROM vault_wrapped_keyrings WHERE user_id = ?;")
		if !ok do return 0, repo_err("failed to prepare the wrap reset")
		defer sqlite3_finalize(stmt)
		bind_text(stmt, 1, cm.user_id)
		if sqlite3_step(stmt) != SQLITE_DONE do return 0, repo_err("the wrap reset failed")
	}
	for w in cm.wraps {
		if w.user_id != cm.user_id do return 0, domain.domain_error(.Validation_Failed, "a wrap must belong to the directory owner")
		if !upsert_wrap_on(conn, w) do return 0, repo_err("failed to write a wrap")
	}
	new_version := cm.expected_version + 1
	if !exec(conn, "COMMIT;") do return 0, repo_err("failed to commit the vault directory")
	committed = true
	return new_version, domain.Domain_Error{}
}

// ── Owner reset ─────────────────────────────────────────────────────────────

@(private = "file")
get_reset_on :: proc(conn: ^Conn, user_id: string) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	stmt, ok := prepare(conn, "SELECT user_id, requested_at, due_at FROM vault_directory_resets WHERE user_id = ?;")
	if !ok do return {}, false, repo_err("failed to prepare vault reset read")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return {}, false, domain.Domain_Error{}
	if rc != SQLITE_ROW do return {}, false, repo_err("failed to read vault reset")
	return domain.Vault_Reset{user_id = column_text(stmt, 0), requested_at = column_text(stmt, 1), due_at = column_text(stmt, 2)}, true, domain.Domain_Error{}
}

vault_get_reset_sqlite :: proc(ctx: rawptr, user_id: string) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	return get_reset_on(impl.conn, user_id)
}

vault_schedule_reset_sqlite :: proc(ctx: rawptr, r: domain.Vault_Reset) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	if !exec(conn, "BEGIN IMMEDIATE;") do return {}, false, repo_err("failed to begin vault reset")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	if _, exists, err := get_directory_on(conn, r.user_id); err.code != .None {
		return {}, false, err
	} else if !exists {
		return {}, false, domain.domain_error(.Not_Found, "vault directory is not configured", `{"configured":false}`)
	}
	existing, found, rerr := get_reset_on(conn, r.user_id)
	if rerr.code != .None do return {}, false, rerr
	if found {
		if !exec(conn, "COMMIT;") do return {}, false, repo_err("failed to end vault reset")
		committed = true
		return existing, false, domain.Domain_Error{}
	}
	stmt, ok := prepare(conn, "INSERT INTO vault_directory_resets (user_id, requested_at, due_at) VALUES (?, ?, ?);")
	if !ok do return {}, false, repo_err("failed to prepare vault reset")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, r.user_id)
	bind_text(stmt, 2, r.requested_at)
	bind_text(stmt, 3, r.due_at)
	if sqlite3_step(stmt) != SQLITE_DONE do return {}, false, repo_err("failed to schedule vault reset")
	if !exec(conn, "COMMIT;") do return {}, false, repo_err("failed to commit vault reset")
	committed = true
	return r, true, domain.Domain_Error{}
}

vault_cancel_reset_sqlite :: proc(ctx: rawptr, user_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	stmt, ok := prepare(conn, "DELETE FROM vault_directory_resets WHERE user_id = ?;")
	if !ok do return false, repo_err("failed to prepare vault reset cancel")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, user_id)
	rc, changes := step_changes(conn.db, stmt)
	if rc != SQLITE_DONE do return false, repo_err("failed to cancel vault reset")
	return changes == 1, domain.Domain_Error{}
}

vault_list_due_resets_sqlite :: proc(ctx: rawptr, now: string) -> ([]string, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	stmt, ok := prepare(impl.conn, "SELECT user_id FROM vault_directory_resets WHERE due_at <= ? ORDER BY due_at;")
	if !ok do return nil, repo_err("failed to prepare due vault resets")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, now)
	out := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, repo_err("failed to list due vault resets")
		append(&out, column_text(stmt, 0))
	}
	return out[:], domain.Domain_Error{}
}

VAULT_RESET_DELETES :: [6]string{
	"DELETE FROM vault_log WHERE user_id = ?;",
	"DELETE FROM vault_wrapped_keyrings WHERE user_id = ?;",
	"DELETE FROM vault_epochs WHERE user_id = ?;",
	"DELETE FROM vault_devices WHERE user_id = ?;",
	"DELETE FROM vault_directories WHERE user_id = ?;",
	"DELETE FROM vault_directory_resets WHERE user_id = ?;",
}

vault_execute_reset_sqlite :: proc(ctx: rawptr, user_id, now: string) -> (bool, domain.Domain_Error) {
	impl := (^Vault_Directory_Repo_SQLite)(ctx)
	lock_tok := dbt.timed_lock(&impl.mutex, .Vault)
	defer dbt.timed_unlock(&impl.mutex, .Vault, lock_tok)
	conn := write_conn(impl)
	if !exec(conn, "BEGIN IMMEDIATE;") do return false, repo_err("failed to begin vault reset execution")
	committed := false
	defer if !committed do _ = exec(conn, "ROLLBACK;")
	r, found, rerr := get_reset_on(conn, user_id)
	if rerr.code != .None do return false, rerr
	if !found || r.due_at > now {
		if !exec(conn, "COMMIT;") do return false, repo_err("failed to end vault reset execution")
		committed = true
		return false, domain.Domain_Error{}
	}
	deletes := VAULT_RESET_DELETES
	for q in deletes {
		stmt, ok := prepare(conn, q)
		if !ok do return false, repo_err("failed to prepare vault reset execution")
		bind_text(stmt, 1, user_id)
		rc := sqlite3_step(stmt)
		sqlite3_finalize(stmt)
		if rc != SQLITE_DONE do return false, repo_err("vault reset execution failed")
	}
	if !exec(conn, "COMMIT;") do return false, repo_err("failed to commit vault reset execution")
	committed = true
	return true, domain.Domain_Error{}
}
