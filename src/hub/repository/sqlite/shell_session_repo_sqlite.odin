package sqlite

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Shell_Session_Repo_SQLite :: struct {
	conn: ^Conn,
}

new_shell_session_repository :: proc(impl: ^Shell_Session_Repo_SQLite, conn: ^Conn) -> iface.Shell_Session_Repository {
	impl.conn = conn
	return iface.Shell_Session_Repository{
		ctx             = rawptr(impl),
		upsert          = shell_session_upsert_sqlite,
		get             = shell_session_get_sqlite,
		get_by_id       = shell_session_get_by_id_sqlite,
		list_by_bridge  = shell_session_list_by_bridge_sqlite,
		list_by_project = shell_session_list_by_project_sqlite,
		list_by_chain   = shell_session_list_by_chain_sqlite,
		list_by_owner   = shell_session_list_by_owner_sqlite,
		delete          = shell_session_delete_sqlite,
		set_server_port = shell_session_set_server_port_sqlite,
		find_live_by_port = shell_session_find_live_by_port_sqlite,
		count_live        = shell_session_count_live_sqlite,
		set_kill_requested = shell_session_set_kill_requested_sqlite,
		list_pending_kills = shell_session_list_pending_kills_sqlite,
		list_live_by_bridge = shell_session_list_live_by_bridge_sqlite,
		delete_terminal_before = shell_session_delete_terminal_before_sqlite,
		delete_terminal_before_owners = shell_session_delete_terminal_before_owners_sqlite,
		list_live_bridge_ids = shell_session_list_live_bridge_ids_sqlite,
		list_live_by_kind    = shell_session_list_live_by_kind_sqlite,
	}
}

// Column order for SELECT queries:
// 0:session_id 1:owner_user_id 2:bridge_id 3:project_id 4:chain_id
// 5:agent_instance_id 6:kind 7:label 8:cmd 9:cwd 10:status
// 11:exit_code 12:pid 13:server_port 14:started_at 15:finished_at
// 16:created_at 17:last_activity_at 18:background 19:conversation_id
// 20:kill_requested_at 21:run_seq
shell_session_select_cols :: "session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id, kind, label, cmd, cwd, status, exit_code, pid, server_port, started_at, finished_at, created_at, last_activity_at, background, conversation_id, kill_requested_at, run_seq"

shell_session_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.Shell_Session {
	s: domain.Shell_Session
	s.session_id         = column_text(stmt, 0)
	s.owner_user_id      = column_text(stmt, 1)
	s.bridge_id          = column_text(stmt, 2)
	s.project_id         = column_text(stmt, 3)
	s.chain_id           = column_text(stmt, 4)
	s.agent_instance_id  = column_text(stmt, 5)
	s.kind               = column_text(stmt, 6)
	s.label              = column_text(stmt, 7)
	s.cmd                = column_text(stmt, 8)
	s.cwd                = column_text(stmt, 9)
	s.status             = column_text(stmt, 10)
	// exit_code is nullable INTEGER: column_text_unowned returns "" for NULL
	ec := column_text_unowned(stmt, 11)
	if ec != "" {
		if v, ok := strconv.parse_int(ec); ok {
			s.exit_code     = int(v)
			s.exit_code_set = true
		}
	}
	// pid and server_port: NOT NULL INTEGER, use column_text_unowned for transient parse
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 12)); ok { s.pid = int(v) }
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 13)); ok { s.server_port = int(v) }
	s.started_at       = column_text(stmt, 14)
	s.finished_at      = column_text(stmt, 15)
	s.created_at       = column_text(stmt, 16)
	s.last_activity_at = column_text(stmt, 17)
	// background is INTEGER NOT NULL DEFAULT 0 (migration 049); any non-zero
	// reading is true, so a value written by anything but this repo still reads
	// sensibly.
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 18)); ok { s.background = v != 0 }
	s.conversation_id  = column_text(stmt, 19)
	s.kill_requested_at = column_text(stmt, 20)
	// run_seq is INTEGER NOT NULL DEFAULT 0 (migration 051). A row written before
	// 051 reads back as run 0, which is the same value a never-restarted session
	// carries, so old rows and new ones agree without a backfill.
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 21)); ok do s.run_seq = v
	return s
}

shell_session_upsert_sqlite :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(`INSERT INTO shell_sessions (
		session_id, owner_user_id, bridge_id, project_id, chain_id, agent_instance_id,
		kind, label, cmd, cwd, status, exit_code, pid, server_port,
		started_at, finished_at, created_at, last_activity_at, background, conversation_id,
		kill_requested_at, run_seq
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(bridge_id, session_id) DO UPDATE SET
		status           = excluded.status,
		-- background is ONE-WAY (domain.shell_session_run_may_background): MAX, not
		-- assignment, so a bridge-event upsert that carries the default 0 -- every
		-- shell_exited report does -- cannot silently clear a run the user has
		-- already backgrounded. Same guard in spirit as the pid/server_port CASEs
		-- above, expressed as MAX because the value is a one-way boolean.
		background       = MAX(excluded.background, shell_sessions.background),
		conversation_id  = CASE WHEN excluded.conversation_id != '' THEN excluded.conversation_id ELSE shell_sessions.conversation_id END,
		exit_code        = excluded.exit_code,
		pid              = CASE WHEN excluded.pid != 0 THEN excluded.pid ELSE shell_sessions.pid END,
		server_port      = CASE WHEN excluded.server_port != 0 THEN excluded.server_port ELSE shell_sessions.server_port END,
		finished_at      = CASE WHEN excluded.finished_at != '' THEN excluded.finished_at ELSE shell_sessions.finished_at END,
		last_activity_at = CASE WHEN excluded.last_activity_at != '' THEN excluded.last_activity_at ELSE shell_sessions.last_activity_at END,
		label            = CASE WHEN excluded.label != '' THEN excluded.label ELSE shell_sessions.label END,
		cwd              = CASE WHEN excluded.cwd != '' THEN excluded.cwd ELSE shell_sessions.cwd END,
		-- kill_requested_at (REQ-SHELL-3) has THREE branches, and the order matters.
		--
		-- 1. A terminal status CLEARS it. This is work item 5 -- "clear the intent once
		--    the session reaches a terminal status" -- satisfied structurally rather
		--    than by remembering to call something: every path that lands a terminal
		--    status goes through this upsert (shell_session_handle_exited included), so
		--    a row can never carry a kill request for a process that is already gone.
		--    That matters beyond tidiness: a spent intent left set would be re-delivered
		--    on the next reconnect, and the pid it named may by then belong to an
		--    unrelated process.
		-- 2. Otherwise a non-empty incoming value SETS it.
		-- 3. Otherwise the stored value is KEPT, so the bridge-event upserts -- which
		--    know nothing about this column and carry "" -- cannot silently drop a
		--    pending kill. Same guard in spirit as the pid/server_port CASEs above.
		--
		-- The terminal set is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES, not
		-- written out here, so "terminal" means in SQL exactly what
		-- shell_session_is_terminal means in Odin.
		kill_requested_at = CASE
			WHEN excluded.status IN (%s) THEN ''
			WHEN excluded.kill_requested_at != '' THEN excluded.kill_requested_at
			ELSE shell_sessions.kill_requested_at END,
		-- run_seq (REQ-SHELL-4) is MONOTONIC, so MAX rather than assignment, for the
		-- same reason background is MAX: only shell_session_restart advances it, and
		-- every other writer carries whatever it last read. A bridge-event upsert that
		-- raced a restart would otherwise roll the counter BACK to the run it knew
		-- about, and the hub would then accept that run's stale exits as current --
		-- re-opening precisely the hole this column closes.
		run_seq          = MAX(excluded.run_seq, shell_sessions.run_seq)
		-- Compare the effective merged row, not the incoming event. IS NOT is
		-- NULL-safe for exit_code. The atomic predicate preserves concurrent MAX,
		-- preserve-old and terminal kill-intent rules without another read.
		WHERE (shell_sessions.status, shell_sessions.background,
			shell_sessions.conversation_id, shell_sessions.exit_code,
			shell_sessions.pid, shell_sessions.server_port,
			shell_sessions.finished_at, shell_sessions.last_activity_at,
			shell_sessions.label, shell_sessions.cwd,
			shell_sessions.kill_requested_at, shell_sessions.run_seq)
		IS NOT (excluded.status, MAX(excluded.background, shell_sessions.background),
			CASE WHEN excluded.conversation_id != '' THEN excluded.conversation_id ELSE shell_sessions.conversation_id END,
			excluded.exit_code,
			CASE WHEN excluded.pid != 0 THEN excluded.pid ELSE shell_sessions.pid END,
			CASE WHEN excluded.server_port != 0 THEN excluded.server_port ELSE shell_sessions.server_port END,
			CASE WHEN excluded.finished_at != '' THEN excluded.finished_at ELSE shell_sessions.finished_at END,
			CASE WHEN excluded.last_activity_at != '' THEN excluded.last_activity_at ELSE shell_sessions.last_activity_at END,
			CASE WHEN excluded.label != '' THEN excluded.label ELSE shell_sessions.label END,
			CASE WHEN excluded.cwd != '' THEN excluded.cwd ELSE shell_sessions.cwd END,
			CASE WHEN excluded.status IN (%s) THEN ''
				WHEN excluded.kill_requested_at != '' THEN excluded.kill_requested_at
				ELSE shell_sessions.kill_requested_at END,
			MAX(excluded.run_seq, shell_sessions.run_seq));`, shell_session_terminal_placeholders(), shell_session_terminal_placeholders())
	// clone_to_cstring, not cstring(raw_data(query)). This query stopped being a
	// string LITERAL when the terminal set made it interpolated, and a literal is
	// NUL-terminated while tprintf output is not guaranteed to be — so the (-1,
	// "read to the NUL") form below would be reading past the string. The temp
	// allocator is reclaimed wholesale, so there is nothing to free.
	c_query := strings.clone_to_cstring(query, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, c_query, -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session upsert")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1,  session.session_id)
	bind_text(stmt, 2,  session.owner_user_id)
	bind_text(stmt, 3,  session.bridge_id)
	bind_text(stmt, 4,  session.project_id)
	bind_text(stmt, 5,  session.chain_id)
	bind_text(stmt, 6,  session.agent_instance_id)
	bind_text(stmt, 7,  session.kind)
	bind_text(stmt, 8,  session.label)
	bind_text(stmt, 9,  session.cmd)
	bind_text(stmt, 10, session.cwd)
	bind_text(stmt, 11, session.status)
	// exit_code: NULL when not set, integer value when set
	if session.exit_code_set {
		sqlite3_bind_int(stmt, 12, c.int(session.exit_code))
	} else {
		sqlite3_bind_null(stmt, 12)
	}
	sqlite3_bind_int(stmt, 13, c.int(session.pid))
	sqlite3_bind_int(stmt, 14, c.int(session.server_port))
	bind_text(stmt, 15, session.started_at)
	bind_text(stmt, 16, session.finished_at)
	bind_text(stmt, 17, session.created_at)
	bind_text(stmt, 18, session.last_activity_at)
	sqlite3_bind_int(stmt, 19, c.int(session.background ? 1 : 0))
	bind_text(stmt, 20, session.conversation_id)
	bind_text(stmt, 21, session.kill_requested_at)
	sqlite3_bind_int(stmt, 22, c.int(session.run_seq))
	// The terminal set for the kill_requested_at CASE, bound after every value
	// parameter so adding a status to the domain table shifts nothing above.
	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	for st, i in terminal {
		bind_text(stmt, 23 + i, st)
		bind_text(stmt, 23 + len(terminal) + i, st)
	}

	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to upsert shell session")
	}
	return true, domain.Domain_Error{}
}

// shell_session_get_sqlite is the OWNER-scoped read behind every user-facing shell
// route — kill, attach, signal, restart, set_port and log (app/wiring.odin:591,
// 604-607, 612) all resolve the session through this one query.
//
// IT REFUSES TO GUESS (REQ-SHELL-12). The query asks for TWO rows and returns a
// .Conflict when it gets them, rather than taking `LIMIT 1` and handing back
// whichever row SQLite happened to visit first. An arbitrary pick here is not a
// cosmetic wrong answer: these six routes MUTATE the session they are given, so
// the failure mode is signalling, restarting or killing the WRONG process while
// reporting success. A read that cannot identify its row has no safe answer, and
// "no answer" is the only honest one.
//
// BE PRECISE ABOUT WHAT THIS IS: DEFENCE IN DEPTH, NOT A LIVE BUG FIX. Migration
// 048 (048_shell_sessions_kind_and_key.sql:83) carries
// `CREATE UNIQUE INDEX shell_sessions_owner_session ON shell_sessions(owner_user_id,
// session_id)`, so a second matching row CANNOT be inserted through any normal path
// and this branch is unreachable today. It exists for the states that index does not
// cover — a hand-edited database, a future migration that rebuilds the table and
// forgets to recreate the index, or a bug that drops it. (A PARTIALLY APPLIED 048
// used to belong on that list and no longer does: REQ-SHELL-13 made the migration
// guard key on 048's LAST object, so an interrupted apply is now detected and
// re-run rather than reported complete.)
//
// The chain's core invariant is that unreconcilable state is a defect rather than an
// acceptable transient. A read that silently picks one of two candidates is exactly
// that defect, so it is spelled out here instead of being left to the index.
//
// WHY .Conflict AND NOT Not_Found: the caller must be able to tell "this session is
// gone" from "this session is ambiguous and I refuse to act on it". The first is
// routine; the second is an operator alert about a corrupt database. .Conflict maps
// to 409 at transport/http/respond.odin:46, so all six routes surface it distinctly
// without a per-route mapping.
shell_session_get_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	// LIMIT 2, not LIMIT 1: one row to return and one row to DETECT. The bound stays
	// so a pathologically duplicated table cannot make this read walk the whole table.
	query := strings.concatenate({"SELECT ", shell_session_select_cols, " FROM shell_sessions WHERE owner_user_id = ? AND session_id = ? LIMIT 2;"}, context.temp_allocator)
	// clone_to_cstring, not cstring(raw_data(query)), for the reason spelled out at the
	// upsert above: strings.concatenate allocates exactly len bytes and appends no NUL,
	// while the -1 below tells prepare_v2 to read to one — so the old spelling scanned
	// past the allocation. The temp allocator is reclaimed wholesale; nothing to free.
	c_query := strings.clone_to_cstring(query, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, c_query, -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell session get")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, session_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Session{}, false, domain.Domain_Error{}
	// Materialise the first row BEFORE stepping again — the column pointers belong to
	// the statement and the next step invalidates them. It is destroyed on the
	// ambiguous path so the refusal does not leak the row it declined to return.
	session := shell_session_from_stmt(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW {
		domain.shell_session_destroy(session)
		return domain.Shell_Session{}, false, domain.domain_error(.Conflict, "shell session id is ambiguous for this owner: refusing to act on an arbitrary match")
	}
	return session, true, domain.Domain_Error{}
}

// shell_session_get_by_id_sqlite resolves a session without an owner, for the
// trusted bridge-event path (REQ-RECON-5) — see Shell_Session_Get_By_Id_Proc. It
// must not be reached from an HTTP handler.
//
// It is OWNER-unscoped but no longer BRIDGE-unscoped (REQ-SHELL-1 §7). The key is
// (bridge_id, session_id), and the one caller — a shell_exited report — always
// knows which bridge reported it, so binding that bridge is free and makes this
// strictly narrower than the single-column lookup it replaces: a bridge can now
// only resolve its own sessions, where before a colliding session_id from another
// bridge would have resolved and been mutated.
shell_session_get_by_id_sqlite :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := strings.concatenate({"SELECT ", shell_session_select_cols, " FROM shell_sessions WHERE bridge_id = ? AND session_id = ? LIMIT 1;"}, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell session get by id")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	bind_text(stmt, 2, session_id)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return shell_session_from_stmt(stmt), true, domain.Domain_Error{}
}

// The three scoped list routes, kept ADJACENT on purpose: each passes the per-kind
// restriction it wants, and the one that passes NONE is visibly the odd one out rather
// than quietly different. project_id is not a scope column — it is an annotation every
// kind may carry — so the by-project route narrows on kind not at all, and says so by
// passing `nil`.
//
// `nil` HERE MEANS NOTHING, which is the point of spelling it as a slice. This used to be
// a `domain.Shell_Session_Scope_Column` plus a parallel `is_scope_column: bool`, and the
// by-project caller passed `nil, false` — where `nil` on an enum is the zero value, i.e.
// secretly `.Bridge`, reachable the moment anyone dropped the bool. Two correlated values
// encoding one fact. An empty slice cannot be misread that way and needs no second
// parameter to disarm it.
shell_session_list_by_bridge_sqlite :: proc(ctx: rawptr, owner_user_id, bridge_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	return shell_session_list_generic(ctx, "bridge_id", {shell_session_kind_scope_clause(.Bridge)}, owner_user_id, bridge_id, status_filter, cursor, limit)
}

shell_session_list_by_project_sqlite :: proc(ctx: rawptr, owner_user_id, project_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	return shell_session_list_generic(ctx, "project_id", nil, owner_user_id, project_id, status_filter, cursor, limit)
}

shell_session_list_by_chain_sqlite :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	// An empty chain id names no chain. `shell` carries chain_id as an OPTIONAL
	// scope column, so binding chain_id='' here would hand back every unattached
	// shell; answer "nothing" instead of widening the listing.
	if chain_id == "" do return nil, "", domain.Domain_Error{}
	return shell_session_list_generic(ctx, "chain_id", {shell_session_kind_scope_clause(.Chain)}, owner_user_id, chain_id, status_filter, cursor, limit)
}

// shell_session_list_by_owner_sqlite lists every session the owner has, across
// all bridges, with each non-empty filter field contributing one AND-ed clause.
// No filter at all is the owner-wide default listing.
shell_session_list_by_owner_sqlite :: proc(ctx: rawptr, owner_user_id: string, filter: iface.Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	clauses := make([dynamic]Shell_Session_Where_Clause, context.temp_allocator)
	// Each scope-column filter also constrains kind, from the same domain rules the
	// scoped routes use: narrowing by a column a kind does not key on must not
	// return that kind (REQ-SHELL-1 §6). project_id is an annotation, not a scope
	// column, so it narrows on value alone.
	if filter.bridge_id != "" {
		append(&clauses, shell_session_eq("bridge_id", filter.bridge_id))
		append(&clauses, shell_session_kind_scope_clause(.Bridge))
	}
	if filter.project_id != "" do append(&clauses, shell_session_eq("project_id", filter.project_id))
	if filter.chain_id != "" {
		append(&clauses, shell_session_eq("chain_id", filter.chain_id))
		append(&clauses, shell_session_kind_scope_clause(.Chain))
	}
	if filter.agent_instance_id != "" {
		append(&clauses, shell_session_eq("agent_instance_id", filter.agent_instance_id))
		append(&clauses, shell_session_kind_scope_clause(.Agent_Instance))
	}
	if filter.status != "" do append(&clauses, shell_session_status_clause(filter.status))
	return shell_session_list_where(ctx, owner_user_id, clauses[:], cursor, limit)
}

// shell_session_list_generic is the one scoped list. `scope_col` is the column to
// narrow on. `kind_clauses` carries the per-kind restriction when `scope_col` is also a
// domain scope column, and is EMPTY when it is not — one value, so there is no way to
// say "restrict to these kinds" and "this is not a scope column" at the same time.
//
// Every clause the three callers pass is built by shell_session_kind_scope_clause from
// domain.SHELL_SESSION_SCOPE_RULES, so the narrowing is STRUCTURAL — a WHERE clause the
// database applies — and not a client-side filter (REQ-SHELL-9 AC3). As written, the
// callers choose WHETHER to narrow and never spell out WHICH kinds.
//
// BE PRECISE ABOUT WHAT ENFORCES THAT, because it is weaker than it looks: it is CALL-SITE
// DISCIPLINE, not the type. The parameter this replaced was a Shell_Session_Scope_Column,
// an enum from which a caller COULD NOT express an arbitrary kind set. A
// []Shell_Session_Where_Clause can be hand-built with any kind strings at all, this proc
// is package-visible, and the loop below appends whatever it is handed. So a fourth caller
// that composed its own kind clause would compile and would bypass the domain table.
// Today there are three callers, all adjacent above, and none does that. If that ceases to
// be obvious at a glance, narrow the type rather than trusting this paragraph.
shell_session_list_generic :: proc(ctx: rawptr, scope_col: string, kind_clauses: []Shell_Session_Where_Clause, owner_user_id, scope_val, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	// The scope clause is UNCONDITIONAL, including when scope_val is "". These
	// three lists are scoped by construction, and an empty scope value means
	// "the sessions whose column is empty" — dropping the clause instead would
	// silently widen a scoped route to the owner's whole fleet. Only the status
	// filter is optional here, exactly as before.
	clauses := make([dynamic]Shell_Session_Where_Clause, context.temp_allocator)
	append(&clauses, shell_session_eq(scope_col, scope_val))
	// REQ-SHELL-1 §6. Before this, list_by_chain(owner, "") returned every session
	// with an empty chain_id — i.e. all the agent-scoped runs and bridge-scoped
	// shells — to a caller asking about a chain. Restricting to the kinds that use
	// the column closes that: a by-chain listing returns servers and chain-attached
	// shells, never runs.
	for c in kind_clauses do append(&clauses, c)
	// Through the same translator as the owner-wide list, so `status=live` and
	// `status=finished` work identically on all four list routes.
	if status_filter != "" do append(&clauses, shell_session_status_clause(status_filter))
	return shell_session_list_where(ctx, owner_user_id, clauses[:], cursor, limit)
}

// shell_session_kind_scope_clause restricts a listing to the kinds whose scope
// key includes `col`, straight from domain.SHELL_SESSION_SCOPE_RULES. The repo
// never spells a kind/scope pairing itself, so the query layer cannot drift from
// the domain's table the way it could if this were a hand-written kind IN (...).
shell_session_kind_scope_clause :: proc(col: domain.Shell_Session_Scope_Column) -> Shell_Session_Where_Clause {
	buf: [len(domain.Shell_Session_Kind)]string
	kinds := domain.shell_session_kinds_scoped_by(col, &buf)
	vals := make([]string, len(kinds), context.temp_allocator)
	for k, i in kinds do vals[i] = k
	return Shell_Session_Where_Clause{col = "kind", op = .In, vals = vals}
}

Shell_Session_Where_Op :: enum {
	Eq,     // <col> = ?
	In,     // <col> IN (?, ?, ...)
	Not_In, // <col> NOT IN (?, ?, ...)
}

// Shell_Session_Where_Clause is one AND-ed condition. `col` is always a literal
// chosen in this file, never caller text, so it is safe to inline into the SQL;
// every value in `vals` is bound as a parameter. Eq carries exactly one value;
// In/Not_In carry the set.
Shell_Session_Where_Clause :: struct {
	col:  string,
	op:   Shell_Session_Where_Op,
	vals: []string,
}

// shell_session_eq is the one-value equality clause, the shape almost every
// filter wants. The backing slice is temp-allocated, so it lives exactly as long
// as the request or loop iteration that builds the query — never past the
// sqlite3_step loop that reads it.
shell_session_eq :: proc(col, val: string) -> Shell_Session_Where_Clause {
	vals := make([]string, 1, context.temp_allocator)
	vals[0] = val
	return Shell_Session_Where_Clause{col = col, op = .Eq, vals = vals}
}

// shell_session_status_clause translates ONE status filter value into a clause.
// The two group names (domain.Shell_Session_Status_Group_Live / _Finished) become
// set membership over domain.SHELL_SESSION_TERMINAL_STATUSES — the domain's own
// definition of "over", so this cannot drift from shell_session_is_terminal.
// Anything else is an exact match, so every concrete status keeps behaving
// exactly as it did before the groups existed.
//
// `live` is NOT IN (terminal) rather than IN (starting, running): a status added
// later is live until the domain says it is terminal, which is the safer default
// — a new status shows up in the Live tab instead of vanishing from both.
shell_session_status_clause :: proc(status: string) -> Shell_Session_Where_Clause {
	switch status {
	case domain.Shell_Session_Status_Group_Finished:
		return Shell_Session_Where_Clause{col = "status", op = .In, vals = shell_session_terminal_vals()}
	case domain.Shell_Session_Status_Group_Live:
		return Shell_Session_Where_Clause{col = "status", op = .Not_In, vals = shell_session_terminal_vals()}
	}
	return shell_session_eq("status", status)
}

// shell_session_terminal_vals copies the domain's terminal set into a temp slice
// for binding. Copied rather than referenced because the domain constant is a
// fixed-size array, and the clause holds a slice.
// shell_session_terminal_placeholders renders the bind placeholders for the
// terminal set — "?, ?, ?" for three statuses. It exists so a query that has to
// EMBED the set in its text (the upsert's kill_requested_at CASE) still gets its
// width from domain.SHELL_SESSION_TERMINAL_STATUSES rather than hard-coding one,
// and still binds the values instead of interpolating them.
shell_session_terminal_placeholders :: proc() -> string {
	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	for _, i in terminal {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "?")
	}
	return strings.to_string(b)
}

shell_session_terminal_vals :: proc() -> []string {
	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	vals := make([]string, len(terminal), context.temp_allocator)
	for st, i in terminal do vals[i] = st
	return vals
}

// shell_session_list_where is the one keyset-paginated shell-session query. It
// always scopes to owner_user_id, ANDs every clause it is given, and keeps the
// `ORDER BY started_at DESC, session_id DESC` ordering the cursor is defined
// against.
shell_session_list_where :: proc(ctx: rawptr, owner_user_id: string, clauses: []Shell_Session_Where_Clause, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, "", domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	lim := limit
	if lim <= 0 do lim = 50

	has_cursor := cursor != ""

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE owner_user_id = ?")
	for c in clauses {
		strings.write_string(&b, " AND ")
		strings.write_string(&b, c.col)
		switch c.op {
		case .Eq:
			strings.write_string(&b, " = ?")
		case .In, .Not_In:
			strings.write_string(&b, " NOT IN (" if c.op == .Not_In else " IN (")
			for _, i in c.vals {
				if i > 0 do strings.write_string(&b, ", ")
				strings.write_string(&b, "?")
			}
			strings.write_string(&b, ")")
		}
	}
	if has_cursor do strings.write_string(&b, " AND session_id < ?")
	strings.write_string(&b, " ORDER BY started_at DESC, session_id DESC LIMIT ?;")
	query := strings.to_string(b)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return nil, "", domain.domain_error(.Internal_Error, "failed to prepare shell session list")
	}
	defer sqlite3_finalize(stmt)

	bind_text(stmt, 1, owner_user_id)
	p := 2
	for c in clauses {
		for v in c.vals { bind_text(stmt, p, v); p += 1 }
	}
	if has_cursor { bind_text(stmt, p, cursor); p += 1 }
	bind_text(stmt, p, int_s(lim))

	items := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&items, shell_session_from_stmt(stmt))
	}
	// The cursor is CLONED, not aliased. It is derived from the last row's
	// session_id, and every caller frees the page (domain.shell_sessions_destroy,
	// which deletes session_id) and the cursor (delete(next_cursor))
	// independently — aliasing made those two frees land on one allocation. An
	// owned copy is what the callers already assume they were handed.
	next_cursor := ""
	if len(items) >= lim && len(items) > 0 {
		next_cursor = strings.clone(items[len(items)-1].session_id)
	}
	return items, next_cursor, domain.Domain_Error{}
}

// shell_session_set_server_port_sqlite writes server_port alone. A direct
// UPDATE rather than a re-upsert: shell_session_upsert_sqlite keeps the existing
// port when the incoming one is 0, so clearing a port through the upsert writes
// nothing. Returns false when no row matched the owner/session pair.
shell_session_set_server_port_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string, server_port: int) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "UPDATE shell_sessions SET server_port = ? WHERE owner_user_id = ? AND session_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session set server_port")
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int(stmt, 1, c.int(server_port))
	bind_text(stmt, 2, owner_user_id)
	bind_text(stmt, 3, session_id)
	step_rc, row_changes := step_changes(impl.conn.db, stmt)
	if step_rc != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to set shell session server_port")
	}
	return row_changes > 0, domain.Domain_Error{}
}

shell_session_delete_sqlite :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	stmt: sqlite3_stmt = nil
	query := "DELETE FROM shell_sessions WHERE owner_user_id = ? AND session_id = ?;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session delete")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, session_id)
	if sqlite3_step(stmt) != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to delete shell session")
	}
	return true, domain.Domain_Error{}
}

// shell_session_delete_terminal_before_sqlite is the row-retention sweep
// (REQ-SHELL-8 item 6). It deletes TERMINAL rows that ended before the cutoff.
//
// The live predicate is built from domain.SHELL_SESSION_TERMINAL_STATUSES rather
// than a hand-written status list, exactly as find_live_by_port does, so a session
// is "over" here by the same single definition that makes it over everywhere else.
// Adding a sixth status to that table makes it retainable and reapable in one edit
// instead of two, and cannot make it terminal in one place and live in the other.
//
// AGE COLUMN: finished_at is the honest end time, but it is nullable and a session
// whose terminal status was INFERRED (a bridge that never came back, a reconcile
// that reaped an orphan) can carry an empty one. Falling back through
// last_activity_at to started_at means such a row still ages out instead of
// becoming immortal through a missing timestamp — and since started_at is NOT NULL,
// the coalesce can never land on NULL and quietly exclude the row from the compare.
//
// The comparison is a plain string compare because every one of these columns holds
// platform.format_rfc3339_utc output: fixed width, zero-padded, always UTC, always
// Z-suffixed. Lexicographic order is chronological order for that format.
shell_session_delete_terminal_before_sqlite :: proc(ctx: rawptr, cutoff_rfc3339: string) -> (int, domain.Domain_Error) {
	owners, err := shell_session_delete_terminal_before_owners_sqlite(ctx, cutoff_rfc3339)
	defer { for k in owners do delete(k); delete(owners) }
	total := 0
	for _, n in owners do total += n
	return total, err
}

// shell_session_delete_terminal_before_owners_sqlite is the one retention DELETE;
// RETURNING owner_user_id reports which owners lost rows in the same statement,
// so no row can be deleted unreported or reported undeleted.
shell_session_delete_terminal_before_owners_sqlite :: proc(ctx: rawptr, cutoff_rfc3339: string) -> (map[string]int, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	// An empty cutoff would compare greater than nothing and delete nothing, but it
	// means the caller failed to read a clock — refuse rather than silently no-op.
	if cutoff_rfc3339 == "" do return nil, domain.domain_error(.Validation_Failed, "shell session row retention requires a cutoff")

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "DELETE FROM shell_sessions WHERE status IN (")
	for _, i in terminal {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "?")
	}
	strings.write_string(&b, ") AND COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at) < ? RETURNING owner_user_id;")
	// clone_to_cstring rather than cstring(raw_data(...)): prepare_v2 is given -1 for
	// the length, so it reads to a NUL that a builder's buffer does not promise.
	query := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare shell session row retention delete")
	}
	defer sqlite3_finalize(stmt)
	for st, i in terminal do bind_text(stmt, 1 + i, st)
	bind_text(stmt, 1 + len(terminal), cutoff_rfc3339)
	owners := make(map[string]int)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for k in owners do delete(k)
			delete(owners)
			return nil, domain.domain_error(.Internal_Error, "failed to delete expired shell session rows")
		}
		owner := column_text_unowned(stmt, 0)
		if owner in owners { owners[owner] += 1 } else { owners[strings.clone(owner)] = 1 }
	}
	return owners, domain.Domain_Error{}
}

// shell_session_list_live_bridge_ids_sqlite backs REQ-SHELL-14's gone-bridge sweep:
// the DISTINCT bridges that currently hold at least one live session.
//
// The live predicate is built from domain.SHELL_SESSION_TERMINAL_STATUSES, like
// find_live_by_bridge and the retention delete above, so "live" means one thing
// across this file.
//
// SELECT DISTINCT rather than a full row read, and bridge_id alone rather than
// shell_session_select_cols: the caller only needs to know WHICH bridges to ask
// about, and it then re-reads each candidate's sessions itself. Fetching whole rows
// here would allocate every live session on the host every 20 seconds to answer a
// question about bridge identity.
//
// bridge_id != '' is a guard, not a filter for an expected case — the column backs
// the primary key for every kind, so an empty one is a corrupt row, and letting it
// through would hand the sweep a bridge_id that resolves to no bridge.
//
// ORDER BY for determinism only: with the limit acting as a runaway backstop, a
// stable order means a truncated result is the same prefix each sweep rather than an
// arbitrary subset that rotates, which would make a stuck bridge reachable on some
// ticks and not others.
shell_session_list_live_bridge_ids_sqlite :: proc(ctx: rawptr, limit: int) -> ([dynamic]string, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	out := make([dynamic]string)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return out, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 1024

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT DISTINCT bridge_id FROM shell_sessions WHERE bridge_id != '' AND status NOT IN (")
	strings.write_string(&b, shell_session_terminal_placeholders())
	strings.write_string(&b, ") ORDER BY bridge_id ASC LIMIT ?;")
	query := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return out, domain.domain_error(.Internal_Error, "failed to prepare live bridge id listing")
	}
	defer sqlite3_finalize(stmt)
	for st, i in terminal do bind_text(stmt, 1 + i, st)
	sqlite3_bind_int(stmt, c.int(1 + len(terminal)), c.int(eff_limit))
	for sqlite3_step(stmt) == SQLITE_ROW {
		// column_text (owned) rather than column_text_unowned: these ids outlive the
		// finalize above, and the caller is documented as owning them.
		append(&out, column_text(stmt, 0))
	}
	return out, domain.Domain_Error{}
}

// shell_session_find_live_by_port_sqlite backs the create-time port conflict check
// (REQ-SHELL-2 §10). See Shell_Session_Find_Live_By_Port_Proc for why it is
// deliberately owner-unscoped: a port belongs to the host, so a cross-tenant
// conflict is a real conflict and would otherwise surface as a failed bind.
//
// The live predicate is built from domain.SHELL_SESSION_TERMINAL_STATUSES, not
// from a hand-written status list, so a terminal session releases its port by
// exactly the rule that makes it terminal anywhere else. server_port = 0 means "no
// port declared" and is never a conflict; the caller does not ask in that case,
// and the guard here keeps that true if one ever does.
//
// ORDER BY started_at: with several holders (only possible from a pre-049 database
// or a manual edit) the OLDEST is named, since it is the one that actually owns
// the bind.
shell_session_find_live_by_port_sqlite :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	if server_port <= 0 || bridge_id == "" do return domain.Shell_Session{}, false, domain.Domain_Error{}

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE bridge_id = ? AND server_port = ? AND status NOT IN (")
	for _, i in terminal {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "?")
	}
	strings.write_string(&b, ") ORDER BY started_at ASC, session_id ASC LIMIT 1;")
	query := strings.to_string(b)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return domain.Shell_Session{}, false, domain.domain_error(.Internal_Error, "failed to prepare shell session port lookup")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	sqlite3_bind_int(stmt, 2, c.int(server_port))
	for st, i in terminal do bind_text(stmt, 3 + i, st)
	if sqlite3_step(stmt) != SQLITE_ROW do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return shell_session_from_stmt(stmt), true, domain.Domain_Error{}
}

// shell_session_count_live_sqlite counts an owner's live sessions of one kind in
// one scope, backing the per-agent run cap and the per-chain server cap.
//
// scope_column is NOT interpolated from user input: the service passes
// domain.shell_session_scope_column_name(...), which returns one of three fixed
// literals, and anything else is refused below rather than reaching the SQL. That
// keeps the column name a closed set even though it has to be concatenated (SQLite
// cannot bind an identifier).
shell_session_count_live_sqlite :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return 0, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	if owner_user_id == "" || kind == "" || scope_value == "" do return 0, domain.Domain_Error{}

	// Closed set, checked against the domain's own spelling of each scope column.
	allowed := false
	for col in domain.Shell_Session_Scope_Column {
		if domain.shell_session_scope_column_name(col) == scope_column {
			allowed = true
			break
		}
	}
	if !allowed do return 0, domain.domain_error(.Internal_Error, "unknown shell session scope column")

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT COUNT(*) FROM shell_sessions WHERE owner_user_id = ? AND kind = ? AND ")
	strings.write_string(&b, scope_column)
	strings.write_string(&b, " = ? AND status NOT IN (")
	for _, i in terminal {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "?")
	}
	strings.write_string(&b, ");")
	query := strings.to_string(b)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return 0, domain.domain_error(.Internal_Error, "failed to prepare shell session live count")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, owner_user_id)
	bind_text(stmt, 2, kind)
	bind_text(stmt, 3, scope_value)
	for st, i in terminal do bind_text(stmt, 4 + i, st)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.Domain_Error{}
	if v, ok := strconv.parse_int(column_text_unowned(stmt, 0)); ok do return int(v), domain.Domain_Error{}
	return 0, domain.Domain_Error{}
}

// shell_session_set_kill_requested_sqlite records an accepted kill on the row
// (REQ-SHELL-3). Owner-scoped, and FIRST-WRITER-WINS via the
// `AND kill_requested_at = ''` guard: a second kill of the same session leaves the
// original timestamp in place, so "pending since" is when the user first asked
// rather than when they last retried.
//
// The returned bool is "the row exists and carries an intent", NOT "this call wrote
// it". A second kill must read as success — the intent it asked for is outstanding,
// which is the whole of what the caller needs to know — so reporting the no-op write
// as a failure would turn a correct idempotent retry into an error. sqlite3_changes
// is therefore deliberately not consulted; the row is re-read instead.
//
// It never clears. Clearing belongs to the upsert, keyed on a terminal status
// landing, so an intent cannot be retired while the process is still alive.
shell_session_set_kill_requested_sqlite :: proc(ctx: rawptr, owner_user_id, session_id, kill_requested_at: string) -> (bool, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	if owner_user_id == "" || session_id == "" || kill_requested_at == "" {
		return false, domain.domain_error(.Validation_Failed, "owner, session id and kill_requested_at are required")
	}

	stmt: sqlite3_stmt = nil
	query := `UPDATE shell_sessions SET kill_requested_at = ?
		WHERE owner_user_id = ? AND session_id = ? AND kill_requested_at = '';`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session kill intent write")
	}
	bind_text(stmt, 1, kill_requested_at)
	bind_text(stmt, 2, owner_user_id)
	bind_text(stmt, 3, session_id)
	step := sqlite3_step(stmt)
	sqlite3_finalize(stmt)
	if step != SQLITE_DONE {
		return false, domain.domain_error(.Internal_Error, "failed to write shell session kill intent")
	}

	// Re-read rather than trusting the change count, so an already-pending session
	// (the idempotent second kill) reports success and a session that does not exist
	// for this owner reports false.
	//
	// LIMIT 2 and the ambiguity refusal below are the same REQ-SHELL-12 rule the
	// owner-scoped get applies, for the same reason: this is an owner-scoped read that
	// was relying on LIMIT 1 for a uniqueness the query itself does not guarantee.
	//
	// BE HONEST ABOUT WHAT THIS ONE FIXES, BECAUSE IT IS NARROWER THAN THE GET'S. The
	// BOOLEAN here was already invariant under ambiguity: the UPDATE above hits EVERY
	// matching row, so whichever row the read-back landed on, a non-empty
	// kill_requested_at was true of all of them. This never returned a wrong answer.
	// What it did do is report SUCCESS for a session it could not identify — and the
	// caller then believes it has killed one specific shell when it has in fact
	// signalled an unknown number of them. The reap path (shell_session_reap.odin:202)
	// reaches this without going through the get above, so the get's refusal does not
	// already cover it.
	read: sqlite3_stmt = nil
	check := `SELECT kill_requested_at FROM shell_sessions WHERE owner_user_id = ? AND session_id = ? LIMIT 2;`
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(check)), -1, &read, nil) != SQLITE_OK {
		return false, domain.domain_error(.Internal_Error, "failed to prepare shell session kill intent read-back")
	}
	defer sqlite3_finalize(read)
	bind_text(read, 1, owner_user_id)
	bind_text(read, 2, session_id)
	if sqlite3_step(read) != SQLITE_ROW do return false, domain.Domain_Error{}
	// column_text_unowned borrows from the statement, so read the value out before the
	// next step invalidates it.
	pending := column_text_unowned(read, 0) != ""
	if sqlite3_step(read) == SQLITE_ROW {
		return false, domain.domain_error(.Conflict, "shell session id is ambiguous for this owner: refusing to confirm a kill intent")
	}
	return pending, domain.Domain_Error{}
}

// shell_session_list_pending_kills_sqlite lists one bridge's OUTSTANDING kill
// intents — the reconnect replay's query, and the only reader of the partial index
// migration 050 creates.
//
// "Outstanding" is `kill_requested_at != '' AND status NOT IN (terminal)`, which is
// domain.shell_session_kill_intent_pending expressed in SQL, with the terminal set
// BOUND from the domain's own table. A spent intent (one whose session already
// terminated) is excluded here as well as cleared by the upsert — belt and braces on
// purpose, since re-delivering a spent kill is exactly how a signal reaches a
// recycled pid.
//
// Owner-unscoped by design; see Shell_Session_List_Pending_Kills_Proc. Ordered
// oldest-first so the longest-waiting kill is delivered first, and bounded by
// `limit` as a runaway backstop rather than as pagination.
shell_session_list_pending_kills_sqlite :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	if bridge_id == "" do return nil, domain.Domain_Error{}
	lim := limit
	if lim <= 0 do lim = 100

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE bridge_id = ? AND kill_requested_at != '' AND status NOT IN (")
	strings.write_string(&b, shell_session_terminal_placeholders())
	strings.write_string(&b, ") ORDER BY kill_requested_at ASC, session_id ASC LIMIT ?;")
	query := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare shell session pending kill listing")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	for st, i in terminal do bind_text(stmt, 2 + i, st)
	sqlite3_bind_int(stmt, c.int(2 + len(terminal)), c.int(lim))

	out := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, shell_session_from_stmt(stmt))
	}
	return out, domain.Domain_Error{}
}

// shell_session_list_live_by_bridge_sqlite lists one bridge's NON-TERMINAL sessions —
// the hub side of REQ-SHELL-10's inventory diff.
//
// The terminal set is BOUND from domain.SHELL_SESSION_TERMINAL_STATUSES rather than
// written out, exactly as the pending-kill listing above binds it, so adding a sixth
// terminal status cannot leave this query treating it as live.
//
// Owner-unscoped, bridge-scoped; see Shell_Session_List_Live_By_Bridge_Proc. Ordered
// by session_id so a diff over a bridge is deterministic run to run, which is what
// makes "applying the same inventory twice changes nothing" testable rather than
// merely true in practice.
// shell_session_list_live_by_kind_sqlite is REQ-SHELL-9's age-reap candidate read:
// every live session of one kind, across all owners and bridges, OLDEST FIRST.
//
// Deliberately shaped like shell_session_list_live_by_bridge_sqlite directly below it
// rather than routed through shell_session_list_generic: that helper is the OWNER-SCOPED
// list path (it binds an owner and supports cursors), and this read has no owner. Reusing
// it would have meant teaching it an unscoped mode, i.e. giving the user-facing list
// routes a code path that can ignore the owner. The duplication here is four lines of
// query building; the alternative is a tenant-isolation hazard in the routes.
//
// The age cutoff is NOT in this query — see Shell_Session_List_Live_By_Kind_Proc for why
// the window stays in Odin next to the constant that justifies it.
shell_session_list_live_by_kind_sqlite :: proc(ctx: rawptr, kind: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	// An empty kind would match no row anyway, but returning early says so rather than
	// leaving a caller to read an empty result as "nothing to reap".
	if kind == "" do return nil, domain.Domain_Error{}
	lim := limit
	if lim <= 0 do lim = 100

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE kind = ? AND status NOT IN (")
	strings.write_string(&b, shell_session_terminal_placeholders())
	strings.write_string(&b, ") ORDER BY started_at ASC, session_id ASC LIMIT ?;")
	query := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare shell session live-by-kind listing")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, kind)
	for st, i in terminal do bind_text(stmt, 2 + i, st)
	sqlite3_bind_int(stmt, c.int(2 + len(terminal)), c.int(lim))

	out := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, shell_session_from_stmt(stmt))
	}
	return out, domain.Domain_Error{}
}

shell_session_list_live_by_bridge_sqlite :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	impl := (^Shell_Session_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil {
		return nil, domain.domain_error(.Internal_Error, "sqlite repository is not open")
	}
	if bridge_id == "" do return nil, domain.Domain_Error{}
	lim := limit
	if lim <= 0 do lim = 100

	terminal := domain.SHELL_SESSION_TERMINAL_STATUSES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT ")
	strings.write_string(&b, shell_session_select_cols)
	strings.write_string(&b, " FROM shell_sessions WHERE bridge_id = ? AND status NOT IN (")
	strings.write_string(&b, shell_session_terminal_placeholders())
	strings.write_string(&b, ") ORDER BY session_id ASC LIMIT ?;")
	query := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)

	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed to prepare shell session live listing")
	}
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, bridge_id)
	for st, i in terminal do bind_text(stmt, 2 + i, st)
	sqlite3_bind_int(stmt, c.int(2 + len(terminal)), c.int(lim))

	out := make([dynamic]domain.Shell_Session)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, shell_session_from_stmt(stmt))
	}
	return out, domain.Domain_Error{}
}
