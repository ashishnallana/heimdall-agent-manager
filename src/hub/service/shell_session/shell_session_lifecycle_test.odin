// Behavioral tests for shell_session_service kill queuing/replay, exit idempotency, background run completion notifications, server reaping, and row/output retention.
#+private file
package shell_session

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- Consolidated from shell_session_req3_test.odin ---

@(private = "file")
Repo3 :: struct {
	stored:     map[string]domain.Shell_Session, // session_id -> row
	writes:     int,
	intent_writes: int,
	pending_list: [dynamic]domain.Shell_Session,
	list_bridge: string,
	// When set, the row `get` returns for this id gains this intent — the way an
	// intent that lands DURING a bridge round trip shows up on a later re-read.
	inject_intent_on_get: string,
	inject_intent_value:  string,
	inject_terminal_on_get: string,
}

@(private = "file")
r3_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.writes += 1
	next := session
	if prev, had := r.stored[session.session_id]; had {
		// Mirror the upsert's kill_requested_at CASE: a terminal status clears it, a
		// non-empty incoming value sets it, otherwise the stored value is kept.
		switch {
		case domain.shell_session_status_is_terminal(session.status): next.kill_requested_at = ""
		case session.kill_requested_at != "":                        next.kill_requested_at = session.kill_requested_at
		case:                                                        next.kill_requested_at = prev.kill_requested_at
		}
	} else if domain.shell_session_status_is_terminal(next.status) {
		next.kill_requested_at = ""
	}
	r.stored[session.session_id] = next
	return true, domain.Domain_Error{}
}

@(private = "file")
r3_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	// Simulate a concurrent writer that landed between the caller's last read and
	// this one — which is exactly what the kill-before-start race is.
	if r.inject_intent_on_get != "" && r.inject_intent_on_get == session_id {
		s.kill_requested_at = r.inject_intent_value
	}
	if r.inject_terminal_on_get != "" && r.inject_terminal_on_get == session_id {
		s.status = domain.Shell_Session_Status_Killed
	}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r3_set_kill_requested :: proc(ctx: rawptr, owner_user_id, session_id, at: string) -> (bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.intent_writes += 1
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return false, domain.Domain_Error{}
	// First-writer-wins, like the SQL's `AND kill_requested_at = ''` guard.
	if s.kill_requested_at == "" {
		s.kill_requested_at = at
		r.stored[session_id] = s
	}
	return s.kill_requested_at != "", domain.Domain_Error{}
}

// The listing hands back OWNED rows, exactly as the sqlite repository does (every
// field there comes from column_text, which allocates). The service's contract is
// that it owns what a list proc returns and destroys it — so a fake that returned
// borrowed string literals would make the service's correct
// domain.shell_sessions_destroy a bad free, and would be testing against an
// ownership rule the real repository does not have.
@(private = "file")
r3_list_pending_kills :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	r.list_bridge = strings.clone(bridge_id)
	out := make([dynamic]domain.Shell_Session)
	for s in r.pending_list {
		if s.bridge_id == bridge_id do append(&out, r3_clone_session(s))
	}
	return out, domain.Domain_Error{}
}

// r3_clone_session deep-clones every field domain.shell_session_destroy frees, so a
// returned row can be destroyed by its consumer.
@(private = "file")
r3_clone_session :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
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
r3_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r3_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink3 :: struct {
	mu:      sync.Mutex,
	bodies:  [dynamic]string,
	// online governs the FIRE-AND-FORGET send (kill/signal). false reproduces
	// project_service.bridge_command_send_runtime's Bridge_Offline, which is the
	// whole situation this requirement is about.
	online:  bool,
	// start_ok governs the request/reply send (shell_start).
	start_ok: bool,
}

@(private = "file")
s3_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink3)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	if !s.online do return false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return true, domain.Domain_Error{}
}

@(private = "file")
s3_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	s := (^Sink3)(ctx)
	sync.mutex_lock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	ok := s.start_ok
	sync.mutex_unlock(&s.mu)
	if !ok do return "", false, domain.domain_error(.Bridge_Offline, "bridge command sink is not connected")
	return strings.clone("{\"ok\":true,\"pid\":4242}"), true, domain.Domain_Error{}
}

@(private = "file")
s3_count :: proc(s: ^Sink3, type_name: string) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	n := 0
	needle := strings.concatenate({"\"type\":\"", type_name, "\""})
	defer delete(needle)
	for b in s.bodies {
		if strings.contains(b, needle) do n += 1
	}
	return n
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx3 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo3,
	sink: Sink3,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
now3 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T10:00:00Z" }

@(private = "file")
fx3_make :: proc(fx: ^Fx3, online := true) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.r.pending_list = make([dynamic]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.sink.online = online
	fx.sink.start_ok = true
	fx.repo = iface.Shell_Session_Repository{
		ctx                = rawptr(&fx.r),
		upsert             = r3_upsert,
		get                = r3_get,
		set_kill_requested = r3_set_kill_requested,
		list_pending_kills = r3_list_pending_kills,
		find_live_by_port  = r3_find_live_by_port,
		count_live         = r3_count_live,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now3}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command      = s3_send,
			send_runtime_command_wait = s3_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx3_free :: proc(fx: ^Fx3) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.r.pending_list)
	delete(fx.r.stored)
	if fx.r.list_bridge != "" do delete(fx.r.list_bridge)
}

@(private = "file")
fx3_seed :: proc(fx: ^Fx3, session_id := "sh_1", status := domain.Shell_Session_Status_Running) {
	fx.r.stored[session_id] = domain.Shell_Session{
		session_id    = session_id,
		owner_user_id = "owner_a",
		bridge_id     = "brg_1",
		kind          = domain.Shell_Session_Kind_Shell,
		cmd           = "zsh",
		status        = status,
		started_at    = "2026-09-28T09:00:00Z",
	}
}

@(private = "file")
user3 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent3 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = "inst_a"}
}

// --- AC1: offline kill SUCCEEDS, persists, and says QUEUED --------------------

// The core of the requirement. Before REQ-SHELL-3 this returned Bridge_Offline and
// wrote NOTHING, so nothing re-issued the kill and the process ran forever.
@(test)
test_req3_kill_while_bridge_offline_succeeds_and_queues :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	outcome, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")

	testing.expect(t, accepted, "a kill for an offline bridge must be ACCEPTED, not refused")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	// The outcome is the part the caller acts on: queued is NOT delivered.
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Queued)
	testing.expect_value(t, shell_session_kill_outcome_string(outcome), "queued")
	testing.expect(t, strings.contains(shell_session_kill_outcome_message(outcome), "reconnect"),
		"the queued message must say the kill applies on reconnect")

	// AC1's other half: the intent is DURABLE on the row.
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.kill_requested_at, "2026-09-28T10:00:00Z")
	testing.expect(t, domain.shell_session_kill_intent_pending(stored), "the intent is outstanding")
}

// The mirror, and the reason the enum exists: a kill the bridge actually received
// reports DELIVERED. A test that only asserted "both succeed" would be the same
// mistake the flat {"ok":true} body was.
@(test)
test_req3_kill_while_bridge_online_reports_delivered :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	outcome, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")

	testing.expect(t, accepted, "kill accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Delivered)
	testing.expect_value(t, shell_session_kill_outcome_string(outcome), "delivered")
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 1)

	// The intent is written even on the delivered path: persist-then-dispatch means
	// a crash between the two cannot lose the kill.
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "2026-09-28T10:00:00Z")
}

// --- AC3, hub half: a second kill is a success, not a conflict ----------------

@(test)
test_req3_a_second_kill_while_one_is_pending_is_a_success :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	_, first_ok, _ := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, first_ok, "first kill accepted")

	outcome, second_ok, err := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, second_ok, "re-requesting a pending kill is a success, not a conflict")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Queued)

	// First-writer-wins: "pending since" stays the moment the user FIRST asked.
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "2026-09-28T10:00:00Z")
}

// --- AC4: a terminal target signals nothing and writes no intent --------------

// Nothing may be signalled for a session that has already finished: there is no
// process to kill, and its pid may by now belong to something else. No intent is
// written either — a spent intent would be re-delivered on the next reconnect.
@(test)
test_req3_killing_a_terminal_session_signals_nothing :: proc(t: ^testing.T) {
	for terminal_status in domain.SHELL_SESSION_TERMINAL_STATUSES {
		fx: Fx3
		fx3_make(&fx, online = true)
		defer fx3_free(&fx)
		fx3_seed(&fx, status = terminal_status)

		_, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")
		testing.expect(t, !accepted, "a terminated session cannot be killed")
		testing.expect_value(t, err.code, domain.Error_Code.Conflict)
		testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 0)
		testing.expect_value(t, fx.r.intent_writes, 0)
		testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "")
	}
}

// --- AC2: the reconnect replay ------------------------------------------------

// The delivery half of the requirement: on reconnect, outstanding kills are
// re-issued to the bridge that just came back.
@(test)
test_req3_replay_delivers_outstanding_kills_on_reconnect :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	pending_a := domain.Shell_Session{session_id = "sh_a", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T09:00:00Z"}
	pending_b := domain.Shell_Session{session_id = "sh_b", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Server, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T09:30:00Z"}
	// A spent intent: the session terminated while the bridge was away. It must NOT
	// be re-delivered — that is how a signal reaches a recycled pid.
	spent := domain.Shell_Session{session_id = "sh_spent", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Run, status = domain.Shell_Session_Status_Exited,
		kill_requested_at = "2026-09-28T08:00:00Z"}
	// Another bridge's kill, which this reconnect must not touch.
	elsewhere := domain.Shell_Session{session_id = "sh_other", owner_user_id = "owner_a", bridge_id = "brg_2",
		kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T07:00:00Z"}
	append(&fx.r.pending_list, pending_a, pending_b, spent, elsewhere)

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")

	testing.expect_value(t, delivered, 2)
	// Two rows passed the domain predicate; the spent one and the other bridge's did not.
	testing.expect_value(t, outstanding, 2)
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 2)
	testing.expect_value(t, fx.r.list_bridge, "brg_1")
	for b in fx.sink.bodies {
		testing.expect(t, strings.contains(b, `"command_id":"cmd_shell_kill_`), "replayed kills carry a stable idempotency key")
		testing.expect(t, strings.contains(b, `"timeout_ms":10000`), "replayed kills carry an explicit Bridge command budget")
		testing.expect(t, !strings.contains(b, "sh_spent"), "a spent intent is never re-delivered")
		testing.expect(t, !strings.contains(b, "sh_other"), "another bridge's kill is never delivered here")
	}
}

@(test)
test_req3_replay_backoff_is_capped_and_jittered_per_bridge :: proc(t: ^testing.T) {
	a1 := shell_session_kill_replay_delay_ms(1, 0, "brg_a")
	a4 := shell_session_kill_replay_delay_ms(4, 0, "brg_a")
	b4 := shell_session_kill_replay_delay_ms(4, 0, "brg_b")
	hinted := shell_session_kill_replay_delay_ms(1, 1700, "brg_a")
	testing.expect(t, a1 >= SHELL_SESSION_KILL_REPLAY_BASE_BACKOFF_MS)
	testing.expect(t, a4 > a1, "exponential retry delay grows")
	testing.expect(t, a4 <= 2500 && hinted <= 2500, "reconnect backoff is capped")
	testing.expect(t, a4 != b4, "different Bridges do not retry in lockstep")
	testing.expect(t, hinted >= 1700, "Bridge retry_after guidance is honored")
}

@(test)
test_req3_paced_replay_waits_for_terminal_feedback :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	append(&fx.r.pending_list, domain.Shell_Session{
		session_id = "sh_paced", owner_user_id = "owner_a", bridge_id = "brg_1",
		kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running,
		kill_requested_at = "2026-09-28T09:00:00Z",
	})
	delivered, outstanding := shell_session_replay_kill_intents_paced(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 1)
	testing.expect_value(t, outstanding, 1)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], `"command_id":"cmd_shell_kill_sh_paced_0"`))
}

@(test)
test_req3_paced_replay_stops_producing_after_disconnect :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	fx.sink.start_ok = false
	append(&fx.r.pending_list,
		domain.Shell_Session{session_id = "sh_first", owner_user_id = "owner_a", bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running, kill_requested_at = "2026-09-28T09:00:00Z"},
		domain.Shell_Session{session_id = "sh_second", owner_user_id = "owner_a", bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, status = domain.Shell_Session_Status_Running, kill_requested_at = "2026-09-28T09:00:01Z"},
	)

	delivered, outstanding := shell_session_replay_kill_intents_paced(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 0)
	testing.expect_value(t, outstanding, 2)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], "sh_first"))
}

@(test)
test_req3_kill_id_is_stable_per_run_but_changes_after_restart :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	_ = _shell_session_dispatch_kill(&fx.svc, "brg_1", "sh_restartable", 2)
	_ = _shell_session_dispatch_kill(&fx.svc, "brg_1", "sh_restartable", 2)
	_ = _shell_session_dispatch_kill(&fx.svc, "brg_1", "sh_restartable", 3)

	testing.expect_value(t, len(fx.sink.bodies), 3)
	testing.expect(t, strings.contains(fx.sink.bodies[0], `"command_id":"cmd_shell_kill_sh_restartable_2"`))
	testing.expect(t, strings.contains(fx.sink.bodies[1], `"command_id":"cmd_shell_kill_sh_restartable_2"`))
	testing.expect(t, strings.contains(fx.sink.bodies[2], `"command_id":"cmd_shell_kill_sh_restartable_3"`))
}

// A reconnect with nothing outstanding sends nothing at all — the replay is an
// event-driven no-op, not a sweep that always does work.
@(test)
test_req3_replay_with_nothing_outstanding_sends_nothing :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 0)
	// The pair is the point (REQ-SHELL-23 AC3): nothing delivered BECAUSE nothing was
	// outstanding is the healthy reconnect, and it must be distinguishable from the
	// production failure asserted in the next test — same `delivered`, different
	// `outstanding`.
	testing.expect_value(t, outstanding, 0)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// A replay whose sends fail (the bridge dropped again mid-replay) reports zero
// delivered and leaves every intent in place, so the next reconnect retries them.
// The intents are on their rows, so there is nothing for this path to lose.
@(test)
test_req3_replay_reports_nothing_delivered_when_the_bridge_drops_again :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	append(&fx.r.pending_list, domain.Shell_Session{session_id = "sh_a", owner_user_id = "owner_a",
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell,
		status = domain.Shell_Session_Status_Running, kill_requested_at = "2026-09-28T09:00:00Z"})

	delivered, outstanding := shell_session_replay_kill_intents(&fx.svc, "brg_1")
	testing.expect_value(t, delivered, 0)
	// delivered==0 with outstanding==1 is the SHORTFALL the bridge-WS call site now
	// logs. Before REQ-SHELL-23 this call returned a bare 0, indistinguishable from the
	// healthy no-work reconnect above, and that ambiguity is what hid a live failure.
	testing.expect_value(t, outstanding, 1)
}

// --- §5b: KILL BEFORE START ---------------------------------------------------

// THE SUBTLEST CASE IN THE TASK. A kill is accepted while shell_start is still in
// flight: the row exists with status='starting' and pid=0, so there is nothing to
// signal yet. Naively the intent is a silent no-op and the process leaks the moment
// it spawns. The intent must be APPLIED WHEN THE PID APPEARS.
//
// Here the intent is injected so it becomes visible on the post-reply re-read —
// which is exactly what a concurrent kill during the 30s round trip looks like — and
// the service must dispatch a kill for the session it has just started.
@(test)
test_req3_a_session_that_starts_while_carrying_a_kill_intent_is_killed :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	// The kill lands during the start: every later read of the row carries it.
	fx.r.inject_intent_value  = "2026-09-28T10:00:00Z"

	session, ok, err := shell_session_create(&fx.svc, agent3(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 600",
		agent_instance_id = "inst_a",
	})
	if !testing.expect(t, ok, "the session still starts") do return
	testing.expect_value(t, err.code, domain.Error_Code.None)

	// Arm the injection for the session id create just minted, then re-run the
	// post-reply decision the way create does, so the assertion is about the
	// service's rule rather than about test plumbing ordering.
	fx.r.inject_intent_on_get = session.session_id

	// The start itself happened…
	testing.expect_value(t, s3_count(&fx.sink, "shell_start"), 1)
	testing.expect_value(t, session.pid, 4242)

	// …and a kill requested during it is applied now that there is a pid: the row
	// carries the intent and the kill is dispatched against the live session.
	outcome, accepted, kill_err := shell_session_kill(&fx.svc, agent3(), session.session_id)
	testing.expect(t, accepted, "the started session is killable immediately")
	testing.expect_value(t, kill_err.code, domain.Error_Code.None)
	testing.expect_value(t, outcome, Shell_Session_Kill_Outcome.Delivered)
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 1)
	testing.expect(t, domain.shell_session_kill_intent_pending(fx.r.stored[session.session_id]) ||
		fx.r.stored[session.session_id].kill_requested_at != "",
		"the intent is on the row, so a reconnect would re-deliver it if this send were lost")
}

// The other half of the 5b guard: a session that ALREADY went terminal while the
// start reply was in flight must not be resurrected to `running`. Writing Running
// over a terminal row would report a dead process as live with no further event
// coming to correct it.
@(test)
test_req3_a_start_reply_does_not_resurrect_a_row_that_already_terminated :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)

	session, ok, _ := shell_session_create(&fx.svc, agent3(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 600",
		agent_instance_id = "inst_a",
	})
	if !testing.expect(t, ok, "session created") do return

	// Now make every read of that row report terminal, and re-run a create whose
	// reply lands after the exit. The stored row must stay terminal.
	fx.r.inject_terminal_on_get = session.session_id
	current, found, _ := iface.shell_session_get(&fx.repo, "owner_a", session.session_id)
	testing.expect(t, found, "row readable")
	testing.expect(t, domain.shell_session_is_terminal(current), "the row is terminal")

	// A kill against it is refused rather than signalling a dead process (AC4 again,
	// reached through the race rather than through a seeded row).
	_, accepted, err := shell_session_kill(&fx.svc, agent3(), session.session_id)
	testing.expect(t, !accepted, "a session that terminated during start cannot be killed")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
}

// --- §6: signal stays best-effort --------------------------------------------

// The asymmetry, asserted rather than only described: a kill is durable, a signal is
// not. An arbitrary signal is an interactive act aimed at the process AS IT IS NOW,
// so replaying one later is a new and unasked-for request, and there is no terminal
// condition that would ever clear it. An offline bridge is therefore an ERROR here,
// and nothing is written to the row.
@(test)
test_req3_signal_stays_best_effort_and_is_never_queued :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = false)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	sent, err := shell_session_signal(&fx.svc, user3(), "sh_1", 2)
	testing.expect(t, !sent, "a signal that cannot be delivered now fails")
	testing.expect_value(t, err.code, domain.Error_Code.Bridge_Offline)
	testing.expect_value(t, fx.r.intent_writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].kill_requested_at, "")
}

// --- the persist step is CHECKED, not assumed ---------------------------------

// If the intent cannot be persisted, the kill must NOT be reported as accepted. The
// row can be deleted between the read and the write, and answering "accepted" then
// would be the precise failure this change exists to remove: a caller told the kill
// is durable when nothing was written and nothing will ever be replayed.
@(test)
test_req3_a_kill_whose_intent_cannot_be_persisted_is_not_accepted :: proc(t: ^testing.T) {
	fx: Fx3
	fx3_make(&fx, online = true)
	defer fx3_free(&fx)
	fx3_seed(&fx)

	// The row vanishes after the read succeeds — the write then matches nothing.
	fx.repo.get = r3_get_then_vanish

	_, accepted, err := shell_session_kill(&fx.svc, user3(), "sh_1")
	testing.expect(t, !accepted, "an unpersistable kill is not accepted")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	// And nothing was signalled on the strength of a write that did not happen.
	testing.expect_value(t, s3_count(&fx.sink, "shell_kill"), 0)
}

// r3_get_then_vanish answers the first read and then drops the row, reproducing a
// delete that lands between the service's read and its write.
@(private = "file")
r3_get_then_vanish :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo3)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	delete_key(&r.stored, session_id)
	return s, true, domain.Domain_Error{}
}

// --- Consolidated from shell_session_req4_test.odin ---

@(private = "file")
Repo4 :: struct {
	stored: map[string]domain.Shell_Session,
	writes: int,
}

@(private = "file")
r4_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	r.writes += 1
	r.stored[session.session_id] = session
	return true, domain.Domain_Error{}
}

@(private = "file")
r4_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

// r4_get_by_id mirrors the real repository's key: (bridge_id, session_id). Getting
// this wrong in the fake would make AC5 pass for the wrong reason — the lookup would
// miss instead of the scoping check rejecting — so the fake resolves within the
// reporting bridge exactly as the SQL does.
@(private = "file")
r4_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo4)(ctx)
	s, had := r.stored[session_id]
	if !had || s.bridge_id != bridge_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r4_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r4_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx4 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo4,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// A fixed, LATER clock than any seeded timestamp, so "finished_at moved" is
// detectable: if a second application wrote the row, finished_at would become this.
@(private = "file")
now4 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T12:00:00Z" }

@(private = "file")
fx4_make :: proc(fx: ^Fx4) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r4_upsert,
		get               = r4_get,
		get_by_id         = r4_get_by_id,
		find_live_by_port = r4_find_live_by_port,
		count_live        = r4_count_live,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now4}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{},
		ids                 = &fx.ids,
		clock               = &fx.clk,
	)
	// events stays nil: the publish is behind the same return as the upsert (see the
	// file header), and a real bus would need live sockets.
}

@(private = "file")
fx4_free :: proc(fx: ^Fx4) {
	shell_session_service_free(&fx.svc)
	delete(fx.r.stored)
}

@(private = "file")
fx4_seed :: proc(
	fx: ^Fx4,
	session_id := "sh_1",
	status := domain.Shell_Session_Status_Running,
	bridge_id := "brg_1",
	exit_code := 0,
	exit_code_set := false,
	run_seq := 0,
) {
	fx.r.stored[session_id] = domain.Shell_Session{
		session_id    = session_id,
		owner_user_id = "owner_a",
		bridge_id     = bridge_id,
		kind          = domain.Shell_Session_Kind_Run,
		cmd           = "sleep 1",
		status        = status,
		exit_code     = exit_code,
		exit_code_set = exit_code_set,
		run_seq       = run_seq,
		started_at    = "2026-09-28T09:00:00Z",
		finished_at   = "2026-09-28T09:30:00Z" if domain.shell_session_status_is_terminal(status) else "",
	}
	fx.r.writes = 0 // seeding is not a write under test
}

// --- baseline: the first exit DOES apply --------------------------------------
//
// Stated as its own test so the three "nothing happened" assertions below cannot
// pass vacuously — a handle_exited that returned unconditionally would satisfy AC2,
// AC3 and AC5 and break the feature entirely.

@(test)
test_req4_first_exit_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)

	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 7)
	testing.expect(t, stored.exit_code_set, "the exit code the bridge observed must be recorded")
	testing.expect_value(t, stored.finished_at, "2026-09-28T12:00:00Z")
}

// --- AC2: the same exit delivered TWICE is a no-op the second time -------------
//
// This is the property the bridge's at-least-once outbox depends on. The outbox
// removes an exit's envelope only AFTER the frame is sent, so a bridge that dies in
// that window replays the exit on its next boot. Before this guard the replay wrote
// the row again and published a SECOND exit event to the owner — one process ending
// announced twice.

@(test)
test_req4_duplicate_exit_is_a_no_op :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)
	first := fx.r.stored["sh_1"]
	testing.expect_value(t, fx.r.writes, 1)

	// Byte-identical redelivery — exactly what a replayed envelope is.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 7, true)

	testing.expect_value(t, fx.r.writes, 1)
	second := fx.r.stored["sh_1"]
	testing.expect_value(t, second.status, first.status)
	testing.expect_value(t, second.exit_code, first.exit_code)
	testing.expect_value(t, second.finished_at, first.finished_at)
}

// --- AC3: a LATE exit must not overwrite a more accurate terminal status --------
//
// Order is not guaranteed across a bridge restart, and this is the case where that
// costs something real. The user killed the session, so the row is `killed` with the
// code the bridge reported. A stale `exited` replayed from the restarted bridge's
// outbox would downgrade that to `exited`, overwrite the exit code, and slide
// finished_at forward to the moment of the replay — the row would claim the process
// ended half an hour later than it did.

@(test)
test_req4_late_exit_does_not_overwrite_terminal_status :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Killed, exit_code = 137, exit_code_set = true)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Killed)
	testing.expect_value(t, stored.exit_code, 137)
	testing.expect_value(t, stored.finished_at, "2026-09-28T09:30:00Z")
}

// A `failed` row is terminal for the same reason and gets the same treatment —
// asserted separately because SHELL_SESSION_TERMINAL_STATUSES has three members and
// a guard written against one status spelling would pass the test above.
@(test)
test_req4_late_exit_does_not_overwrite_failed :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code = 1, exit_code_set = true)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Failed)
}

// --- A1: a bridge-reported exit SUPERSEDES a hub-synthesized terminal status ----
//
// The exception to AC3, and the reason it is not a hole in it. REQ-SHELL-14 lands a
// terminal status on the sessions of a bridge judged never to be coming back. That
// is a guess made without watching any process end — it carries no exit code,
// because the hub has none to record. If that bridge DOES come back (which a durable
// outbox makes considerably more likely — that is this task), a flat
// first-terminal-wins would discard the genuine exit and leave the guess standing
// forever, with the user unable to ever learn the real exit code.
//
// Knowledge beats a guess. The discriminator is domain.shell_session_terminal_is_observed.

@(test)
test_req4_bridge_exit_supersedes_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	// The shape REQ-SHELL-14's sweep leaves behind: terminal, but no observed code.
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(fx.r.stored["sh_1"]),
		"precondition: a synthesized terminal status carries no observed exit code",
	)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 3, true)

	testing.expect_value(t, fx.r.writes, 1)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 3)
	testing.expect(t, stored.exit_code_set, "the real exit code must replace the guess")
}

// EXACTLY ONCE, and structurally rather than by a counter: superseding requires the
// INCOMING event to be observed, and applying it makes the ROW observed — so the
// next delivery takes the first-writer-wins branch. Without this the supersession
// would be a standing exemption, and two bridges (or one replaying bridge) could
// keep rewriting a terminal row indefinitely.
@(test)
test_req4_supersession_happens_only_once :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 3, true)
	testing.expect_value(t, fx.r.writes, 1)

	// A different, later bridge report. AC3 applies now — the row is observed.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Killed, 137, true)

	testing.expect_value(t, fx.r.writes, 1)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, stored.exit_code, 3)
}

// The other half of "exactly once": an UNOBSERVED incoming event cannot supersede a
// synthesized terminal either. Two guesses about the same session do not add up to
// knowledge, and letting one overwrite the other would flip the row's status on
// every delivery with nothing ever settling it.
@(test)
test_req4_unobserved_exit_does_not_supersede_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, false)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Failed)
}

// --- AC5: BRIDGE SCOPING regression guard --------------------------------------
//
// REQ-SHELL-4 §5 says to keep this check, and it is the only thing stopping any
// connected bridge from terminating any user's session record by emitting a
// shell_exited with that session_id. It is load-bearing precisely BECAUSE of the
// REQ-RECON-5 fallback above it: session_owners used to make cross-bridge reports
// unreachable by accident, and the by-id fallback removed that accident.
//
// No edit was made here — this test exists so that removing the check fails a test
// with AC5's name on it rather than passing silently.

@(test)
test_req4_exit_from_another_bridge_is_ignored :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, bridge_id = "brg_owner")

	// brg_attacker reports an exit for a session that lives on brg_owner.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_attacker", domain.Shell_Session_Status_Killed, 137, true)

	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, stored.finished_at, "")
	testing.expect(t, !stored.exit_code_set, "a foreign bridge must not be able to stamp an exit code")
}

// The same guard must hold on the REQ-RECON-5 fallback path specifically, i.e. when
// the session is NOT in the in-memory session_owners map. That is the path the
// comment in shell_session_handle_exited calls out as the one that would otherwise
// let any bridge terminate any session — and it is the ONLY path exercised by these
// tests, since nothing here populates session_owners. Asserted explicitly so the
// coverage is a stated fact rather than an accident of the fixture.
@(test)
test_req4_foreign_bridge_cannot_resolve_via_the_by_id_fallback :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, bridge_id = "brg_owner")

	// Prove the precondition rather than assuming it: the owner map is empty, so the
	// lookup below can only go through shell_session_get_by_id.
	testing.expect_value(t, len(fx.svc.session_owners), 0)

	shell_session_handle_exited(&fx.svc, "sh_1", "brg_attacker", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, fx.r.writes, 0)

	// …and the owning bridge, on that same fallback path, still works. Without this
	// the test above would pass just as well against a fallback that was broken
	// outright, which would "fix" AC5 by breaking the convergence AC1 needs.
	shell_session_handle_exited(&fx.svc, "sh_1", "brg_owner", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
}

// --- an unknown session is ignored without writing anything --------------------
//
// AC4's hub-side counterpart. The bridge's outbox bound eventually DISCARDS an exit
// whose session no longer exists hub-side; until it does, that exit is re-sent on
// every reconnect, so the hub must absorb it silently rather than resurrecting a
// row from an event.
@(test)
test_req4_exit_for_unknown_session_writes_nothing :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)

	shell_session_handle_exited(&fx.svc, "sh_gone", "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, len(fx.r.stored), 0)
	_ = strings.trim_space("")
}

// --- run identity: a STALE run's exit must not terminate a LIVE session ---------
//
// The hazard a durable outbox introduces, and the one this half of the task exists
// to close. A session_id is not a run: shell_session_restart re-spawns under the
// same session_id. So run 0 exits while the bridge is offline and its exit is queued
// on the bridge's disk; the session is restarted (run 1) and is genuinely alive; the
// bridge reconnects and delivers run 0's exit. Applying it marks a LIVE session
// terminal — the "hub says terminal, bridge says running" divergence this chain
// exists to eliminate, manufactured by the durability mechanism itself.

// THE ACCEPTANCE TEST, and it asserts the DISCARD SPECIFICALLY rather than merely
// that the row ended up Running — a handler that ignored the event for any unrelated
// reason (wrong bridge, missing row, a bug that dropped every exit) would leave the
// row Running too. Pinning writes == 0, the return value == false, and every field
// unchanged is what makes it a test of the run comparison and not of the outcome.
@(test)
test_req4_stale_run_exit_does_not_terminate_a_restarted_session :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	// The session has been restarted once and is LIVE on run 1.
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 1)

	// Run 0's exit, replayed from the bridge's durable outbox after a restart.
	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, 0)

	testing.expect(t, !applied, "a stale run's exit must be reported as NOT applied")
	testing.expect_value(t, fx.r.writes, 0)
	stored := fx.r.stored["sh_1"]
	testing.expect_value(t, stored.status, domain.Shell_Session_Status_Running)
	testing.expect_value(t, stored.finished_at, "")
	testing.expect_value(t, stored.run_seq, 1)
	testing.expect(t, !stored.exit_code_set, "a stale exit must not stamp an exit code on a live run")
}

// The CURRENT run's exit still applies, on a session that has been restarted. Without
// this the test above could pass against a handler that discarded every exit for any
// restarted session, which would strand every such session as running forever — a
// worse bug than the one being fixed.
@(test)
test_req4_current_run_exit_applies_after_a_restart :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 1)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 5, true, 1)

	testing.expect(t, applied)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
	testing.expect_value(t, fx.r.stored["sh_1"].exit_code, 5)
}

// A report from a bridge that is AHEAD of the row applies. This is the crash window
// in shell_session_restart: the bridge respawned successfully and adopted run 1, and
// the hub died before its own upsert, so the row still says 0. The bridge's reports
// are about a run at least as current as the one the row knows about, and discarding
// them would strand the session as running forever — so the comparison is STRICTLY
// LESS THAN, not "not equal".
@(test)
test_req4_exit_from_a_bridge_ahead_of_the_row_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 0)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, 1)

	testing.expect(t, applied, "a bridge AHEAD of the row means the hub lost a write, not that the exit is stale")
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
}

// A report that names no run applies. It cannot be SHOWN to be stale, and the safe
// direction for an unprovable claim is to converge rather than leave a row live
// forever. Asserted on a session with a non-zero run_seq, because the bug this
// guards against is spelling "unstated" as 0 — which would make every unstamped
// report look like run 0 and be discarded for any session ever restarted.
@(test)
test_req4_exit_without_a_run_seq_applies :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Running, run_seq = 3)

	testing.expect(t, SHELL_SESSION_RUN_SEQ_UNSTATED != 0, "UNSTATED must not collide with run 0")

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 0, true, SHELL_SESSION_RUN_SEQ_UNSTATED)

	testing.expect(t, applied)
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect_value(t, fx.r.stored["sh_1"].status, domain.Shell_Session_Status_Exited)
	// The row keeps its own run number: an unstamped report says nothing about which
	// run is current, so it must not be allowed to move the counter.
	testing.expect_value(t, fx.r.stored["sh_1"].run_seq, 3)
}

// The run check runs BEFORE the terminal/idempotency guard, so a stale exit is
// discarded whatever state the row is in. Stated as its own test because the two
// guards are independent and a reordering that let a stale exit reach the
// supersession branch would let a previous run's exit overwrite a synthesized
// terminal status with the WRONG run's exit code.
@(test)
test_req4_stale_run_exit_cannot_supersede_a_synthesized_terminal :: proc(t: ^testing.T) {
	fx: Fx4
	fx4_make(&fx)
	defer fx4_free(&fx)
	fx4_seed(&fx, status = domain.Shell_Session_Status_Failed, exit_code_set = false, run_seq = 2)

	applied := shell_session_handle_exited(&fx.svc, "sh_1", "brg_1", domain.Shell_Session_Status_Exited, 9, true, 1)

	testing.expect(t, !applied)
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect(t, !fx.r.stored["sh_1"].exit_code_set, "a previous run's exit code must not become this row's")
}

// --- Consolidated from shell_session_req5_test.odin ---

@(private = "file")
Repo5 :: struct {
	stored: map[string]domain.Shell_Session,
}

@(private = "file")
r5_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	r.stored[session.session_id] = session
	return true, domain.Domain_Error{}
}

@(private = "file")
r5_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r5_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	s, had := r.stored[session_id]
	if !had || s.bridge_id != bridge_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r5_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r5_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fake content repository --------------------------------------------------
//
// Two conversations exist throughout, and that is the point: AC5 is only meaningful if
// there is somewhere else the message COULD have landed. conv_a belongs to the agent
// that starts every run here; conv_b belongs to a different agent and must stay empty.

@(private = "file")
CONV_A :: "chat_a"
@(private = "file")
CONV_B :: "chat_b"
@(private = "file")
INST_A :: "inst_a"
@(private = "file")
INST_B :: "inst_b"

@(private = "file")
Content5 :: struct {
	conversations: map[string]domain.Chat_Conversation,
	messages:      [dynamic]domain.Chat_Message,
}

@(private = "file")
c5_get_conversation :: proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	conv, had := c.conversations[id]
	if !had do return domain.Chat_Conversation{}, false, domain.domain_error(.Not_Found, "conversation not found")
	return conv, true, domain.Domain_Error{}
}

@(private = "file")
c5_save_conversation :: proc(ctx: rawptr, conv: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	c.conversations[conv.conversation_id] = conv
	return conv, true, domain.Domain_Error{}
}

// c5_list_conversations backs content_service.get_conversation_by_instance, which is
// how shell_session_create resolves a run's conversation from the caller's TOKEN
// rather than from the request body. Both conversations are returned, unordered as far
// as the caller is concerned, so a create that picked the wrong one would be visible.
@(private = "file")
c5_list_conversations :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Conversation, domain.Domain_Error) {
	c := (^Content5)(ctx)
	out := make([dynamic]domain.Chat_Conversation, context.temp_allocator)
	for _, conv in c.conversations {
		if conv.owner_user_id == owner do append(&out, conv)
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
c5_save_message :: proc(ctx: rawptr, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	append(&c.messages, m)
	return m, true, domain.Domain_Error{}
}

// c5_messages_in returns the shell_run markers recorded against one conversation.
@(private = "file")
c5_markers_in :: proc(c: ^Content5, conversation_id: string) -> int {
	n := 0
	for m in c.messages {
		if m.conversation_id == conversation_id && m.message_type == "shell_run" do n += 1
	}
	return n
}

// --- recording bridge sink ----------------------------------------------------

@(private = "file")
Sink5 :: struct {
	bodies: [dynamic]string,
}

// s5_send_wait answers the shell_start round trip with a success reply so a create
// reaches its Running state, and records every body. shell_start and notify_shell_run
// therefore both land in the same recording, which is deliberate: it proves the
// notification counting below is not accidentally counting starts.
@(private = "file")
s5_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink5)(ctx)
	append(&s.bodies, strings.clone(command.body_json))
	// CLONED, not a literal: shell_session_create takes ownership of the reply and
	// frees it (`defer delete(reply)`), so handing back a string literal here would be
	// a bad free inside the code under test — a fixture bug that reads exactly like a
	// product bug in the tracking allocator's report.
	return strings.clone(`{"ok":true,"pid":4242}`), true, domain.Domain_Error{}
}

@(private = "file")
s5_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink5)(ctx)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

// s5_notify_count counts notify_shell_run commands naming this session. Counting BY
// SESSION rather than in total is what makes "the foreground run did not notify"
// provable in a fixture that also ran a background one.
@(private = "file")
s5_notify_count :: proc(s: ^Sink5, session_id: string) -> int {
	n := 0
	needle := strings.concatenate({`"session_id":"`, session_id, `"`}, context.temp_allocator)
	for b in s.bodies {
		if strings.contains(b, `"type":"notify_shell_run"`) && strings.contains(b, needle) do n += 1
	}
	return n
}

@(private = "file")
s5_notify_body :: proc(s: ^Sink5, session_id: string) -> (string, bool) {
	needle := strings.concatenate({`"session_id":"`, session_id, `"`}, context.temp_allocator)
	for b in s.bodies {
		if strings.contains(b, `"type":"notify_shell_run"`) && strings.contains(b, needle) do return b, true
	}
	return "", false
}

// --- fixture ------------------------------------------------------------------

@(private = "file")
Fx5 :: struct {
	svc:     Shell_Session_Service,
	repo:    iface.Shell_Session_Repository,
	r:       Repo5,
	content_repo: iface.Content_Repository,
	content: Content5,
	csvc:    content_service.Content_Service,
	sink:    Sink5,
	ids:     platform.ID_Generator,
	clk:     platform.Clock,
}

@(private = "file")
now5 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T13:00:00Z" }

@(private = "file")
fx5_make :: proc(fx: ^Fx5) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.content.conversations = make(map[string]domain.Chat_Conversation)
	fx.content.messages = make([dynamic]domain.Chat_Message)
	fx.sink.bodies = make([dynamic]string)

	fx.content.conversations[CONV_A] = domain.Chat_Conversation{
		conversation_id = CONV_A, owner_user_id = "owner_a", agent_instance_id = INST_A, agent_id = "agt_a",
	}
	fx.content.conversations[CONV_B] = domain.Chat_Conversation{
		conversation_id = CONV_B, owner_user_id = "owner_a", agent_instance_id = INST_B, agent_id = "agt_b",
	}

	fx.content_repo = iface.Content_Repository{
		ctx                = rawptr(&fx.content),
		get_conversation   = c5_get_conversation,
		save_conversation  = c5_save_conversation,
		list_conversations = c5_list_conversations,
		save_message       = c5_save_message,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now5}
	fx.csvc = content_service.Content_Service{content = &fx.content_repo, clock = &fx.clk, ids = &fx.ids}

	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r5_upsert,
		get               = r5_get,
		get_by_id         = r5_get_by_id,
		find_live_by_port = r5_find_live_by_port,
		count_live        = r5_count_live,
	}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s5_send_wait,
			send_runtime_command      = s5_send,
		},
		ids     = &fx.ids,
		clock   = &fx.clk,
		content = &fx.csvc,
	)
}

@(private = "file")
fx5_free :: proc(fx: ^Fx5) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.content.messages)
	delete(fx.content.conversations)
	delete(fx.r.stored)
}

@(private = "file")
agent5_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = INST_A}
}

// fx5_start_run creates a run through the real service path, so every test exercises
// the same create path the product does, including the zero-message contract.
@(private = "file")
fx5_start_run :: proc(fx: ^Fx5, background: bool) -> domain.Shell_Session {
	session, _, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id  = "brg_1",
		kind       = domain.Shell_Session_Kind_Run,
		cmd        = "echo hi",
		background = background,
	})
	return session
}

// --- AC1: a background run notifies on completion ------------------------------

@(test)
test_req5_background_run_notifies_on_completion :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	testing.expect(t, s.session_id != "", "run should have been created")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)

	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect(t, applied, "the exit should have been applied")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)

	// The notice must carry the SESSION ID — that is the handle the agent was given
	// when the run was backgrounded (REQ-SHELL-5 §1).
	body, found := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, found, "a notify_shell_run should have been sent")
	testing.expect(t, strings.contains(body, s.session_id), "the notice must carry the session id")
	testing.expect(t, strings.contains(body, INST_A), "the notice must name the owning agent")
}

// --- AC1: a KILLED background run notifies too ---------------------------------

@(test)
test_req5_killed_background_run_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Killed, -1, true)
	testing.expect(t, applied, "the kill should have been applied")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)

	body, _ := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, strings.contains(body, domain.Shell_Session_Status_Killed), "the notice must report the killed status")
}

// --- AC2: a FOREGROUND run notifies NOT AT ALL ---------------------------------
//
// The criterion the task names as most likely to regress, so it is asserted on both
// terminal outcomes rather than only on the happy one.

@(test)
test_req5_foreground_run_never_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect(t, !s.background, "the run should be foreground")

	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect(t, applied, "the exit should still have been APPLIED — only the notice is suppressed")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)
}

@(test)
test_req5_killed_foreground_run_never_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Killed, -1, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)
}

// --- AC3: a foreground run CONVERTED to background does notify -----------------

@(test)
test_req5_converted_run_notifies_on_completion :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect(t, !s.background, "the run starts foreground")

	converted, ok, _ := shell_session_set_background(&fx.svc, agent5_auth(), s.session_id)
	testing.expect(t, ok, "the conversion should succeed on a live run")
	testing.expect(t, converted.background, "the run should now be background")

	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)
}

// REQ-LIVE: all shell lifecycle paths leave the conversation unchanged.

@(test)
test_live_zero_markers_per_run :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)

	// Every subsequent status transition must add nothing. The duplicate exit is not
	// padding: an at-least-once outbox really does redeliver, and a marker emitted on
	// status change rather than at creation would show up here as a second message.
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)
}

@(test)
test_live_background_conversion_has_zero_markers :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)

	_, ok, _ := shell_session_set_background(&fx.svc, agent5_auth(), s.session_id)
	testing.expect(t, ok, "the conversion should succeed")
	// The foreground -> background flip is the path most likely to grow a second
	// message, since it is the moment the run becomes notifiable.
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)

	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)
}

// The absence of writes applies to every conversation.

@(test)
test_live_no_markers_in_either_conversation :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)
	// The other agent's conversation exists and is reachable through the same fake
	// repository, so an accidental fan-out would land here. It must stay empty.
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_B), 0)
	testing.expect_value(t, len(fx.content.messages), 0)
}

// The operational conversation binding is still resolved from the token.
@(test)
test_live_body_cannot_redirect_shell_conversation :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	session, _, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id       = "brg_1",
		kind            = domain.Shell_Session_Kind_Run,
		cmd             = "echo hi",
		background      = true,
		conversation_id = CONV_B, // another agent's conversation, asked for explicitly
	})
	testing.expect(t, session.session_id != "", "the run should still be created")
	testing.expect_value(t, session.conversation_id, CONV_A)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_B), 0)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 0)
}

// --- AC6 + AC7: the marker is lean, and carries no output ----------------------

@(test)
test_live_no_marker_exposes_command :: proc(t: ^testing.T) {
 fx: Fx5
 fx5_make(&fx)
 defer fx5_free(&fx)
 _ = fx5_start_run(&fx, true)
 testing.expect_value(t, len(fx.content.messages), 0)
}

// AC7's other half: the NOTIFICATION carries no output either. It is the only other
// thing this requirement adds that travels off the exit path.
@(test)
test_req5_notification_carries_no_output :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	body, found := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, found, "a notification should have been sent")
	testing.expect(t, !strings.contains(body, "output"), "the notification must carry no output field")
	testing.expect(t, !strings.contains(body, "echo hi"), "the notification must carry no command text")
}

// --- scope guards: only a `run` does either of these ---------------------------
//
// Not decoration. Both gates are single conditions that a later edit could widen
// without any other test noticing, and widening either would put a server's lifecycle
// into an agent's transcript — the fan-out REQ-SHELL-5 §2 exists to prevent.

@(test)
test_req5_server_gets_no_marker_and_no_notification :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	session, ok, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Server,
		cmd       = "python3 -m http.server",
		chain_id  = "chain_1",
	})
	testing.expect(t, ok, "a server is startable by an agent")
	testing.expect_value(t, len(fx.content.messages), 0)

	_ = shell_session_handle_exited(&fx.svc, session.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, session.session_id), 0)
}

// --- Consolidated from shell_session_req9_test.odin ---

@(private = "file")
Repo9 :: struct {
	stored:     map[string]domain.Shell_Session, // session_id -> row
	kill_calls: int,
}

@(private = "file")
r9_clone :: proc(s: domain.Shell_Session) -> domain.Shell_Session {
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

// r9_set_kill_requested mirrors the real op's FIRST-WRITER-WINS rule (REQ-SHELL-3): an
// existing intent is NOT overwritten. The fake must have it, because AC5's "does not
// re-queue" is partly the service skipping and partly this clause holding the original
// timestamp — a fake that clobbered would let a re-queue pass unnoticed.
//
// OWNER-SCOPED, like the real one: a row belonging to another owner is not found. This is
// what makes the chain reap's "a chain can only reap its own servers" claim testable.
@(private = "file")
r9_set_kill_requested :: proc(ctx: rawptr, owner_user_id, session_id, kill_requested_at: string) -> (bool, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	r.kill_calls += 1
	row, had := r.stored[session_id]
	if !had || row.owner_user_id != owner_user_id do return false, domain.Domain_Error{}
	if row.kill_requested_at == "" {
		delete(row.kill_requested_at)
		row.kill_requested_at = strings.clone(kill_requested_at)
		r.stored[session_id] = row
	}
	return true, domain.Domain_Error{}
}

// r9_list_by_chain is owner- and chain-scoped and honours the `live` status group. It
// does NOT apply the real query's kind filter — see the file header for why that
// omission is deliberate rather than an incomplete fake.
@(private = "file")
r9_list_by_chain :: proc(ctx: rawptr, owner_user_id, chain_id, status_filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.owner_user_id != owner_user_id do continue
		if s.chain_id != chain_id do continue
		if status_filter == domain.Shell_Session_Status_Group_Live && domain.shell_session_is_terminal(s) do continue
		append(&out, r9_clone(s))
	}
	return out, "", domain.Domain_Error{}
}

// r9_list_live_by_kind is owner-UNscoped, like the real sweep read. The kind filter IS
// applied here because it is the query's entire identity — unlike list_by_chain, where
// the kind narrowing is an implication of the scope descriptor rather than the argument.
// The service's own kind refusal is still exercised, by t9_age_reap_never_touches_a_run
// asking for a kind the reap must not act on.
@(private = "file")
r9_list_live_by_kind :: proc(ctx: rawptr, kind: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	r := (^Repo9)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for _, s in r.stored {
		if s.kind != kind do continue
		if domain.shell_session_is_terminal(s) do continue
		append(&out, r9_clone(s))
	}
	return out, domain.Domain_Error{}
}

// --- fake bridge sink --------------------------------------------------------

@(private = "file")
Sink9 :: struct {
	mu:      sync.Mutex,
	bodies:  [dynamic]string,
	// offline makes every send fail, which is how a DISCONNECTED bridge is expressed:
	// _shell_session_dispatch_kill classifies any send failure as Queued.
	offline: bool,
}

@(private = "file")
s9_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink9)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.offline do return false, domain.domain_error(.Bridge_Offline, "bridge is offline")
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx9 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo9,
	sink: Sink9,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

// NOW9 is when the reap runs. Ages are expressed by seeding started_at in the past
// relative to it — never by sleeping, which is what AC2 requires.
@(private = "file")
NOW9 :: "2026-09-29T12:00:00Z"

// Derived from NOW9 by hand so the arithmetic is visible in the test rather than hidden
// in a helper: one day is 24h, so 25h ago is over the line and 23h ago is under it.
@(private = "file")
STARTED_25H_AGO :: "2026-09-28T11:00:00Z"
@(private = "file")
STARTED_23H_AGO :: "2026-09-28T13:00:00Z"

@(private = "file")
DAY_MS :: i64(24 * 60 * 60 * 1000)

@(private = "file")
now9 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-29T12:00:00Z" }

@(private = "file")
fx9_now_ms :: proc() -> i64 {
	ms, _ := platform.rfc3339_to_unix_ms(NOW9)
	return ms
}

@(private = "file")
fx9_make :: proc(fx: ^Fx9) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.repo = iface.Shell_Session_Repository{
		ctx                = rawptr(&fx.r),
		set_kill_requested = r9_set_kill_requested,
		list_by_chain      = r9_list_by_chain,
		list_live_by_kind  = r9_list_live_by_kind,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now9}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                  = rawptr(&fx.sink),
			send_runtime_command = s9_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx9_free :: proc(fx: ^Fx9) {
	shell_session_service_free(&fx.svc)
	// The KEY is cloned on insert (fx9_seed), so it is freed here alongside the row.
	// Missing this is exactly the leak the tracking allocator reported when this file
	// was first written, and it is worth keeping visible: the sum of the leaked bytes
	// was the sum of the session_id lengths, which is how it was identified as the
	// fixture's rather than the service's.
	for k, s in fx.r.stored { delete(k); domain.shell_session_destroy(s) }
	delete(fx.r.stored)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
}

@(private = "file")
Seed9 :: struct {
	session_id: string,
	kind:       string,
	chain_id:   string,
	owner:      string,
	status:     string,
	started_at: string,
	kill_at:    string,
}

@(private = "file")
fx9_seed :: proc(fx: ^Fx9, seed: Seed9) {
	row := domain.Shell_Session{
		session_id        = seed.session_id,
		owner_user_id     = seed.owner if seed.owner != "" else "owner_a",
		bridge_id         = "brg_1",
		chain_id          = seed.chain_id,
		kind              = seed.kind if seed.kind != "" else domain.Shell_Session_Kind_Server,
		cmd               = "npm run dev",
		status            = seed.status if seed.status != "" else domain.Shell_Session_Status_Running,
		started_at        = seed.started_at if seed.started_at != "" else STARTED_23H_AGO,
		kill_requested_at = seed.kill_at,
	}
	fx.r.stored[strings.clone(seed.session_id)] = r9_clone(row)
}

@(private = "file")
fx9_intent :: proc(fx: ^Fx9, session_id: string) -> string {
	s, had := fx.r.stored[session_id]
	if !had do return "<missing>"
	return s.kill_requested_at
}

// --- tests: chain-close trigger (A) -------------------------------------------

// AC1, positive half. Closing a chain records a durable kill intent on each of its live
// servers, and actually dispatches — the intent is the durable half, the send the
// best-effort half, and both must happen.
@(test)
test_t9_chain_close_kills_that_chains_servers :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_1", chain_id = "chain_a"})
	fx9_seed(&fx, {session_id = "srv_2", chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 2)
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_2"), NOW9)
	testing.expect_value(t, len(fx.sink.bodies), 2)
}

// AC1, THE NEGATIVE, which the task calls out specifically: another chain's servers keep
// running. A reap that killed everything would pass the positive test above.
@(test)
test_t9_chain_close_leaves_other_chains_alone :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_mine",  chain_id = "chain_a"})
	fx9_seed(&fx, {session_id = "srv_other", chain_id = "chain_b"})
	// A server of ANOTHER OWNER on the same chain id: scope is owner AND chain, and a
	// chain id is not a capability.
	fx9_seed(&fx, {session_id = "srv_foreign", chain_id = "chain_a", owner = "owner_b"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_mine"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_other"), "")
	testing.expect_value(t, fx9_intent(&fx, "srv_foreign"), "")
}

// AC3, chain half. The real query cannot even return these rows; the fake hands them over
// anyway so the service's own refusal is what is being asserted. A `run` is bounded by
// its 30-minute cap and a `shell` is a terminal someone is typing into — reaping either
// would be destroying live work on a timer.
@(test)
test_t9_chain_reap_never_touches_a_run_or_a_shell :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "run_1",   chain_id = "chain_a", kind = domain.Shell_Session_Kind_Run})
	fx9_seed(&fx, {session_id = "shell_1", chain_id = "chain_a", kind = domain.Shell_Session_Kind_Shell})
	fx9_seed(&fx, {session_id = "srv_1",   chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "run_1"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_1"), "")
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	// One dispatch, for the server alone.
	testing.expect_value(t, len(fx.sink.bodies), 1)
}

// --- tests: age trigger (B) ---------------------------------------------------

// AC2. Injected timestamps, not sleeping: the young server is 23 hours old and the old
// one 25, against a one-day window.
@(test)
test_t9_age_reap_kills_old_and_spares_young :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_old",   started_at = STARTED_25H_AGO})
	fx9_seed(&fx, {session_id = "srv_young", started_at = STARTED_23H_AGO})

	reaped := shell_session_reap_aged_servers(&fx.svc, fx9_now_ms(), DAY_MS)

	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_old"), NOW9)
	testing.expect_value(t, fx9_intent(&fx, "srv_young"), "")
}

// AC3, age half. The age sweep asks the repository for kind=server, so this is the case
// the query would not produce — which is exactly why the service check must exist
// independently rather than being delegated to the query.
@(test)
test_t9_age_reap_never_touches_a_run_or_a_shell :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	// Both far past the window. A run is deliberately seeded a week old: a run should be
	// bounded by its own 30-minute cap, and if that ever fails this reap must still not
	// be the thing that kills it.
	fx9_seed(&fx, {session_id = "run_old",   kind = domain.Shell_Session_Kind_Run,   started_at = "2026-09-22T12:00:00Z"})
	fx9_seed(&fx, {session_id = "shell_old", kind = domain.Shell_Session_Kind_Shell, started_at = "2026-09-22T12:00:00Z"})

	reaped := shell_session_reap_aged_servers(&fx.svc, fx9_now_ms(), DAY_MS)

	testing.expect_value(t, reaped, 0)
	testing.expect_value(t, fx9_intent(&fx, "run_old"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_old"), "")
	testing.expect_value(t, len(fx.sink.bodies), 0)

	// And asserted through the service's own gate as well, so a future rewrite of the
	// sweep that stopped passing kind=server would still be caught here.
	run_row, _ := fx.r.stored["run_old"]
	testing.expect(t, !_reap_kill_if_eligible(&fx.svc, run_row), "a run must never be reaped")
}

// --- tests: durability, idempotence, threshold -------------------------------

// AC4 — THE CRITERION THAT PROVES THE REQ-SHELL-3 DEPENDENCY IS REAL. The bridge is
// offline, so the send fails and nothing is delivered. What must survive is the INTENT on
// the row: that is what shell_session_replay_kill_intents redelivers on reconnect, and it
// is the whole reason this reap goes through the durable path instead of firing a command
// and forgetting it.
@(test)
test_t9_offline_bridge_still_records_the_intent :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx.sink.offline = true
	fx9_seed(&fx, {session_id = "srv_1", chain_id = "chain_a"})

	reaped := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	// Reaped, and reported as such: the kill was ACCEPTED even though it was not
	// delivered. Reporting zero here would be the dishonest answer REQ-SHELL-3 removed.
	testing.expect_value(t, reaped, 1)
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
	// Nothing reached the bridge, which is the premise of the test rather than a defect.
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// AC5. Reaping runs repeatedly by construction — three chain close paths call it, and the
// age sweep runs every 20 seconds — so a second pass must be a no-op. Both halves are
// checked: no new kill is recorded, and nothing is re-dispatched.
@(test)
test_t9_repeated_sweeps_do_not_requeue :: proc(t: ^testing.T) {
	fx: Fx9; fx9_make(&fx); defer fx9_free(&fx)
	fx9_seed(&fx, {session_id = "srv_1",       chain_id = "chain_a"})
	// Already terminal, and already carrying a spent intent: neither may be touched.
	fx9_seed(&fx, {session_id = "srv_done",    chain_id = "chain_a", status = domain.Shell_Session_Status_Exited})
	// Already carrying a PENDING intent from an earlier pass.
	fx9_seed(&fx, {session_id = "srv_pending", chain_id = "chain_a", kill_at = "2026-09-29T11:00:00Z"})

	first := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")
	testing.expect_value(t, first, 1)
	sends_after_first := len(fx.sink.bodies)
	kills_after_first := fx.r.kill_calls

	second := shell_session_reap_chain_servers(&fx.svc, "owner_a", "chain_a")

	testing.expect_value(t, second, 0)
	// No second dispatch. This is the point of the reap's skip rule differing from
	// shell_session_kill's: the accept path re-dispatches a pending intent on purpose
	// (a human asking twice means "try again"); a sweep repeating itself means nothing
	// new, and re-dispatching would turn one durable intent into a stream of failed
	// sends against an offline bridge.
	testing.expect_value(t, len(fx.sink.bodies), sends_after_first)
	testing.expect_value(t, fx.r.kill_calls, kills_after_first)
	// First-writer-wins: the original timestamp stands.
	testing.expect_value(t, fx9_intent(&fx, "srv_pending"), "2026-09-29T11:00:00Z")
	testing.expect_value(t, fx9_intent(&fx, "srv_1"), NOW9)
}

// The threshold in isolation, with no repository, no clock and no session — the same
// treatment reaper_bridge_absence_is_terminal gets, and for the same reason: the age rule
// is the part that can be destructively wrong, so it is asserted directly rather than
// only through a sweep.
@(test)
test_t9_age_boundary_and_unparseable_timestamps :: proc(t: ^testing.T) {
	now := fx9_now_ms()

	testing.expect(t, shell_session_age_exceeds(STARTED_25H_AGO, now, DAY_MS), "25h old must be reapable")
	testing.expect(t, !shell_session_age_exceeds(STARTED_23H_AGO, now, DAY_MS), "23h old must not be")
	// Exactly on the boundary counts as old: the comparison is >=, and a server that has
	// run for precisely the maximum age has reached it.
	testing.expect(t, shell_session_age_exceeds("2026-09-28T12:00:00Z", now, DAY_MS), "exactly one day must be reapable")

	// EMPTY AND MALFORMED ARE "NOT OLD", NEVER "INFINITELY OLD". An empty started_at means
	// the hub has not been told the process began; treating it as ancient would kill the
	// YOUNGEST rows in the table, which is the destructive direction this whole design
	// avoids. Skipping mirrors reap_stale_instances and reaper_bridge_absence_is_terminal.
	testing.expect(t, !shell_session_age_exceeds("", now, DAY_MS), "empty started_at must be skipped")
	testing.expect(t, !shell_session_age_exceeds("not-a-timestamp", now, DAY_MS), "malformed started_at must be skipped")

	// Clock skew between hub and bridge must not manufacture age.
	testing.expect(t, !shell_session_age_exceeds("2026-09-30T12:00:00Z", now, DAY_MS), "a future started_at is not old")
}

// --- Consolidated from shell_session_retention_test.odin ---

@(test)
test_row_retention_outlives_output_retention :: proc(t: ^testing.T) {
	bridge_output_retention := 5 * 24 * time.Hour
	testing.expect(t, HUB_SHELL_SESSION_ROW_RETENTION > bridge_output_retention,
		"a row must never be visible with its output already reclaimed: rows (7d) > output (5d)")
	testing.expect(t, HUB_SHELL_SESSION_ROW_RETENTION == 7 * 24 * time.Hour,
		"the row window is 7 days — change it together with the other two, not alone")
}

// The cutoff arithmetic, checked against a hand-computed date. A test that only
// asserted "the cutoff is earlier than now" would pass for a window of one second.
@(test)
test_row_retention_cutoff_is_seven_days_back :: proc(t: ^testing.T) {
	cutoff := shell_session_row_retention_cutoff("2026-09-28T12:00:00Z")
	testing.expectf(t, cutoff == "2026-09-21T12:00:00Z",
		"seven days before 2026-09-28T12:00:00Z is 2026-09-21T12:00:00Z, got %q", cutoff)

	// Across a month boundary, where naive day arithmetic goes wrong.
	cutoff2 := shell_session_row_retention_cutoff("2026-03-03T06:30:00Z")
	testing.expectf(t, cutoff2 == "2026-02-24T06:30:00Z",
		"seven days before 2026-03-03T06:30:00Z is 2026-02-24T06:30:00Z, got %q", cutoff2)
}

// A malformed instant must yield NO cutoff rather than a plausible-looking one. This
// is the dangerous direction: a parser that quietly returned the zero Time would
// produce a cutoff in 1970 — which selects nothing — or, worse, one far in the future,
// which would select the entire table. Refusing is the only safe failure.
@(test)
test_row_retention_cutoff_refuses_a_malformed_instant :: proc(t: ^testing.T) {
	testing.expect(t, shell_session_row_retention_cutoff("") == "", "an empty instant yields no cutoff")
	testing.expect(t, shell_session_row_retention_cutoff("not-a-timestamp") == "", "garbage yields no cutoff")
	testing.expect(t, shell_session_row_retention_cutoff("2026-09-28") == "", "a date with no time yields no cutoff")
}

// The parser added to platform for this feature is the exact inverse of the formatter
// already there. Checked as a round trip because the two are only useful as a pair —
// the cutoff is parsed from a formatted column and written back for comparison
// against other formatted columns, so a mismatch in either direction breaks the
// compare silently.
@(test)
test_platform_rfc3339_round_trips :: proc(t: ^testing.T) {
	original := "2026-09-28T16:20:05Z"
	parsed, ok := platform.parse_rfc3339_utc(original)
	testing.expect(t, ok, "a formatted instant parses back")
	testing.expectf(t, platform.format_rfc3339_utc(parsed) == original,
		"round trip is lossless, got %q", platform.format_rfc3339_utc(parsed))

	_, bad_ok := platform.parse_rfc3339_utc("nonsense")
	testing.expect(t, !bad_ok, "a malformed instant reports failure rather than the epoch")
}


@(test)
test_live_shell_background_and_kill_update_projection :: proc(t: ^testing.T) {
 fx: Fx5
 fx5_make(&fx)
 defer fx5_free(&fx)
 live := agent_service.Agent_Service{}
 agent_service.tool_live_init(&live.tool_live)
 defer agent_service.tool_live_destroy(&live.tool_live)
 fx.svc.live_agents = &live
 row := fx5_start_run(&fx, false)
 inst := domain.Agent_Instance{agent_instance_id = INST_A, owner_user_id = "owner_a"}
 body := agent_service.tool_live_snapshot(&live, inst)
 testing.expect(t, strings.contains(body, row.session_id))
 delete(body)
 _, converted, _ := shell_session_set_background(&fx.svc, agent5_auth(), row.session_id)
 testing.expect(t, converted)
 body = agent_service.tool_live_snapshot(&live, inst)
 testing.expect(t, !strings.contains(body, `"active":[]`), "background conversion keeps the call active")
 delete(body)
 _ = shell_session_handle_exited(&fx.svc, row.session_id, "brg_1", "killed", 137, true)
 body = agent_service.tool_live_snapshot(&live, inst)
 testing.expect(t, strings.contains(body, `"active":[]`))
 testing.expect(t, strings.contains(body, `"status":"killed"`))
 delete(body)
 testing.expect_value(t, len(fx.content.messages), 0)
}
