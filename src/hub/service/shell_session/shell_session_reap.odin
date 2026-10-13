package shell_session

// REQ-SHELL-9 — SERVERS MUST NOT OUTLIVE THEIR PURPOSE.
//
// A `server` is the one kind with no natural end. A `run` is bounded by the 30-minute
// hard cap and a `shell` is an interactive terminal a person closes; a server is a
// long-running process started to serve something, and when the thing it served is over
// nothing in the system had an opinion about it. Two independent triggers close that,
// and they are independent on purpose — neither is a fallback for the other:
//
//   A. THE CHAIN CLOSED. Every server scoped to that chain dies. Purpose-driven, exact,
//      and immediate, hooked on the chain's terminal transition.
//   B. THE SERVER IS OLDER THAN A DAY. It dies regardless of chain state. This is the
//      backstop for a server whose chain never closes, or that was started outside any
//      chain's lifetime, and it rides the reaper that already runs.
//
// BOTH GO THROUGH THE REQ-SHELL-3 DURABLE KILL INTENT, never a bare send. A server on a
// disconnected bridge must still die when the bridge returns, which a fire-and-forget
// send cannot promise and an intent on the row can: shell_session_replay_kill_intents
// redelivers the outstanding set on reconnect. That is the whole reason this work
// depends on REQ-SHELL-3.
//
// ONLY SERVERS. A run and a shell are never touched by either trigger — see
// _reap_kill_if_eligible, which refuses any other kind even when a caller hands it one.

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// SHELL_SESSION_REAP_MAX_ROWS bounds one reap, a runaway backstop rather than
// pagination, in the same spirit as SHELL_SESSION_INVENTORY_MAX_ROWS and
// SHELL_SESSION_KILL_REPLAY_MAX. Both reaps are idempotent and both run repeatedly, so
// anything a cap truncates is picked up by the next pass rather than lost — which is
// what makes a plain cap the right answer here instead of paging.
//
// It sits well above the per-chain live-server cap (REQ-SHELL-2 §11), so for the chain
// reap it can only ever bite on a database that has already broken that invariant.
SHELL_SESSION_REAP_MAX_ROWS :: 512

// shell_session_reap_chain_servers kills every LIVE SERVER of one chain. It is trigger
// A, called from the task chain's terminal transition, and it returns how many kills it
// recorded.
//
// THE KIND FILTER IS THE QUERY'S, AND _reap_kill_if_eligible IS THE GATE. list_by_chain
// narrows on chain_id AND on the kinds that use .Chain (repo_sqlite's
// shell_session_kind_scope_clause, built from domain.SHELL_SESSION_SCOPE_RULES). Server
// keys on .Chain and a shell may optionally carry it, so this listing can return a
// chain-attached shell — but never a run. _reap_kill_if_eligible kills servers only,
// so a user's chain-attached interactive shell is never reaped with the chain.
//
// status = "live" comes from the same place: the repository translates it from
// domain.SHELL_SESSION_TERMINAL_STATUSES, so "already terminal" is excluded by the
// query, by the one definition of terminal, rather than by an eye-check here.
//
// OWNER-SCOPED, unlike the age reap: a chain row carries owner_user_id, so this path has
// a real owner and does not need an unscoped read. Passing the chain's owner also means
// a chain can only ever reap its OWN servers.
//
// REOPENING A CHAIN DOES NOT RESURRECT ANYTHING. valid_chain_transition allows
// Completed -> Active, and a chain reopened after this ran comes back with its servers
// dead. That is deliberate: the processes are gone, and a hub cannot restart a process
// it did not keep. Whoever reopens the chain starts what they still need.
shell_session_reap_chain_servers :: proc(svc: ^Shell_Session_Service, owner_user_id, chain_id: string) -> int {
	if svc == nil || svc.repo == nil || owner_user_id == "" || chain_id == "" do return 0

	// THE CURSOR IS OWNED AND MUST BE FREED, discarding it is a leak. It looks
	// ignorable — this proc does not page — but shell_session_list_where CLONES the last
	// row's session_id into it whenever the page is full, and its comment says so
	// explicitly: "every caller frees the page and the cursor independently". A `_` here
	// would leak silently and only ever on a FULL page, which is precisely the case no
	// small test produces.
	sessions, next_cursor, err := iface.shell_session_list_by_chain(
		svc.repo,
		owner_user_id,
		chain_id,
		domain.Shell_Session_Status_Group_Live,
		"",
		SHELL_SESSION_REAP_MAX_ROWS,
	)
	defer delete(next_cursor)
	// The listing returns owned rows. This runs on a request thread via the chain hook,
	// which has an arena, but the rows are freed explicitly anyway: the same proc is one
	// refactor away from the reaper thread, which has none, and a page of 512 rows is not
	// something to leave to a caller's context.
	//
	// ARMED BEFORE THE ERROR CHECK, deliberately. Today the sqlite repository returns a
	// nil slice alongside an error, so the order does not matter — but that is the
	// repository's current behaviour, not a contract the interface states, and a partial
	// page returned with an error would leak through an early return. Same ordering as
	// reaper_reap_gone_bridges, for the same reason.
	defer domain.shell_sessions_destroy(sessions)
	if err.code != .None do return 0

	reaped := 0
	for session in sessions {
		if _reap_kill_if_eligible(svc, session) do reaped += 1
	}
	return reaped
}

// shell_session_reap_aged_servers kills every LIVE SERVER whose age exceeds max_age_ms.
// It is trigger B, called from the reaper sweep, and it returns how many kills it
// recorded.
//
// `now_ms` and `max_age_ms` are PARAMETERS, not read from a clock here, which is what
// lets a test place a server 25 hours in the past instead of waiting 25 hours (AC2
// requires injected timestamps, not sleeping). The window's value and the argument for
// it live at REAPER_SERVER_MAX_AGE_MS in src/hub/app/reaper.odin, next to the other
// reaper thresholds.
//
// AGE IS MEASURED FROM started_at, NOT created_at. created_at is when the HUB WROTE THE
// ROW; started_at is when the PROCESS BEGAN. They differ by however long the start took
// to be confirmed, and a slow start is not age. The requirement is "servers older than
// one day", which is a statement about a running process, so the process's own clock is
// the one that answers it.
//
// A ROW WHOSE started_at IS EMPTY OR UNPARSEABLE IS SKIPPED, never reaped. An empty
// started_at means the hub has not yet been told the process began, and treating an
// unreadable timestamp as infinitely old would kill the youngest sessions in the table —
// the destructive direction. This mirrors reaper_bridge_absence_is_terminal and
// reap_stale_instances, both of which skip rather than guess. The cost is bounded and
// covered elsewhere: a session stuck without a started_at on a bridge that dies is
// closed by REQ-SHELL-14's gone-bridge sweep, and one on a live bridge is corrected by
// REQ-SHELL-10's inventory diff.
//
// A FUTURE-DATED started_at is likewise not old, which falls out of the signed
// comparison: clock skew between hub and bridge must not manufacture age.
shell_session_reap_aged_servers :: proc(svc: ^Shell_Session_Service, now_ms: i64, max_age_ms: i64) -> int {
	if svc == nil || svc.repo == nil || max_age_ms <= 0 do return 0

	sessions, err := iface.shell_session_list_live_by_kind(
		svc.repo,
		domain.Shell_Session_Kind_Server,
		SHELL_SESSION_REAP_MAX_ROWS,
	)
	// The reaper thread has no per-request arena. These rows are heap and are freed here
	// or not at all; a leak on this path accumulates every 20 seconds forever — which is
	// also why the free is armed BEFORE the error check rather than after it.
	defer domain.shell_sessions_destroy(sessions)
	if err.code != .None do return 0

	reaped := 0
	for session in sessions {
		if !shell_session_age_exceeds(session.started_at, now_ms, max_age_ms) do continue
		if _reap_kill_if_eligible(svc, session) do reaped += 1
	}
	return reaped
}

// shell_session_age_exceeds is the age test itself: has `started_at` been in the past
// for longer than max_age_ms?
//
// A separate, pure proc taking milliseconds rather than an inline comparison, for the
// same reason reaper_bridge_absence_is_terminal is one: the THRESHOLD DECISION is then
// testable with no repository, no clock and no session — a test can assert directly that
// 23 hours is young and 25 hours is old, which is the acceptance criterion this is judged
// on. See shell_session_reap_aged_servers for why unparseable and future-dated are both
// "not old".
shell_session_age_exceeds :: proc(started_at: string, now_ms: i64, max_age_ms: i64) -> bool {
	if started_at == "" do return false
	started_ms, ok := platform.rfc3339_to_unix_ms(started_at)
	if !ok do return false
	return now_ms - started_ms >= max_age_ms
}

// _reap_kill_if_eligible is the ONE gate both triggers pass through, and the one place
// the reap's skip rules are written. It returns whether a kill was recorded.
//
// THREE REFUSALS, in the order that makes each one's reason clearest:
//
//  1. NOT A SERVER -> refuse. A `run` is already bounded by the 30-minute hard cap and a
//     `shell` is an interactive terminal a person is sitting at; reaping either would be
//     destroying someone's live work on a timer. AC4 demands this be asserted rather
//     than inferred, so it is checked here even though the chain reap's query already
//     makes it structurally impossible — this is the assertion that survives a future
//     edit to the scope table, and the only kind check the age path has.
//
//  2. ALREADY TERMINAL -> refuse. The process is gone; an intent on a finished row is
//     spent by definition. Read through the domain predicate, not by comparing status
//     strings, so terminal means one thing everywhere.
//
//  3. ALREADY CARRYING A PENDING INTENT -> refuse, AND THIS IS WHERE THE REAP
//     DELIBERATELY DIFFERS FROM shell_session_kill. The user-facing accept path
//     RE-DISPATCHES a kill that is already pending, because a human clicking kill twice
//     means "try again" and redelivery is a no-op on the bridge. A sweep is not a human:
//     it runs every 20 seconds, so for a server on a bridge that has been offline for an
//     hour, re-dispatching would mean 180 identical sends that all fail, replacing the
//     one durable intent the design relies on with noise. The intent is already
//     recorded; the reconnect replay owns delivery from here. AC5 is this line.
//
// Both refusals 2 and 3 are why the reaps are safe to run repeatedly — which in turn is
// what makes it safe to call the chain reap from all three of the chain's close paths
// rather than hunting for a single choke point that does not exist.
_reap_kill_if_eligible :: proc(svc: ^Shell_Session_Service, session: domain.Shell_Session) -> bool {
	if session.kind != domain.Shell_Session_Kind_Server do return false
	if domain.shell_session_is_terminal(session) do return false
	if domain.shell_session_kill_intent_pending(session) do return false

	_, ok, _ := _shell_session_record_and_dispatch_kill(svc, session.owner_user_id, session.session_id, session.bridge_id, session.run_seq)
	return ok
}
