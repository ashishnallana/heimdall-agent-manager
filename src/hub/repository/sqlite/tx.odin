package sqlite

import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import lockorder "odin_test:lib/lockorder"
import metrics "odin_test:lib/metrics"
import dbt "odin_test:hub/platform/dbtelemetry"

// tx_mutex serialises every unit of work in the process (Task System v2 §2.1).
//
// The hub has ONE sqlite connection shared by every request thread
// (server.odin is thread-per-connection) and no application-level lock around
// it. Two threads issuing BEGIN on that one handle do not get two transactions:
// the second BEGIN fails ("cannot start a transaction within a transaction") or,
// worse, an unrelated thread's autocommit writes land inside the open
// transaction and are rolled back with it. So `begin` takes this mutex and
// `commit`/`rollback` release it: at any moment there is exactly one unit of
// work in the process, which is also what makes "the matcher runs inside the
// verb's transaction" and "two matcher runs on one chain are impossible" true
// without any further coordination.
//
// INVARIANT FOR CALLERS: never hold a unit of work across network I/O. Bridge
// wakes and user-event publishes happen AFTER commit; a verb that did otherwise
// would stall every other write in the hub behind a socket.
//
// LOCK ORDER (review B1): tx_mutex → Bridge_Runtime_Connection.state_mutex is
// the single allowed order (a unit of work may reserve runtime capacity via
// bridge_runtime_instance_apply). Code holding a state_mutex must never begin a
// unit of work; it returns facts (terminal/activity) and the caller acts after
// the unlock. lockorder.assert_tx_mutex_allowed enforces it at begin.
//
// NESTING: a thread that already owns the unit of work and begins another one
// (card accept → change_chain_status → engine chain_closed) gets a SAVEPOINT
// nested inside the outer transaction instead of a self-deadlock. The mutex is
// taken at depth 0 and released when depth returns to 0; a nested commit is
// RELEASE, a nested rollback is ROLLBACK TO + RELEASE. A nested UoW's
// post-commit effects are registered with unit_of_work_after_commit and run by
// the outermost COMMIT after the mutex is released, so the no-I/O rule holds
// for nested units too (review S7).
@(private = "file")
tx_mutex: sync.Mutex
// tx_owner_thread / tx_depth are read before the mutex is taken (to detect
// same-thread nesting), so they are accessed atomically (review S7).
@(private = "file")
tx_owner_thread: int
@(private = "file")
tx_depth: int
// tx_after_commit: hooks registered by nested units of work, run by the
// outermost commit AFTER the mutex is released. Only the owner thread touches
// it while the transaction is open. `depth` lets a nested rollback drop the
// hooks its savepoint registered.
@(private = "file")
tx_after_commit: [dynamic]Pending_After_Commit
// DB telemetry (owner-written): lock token, outer BEGIN start, and the acquire
// tick for heimdall_db_uow_oldest_hold_seconds (atomic; 0 = no open UoW).
@(private = "file")
tx_lock_token: dbt.Lock_Token
@(private = "file")
tx_started: time.Tick
@(private = "file")
tx_acquired_nsec: i64

@(private = "file")
Pending_After_Commit :: struct {
	depth: int,
	hook:  iface.After_Commit_Hook,
}

SQLite_Unit_Of_Work_Factory :: struct {
	conn: ^Conn,
	repos: ^iface.Repositories,
}

SQLite_Unit_Of_Work_Context :: struct {
	conn: ^Conn,
	repos: ^iface.Repositories,
	closed: bool,
	// depth 0 = the outer BEGIN/COMMIT that owns the mutex; >0 = SAVEPOINT.
	depth: int,
}

new_unit_of_work_factory :: proc(factory: ^SQLite_Unit_Of_Work_Factory, conn: ^Conn, repos: ^iface.Repositories) -> iface.Unit_Of_Work_Factory {
	factory.conn = conn
	factory.repos = repos
	return iface.Unit_Of_Work_Factory{ctx = rawptr(factory), begin = sqlite_uow_begin}
}

sqlite_uow_begin :: proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
	factory := (^SQLite_Unit_Of_Work_Factory)(ctx)
	if factory == nil || factory.conn == nil || factory.conn.db == nil {
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "sqlite unit of work factory is not open")
	}
	me := sync.current_thread_id()
	if sync.atomic_load(&tx_depth) > 0 && sync.atomic_load(&tx_owner_thread) == me {
		// Nested: this thread already owns the transaction.
		depth := sync.atomic_load(&tx_depth)
		sp := savepoint_name(depth)
		if !exec(factory.conn, sp.begin) do return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to open nested savepoint")
		uow_ctx := new(SQLite_Unit_Of_Work_Context)
		uow_ctx.conn = factory.conn
		uow_ctx.repos = factory.repos
		uow_ctx.depth = depth
		sync.atomic_store(&tx_depth, depth + 1)
		if dbt.enabled() do metrics.counter_inc(sqlite_tm.uow_nested)
		return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos, nested = true, after_commit = sqlite_uow_after_commit}, true, domain.Domain_Error{}
	}
	lockorder.assert_tx_mutex_allowed()
	tx_lock(factory.conn)
	if !exec(factory.conn, "BEGIN;") {
		tx_unlock(factory.conn, .Begin_Failed)
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to begin transaction")
	}
	sync.atomic_store(&tx_owner_thread, me)
	sync.atomic_store(&tx_depth, 1)
	uow_ctx := new(SQLite_Unit_Of_Work_Context)
	uow_ctx.conn = factory.conn
	uow_ctx.repos = factory.repos
	uow_ctx.depth = 0
	return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos, after_commit = sqlite_uow_after_commit}, true, domain.Domain_Error{}
}

// sqlite_uow_after_commit queues a hook on the transaction this unit of work
// belongs to; the outermost commit runs it after releasing the mutex.
sqlite_uow_after_commit :: proc(ctx: rawptr, hook: iface.After_Commit_Hook) -> bool {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return false
	if tx_after_commit == nil do tx_after_commit = make([dynamic]Pending_After_Commit)
	append(&tx_after_commit, Pending_After_Commit{depth = uow_ctx.depth, hook = hook})
	return true
}

// drop_after_commit_from removes hooks registered at `depth` or deeper (a
// rolled-back savepoint takes its hooks with it).
@(private = "file")
drop_after_commit_from :: proc(depth: int) {
	for i := 0; i < len(tx_after_commit); i += 1 {
		if tx_after_commit[i].depth >= depth {
			ordered_remove(&tx_after_commit, i)
			i -= 1
		}
	}
}

Savepoint_SQL :: struct { begin, release, rollback: string }

@(private = "file")
savepoint_name :: proc(depth: int) -> Savepoint_SQL {
	switch depth {
	case 1: return {"SAVEPOINT uow_1;", "RELEASE uow_1;", "ROLLBACK TO uow_1; RELEASE uow_1;"}
	case 2: return {"SAVEPOINT uow_2;", "RELEASE uow_2;", "ROLLBACK TO uow_2; RELEASE uow_2;"}
	case 3: return {"SAVEPOINT uow_3;", "RELEASE uow_3;", "ROLLBACK TO uow_3; RELEASE uow_3;"}
	}
	return {"SAVEPOINT uow_n;", "RELEASE uow_n;", "ROLLBACK TO uow_n; RELEASE uow_n;"}
}

sqlite_uow_commit :: proc(ctx: rawptr) -> (bool, domain.Domain_Error) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return false, domain.domain_error(.Internal_Error, "transaction is closed")
	uow_ctx.closed = true
	if uow_ctx.depth > 0 {
		sp := savepoint_name(uow_ctx.depth)
		ok := exec(uow_ctx.conn, sp.release)
		if !ok {
			exec(uow_ctx.conn, sp.rollback)
			drop_after_commit_from(uow_ctx.depth)
		}
		sync.atomic_store(&tx_depth, uow_ctx.depth)
		free(uow_ctx)
		if !ok do return false, domain.domain_error(.Internal_Error, "failed to release nested savepoint")
		return true, domain.Domain_Error{}
	}
	uow_ctx_conn := uow_ctx.conn
	ok := exec(uow_ctx.conn, "COMMIT;")
	if !ok {
		// A failed COMMIT leaves the transaction open on the handle; roll it back
		// so the next BEGIN (on whichever thread wins the mutex) can start clean.
		exec(uow_ctx.conn, "ROLLBACK;")
	}
	free(uow_ctx)
	// Take the deferred hooks out before releasing the mutex (the next owner
	// may register its own), run them after.
	hooks := tx_after_commit
	tx_after_commit = nil
	sync.atomic_store(&tx_depth, 0)
	sync.atomic_store(&tx_owner_thread, 0)
	tx_unlock(uow_ctx_conn, .Commit if ok else .Commit_Failed)
	if ok {
		for h in hooks do if h.hook.run != nil do h.hook.run(h.hook.ctx)
	}
	delete(hooks)
	if !ok do return false, domain.domain_error(.Internal_Error, "failed to commit transaction")
	return true, domain.Domain_Error{}
}

sqlite_uow_rollback :: proc(ctx: rawptr) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return
	uow_ctx.closed = true
	if uow_ctx.depth > 0 {
		exec(uow_ctx.conn, savepoint_name(uow_ctx.depth).rollback)
		drop_after_commit_from(uow_ctx.depth)
		sync.atomic_store(&tx_depth, uow_ctx.depth)
		free(uow_ctx)
		return
	}
	uow_ctx_conn := uow_ctx.conn
	exec(uow_ctx.conn, "ROLLBACK;")
	free(uow_ctx)
	delete(tx_after_commit)
	tx_after_commit = nil
	sync.atomic_store(&tx_depth, 0)
	sync.atomic_store(&tx_owner_thread, 0)
	tx_unlock(uow_ctx_conn, .Rollback)
}

// tx_lock / tx_unlock take and release tx_mutex for the OUTER unit of work.
// With DB telemetry on they observe lock wait/hold{uow_tx} and the tx duration
// (outer BEGIN start -> COMMIT/ROLLBACK return; after-commit hooks run later,
// outside it). Lock order and semantics are exactly sync.mutex_lock/unlock.
@(private = "file")
tx_lock :: proc(conn: ^Conn) {
	tx_lock_token = dbt.timed_lock(&tx_mutex, .Uow_Tx)
	if !tx_lock_token.timed do return
	tx_started = time.tick_now()
	sync.atomic_store(&tx_acquired_nsec, tx_started._nsec)
	tl_uow_active = true
	tl_uow_wrote = false
}

@(private = "file")
tx_unlock :: proc(conn: ^Conn, outcome: Tx_Outcome) {
	token := tx_lock_token
	tx_lock_token = {}
	if token.timed {
		kind := conn_kind_of(conn.db) if conn != nil else Conn_Kind.Other
		tx_observe(kind, .Uow, tl_uow_wrote, outcome, tx_started)
		sync.atomic_store(&tx_acquired_nsec, 0)
		tl_uow_active = false
		tl_uow_wrote = false
	}
	dbt.timed_unlock(&tx_mutex, .Uow_Tx, token)
}

// uow_oldest_hold_ns is the age of the open outer unit of work (0 if none),
// read by the scrape collector.
uow_oldest_hold_ns :: proc() -> i64 {
	acquired := sync.atomic_load(&tx_acquired_nsec)
	if acquired == 0 do return 0
	age := time.tick_now()._nsec - acquired
	return age if age > 0 else 0
}

// tx_mutex_try_lock is a TEST SEAM: it reports whether the process-wide unit of
// work mutex is currently free by trying to take it (and releasing it at once on
// success). Production code must never call it.
tx_mutex_try_lock :: proc() -> bool {
	if sync.mutex_try_lock(&tx_mutex) {
		sync.mutex_unlock(&tx_mutex)
		return true
	}
	return false
}
