package dbtelemetry

import "core:fmt"
import "core:sync"
import metrics "odin_test:lib/metrics"

// DB latency and lock-contention telemetry (docs/reference/db-telemetry.md,
// plan docs/plans/db-latency-telemetry.md §2).
//
// Leaf package: service packages time their DB-guarding mutexes through
// timed_lock / timed_unlock without importing repository/sqlite, and the
// sqlite wrappers feed the same per-thread accumulators.
//
// Per thread, the intervals app_lock_wait, conn_wait and exec never overlap, so
// the scope / per-request component totals may be summed. Hold durations
// contain the holder's waits and execution and are kept in separate families.
//
// HEIMDALL_DB_TELEMETRY=basic is the default. =off registers nothing, and every
// proc below reduces to the plain operation it wraps (one atomic load of `mode`).

// Off stays the zero value so test binaries and tools that never run
// configure_db_telemetry keep the plain wrappers; the hub sets Basic at boot
// unless HEIMDALL_DB_TELEMETRY=off.
Mode :: enum u8 {
	Off,
	Basic,
}

Lock :: enum u8 {
	Uow_Tx,
	Billing,
	Vault,
	Enroll,
	Collector,
	Projector,
	Reconfig,
	Launch_Prefs,
	Conn_Main,
	Conn_Billing,
	Conn_Enroll,
	Conn_Vault,
	Conn_Metrics,
}

LOCK_LABELS := [Lock]string {
	.Uow_Tx       = "uow_tx",
	.Billing      = "billing",
	.Vault        = "vault",
	.Enroll       = "enroll",
	.Collector    = "collector",
	.Projector    = "projector",
	.Reconfig     = "reconfig",
	.Launch_Prefs = "launch_prefs",
	.Conn_Main    = "conn_main",
	.Conn_Billing = "conn_billing",
	.Conn_Enroll  = "conn_enroll",
	.Conn_Vault   = "conn_vault",
	.Conn_Metrics = "conn_metrics",
}

// App locks have a hold histogram and a held gauge; connection mutexes do not
// (their hold time is heimdall_sqlite_exec_seconds).
is_app_lock :: proc "contextless" (l: Lock) -> bool { return l < .Conn_Main }

Component :: enum u8 {
	App_Lock_Wait,
	Conn_Wait,
	Exec_Excl_Busy,
	Busy_Wait, // phase 2 only; always 0 in basic mode
}

COMPONENT_LABELS := [Component]string {
	.App_Lock_Wait  = "app_lock_wait",
	.Conn_Wait      = "conn_wait",
	.Exec_Excl_Busy = "exec_excl_busy",
	.Busy_Wait      = "busy_wait",
}

Scope :: enum u8 {
	Other,
	Http,
	Ws,
	Timer,
	Merge,
	Bridge_Log,
	Shell,
	Scrape,
}

SCOPE_LABELS := [Scope]string {
	.Other      = "other",
	.Http       = "http",
	.Ws         = "ws",
	.Timer      = "timer",
	.Merge      = "merge",
	.Bridge_Log = "bridge_log",
	.Shell      = "shell",
	.Scrape     = "scrape",
}

// lib/metrics caps histograms at 10 buckets (cardinality guard), so these are
// the plan's §2.2 layouts thinned to 10 bounds, keeping the decision points:
// 1 us floor, the 1 ms "waited" line, and the 5 s busy_timeout ceiling (wait);
// 30 s for pathological units of work (hold / tx).
LOCK_WAIT_BUCKETS := [?]f64{1e-6, 1e-5, 1e-4, 5e-4, 1e-3, 5e-3, 0.025, 0.1, 1, 5}
HOLD_BUCKETS := [?]f64{1e-4, 1e-3, 5e-3, 0.025, 0.1, 0.5, 1, 5, 10, 30}

@(private)
mode_value: u8 // Mode; read with an atomic load on every hot-path call

mode :: #force_inline proc "contextless" () -> Mode {
	return Mode(sync.atomic_load_explicit(&mode_value, .Relaxed))
}

enabled :: #force_inline proc "contextless" () -> bool { return mode() != .Off }

// parse_mode maps HEIMDALL_DB_TELEMETRY. "" (unset) means basic, the default;
// "off" is the explicit opt-out. "full" (the phase-2 busy handler) is NOT
// implemented and is rejected explicitly, as is any other value, so a typo
// never silently enables or disables telemetry.
parse_mode :: proc(value: string) -> (m: Mode, ok: bool, message: string) {
	switch value {
	case "off":
		return .Off, true, ""
	case "", "basic":
		return .Basic, true, ""
	case "full":
		return .Off, false, "HEIMDALL_DB_TELEMETRY=full (busy-handler instrumentation) is not implemented in this release; use off or basic"
	}
	return .Off, false, "HEIMDALL_DB_TELEMETRY must be off or basic"
}

// set_mode must run before init and before any DB handle is opened (boot, or
// test setup). Changing it at runtime is not supported.
set_mode :: proc "contextless" (m: Mode) {
	sync.atomic_store(&mode_value, u8(m))
}

// ---------------------------------------------------------------------------
// Metric families (pre-resolved series, never metrics.with on the hot path).

Telemetry_Metrics :: struct {
	initialised:    bool,
	lock_wait:      [Lock]^metrics.Series,
	lock_hold:      [Lock]^metrics.Series, // app locks only
	waiters:        [Lock]^metrics.Series,
	contended:      [Lock]^metrics.Series,
	held:           [Lock]^metrics.Series, // app locks only
	scope_seconds:  [Scope][Component]^metrics.Series,
	slow_dropped:   [Slow_Reason]^metrics.Series,
	// High-water mark of waiters since the previous scrape (collector resets it).
	waiters_max:    [Lock]i64,
}

tm: Telemetry_Metrics

@(private)
init_mu: sync.Mutex

// init registers the lock / scope families. No-op when mode is off (so `off`
// exposes exactly the legacy families) and idempotent.
init :: proc(reg: ^metrics.Registry) {
	if reg == nil || !enabled() do return
	sync.lock(&init_mu)
	defer sync.unlock(&init_mu)
	if tm.initialised do return
	wait := metrics.new_histogram_seconds(reg, "heimdall_db_lock_wait_seconds",
		"Time spent waiting to acquire a DB-guarding lock (app mutex or SQLite connection mutex).", {"lock"}, LOCK_WAIT_BUCKETS[:])
	hold := metrics.new_histogram_seconds(reg, "heimdall_db_lock_hold_seconds",
		"Time a DB-guarding application lock was held (contains the holder's waits and execution; never add to wait).", {"lock"}, HOLD_BUCKETS[:])
	waiters := metrics.new_gauge(reg, "heimdall_db_lock_waiters",
		"Threads currently waiting for the lock (instantaneous; sampled at scrape).", {"lock"})
	contended := metrics.new_counter(reg, "heimdall_db_lock_contended_total",
		"Acquisitions that found the lock held by another thread.", {"lock"})
	held := metrics.new_gauge(reg, "heimdall_db_lock_held",
		"1 while the application lock is held.", {"lock"})
	for l in Lock {
		tm.lock_wait[l] = metrics.with(wait, LOCK_LABELS[l])
		tm.waiters[l] = metrics.with(waiters, LOCK_LABELS[l])
		tm.contended[l] = metrics.with(contended, LOCK_LABELS[l])
		if is_app_lock(l) {
			tm.lock_hold[l] = metrics.with(hold, LOCK_LABELS[l])
			tm.held[l] = metrics.with(held, LOCK_LABELS[l])
		}
	}
	scope := metrics.new_counter(reg, "heimdall_db_scope_seconds_total",
		"DB time per scope by disjoint component (app_lock_wait, conn_wait, exec_excl_busy, busy_wait).", {"scope", "component"}, 9)
	for s in Scope do for c in Component do tm.scope_seconds[s][c] = metrics.with(scope, SCOPE_LABELS[s], COMPONENT_LABELS[c])
	dropped := metrics.new_counter(reg, "heimdall_db_slow_log_dropped_total",
		"db_slow_request / db_slow_scope records dropped by the rate limiter.", {"reason"})
	for r in Slow_Reason do tm.slow_dropped[r] = metrics.with(dropped, SLOW_REASON_LABELS[r])
	metrics.registry_add_collector(reg, nil, waiters_max_collect)
	tm.initialised = true
}

// waiters_max_collect exposes the per-lock high-water mark of `waiters` since
// the previous scrape and resets it to the current depth. Correct with ONE
// scraper; a second scraper splits the maximum (lower bound).
@(private)
waiters_max_collect :: proc(ctx: rawptr, e: ^metrics.Exposition) {
	if !tm.initialised do return
	names := []string{"lock"}
	metrics.expo_header(e, "heimdall_db_lock_waiters_max", "High-water mark of lock waiters since the previous scrape (reset on scrape).", .Gauge)
	for l in Lock {
		values := []string{LOCK_LABELS[l]}
		metrics.expo_sample_i64(e, "heimdall_db_lock_waiters_max", names, values, waiters_max_take(l))
	}
}

// waiters_max_take returns the high-water mark since the last take and resets
// it to the current waiter count (what the scrape collector exposes).
waiters_max_take :: proc "contextless" (l: Lock) -> i64 {
	current := sync.atomic_load(&tm.waiters[l].gauge) if tm.waiters[l] != nil else 0
	peak := sync.atomic_exchange(&tm.waiters_max[l], current)
	return max(peak, current)
}

// ---------------------------------------------------------------------------
// Per-thread accounting.

Thread_Acc :: struct {
	scope:       Scope,
	scope_depth: int,
	start_ns:    i64,
	component:   [Component]i64, // ns inside the current outermost scope
	steps:       int,
	statements:  int,
	tx_count:    int,
	tx_hold_ns:  i64,
	busy_errors: int,
	top:         [3]Top_Call,
}

Top_Call :: struct {
	conn:    string,
	op:      string,
	exec_ns: i64,
	wait_ns: i64,
	file:    string, // caller file path (static string; basename taken when formatted)
	line:    i32,
}

@(thread_local)
tl: Thread_Acc

add_component :: #force_inline proc "contextless" (c: Component, ns: i64) {
	tl.component[c] += ns
	if tl.scope_depth == 0 {
		// Outside any scope: flush straight into scope=other so nothing is dropped.
		if s := tm.scope_seconds[.Other][c]; s != nil && ns > 0 do sync.atomic_add(&s.value, u64(ns))
		tl.component[c] = 0
	}
}

note_step :: #force_inline proc "contextless" (first_of_statement: bool) {
	tl.steps += 1
	if first_of_statement do tl.statements += 1
}

note_tx :: #force_inline proc "contextless" (hold_ns: i64) {
	tl.tx_count += 1
	tl.tx_hold_ns += hold_ns
}

note_busy_error :: #force_inline proc "contextless" () { tl.busy_errors += 1 }

note_call :: proc "contextless" (conn, op: string, exec_ns, wait_ns: i64, file: string, line: i32) {
	if tl.scope_depth == 0 do return
	slot := -1
	min_ns := exec_ns + wait_ns
	for i in 0..<len(tl.top) {
		t := tl.top[i].exec_ns + tl.top[i].wait_ns
		if t < min_ns { min_ns = t; slot = i }
	}
	if slot >= 0 do tl.top[slot] = Top_Call{conn = conn, op = op, exec_ns = exec_ns, wait_ns = wait_ns, file = file, line = line}
}

Scope_Totals :: struct {
	scope:       Scope,
	elapsed_ns:  i64,
	component:   [Component]i64,
	steps:       int,
	statements:  int,
	tx_count:    int,
	tx_hold_ns:  i64,
	busy_errors: int,
	top:         [3]Top_Call,
}

// scope_begin opens a per-thread accounting scope. Re-entrant: only the
// outermost begin/end pair resets and flushes.
scope_begin :: proc "contextless" (s: Scope) {
	if !enabled() do return
	if tl.scope_depth == 0 {
		tl = Thread_Acc{}
		tl.scope = s
		tl.start_ns = now_ns()
	}
	tl.scope_depth += 1
}

// scope_end closes the scope. For the outermost scope it adds the component
// totals to heimdall_db_scope_seconds_total{scope} and returns them (ok=true)
// so the caller can attribute them further (HTTP route) or log a slow record.
scope_end :: proc "contextless" () -> (totals: Scope_Totals, ok: bool) {
	if !enabled() || tl.scope_depth == 0 do return
	tl.scope_depth -= 1
	if tl.scope_depth > 0 do return
	totals = Scope_Totals{
		scope = tl.scope, elapsed_ns = now_ns() - tl.start_ns, component = tl.component, steps = tl.steps, statements = tl.statements,
		tx_count = tl.tx_count, tx_hold_ns = tl.tx_hold_ns, busy_errors = tl.busy_errors, top = tl.top,
	}
	for c in Component {
		if s := tm.scope_seconds[tl.scope][c]; s != nil && totals.component[c] > 0 do sync.atomic_add(&s.value, u64(totals.component[c]))
	}
	tl = Thread_Acc{}
	return totals, true
}

// ---------------------------------------------------------------------------
// Timed acquisition shared by app mutexes and SQLite connection mutexes.

// begin_wait is called after a failed try-lock: counts the contended
// acquisition, raises the waiter gauge and its scrape high-water mark.
begin_wait :: proc "contextless" (l: Lock) {
	if s := tm.contended[l]; s != nil do sync.atomic_add(&s.value, 1)
	w := tm.waiters[l]
	if w == nil do return
	n := sync.atomic_add(&w.gauge, 1) + 1
	for {
		cur := sync.atomic_load(&tm.waiters_max[l])
		if n <= cur do break
		if _, swapped := sync.atomic_compare_exchange_weak(&tm.waiters_max[l], cur, n); swapped do break
	}
}

end_wait :: proc "contextless" (l: Lock) {
	if w := tm.waiters[l]; w != nil do sync.atomic_sub(&w.gauge, 1)
}

// record_wait observes one completed acquisition (contended or not) and adds
// its duration to the thread's component total.
record_wait :: proc "contextless" (l: Lock, ns: i64, component: Component) {
	observe_ns(tm.lock_wait[l], ns)
	add_component(component, ns)
}

observe_ns :: #force_inline proc "contextless" (s: ^metrics.Series, ns: i64) {
	if s == nil || s.buckets == nil do return
	v := u64(ns if ns > 0 else 0)
	if s.family.decimals != 9 do v = u64(rescale_ns(i64(v), s.family.decimals))
	bounds := s.family.bounds
	i := 0
	for ; i < len(bounds); i += 1 do if v <= bounds[i] do break
	sync.atomic_add(&s.buckets[i], 1)
	sync.atomic_add(&s.sum, v)
}

@(private)
rescale_ns :: proc "contextless" (v: i64, to_decimals: int) -> i64 {
	r := v
	for d := 9; d > to_decimals; d -= 1 do r /= 10
	return r
}

counter_add :: #force_inline proc "contextless" (s: ^metrics.Series, n: u64) {
	if s != nil && n > 0 do sync.atomic_add(&s.value, n)
}

Lock_Token :: struct {
	acquired: i64, // now_ns at acquisition
	timed:    bool,
}

// timed_lock acquires `mu` exactly like sync.mutex_lock. With telemetry on it
// first tries the lock, and on contention records waiters / contended / wait.
// Pair with `defer timed_unlock(&mu, lock, token)` so every early return
// observes the hold.
timed_lock :: proc "contextless" (mu: ^sync.Mutex, l: Lock) -> Lock_Token {
	if !enabled() {
		sync.mutex_lock(mu)
		return {}
	}
	t0 := now_ns()
	if !sync.mutex_try_lock(mu) {
		begin_wait(l)
		sync.mutex_lock(mu)
		end_wait(l)
	}
	t1 := now_ns()
	record_wait(l, t1 - t0, .App_Lock_Wait)
	if s := tm.held[l]; s != nil do sync.atomic_store(&s.gauge, 1)
	return Lock_Token{acquired = t1, timed = true}
}

timed_unlock :: proc "contextless" (mu: ^sync.Mutex, l: Lock, token: Lock_Token) {
	if token.timed {
		observe_ns(tm.lock_hold[l], now_ns() - token.acquired)
		if s := tm.held[l]; s != nil do sync.atomic_store(&s.gauge, 0)
	}
	sync.mutex_unlock(mu)
}

// scope_end_background closes a background scope (timer tick, merge job,
// bridge-log flush, shell replay) and writes one db_slow_scope line when the
// pass took >= slow_config.scope_slow_ms (1 s) or was sampled. Same rate limiter
// and sanitisation rules as db_slow_request: scope enum, timings, counts and
// file:line of the top-3 calls only.
scope_end_background :: proc() {
	totals, ok := scope_end()
	if !ok do return
	d := slow_decide(totals.elapsed_ns, slow_config.scope_slow_ms)
	if !d.emit do return
	b: [512]u8
	line := fmt.bprintf(b[:], "db_slow_scope reason=%s scope=%s elapsed_ns=%d app_lock_wait_ns=%d conn_wait_ns=%d exec_ns=%d busy_wait_ns=%d steps=%d statements=%d tx_count=%d tx_hold_ns=%d busy_errors=%d dropped_since_last=%d",
		SLOW_REASON_LABELS[d.reason], SCOPE_LABELS[totals.scope], totals.elapsed_ns,
		totals.component[.App_Lock_Wait], totals.component[.Conn_Wait], totals.component[.Exec_Excl_Busy], totals.component[.Busy_Wait],
		totals.steps, totals.statements, totals.tx_count, totals.tx_hold_ns, totals.busy_errors, d.dropped_since_last)
	fmt.eprintln(line)
}
