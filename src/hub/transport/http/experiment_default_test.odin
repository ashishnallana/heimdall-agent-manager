package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
Default_Exp_Repo :: struct {
	rows: []domain.Experiment,
}

@(private = "file")
default_exp_list :: proc(ctx: rawptr, owner_user_id: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Default_Exp_Repo)(ctx)
	out := make([dynamic]domain.Experiment)
	for row in r.rows {
		append(&out, domain.Experiment{owner_user_id = strings.clone(owner_user_id), key = strings.clone(row.key), enabled = row.enabled, updated_at = strings.clone("2026-10-16T00:00:00Z")})
	}
	return out, domain.Domain_Error{}
}

// Streaming terminal panes are on for a user who never set the flag; a stored "off"
// is still respected, and other experiments stay off until enabled.
@(test)
test_streaming_terminal_pane_is_default_on :: proc(t: ^testing.T) {
	testing.expect(t, domain.experiment_default_enabled(domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY))
	testing.expect(t, !domain.experiment_default_enabled(domain.PROJECT_VCS_EXPERIMENT_KEY))
	testing.expect(t, !domain.experiment_default_enabled("lsp"))

	never_set := Default_Exp_Repo{rows = {{key = "lsp", enabled = true}}}
	repo := iface.Experiment_Repository{ctx = rawptr(&never_set), list_by_owner = default_exp_list}
	testing.expect(t, shell_stream_experiment_enabled(&repo, "user_a"), "no stored row: streaming is on")

	turned_off := Default_Exp_Repo{rows = {{key = domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = false}}}
	repo_off := iface.Experiment_Repository{ctx = rawptr(&turned_off), list_by_owner = default_exp_list}
	testing.expect(t, !shell_stream_experiment_enabled(&repo_off, "user_a"), "an explicit off is respected")
}

@(test)
test_experiment_list_includes_unset_default_on_flags :: proc(t: ^testing.T) {
	empty := experiment_list_json({})
	defer delete(empty)
	testing.expect_value(t, empty, `{"ok":true,"experiments":[{"key":"streaming_terminal_pane","enabled":true,"updated_at":""}]}`)

	stored := []domain.Experiment{{key = "lsp", enabled = true, updated_at = "t1"}}
	with_other := experiment_list_json(stored)
	defer delete(with_other)
	testing.expect_value(t, with_other, `{"ok":true,"experiments":[{"key":"lsp","enabled":true,"updated_at":"t1"},{"key":"streaming_terminal_pane","enabled":true,"updated_at":""}]}`)

	off := []domain.Experiment{{key = domain.STREAMING_TERMINAL_PANE_EXPERIMENT_KEY, enabled = false, updated_at = "t2"}}
	explicit := experiment_list_json(off)
	defer delete(explicit)
	testing.expect_value(t, explicit, `{"ok":true,"experiments":[{"key":"streaming_terminal_pane","enabled":false,"updated_at":"t2"}]}`)
}
