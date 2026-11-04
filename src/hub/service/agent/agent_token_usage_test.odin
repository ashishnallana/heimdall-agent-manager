package agent

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// apply_bridge_token_usage (T3r): canonical snapshot write, final -> totals,
// invalid members ignored. The SQLite de-dup itself is covered in
// repository/sqlite/agent_token_usage_repo_test.odin.

@(private = "file")
Tok_Fake :: struct {
	snapshots: [dynamic]string,
	finals:    [dynamic][5]i64, // run, ctx, est, out, 0
	last_run:  int,
}

@(private = "file")
tok_fake_update :: proc(ctx: rawptr, instance_id, bridge_id, usage_json, updated_at: string) -> (bool, domain.Domain_Error) {
	f := (^Tok_Fake)(ctx)
	append(&f.snapshots, strings.clone(usage_json, context.temp_allocator))
	return true, {}
}

@(private = "file")
tok_fake_add :: proc(ctx: rawptr, instance_id, bridge_id: string, run_count: int, c, e, o: i64) -> (bool, domain.Domain_Error) {
	f := (^Tok_Fake)(ctx)
	if run_count <= f.last_run do return false, {}
	f.last_run = run_count
	append(&f.finals, [5]i64{i64(run_count), c, e, o, 0})
	return true, {}
}

@(test)
test_apply_bridge_token_usage_snapshot_and_final :: proc(t: ^testing.T) {
	fake: Tok_Fake
	fake.snapshots = make([dynamic]string, context.temp_allocator)
	fake.finals = make([dynamic][5]i64, context.temp_allocator)
	repo := iface.Agent_Repository{ctx = &fake, update_token_usage = tok_fake_update, add_token_totals = tok_fake_add}
	svc := Agent_Service{agents = &repo}

	live := `{"tool_calls":2,"est_tokens_total":40,"context_window":200000,"window_source":"default","run_count":4,"compactions":0,"updated_at_ms":9}`
	final := `{"tool_calls":9,"est_tokens_total":700,"context_tokens":160000,"context_window":200000,"window_source":"config","output_tokens_total":321,"run_count":3,"compactions":0,"updated_at_ms":8}`
	res, err := apply_bridge_token_usage(&svc, "brg", "inst", live, final)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, res.snapshot_saved && res.totals_added)
	testing.expect_value(t, len(fake.snapshots), 1)
	testing.expect_value(t, fake.snapshots[0], live)
	testing.expect_value(t, fake.finals[0], [5]i64{3, 160000, 700, 321, 0})

	// The same final on the next frame (stop retry / replay) is not re-added.
	res, _ = apply_bridge_token_usage(&svc, "brg", "inst", "", final)
	testing.expect(t, !res.snapshot_saved && !res.totals_added)
	testing.expect_value(t, len(fake.finals), 1)

	// A final without a run (older bridge) or an invalid object is ignored.
	res, _ = apply_bridge_token_usage(&svc, "brg", "inst", `{"tool_calls":"x"}`, `{"tool_calls":1,"est_tokens_total":1}`)
	testing.expect(t, !res.snapshot_saved && !res.totals_added)
	// A final with no context/output reported counts zero for those.
	res, _ = apply_bridge_token_usage(&svc, "brg", "inst", "", `{"tool_calls":1,"est_tokens_total":5,"run_count":4}`)
	testing.expect(t, res.totals_added)
	testing.expect_value(t, fake.finals[1], [5]i64{4, 0, 5, 0, 0})
}
