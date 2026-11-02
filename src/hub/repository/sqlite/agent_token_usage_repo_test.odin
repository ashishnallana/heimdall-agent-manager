package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// T3r: latest token snapshot + lifetime totals on agent_instances (migration 189).

@(private = "file")
tok_repo_setup :: proc(t: ^testing.T, conn: ^Conn, impl: ^Agent_Repo_SQLite) -> (iface.Agent_Repository, bool) {
	opened, ok := tmpl_clone_migrated(t)
	conn^ = opened
	if !ok do return {}, false
	repo := new_agent_repository(impl, conn)
	_, stored, err := iface.agent_save_instance(&repo, domain.Agent_Instance{agent_instance_id = "inst_tok", owner_user_id = "owner", agent_id = "agent", bridge_id = "brg_tok", provider = "claude", model = "opus", runtime_status = "running", run_count = 2, created_at = "2026-11-02T10:00:00Z", updated_at = "2026-11-02T10:00:00Z"})
	testing.expect(t, stored, err.message)
	return repo, stored
}

@(private = "file")
tok_repo_get :: proc(t: ^testing.T, repo: ^iface.Agent_Repository) -> domain.Agent_Instance {
	inst, found, err := iface.agent_get_instance(repo, "inst_tok")
	testing.expect(t, found, err.message)
	return inst
}

@(test)
test_token_usage_snapshot_persist_absent_and_bridge_scoped :: proc(t: ^testing.T) {
	conn: Conn; impl: Agent_Repo_SQLite
	repo, ok := tok_repo_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return

	inst := tok_repo_get(t, &repo)
	testing.expect_value(t, inst.token_usage_json, "")
	testing.expect(t, !inst.has_token_totals, "no totals before any run is counted")
	domain.agent_instance_destroy(&inst)

	snap := `{"tool_calls":3,"est_tokens_total":900,"context_tokens":50000,"context_window":200000,"window_source":"config","context_pct":25,"run_count":2,"compactions":0,"updated_at_ms":1}`
	saved, err := iface.agent_update_token_usage(&repo, "inst_tok", "brg_other", snap, "2026-11-02T10:01:00Z")
	testing.expect(t, !saved && err.code == .None, "another bridge cannot write the snapshot")
	saved, err = iface.agent_update_token_usage(&repo, "inst_tok", "brg_tok", snap, "2026-11-02T10:01:00Z")
	testing.expect(t, saved, err.message)
	saved, _ = iface.agent_update_token_usage(&repo, "inst_tok", "brg_tok", snap, "2026-11-02T10:02:00Z")
	testing.expect(t, !saved, "an unchanged snapshot is not rewritten")

	inst = tok_repo_get(t, &repo)
	testing.expect_value(t, inst.token_usage_json, snap)
	testing.expect_value(t, inst.token_usage_updated_at, "2026-11-02T10:01:00Z")
	// A normal instance save never clobbers the token columns.
	delete(inst.runtime_status); inst.runtime_status = strings.clone("idle")
	_, stored, serr := iface.agent_save_instance(&repo, inst)
	testing.expect(t, stored, serr.message)
	domain.agent_instance_destroy(&inst)
	inst = tok_repo_get(t, &repo)
	testing.expect_value(t, inst.token_usage_json, snap)
	testing.expect_value(t, inst.runtime_status, "idle")
	domain.agent_instance_destroy(&inst)
}

@(test)
test_token_totals_added_once_per_run :: proc(t: ^testing.T) {
	conn: Conn; impl: Agent_Repo_SQLite
	repo, ok := tok_repo_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return

	added, err := iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 1, 120_000, 3_000, 800)
	testing.expect(t, added, err.message)
	// The bridge repeats the final on later frames / a stop retry: no double count.
	added, _ = iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 1, 120_000, 3_000, 800)
	testing.expect(t, !added, "a retried final for a counted run is a no-op")
	added, _ = iface.agent_add_token_totals(&repo, "inst_tok", "brg_other", 2, 1, 1, 1)
	testing.expect(t, !added, "another bridge cannot add totals")
	added, _ = iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 3, 1, 1, 1)
	testing.expect(t, !added, "a run beyond the instance's run_count is refused")
	added, _ = iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 0, 1, 1, 1)
	testing.expect(t, !added, "run 0 (unknown generation) is never counted")

	inst := tok_repo_get(t, &repo)
	testing.expect(t, inst.has_token_totals)
	testing.expect_value(t, inst.token_runs_counted, 1)
	testing.expect_value(t, inst.token_totals_last_run, 1)
	domain.agent_instance_destroy(&inst)

	added, err = iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 2, 30_000, 500, 200)
	testing.expect(t, added, err.message)
	added, _ = iface.agent_add_token_totals(&repo, "inst_tok", "brg_tok", 1, 999, 999, 999)
	testing.expect(t, !added, "an older run arriving late is a no-op")

	inst = tok_repo_get(t, &repo)
	testing.expect_value(t, inst.token_total_context_tokens, 150_000)
	testing.expect_value(t, inst.token_total_est_tool_tokens, 3_500)
	testing.expect_value(t, inst.token_total_output_tokens, 1_000)
	testing.expect_value(t, inst.token_runs_counted, 2)
	testing.expect_value(t, inst.token_totals_last_run, 2)
	totals := domain.agent_token_totals_json(inst, context.temp_allocator)
	testing.expect_value(t, totals, `{"total_context_tokens":150000,"total_est_tool_tokens":3500,"total_output_tokens":1000,"runs_counted":2,"last_run_counted":2}`)
	domain.agent_instance_destroy(&inst)
}
