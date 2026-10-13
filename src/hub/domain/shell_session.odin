package domain

// Shell_Session is the hub-side record for a bridge-managed shell session.
// It is THE unified session concept per REQ-SH-CONTRACT §1. (It superseded a
// Shell_Job record, whose stack REQ-SHELL-7 deleted outright — named here only so
// the lineage is not a mystery, not as a type you can still find.)
//
// REQ-SHELL-1 collapsed the model to exactly THREE kinds, sharing ONE lifecycle:
//
//   run    — a one-shot command with captured stdout. Agent-triggered only.
//   shell  — an interactive PTY. User only; no stdout capture, it is a terminal.
//   server — a long-running process with stdout and an optional exposable port.
//
// The former `agent` kind is GONE, not renamed. It only ever meant "key the
// pty-host daemon by agent_instance_id instead of session_id", and agent
// terminal panes are served by a different mechanism entirely
// (capture_agent_pane / get_agent_pane in src/bridge/hub_runtime_client.odin),
// so nothing consumed it. `command` became `run` and `interactive` became
// `shell` as HARD renames — there is no back-compat requirement here, so there
// are deliberately no alias values and no dual-accept parsing. Migration
// 048_shell_sessions_kind_and_key.sql rewrites the stored rows.
Shell_Session_ID :: distinct string

Shell_Session_Kind :: enum {
	Run,
	Shell,
	Server,
}

shell_session_kind_string := [Shell_Session_Kind]string{
	.Run    = "run",
	.Shell  = "shell",
	.Server = "server",
}

// The wire/storage spelling of each kind, for the many callers that hold a
// string rather than the enum (the column is TEXT, and the bridge protocol is
// JSON). These are the SAME values as shell_session_kind_string — that table is
// the definition and these are named handles onto it, so a rename cannot land
// in one and miss the other.
Shell_Session_Kind_Run    :: "run"
Shell_Session_Kind_Shell  :: "shell"
Shell_Session_Kind_Server :: "server"

shell_session_kind_from_string :: proc(s: string) -> (Shell_Session_Kind, bool) {
	for spelling, kind in shell_session_kind_string {
		if s == spelling do return kind, true
	}
	return .Run, false
}

// --- per-kind scope rules (REQ-SHELL-1 §5) --------------------------------
//
// Scope governs ownership, listing and visibility, and it differs per kind:
//
//   run    — AGENT scoped.            Keyed by agent_instance_id.
//   server — TASK CHAIN + BRIDGE.     Keyed by chain_id AND bridge_id.
//   shell  — BRIDGE scoped.           Keyed by bridge_id; chain_id optional.
//
// This is ONE definition, in the same spirit as SHELL_SESSION_TERMINAL_STATUSES
// below: the service validates against it, the repository builds its list
// filters from it, and the handlers do neither of those themselves. Do not
// re-express a scope rule anywhere else — a second spelling is exactly the drift
// the terminal-status table exists to prevent.
Shell_Session_Scope_Column :: enum {
	Bridge,
	Chain,
	Agent_Instance,
}

// Shell_Session_Scope_Rule describes one kind's scope contract.
//
//   key       — the columns that IDENTIFY a session of this kind. Each must be
//               non-empty, and a list narrowed by one of these columns may
//               legitimately return this kind.
//   optional  — columns this kind MAY carry but does not require. When set, a
//               list narrowed by that column returns the session (the column's
//               value still has to match); when empty it is simply absent.
//   forbidden — the columns this kind does NOT use. Each must be EMPTY, rather
//               than filled with noise, and a list narrowed by one of them must
//               never return this kind.
//
// bridge_id is deliberately absent from `forbidden` everywhere: every session
// physically lives on a bridge and (bridge_id, session_id) is the table's
// primary key, so bridge_id is always populated. For `run` it simply is not the
// SCOPE key — which is why it is in neither set for that kind.
//
// A `shell` may optionally be attached to a task chain (chain_id) so it shows up
// in that chain's workbench; it stays bridge-scoped and is never chain-reaped
// (_reap_kill_if_eligible only kills servers).
Shell_Session_Scope_Rule :: struct {
	key:       bit_set[Shell_Session_Scope_Column],
	optional:  bit_set[Shell_Session_Scope_Column],
	forbidden: bit_set[Shell_Session_Scope_Column],
}

SHELL_SESSION_SCOPE_RULES := [Shell_Session_Kind]Shell_Session_Scope_Rule{
	.Run    = {key = {.Agent_Instance},   forbidden = {.Chain}},
	.Server = {key = {.Chain, .Bridge},   forbidden = {.Agent_Instance}},
	.Shell  = {key = {.Bridge},           optional = {.Chain}, forbidden = {.Agent_Instance}},
}

shell_session_scope_rule :: proc(kind: Shell_Session_Kind) -> Shell_Session_Scope_Rule {
	return SHELL_SESSION_SCOPE_RULES[kind]
}

// shell_session_scope_column_value reads the column a scope rule names off a
// record, so the validator and the repository agree on what "the chain column"
// means without either of them hand-writing the mapping.
shell_session_scope_column_value :: proc(s: Shell_Session, col: Shell_Session_Scope_Column) -> string {
	switch col {
	case .Bridge:         return s.bridge_id
	case .Chain:          return s.chain_id
	case .Agent_Instance: return s.agent_instance_id
	}
	return ""
}

shell_session_scope_column_name :: proc(col: Shell_Session_Scope_Column) -> string {
	switch col {
	case .Bridge:         return "bridge_id"
	case .Chain:          return "chain_id"
	case .Agent_Instance: return "agent_instance_id"
	}
	return ""
}

// shell_session_kinds_scoped_by returns the kinds a list narrowed by `col` may
// return: those whose scope key or optional set includes that column. A kind
// that forbids the column, or does not use it at all, is excluded — which is
// what stops a by-chain listing from handing back agent-scoped runs.
shell_session_kinds_scoped_by :: proc(col: Shell_Session_Scope_Column, out: ^[len(Shell_Session_Kind)]string) -> []string {
	n := 0
	for rule, kind in SHELL_SESSION_SCOPE_RULES {
		if col in rule.key || col in rule.optional {
			out[n] = shell_session_kind_string[kind]
			n += 1
		}
	}
	return out[:n]
}

// shell_session_validate_scope checks a record against its kind's scope rule.
// It is the ONE place a create is rejected for bad scoping, so a kind missing
// its required scope columns is refused rather than silently stored.
// Returns the offending column name and whether it was missing (vs. set when it
// must not be), so the caller can build a precise message.
shell_session_validate_scope :: proc(s: Shell_Session) -> (col: string, missing: bool, ok: bool) {
	kind, known := shell_session_kind_from_string(s.kind)
	if !known do return "kind", false, false
	// bridge_id backs the primary key for every kind, scope key or not.
	if s.bridge_id == "" do return "bridge_id", true, false
	rule := shell_session_scope_rule(kind)
	for c in Shell_Session_Scope_Column {
		v := shell_session_scope_column_value(s, c)
		if c in rule.key       && v == "" do return shell_session_scope_column_name(c), true,  false
		if c in rule.forbidden && v != "" do return shell_session_scope_column_name(c), false, false
	}
	return "", false, true
}

// --- per-kind starter rules (REQ-SHELL-2 §1, §7) ---------------------------
//
// WHO may start a kind, as a table rather than an if-chain, for the same reason
// SHELL_SESSION_SCOPE_RULES is a table: there is exactly one definition and the
// service reads it, so "run is agent-only" cannot be true at one call site and
// false at another.
//
//   run    — AGENT ONLY. A user can never start one (REQ-SHELL-2 §1: "enforce
//            that at the API, not only in the UI").
//   shell  — USER ONLY. It is an interactive terminal; an agent has no terminal
//            to type into.
//   server — EITHER. Explicitly "do not build an agent-only variant".
//
// This is AUTHORIZATION and is deliberately NOT part of the scope rules, which
// are STRUCTURAL (which columns identify a session). Conflating the two is what
// the coordinator's note rules out: nothing here may hide a user's own runs from
// them, and nothing in the scope rules may decide who is allowed to start what.
Shell_Session_Starter :: enum {
	Agent,
	User,
}

SHELL_SESSION_STARTER_RULES := [Shell_Session_Kind]bit_set[Shell_Session_Starter]{
	.Run    = {.Agent},
	.Shell  = {.User},
	.Server = {.Agent, .User},
}

// shell_session_kind_may_start answers whether `starter` is allowed to create a
// session of `kind`.
shell_session_kind_may_start :: proc(kind: Shell_Session_Kind, starter: Shell_Session_Starter) -> bool {
	return starter in SHELL_SESSION_STARTER_RULES[kind]
}

// shell_session_starters_string names a kind's permitted starters for an error
// message, so a refusal says what IS allowed rather than only what is not.
shell_session_starters_string :: proc(kind: Shell_Session_Kind) -> string {
	rule := SHELL_SESSION_STARTER_RULES[kind]
	switch rule {
	case {.Agent}:        return "an agent"
	case {.User}:         return "a user"
	case {.Agent, .User}: return "an agent or a user"
	}
	return "nobody"
}

// --- backgrounding (REQ-SHELL-2 §2, §3) -----------------------------------
//
// Only a `run` has a foreground form at all: a `shell` is a terminal with no
// caller to block, and a `server` is long-running by definition. So only a run
// can be backgrounded, and the flip is ONE-WAY — foreground -> background and
// never back.
//
// One-way is not tidiness, it is what makes the blocked caller's release
// unambiguous. The release happens exactly once, on the transition, and hands
// back the session id in the same shape a --bg start would have. If background
// could be cleared, a run could notify and then stop being notifiable, and a
// second waiter could attach to a session whose first waiter had already been
// released with a promise of notification.
shell_session_run_may_background :: proc(s: Shell_Session) -> (ok: bool, reason: string) {
	kind, known := shell_session_kind_from_string(s.kind)
	if !known do return false, "unknown session kind"
	if kind != .Run do return false, "only a run can be backgrounded"
	if shell_session_is_terminal(s) do return false, "session has already terminated"
	if s.background do return false, "session is already running in the background"
	return true, ""
}

// --- live-session caps (REQ-SHELL-2 §11) ----------------------------------
//
// Nothing bounded how many sessions an agent or a chain could spawn, so a loop
// that starts a session per iteration could exhaust the host's pids, ports and
// output disk with no refusal anywhere in the system.
//
// The caps below are deliberately far above any legitimate workflow — they are a
// RUNAWAY BACKSTOP, not a scheduling policy. Nothing should ever plan around
// them, and a workflow that hits one has a bug, which is exactly what the
// refusal is meant to surface.
//
// The scope of each cap follows the kind's own scope rule rather than being
// chosen independently: runs are agent-scoped, so the cap is per agent instance;
// servers are chain-scoped, so the cap is per chain. Only LIVE sessions count —
// a terminal one holds nothing.
SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT :: 32
SHELL_SESSION_MAX_LIVE_SERVERS_PER_CHAIN :: 16

Shell_Session_Status_Starting :: "starting"
Shell_Session_Status_Running  :: "running"
Shell_Session_Status_Exited   :: "exited"
Shell_Session_Status_Killed   :: "killed"
Shell_Session_Status_Failed   :: "failed"

// The two STATUS GROUP names a list filter accepts in place of a concrete status.
// They are not statuses and are never stored on a record — no row's status column
// ever holds "live" or "finished". They exist so a query can express the
// terminal/non-terminal split the domain has always owned (see
// SHELL_SESSION_TERMINAL_STATUSES and shell_session_is_terminal below), which
// before this had no spelling at the query layer at all.
Shell_Session_Status_Group_Live     :: "live"
Shell_Session_Status_Group_Finished :: "finished"

// SHELL_SESSION_TERMINAL_STATUSES is the single definition of "this session is
// over". shell_session_is_terminal reads it, and the repository's `finished` /
// `live` filters build their SQL from it, so a sixth status can never be terminal
// in one place and live in the other. Add a status here and both follow.
SHELL_SESSION_TERMINAL_STATUSES :: [3]string{
	Shell_Session_Status_Exited,
	Shell_Session_Status_Killed,
	Shell_Session_Status_Failed,
}

Shell_Session :: struct {
	session_id:          string,
	owner_user_id:       string,
	bridge_id:           string,
	project_id:          string,
	chain_id:            string,
	agent_instance_id:   string,
	kind:                string, // "run" | "shell" | "server" (see Shell_Session_Kind)
	label:               string,
	cmd:                 string,
	cwd:                 string,
	status:              string, // "starting" | "running" | "exited" | "killed" | "failed"
	exit_code:           int,
	exit_code_set:       bool,
	pid:                 int,
	server_port:         int,
	preview_enabled:     bool,
	// background — kind=run only, and ONE-WAY (see shell_session_run_may_background).
	// REQ-SHELL-2 deleted the implicit 15s auto-background rule, so this is the
	// whole of the foreground/background distinction: it is asked for at start
	// (--bg) or flipped on a live run by the user, never inferred from elapsed
	// time. ONLY a background run notifies on completion; a foreground run returns
	// its result to the blocked caller inline and notifies nothing.
	background:          bool,
	// conversation_id — the conversation that TRIGGERED this session, not a scope
	// column (scope is SHELL_SESSION_SCOPE_RULES alone). It is an annotation in the
	// same sense project_id is: it says where a completion notice is delivered,
	// which REQ-SHELL-2 §5 requires on the row because REQ-SHELL-5 scopes the
	// marker message to the triggering conversation ONLY.
	conversation_id:     string,
	// kill_requested_at — REQ-SHELL-3. The durable record that a kill was ACCEPTED
	// for this session; "" means none outstanding. It exists because a kill used to
	// be fire-and-forget: requested while the bridge was offline, it failed and
	// persisted nothing, so nothing re-issued it on reconnect and the process ran
	// forever. With it, accepting a kill for an offline bridge SUCCEEDS — the intent
	// is durable and the delivery is asynchronous.
	//
	// A timestamp, not a flag: it answers "pending since when", and it is
	// first-writer-wins so a second kill of the same session keeps the moment the
	// user first asked rather than sliding forward on every retry.
	//
	// SET is not the same as OUTSTANDING — see shell_session_kill_intent_pending.
	kill_requested_at:   string,
	// run_seq — REQ-SHELL-4. WHICH RUN of this session is current. A session_id is
	// not a run: shell_session_restart re-spawns under the same session_id, so a run
	// is the pair (session_id, run_seq).
	//
	// It exists because REQ-SHELL-4 made the bridge's shell_exited queue durable, and
	// a durable queue can deliver an exit AFTER the session has been restarted and is
	// genuinely alive again. Applying that exit would mark a live session terminal —
	// the "hub says terminal, bridge says running" divergence this chain exists to
	// remove, manufactured by the durability mechanism itself. The hub discards an
	// exit whose run_seq is not the row's current one.
	//
	// HUB-ASSIGNED, bridge-echoed, following the precedent REQ-SHELL-1 §8 set for
	// started_at rather than adding a second source of truth. INCREMENTED ONLY BY
	// shell_session_restart, so its value is exactly "restarts so far" and 0 is the
	// first run — which is also what every pre-migration-051 row and every bridge
	// spec written before this change reads back as, so old and new agree with no
	// backfill.
	//
	// Not a discriminator borrowed from an existing field, deliberately: started_at
	// is assigned once at create and is an INPUT to the pid-liveness check
	// (bridge_shell_session_pid_is_plausible, REQ-SHELL-2 P6), and pid is re-stamped
	// by the hub on restart but NOT by the bridge — which is the side that writes the
	// exit envelope. See migration 051 for the full reasoning.
	run_seq:             int,
	started_at:          string,
	finished_at:         string,
	created_at:          string,
	last_activity_at:    string,
}

shell_session_is_terminal :: proc(s: Shell_Session) -> bool {
	return shell_session_status_is_terminal(s.status)
}

// shell_session_kill_intent_pending answers whether this session still has a kill
// to deliver. It is deliberately NOT "kill_requested_at != \"\"": an intent on a
// session that has already reached a terminal status is SPENT, not pending — the
// process it named is gone, and re-delivering would at best be a no-op and at worst
// a signal aimed at a pid the OS has since recycled.
//
// One definition, read by every consumer: the service before it dispatches, the
// reconnect replay before it re-delivers, and the repository's pending-kill listing
// (which builds the same predicate in SQL from SHELL_SESSION_TERMINAL_STATUSES).
// This is the same reason SHELL_SESSION_TERMINAL_STATUSES itself is one table —
// "still needs killing" must not be true in one layer and false in the next.
shell_session_kill_intent_pending :: proc(s: Shell_Session) -> bool {
	if s.kill_requested_at == "" do return false
	return !shell_session_is_terminal(s)
}

// shell_session_terminal_is_observed answers a question ABOUT A TERMINAL ROW that
// the status vocabulary alone cannot: did anyone actually WATCH this process end?
//
// Two very different things reach a terminal status here:
//
//   OBSERVED   — a bridge reported the exit. The bridge waited on the child, so it
//                knows the process is gone and knows its exit code. This is
//                knowledge.
//   SYNTHESIZED — the hub concluded the process must be gone without seeing it end:
//                shell_session_create's failure path, and (REQ-SHELL-14) the sweep
//                that lands a terminal status on the sessions of a bridge that is
//                never coming back. This is a well-founded guess.
//
// REQ-SHELL-4 needs the distinction because the two orderings are not symmetric. A
// bridge that was written off and then returns with the real exit must be allowed to
// correct the guess — otherwise a synthesized status permanently outranks ground
// truth, and the session keeps a fabricated exit_code forever. The reverse is never
// allowed: a guess must not overwrite an observation.
//
// EXIT_CODE_SET IS THE DISCRIMINATOR, and it is reused rather than duplicated with a
// new provenance column because it already carries exactly this meaning: every
// bridge-reported exit sets it (all three bridge_shell_exited_event_json call sites
// pass exit_code_set=true — bridge_shell_session.odin:1113, :1192,
// pty_host_runtime.odin:616), and no hub-synthesized terminal can set it, because
// the hub has no exit code to record. An observed exit is precisely one that came
// with an observed code.
//
// THE CONDITION ON THAT REUSE, which REQ-SHELL-14 must honour: a synthesized
// terminal status must NOT invent an exit_code_set=true. The moment a hub-side path
// stamps a fabricated exit code, this predicate silently starts calling a guess an
// observation, and the supersession above stops working with no test failing. If
// REQ-SHELL-14 needs to record a code it did not observe, this predicate must move
// to an explicit provenance field FIRST — which is why the question is asked in one
// named place instead of being spelled `!s.exit_code_set` at the call site.
shell_session_terminal_is_observed :: proc(s: Shell_Session) -> bool {
	return s.exit_code_set
}

// shell_session_status_is_terminal is the same question asked of a bare status
// string, for callers that have a status but no record (a filter value, say).
shell_session_status_is_terminal :: proc(status: string) -> bool {
	for terminal in SHELL_SESSION_TERMINAL_STATUSES {
		if status == terminal do return true
	}
	return false
}

shell_session_destroy :: proc(s: Shell_Session) {
	delete(s.session_id)
	delete(s.owner_user_id)
	delete(s.bridge_id)
	delete(s.project_id)
	delete(s.chain_id)
	delete(s.agent_instance_id)
	delete(s.kind)
	delete(s.conversation_id)
	delete(s.kill_requested_at)
	delete(s.label)
	delete(s.cmd)
	delete(s.cwd)
	delete(s.status)
	delete(s.started_at)
	delete(s.finished_at)
	delete(s.created_at)
	delete(s.last_activity_at)
}

shell_sessions_destroy :: proc(sessions: [dynamic]Shell_Session) {
	for s in sessions do shell_session_destroy(s)
	delete(sessions)
}
