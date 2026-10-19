// Behavioral tests for shell_session_service create, restart, backgrounding, caps, port conflict, and start failure.
#+private file
package shell_session

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- Consolidated from shell_session_create_test.odin ---

@(private = "file")
Fake_Repo :: struct {
	last:   domain.Shell_Session,
	writes: int,
	// Canned answers for the two REQ-SHELL-2 create-time checks.
	port_holder:       domain.Shell_Session,
	live_count:        int,
	last_count_kind:   string,
	last_count_column: string,
	last_count_value:  string,
}

@(private = "file")
fake_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.last = session
	f.writes += 1
	return true, domain.Domain_Error{}
}

// REQ-SHELL-2 added two repository questions that create now asks before it
// writes anything: "is this port already held on this bridge?" and "is this agent
// or chain already at its live-session cap?". A fake that answers neither makes
// every create fail as misconfigured, so both are wired here.
//
// The defaults are the permissive answers — no holder, nothing live — so these
// tests keep testing what they were written to test. The cap and conflict
// behaviour has its own tests, which set the counters.
@(private = "file")
fake_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	if f.port_holder.session_id != "" && f.port_holder.server_port == server_port {
		return f.port_holder, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
fake_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.last_count_kind   = kind
	f.last_count_column = scope_column
	f.last_count_value  = scope_value
	return f.live_count, domain.Domain_Error{}
}

@(private = "file")
fake_repo :: proc(f: ^Fake_Repo) -> iface.Shell_Session_Repository {
	return iface.Shell_Session_Repository{
		ctx               = rawptr(f),
		upsert            = fake_upsert,
		find_live_by_port = fake_find_live_by_port,
		count_live        = fake_count_live,
	}
}

// A clock frozen at a known instant, so the test can assert on the exact value
// rather than on "something timestamp-shaped".
@(private = "file")
FROZEN_NOW :: "2026-09-28T08:00:00Z"

@(private = "file")
frozen_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return FROZEN_NOW
}

@(private = "file")
Fake_Sink :: struct {
	mu:        sync.Mutex,
	last_body: string,
	sends:     int,
}

// Records the dispatched spec and answers "not ok". create() then marks the row
// failed, which is irrelevant here — the spec has already been built and handed
// to the sink, which is the thing under test.
@(private = "file")
fake_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Fake_Sink)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	delete(s.last_body)
	s.last_body = strings.clone(command.body_json)
	s.sends += 1
	return "", false, domain.domain_error(.Bridge_Offline, "test sink")
}

@(private = "file")
Fixture :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	f:    Fake_Repo,
	sink: Fake_Sink,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
fixture_make :: proc(fx: ^Fixture) {
	fx.repo = fake_repo(&fx.f)
	fx.ids  = platform.real_id_generator()
	fx.clk  = platform.Clock{ctx = nil, now = frozen_now}
	fx.svc  = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = fake_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fixture_free :: proc(fx: ^Fixture) {
	shell_session_service_free(&fx.svc)
	delete(fx.sink.last_body)
}

@(private = "file")
test_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "user_clock"}
}

// REQ-SHELL-2 §1 made the STARTER part of create: a `run` is agent-only and a
// `shell` is user-only, decided from the auth KIND (an Instance_Token is an
// agent). Tests that want to reach scope validation for a run must therefore
// present an agent, or they are refused earlier, for a different reason.
@(private = "file")
test_agent_auth :: proc(instance_id := "") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "user_clock", agent_instance_id = instance_id}
}

// --- §8: one clock -----------------------------------------------------------

@(test)
test_shell_session_create_sends_the_hub_started_at_to_the_bridge :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})

	// The row carries the hub clock's value...
	testing.expect_value(t, fx.f.last.started_at, FROZEN_NOW)

	// ...and so does the spec the bridge is asked to spawn from. Two stamps for one
	// fact was the bug: the hub-side 1-day server reap and the bridge-side output
	// retention window read started_at from different clocks, so skew made them
	// disagree about the same session's age. They now read the same string.
	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, strings.contains(body, "\"started_at\":\"" + FROZEN_NOW + "\""), "shell_start spec carries the hub-assigned started_at")
}

// --- §5: scope enforced on create --------------------------------------------

@(test)
test_shell_session_create_rejects_a_kind_missing_its_scope :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// run is AGENT scoped, so a run with no agent_instance_id has no scope at all.
	//
	// Started BY AN AGENT WITH NO INSTANCE ID ON ITS TOKEN, deliberately: a run from
	// a user is refused by the starter rule before scope is ever reached, and an
	// agent whose token names an instance has that instance filled in for it. This
	// is the one shape that still reaches the scope check, which is what is under
	// test here.
	_, ok, err := shell_session_create(&fx.svc, test_agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Run,
		cmd       = "echo hi",
	})
	testing.expect(t, !ok, "a run without an agent_instance_id is rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)

	// server is CHAIN + BRIDGE scoped.
	_, ok2, err2 := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Server,
		cmd       = "serve",
	})
	testing.expect(t, !ok2, "a server without a chain_id is rejected")
	testing.expect_value(t, err2.code, domain.Error_Code.Validation_Failed)

	// Rejected means NOT STORED and never dispatched — not stored-then-complained-about.
	testing.expect_value(t, fx.f.writes, 0)
	testing.expect_value(t, fx.sink.sends, 0)
}

@(test)
test_shell_session_create_rejects_scope_columns_a_kind_does_not_use :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// shell is BRIDGE scoped with an OPTIONAL chain_id; agent_instance_id must be
	// left empty rather than filled with noise that later reads would treat as scope.
	_, ok, err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Shell,
		cmd               = "zsh",
		agent_instance_id = "inst_1",
	})
	testing.expect(t, !ok, "a shell carrying an agent_instance_id is rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)

	_, ok2, _ := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Server,
		cmd               = "serve",
		chain_id          = "chain_1",
		agent_instance_id = "inst_1",
	})
	testing.expect(t, !ok2, "a server carrying an agent_instance_id is rejected")
	testing.expect_value(t, fx.f.writes, 0)
}

@(test)
test_shell_session_create_accepts_each_kind_with_its_own_scope :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	// Each of the three, scoped per the rules. The sink answers not-ok, so create
	// returns false — what is asserted here is that it got PAST validation, which
	// the write count shows.
	// Each kind is presented by a starter allowed to start it (REQ-SHELL-2 §1):
	// run by an agent, shell by a user, server by either.
	_, _, run_err := shell_session_create(&fx.svc, test_agent_auth("inst_1"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run,
		cmd = "echo hi", agent_instance_id = "inst_1",
	})
	testing.expect(t, run_err.code != .Validation_Failed, "an agent-scoped run passes validation")
	testing.expect(t, run_err.code != .Forbidden, "an agent may start a run")

	_, _, shell_err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, cmd = "zsh",
	})
	testing.expect(t, shell_err.code != .Validation_Failed, "a bridge-scoped shell passes validation")

	_, _, server_err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, server_err.code != .Validation_Failed, "a chain+bridge-scoped server passes validation")

	testing.expect_value(t, fx.sink.sends, 3)
}

// --- §1: the retired vocabulary is gone, not aliased -------------------------

@(test)
test_shell_session_create_rejects_retired_kind_spellings :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	for retired in ([]string{"command", "interactive", "agent"}) {
		_, ok, err := shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
			bridge_id = "brg_1",
			kind      = retired,
			cmd       = "echo hi",
		})
		testing.expect(t, !ok, "a retired kind spelling is rejected")
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	}
	testing.expect_value(t, fx.f.writes, 0)
}

// An omitted kind defaults to `shell`, and never to a retired spelling.
//
// CHANGED BY REQ-SHELL-2 (N3). It used to default to `run`, which no user can
// legitimately start: scope validation then refused with "agent_instance_id is
// required for kind run", telling a plain REST caller about an agent field it had
// never mentioned, for a kind it could never have meant. `shell` is the kind a
// person opening a session means, and is what ham-ctl has always defaulted to.
//
// It cannot break a caller that worked before, because every existing caller
// sends an explicit kind — so nothing is silently re-pointed at a different kind
// by this default, it only replaces a guaranteed error with a useful one.
@(test)
test_shell_session_create_defaults_kind_to_shell :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		cmd       = "zsh",
	})
	testing.expect_value(t, fx.f.last.kind, domain.Shell_Session_Kind_Shell)
}

// The other half of N3: an AGENT that omits kind gets a refusal naming the kinds
// it can actually start, rather than the old scope error about a column.
@(test)
test_shell_session_create_agent_omitting_kind_is_told_what_it_may_start :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, test_agent_auth("inst_1"), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		cmd       = "echo hi",
	})
	testing.expect(t, !ok, "an agent cannot start the defaulted shell kind")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect(t, strings.contains(err.message, "user"), "the refusal names who may start a shell")
	testing.expect_value(t, fx.f.writes, 0)
}

// --- REQ-SHELL-ENC-7: enc_spec forwarding ------------------------------------

@(test)
test_shell_session_create_forwards_enc_spec_to_the_bridge :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	TEST_ENC_SPEC :: "vault:v2:test_armored_ciphertext_spec"
	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
		enc_spec  = TEST_ENC_SPEC,
	})

	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, strings.contains(body, "\"enc_spec\":\"" + TEST_ENC_SPEC + "\""), "shell_start spec carries enc_spec")
}

@(test)
test_shell_session_create_omits_enc_spec_when_empty :: proc(t: ^testing.T) {
	fx: Fixture
	fixture_make(&fx)
	defer fixture_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, test_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})

	sync.mutex_lock(&fx.sink.mu)
	body := strings.clone(fx.sink.last_body, context.temp_allocator)
	sends := fx.sink.sends
	sync.mutex_unlock(&fx.sink.mu)

	testing.expect_value(t, sends, 1)
	testing.expect(t, !strings.contains(body, "\"enc_spec\":"), "shell_start spec omits enc_spec when empty")
}

// --- Consolidated from shell_session_req2_test.odin ---

@(private = "file")
Repo2 :: struct {
	last:        domain.Shell_Session,
	writes:      int,
	stored:      domain.Shell_Session,
	has_stored:  bool,
	port_holder: domain.Shell_Session,
	live_count:  int,
	count_kind:   string,
	count_column: string,
	count_value:  string,
	listed:      [dynamic]domain.Shell_Session,
}

@(private = "file")
r2_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	r.last = session
	r.stored = session
	r.has_stored = true
	r.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r2_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	if r.has_stored && r.stored.session_id == session_id && r.stored.owner_user_id == owner_user_id {
		return r.stored, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r2_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	if r.port_holder.session_id != "" && r.port_holder.server_port == server_port {
		return r.port_holder, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r2_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	r.count_kind   = kind
	r.count_column = scope_column
	r.count_value  = scope_value
	return r.live_count, domain.Domain_Error{}
}

@(private = "file")
r2_list_by_owner :: proc(ctx: rawptr, owner_user_id: string, filter: iface.Shell_Session_List_Filter, cursor: string, limit: int) -> ([dynamic]domain.Shell_Session, string, domain.Domain_Error) {
	r := (^Repo2)(ctx)
	out := make([dynamic]domain.Shell_Session)
	for s in r.listed {
		if filter.agent_instance_id != "" && s.agent_instance_id != filter.agent_instance_id do continue
		append(&out, s)
	}
	return out, "", domain.Domain_Error{}
}

@(private = "file")
Fx2 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo2,
	sink: Sink2,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
Sink2 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

@(private = "file")
s2_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink2)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return "", false, domain.domain_error(.Bridge_Offline, "test sink")
}

@(private = "file")
s2_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink2)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
now2 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T09:00:00Z" }

@(private = "file")
fx2_make :: proc(fx: ^Fx2) {
	fx.r.listed = make([dynamic]domain.Shell_Session)
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r2_upsert,
		get               = r2_get,
		find_live_by_port = r2_find_live_by_port,
		count_live        = r2_count_live,
		list_by_owner     = r2_list_by_owner,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now2}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s2_send_wait,
			send_runtime_command      = s2_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx2_free :: proc(fx: ^Fx2) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.r.listed)
}

@(private = "file")
user_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent_auth :: proc(inst := "inst_a") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = inst}
}

// --- §1 / AC5: run is agent-only, enforced in the service --------------------

// AC5. A USER-authenticated caller attempting to create a kind=run session is
// rejected. Asserted at the SERVICE, deliberately: the requirement is that this
// is enforced at the API rather than only in the UI, and the service is the layer
// every transport goes through — a check that lived only in the REST handler
// would be bypassed by the next caller added.
@(test)
test_req2_a_user_cannot_start_a_run :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "echo hi",
		agent_instance_id = "inst_a",
	})
	testing.expect(t, !ok, "a user may not start a run")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	// Refused means nothing was written and the bridge was never asked to spawn.
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// The mirror: an agent may not start a `shell`, which is a user's interactive
// terminal. Both directions come from one table, so neither can drift.
@(test)
test_req2_an_agent_cannot_start_a_shell :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, ok, err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})
	testing.expect(t, !ok, "an agent may not start an interactive shell")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
}

// A server is startable by BOTH, which is the explicit instruction not to build an
// agent-only variant.
@(test)
test_req2_a_server_may_be_started_by_either :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, _, user_err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, user_err.code != .Forbidden, "a user may start a server")

	_, _, agent_err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, agent_err.code != .Forbidden, "and so may an agent")
}

// An agent's run is attributed from its TOKEN, not from the body, so a run cannot
// be pinned on a different agent instance by asking.
@(test)
test_req2_a_run_is_attributed_from_the_token :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)

	_, _, _ = shell_session_create(&fx.svc, agent_auth("inst_real"), Shell_Session_Create_Input{
		bridge_id         = "brg_1",
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "echo hi",
		agent_instance_id = "inst_someone_else",
	})
	testing.expect_value(t, fx.r.last.agent_instance_id, "inst_real")
}

// --- §10 / AC13: port conflicts ---------------------------------------------

// AC13, same-owner branch: the conflict names the session holding the port,
// because the caller can act on that.
@(test)
test_req2_same_owner_port_conflict_names_the_holder :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id    = "sh_holder",
		owner_user_id = "owner_a",
		kind          = domain.Shell_Session_Kind_Server,
		server_port   = 8111,
		status        = domain.Shell_Session_Status_Running,
	}

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1", server_port = 8111,
	})
	testing.expect(t, !ok, "the second server on the same port is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "sh_holder"), "a same-owner conflict names the holder")
	testing.expect_value(t, fx.r.writes, 0)
}

// AC13, cross-owner branch. THE ASYMMETRY IS THE POINT and this test exists to
// keep it: the LOOKUP stays owner-unscoped (a port is a host resource, so the
// conflict is real and must be reported), but the ANSWER must not disclose
// another tenant's session id or kind, nor tell the caller to kill something they
// cannot touch.
@(test)
test_req2_cross_owner_port_conflict_discloses_nothing :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id    = "sh_other_tenant",
		owner_user_id = "owner_b",
		kind          = domain.Shell_Session_Kind_Server,
		server_port   = 8111,
		status        = domain.Shell_Session_Status_Running,
	}

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server,
		cmd = "serve", chain_id = "chain_1", server_port = 8111,
	})
	testing.expect(t, !ok, "the conflict is still reported across tenants")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	// The negatives are the substance of this test.
	testing.expect(t, !strings.contains(err.message, "sh_other_tenant"), "the other tenant's session id is NOT disclosed")
	testing.expect(t, !strings.contains(err.message, "owner_b"), "nor its owner")
	testing.expect(t, !strings.contains(err.message, "kill"), "and the caller is not told to kill what it cannot touch")
	testing.expect(t, strings.contains(err.message, "in use"), "but it is told the port is unavailable")
}

// A port nobody holds is not a conflict, and a session with no port asks nothing.
@(test)
test_req2_no_port_is_never_a_conflict :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.port_holder = domain.Shell_Session{
		session_id = "sh_holder", owner_user_id = "owner_a", server_port = 8111,
	}

	// AC11's second half: a serve with no --port starts fine.
	_, _, err := shell_session_create(&fx.svc, agent_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_1",
	})
	testing.expect(t, err.code != .Conflict, "a server with no port exposes nothing and conflicts with nothing")
}

// --- §11 / AC14: caps --------------------------------------------------------

// AC14, runs. The cap is PER AGENT, which is the scope a run already has — the
// scope column the count narrows on is read from the domain rather than named
// here, so the cap cannot drift from the scope rule.
@(test)
test_req2_run_cap_is_per_agent :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT

	_, ok, err := shell_session_create(&fx.svc, agent_auth("inst_busy"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run, cmd = "echo hi",
	})
	testing.expect(t, !ok, "an over-cap run is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "agent instance"), "the refusal names the scope the cap applies to")
	testing.expect_value(t, fx.r.writes, 0)

	// It counted LIVE sessions of this kind, narrowed by the agent column.
	testing.expect_value(t, fx.r.count_kind, domain.Shell_Session_Kind_Run)
	testing.expect_value(t, fx.r.count_column, "agent_instance_id")
	testing.expect_value(t, fx.r.count_value, "inst_busy")
}

// AC14, servers. Per CHAIN, again following that kind's own scope.
@(test)
test_req2_server_cap_is_per_chain :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_SERVERS_PER_CHAIN

	_, ok, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Server, cmd = "serve", chain_id = "chain_busy",
	})
	testing.expect(t, !ok, "an over-cap server is refused")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect(t, strings.contains(err.message, "task chain"), "the refusal names the chain scope")
	testing.expect_value(t, fx.r.count_column, "chain_id")
	testing.expect_value(t, fx.r.count_value, "chain_busy")
}

// One below the cap still passes: the cap is a runaway backstop, not an off-by-one
// trap for a workflow sitting just under it.
@(test)
test_req2_just_under_the_cap_is_allowed :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = domain.SHELL_SESSION_MAX_LIVE_RUNS_PER_AGENT - 1

	_, _, err := shell_session_create(&fx.svc, agent_auth("inst_a"), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Run, cmd = "echo hi",
	})
	testing.expect(t, err.code != .Conflict, "the last run under the cap is allowed")
}

// A `shell` has no cap: it is opened by a person, one at a time, and there is no
// runaway shape to bound.
@(test)
test_req2_a_shell_has_no_cap :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	fx.r.live_count = 10_000

	_, _, err := shell_session_create(&fx.svc, user_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1", kind = domain.Shell_Session_Kind_Shell, cmd = "zsh",
	})
	testing.expect(t, err.code != .Conflict, "an interactive shell is not capped")
}

// --- §3 / AC3: the conversion, hub half --------------------------------------

@(private = "file")
seed_live_run :: proc(fx: ^Fx2, session_id := "sh_run_1", agent := "inst_a", background := false) {
	fx.r.stored = domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = "owner_a",
		bridge_id         = "brg_1",
		agent_instance_id = agent,
		kind              = domain.Shell_Session_Kind_Run,
		cmd               = "sleep 60",
		status            = domain.Shell_Session_Status_Running,
		background        = background,
	}
	fx.r.has_stored = true
	fx.r.writes = 0
}

// AC3, hub half: the conversion writes the row and asks the bridge to release the
// blocked caller. The bridge half (the caller actually being released with the
// session id) is asserted in the bridge suite.
@(test)
test_req2_background_conversion_persists_then_signals :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx)

	session, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, ok, "a live foreground run can be backgrounded")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, session.background, "the returned session is background")
	testing.expect_value(t, fx.r.writes, 1)
	testing.expect(t, fx.r.last.background, "and the ROW says so, so it survives a bridge restart")

	// The row is written BEFORE the bridge is told, so a bridge that never gets the
	// command still leaves a run the hub correctly calls background.
	sync.mutex_lock(&fx.sink.mu)
	defer sync.mutex_unlock(&fx.sink.mu)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], "shell_background"), "the bridge is asked to convert")
	testing.expect(t, strings.contains(fx.sink.bodies[0], "sh_run_1"), "naming the session")
}

// ONE-WAY. A run already background is refused, so a double-click cannot release
// a second waiter or re-arm a notification.
@(test)
test_req2_background_conversion_is_one_way :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, background = true)

	_, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, !ok, "a run already in the background is not converted again")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect_value(t, fx.r.writes, 0)
}

// Only a RUN has a foreground form, so only a run can be backgrounded.
@(test)
test_req2_only_a_run_can_be_backgrounded :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx)
	fx.r.stored.kind = domain.Shell_Session_Kind_Server

	_, ok, err := shell_session_set_background(&fx.svc, user_auth(), "sh_run_1")
	testing.expect(t, !ok, "a server has no foreground form to convert from")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
}

// --- §9 / AC12: a foreground run whose agent goes unreachable ----------------

// AC12. The run must not stay a live untracked FOREGROUND run. It is CONVERTED,
// not killed — see shell_session_background_runs_for_agent for why: the signals
// that trigger this include a bridge-wide disconnect on which the agent processes
// are usually alive, so killing would destroy in-flight work on a transient blip.
@(test)
test_req2_unreachable_agent_backgrounds_its_foreground_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_gone")
	append(&fx.r.listed, fx.r.stored)

	converted := shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone")
	testing.expect_value(t, converted, 1)
	testing.expect(t, fx.r.last.background, "the stranded foreground run is now background")
	// Converted, NOT killed: it is still running, so it stays addressable, killable,
	// reapable and capped, and it now notifies on completion.
	testing.expect_value(t, fx.r.last.status, domain.Shell_Session_Status_Running)
}

// A run that is ALREADY background is left alone, so the returned count means
// "runs actually rescued" rather than counting no-ops.
@(test)
test_req2_unreachable_agent_skips_already_background_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_gone", background = true)
	append(&fx.r.listed, fx.r.stored)

	testing.expect_value(t, shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone"), 0)
	testing.expect_value(t, fx.r.writes, 0)
}

// Another agent's runs are untouched: the hook is scoped to the instance that
// actually went away.
@(test)
test_req2_unreachable_agent_does_not_touch_other_agents_runs :: proc(t: ^testing.T) {
	fx: Fx2
	fx2_make(&fx)
	defer fx2_free(&fx)
	seed_live_run(&fx, "sh_run_1", "inst_healthy")
	append(&fx.r.listed, fx.r.stored)

	testing.expect_value(t, shell_session_background_runs_for_agent(&fx.svc, "owner_a", "inst_gone"), 0)
	testing.expect_value(t, fx.r.writes, 0)
}

// --- Consolidated from shell_session_req16_test.odin ---

@(private = "file")
R16_Repo :: struct {
	last:   domain.Shell_Session,
	writes: int,
}

@(private = "file")
r16_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	f := (^R16_Repo)(ctx)
	f.last = session
	f.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r16_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r16_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

@(private = "file")
r16_repo :: proc(f: ^R16_Repo) -> iface.Shell_Session_Repository {
	return iface.Shell_Session_Repository{
		ctx               = rawptr(f),
		upsert            = r16_upsert,
		find_live_by_port = r16_find_live_by_port,
		count_live        = r16_count_live,
	}
}

@(private = "file")
R16_NOW :: "2026-09-28T09:00:00Z"

@(private = "file")
r16_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return R16_NOW
}

// Unlike the create-test sink, this one ANSWERS. The reply it returns is the whole
// point: the D1b defect was that a well-formed `ok:false` reply carrying a reason
// reached the hub and the reason was dropped, so a sink that merely reports
// transport failure cannot reach the code under test at all.
@(private = "file")
R16_Sink :: struct {
	mu:         sync.Mutex,
	reply:      string, // canned bridge reply, returned verbatim
	reply_ok:   bool,   // false = transport/offline branch instead
	sends:      int,
}

@(private = "file")
r16_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	_ = command
	s := (^R16_Sink)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	s.sends += 1
	if !s.reply_ok do return "", false, domain.domain_error(.Bridge_Offline, "test sink offline")
	// create() takes ownership of the reply and deletes it, so hand over a clone.
	return strings.clone(s.reply), true, domain.Domain_Error{}
}

@(private = "file")
R16_Fixture :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	f:    R16_Repo,
	sink: R16_Sink,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
r16_fixture_make :: proc(fx: ^R16_Fixture, reply: string, reply_ok := true) {
	fx.repo         = r16_repo(&fx.f)
	fx.ids          = platform.real_id_generator()
	fx.clk          = platform.Clock{ctx = nil, now = r16_now}
	fx.sink.reply   = reply
	fx.sink.reply_ok = reply_ok
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = r16_send_wait,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
r16_fixture_free :: proc(fx: ^R16_Fixture) {
	shell_session_service_free(&fx.svc)
}

@(private = "file")
r16_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "user_r16"}
}

@(private = "file")
r16_create :: proc(fx: ^R16_Fixture) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return shell_session_create(&fx.svc, r16_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_r16",
		kind      = domain.Shell_Session_Kind_Shell,
		cmd       = "zsh",
	})
}

// --- D1b: the bridge's reason survives ---------------------------------------

@(test)
test_req16_start_failure_surfaces_the_bridge_reason :: proc(t: ^testing.T) {
	fx: R16_Fixture
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false,"error":{"code":"bridge_busy","class":"retriable","cause":"pty_host_unreachable","message":"daemon unavailable"}}`)
	defer r16_fixture_free(&fx)

	_, ok, err := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	// The specific reason is the whole point: "daemon unavailable" is one of the four
	// bridge rejection reasons, and before this it was replaced by a constant that
	// made all four indistinguishable.
	testing.expect(
		t,
		strings.contains(err.message, "daemon unavailable"),
		"the bridge's reason must reach the caller",
	)
	// The generic text is kept as context rather than replaced, so existing callers
	// and logs still match on it.
	testing.expect(
		t,
		strings.contains(err.message, "bridge failed to start shell session"),
		"the generic context must be kept alongside the reason",
	)
}

@(test)
test_req16_start_failure_without_a_reason_falls_back_to_the_constant :: proc(t: ^testing.T) {
	fx: R16_Fixture
	// No `error` field at all. This is also the case that made the unconditional
	// delete in the old set_server_port branch a bad free: _json_str returns a
	// non-allocated "" literal here.
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false}`)
	defer r16_fixture_free(&fx)

	_, ok, err := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")
	testing.expect_value(t, err.message, "bridge failed to start shell session")
}

// --- D2: a terminal row carries a finish time --------------------------------

@(test)
test_req16_start_failure_stamps_finished_at :: proc(t: ^testing.T) {
	fx: R16_Fixture
	r16_fixture_make(&fx, `{"type":"shell_start_result","ok":false,"error":{"code":"unprocessable_entity","class":"fatal","cause":"shell_start_failed","message":"spawn failed"}}`)
	defer r16_fixture_free(&fx)

	_, ok, _ := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	testing.expect_value(t, fx.f.last.status, domain.Shell_Session_Status_Failed)
	testing.expect_value(t, fx.f.last.finished_at, R16_NOW)

	// The invariant from domain/shell_session.odin:356-392: a synthesized terminal
	// must not claim to have observed an exit.
	testing.expect(t, !fx.f.last.exit_code_set, "a synthesized terminal must not set exit_code_set")
	testing.expect(
		t,
		!domain.shell_session_terminal_is_observed(fx.f.last),
		"a start failure must not be classified as an observed terminal",
	)
}

@(test)
test_req16_offline_bridge_start_failure_also_stamps_finished_at :: proc(t: ^testing.T) {
	fx: R16_Fixture
	// The OTHER failure branch: the bridge never answered at all. It was equally
	// unstamped, and is the branch the production row most likely came through.
	r16_fixture_make(&fx, "", reply_ok = false)
	defer r16_fixture_free(&fx)

	_, ok, _ := r16_create(&fx)
	testing.expect(t, !ok, "create must report failure")

	testing.expect_value(t, fx.f.last.status, domain.Shell_Session_Status_Failed)
	testing.expect_value(t, fx.f.last.finished_at, R16_NOW)
	testing.expect(t, !fx.f.last.exit_code_set, "a synthesized terminal must not set exit_code_set")
}

// --- Consolidated from shell_session_req24_test.odin ---

@(private = "file")
Repo24 :: struct {
	stored: domain.Shell_Session,
	has:    bool,
	writes: int,
	last:   domain.Shell_Session,
}

@(private = "file")
r24_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo24)(ctx)
	r.stored = session
	r.last = session
	r.has = true
	r.writes += 1
	return true, domain.Domain_Error{}
}

@(private = "file")
r24_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo24)(ctx)
	if r.has && r.stored.session_id == session_id && r.stored.owner_user_id == owner_user_id {
		return r.stored, true, domain.Domain_Error{}
	}
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
Sink24 :: struct {
	mu:     sync.Mutex,
	bodies: [dynamic]string,
}

// The reply is a SUCCESSFUL respawn, so the permitted cases (AC3, AC4) genuinely
// travel the whole path — bridge send, ok-reply, row update — rather than passing
// for the unrelated reason that the fake bridge refused them.
@(private = "file")
s24_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink24)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return strings.clone("{\"ok\":true,\"pid\":4242}"), true, domain.Domain_Error{}
}

@(private = "file")
s24_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink24)(ctx)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

@(private = "file")
now24 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-29T03:00:00Z" }

@(private = "file")
Fx24 :: struct {
	svc:  Shell_Session_Service,
	repo: iface.Shell_Session_Repository,
	r:    Repo24,
	sink: Sink24,
	ids:  platform.ID_Generator,
	clk:  platform.Clock,
}

@(private = "file")
fx24_make :: proc(fx: ^Fx24) {
	fx.sink.bodies = make([dynamic]string)
	fx.repo = iface.Shell_Session_Repository{
		ctx    = rawptr(&fx.r),
		upsert = r24_upsert,
		get    = r24_get,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now24}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s24_send_wait,
			send_runtime_command      = s24_send,
		},
		ids   = &fx.ids,
		clock = &fx.clk,
	)
}

@(private = "file")
fx24_free :: proc(fx: ^Fx24) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
}

// seed installs a LIVE session of `kind` owned by owner_a, as the thing to restart.
// agent_instance_id is set for a run because that is how a real run row looks; the
// gate must not depend on it, which is the point of AC2 — the user owns this row.
@(private = "file")
fx24_seed :: proc(fx: ^Fx24, kind: string) {
	fx.r.stored = domain.Shell_Session{
		session_id        = "sh_1",
		owner_user_id     = "owner_a",
		bridge_id         = "brg_1",
		kind              = kind,
		status            = domain.Shell_Session_Status_Running,
		run_seq           = 0,
		agent_instance_id = "inst_a" if kind == domain.Shell_Session_Kind_Run else "",
	}
	fx.r.has = true
	fx.r.writes = 0
}

@(private = "file")
user24 :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = "owner_a"}
}

@(private = "file")
agent24 :: proc(inst := "inst_a") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = inst}
}

// --- AC2: a user may not restart a run, and nothing is spawned ---------------

// THE DEFECT ITSELF. Note what makes it reachable: the row is owned by owner_a and
// the caller IS owner_a, so ownership — the only check restart used to perform —
// passes. The refusal has to come from the starter rule or not at all.
@(test)
test_req24_a_user_cannot_restart_a_run :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Run)

	_, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")

	testing.expect(t, !ok, "a user may not restart an agent-only run")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)

	// AC2's second half, asserted explicitly: a refusal that still delivered
	// shell_restart to the bridge would be WORSE than the bug being fixed — the
	// process would respawn while the API claimed it had refused.
	testing.expect_value(t, len(fx.sink.bodies), 0)
	// And nothing was persisted, so run_seq did not move either.
	testing.expect_value(t, fx.r.writes, 0)
	testing.expect_value(t, fx.r.stored.run_seq, 0)
}

// --- AC3: an agent restarting its OWN run still works -----------------------

// The over-correction guard, and the reason the fix is a STARTER check rather than
// a ban on restarting runs: re-running is the agent's call.
@(test)
test_req24_an_agent_may_restart_its_own_run :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Run)

	session, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")

	testing.expect(t, ok, "an agent may restart its own run")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	// It really respawned: the bridge was asked, and the new run was adopted.
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect(t, strings.contains(fx.sink.bodies[0], "\"type\":\"shell_restart\""), "the bridge was sent shell_restart")
	testing.expect_value(t, session.run_seq, 1)
	testing.expect_value(t, fx.r.stored.run_seq, 1)
	testing.expect_value(t, session.pid, 4242)
}

// --- AC4: user restart of shell and server is UNAFFECTED --------------------

// A `shell` is a user's own interactive terminal. If this fails, the fix narrowed
// something it was told not to touch.
@(test)
test_req24_a_user_may_still_restart_a_shell :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Shell)

	session, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")

	testing.expect(t, ok, "a user may restart their own shell")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(fx.sink.bodies), 1)
	testing.expect_value(t, session.run_seq, 1)
}

// A `server` permits BOTH starters, so both must still be able to restart one.
// Covered in both directions because "server is startable by either" is the entry
// in the rules table an over-broad gate would silently take away.
@(test)
test_req24_a_user_may_still_restart_a_server :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Server)

	_, ok, err := shell_session_restart(&fx.svc, user24(), "sh_1")
	testing.expect(t, ok, "a user may restart a server")
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(test)
test_req24_an_agent_may_still_restart_a_server :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Server)

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, ok, "an agent may restart a server")
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

// --- the mirror, and fail-closed -------------------------------------------

// The other half of the table: an agent may not start a `shell`, so it may not
// restart one either. This is not a case anyone reported — it is here so the gate
// is asserted as the TABLE it reads from rather than as a single run-shaped
// special case, which is how a rules-table change would slip past one-sided tests.
@(test)
test_req24_an_agent_cannot_restart_a_shell :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, domain.Shell_Session_Kind_Shell)

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, !ok, "an agent may not restart a user's interactive shell")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// A stored kind the hub cannot name FAILS CLOSED. Treating unknown as permitted
// would reintroduce this hole for exactly the rows that are already malformed.
@(test)
test_req24_an_unknown_stored_kind_cannot_be_restarted :: proc(t: ^testing.T) {
	fx: Fx24
	fx24_make(&fx)
	defer fx24_free(&fx)
	fx24_seed(&fx, "command") // a retired REQ-SHELL-1 spelling: parses as nothing

	_, ok, err := shell_session_restart(&fx.svc, agent24(), "sh_1")
	testing.expect(t, !ok, "an unnameable kind is not restartable by anyone")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, len(fx.sink.bodies), 0)
}

// --- Consolidated from shell_session_req25_test.odin ---

@(test)
test_req25_started_event_names_the_type_the_client_switches_on :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_1", "run", "running", "")
	defer delete(evt)
	testing.expect(
		t,
		strings.contains(evt, `"type":"shell_session_started"`),
		"the client switches on this exact type string",
	)
	testing.expect(t, strings.contains(evt, `"session_id":"sh_1"`))
	testing.expect(t, strings.contains(evt, `"kind":"run"`))
	testing.expect(t, strings.contains(evt, `"status":"running"`))
}

// chain_id is what lets a `server` repaint the chain summary's active-server list on the
// same frame, because the client invalidates by session AND by chain.
@(test)
test_req25_started_event_carries_chain_id_for_servers :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_2", "server", "running", "chain_7")
	defer delete(evt)
	testing.expect(t, strings.contains(evt, `"chain_id":"chain_7"`))
	testing.expect(t, strings.contains(evt, `"kind":"server"`))
}

// Omitted rather than sent as "", matching how the exited event treats an absent
// exit_code. A run has no chain, so this is the common case, not an edge one.
@(test)
test_req25_started_event_omits_empty_chain_id :: proc(t: ^testing.T) {
	evt := _shell_session_started_event_json("sh_3", "run", "running", "")
	defer delete(evt)
	testing.expect(
		t,
		!strings.contains(evt, "chain_id"),
		"an empty chain_id is omitted, not emitted as an empty string",
	)
}

// The event is emitted for ALL THREE KINDS, not runs only: the transcript marker is
// runs-only because it is conversation content, but this is a cache invalidation and a
// `shell` must reach the session list as promptly as a run reaches the thread.
@(test)
test_req25_started_event_is_not_run_only :: proc(t: ^testing.T) {
	for kind in ([]string{"run", "shell", "server"}) {
		evt := _shell_session_started_event_json("sh_4", kind, "running", "")
		defer delete(evt)
		testing.expect(
			t,
			strings.contains(evt, strings.concatenate({`"kind":"`, kind, `"`}, context.temp_allocator)),
			"every kind gets a creation event",
		)
	}
}
