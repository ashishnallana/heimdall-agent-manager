package sqlite

import "core:c"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// CARD_COLUMNS is the single column list every card SELECT uses, in the order
// card_from_stmt reads them.
CARD_COLUMNS :: "card_id, owner_user_id, project_id, title, rationale, scope, provider, confidence, source_refs_json, status, operations_json, guard_json, snooze_until, ttl_at, created_at, updated_at, kind, attention_since, source_marker, details_json, action_refs_json"

Card_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_card_repository :: proc(impl: ^Card_Repo_SQLite, conn: ^Conn) -> iface.Card_Repository {
	impl.conn = conn
	return iface.Card_Repository{
		ctx = rawptr(impl),
		create = card_create_sqlite,
		get = card_get_sqlite,
		list = card_list_sqlite,
		list_by_project = card_list_by_project_sqlite,
		update_status = card_update_status_sqlite,
		update = card_update_sqlite,
		delete_card = card_delete_sqlite,
	}
}

card_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Card {
	card: domain.Card
	card.card_id = domain.Card_ID(column_text(stmt, 0))
	card.owner_user_id = domain.User_ID(column_text(stmt, 1))
	card.project_id = domain.Project_ID(column_text(stmt, 2))
	card.title = column_text(stmt, 3)
	card.rationale = column_text(stmt, 4)
	card.scope = column_text(stmt, 5)
	if card.scope == "" do card.scope = "project"
	card.provider = column_text(stmt, 6)
	card.confidence = f32(sqlite3_column_double(stmt, 7))
	card.source_refs_json = column_text(stmt, 8)
	if card.source_refs_json == "" do card.source_refs_json = "[]"
	card.status = column_text(stmt, 9)
	if card.status == "" do card.status = "pending"
	card.operations_json = column_text(stmt, 10)
	if card.operations_json == "" do card.operations_json = "[]"
	card.guard_json = column_text(stmt, 11)
	if card.guard_json == "" do card.guard_json = "{}"
	card.snooze_until = column_text(stmt, 12)
	card.ttl_at = column_text(stmt, 13)
	card.created_at = column_text(stmt, 14)
	card.updated_at = column_text(stmt, 15)
	card.kind = column_text(stmt, 16)
	if card.kind == "" do card.kind = domain.card_kind_for_provider(card.provider)
	card.attention_since = column_text(stmt, 17)
	if card.attention_since == "" do card.attention_since = card.created_at
	card.source_marker = column_text(stmt, 18)
	card.details_json = column_text(stmt, 19)
	if card.details_json == "" do card.details_json = "{}"
	card.action_refs_json = column_text(stmt, 20)
	if card.action_refs_json == "" do card.action_refs_json = "{}"
	return card
}

// card_normalized fills the defaults every write path stores, so the value a
// write returns always equals what a later read yields.
card_normalized :: proc(card: domain.Card) -> domain.Card {
	n := card
	if n.scope == "" do n.scope = "project"
	if n.source_refs_json == "" do n.source_refs_json = "[]"
	if n.status == "" do n.status = "pending"
	if n.operations_json == "" do n.operations_json = "[]"
	if n.guard_json == "" do n.guard_json = "{}"
	if n.kind == "" do n.kind = domain.card_kind_for_provider(n.provider)
	if n.attention_since == "" do n.attention_since = n.created_at
	if n.details_json == "" do n.details_json = "{}"
	if n.action_refs_json == "" do n.action_refs_json = "{}"
	return n
}

bind_card_insert :: proc(stmt: sqlite3_stmt, card: domain.Card) {
	n := card_normalized(card)
	bind_text(stmt, 1, string(n.card_id))
	bind_text(stmt, 2, string(n.owner_user_id))
	bind_text(stmt, 3, string(n.project_id))
	bind_text(stmt, 4, n.title)
	bind_text(stmt, 5, n.rationale)
	bind_text(stmt, 6, n.scope)
	bind_text(stmt, 7, n.provider)
	sqlite3_bind_double(stmt, 8, c.double(n.confidence))
	bind_text(stmt, 9, n.source_refs_json)
	bind_text(stmt, 10, n.status)
	bind_text(stmt, 11, n.operations_json)
	bind_text(stmt, 12, n.guard_json)
	bind_text(stmt, 13, n.snooze_until)
	bind_text(stmt, 14, n.ttl_at)
	bind_text(stmt, 15, n.created_at)
	bind_text(stmt, 16, n.updated_at)
	bind_text(stmt, 17, n.kind)
	bind_text(stmt, 18, n.attention_since)
	bind_text(stmt, 19, n.source_marker)
	bind_text(stmt, 20, n.details_json)
	bind_text(stmt, 21, n.action_refs_json)
}

card_create_sqlite :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `INSERT INTO cards (
		card_id, owner_user_id, project_id, title, rationale, scope,
		provider, confidence, source_refs_json, status, operations_json,
		guard_json, snooze_until, ttl_at, created_at, updated_at,
		kind, attention_since, source_marker, details_json, action_refs_json
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card insert")
	}
	defer sqlite3_finalize(stmt)

	bind_card_insert(stmt, card)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return domain.Card{}, false, domain.domain_error(.Conflict, "card could not be saved")
	}
	return card_normalized(card), true, domain.Domain_Error{}
}

card_get_sqlite :: proc(ctx: rawptr, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
	}
	return card_from_stmt(stmt), true, domain.Domain_Error{}
}

card_list_sqlite :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Card, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE owner_user_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare card list")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner_user_id))

	items := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, card_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

card_list_by_project_sqlite :: proc(ctx: rawptr, project_id: domain.Project_ID) -> ([]domain.Card, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "SELECT " + CARD_COLUMNS + " FROM cards WHERE project_id = ? ORDER BY created_at DESC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare card list by project")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(project_id))

	items := make([dynamic]domain.Card)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, card_from_stmt(stmt))
	}
	return items[:], domain.Domain_Error{}
}

card_update_status_sqlite :: proc(ctx: rawptr, id: domain.Card_ID, status: string, updated_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE cards SET status = ?, updated_at = ? WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare card update status")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, status)
	bind_text(stmt, 2, updated_at)
	bind_text(stmt, 3, string(id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to update card status")
	}
	return row_changes > 0, domain.Domain_Error{}
}

card_update_sqlite :: proc(ctx: rawptr, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := `UPDATE cards SET
		title = ?, rationale = ?, scope = ?, provider = ?, confidence = ?,
		source_refs_json = ?, status = ?, operations_json = ?, guard_json = ?,
		snooze_until = ?, ttl_at = ?, updated_at = ?,
		kind = ?, attention_since = ?, source_marker = ?, details_json = ?, action_refs_json = ?
		WHERE card_id = ?;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to prepare card update")
	}
	defer sqlite3_finalize(stmt)

	n := card_normalized(card)
	bind_card_update_fields(stmt, n)
	bind_text(stmt, 18, string(n.card_id))

	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return domain.Card{}, false, domain.domain_error(.Internal_Error, "failed to update card")
	}
	if row_changes == 0 {
		return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
	}
	return n, true, domain.Domain_Error{}
}

// bind_card_update_fields binds the 17 mutable columns (positions 1..17) shared
// by card_update_sqlite and the projector's compare-and-set update.
bind_card_update_fields :: proc(stmt: sqlite3_stmt, n: domain.Card) {
	bind_text(stmt, 1, n.title)
	bind_text(stmt, 2, n.rationale)
	bind_text(stmt, 3, n.scope)
	bind_text(stmt, 4, n.provider)
	sqlite3_bind_double(stmt, 5, c.double(n.confidence))
	bind_text(stmt, 6, n.source_refs_json)
	bind_text(stmt, 7, n.status)
	bind_text(stmt, 8, n.operations_json)
	bind_text(stmt, 9, n.guard_json)
	bind_text(stmt, 10, n.snooze_until)
	bind_text(stmt, 11, n.ttl_at)
	bind_text(stmt, 12, n.updated_at)
	bind_text(stmt, 13, n.kind)
	bind_text(stmt, 14, n.attention_since)
	bind_text(stmt, 15, n.source_marker)
	bind_text(stmt, 16, n.details_json)
	bind_text(stmt, 17, n.action_refs_json)
}

card_delete_sqlite :: proc(ctx: rawptr, id: domain.Card_ID) -> (bool, domain.Domain_Error) {
	impl := (^Card_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM cards WHERE card_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare card delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(id))
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete card")
	}
	return row_changes > 0, domain.Domain_Error{}
}
