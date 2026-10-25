package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Gate_Exp_Repo is an owner-keyed fake: rows belong to one owner and list_by_owner
// returns only that owner's rows, like the SQLite repository.
@(private = "file")
Gate_Exp_Repo :: struct {
	rows:  []domain.Experiment,
	fail:  bool,
	calls: int,
	last_owner: string,
}

@(private = "file")
gate_exp_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Gate_Exp_Repo)(ctx)
	r.calls += 1
	r.last_owner = owner_user_id
	if r.fail do return nil, domain.domain_error(.Not_Found, "database is locked")
	out := make([dynamic]domain.Experiment)
	for row in r.rows {
		if row.owner_user_id != owner_user_id do continue
		append(&out, domain.Experiment{owner_user_id = strings.clone(row.owner_user_id), key = strings.clone(row.key), enabled = row.enabled, updated_at = strings.clone("2026-10-25T00:00:00Z")})
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
gate_repo :: proc(fake: ^Gate_Exp_Repo) -> iface.Experiment_Repository {
	return iface.Experiment_Repository{ctx = rawptr(fake), list_by_owner = gate_exp_list}
}

@(test)
test_experiment_gate_absent_and_false_are_disabled :: proc(t: ^testing.T) {
	fake := Gate_Exp_Repo{rows = {{owner_user_id = "user_a", key = domain.ACTIONS_EXPERIMENT_KEY, enabled = false}}}
	repo := gate_repo(&fake)

	off := experiment_gate_error(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, off.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, fake.last_owner, "user_a")

	absent := experiment_gate_error(&repo, "user_a", domain.PROJECT_VCS_EXPERIMENT_KEY)
	testing.expect_value(t, absent.code, domain.Error_Code.Forbidden)
	testing.expect(t, strings.contains(absent.details_json, `"feature":"project_vcs"`))
}

@(test)
test_experiment_gate_enabled_passes :: proc(t: ^testing.T) {
	fake := Gate_Exp_Repo{rows = {
		{owner_user_id = "user_a", key = domain.ACTIONS_EXPERIMENT_KEY, enabled = true},
		{owner_user_id = "user_a", key = domain.PROJECT_VCS_EXPERIMENT_KEY, enabled = true},
	}}
	repo := gate_repo(&fake)
	testing.expect_value(t, experiment_gate_error(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY).code, domain.Error_Code.None)
	testing.expect_value(t, experiment_gate_error(&repo, "user_a", domain.PROJECT_VCS_EXPERIMENT_KEY).code, domain.Error_Code.None)

	ok, resp := require_experiment_enabled(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY, "req_1")
	testing.expect(t, ok)
	testing.expect_value(t, resp.status, 0)
}

// One owner's opt-in never enables another owner (user or bridge-owner credentials).
@(test)
test_experiment_gate_is_owner_isolated :: proc(t: ^testing.T) {
	fake := Gate_Exp_Repo{rows = {{owner_user_id = "user_a", key = domain.ACTIONS_EXPERIMENT_KEY, enabled = true}}}
	repo := gate_repo(&fake)
	testing.expect_value(t, experiment_gate_error(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY).code, domain.Error_Code.None)
	other := experiment_gate_error(&repo, "user_b", domain.ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, other.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, fake.last_owner, "user_b")

	calls := fake.calls
	no_owner := experiment_gate_error(&repo, "", domain.ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, no_owner.code, domain.Error_Code.Forbidden)
	testing.expect_value(t, fake.calls, calls) // never lists an unscoped owner
}

// Repository failures and missing wiring fail closed with internal_error, not success
// and not a misleading "disabled".
@(test)
test_experiment_gate_repo_failure_fails_closed :: proc(t: ^testing.T) {
	fake := Gate_Exp_Repo{rows = {{owner_user_id = "user_a", key = domain.ACTIONS_EXPERIMENT_KEY, enabled = true}}, fail = true}
	repo := gate_repo(&fake)
	failed := experiment_gate_error(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, failed.code, domain.Error_Code.Internal_Error)

	ok, resp := require_experiment_enabled(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY, "req_2")
	defer delete(resp.body)
	testing.expect(t, !ok)
	testing.expect_value(t, resp.status, 500)
	testing.expect(t, strings.contains(resp.body, `"code":"internal_error"`))

	testing.expect_value(t, experiment_gate_error(nil, "user_a", domain.ACTIONS_EXPERIMENT_KEY).code, domain.Error_Code.Internal_Error)
	unwired := iface.Experiment_Repository{}
	testing.expect_value(t, experiment_gate_error(&unwired, "user_a", domain.ACTIONS_EXPERIMENT_KEY).code, domain.Error_Code.Internal_Error)
}

// REQ-EXP-GATE-3 wire shape: 403, error.code forbidden, exact message, details.
@(test)
test_require_experiment_enabled_disabled_response_envelope :: proc(t: ^testing.T) {
	fake := Gate_Exp_Repo{}
	repo := gate_repo(&fake)
	ok, resp := require_experiment_enabled(&repo, "user_a", domain.ACTIONS_EXPERIMENT_KEY, "req_3")
	defer delete(resp.body)
	testing.expect(t, !ok)
	testing.expect_value(t, resp.status, 403)
	testing.expect_value(t, resp.content_type, "application/json")

	Envelope :: struct {
		error: struct {
			code:    string,
			message: string,
			details: struct {code: string, feature: string},
		},
	}
	env: Envelope
	testing.expect(t, json.unmarshal_string(resp.body, &env, .JSON, context.temp_allocator) == nil, resp.body)
	testing.expect_value(t, env.error.code, "forbidden")
	testing.expect_value(t, env.error.message, "Actions is experimental. Enable it in Settings > Experimental to use it.")
	testing.expect_value(t, env.error.details.code, "experimental_feature_disabled")
	testing.expect_value(t, env.error.details.feature, "actions")
}

// The new flag is opt-in in the settings listing: never listed as on for a fresh user.
@(test)
test_experiment_list_does_not_default_actions_on :: proc(t: ^testing.T) {
	empty := experiment_list_json({})
	defer delete(empty)
	testing.expect(t, !strings.contains(empty, `"actions"`))
	testing.expect(t, !strings.contains(empty, `"project_vcs"`))
}
