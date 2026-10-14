package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sqlite "odin_test:hub/repository/sqlite"
import metrics "odin_test:lib/metrics"

// Fixture: migrated hub DB with two users, three bridges, two billing rows and
// one API token. `now` is pinned so the activity windows are deterministic.
@(private = "file")
DBC_NOW :: "2026-10-10T12:00:00Z"

@(private = "file")
dbc_fixture :: proc(t: ^testing.T, suffix: string) -> (sqlite.Conn, string) {
	path := strings.clone(fmt.tprintf("/tmp/heimdall_dbc_%s_%d.db", suffix, os.get_pid()))
	_ = os.remove(path)
	conn, ok, err := sqlite.open(path)
	testing.expect(t, ok && err.code == .None, "open fixture db")
	migrated, migration_err := sqlite.run_migrations(&conn, "/nonexistent/migrations")
	testing.expect(t, migrated && migration_err.code == .None, "embedded migrations apply")
	testing.expect(t, sqlite.exec(&conn, `
		INSERT INTO users VALUES ('alice', 'alice', 'Alice', 'a@example.com', 'active', '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z');
		INSERT INTO users VALUES ('bob',   'bob',   'Bob',   '',              'active', '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z');
		INSERT INTO users VALUES ('carol', 'carol', 'Carol', '',              'active', '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z');
		-- alice: bridge seen 2h ago (1d/7d/30d); bob: bridge seen 3 days ago (7d/30d); carol: token used 20 days ago (30d).
		INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at, last_seen_at) VALUES ('br-a', 'alice', 'online',  '2026-09-01T00:00:00Z', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
		INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at, last_seen_at) VALUES ('br-b', 'bob',   'offline', '2026-09-01T00:00:00Z', '2026-10-07T12:00:00Z', '2026-10-07T12:00:00Z');
		INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at, last_seen_at, revoked_at) VALUES ('br-c', 'bob', 'revoked', '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z', '2026-09-01T12:00:00Z', '2026-09-02T00:00:00Z');
		INSERT INTO bridges (bridge_id, owner_user_id, status, created_at, updated_at, last_seen_at) VALUES ('br-d', 'alice', 'weird',   '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '');
		INSERT INTO user_api_tokens (token_id, owner_user_id, token_hash, created_at, updated_at, last_used_at) VALUES ('tok-c', 'carol', 'sha1:c', '2026-09-01T00:00:00Z', '2026-09-20T12:00:00Z', '2026-09-20T12:00:00Z');
		-- users_billing_defaults trigger already inserted a free/free row per user.
		UPDATE account_billing SET plan_id = 'hobbyist', status = 'active' WHERE user_id = 'alice';
		INSERT INTO billing_plans VALUES ('bespoke', 'Custom', NULL, 9, 1);
		UPDATE account_billing SET plan_id = 'bespoke', status = 'mystery' WHERE user_id = 'carol';
	`), "seed fixture rows")
	return conn, path
}

@(test)
test_db_collectors_query_snapshot :: proc(t: ^testing.T) {
	conn, path := dbc_fixture(t, "query")
	defer { sqlite.close(&conn); _ = os.remove(path); delete(path) }
	now, _ := time.rfc3339_to_time_utc(DBC_NOW)

	snap: Db_Collector_Snapshot
	testing.expect(t, db_collectors_query(&conn, &snap, now), "query succeeds")
	testing.expect_value(t, snap.users, i64(3))
	testing.expect_value(t, snap.users_active[0], i64(1)) // 1d: alice
	testing.expect_value(t, snap.users_active[1], i64(2)) // 7d: alice, bob
	testing.expect_value(t, snap.users_active[2], i64(3)) // 30d: + carol via token
	testing.expect_value(t, snap.bridges[.Online], i64(1))
	testing.expect_value(t, snap.bridges[.Offline], i64(1))
	testing.expect_value(t, snap.bridges[.Revoked], i64(1))
	testing.expect_value(t, snap.bridges[.Other], i64(1))
	testing.expect_value(t, snap.subscriptions[.Hobbyist][.Active], i64(1))
	testing.expect_value(t, snap.subscriptions[.Free][.Free], i64(1))
	testing.expect_value(t, snap.subscriptions[.Other][.Other], i64(1))
}

@(test)
test_db_collectors_attach_exposes_and_caches :: proc(t: ^testing.T) {
	reg := metrics.init_global()
	db_collectors_init(reg)
	conn, path := dbc_fixture(t, "attach")
	defer { sqlite.close(&conn); _ = os.remove(path); delete(path) }

	testing.expect(t, db_collectors_attach(path), "attach opens the collector connection")
	defer db_collectors_detach()

	gather := proc(reg: ^metrics.Registry) -> string {
		b := strings.builder_make()
		metrics.gather(reg, &b)
		return strings.to_string(b)
	}
	out := gather(reg)
	defer delete(out)
	testing.expect(t, strings.contains(out, "heimdall_users 3\n"), "users exposed")
	testing.expect(t, strings.contains(out, "heimdall_users_active{window=\"1d\"} "), "users_active window label")
	testing.expect(t, strings.contains(out, "heimdall_bridges{status=\"online\"} 1\n"), "bridges online")
	testing.expect(t, strings.contains(out, "heimdall_bridges{status=\"other\"} 1\n"), "bridges unknown status -> other")
	testing.expect(t, strings.contains(out, "heimdall_subscriptions{plan=\"hobbyist\",state=\"active\"} 1\n"), "subscriptions populated combo")
	testing.expect(t, !strings.contains(out, "plan=\"hobbyist\",state=\"paused\""), "empty combos are not emitted")

	// A write inside the TTL is NOT visible (cached); invalidating re-queries.
	testing.expect(t, sqlite.exec(&conn, "INSERT INTO users VALUES ('dave', 'dave', 'Dave', '', 'active', '2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z');"), "insert")
	cached := gather(reg)
	defer delete(cached)
	testing.expect(t, strings.contains(cached, "heimdall_users 3\n"), "snapshot served from cache within 60 s")
	db_collectors_invalidate()
	fresh := gather(reg)
	defer delete(fresh)
	testing.expect(t, strings.contains(fresh, "heimdall_users 4\n"), "re-queried after invalidation")

	// After detach nothing is emitted.
	db_collectors_detach()
	gone := gather(reg)
	defer delete(gone)
	testing.expect(t, !strings.contains(gone, "heimdall_users "), "detached collector emits nothing")
}
