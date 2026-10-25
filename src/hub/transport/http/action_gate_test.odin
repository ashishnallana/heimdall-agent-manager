package http

// REQ-EXP-GATE-3/4/6: every Actions route (user CRUD/run, /scheduled-prompts aliases,
// bridge snapshot and execute) is refused for an owner without the actions flag
// BEFORE any action repository read, write, lease, launch or prompt. These drive the
// production handlers with real trusted-proxy / bridge-token auth (wire fixture) and a
// counting fake action repository: a refusal leaves the counter at zero.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
Action_Gate_Exp :: struct {
	enabled_owner: string, // the only owner whose actions row is true
	since:         string, // updated_at of that row
	disabled_row:  bool,   // store an explicit enabled=false row instead of none
	fail:          bool,
}

@(private = "file")
action_gate_exp_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Action_Gate_Exp)(ctx)
	if r.fail do return nil, domain.domain_error(.Internal_Error, "database is locked")
	out := make([dynamic]domain.Experiment)
	if r.enabled_owner != "" && owner_user_id == r.enabled_owner {
		append(&out, domain.Experiment{owner_user_id = strings.clone(owner_user_id), key = strings.clone(domain.ACTIONS_EXPERIMENT_KEY), enabled = !r.disabled_row, updated_at = strings.clone(r.since)})
	}
	return out, domain.Domain_Error{}
}

// Counting fake: every action repository entry point increments calls.
@(private = "file")
Action_Gate_Repo :: struct {
	calls:    int,
	revision: i64,
}

@(private = "file")
gate_repo_get :: proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error) {
	(^Action_Gate_Repo)(ctx).calls += 1
	return domain.Action{}, false, domain.domain_error(.Not_Found, "action not found")
}

@(private = "file")
gate_repo_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Action, domain.Domain_Error) {
	(^Action_Gate_Repo)(ctx).calls += 1
	return nil, {}
}

@(private = "file")
gate_repo_save :: proc(ctx: rawptr, a: domain.Action) -> (domain.Action, bool, domain.Domain_Error) {
	(^Action_Gate_Repo)(ctx).calls += 1
	return a, true, {}
}

@(private = "file")
gate_repo_snapshot :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID, known: i64) -> (i64, []domain.Action, bool, domain.Domain_Error) {
	r := (^Action_Gate_Repo)(ctx)
	r.calls += 1
	return r.revision, nil, known == r.revision, {}
}

@(private = "file")
gate_repo_revision :: proc(ctx: rawptr) -> (i64, domain.Domain_Error) {
	return (^Action_Gate_Repo)(ctx).revision, {}
}

@(private = "file")
Action_Gate_Fixture :: struct {
	wire:     ^wire_fixture,
	exp:      Action_Gate_Exp,
	exp_repo: iface.Experiment_Repository,
	fake:     Action_Gate_Repo,
	repo:     iface.Action_Repository,
	h:        Action_Handlers,
}

@(private = "file")
setup_action_gate :: proc(t: ^testing.T, tag: string) -> ^Action_Gate_Fixture {
	f := new(Action_Gate_Fixture)
	f.wire = wire_setup(t, tag)
	f.fake.revision = 3
	f.exp_repo = iface.Experiment_Repository{ctx = rawptr(&f.exp), list_by_owner = action_gate_exp_list}
	f.repo = iface.Action_Repository{
		ctx = rawptr(&f.fake), get = gate_repo_get, list = gate_repo_list, save = gate_repo_save,
		snapshot = gate_repo_snapshot, revision = gate_repo_revision,
	}
	f.h = Action_Handlers{auth = &f.wire.auth_svc, agents = &f.wire.ag_svc, bridges = &f.wire.br_svc, repo = &f.repo, experiments = &f.exp_repo}
	return f
}

@(private = "file")
teardown_action_gate :: proc(f: ^Action_Gate_Fixture) {
	wire_teardown(f.wire)
	free(f)
}

@(private = "file")
Action_Gate_Route :: struct {
	name:    string,
	handler: Handler_Proc,
	method:  string,
	path:    string,
	body:    string,
}

// Every user route wiring.odin registers for /actions and the /scheduled-prompts aliases.
@(private = "file")
ACTION_USER_ROUTES := [?]Action_Gate_Route{
	{"list", list_actions_handler, "GET", "/api/v1/actions", ""},
	{"create", create_action_handler, "POST", "/api/v1/actions", `{"target_instance_id":"inst_x","prompt_text":"p","target_run_at":"2026-10-25T00:00:00Z"}`},
	{"get", get_action_handler, "GET", "/api/v1/actions/act_x", ""},
	{"patch", patch_action_handler, "PATCH", "/api/v1/actions/act_x", `{"prompt_text":"q"}`},
	{"delete", delete_action_handler, "DELETE", "/api/v1/actions/act_x", ""},
	{"run", run_action_handler, "POST", "/api/v1/actions/act_x/run", ""},
	{"alias list", list_scheduled_prompts_handler, "GET", "/api/v1/scheduled-prompts", ""},
	{"alias create", create_scheduled_prompt_handler, "POST", "/api/v1/scheduled-prompts", `{"target_instance_id":"inst_x","prompt_text":"p","target_run_at":"2026-10-25T00:00:00Z"}`},
	{"alias get", get_scheduled_prompt_handler, "GET", "/api/v1/scheduled-prompts/act_x", ""},
	{"alias patch", patch_scheduled_prompt_handler, "PATCH", "/api/v1/scheduled-prompts/act_x", `{"prompt_text":"q"}`},
	{"alias delete", delete_scheduled_prompt_handler, "DELETE", "/api/v1/scheduled-prompts/act_x", ""},
}

@(private = "file")
ACTION_BRIDGE_ROUTES := [?]Action_Gate_Route{
	{"bridge snapshot", bridge_list_actions_handler, "GET", "/api/v1/bridge/actions", ""},
	{"bridge execute", bridge_execute_action_handler, "POST", "/api/v1/bridge/actions/act_x/execute", `{"instance_id":"inst_x"}`},
	{"alias bridge snapshot", bridge_list_scheduled_prompts_handler, "GET", "/api/v1/bridge/scheduled-prompts", ""},
	{"alias bridge execute", bridge_execute_scheduled_prompt_handler, "POST", "/api/v1/bridge/scheduled-prompts/act_x/execute", `{"instance_id":"inst_x"}`},
}

@(private = "file")
action_gate_call :: proc(f: ^Action_Gate_Fixture, route: Action_Gate_Route, bridge: bool, extra: []contracts.HTTP_Header = nil) -> Response {
	req := wire_cookie_request(f.wire, route.method, route.path, route.body)
	if bridge {
		req = wire_agent_request(f.wire, "unused", route.body)
		req.method = route.method
		req.path = route.path
	}
	if extra != nil {
		headers := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
		append(&headers, ..req.headers)
		append(&headers, ..extra)
		req.headers = headers[:]
	}
	return route.handler(rawptr(&f.h), req)
}

@(private = "file")
expect_actions_disabled :: proc(t: ^testing.T, name: string, resp: Response) {
	testing.expectf(t, resp.status == 403, "%s: disabled Actions must be 403, got %d (%s)", name, resp.status, resp.body)
	testing.expectf(t, strings.contains(resp.body, `"code":"forbidden"`), "%s: existing forbidden code", name)
	testing.expectf(t, strings.contains(resp.body, "Actions is experimental. Enable it in Settings > Experimental to use it."), "%s: spec message", name)
	testing.expectf(t, strings.contains(resp.body, `"experimental_feature_disabled"`), "%s: details code", name)
	testing.expectf(t, strings.contains(resp.body, `"feature":"actions"`), "%s: details feature", name)
}

@(test)
test_actions_routes_refuse_disabled_owner_before_side_effects :: proc(t: ^testing.T) {
	f := setup_action_gate(t, "action_gate_off")
	defer teardown_action_gate(f)
	// Absent row, then an explicit false row: both disabled, zero repository calls.
	for pass in 0..<2 {
		if pass == 1 { f.exp.enabled_owner = string(f.wire.owner); f.exp.disabled_row = true }
		for route in ACTION_USER_ROUTES do expect_actions_disabled(t, route.name, action_gate_call(f, route, false))
		for route in ACTION_BRIDGE_ROUTES do expect_actions_disabled(t, route.name, action_gate_call(f, route, true))
	}
	testing.expect_value(t, f.fake.calls, 0)
}

@(test)
test_actions_routes_pass_enabled_owner_to_existing_checks :: proc(t: ^testing.T) {
	f := setup_action_gate(t, "action_gate_on")
	defer teardown_action_gate(f)
	f.exp.enabled_owner = string(f.wire.owner)
	f.exp.since = "2026-10-25T04:00:00Z"
	testing.expect_value(t, action_gate_call(f, ACTION_USER_ROUTES[0], false).status, 200)
	// Ownership/existence checks still run for an enabled owner.
	testing.expect_value(t, action_gate_call(f, ACTION_USER_ROUTES[2], false).status, 404)
	testing.expect_value(t, action_gate_call(f, ACTION_USER_ROUTES[5], false).status, 404)
	testing.expect_value(t, action_gate_call(f, ACTION_BRIDGE_ROUTES[1], true).status, 404)
	snap := action_gate_call(f, ACTION_BRIDGE_ROUTES[0], true)
	testing.expect_value(t, snap.status, 200)
	wire: struct { snapshot: struct {epoch: string, revision: i64, etag: string, eligible_since: string} }
	testing.expect(t, json.unmarshal_string(snap.body, &wire, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, wire.snapshot.eligible_since, "2026-10-25T04:00:00Z")
	testing.expect(t, strings.has_suffix(wire.snapshot.epoch, ".on20261025040000"), "eligibility folded into epoch")
	testing.expect(t, f.fake.calls > 0)
	// Missing request auth is still 401 (existing auth intact).
	req := wire_cookie_request(f.wire, "GET", "/api/v1/actions", "")
	req.headers = nil
	testing.expect_value(t, list_actions_handler(rawptr(&f.h), req).status, 401)
}

@(test)
test_actions_gate_is_owner_isolated :: proc(t: ^testing.T) {
	f := setup_action_gate(t, "action_gate_iso")
	defer teardown_action_gate(f)
	// Another user's opt-in never enables this owner or this owner's bridge.
	f.exp.enabled_owner = "someone_else"
	for route in ACTION_USER_ROUTES do expect_actions_disabled(t, route.name, action_gate_call(f, route, false))
	for route in ACTION_BRIDGE_ROUTES do expect_actions_disabled(t, route.name, action_gate_call(f, route, true))
	testing.expect_value(t, f.fake.calls, 0)
}

@(test)
test_actions_gate_fails_closed_on_experiment_repo_error :: proc(t: ^testing.T) {
	f := setup_action_gate(t, "action_gate_fail")
	defer teardown_action_gate(f)
	f.exp.enabled_owner = string(f.wire.owner)
	f.exp.fail = true
	for route in ACTION_USER_ROUTES do testing.expectf(t, action_gate_call(f, route, false).status == 500, "%s fails closed", route.name)
	for route in ACTION_BRIDGE_ROUTES do testing.expectf(t, action_gate_call(f, route, true).status == 500, "%s fails closed", route.name)
	testing.expect_value(t, f.fake.calls, 0)
	base, rev := action_schedules_owner_token(rawptr(&f.h), &f.exp_repo, string(f.wire.owner))
	testing.expect_value(t, base, "")
	testing.expect_value(t, rev, i64(-1))
}

@(test)
test_actions_snapshot_etag_and_token_track_eligibility :: proc(t: ^testing.T) {
	f := setup_action_gate(t, "action_gate_etag")
	defer teardown_action_gate(f)
	owner := string(f.wire.owner)
	f.exp.enabled_owner = owner
	f.exp.since = "2026-10-25T04:00:00Z"
	on_epoch, on_rev := action_schedules_owner_token(rawptr(&f.h), &f.exp_repo, owner)
	first := action_gate_call(f, ACTION_BRIDGE_ROUTES[0], true)
	testing.expect_value(t, first.status, 200)
	etag := ""
	for hd in first.headers do if hd.name == "ETag" do etag = hd.value
	testing.expect(t, etag != "")
	inm := []contracts.HTTP_Header{{name = "If-None-Match", value = etag}}
	testing.expect_value(t, action_gate_call(f, ACTION_BRIDGE_ROUTES[0], true, inm).status, 304)

	// Disable: the heartbeat token moves, and the old validator cannot revalidate.
	f.exp.disabled_row = true
	off_epoch, off_rev := action_schedules_owner_token(rawptr(&f.h), &f.exp_repo, owner)
	testing.expect(t, off_epoch != "" && off_epoch != on_epoch, "disable changes heartbeat epoch")
	testing.expect_value(t, off_rev, on_rev)
	calls := f.fake.calls
	expect_actions_disabled(t, "conditional snapshot after disable", action_gate_call(f, ACTION_BRIDGE_ROUTES[0], true, inm))
	testing.expect_value(t, f.fake.calls, calls)

	// Re-enable (new updated_at): a pre-disable ETag gets a full snapshot, never 304.
	f.exp.disabled_row = false
	f.exp.since = "2026-10-25T05:00:00Z"
	re_epoch, _ := action_schedules_owner_token(rawptr(&f.h), &f.exp_repo, owner)
	testing.expect(t, re_epoch != on_epoch && re_epoch != off_epoch, "re-enable mints a new epoch")
	testing.expect_value(t, action_gate_call(f, ACTION_BRIDGE_ROUTES[0], true, inm).status, 200)
}
