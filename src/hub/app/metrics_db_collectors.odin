package app

import "core:c"
import "core:fmt"
import "core:sync"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import sqlite "odin_test:hub/repository/sqlite"
import metrics "odin_test:lib/metrics"

// DB-backed collectors (hub telemetry plan 3.8): heimdall_users,
// heimdall_users_active{window}, heimdall_bridges{status},
// heimdall_subscriptions{plan,state}. Re-queried at most once per
// DB_COLLECTORS_CACHE_TTL; scrapes in between re-emit the cached snapshot.
//
// Design:
//   - A DEDICATED read-only SQLite connection, opened by db_collectors_attach
//     from build_graph (after migrations) and closed by db_collectors_detach
//     from shutdown_graph. The metrics thread therefore never touches the
//     request-shared graph.db handle, and the swappable state is a package
//     global guarded by a mutex rather than a pointer into an App_Graph (tests
//     build and destroy many graphs per process).
//   - No allocation on the scrape path: every label value is a static enum
//     string and the snapshot is a fixed-size struct. The collector runs on the
//     metrics thread, which never resets a temp arena.
//   - users_active counts DISTINCT owners seen in the window via either a
//     bridge heartbeat (bridges.last_seen_at) or a user API token use
//     (user_api_tokens.last_used_at); `users` has no last-seen column of its
//     own. Timestamps are the hub's fixed-width RFC3339 UTC form, so a string
//     compare against a formatted cutoff is a correct ordering.

DB_COLLECTORS_CACHE_TTL :: 60 * time.Second

@(private = "file")
Plan :: enum u8 { Free, Hobbyist, Other }
@(private = "file")
PLAN_LABELS := [Plan]string{.Free = "free", .Hobbyist = "hobbyist", .Other = "other"}

@(private = "file")
Sub_State :: enum u8 { Free, Active, Trialing, Past_Due, Paused, Canceled, Custom, Other }
@(private = "file")
SUB_STATE_LABELS := [Sub_State]string{
	.Free = "free", .Active = "active", .Trialing = "trialing", .Past_Due = "past_due",
	.Paused = "paused", .Canceled = "canceled", .Custom = "custom", .Other = "other",
}

@(private = "file")
Bridge_State :: enum u8 { Online, Offline, Revoked, Other }
@(private = "file")
BRIDGE_STATE_LABELS := [Bridge_State]string{.Online = "online", .Offline = "offline", .Revoked = "revoked", .Other = "other"}

@(private = "file")
ACTIVE_WINDOW_LABELS := [3]string{"1d", "7d", "30d"}
@(private = "file")
ACTIVE_WINDOW_SECONDS := [3]i64{86_400, 7 * 86_400, 30 * 86_400}

Db_Collector_Snapshot :: struct {
	users:         i64,
	users_active:  [3]i64,
	bridges:       [Bridge_State]i64,
	subscriptions: [Plan][Sub_State]i64,
}

@(private = "file")
Db_Collector_State :: struct {
	mu:          sync.Mutex,
	attached:    bool,
	conn:        sqlite.Conn,
	have_cache:  bool,
	cached_at:   time.Tick,
	snapshot:    Db_Collector_Snapshot,
	registered:  bool,
}

@(private = "file")
db_collectors: Db_Collector_State

db_collectors_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	sync.lock(&db_collectors.mu)
	defer sync.unlock(&db_collectors.mu)
	if db_collectors.registered do return
	db_collectors.registered = true
	metrics.registry_add_collector(reg, nil, db_collectors_collect)
}

// db_collectors_attach opens the dedicated read-only connection. Call after
// migrations have run. Returns false (hub keeps running; the families are
// simply absent from scrapes) if the file cannot be opened.
db_collectors_attach :: proc(db_path: string) -> bool {
	if db_path == "" do return false
	conn, ok, _ := sqlite.open(db_path, .Metrics)
	if !ok do return false
	_ = sqlite.exec(&conn, "PRAGMA query_only = 1;")
	_ = sqlite.exec(&conn, "PRAGMA busy_timeout = 1000;")
	sync.lock(&db_collectors.mu)
	defer sync.unlock(&db_collectors.mu)
	if db_collectors.attached do sqlite.close(&db_collectors.conn)
	db_collectors.conn = conn
	db_collectors.attached = true
	db_collectors.have_cache = false
	return true
}

// db_collectors_detach closes the connection and drops the cache. Safe to call
// when nothing is attached. Blocks until any in-progress scrape query finishes.
db_collectors_detach :: proc() {
	sync.lock(&db_collectors.mu)
	defer sync.unlock(&db_collectors.mu)
	if db_collectors.attached do sqlite.close(&db_collectors.conn)
	db_collectors.attached = false
	db_collectors.have_cache = false
}

// db_collectors_invalidate forces the next scrape to re-query (tests).
db_collectors_invalidate :: proc() {
	sync.lock(&db_collectors.mu)
	defer sync.unlock(&db_collectors.mu)
	db_collectors.have_cache = false
}

@(private = "file")
db_collectors_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	dbt.scope_begin(.Scrape)
	defer dbt.scope_end()
	lock_tok := dbt.timed_lock(&db_collectors.mu, .Collector)
	defer dbt.timed_unlock(&db_collectors.mu, .Collector, lock_tok)
	s := &db_collectors
	if !s.attached do return
	if !s.have_cache || time.tick_since(s.cached_at) >= DB_COLLECTORS_CACHE_TTL {
		if !db_collectors_query(&s.conn, &s.snapshot, time.now()) do return
		s.have_cache = true
		s.cached_at = time.tick_now()
	}
	db_collectors_emit(e, &s.snapshot)
}

// db_collectors_query fills `out` from `conn`. `now` parameterised for tests.
// Exported within the package so a test can drive it against a fixture DB.
db_collectors_query :: proc(conn: ^sqlite.Conn, out: ^Db_Collector_Snapshot, now: time.Time) -> bool {
	if conn == nil || conn.db == nil do return false
	snap: Db_Collector_Snapshot

	users, users_ok := db_scalar_i64(conn, "SELECT COUNT(*) FROM users;")
	if !users_ok do return false
	snap.users = users

	for window, i in ACTIVE_WINDOW_SECONDS {
		cutoff_buf: [32]u8
		cutoff := format_rfc3339_into(cutoff_buf[:], time.time_add(now, time.Duration(-window) * time.Second))
		active, active_ok := db_scalar_i64(conn,
			"SELECT COUNT(*) FROM (SELECT owner_user_id FROM bridges WHERE last_seen_at >= ?1 UNION SELECT owner_user_id FROM user_api_tokens WHERE last_used_at >= ?1);",
			cutoff)
		if !active_ok do return false
		snap.users_active[i] = active
	}

	{
		stmt, ok := db_prepare(conn, "SELECT status, COUNT(*) FROM bridges GROUP BY status;")
		if !ok do return false
		defer sqlite.sqlite3_finalize(stmt)
		for sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW {
			state := bridge_state_enum(sqlite.column_text_unowned(stmt, 0))
			snap.bridges[state] += sqlite.sqlite3_column_int64(stmt, 1)
		}
	}
	{
		stmt, ok := db_prepare(conn, "SELECT plan_id, status, COUNT(*) FROM account_billing GROUP BY plan_id, status;")
		if !ok do return false
		defer sqlite.sqlite3_finalize(stmt)
		for sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW {
			plan := plan_enum(sqlite.column_text_unowned(stmt, 0))
			state := sub_state_enum(sqlite.column_text_unowned(stmt, 1))
			snap.subscriptions[plan][state] += sqlite.sqlite3_column_int64(stmt, 2)
		}
	}
	out^ = snap
	return true
}

@(private = "file")
db_collectors_emit :: proc(e: ^metrics.Exposition, s: ^Db_Collector_Snapshot) {
	metrics.expo_header(e, "heimdall_users", "Registered users.", .Gauge)
	metrics.expo_sample_i64(e, "heimdall_users", nil, nil, s.users)

	metrics.expo_header(e, "heimdall_users_active", "Distinct users with a bridge heartbeat or API token use inside the window.", .Gauge)
	for label, i in ACTIVE_WINDOW_LABELS {
		metrics.expo_sample_i64(e, "heimdall_users_active", {"window"}, {label}, s.users_active[i])
	}

	metrics.expo_header(e, "heimdall_bridges", "Enrolled bridges by durable status.", .Gauge)
	for state in Bridge_State {
		if state == .Other && s.bridges[state] == 0 do continue
		metrics.expo_sample_i64(e, "heimdall_bridges", {"status"}, {BRIDGE_STATE_LABELS[state]}, s.bridges[state])
	}

	wrote_header := false
	for plan in Plan {
		for state in Sub_State {
			n := s.subscriptions[plan][state]
			if n == 0 do continue
			if !wrote_header {
				metrics.expo_header(e, "heimdall_subscriptions", "Billing accounts by plan and subscription state (populated combinations only).", .Gauge)
				wrote_header = true
			}
			metrics.expo_sample_i64(e, "heimdall_subscriptions", {"plan", "state"}, {PLAN_LABELS[plan], SUB_STATE_LABELS[state]}, n)
		}
	}
}

// ---------------------------------------------------------------------------
// Enum mappers (unknown -> other).

@(private = "file")
plan_enum :: proc(plan_id: string) -> Plan {
	switch plan_id {
	case "free":     return .Free
	case "hobbyist": return .Hobbyist
	}
	return .Other
}

@(private = "file")
sub_state_enum :: proc(status: string) -> Sub_State {
	switch status {
	case "free":     return .Free
	case "active":   return .Active
	case "trialing": return .Trialing
	case "past_due": return .Past_Due
	case "paused":   return .Paused
	case "canceled": return .Canceled
	case "custom":   return .Custom
	}
	return .Other
}

@(private = "file")
bridge_state_enum :: proc(status: string) -> Bridge_State {
	switch status {
	case "online":  return .Online
	case "offline": return .Offline
	case "revoked": return .Revoked
	}
	return .Other
}

// ---------------------------------------------------------------------------
// Allocation-free SQLite helpers. SQL must be a literal (NUL-terminated in the
// binary), matching the convention the repositories rely on.

@(private = "file")
db_prepare :: proc(conn: ^sqlite.Conn, sql: string) -> (sqlite.sqlite3_stmt, bool) {
	stmt: sqlite.sqlite3_stmt
	if sqlite.sqlite3_prepare_v2(conn.db, cstring(raw_data(sql)), c.int(len(sql)), &stmt, nil) != sqlite.SQLITE_OK do return nil, false
	return stmt, true
}

@(private = "file")
db_scalar_i64 :: proc(conn: ^sqlite.Conn, sql: string, args: ..string) -> (i64, bool) {
	stmt, ok := db_prepare(conn, sql)
	if !ok do return 0, false
	defer sqlite.sqlite3_finalize(stmt)
	for arg, i in args do sqlite.bind_text(stmt, i + 1, arg)
	if sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW do return 0, false
	return sqlite.sqlite3_column_int64(stmt, 0), true
}

// format_rfc3339_into writes the hub's canonical "YYYY-MM-DDTHH:MM:SSZ" into
// buf without allocating (platform.format_rfc3339_utc uses the temp arena).
@(private = "file")
format_rfc3339_into :: proc(buf: []u8, t: time.Time) -> string {
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	return fmt.bprintf(buf, "%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}
