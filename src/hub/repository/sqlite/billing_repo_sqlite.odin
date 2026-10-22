package sqlite

import "core:c"
import "core:fmt"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// A dedicated connection and mutex keep billing transactions isolated from
// unrelated hub requests using the main repository connection.
Billing_Repo_SQLite :: struct {
	conn: Conn,
	mutex: sync.Mutex,
}

billing_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "billing storage operation failed")
}

billing_prepare :: proc(impl: ^Billing_Repo_SQLite, query: string, args: []string = nil) -> sqlite3_stmt {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return nil
	for arg, i in args do bind_text(stmt, i+1, arg)
	return stmt
}

billing_write :: proc(impl: ^Billing_Repo_SQLite, query: string, args: []string = nil) -> bool {
	stmt := billing_prepare(impl, query, args)
	if stmt == nil do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_DONE
}

billing_scalar :: proc(impl: ^Billing_Repo_SQLite, query: string, args: []string = nil) -> (string, bool) {
	stmt := billing_prepare(impl, query, args)
	if stmt == nil do return "", false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW do return column_text(stmt, 0), true
	return "", false
}

new_billing_repository :: proc(impl: ^Billing_Repo_SQLite, path, environment, hobbyist_price: string, configured: bool) -> (iface.Billing_Repository, domain.Domain_Error) {
	conn, ok, err := open(path)
	if !ok do return {}, err
	impl.conn = conn
	_ = exec(&impl.conn, "PRAGMA busy_timeout = 5000;")
	if configured {
		saved_env, found := billing_scalar(impl, "SELECT value FROM billing_settings WHERE key = 'paddle_environment';")
		if found && saved_env != environment {
			close(&impl.conn)
			return {}, domain.domain_error(.Validation_Failed, "Paddle environment differs from the billing database; use a separate sandbox database")
		}
		if !billing_write(impl, "INSERT OR IGNORE INTO billing_settings VALUES ('paddle_environment', ?);", {environment}) {
			close(&impl.conn); return {}, billing_error()
		}
	}
	if hobbyist_price != "" {
		existing_plan, known := billing_scalar(impl, "SELECT plan_id FROM billing_plan_prices WHERE price_id = ?;", {hobbyist_price})
		if known && existing_plan != "hobbyist" {
			close(&impl.conn); return {}, domain.domain_error(.Validation_Failed, "Paddle price is already mapped to another plan")
		}
		if !billing_write(impl, "INSERT OR IGNORE INTO billing_plan_prices (price_id, plan_id) VALUES (?, 'hobbyist');", {hobbyist_price}) {
			close(&impl.conn); return {}, billing_error()
		}
	}
	if !billing_write(impl, "UPDATE billing_plans SET price_id = NULLIF(?, '') WHERE plan_id = 'hobbyist';", {hobbyist_price}) {
		close(&impl.conn); return {}, billing_error()
	}
	return iface.Billing_Repository{ctx = impl, get_account = billing_get_account, list_plans = billing_list_plans,
		reserve_checkout = billing_reserve_checkout, finish_checkout = billing_finish_checkout, apply_event = billing_apply_event}, {}
}

billing_refresh_parameters :: proc(impl: ^Billing_Repo_SQLite, user_id, now: string) -> bool {
	// Explicit 0/false overrides survive COALESCE and all subscription updates.
	return billing_write(impl, `UPDATE account_entitlements SET
		max_bridges = COALESCE(override_max_bridges, (SELECT p.max_bridges FROM account_billing b JOIN billing_plans p ON p.plan_id = CASE WHEN b.status IN ('active', 'trialing', 'custom') OR (b.status = 'past_due' AND b.grace_until > ?) THEN b.plan_id ELSE 'free' END WHERE b.user_id = ?)),
		terminal_streaming_enabled = COALESCE(override_terminal_streaming_enabled, (SELECT p.terminal_streaming_enabled FROM account_billing b JOIN billing_plans p ON p.plan_id = CASE WHEN b.status IN ('active', 'trialing', 'custom') OR (b.status = 'past_due' AND b.grace_until > ?) THEN b.plan_id ELSE 'free' END WHERE b.user_id = ?)),
		terminal_input_enabled = COALESCE(override_terminal_input_enabled, (SELECT p.terminal_input_enabled FROM account_billing b JOIN billing_plans p ON p.plan_id = CASE WHEN b.status IN ('active', 'trialing', 'custom') OR (b.status = 'past_due' AND b.grace_until > ?) THEN b.plan_id ELSE 'free' END WHERE b.user_id = ?)),
		max_concurrent_streams = COALESCE(override_max_concurrent_streams, (SELECT p.max_concurrent_streams FROM account_billing b JOIN billing_plans p ON p.plan_id = CASE WHEN b.status IN ('active', 'trialing', 'custom') OR (b.status = 'past_due' AND b.grace_until > ?) THEN b.plan_id ELSE 'free' END WHERE b.user_id = ?)),
		shells_enabled = COALESCE(override_shells_enabled, (SELECT p.shells_enabled FROM account_billing b JOIN billing_plans p ON p.plan_id = CASE WHEN b.status IN ('active', 'trialing', 'custom') OR (b.status = 'past_due' AND b.grace_until > ?) THEN b.plan_id ELSE 'free' END WHERE b.user_id = ?)),
		updated_at = ? WHERE user_id = ?;`, {now, user_id, now, user_id, now, user_id, now, user_id, now, user_id, now, user_id})
}

billing_ensure_account :: proc(impl: ^Billing_Repo_SQLite, user_id, now: string) -> bool {
	return billing_write(impl, "INSERT OR IGNORE INTO account_billing (user_id, created_at, updated_at) VALUES (?, ?, ?);", {user_id, now, now}) &&
		billing_write(impl, "INSERT OR IGNORE INTO account_entitlements (user_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, updated_at) SELECT ?, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, ? FROM billing_plans WHERE plan_id = 'free';", {user_id, now}) &&
		billing_refresh_parameters(impl, user_id, now)
}

billing_get_account :: proc(ctx: rawptr, user_id, now: string) -> (domain.Account_Billing, domain.Domain_Error) {
	impl := (^Billing_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	if !exec(&impl.conn, "BEGIN IMMEDIATE;") do return {}, billing_error()
	committed := false
	defer if !committed do _ = exec(&impl.conn, "ROLLBACK;")
	if !billing_ensure_account(impl, user_id, now) do return {}, billing_error()
	stmt := billing_prepare(impl, `SELECT b.user_id, b.plan_id, p.plan_label, b.status, b.customer_id, b.subscription_id, b.price_id, b.renews_at, b.cancels_at, b.grace_until, b.last_event_ns, e.max_bridges, e.terminal_streaming_enabled, b.created_at, b.updated_at, e.terminal_input_enabled, e.max_concurrent_streams, e.shells_enabled
		FROM account_billing b JOIN billing_plans p ON p.plan_id = b.plan_id JOIN account_entitlements e ON e.user_id = b.user_id WHERE b.user_id = ?;`, {user_id})
	if stmt == nil do return {}, billing_error()
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return {}, billing_error()
	account := domain.Account_Billing{user_id = column_text(stmt, 0), plan_id = column_text(stmt, 1), plan_label = column_text(stmt, 2), status = column_text(stmt, 3), customer_id = column_text(stmt, 4), subscription_id = column_text(stmt, 5), price_id = column_text(stmt, 6), renews_at = column_text(stmt, 7), cancels_at = column_text(stmt, 8), grace_until = column_text(stmt, 9), last_event_ns = i64(int_v(column_text_unowned(stmt, 10))), entitlements = {max_bridges = int_v(column_text_unowned(stmt, 11)), terminal_streaming_enabled = column_text_unowned(stmt, 12) == "1", terminal_input_enabled = column_text_unowned(stmt, 15) == "1", max_concurrent_streams = int_v(column_text_unowned(stmt, 16)), shells_enabled = column_text_unowned(stmt, 17) == "1"}, created_at = column_text(stmt, 13), updated_at = column_text(stmt, 14)}
	_, account.checkout_pending = billing_scalar(impl, "SELECT reference FROM billing_checkouts WHERE user_id = ? AND expires_at > ? LIMIT 1;", {user_id, now})
	committed = exec(&impl.conn, "COMMIT;")
	if !committed do return {}, billing_error()
	return account, {}
}

billing_list_plans :: proc(ctx: rawptr) -> ([]domain.Billing_Plan, domain.Domain_Error) {
	impl := (^Billing_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	stmt := billing_prepare(impl, "SELECT plan_id, plan_label, price_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled FROM billing_plans ORDER BY plan_id;")
	if stmt == nil do return nil, billing_error()
	defer sqlite3_finalize(stmt)
	plans := make([dynamic]domain.Billing_Plan, context.temp_allocator)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW do return nil, billing_error()
		append(&plans, domain.Billing_Plan{plan_id = column_text(stmt, 0), plan_label = column_text(stmt, 1), price_id = column_text(stmt, 2), entitlements = {max_bridges = int_v(column_text_unowned(stmt, 3)), terminal_streaming_enabled = column_text_unowned(stmt, 4) == "1", terminal_input_enabled = column_text_unowned(stmt, 5) == "1", max_concurrent_streams = int_v(column_text_unowned(stmt, 6)), shells_enabled = column_text_unowned(stmt, 7) == "1"}})
	}
	return plans[:], {}
}

billing_reserve_checkout :: proc(ctx: rawptr, checkout: domain.Billing_Checkout, now: string) -> (domain.Billing_Checkout, bool, domain.Domain_Error) {
	impl := (^Billing_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	if !exec(&impl.conn, "BEGIN IMMEDIATE;") do return {}, false, billing_error()
	committed := false
	defer if !committed do _ = exec(&impl.conn, "ROLLBACK;")
	_, allowed := billing_scalar(impl, "SELECT user_id FROM account_billing WHERE user_id = ? AND status != 'custom' AND (subscription_id IS NULL OR status = 'canceled');", {checkout.user_id})
	if !allowed do return {}, false, domain.domain_error(.Conflict, "account already has a subscription")
	// The write transaction also protects reservations across hub processes.
	stmt := billing_prepare(impl, "SELECT reference, plan_id, price_id, transaction_id, expires_at FROM billing_checkouts WHERE user_id = ? AND expires_at > ? ORDER BY expires_at DESC LIMIT 1;", {checkout.user_id, now})
	if stmt == nil do return {}, false, billing_error()
	if sqlite3_step(stmt) == SQLITE_ROW {
		existing := domain.Billing_Checkout{reference = column_text(stmt, 0), user_id = checkout.user_id, plan_id = column_text(stmt, 1), price_id = column_text(stmt, 2), transaction_id = column_text(stmt, 3), expires_at = column_text(stmt, 4)}
		sqlite3_finalize(stmt)
		if existing.price_id != checkout.price_id || existing.transaction_id == "" do return {}, false, domain.domain_error(.Conflict, "a checkout is already being prepared; retry shortly")
		committed = exec(&impl.conn, "COMMIT;")
		if !committed do return {}, false, billing_error()
		return existing, false, {}
	}
	sqlite3_finalize(stmt)
	if !billing_write(impl, "INSERT INTO billing_checkouts (reference, user_id, plan_id, price_id, expires_at) VALUES (?, ?, ?, ?, ?);", {checkout.reference, checkout.user_id, checkout.plan_id, checkout.price_id, checkout.expires_at}) do return {}, false, billing_error()
	committed = exec(&impl.conn, "COMMIT;")
	if !committed do return {}, false, billing_error()
	return checkout, true, {}
}

billing_finish_checkout :: proc(ctx: rawptr, checkout: domain.Billing_Checkout) -> domain.Domain_Error {
	impl := (^Billing_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	if !billing_write(impl, "UPDATE billing_checkouts SET transaction_id = ? WHERE reference = ? AND user_id = ?;", {checkout.transaction_id, checkout.reference, checkout.user_id}) do return billing_error()
	return {}
}

billing_apply_event :: proc(ctx: rawptr, event: domain.Billing_Event, now: string) -> domain.Domain_Error {
	impl := (^Billing_Repo_SQLite)(ctx)
	sync.mutex_lock(&impl.mutex); defer sync.mutex_unlock(&impl.mutex)
	if !exec(&impl.conn, "BEGIN IMMEDIATE;") do return billing_error()
	committed := false
	defer if !committed do _ = exec(&impl.conn, "ROLLBACK;")
	if _, duplicate := billing_scalar(impl, "SELECT event_id FROM billing_events WHERE event_id = ?;", {event.event_id}); duplicate {
		committed = exec(&impl.conn, "COMMIT;")
		if !committed do return billing_error()
		return {}
	}
	owner, found := billing_scalar(impl, "SELECT user_id FROM account_billing WHERE subscription_id = ?;", {event.subscription_id})
	if !found && event.checkout_reference != "" {
		owner, found = billing_scalar(impl, "SELECT user_id FROM billing_checkouts WHERE reference = ?;", {event.checkout_reference})
	}
	if !found do return domain.domain_error(.Conflict, "subscription has no server-created account checkout mapping")
	stored_ns, _ := billing_scalar(impl, "SELECT CAST(last_event_ns AS TEXT) FROM account_billing WHERE user_id = ?;", {owner})
	if event.occurred_ns > i64(int_v(stored_ns)) {
		customer, _ := billing_scalar(impl, "SELECT COALESCE(customer_id, '') FROM account_billing WHERE user_id = ?;", {owner})
		if customer != "" && customer != event.customer_id do return domain.domain_error(.Conflict, "subscription customer does not match account")
		existing_sub, _ := billing_scalar(impl, "SELECT COALESCE(subscription_id, '') FROM account_billing WHERE user_id = ? AND status NOT IN ('free', 'canceled', 'paused');", {owner})
		if existing_sub != "" && existing_sub != event.subscription_id do return domain.domain_error(.Conflict, "account already has another subscription")
		plan_id, known := billing_scalar(impl, "SELECT plan_id FROM billing_plan_prices WHERE price_id = ? UNION SELECT plan_id FROM billing_plans WHERE price_id = ? LIMIT 1;", {event.price_id, event.price_id})
		if !known do return domain.domain_error(.Validation_Failed, "subscription price is not in the approved plan catalog")
		grace_until := event.grace_until
		if event.status == "past_due" {
			existing_grace, already_past_due := billing_scalar(impl, "SELECT grace_until FROM account_billing WHERE user_id = ? AND status = 'past_due';", {owner})
			if already_past_due do grace_until = existing_grace
		}
		if !billing_write(impl, `UPDATE account_billing SET plan_id = ?, status = ?, customer_id = ?, subscription_id = ?, price_id = ?, renews_at = ?, cancels_at = ?, grace_until = ?, last_event_ns = ?, updated_at = ? WHERE user_id = ?;`, {plan_id, event.status, event.customer_id, event.subscription_id, event.price_id, event.renews_at, event.cancels_at, grace_until, fmt.tprintf("%d", event.occurred_ns), now, owner}) || !billing_refresh_parameters(impl, owner, now) do return billing_error()
		if !billing_write(impl, "UPDATE billing_checkouts SET expires_at = ? WHERE user_id = ?;", {now, owner}) do return billing_error()
	}
	if !billing_write(impl, "INSERT INTO billing_events VALUES (?, ?, ?, ?, ?);", {event.event_id, event.event_type, fmt.tprintf("%d", event.occurred_ns), event.subscription_id, now}) do return billing_error()
	committed = exec(&impl.conn, "COMMIT;")
	if !committed do return billing_error()
	return {}
}
