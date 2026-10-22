package sqlite

import "core:testing"
import domain "odin_test:hub/domain"

billing_test_database :: proc(t: ^testing.T, suffix: string) -> (Conn, string) {
	conn, path, ok := tmpl_open_file_prod(t, suffix)
	testing.expect(t, ok)
	migrated, migration_err := run_migrations(&conn, "/nonexistent/billing-migrations")
	testing.expect(t, migrated && migration_err.code == .None, "embedded migrations include billing")
	testing.expect(t, exec(&conn, `INSERT INTO users VALUES ('alice', 'alice', 'Alice', 'alice@example.com', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z'); INSERT INTO users VALUES ('bob', 'bob', 'Bob', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');`))
	return conn, path
}

@(test)
test_billing_persists_effective_parameters_and_custom_overrides :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path := billing_test_database(t, "persistence")
	defer tmpl_remove_db(path)
	defer close(&conn)
	impl: Billing_Repo_SQLite
	repo, err := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	first, first_err := repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	testing.expect_value(t, first_err.code, domain.Error_Code.None)
	testing.expect_value(t, first.entitlements.max_bridges, 1)
	testing.expect(t, first.entitlements.terminal_streaming_enabled)
	testing.expect(t, exec(&conn, `INSERT INTO billing_plans (plan_id, plan_label, price_id, max_bridges, terminal_streaming_enabled) VALUES ('bespoke', 'Custom agreement', NULL, 9, 1);
		UPDATE account_billing SET plan_id = 'bespoke', status = 'custom' WHERE user_id = 'alice';
		UPDATE account_entitlements SET override_max_bridges = 0, override_terminal_streaming_enabled = 0, override_terminal_input_enabled = 0, override_max_concurrent_streams = 0, override_shells_enabled = 0, override_reason = 'custom grant', override_updated_by = 'operator' WHERE user_id = 'alice';`))
	close(&impl.conn)
	repo, err = new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	defer close(&impl.conn)
	custom, custom_err := repo.get_account(repo.ctx, "alice", "2026-10-10T10:01:00Z")
	testing.expect_value(t, custom_err.code, domain.Error_Code.None)
	testing.expect_value(t, custom.plan_label, "Custom agreement")
	testing.expect_value(t, custom.entitlements.max_bridges, 0)
	testing.expect(t, !custom.entitlements.terminal_streaming_enabled, "false override survives restart")
	testing.expect(t, !custom.entitlements.terminal_input_enabled && !custom.entitlements.shells_enabled)
	testing.expect_value(t, custom.entitlements.max_concurrent_streams, 0)
	bob, bob_err := repo.get_account(repo.ctx, "bob", "2026-10-10T10:01:00Z")
	testing.expect_value(t, bob_err.code, domain.Error_Code.None)
	testing.expect_value(t, bob.entitlements.max_bridges, 1)
	testing.expect(t, bob.entitlements.terminal_streaming_enabled)
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_terminal_streaming_enabled = 1, override_reason = 'custom streaming grant', override_updated_by = 'operator' WHERE user_id = 'bob';"))
	granted, _ := repo.get_account(repo.ctx, "bob", "2026-10-10T10:02:00Z")
	testing.expect_value(t, granted.plan_id, "free")
	testing.expect(t, granted.entitlements.terminal_streaming_enabled, "parameters can grant a feature independently of tier")
}

@(test)
test_billing_webhook_ordering_deduplication_and_parameter_persistence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path := billing_test_database(t, "events")
	defer tmpl_remove_db(path); defer close(&conn)
	impl: Billing_Repo_SQLite
	repo, _ := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	defer close(&impl.conn)
	_, _ = repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	checkout, reserved, err := repo.reserve_checkout(repo.ctx, domain.Billing_Checkout{reference = "server_reference", user_id = "alice", plan_id = "hobbyist", price_id = "pri_hobbyist", expires_at = "2026-10-10T10:20:00Z"}, "2026-10-10T10:00:00Z")
	testing.expect(t, reserved && err.code == .None)
	checkout.transaction_id = "txn_test"
	testing.expect_value(t, repo.finish_checkout(repo.ctx, checkout).code, domain.Error_Code.None)
	event := domain.Billing_Event{event_id = "evt_active", event_type = "subscription.activated", occurred_ns = 200, checkout_reference = "server_reference", subscription_id = "sub_alice", customer_id = "ctm_alice", price_id = "pri_hobbyist", status = "active"}
	testing.expect_value(t, repo.apply_event(repo.ctx, event, "2026-10-10T10:01:00Z").code, domain.Error_Code.None)
	active, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:01:00Z")
	testing.expect(t, active.entitlements.terminal_streaming_enabled && active.entitlements.terminal_input_enabled && active.entitlements.shells_enabled)
	testing.expect_value(t, active.entitlements.max_concurrent_streams, -1)
	testing.expect(t, !active.checkout_pending)
	// A retry with the same event ID cannot mutate already-applied state.
	duplicate := event; duplicate.status = "canceled"; duplicate.occurred_ns = 300
	testing.expect_value(t, repo.apply_event(repo.ctx, duplicate, "2026-10-10T10:02:00Z").code, domain.Error_Code.None)
	stale := event; stale.event_id = "evt_old"; stale.status = "canceled"; stale.occurred_ns = 100
	testing.expect_value(t, repo.apply_event(repo.ctx, stale, "2026-10-10T10:02:00Z").code, domain.Error_Code.None)
	still_active, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:02:00Z")
	testing.expect_value(t, still_active.status, "active")
	bad := event; bad.event_id = "evt_unknown_price"; bad.occurred_ns = 400; bad.price_id = "pri_unapproved"
	testing.expect_value(t, repo.apply_event(repo.ctx, bad, "2026-10-10T10:03:00Z").code, domain.Error_Code.Validation_Failed)
	_, recorded := billing_scalar(&impl, "SELECT event_id FROM billing_events WHERE event_id = 'evt_unknown_price';")
	testing.expect(t, !recorded, "failed webhook rolls back dedup record for retry")
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_max_bridges = 7 WHERE user_id = 'alice';"))
	canceled := event; canceled.event_id = "evt_cancel"; canceled.occurred_ns = 500; canceled.status = "canceled"
	testing.expect_value(t, repo.apply_event(repo.ctx, canceled, "2026-10-10T10:04:00Z").code, domain.Error_Code.None)
	close(&impl.conn)
	repo, _ = new_billing_repository(&impl, path, "sandbox", "pri_new_hobbyist", true)
	final, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:05:00Z")
	testing.expect_value(t, final.entitlements.max_bridges, 7)
	testing.expect(t, final.entitlements.terminal_streaming_enabled, "free retains view-only streaming after cancellation")
	resumed := event; resumed.event_id = "evt_resume_old_price"; resumed.occurred_ns = 600
	testing.expect_value(t, repo.apply_event(repo.ctx, resumed, "2026-10-10T10:06:00Z").code, domain.Error_Code.None)
	historical, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:06:00Z")
	testing.expect(t, historical.entitlements.terminal_streaming_enabled, "existing subscriptions retain approved historical prices")
}

@(test)
test_billing_grace_expiry_does_not_extend_on_updates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path := billing_test_database(t, "grace")
	defer tmpl_remove_db(path); defer close(&conn)
	impl: Billing_Repo_SQLite
	repo, _ := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	defer close(&impl.conn)
	_, _ = repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	testing.expect(t, exec(&conn, "UPDATE account_billing SET subscription_id = 'sub_alice', customer_id = 'ctm_alice' WHERE user_id = 'alice';"))
	event := domain.Billing_Event{event_id = "evt_due", event_type = "subscription.past_due", occurred_ns = 100, subscription_id = "sub_alice", customer_id = "ctm_alice", price_id = "pri_hobbyist", status = "past_due", grace_until = "2026-10-11T10:00:00Z"}
	testing.expect_value(t, repo.apply_event(repo.ctx, event, "2026-10-10T10:00:00Z").code, domain.Error_Code.None)
	in_grace, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T11:00:00Z")
	testing.expect(t, in_grace.entitlements.terminal_input_enabled && in_grace.entitlements.shells_enabled)
	testing.expect_value(t, in_grace.entitlements.max_concurrent_streams, -1)
	event.event_id = "evt_due_update"; event.occurred_ns = 200; event.grace_until = "2026-10-14T10:00:00Z"
	testing.expect_value(t, repo.apply_event(repo.ctx, event, "2026-10-11T09:00:00Z").code, domain.Error_Code.None)
	expired, _ := repo.get_account(repo.ctx, "alice", "2026-10-11T10:00:01Z")
	testing.expect_value(t, expired.grace_until, "2026-10-11T10:00:00Z")
	testing.expect(t, expired.entitlements.terminal_streaming_enabled)
	testing.expect(t, !expired.entitlements.terminal_input_enabled && !expired.entitlements.shells_enabled)
	testing.expect_value(t, expired.entitlements.max_concurrent_streams, 2)
	persisted, _ := billing_scalar(&impl, "SELECT terminal_streaming_enabled FROM account_entitlements WHERE user_id = 'alice';")
	testing.expect_value(t, persisted, "1")
}

@(test)
test_billing_checkout_reservations_and_environment_guard :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path := billing_test_database(t, "reservation")
	defer tmpl_remove_db(path); defer close(&conn)
	impl: Billing_Repo_SQLite
	repo, _ := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	defer close(&impl.conn)
	_, _ = repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	input := domain.Billing_Checkout{reference = "first", user_id = "alice", plan_id = "hobbyist", price_id = "pri_hobbyist", expires_at = "2026-10-10T10:20:00Z"}
	saved, fresh, err := repo.reserve_checkout(repo.ctx, input, "2026-10-10T10:00:00Z")
	testing.expect(t, fresh && err.code == .None)
	_, _, busy := repo.reserve_checkout(repo.ctx, input, "2026-10-10T10:01:00Z")
	testing.expect_value(t, busy.code, domain.Error_Code.Conflict)
	saved.transaction_id = "txn_existing"
	testing.expect_value(t, repo.finish_checkout(repo.ctx, saved).code, domain.Error_Code.None)
	reused, is_new, reuse_err := repo.reserve_checkout(repo.ctx, input, "2026-10-10T10:02:00Z")
	testing.expect(t, !is_new && reuse_err.code == .None)
	testing.expect_value(t, reused.transaction_id, "txn_existing")
	other: Billing_Repo_SQLite
	_, environment_err := new_billing_repository(&other, path, "live", "pri_live", true)
	testing.expect_value(t, environment_err.code, domain.Error_Code.Validation_Failed)
}

@(test)
test_free_one_bridge_migration_updates_existing_accounts_preserves_paid_and_custom :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    conn, path := billing_test_database(t, "free_limit_migration")
    defer tmpl_remove_db(path); defer close(&conn)
    testing.expect(t, exec(&conn, `UPDATE billing_plans SET max_bridges = 2 WHERE plan_id = 'free';
        UPDATE account_entitlements SET max_bridges = 2;
        UPDATE account_entitlements SET override_max_bridges = 5 WHERE user_id = 'bob';
        INSERT INTO users VALUES ('carol', 'carol', 'Carol', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
        UPDATE account_billing SET plan_id = 'hobbyist', status = 'active' WHERE user_id = 'carol';`))
    testing.expect(t, exec(&conn, MIGRATION_070_FREE_ONE_BRIDGE))
    impl: Billing_Repo_SQLite
    repo, _ := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
    defer close(&impl.conn)
    alice, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
    bob, _ := repo.get_account(repo.ctx, "bob", "2026-10-10T10:00:00Z")
    carol, _ := repo.get_account(repo.ctx, "carol", "2026-10-10T10:00:00Z")
    testing.expect_value(t, alice.entitlements.max_bridges, 1)
    testing.expect_value(t, bob.entitlements.max_bridges, 5)
    testing.expect_value(t, carol.entitlements.max_bridges, 2)
}

@(test)
test_plan_enforcement_migration_upgrades_snapshots_defaults_and_preserves_overrides :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "plan_enforcement_upgrade")
	testing.expect(t, ok)
	defer tmpl_remove_db(path); defer close(&conn)
	migrated, migration_err := run_migrations(&conn, "/nonexistent/migrations", "103_plan_enforcement.sql")
	testing.expect(t, migrated && migration_err.code == .None)
	testing.expect(t, exec(&conn, `INSERT INTO users VALUES
		('free_user', 'free_user', 'Free', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z'),
		('paid_user', 'paid_user', 'Paid', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z'),
		('override_user', 'override_user', 'Override', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z'),
		('expired_user', 'expired_user', 'Expired', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z'),
		('grace_user', 'grace_user', 'Grace', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
		UPDATE account_billing SET plan_id = 'hobbyist', status = 'active' WHERE user_id = 'paid_user';
		UPDATE account_billing SET plan_id = 'hobbyist', status = 'past_due', grace_until = '2000-01-01T00:00:00Z' WHERE user_id = 'expired_user';
		UPDATE account_billing SET plan_id = 'hobbyist', status = 'past_due', grace_until = '2999-01-01T00:00:00Z' WHERE user_id = 'grace_user';
		UPDATE account_entitlements SET override_max_bridges = 0, override_terminal_streaming_enabled = 0, override_reason = 'keep agreement', override_updated_by = 'operator' WHERE user_id = 'override_user';`))
	migrated, migration_err = run_migrations(&conn, "/nonexistent/migrations")
	testing.expect(t, migrated && migration_err.code == .None)
	testing.expect(t, table_column_exists(&conn, "bridges", "plan_disabled_at"))
	impl: Billing_Repo_SQLite
	repo, repo_err := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	testing.expect_value(t, repo_err.code, domain.Error_Code.None)
	defer close(&impl.conn)
	// Inspect snapshots before get_account can recompute them.
	paid_snapshot, _ := billing_scalar(&impl, "SELECT terminal_input_enabled || ':' || max_concurrent_streams || ':' || shells_enabled FROM account_entitlements WHERE user_id = 'paid_user';")
	testing.expect_value(t, paid_snapshot, "1:-1:1")
	expired_snapshot, _ := billing_scalar(&impl, "SELECT terminal_input_enabled || ':' || max_concurrent_streams || ':' || shells_enabled FROM account_entitlements WHERE user_id = 'expired_user';")
	testing.expect_value(t, expired_snapshot, "0:2:0")
	grace_snapshot, _ := billing_scalar(&impl, "SELECT terminal_input_enabled FROM account_entitlements WHERE user_id = 'grace_user';")
	testing.expect_value(t, grace_snapshot, "1")
	overridden, _ := repo.get_account(repo.ctx, "override_user", "2026-10-10T10:00:00Z")
	testing.expect_value(t, overridden.entitlements.max_bridges, 0)
	testing.expect(t, !overridden.entitlements.terminal_streaming_enabled)
	reason, _ := billing_scalar(&impl, "SELECT override_reason || ':' || override_updated_by FROM account_entitlements WHERE user_id = 'override_user';")
	testing.expect_value(t, reason, "keep agreement:operator")
	testing.expect(t, exec(&conn, "INSERT INTO users VALUES ('fresh', 'fresh', 'Fresh', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');"))
	fresh_snapshot, _ := billing_scalar(&impl, "SELECT max_bridges || ':' || terminal_streaming_enabled || ':' || terminal_input_enabled || ':' || max_concurrent_streams || ':' || shells_enabled FROM account_entitlements WHERE user_id = 'fresh';")
	testing.expect_value(t, fresh_snapshot, "1:1:0:2:0")
	// All new nullable overrides preserve explicit false/zero (zero is restrictive).
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_terminal_input_enabled = 0, override_max_concurrent_streams = 0, override_shells_enabled = 0 WHERE user_id = 'paid_user';"))
	paid, _ := repo.get_account(repo.ctx, "paid_user", "2026-10-10T10:00:00Z")
	testing.expect(t, !paid.entitlements.terminal_input_enabled && !paid.entitlements.shells_enabled)
	testing.expect_value(t, paid.entitlements.max_concurrent_streams, 0)
	plans, plans_err := repo.list_plans(repo.ctx)
	testing.expect_value(t, plans_err.code, domain.Error_Code.None)
	for plan in plans {
		if plan.plan_id == "free" {
			testing.expect_value(t, plan.entitlements.max_bridges, 1)
			testing.expect(t, plan.entitlements.terminal_streaming_enabled && !plan.entitlements.terminal_input_enabled && !plan.entitlements.shells_enabled)
			testing.expect_value(t, plan.entitlements.max_concurrent_streams, 2)
		}
		if plan.plan_id == "hobbyist" {
			testing.expect_value(t, plan.entitlements.max_bridges, 2)
			testing.expect(t, plan.entitlements.terminal_input_enabled && plan.entitlements.shells_enabled)
			testing.expect_value(t, plan.entitlements.max_concurrent_streams, -1)
		}
	}
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_max_concurrent_streams = -1 WHERE user_id = 'paid_user';"))
	unlimited, unlimited_err := repo.get_account(repo.ctx, "paid_user", "2026-10-10T10:00:00Z")
	testing.expect_value(t, unlimited_err.code, domain.Error_Code.None)
	testing.expect_value(t, unlimited.entitlements.max_concurrent_streams, -1)
	testing.expect(t, !exec(&conn, "UPDATE account_entitlements SET override_max_concurrent_streams = -2 WHERE user_id = 'paid_user';"))
	// Simulate a crash after SQL commit but before the migration ledger write.
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version = '103_plan_enforcement.sql';"))
	again, again_err := run_migrations(&conn, "/nonexistent/migrations")
	testing.expect(t, again && again_err.code == .None)
}
