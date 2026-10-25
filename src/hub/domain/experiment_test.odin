package domain

import "core:encoding/json"
import "core:testing"

// REQ-EXP-GATE-1: Actions and Project/VCS are opt-in; only streaming panes default on.
@(test)
test_actions_and_project_vcs_experiments_default_off :: proc(t: ^testing.T) {
	testing.expect_value(t, ACTIONS_EXPERIMENT_KEY, "actions")
	testing.expect_value(t, PROJECT_VCS_EXPERIMENT_KEY, "project_vcs")
	testing.expect(t, !experiment_default_enabled(ACTIONS_EXPERIMENT_KEY))
	testing.expect(t, !experiment_default_enabled(PROJECT_VCS_EXPERIMENT_KEY))
	testing.expect(t, experiment_default_enabled(STREAMING_TERMINAL_PANE_EXPERIMENT_KEY))
}

@(test)
test_experiment_enabled_in_stored_row_wins_over_default :: proc(t: ^testing.T) {
	testing.expect(t, !experiment_enabled_in({}, ACTIONS_EXPERIMENT_KEY), "absent is off")
	testing.expect(t, experiment_enabled_in({}, STREAMING_TERMINAL_PANE_EXPERIMENT_KEY), "absent default-on is on")

	rows := []Experiment{
		{key = PROJECT_VCS_EXPERIMENT_KEY, enabled = true},
		{key = ACTIONS_EXPERIMENT_KEY, enabled = false},
		{key = STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = false},
	}
	testing.expect(t, experiment_enabled_in(rows, PROJECT_VCS_EXPERIMENT_KEY), "existing project_vcs opt-in stays valid")
	testing.expect(t, !experiment_enabled_in(rows, ACTIONS_EXPERIMENT_KEY), "explicit off")
	testing.expect(t, !experiment_enabled_in(rows, STREAMING_TERMINAL_PANE_EXPERIMENT_KEY), "explicit off beats default-on")

	other_only := []Experiment{{key = "lsp", enabled = true}}
	testing.expect(t, !experiment_enabled_in(other_only, ACTIONS_EXPERIMENT_KEY), "an unrelated flag does not enable actions")
}

// REQ-EXP-GATE-3: forbidden envelope, exact message and machine-readable details.
@(test)
test_experimental_feature_disabled_error_shape :: proc(t: ^testing.T) {
	Details :: struct {code: string, feature: string}

	actions := experimental_feature_disabled_error(ACTIONS_EXPERIMENT_KEY)
	testing.expect_value(t, actions.code, Error_Code.Forbidden)
	testing.expect_value(t, error_code_string(actions.code), "forbidden")
	testing.expect_value(t, actions.message, "Actions is experimental. Enable it in Settings > Experimental to use it.")
	d: Details
	testing.expect(t, json.unmarshal_string(actions.details_json, &d, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, d.code, "experimental_feature_disabled")
	testing.expect_value(t, d.feature, "actions")

	explorer := experimental_feature_disabled_error(PROJECT_VCS_EXPERIMENT_KEY)
	testing.expect_value(t, explorer.message, "Project Explorer is experimental. Enable it in Settings > Experimental to use it.")
	e: Details
	testing.expect(t, json.unmarshal_string(explorer.details_json, &e, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, e.feature, "project_vcs")

	// An unknown key is still valid JSON in details.
	odd := experimental_feature_disabled_error(`we"ird`)
	o: Details
	testing.expect(t, json.unmarshal_string(odd.details_json, &o, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, o.feature, `we"ird`)
}
