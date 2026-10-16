package sqlite

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import lockorder "odin_test:lib/lockorder"

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
// RELEASE, a nested rollback is ROLLBACK TO + RELEASE. Effects the nested UoW
// flushes still run inside the outer transaction — rare, and bounded by the
// outer caller, but it is the one place this file's no-I/O rule bends.
@(private = "file")
tx_mutex: sync.Mutex
@(private = "file")
tx_owner_thread: int
@(private = "file")
tx_depth: int

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
	if tx_depth > 0 && tx_owner_thread == me {
		// Nested: this thread already owns the transaction.
		sp := savepoint_name(tx_depth)
		if !exec(factory.conn, sp.begin) do return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to open nested savepoint")
		uow_ctx := new(SQLite_Unit_Of_Work_Context)
		uow_ctx.conn = factory.conn
		uow_ctx.repos = factory.repos
		uow_ctx.depth = tx_depth
		tx_depth += 1
		return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos}, true, domain.Domain_Error{}
	}
	lockorder.assert_tx_mutex_allowed()
	sync.mutex_lock(&tx_mutex)
	if !exec(factory.conn, "BEGIN;") {
		sync.mutex_unlock(&tx_mutex)
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to begin transaction")
	}
	tx_owner_thread = me
	tx_depth = 1
	uow_ctx := new(SQLite_Unit_Of_Work_Context)
	uow_ctx.conn = factory.conn
	uow_ctx.repos = factory.repos
	uow_ctx.depth = 0
	return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos}, true, domain.Domain_Error{}
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
		if !ok do exec(uow_ctx.conn, sp.rollback)
		tx_depth -= 1
		free(uow_ctx)
		if !ok do return false, domain.domain_error(.Internal_Error, "failed to release nested savepoint")
		return true, domain.Domain_Error{}
	}
	ok := exec(uow_ctx.conn, "COMMIT;")
	if !ok {
		// A failed COMMIT leaves the transaction open on the handle; roll it back
		// so the next BEGIN (on whichever thread wins the mutex) can start clean.
		exec(uow_ctx.conn, "ROLLBACK;")
	}
	free(uow_ctx)
	tx_depth = 0
	tx_owner_thread = 0
	sync.mutex_unlock(&tx_mutex)
	if !ok do return false, domain.domain_error(.Internal_Error, "failed to commit transaction")
	return true, domain.Domain_Error{}
}

sqlite_uow_rollback :: proc(ctx: rawptr) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return
	uow_ctx.closed = true
	if uow_ctx.depth > 0 {
		exec(uow_ctx.conn, savepoint_name(uow_ctx.depth).rollback)
		tx_depth -= 1
		free(uow_ctx)
		return
	}
	exec(uow_ctx.conn, "ROLLBACK;")
	free(uow_ctx)
	tx_depth = 0
	tx_owner_thread = 0
	sync.mutex_unlock(&tx_mutex)
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
