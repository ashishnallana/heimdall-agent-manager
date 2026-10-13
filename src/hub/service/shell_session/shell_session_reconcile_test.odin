// Behavioral tests for shell_session_service bridge inventory reconciliation, parser resilience, viewer reattachment, and bridge disconnect reaping.
#+private file
package shell_session

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- Consolidated from shell_session_req10_test.odin ---

@(private = "file")
Repo10 :: struct {
	stored: map[string]domain.Shell_Session, // "<bridge_id>\x00<session_id>" -> row
	writes: int,
	// When set, r10_list_pending_kills scopes by bridge_id ONLY and does not apply
	// domain.shell_session_kill_intent_pending itself. It models a repository whose
	// QUERY failed to encode the rule — which is the exact situation the service's
	// re-check exists for: "this re-asks with the domain's own predicate so the rule is
	// enforced by the definition rather than by trusting the SQL to have encoded it"
	// (shell_session_service.odin:826). With the fake applying the predicate too, a
	// spent row never reaches the service and that re-check cannot be observed at all.
	// Default false, so every other test still exercises the faithful query.
	pending_kills_unfiltered: bool,
}

@(private = "file")
r10_key :: proc(bridge_id, session_id: string) -> string {
	// context.temp_allocator: keys are compared and cloned by the map on insert, so a
	// per-call scratch string is enough and nothing here has to be freed by hand.
	return strings.concatenate({bridge_id, "\x00", session_id}, context.temp_allocator)
}

@(private = "file")
r10_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	out := s
	out.session_id        = strings.clone(s.session_id)
	out.owner_user_id     = strings.clone(s.owner_user_id)
	out.bridge_id         = strings.clone(s.bridge_id)
	out.project_id        = strings.clone(s.project_id)
	out.chain_id          = strings.clone(s.chain_id)
	out.agent_instance_id = strings.clone(s.agent_instance_id)
	out.kind              = strings.clone(s.kind)
	out.conversation_id   = strings.clone(s.conversation_id)
	out.label             = strings.clone(s.label)
	out.cmd               = strings.clone(s.cmd)
	out.cwd               = strings.clone(s.cwd)
	out.status            = strings.clone(s.status)
	out.kill_requested_at = strings.clone(s.kill_requested_at)
	out.started_at        = strings.clone(s.started_at)
	out.finished_at       = strings.clone(s.finished_at)
	out.created_at        = strings.clone(s.created_at)
	out.last_activity_at  = strings.clone(s.last_activity_at)
	return out
}

@(private = "file")
r10_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	r.writes += 1
	key := r10_key(session.bridge_id, session.session_id)
	next := r10_clone(session)
	if prev, had := r.stored[key]; had {
		// Mirror the real upsert's kill_requested_at CASE: a terminal status clears the
		// intent structurally (REQ-SHELL-3), a non-empty incoming value sets it,
		// otherwise the stored value survives. This diff writes no intent of its own and
		// relies on exactly that auto-clear, so a fake without it would let the test pass
		// while the real thing left a spent intent behind.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = _r10_replace(next.kill_requested_at, "")
		case session.kill_requested_at != "":                          // keep incoming
		case:                                                          next.kill_requested_at = _r10_replace(next.kill_requested_at, prev.kill_requested_at)
		}
		domain.shell_session_destroy(prev)
	} else if domain.shell_session_status_is_terminal(next.status) {
		next.kill_requested_at = _r10_replace(next.kill_requested_at, "")
	}
	// Clone the key only when INSERTING: assigning to an existing entry keeps the map's
	// original key, so cloning unconditionally would leak one key string per update.
	if _, present := r.stored[key]; present {
		r.stored[key] = next
	} else {
		r.stored[strings.clone(key)] = next
	}
	return true, domain.Domain_Error{}
}

// _r10_replace frees a clone's field and returns a fresh clone of `with`, so the
// stored row stays wholly repo-owned whichever branch above ran.
@(private = "file")
_r10_replace :: proc(current, with: string) -> string {
	delete(current)
	return strings.clone(with)
}

@(private = "file")
r10_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	// Owner-scoped and bridge-agnostic, like the real owner-scoped get.
	for _, s in r.stored {
		if s.session_id == session_id && s.owner_user_id == owner_user_id do return r10_clone(s), true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

// Bridge-scoped and owner-unscoped, like the real get_by_id. The bridge check is the
// fake's whole point for AC4: a session belonging to another bridge must not resolve.
@(private = "file")
r10_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	s, had := r.stored[r10_key(bridge_id, session_id)]
	if !had do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return r10_clone(s), true, domain.Domain_Error{}
}

@(private = "file")
r10_list_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r10_clone(s))
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
r10_list_pending_kills :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo10)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if !r.pending_kills_unfiltered && !domain.shell_session_kill_intent_pending(s) do continue
		append(&out, r10_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink10 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
s10_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink10)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
s10_count :: proc(s: ^Sink10, type_name: string) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	needle := strings.concatenate({"\"type\":\"", type_name, "\""})
	defer delete(needle)
	n := 0
	for b in s.bodies {
		if strings.contains(b, needle) do n += 1
	}
	return n
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx10 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo10,
	sink: Sink10,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
NOW10 :: "2026-09-28T12:00:00Z"

@(private = "file")
now10 :: proc(ctx: rawptr) -> string { _ = ctx; return strings.clone(NOW10) }

@(private = "file")
fx10_make :: proc(fx: ^Fx10) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx                 = rawptr(&fx.r),
		upsert              = r10_upsert,
		get                 = r10_get,
		get_by_id           = r10_get_by_id,
		list_live_by_bridge = r10_list_live_by_bridge,
		list_pending_kills  = r10_list_pending_kills,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now10}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                  = rawptr(&fx.sink),
			send_runtime_command = s10_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx10_free :: proc(fx: ^Fx10) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
}

@(private = "file")
Seed10 :: struct {
	session_id:    string,
	bridge_id:     string,
	status:        string,
	exit_code_set: bool,
	run_seq:       int,
	kill_at:       string,
}

@(private = "file")
fx10_seed :: proc(fx: ^Fx10, seed: Seed10) {
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = "owner_a",
		bridge_id         = seed.bridge_id,
		kind              = domain.Shell_Session_Kind_Shell,
		cmd               = "zsh",
		status            = seed.status,
		exit_code_set     = seed.exit_code_set,
		run_seq           = seed.run_seq,
		kill_requested_at = seed.kill_at,
		started_at        = "2026-09-28T09:00:00Z",
	}
	fx.r.stored[strings.clone(r10_key(seed.bridge_id, seed.session_id))] = r10_clone(row)
}

@(private = "file")
fx10_row :: proc(fx: ^Fx10, session_id: string, bridge_id := "brg_1") -> (domain.Shell_Session, bool) {
	s, had := fx.r.stored[r10_key(bridge_id, session_id)]
	return s, had
}

// inv10 builds an inventory frame the way the bridge does, so these tests exercise
// the real parser rather than a convenient shape it never sees.
@(private = "file")
inv10 :: proc(entries: []string, truncated := false) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_inventory\",\"sessions\":[")
	for e, i in entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "],\"truncated\":")
	strings.write_string(&b, truncated ? "true" : "false")
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
Entry10 :: struct {
	session_id: string,
	status:     string,
	kind:       string,
	owner:      string,
	pid:        int,
	run_seq:    int,
}

@(private = "file")
entry10 :: proc(e: Entry10) -> string {
	kind := e.kind if e.kind != "" else domain.Shell_Session_Kind_Shell
	owner := e.owner if e.owner != "" else "owner_a"
	status := e.status if e.status != "" else domain.Shell_Session_Status_Running
	b := strings.builder_make()
	strings.write_string(&b, "{\"session_id\":\"")
	strings.write_string(&b, e.session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	strings.write_string(&b, kind)
	strings.write_string(&b, "\",\"status\":\"")
	strings.write_string(&b, status)
	strings.write_string(&b, "\",\"shell_id\":\"\",\"started_at\":\"2026-09-28T09:00:00Z\",\"label\":\"\",\"cmd\":\"zsh\",\"cwd\":\"/tmp\",\"owner_user_id\":\"")
	strings.write_string(&b, owner)
	strings.write_string(&b, "\",\"project_id\":\"\",\"chain_id\":\"\",\"agent_instance_id\":\"\",\"background\":false,\"pid\":")
	strings.write_int(&b, e.pid)
	strings.write_string(&b, ",\"server_port\":0,\"run_seq\":")
	strings.write_int(&b, e.run_seq)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// --- AC1: the three diff branches --------------------------------------------

// BRANCH (a): the hub believes a session is live; the bridge's complete inventory
// does not name it. It died while we were away — invariant (b), for the reconnect
// case. The status must be TERMINAL but NOT OBSERVED: fabricating an exit code here
// would make this guess outrank a real exit that may still arrive from the bridge's
// durable outbox (see domain.shell_session_terminal_is_observed).
@(test)
test_t10_absent_row_goes_terminal :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_gone", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	frame := inv10({}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.terminated, 1)
	row, had := fx10_row(&fx, "sh_gone")
	testing.expect(t, had, "the row must still exist — converging is not deleting")
	testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
	testing.expect_value(t, row.finished_at, NOW10)
	testing.expect(t, !domain.shell_session_terminal_is_observed(row),
		"a status the hub SYNTHESIZED must not claim to be an observed exit, or a late real exit can never correct it")
}

// BRANCH (b): the bridge is running a session the hub has no row for — invariant (a),
// "running on a bridge but untracked by the hub". Adopting it is what makes it
// listable and killable instead of an invisible process.
@(test)
test_t10_untracked_session_is_adopted :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)

	e := entry10(Entry10{session_id = "sh_new", pid = 4242, run_seq = 3}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.adopted, 1)
	row, had := fx10_row(&fx, "sh_new")
	testing.expect(t, had, "an untracked live session must become a row")
	testing.expect_value(t, row.bridge_id, "brg_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.pid, 4242)
	// The bridge's echo is the only record of which run this is; taking it is what
	// stops a later exit for run 3 being discarded as stale against a row that had
	// defaulted to 0.
	testing.expect_value(t, row.run_seq, 3)
}

// BRANCH (c): both sides know the session and disagree about its status. The bridge
// owns the processes and has just observed this one, so the bridge wins.
@(test)
test_t10_bridge_wins_on_status_disagreement :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_1", bridge_id = "brg_1", status = domain.Shell_Session_Status_Starting})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running, pid = 99}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.corrected, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.pid, 99)
}

// --- "hub says terminal, bridge says running" — REQ-SHELL-14's dependency -----

// The case REQ-SHELL-14 exists to create: it writes off the sessions of a bridge it
// judges gone, necessarily WITHOUT observing anything. If that bridge returns with the
// process alive, this diff is the only thing that can undo the guess — so the guess
// must lose to the bridge's observation.
@(test)
test_t10_unobserved_terminal_is_revived :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Failed, exit_code_set = false, // synthesized
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.finished_at, "")
}

// The exception, and the reason reviving is conditional rather than unconditional: a
// terminal the hub OBSERVED for THIS run is not a guess, it is a report from a bridge
// that watched the process end. Resurrecting a row on the strength of a claim that
// contradicts something we watched happen would be adopting the WORSE evidence.
@(test)
test_t10_observed_terminal_is_not_revived :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Exited, exit_code_set = true, run_seq = 2, // observed
	})

	e := entry10(Entry10{session_id = "sh_1", run_seq = 2}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 0)
	testing.expect_value(t, res.conflicted, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Exited)
}

// …but a NEWER run is not that conflict at all: the bridge restarted the session, so
// it is describing a different run from the one the hub watched end, and it wins as
// usual. Without this, a restart whose hub-side write was lost would leave the session
// permanently terminal with a live process behind it.
@(test)
test_t10_observed_terminal_loses_to_a_newer_run :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Exited, exit_code_set = true, run_seq = 2,
	})

	e := entry10(Entry10{session_id = "sh_1", run_seq = 3}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
}

// --- AC4: a bridge may only ever touch its own sessions ----------------------

// The check that matters most in this file. One inventory mutates MANY rows, so a
// missing scope check here is not one leaked session but a whole bridge's worth —
// and, in practice, another user's.
@(test)
test_t10_inventory_cannot_touch_another_bridge :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_b", bridge_id = "brg_2", status = domain.Shell_Session_Status_Running})

	// Bridge A names bridge B's session, both as a live entry and by omitting it.
	e := entry10(Entry10{session_id = "sh_b"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	// B's row is untouched: not corrected, not revived, and — crucially — not
	// TERMINATED, even though bridge A's inventory is complete and A's live-row query
	// is what drives the "absent means dead" branch.
	b_row, b_had := fx10_row(&fx, "sh_b", "brg_2")
	testing.expect(t, b_had, "bridge B's row must still exist")
	testing.expect_value(t, b_row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, b_row.bridge_id, "brg_2")
	testing.expect_value(t, res.corrected, 0)
	testing.expect_value(t, res.terminated, 0)
	testing.expect_value(t, res.revived, 0)
	// A's entry resolved to nothing on A (the lookup is bridge-scoped), so it took the
	// adopt path — and adoption stamps the REPORTING bridge's id. Whatever that created
	// is A's own row under the composite key (bridge_id, session_id), never B's.
	if res.adopted == 1 {
		a_row, a_had := fx10_row(&fx, "sh_b", "brg_1")
		testing.expect(t, a_had, "the adopted row belongs to the reporting bridge")
		testing.expect_value(t, a_row.bridge_id, "brg_1")
	}
}

// --- AC5: idempotence --------------------------------------------------------

// Reconnect flapping delivers the same inventory repeatedly. The second application
// must write nothing and publish nothing, or a bridge that reconnects five times in a
// minute produces five rounds of events for one convergence.
@(test)
test_t10_same_inventory_twice_is_a_noop :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_1", bridge_id = "brg_1", status = domain.Shell_Session_Status_Starting})
	fx10_seed(&fx, Seed10{session_id = "sh_gone", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running}); defer delete(e)
	e2 := entry10(Entry10{session_id = "sh_new"}); defer delete(e2)
	frame := inv10({e, e2}); defer delete(frame)

	first := shell_session_apply_inventory(&fx.svc, "brg_1", frame)
	testing.expect(t, shell_session_inventory_changed(first), "the first apply must converge something")
	writes_after_first := fx.r.writes

	second := shell_session_apply_inventory(&fx.svc, "brg_1", frame)
	testing.expect(t, !shell_session_inventory_changed(second), "the second apply must change nothing")
	testing.expect_value(t, second.adopted, 0)
	testing.expect_value(t, second.corrected, 0)
	testing.expect_value(t, second.terminated, 0)
	testing.expect_value(t, second.revived, 0)
	testing.expect_value(t, fx.r.writes, writes_after_first)
}

// --- truncation: a bound must not become a death sentence --------------------

// The "it died while we were away" branch reasons from ABSENCE, and a truncated
// inventory cannot establish absence — only that the bridge ran out of room. Reading a
// full buffer as a death report would kill off rows whose processes are alive, which
// is strictly worse than the stale row it set out to fix.
@(test)
test_t10_truncated_inventory_does_not_terminate :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_unlisted", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	e := entry10(Entry10{session_id = "sh_new"}); defer delete(e)
	frame := inv10({e}, truncated = true); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.terminated, 0)
	row, _ := fx10_row(&fx, "sh_unlisted")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	// Presence-based branches are unaffected by truncation, so adoption still happens.
	testing.expect_value(t, res.adopted, 1)
}

// --- AC2 / invariant (c): the kill lands on reconnect ------------------------

// The window this closes: shell_session_replay_kill_intents runs on the bridge-WS
// ACCEPT path, strictly before this frame can arrive. A session revived (or adopted)
// by the diff was therefore not in the set that replay read, and its durable kill
// would wait for a further reconnect that may never come.
@(test)
test_t10_kill_intent_replayed_for_revived_session :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Failed, // a REQ-SHELL-14-style guess
		kill_at = "2026-09-28T11:00:00Z",
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.revived, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 1)
	testing.expect_value(t, res.kills_replayed, 1)
}

// A diff that changed nothing writes nothing and publishes nothing.
//
// THIS TEST USED TO ASSERT THE DEFECT, and the change is worth recording rather than
// quietly editing. It seeded a row CARRYING AN OUTSTANDING KILL INTENT, applied a clean
// inventory, and asserted that no shell_kill was sent — locking in the exact production
// failure of REQ-SHELL-23 as if it were the specification. Its rationale ("the replay is
// conditioned on convergence so a no-op inventory stays a no-op end to end") was the
// gate's own self-justification promoted to an invariant; whether an inventory found
// discrepancies and whether a durable kill is outstanding are unrelated facts.
//
// What survives is the part that was always true and is still enforced: a no-op diff
// performs no WRITES and no PUBLISHES. The seed no longer carries an intent, because
// "clean inventory + outstanding intent" has the opposite expected outcome and now lives
// in t23_clean_inventory_still_replays_an_outstanding_kill. The no-intent case — a clean
// inventory must not start inventing kills — is t23_clean_inventory_with_no_intent_sends_nothing.
@(test)
test_t10_noop_inventory_replays_no_kills :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status = domain.Shell_Session_Status_Running,
	})

	e := entry10(Entry10{session_id = "sh_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	writes_before := fx.r.writes
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect(t, !shell_session_inventory_changed(res), "nothing diverged, so nothing should be written")
	testing.expect_value(t, fx.r.writes, writes_before)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 0)
}

// --- refusals ----------------------------------------------------------------

// Adoption is the one branch that CREATES a row, so it is the one an entry could use
// to manufacture junk. A row with no owner is invisible to every owner-scoped read and
// unkillable through the API — worse than the untracked process it meant to fix — and
// one that violates its kind's scope rule would be returned by the wrong listings for
// the rest of its life (REQ-SHELL-1 §5).
@(test)
test_t10_unadoptable_entries_are_refused :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)

	no_owner := entry10(Entry10{session_id = "sh_no_owner", owner = " "}); defer delete(no_owner)
	// kind=shell is BRIDGE scoped and forbids agent_instance_id, so this entry
	// contradicts its own kind's scope rule.
	bad_scope_src := entry10(Entry10{session_id = "sh_bad_scope"}); defer delete(bad_scope_src)
	bad_scope, _ := strings.replace(bad_scope_src, "\"agent_instance_id\":\"\"", "\"agent_instance_id\":\"inst_x\"", 1)
	defer delete(bad_scope)
	unknown_kind := entry10(Entry10{session_id = "sh_bad_kind", kind = "agent"}); defer delete(unknown_kind)
	// A terminal status in an inventory is refused: ending a session belongs to the
	// exit path, which carries the exit code this frame does not.
	terminal := entry10(Entry10{session_id = "sh_terminal", status = domain.Shell_Session_Status_Exited}); defer delete(terminal)

	frame := inv10({no_owner, bad_scope, unknown_kind, terminal}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.adopted, 0)
	testing.expect_value(t, res.ignored, 4)
	for id in ([]string{"sh_no_owner", "sh_bad_scope", "sh_bad_kind", "sh_terminal"}) {
		_, had := fx10_row(&fx, id)
		testing.expectf(t, !had, "%s must not have been stored", id)
	}
}

// --- the parser --------------------------------------------------------------

// A shell session's cmd is arbitrary user text. A brace counter alone would end the
// object early on `echo "}"`, truncating every field after it — silently, since the
// result is a well-formed entry with missing values. The key scan has the same hazard
// in reverse: a cmd containing `"pid":` must not be read as the field.
@(test)
test_t10_parse_survives_json_lookalikes_in_cmd :: proc(t: ^testing.T) {
	frame := strings.concatenate({
		"{\"type\":\"shell_inventory\",\"sessions\":[",
		"{\"session_id\":\"sh_1\",\"kind\":\"shell\",\"status\":\"running\",",
		"\"cmd\":\"echo '}' && echo \\\"pid\\\": 7 && echo [sessions]\",",
		"\"owner_user_id\":\"owner_a\",\"pid\":31337,\"run_seq\":0},",
		"{\"session_id\":\"sh_2\",\"kind\":\"shell\",\"status\":\"running\",\"cmd\":\"zsh\",\"owner_user_id\":\"owner_a\",\"pid\":2,\"run_seq\":0}",
		"],\"truncated\":false}",
	})
	defer delete(frame)

	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].session_id, "sh_1")
	testing.expect_value(t, entries[0].pid, 31337)
	testing.expect_value(t, entries[1].session_id, "sh_2")
	testing.expect_value(t, entries[1].pid, 2)
}

// REQ-P1-INVENTORY: Command lines containing quotes, braces, and backslashes decode with high fidelity.
@(test)
test_t10_parse_escapes_and_special_characters :: proc(t: ^testing.T) {
	// Sample frame from REQ-P1-INVENTORY specification
	frame := `{"type":"shell_inventory","bridge_id":"brg_1","truncated":false,"sessions":[{"session_id":"sh_1","cmd":"echo \"hello world\" && echo }","kind":"run","status":"running","pid":1234}]}`
	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect_value(t, entries[0].session_id, "sh_1")
		// Quotes and braces must decode cleanly without remaining backslash artifacts
		testing.expect_value(t, entries[0].cmd, `echo "hello world" && echo }`)
		testing.expect_value(t, entries[0].kind, "run")
		testing.expect_value(t, entries[0].status, "running")
		testing.expect_value(t, entries[0].pid, 1234)
	}

	// Complex command line with paths, quotes, backslashes, braces
	complex_frame := `{"type":"shell_inventory","bridge_id":"brg_1","truncated":false,"sessions":[{"session_id":"sh_complex","cmd":"cmd.exe /c \"dir \\\"C:\\\\Program Files\\\\test\\\" && {echo done}\"","kind":"shell","status":"running"}]}`
	complex_entries := shell_session_inventory_parse(complex_frame)
	defer delete(complex_entries)

	testing.expect_value(t, len(complex_entries), 1)
	if len(complex_entries) == 1 {
		testing.expect_value(t, complex_entries[0].session_id, "sh_complex")
		testing.expect_value(t, complex_entries[0].cmd, `cmd.exe /c "dir \"C:\\Program Files\\test\" && {echo done}"`)
	}
}

// REQ-P1-INVENTORY: Reordered keys and arbitrary whitespace/newlines parse without error.
@(test)
test_t10_parse_reordered_keys_and_whitespace :: proc(t: ^testing.T) {
	frame := `
	{
		"truncated": false,
		"bridge_id": "brg_custom",
		"sessions": [
			{
				"run_seq": 7,
				"background": true,
				"pid": 4321,
				"server_port": 9090,
				"agent_instance_id": "inst_worker_99",
				"chain_id": "chain_77",
				"project_id": "proj_reorder",
				"owner_user_id": "usr_reorder",
				"cwd": "/opt/workspace",
				"cmd": "server --debug",
				"label": "worker background service",
				"started_at": "2026-10-03T10:00:00Z",
				"shell_id": "shl_root",
				"status": "starting",
				"kind": "server",
				"session_id": "sh_reordered"
			}
		],
		"type": "shell_inventory"
	}
	`
	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		e := entries[0]
		testing.expect_value(t, e.session_id, "sh_reordered")
		testing.expect_value(t, e.kind, "server")
		testing.expect_value(t, e.status, "starting")
		testing.expect_value(t, e.shell_id, "shl_root")
		testing.expect_value(t, e.started_at, "2026-10-03T10:00:00Z")
		testing.expect_value(t, e.label, "worker background service")
		testing.expect_value(t, e.cmd, "server --debug")
		testing.expect_value(t, e.cwd, "/opt/workspace")
		testing.expect_value(t, e.owner_user_id, "usr_reorder")
		testing.expect_value(t, e.project_id, "proj_reorder")
		testing.expect_value(t, e.chain_id, "chain_77")
		testing.expect_value(t, e.agent_instance_id, "inst_worker_99")
		testing.expect_value(t, e.background, true)
		testing.expect_value(t, e.pid, 4321)
		testing.expect_value(t, e.server_port, 9090)
		testing.expect_value(t, e.run_seq, 7)
	}
}

// REQ-P1-INVENTORY: Zero memory leaks and bad frees under Odin tracking allocator.
@(test)
test_t10_parse_tracking_allocator_zero_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	for _ in 0..<10 {
		frame := `{"type":"shell_inventory","bridge_id":"brg_1","truncated":false,"sessions":[{"session_id":"sh_leak","cmd":"echo \"test\" && echo }","kind":"run","status":"running","pid":999}]}`
		entries := shell_session_inventory_parse(frame)
		delete(entries)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// The coordinator asked for the replay window to be pinned on the ADOPTED path as
// well as the revived one. It cannot be: a kill intent lives ON A ROW
// (kill_requested_at), and adoption is by definition the branch where NO ROW EXISTS —
// so an adopted session cannot carry a pre-existing intent, and there is no state to
// construct the test from. Reported rather than faked with a hand-placed intent no
// real code path could have written.
//
// The CORRECTED path can carry one, and it exercises the same window for the same
// reason, so it is pinned here instead: the accept-path replay saw this row before the
// inventory arrived, and whether the kill goes out in THIS reconnect or waits for a
// further one that may never come is decided by the re-run after the diff.
@(test)
test_t10_kill_intent_replayed_for_corrected_session :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{
		session_id = "sh_1", bridge_id = "brg_1",
		status  = domain.Shell_Session_Status_Starting,
		kill_at = "2026-09-28T11:00:00Z", // accepted while the bridge was offline
	})

	e := entry10(Entry10{session_id = "sh_1", status = domain.Shell_Session_Status_Running}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.corrected, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 1)
	testing.expect_value(t, res.kills_replayed, 1)
	// The intent is still OUTSTANDING, not cleared by delivery: it retires when a
	// terminal status lands, which is REQ-SHELL-3's structural auto-clear and not this
	// path's business. Clearing it here would strand the session if the kill were lost.
	row, _ := fx10_row(&fx, "sh_1")
	testing.expect(t, domain.shell_session_kill_intent_pending(row),
		"an intent is spent by a terminal status landing, not by being dispatched")
}

// --- the production clock's ALLOCATION contract -------------------------------

// REGRESSION. This diff once did `defer delete(now)` on the result of
// platform.clock_now, and it crash-looped the production hub: every bridge reconnect
// sends an inventory, so every reconnect freed a pointer the heap never handed out.
//
// WHY 64 GREEN TESTS SHIPPED A SEGFAULT, and the only reason this test exists in this
// shape: the fixture clock above (now10) returns strings.clone(NOW10) — a HEAP block —
// so under test the bad free was a perfectly legal one. The real clock
// (platform.real_clock_now -> format_rfc3339_utc -> fmt.tprintf) returns TEMP-arena
// memory. The fake was not merely simpler than production, it had the opposite
// ownership, which is the one way a fake can hide a bug rather than just miss it.
//
// So this fixture allocates the way PRODUCTION does, and the test installs its OWN
// mem.Tracking_Allocator to ASSERT on the outcome rather than leave it to the runner.
// That matters: `odin test`'s built-in tracking reports an invalid free as a WARN line
// and still calls the run successful, which is precisely the reporting level that let
// this ship. bad_free_count must be 0 for the test to pass, so a re-introduced
// `delete(now)` fails CI instead of printing a warning nobody gates on.
@(private = "file")
now10_temp :: proc(ctx: rawptr) -> string {
	_ = ctx
	return fmt.tprintf("%s", NOW10) // temp arena, exactly like format_rfc3339_utc
}

@(test)
test_t10_apply_does_not_free_the_clock_string :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx.clk.now = now10_temp // production's allocation contract, not the fixture's
	fx.svc.clock = &fx.clk

	// One entry to adopt and one live row to reap: both write branches read `now`.
	fx10_seed(&fx, Seed10{session_id = "sh_gone", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	e := entry10(Entry10{session_id = "sh_new", pid = 4242}); defer delete(e)
	frame := inv10({e}); defer delete(frame)

	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	// THE ASSERTION THIS TEST EXISTS FOR. Every pointer this call freed must be one
	// the heap allocator actually issued. `now` is not.
	testing.expect_value(t, len(track.bad_free_array), 0)
	for bf in track.bad_free_array {
		testing.expectf(t, false, "freed a pointer the heap never allocated: %p at %v", bf.memory, bf.location)
	}

	testing.expect_value(t, res.adopted, 1)
	testing.expect_value(t, res.terminated, 1)
	// The timestamp still has to LAND, so this cannot be satisfied by simply not
	// reading the clock.
	adopted, _ := fx10_row(&fx, "sh_new")
	testing.expect_value(t, adopted.created_at, NOW10)
	reaped, _ := fx10_row(&fx, "sh_gone")
	testing.expect_value(t, reaped.finished_at, NOW10)
}

// --- REQ-SHELL-23: a CLEAN inventory must still deliver an outstanding kill -----
//
// THIS IS THE TEST THAT WOULD HAVE CAUGHT REQ-SHELL-23 ON THE HUB SIDE, and it is
// deliberately not the shape of the REQ-SHELL-3 replay tests, which all call
// shell_session_replay_kill_intents DIRECTLY. Calling it directly proves it works when
// it is called; it cannot prove it is REACHED. This test asserts reachability through
// apply_inventory, which is the only thing the production failure disagreed with.
//
// WHY IT FAILS BEFORE THE FIX, precisely: the replay used to be guarded by
// `if shell_session_inventory_changed(result)`. The row seeded below already agrees with
// the inventory entry in every field the diff inspects — same session, running, same pid,
// same run_seq — so nothing is adopted, corrected, terminated or revived, the guard is
// false, and the kill is never re-issued. kills_replayed comes back 0 and no shell_kill
// reaches the sink. The healthier the rest of the state, the more reliably the kill was
// dropped, which is why a no-op inventory is the exact case worth pinning down.
@(test)
test_t23_clean_inventory_still_replays_an_outstanding_kill :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	// Running, correct pid, and carrying a durable kill intent the bridge never got.
	fx10_seed(&fx, Seed10{
		session_id = "sh_live",
		bridge_id  = "brg_1",
		status     = domain.Shell_Session_Status_Running,
		kill_at    = "2026-09-28T11:00:00Z",
	})

	// An inventory that agrees with the row completely, so the diff is a clean no-op.
	e := entry10(Entry10{session_id = "sh_live", status = domain.Shell_Session_Status_Running})
	defer delete(e)
	frame := inv10({e}); defer delete(frame)

	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect(t, !shell_session_inventory_changed(res),
		"the inventory must be a genuine no-op, or this test is not exercising the gate that was removed")
	testing.expect_value(t, res.kills_replayed, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 1)
}

// The other half of the same rule: ungating the replay must not make a reconnect with
// NOTHING outstanding start sending kills. A clean inventory over rows carrying no intent
// costs one empty query and sends nothing — which is what makes removing the gate a free
// trade rather than a louder bridge.
@(test)
test_t23_clean_inventory_with_no_intent_sends_nothing :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	fx10_seed(&fx, Seed10{session_id = "sh_live", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})

	e := entry10(Entry10{session_id = "sh_live", status = domain.Shell_Session_Status_Running})
	defer delete(e)
	frame := inv10({e}); defer delete(frame)

	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect(t, !shell_session_inventory_changed(res), "still a no-op diff")
	testing.expect_value(t, res.kills_replayed, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 0)
}

// AC5, on the path this task changed: a SPENT intent is never re-delivered by the newly
// ungated replay. The row is terminal, so domain.shell_session_kill_intent_pending refuses
// it even though kill_requested_at is still stamped — the pid it names may since have been
// recycled. Without this, running the replay on every inventory would turn a stale
// timestamp into a signal against an unrelated process.
//
// IT TESTS THE SERVICE'S RE-CHECK, which took a deliberate fix to be true (REQ-SHELL-13).
// This test used to set `pending_kills_unfiltered` not at all, and was VACUOUS as a result:
// the fake applied domain.shell_session_kill_intent_pending in its own query, so the spent
// row never reached the service and the re-check at shell_session_service.odin:829 never
// ran. The test passed with that line deleted outright — which is worse than no test,
// because it licenses deleting the real guard and seeing green.
//
// With the flag set, the fake returns the spent row and the SERVICE's re-check is the only
// thing that can exclude it. Verified by deleting that line and watching this test fail.
//
// The other AC5 coverage — that a spent row is excluded from the OUTSTANDING count as well
// as from delivery — lives in test_req3_replay_delivers_outstanding_kills_on_reconnect
// (req3_test.odin:110), whose fake filters by bridge_id only for the same reason.
@(test)
test_t23_ungated_replay_never_redelivers_a_spent_intent :: proc(t: ^testing.T) {
	fx: Fx10; fx10_make(&fx); defer fx10_free(&fx)
	// The whole point of the test: let the spent row PAST the fake's query so the
	// service's own predicate is what refuses it.
	fx.r.pending_kills_unfiltered = true
	fx10_seed(&fx, Seed10{
		session_id    = "sh_spent",
		bridge_id     = "brg_1",
		status        = domain.Shell_Session_Status_Killed,
		exit_code_set = true,
		kill_at       = "2026-09-28T11:00:00Z",
	})
	// A live session so the diff has something to adopt, proving the replay really ran.
	e := entry10(Entry10{session_id = "sh_new", status = domain.Shell_Session_Status_Running})
	defer delete(e)
	frame := inv10({e}); defer delete(frame)

	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect(t, shell_session_inventory_changed(res), "sh_new must be adopted, so the replay is reached")
	testing.expect_value(t, res.kills_replayed, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_kill"), 0)
}

// =============================================================================
// REQ-SHELL-40 — Pass 3: a reconnect re-attaches the OUTPUT STREAM of every
// still-viewed live session.
//
// THEY LIVE IN THIS FILE, not a file of their own, and that is deliberate: the fix is
// an extension of T10's convergence path (AC3), so it is tested against T10's own fake
// repository and sink rather than a second fixture that could drift from it. Reusing
// Fx10 also means these tests exercise the REAL inventory parser via inv10/entry10.
//
// NO PTY AND NO BROWSER (AC6). The viewer sockets below are bare net.TCP_Socket
// descriptor numbers that are never read or written — Pass 3 only ever asks whether the
// viewer LIST for a session is non-empty, so a fabricated descriptor is a faithful
// stand-in and the test cannot hang on IO. What is asserted is the COMMAND the hub
// emits, which is the whole of the hub's half of the protocol.
//
// THE FALSE-PASS SHAPE THESE ARE BUILT TO AVOID. shell_session_attach ITSELF sends an
// attach on the 0->1 transition, so a test that merely counted attaches after
// attach+apply would read 1 and pass whether or not Pass 3 ran at all. Every test below
// therefore takes a BASELINE after attaching and asserts the DELTA across
// apply_inventory. Deleting the Pass 3 call must turn these red; it does.
// =============================================================================

// t40_baseline captures the attach count after fixture setup so each assertion is about
// what the INVENTORY caused, never about what attaching a viewer caused.
@(private = "file")
t40_baseline :: proc(fx: ^Fx10) -> int {
	return s10_count(&fx.sink, "shell_stream_attach")
}

@(test)
test_t40_reconnect_reattaches_a_viewed_live_session :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	fx10_seed(&fx, Seed10{session_id = "sh_viewed", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_viewed", net.TCP_Socket(401), "brg_1")
	testing.expect_value(t, shell_session_viewer_count(&fx.svc, "sh_viewed"), 1)
	base := t40_baseline(&fx)

	// The reconnect. Nothing about the VIEWER changed — which is exactly why the old
	// code did nothing here: from the hub's point of view no viewer ever left.
	e := entry10(Entry10{session_id = "sh_viewed"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 1)
	// A clean reconnect must still be a clean reconnect: re-attaching writes no row, so
	// T10's idempotency predicate must keep reading false.
	testing.expect(t, !shell_session_inventory_changed(res), "a re-attach writes no row and must not register as a change")
}

@(test)
test_t40_reconnect_does_not_reattach_an_unviewed_session :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// Live on the bridge, live on the hub, and NOBODY IS WATCHING — the common case
	// (`ham-ctl shell run` with no pane open). Attaching here would spawn a pty-host
	// socket and a thread on the bridge to carry bytes to no one, which is the leak half
	// of the invariant in the other direction.
	fx10_seed(&fx, Seed10{session_id = "sh_unwatched", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	testing.expect_value(t, shell_session_viewer_count(&fx.svc, "sh_unwatched"), 0)

	e := entry10(Entry10{session_id = "sh_unwatched"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach"), 0)
}

@(test)
test_t40_reattach_is_scoped_to_the_bridge_that_sent_the_inventory :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// The session and its viewer belong to brg_1. brg_2 then names it in its own
	// inventory — which a compromised or simply confused bridge can do, since the frame
	// is untrusted payload. The attach must not be sent, and must not be sent to EITHER
	// bridge: brg_2 does not own the session, and an inventory from brg_2 is no evidence
	// at all about what brg_1 is running.
	fx10_seed(&fx, Seed10{session_id = "sh_owned_by_1", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_owned_by_1", net.TCP_Socket(402), "brg_1")
	base := t40_baseline(&fx)

	e := entry10(Entry10{session_id = "sh_owned_by_1"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_2", frame)

	testing.expect_value(t, res.reattached, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 0)
}

@(test)
test_t40_a_terminal_inventory_entry_is_not_reattached :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// The hub still thinks it is running and a pane is still open, but the bridge says
	// it is over. The bridge wins — the same rule T10 applies to rows, applied to the
	// command. Re-attaching here would ask the bridge to stream a dead process.
	fx10_seed(&fx, Seed10{session_id = "sh_done", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_done", net.TCP_Socket(403), "brg_1")
	base := t40_baseline(&fx)

	e := entry10(Entry10{session_id = "sh_done", status = "exited"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 0)
}

@(test)
test_t40_many_viewers_on_one_session_reattach_once :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// AC4's real hazard, and the likeliest way a fix here becomes a worse bug than the
	// one it fixes. There is ONE stream worker per SESSION on the bridge, not one per
	// viewer, so a pass that iterated viewers instead of sessions would ask the bridge
	// to attach three times for one session on every reconnect. The bridge's early
	// return would absorb it today, which is precisely why this needs asserting on the
	// HUB side: a bug the other end silently tolerates is a bug that survives.
	fx10_seed(&fx, Seed10{session_id = "sh_crowded", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_crowded", net.TCP_Socket(404), "brg_1")
	shell_session_attach(&fx.svc, "sh_crowded", net.TCP_Socket(405), "brg_1")
	shell_session_attach(&fx.svc, "sh_crowded", net.TCP_Socket(406), "brg_1")
	testing.expect_value(t, shell_session_viewer_count(&fx.svc, "sh_crowded"), 3)
	base := t40_baseline(&fx)

	e := entry10(Entry10{session_id = "sh_crowded"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 1)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 1)
}

@(test)
test_t40_a_reconnect_storm_sends_one_attach_per_reconnect :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// STATING THE IDEMPOTENCE HONESTLY RATHER THAN OVERCLAIMING IT. Three reconnects send
	// three attaches, and that is correct, not a leak: each reconnect really did empty
	// the bridge's worker set, so each one really does need an attach. What must NOT
	// happen is growth — 1 then 3 then 6 — which is what a pass that accumulated state
	// across applies would produce. The dedup that turns the 2nd and 3rd into no-ops
	// lives on the bridge (bridge_pty_stream_worker_start returns early for a live
	// worker), and it is asserted there, in t40_reattach_of_a_live_worker_creates_no_second_worker.
	fx10_seed(&fx, Seed10{session_id = "sh_flap", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_flap", net.TCP_Socket(407), "brg_1")
	base := t40_baseline(&fx)

	e := entry10(Entry10{session_id = "sh_flap"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	for i in 1 ..= 3 {
		res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)
		testing.expect_value(t, res.reattached, 1)
		testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, i)
	}
}

@(test)
test_t40_a_viewer_that_left_during_the_outage_is_not_reattached :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// The leak direction, from the hub's side. The pane closed while the bridge was away,
	// so the detach was sent into a dead socket and DROPPED — send_runtime_command is
	// fire-and-forget and returns .Bridge_Offline without queueing. The hub must not then
	// re-attach on reconnect and resurrect a stream for a pane that is gone. What reaps
	// the worker the dropped detach left behind is the bridge's teardown of every worker
	// on disconnect (bridge_pty_stream_stop_all_for_reconnect), so after this reconnect
	// there is no worker and no viewer — converged, both directions.
	fx10_seed(&fx, Seed10{session_id = "sh_left", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	sock := net.TCP_Socket(408)
	shell_session_attach(&fx.svc, "sh_left", sock, "brg_1")
	shell_session_detach(&fx.svc, "sh_left", sock, "brg_1")
	testing.expect_value(t, shell_session_viewer_count(&fx.svc, "sh_left"), 0)
	base := t40_baseline(&fx)

	e := entry10(Entry10{session_id = "sh_left"}); defer delete(e)
	frame := inv10({e}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 0)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 0)
}

@(test)
test_t40_one_reconnect_reattaches_every_viewed_session :: proc(t: ^testing.T) {
	fx: Fx10
	fx10_make(&fx)
	defer fx10_free(&fx)

	// EVERY OTHER TEST HERE PUTS EXACTLY ONE SESSION IN THE INVENTORY, so none of them can
	// tell "re-attaches the viewed sessions" from "re-attaches the FIRST viewed session".
	// A reconnect on a real bridge carries the whole roster, and a host with three panes
	// open across two sessions is ordinary — so a loop that broke after the first match, or
	// that reused one target for all of them, would have passed the entire suite above.
	//
	// The unviewed third session is in the same frame deliberately: it proves the loop
	// SKIPS rather than stops, which is the other way a break-vs-continue slip hides.
	fx10_seed(&fx, Seed10{session_id = "sh_a", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	fx10_seed(&fx, Seed10{session_id = "sh_b", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	fx10_seed(&fx, Seed10{session_id = "sh_c", bridge_id = "brg_1", status = domain.Shell_Session_Status_Running})
	shell_session_attach(&fx.svc, "sh_a", net.TCP_Socket(410), "brg_1")
	shell_session_attach(&fx.svc, "sh_c", net.TCP_Socket(411), "brg_1")
	// sh_b is live and un-viewed, and sits BETWEEN the two viewed ones in the frame.
	base := t40_baseline(&fx)
	// The INDEX of the first body Pass 3 will write, so the per-session assertions below
	// can look at ONLY what the inventory caused. Scanning the whole sink is contaminated:
	// the two shell_session_attach calls above each already sent an attach naming sh_a and
	// sh_c, so "did I see an attach for sh_c" is true no matter what Pass 3 did. That is the
	// same false-PASS shape the delta assertions exist to avoid, and it defeated this test's
	// name checks until a red run exposed them as unfalsifiable.
	sync.mutex_lock(&fx.sink.mu)
	from := len(fx.sink.bodies)
	sync.mutex_unlock(&fx.sink.mu)

	ea := entry10(Entry10{session_id = "sh_a"}); defer delete(ea)
	eb := entry10(Entry10{session_id = "sh_b"}); defer delete(eb)
	ec := entry10(Entry10{session_id = "sh_c"}); defer delete(ec)
	frame := inv10({ea, eb, ec}); defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_1", frame)

	testing.expect_value(t, res.reattached, 2)
	testing.expect_value(t, s10_count(&fx.sink, "shell_stream_attach") - base, 2)

	// Named explicitly rather than counted, so a loop that sent two attaches for the SAME
	// session would fail here instead of passing on the count alone.
	sync.mutex_lock(&fx.sink.mu)
	saw_a, saw_b, saw_c := false, false, false
	for body in fx.sink.bodies[from:] {
		if !strings.contains(body, "\"type\":\"shell_stream_attach\"") do continue
		if strings.contains(body, "\"session_id\":\"sh_a\"") do saw_a = true
		if strings.contains(body, "\"session_id\":\"sh_b\"") do saw_b = true
		if strings.contains(body, "\"session_id\":\"sh_c\"") do saw_c = true
	}
	sync.mutex_unlock(&fx.sink.mu)
	testing.expect(t, saw_a, "the first viewed session must be re-attached")
	testing.expect(t, saw_c, "a viewed session AFTER an unviewed one must also be re-attached")
	testing.expect(t, !saw_b, "an unviewed session in the same frame must never be re-attached")
}

// --- Consolidated from shell_session_req13_test.odin ---

@(test)
test_t13_truncated_lookalike_in_a_cmd_loses_to_the_real_flag :: proc(t: ^testing.T) {
	// Decoy says false and comes first; the real trailing flag says true.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"echo \"truncated\":false"}],"truncated":true}`
	testing.expect(
		t,
		_json_bool(frame, "truncated"),
		"the real trailing truncated:true must win over a decoy inside a cmd",
	)
}

// The other direction, which is the dangerous one: reading `truncated` as FALSE on a list
// that really was cut short makes the caller reap by ABSENCE over an incomplete inventory
// and land a terminal status on HEALTHY sessions. That is why this guard is load-bearing
// and worth a self-contained read.
@(test)
test_t13_truncated_lookalike_cannot_fake_a_true :: proc(t: ^testing.T) {
	// Decoy says true and comes first; the real trailing flag says false.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"x \"truncated\":true y"}],"truncated":false}`
	testing.expect(
		t,
		!_json_bool(frame, "truncated"),
		"a truncated:true lookalike inside a cmd must not be read as the frame's flag",
	)

	// With no real flag present at all, the answer is false rather than the decoy's value:
	// a key occurring only INSIDE a literal is not a key.
	decoy_only := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"\"truncated\":true"}]}`
	testing.expect(
		t,
		!_json_bool(decoy_only, "truncated"),
		"an absent flag must read false even when a literal contains the key",
	)
}

// AC-C. Under earlier hand-rolled lexers, an unescaped or unhandled `}` inside command
// content risked driving depth counters to 0 or negative and dropping subsequent entries.
// With typed unmarshaling via `core:encoding/json`, braces within string values do not
// affect object boundaries.
@(test)
test_t13_stray_close_brace_does_not_drop_later_entries :: proc(t: ^testing.T) {
	// Two real entries with a closing brace inside the first session's cmd.
	frame := `{"type":"shell_inventory","sessions":[{"session_id":"sh_1","cmd":"echo }"},{"session_id":"sh_2","cmd":"echo ok"}],"truncated":false}`
	entries := shell_session_inventory_parse(frame)
	defer delete(entries)

	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].session_id, "sh_1")
		testing.expect_value(t, entries[0].cmd, "echo }")
		// The entry AFTER the brace is unmarshaled cleanly without being dropped.
		testing.expect_value(t, entries[1].session_id, "sh_2")
		testing.expect_value(t, entries[1].cmd, "echo ok")
	}
}

// --- Consolidated from shell_session_req14_test.odin ---

@(private = "file")
Repo14 :: struct {
	stored: map[string]domain.Shell_Session, // "<bridge_id>\x00<session_id>" -> row
	writes: int,
}

@(private = "file")
r14_key :: proc(bridge_id, session_id: string) -> string {
	return strings.concatenate({bridge_id, "\x00", session_id}, context.temp_allocator)
}

@(private = "file")
r14_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
	out := s
	out.session_id        = strings.clone(s.session_id)
	out.owner_user_id     = strings.clone(s.owner_user_id)
	out.bridge_id         = strings.clone(s.bridge_id)
	out.project_id        = strings.clone(s.project_id)
	out.chain_id          = strings.clone(s.chain_id)
	out.agent_instance_id = strings.clone(s.agent_instance_id)
	out.kind              = strings.clone(s.kind)
	out.conversation_id   = strings.clone(s.conversation_id)
	out.label             = strings.clone(s.label)
	out.cmd               = strings.clone(s.cmd)
	out.cwd               = strings.clone(s.cwd)
	out.status            = strings.clone(s.status)
	out.kill_requested_at = strings.clone(s.kill_requested_at)
	out.started_at        = strings.clone(s.started_at)
	out.finished_at       = strings.clone(s.finished_at)
	out.created_at        = strings.clone(s.created_at)
	out.last_activity_at  = strings.clone(s.last_activity_at)
	return out
}

@(private = "file")
_r14_replace :: proc(current, with: string) -> string {
	delete(current)
	return strings.clone(with)
}

@(private = "file")
r14_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	r.writes += 1
	key := r14_key(session.bridge_id, session.session_id)
	next := r14_clone(session)
	if prev, had := r.stored[key]; had {
		// The real upsert's kill_requested_at CASE (REQ-SHELL-3): a terminal status
		// clears the intent, a non-empty incoming value sets it, otherwise the stored
		// value survives. This task writes no intent of its own and depends entirely on
		// that clause, so the fake must have it.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = _r14_replace(next.kill_requested_at, "")
		case session.kill_requested_at != "":                          // keep incoming
		case:                                                          next.kill_requested_at = _r14_replace(next.kill_requested_at, prev.kill_requested_at)
		}
		domain.shell_session_destroy(prev)
		r.stored[key] = next
	} else {
		if domain.shell_session_status_is_terminal(next.status) {
			next.kill_requested_at = _r14_replace(next.kill_requested_at, "")
		}
		r.stored[strings.clone(key)] = next
	}
	return true, domain.Domain_Error{}
}

// Bridge-scoped and owner-unscoped, like the real get_by_id. The bridge check is the
// load-bearing part: it is what stops one bridge's inventory resolving another's row.
//
// RETURNS AN OWNED CLONE, because _apply_inventory_entry does
// `defer domain.shell_session_destroy(row)` on what this hands back. A fake returning
// its own stored pointers would have the service free the map's contents out from under
// it — the ownership rule the sqlite reader satisfies by construction.
@(private = "file")
r14_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	s, had := r.stored[r14_key(bridge_id, session_id)]
	if !had do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return r14_clone(s), true, domain.Domain_Error{}
}

// r14_list_live_by_bridge is the read the reap drives: this bridge's NON-terminal rows.
// "Live" is domain.shell_session_is_terminal inverted, the same rule the SQL builds from
// domain.SHELL_SESSION_TERMINAL_STATUSES, so the fake cannot disagree with it about which
// rows are candidates.
@(private = "file")
r14_list_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo14)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.bridge_id != bridge_id do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r14_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx14 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo14,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// NOW14 is when the SWEEP runs. Absence is expressed by seeding a bridge's last_seen_at
// in the past relative to it (in the app-package tests); here it is simply the timestamp
// the reap is expected to stamp into finished_at.
@(private = "file")
NOW14 :: "2026-09-28T12:00:00Z"

@(private = "file")
now14 :: proc(ctx: rawptr) -> string { _ = ctx; return strings.clone(NOW14) }

@(private = "file")
fx14_make :: proc(fx: ^Fx14) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx                 = rawptr(&fx.r),
		upsert              = r14_upsert,
		get_by_id           = r14_get_by_id,
		list_live_by_bridge = r14_list_live_by_bridge,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now14}
	fx.svc = new_shell_session_service(repo = &fx.repo, ids = &fx.ids, clock = &fx.clk)
}

@(private = "file")
fx14_free :: proc(fx: ^Fx14) {
	shell_session_service_free(&fx.svc)
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
}

@(private = "file")
Seed14 :: struct {
	session_id:    string,
	bridge_id:     string,
	status:        string,
	exit_code:     int,
	exit_code_set: bool,
	run_seq:       int,
	kill_at:       string,
}

@(private = "file")
fx14_seed :: proc(fx: ^Fx14, seed: Seed14) {
	status := seed.status if seed.status != "" else domain.Shell_Session_Status_Running
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = "owner_a",
		bridge_id         = seed.bridge_id,
		kind              = domain.Shell_Session_Kind_Shell,
		cmd               = "zsh",
		status            = status,
		exit_code         = seed.exit_code,
		exit_code_set     = seed.exit_code_set,
		run_seq           = seed.run_seq,
		kill_requested_at = seed.kill_at,
		started_at        = "2026-09-28T09:00:00Z",
	}
	fx.r.stored[strings.clone(r14_key(seed.bridge_id, seed.session_id))] = r14_clone(row)
}

@(private = "file")
fx14_row :: proc(fx: ^Fx14, session_id: string, bridge_id := "brg_gone") -> (domain.Shell_Session, bool) {
	s, had := fx.r.stored[r14_key(bridge_id, session_id)]
	return s, had
}

// --- tests -------------------------------------------------------------------

// The core write: a bridge judged gone has EVERY live row moved to a terminal status
// with finished_at set, which is what stops the hub reporting them live.
@(test)
test_t14_gone_bridge_live_rows_go_terminal :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})
	fx14_seed(&fx, Seed14{session_id = "sh_2", bridge_id = "brg_gone", status = domain.Shell_Session_Status_Starting})

	moved := shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14)
	testing.expect_value(t, moved, 2)

	for id in ([]string{"sh_1", "sh_2"}) {
		row, had := fx14_row(&fx, id)
		testing.expect(t, had, "row must still exist — reaping is a status change, not a delete")
		// The EXISTING unobserved-terminal spelling, not a new status value.
		testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
		testing.expect(t, domain.shell_session_status_is_terminal(row.status), "status must be in the terminal set")
		testing.expect_value(t, row.finished_at, NOW14)
		testing.expect_value(t, row.last_activity_at, NOW14)
	}
}

// exit_code_set MUST stay false. It is the discriminator
// domain.shell_session_terminal_is_observed reads to tell a hub-side guess from a
// bridge-reported fact: the moment this path stamps a fabricated code, the guess
// outranks ground truth, REQ-SHELL-4's supersession in shell_session_handle_exited stops
// firing, and the revive below — the entire safety net under the one-hour threshold —
// goes with it. This is a condition on the mechanism, not a preference.
@(test)
test_t14_reap_never_fabricates_an_exit_code :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	row, _ := fx14_row(&fx, "sh_1")
	testing.expect(t, !row.exit_code_set, "a path that observed nothing must report no exit code")
	testing.expect_value(t, row.exit_code, 0)
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(row),
		"the terminal must remain UNOBSERVED so a returning bridge's real exit code still wins",
	)
}

// Already-terminal rows are not candidates, so the sweep is idempotent — it runs every
// 20 seconds and must not rewrite rows or re-emit events on each tick. The observed
// terminal in particular must survive untouched: overwriting a real exit code with a
// guess is the same defect as fabricating one.
@(test)
test_t14_already_terminal_rows_are_untouched :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{
		session_id = "sh_observed", bridge_id = "brg_gone",
		status = domain.Shell_Session_Status_Exited, exit_code = 7, exit_code_set = true,
	})
	fx14_seed(&fx, Seed14{session_id = "sh_live", bridge_id = "brg_gone"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)
	writes_after_first := fx.r.writes

	observed, _ := fx14_row(&fx, "sh_observed")
	testing.expect_value(t, observed.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, observed.exit_code, 7)
	testing.expect(t, observed.exit_code_set, "a bridge-reported exit code must not be overwritten by a guess")

	// Second tick: nothing left live, so no rows move and no writes are issued.
	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 0)
	testing.expect_value(t, fx.r.writes, writes_after_first)
}

// One bridge's absence says nothing about another's. The reap is scoped by bridge_id,
// which matters because the candidate listing that drives it is owner-unscoped and
// host-wide.
@(test)
test_t14_reap_cannot_touch_another_bridge :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})
	fx14_seed(&fx, Seed14{session_id = "sh_2", bridge_id = "brg_healthy"})

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	other, had := fx14_row(&fx, "sh_2", "brg_healthy")
	testing.expect(t, had, "the healthy bridge's row must still be there")
	testing.expect_value(t, other.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, other.finished_at, "")
}

// ACCEPTANCE: a pending kill_requested_at is cleared BY the transition, through
// REQ-SHELL-3's existing auto-clear in the upsert's CASE — with no REQ-SHELL-3 code in
// this task. That is the proof the two compose: T3 clears the intent whenever any
// terminal status lands, and on a bridge that never returns this reap is the only thing
// that can ever land one, so without it the kill intent would also stick forever.
@(test)
test_t14_pending_kill_intent_is_cleared :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{
		session_id = "sh_1", bridge_id = "brg_gone",
		kill_at = "2026-09-28T11:00:00Z", // requested while the bridge was already silent
	})
	before, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, before.kill_requested_at, "2026-09-28T11:00:00Z")

	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)

	row, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, row.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)
	testing.expect_value(t, row.kill_requested_at, "")
}

// ACCEPTANCE, and the CONDITION the one-hour threshold rests on: a row this task
// synthesized to `failed` is REVIVED when the bridge comes back with the process still
// alive. Asserted as an executed sequence — reap, then a real inventory frame — rather
// than inferred from REQ-SHELL-10 having a revive branch, because if revive did not fire
// for hub-synthesized rows the threshold would not be conservative, it would be
// destructive: every partition longer than an hour would permanently mark live work
// failed. REQ-SHELL-10's diff is the ONLY reconciler; this task adds none.
@(test)
test_t14_synthesized_terminal_is_revived :: proc(t: ^testing.T) {
	fx: Fx14; fx14_make(&fx); defer fx14_free(&fx)
	fx14_seed(&fx, Seed14{session_id = "sh_1", bridge_id = "brg_gone"})

	// 1. The hub decides the bridge is gone and synthesizes a terminal.
	testing.expect_value(t, shell_session_reap_gone_bridge(&fx.svc, "brg_gone", NOW14), 1)
	reaped, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, reaped.status, SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL)

	// 2. The bridge returns and reports the process is still running.
	frame := strings.concatenate({
		"{\"type\":\"shell_inventory\",\"sessions\":[{\"session_id\":\"sh_1\",\"kind\":\"",
		domain.Shell_Session_Kind_Shell,
		"\",\"status\":\"", domain.Shell_Session_Status_Running,
		"\",\"shell_id\":\"\",\"started_at\":\"2026-09-28T09:00:00Z\",\"label\":\"\",\"cmd\":\"zsh\"",
		",\"cwd\":\"/tmp\",\"owner_user_id\":\"owner_a\",\"project_id\":\"\",\"chain_id\":\"\"",
		",\"agent_instance_id\":\"\",\"background\":false,\"pid\":4242,\"server_port\":0,\"run_seq\":0}",
		"],\"truncated\":false}",
	})
	defer delete(frame)
	res := shell_session_apply_inventory(&fx.svc, "brg_gone", frame)

	// 3. The wrong call is corrected by REQ-SHELL-10's diff, not by anything here.
	testing.expect_value(t, res.revived, 1)
	row, _ := fx14_row(&fx, "sh_1")
	testing.expect_value(t, row.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, row.finished_at, "")
}
