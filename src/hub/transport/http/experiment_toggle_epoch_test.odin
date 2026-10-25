package http

// REQ-EXP-GATE-4 integration: clock_now has one-second resolution and the Actions
// snapshot epoch / eligible_since derive from the flag's updated_at. These drive the
// production PUT /api/v1/me/experiments/{key} handler (real cookie auth) with a frozen
// clock, so an on/off/on happens inside one second, and check that the re-enable still
// yields a fresh on-epoch: a bridge that suspended on the first on-epoch must see a
// token change and resync instead of staying suspended.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

@(private = "file")
Toggle_Exp_Repo :: struct {
	rows: [dynamic]domain.Experiment,
}

@(private = "file")
toggle_exp_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Toggle_Exp_Repo)(ctx)
	out := make([dynamic]domain.Experiment)
	for row in r.rows {
		if row.owner_user_id != owner_user_id do continue
		append(&out, domain.Experiment{owner_user_id = strings.clone(row.owner_user_id), key = strings.clone(row.key), enabled = row.enabled, updated_at = strings.clone(row.updated_at)})
	}
	return out, {}
}

@(private = "file")
toggle_exp_set :: proc(ctx: rawptr, exp: domain.Experiment) -> (bool, domain.Domain_Error) {
	r := (^Toggle_Exp_Repo)(ctx)
	for &row in r.rows {
		if row.owner_user_id == exp.owner_user_id && row.key == exp.key {
			delete(row.updated_at)
			row.enabled = exp.enabled
			row.updated_at = strings.clone(exp.updated_at)
			return true, {}
		}
	}
	append(&r.rows, domain.Experiment{owner_user_id = strings.clone(exp.owner_user_id), key = strings.clone(exp.key), enabled = exp.enabled, updated_at = strings.clone(exp.updated_at)})
	return true, {}
}

@(private = "file")
toggle_exp_repo_destroy :: proc(r: ^Toggle_Exp_Repo) {
	for row in r.rows {
		delete(row.owner_user_id)
		delete(row.key)
		delete(row.updated_at)
	}
	delete(r.rows)
}

@(private = "file")
toggle_frozen_now :: proc(ctx: rawptr) -> string {
	return "2026-10-25T05:00:00Z"
}

@(private = "file")
toggle_revision :: proc(ctx: rawptr) -> (i64, domain.Domain_Error) {
	return 7, {}
}

@(private = "file")
toggle_put :: proc(t: ^testing.T, f: ^wire_fixture, h: ^Experiment_Rest_Handlers, enabled: bool) {
	body := `{"enabled":true}` if enabled else `{"enabled":false}`
	resp := experiment_set_handler(rawptr(h), wire_cookie_request(f, "PUT", "/api/v1/me/experiments/actions", body))
	testing.expect_value(t, resp.status, 200)
}

@(test)
test_actions_same_second_reenable_yields_fresh_epoch :: proc(t: ^testing.T) {
	f := wire_setup(t, "exp_toggle_epoch")
	defer wire_teardown(f)

	exp_fake: Toggle_Exp_Repo
	defer toggle_exp_repo_destroy(&exp_fake)
	exp_repo := iface.Experiment_Repository{ctx = rawptr(&exp_fake), list_by_owner = toggle_exp_list, set = toggle_exp_set}
	clock := platform.Clock{now = toggle_frozen_now}
	eh := Experiment_Rest_Handlers{auth = &f.auth_svc, repo = &exp_repo, clock = &clock}
	action_repo := iface.Action_Repository{revision = toggle_revision}
	ah := Action_Handlers{repo = &action_repo, experiments = &exp_repo}
	owner := string(f.owner)

	toggle_put(t, f, &eh, true)
	first_on, rev := action_schedules_owner_token(rawptr(&ah), &exp_repo, owner)
	testing.expect_value(t, rev, i64(7))
	testing.expect(t, strings.contains(first_on, ".on"))
	first_on = strings.clone(first_on)
	defer delete(first_on)

	toggle_put(t, f, &eh, false)
	off, _ := action_schedules_owner_token(rawptr(&ah), &exp_repo, owner)
	testing.expect(t, strings.has_suffix(off, ".off"))

	toggle_put(t, f, &eh, true)
	second_on, _ := action_schedules_owner_token(rawptr(&ah), &exp_repo, owner)
	testing.expect(t, strings.contains(second_on, ".on"))
	// The clock never moved, yet the re-enable must not reuse the first on-epoch.
	testing.expect(t, second_on != first_on)

	// Each write is stamped strictly after the previous one; eligible_since moves too.
	since, err := action_owner_eligibility(&exp_repo, owner)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, since, "2026-10-25T05:00:02Z")
}

@(test)
test_experiment_next_updated_at_is_strictly_monotonic :: proc(t: ^testing.T) {
	// Later clock: used as is.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:09Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:09Z")
	// Same second or clock behind the stored row: one second after the stored row.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:01Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T04:59:00Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:01Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T23:59:59Z", "2026-10-25T23:59:59Z"), "2026-10-26T00:00:00Z")
	// No previous row, or an unreadable one: the clock value.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", ""), "2026-10-25T05:00:00Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", "garbage"), "2026-10-25T05:00:00Z")
}
