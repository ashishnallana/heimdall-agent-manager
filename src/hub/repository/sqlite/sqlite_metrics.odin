package sqlite

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import metrics "odin_test:lib/metrics"

// SQLite storage metrics (hub telemetry plan 3.8).
//
// Every statement in this package executes through sqlite3_step or
// sqlite3_exec, so those two FFI symbols are bound as *_raw in conn.odin and
// the Odin procs below (same names, same signatures) wrap them. Repositories
// are untouched; they keep calling sqlite3_step / sqlite3_exec.
//
// What is measured:
//   - heimdall_sqlite_query_duration_seconds{op}: wall time of ONE step or
//     exec call. A SELECT that yields N rows is observed N+1 times (one per
//     step), so `_count` is "step calls", not "statements"; `_sum` is still
//     the total time spent inside SQLite. `op` is the leading SQL keyword
//     (fixed enum, unknown -> other) and never the SQL text.
//   - heimdall_sqlite_busy_total: step/exec calls that came back SQLITE_BUSY
//     or SQLITE_LOCKED. With `PRAGMA busy_timeout` set, this fires only after
//     the in-library retry loop gave up, i.e. it counts real lock stalls.
//   - heimdall_sqlite_db_bytes / heimdall_sqlite_wal_bytes: collector that
//     stats the tracked database file and its -wal sidecar at scrape time.
//     The path is recorded by open() (reference counted across the main and
//     billing connections, which share one file) and released by close().
//
// Allocator rules: nothing here allocates on the hot path. The tracked path is
// cloned on the runtime heap (never context.allocator — open() is called from
// build_graph but also from tests with tracking allocators).

Sqlite_Metrics :: struct {
	query_duration: ^metrics.Family, // {op}
	busy_total:     ^metrics.Series,
}

sqlite_metrics: Sqlite_Metrics

SQLITE_DURATION_BUCKETS := [?]f64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.5, 1}

SQLITE_BUSY :: 5
SQLITE_LOCKED :: 6

@(private = "file")
tracked_path_mu: sync.Mutex
@(private = "file")
tracked_path: string // heap clone, "" when nothing is open
@(private = "file")
tracked_path_refs: int
@(private = "file")
collector_registered: bool

sqlite_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	m := &sqlite_metrics
	m.query_duration = metrics.new_histogram_seconds(reg, "heimdall_sqlite_query_duration_seconds",
		"Wall time of one sqlite3_step/sqlite3_exec call, by leading SQL keyword.", {"op"}, SQLITE_DURATION_BUCKETS[:])
	m.busy_total = metrics.with(metrics.new_counter(reg, "heimdall_sqlite_busy_total",
		"Statements that failed with SQLITE_BUSY or SQLITE_LOCKED after the busy_timeout retry loop."))
	if !collector_registered {
		collector_registered = true
		metrics.registry_add_collector(reg, nil, sqlite_size_collect)
	}
}

// ---------------------------------------------------------------------------
// FFI wrappers. Same signature as the raw symbols so call sites are unchanged.

sqlite3_step :: proc(pStmt: sqlite3_stmt) -> c.int {
	start := time.tick_now()
	rc := sqlite3_step_raw(pStmt)
	sqlite_metrics_record(sqlite3_sql(pStmt), rc, time.tick_since(start))
	return rc
}

sqlite3_exec :: proc(db: sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: [^]cstring) -> c.int {
	start := time.tick_now()
	rc := sqlite3_exec_raw(db, sql, callback, arg, errmsg)
	sqlite_metrics_record(sql, rc, time.tick_since(start))
	return rc
}

// sqlite_metrics_record never touches context.allocator: the metrics package
// uses its own registry allocator for series creation and atomics otherwise.
@(private = "file")
sqlite_metrics_record :: proc(sql: cstring, rc: c.int, elapsed: time.Duration) {
	m := &sqlite_metrics
	if m.query_duration == nil && m.busy_total == nil do return
	metrics.observe_duration(metrics.with(m.query_duration, sqlite_op_from_sql(sql)), elapsed)
	code := rc & 0xff // primary result code (extended codes keep it in the low byte)
	if code == SQLITE_BUSY || code == SQLITE_LOCKED do metrics.counter_inc(m.busy_total)
}

// sqlite_op_from_sql classifies by the first SQL keyword, skipping leading
// whitespace, `--` line comments and `/* */` block comments. Reads at most a
// few dozen bytes and never past the NUL. Fixed enum: anything else is "other".
sqlite_op_from_sql :: proc "contextless" (sql: cstring) -> string {
	if sql == nil do return "other"
	p := ([^]u8)(sql)
	i := 0
	// Skip whitespace and comments (bounded so a pathological prefix cannot spin).
	for i < 4096 {
		ch := p[i]
		if ch == 0 do return "other"
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i += 1; continue }
		if ch == '-' && p[i+1] == '-' {
			i += 2
			for p[i] != 0 && p[i] != '\n' do i += 1
			continue
		}
		if ch == '/' && p[i+1] == '*' {
			i += 2
			for p[i] != 0 && !(p[i] == '*' && p[i+1] == '/') do i += 1
			if p[i] != 0 do i += 2
			continue
		}
		break
	}
	// Copy the keyword (letters only), lower-cased, into a small buffer.
	buf: [12]u8
	n := 0
	for n < len(buf) {
		ch := p[i+n]
		if ch >= 'A' && ch <= 'Z' do ch += 'a' - 'A'
		if ch < 'a' || ch > 'z' do break
		buf[n] = ch
		n += 1
	}
	switch string(buf[:n]) {
	case "select", "insert", "update", "delete", "begin", "commit", "rollback", "pragma", "create":
		return sqlite_op_intern(buf[:n])
	case "with":
		return "select"
	case "replace":
		return "insert"
	case "end":
		return "commit"
	}
	return "other"
}

// sqlite_op_intern maps a matched keyword back to a static string so the label
// value never points into the caller's stack buffer.
@(private = "file")
sqlite_op_intern :: proc "contextless" (kw: []u8) -> string {
	switch string(kw) {
	case "select":   return "select"
	case "insert":   return "insert"
	case "update":   return "update"
	case "delete":   return "delete"
	case "begin":    return "begin"
	case "commit":   return "commit"
	case "rollback": return "rollback"
	case "pragma":   return "pragma"
	case "create":   return "create"
	}
	return "other"
}

// ---------------------------------------------------------------------------
// Database file size collector.

// sqlite_metrics_track_path remembers the file behind an opened connection.
// Reference counted: the hub opens the same file twice (main + billing).
sqlite_metrics_track_path :: proc(path: string) {
	if path == "" || path == ":memory:" do return
	sync.lock(&tracked_path_mu)
	defer sync.unlock(&tracked_path_mu)
	if tracked_path == "" {
		tracked_path = strings.clone(path, runtime.heap_allocator())
		tracked_path_refs = 1
		return
	}
	if tracked_path == path do tracked_path_refs += 1
}

sqlite_metrics_untrack_path :: proc(path: string) {
	sync.lock(&tracked_path_mu)
	defer sync.unlock(&tracked_path_mu)
	if tracked_path == "" || tracked_path != path do return
	tracked_path_refs -= 1
	if tracked_path_refs <= 0 {
		delete(tracked_path, runtime.heap_allocator())
		tracked_path = ""
		tracked_path_refs = 0
	}
}

// sqlite_metrics_set_db_path overrides the tracked file explicitly (the app
// may call it with config.database_path; tests use it to pin a known file).
// An empty path clears tracking.
sqlite_metrics_set_db_path :: proc(path: string) {
	sync.lock(&tracked_path_mu)
	defer sync.unlock(&tracked_path_mu)
	if tracked_path != "" do delete(tracked_path, runtime.heap_allocator())
	tracked_path = ""
	tracked_path_refs = 0
	if path == "" do return
	tracked_path = strings.clone(path, runtime.heap_allocator())
	tracked_path_refs = 1
}

// sqlite_metrics_tracked_path copies the tracked path into `buf` (for the
// collector and tests). Returns "" when nothing is tracked or it does not fit.
sqlite_metrics_tracked_path :: proc(buf: []u8) -> string {
	sync.lock(&tracked_path_mu)
	defer sync.unlock(&tracked_path_mu)
	if tracked_path == "" || len(tracked_path) > len(buf) do return ""
	copy(buf, tracked_path)
	return string(buf[:len(tracked_path)])
}

@(private = "file")
sqlite_size_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	path_buf: [4096]u8
	path := sqlite_metrics_tracked_path(path_buf[:4096 - len("-wal")])
	if path == "" do return
	if size, ok := sqlite_file_size(path); ok {
		metrics.expo_header(e, "heimdall_sqlite_db_bytes", "Size of the hub SQLite database file.", .Gauge)
		metrics.expo_sample_i64(e, "heimdall_sqlite_db_bytes", nil, nil, size)
	}
	// Append "-wal" in place; the buffer was sized to leave room for it.
	n := len(path)
	copy(path_buf[n:], "-wal")
	wal_size, wal_ok := sqlite_file_size(string(path_buf[:n + 4]))
	if !wal_ok do wal_size = 0 // no WAL file = nothing pending; still expose 0
	metrics.expo_header(e, "heimdall_sqlite_wal_bytes", "Size of the hub SQLite write-ahead log (0 when absent).", .Gauge)
	metrics.expo_sample_i64(e, "heimdall_sqlite_wal_bytes", nil, nil, wal_size)
}

// sqlite_file_size stats a path with a stack cstring and no allocation (this
// runs on the metrics thread, which never resets a temp arena).
sqlite_file_size :: proc(path: string) -> (i64, bool) {
	cbuf: [4096 + 1]u8
	if len(path) >= len(cbuf) do return 0, false
	copy(cbuf[:], path)
	cbuf[len(path)] = 0
	st: posix.stat_t
	if posix.stat(cstring(raw_data(cbuf[:])), &st) != .OK do return 0, false
	return i64(st.st_size), true
}
