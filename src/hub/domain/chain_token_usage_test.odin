package domain

import "core:testing"

// Two agents; the worker has two instances across several runs. Covers: counted
// totals + an uncounted live run, a snapshot that is the frozen final of an
// already-counted run (not added twice), a self-exited stopped run that is not
// counted yet (added, but no current %), an instance with no data, and the
// per-agent max context %.
@(test)
test_chain_token_usage_aggregates_agents_instances_and_runs :: proc(t: ^testing.T) {
	instances := []Agent_Instance{
		// Worker #1: 2 counted runs, live run 3 not counted yet (65 % of 200K).
		{agent_instance_id = "inst_w1", agent_id = "agt_worker", runtime_status = "running", kind = "agent",
		 token_usage_json = `{"tool_calls":3,"est_tokens_total":500,"context_tokens":130000,"context_window":200000,"output_tokens_total":900,"run_count":3,"compactions":0,"updated_at_ms":1}`,
		 has_token_totals = true, token_total_context_tokens = 300000, token_total_est_tool_tokens = 7000, token_total_output_tokens = 4000, token_runs_counted = 2, token_totals_last_run = 2},
		// Worker #2: stopped; its snapshot is run 4's final, which IS counted.
		{agent_instance_id = "inst_w2", agent_id = "agt_worker", runtime_status = "stopped", kind = "agent",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":100,"context_tokens":50000,"context_window":200000,"output_tokens_total":10,"run_count":4,"compactions":0,"updated_at_ms":1}`,
		 has_token_totals = true, token_total_context_tokens = 80000, token_total_est_tool_tokens = 300, token_total_output_tokens = 20, token_runs_counted = 1, token_totals_last_run = 4},
		// Worker #3: never reported anything.
		{agent_instance_id = "inst_w3", agent_id = "agt_worker", runtime_status = "idle", kind = "agent"},
		// Coordinator: a run that exited on its own (stopped, never counted).
		{agent_instance_id = "inst_c1", agent_id = "agt_coord", runtime_status = "stopped", kind = "agent",
		 token_usage_json = `{"tool_calls":2,"est_tokens_total":40,"context_tokens":20000,"context_window":200000,"run_count":1,"compactions":0,"updated_at_ms":1}`},
	}
	names := make(map[string]string, 2, context.temp_allocator)
	names["agt_worker"] = "Worker"
	names["agt_coord"] = "Coordinator"
	usage := chain_token_usage_aggregate(instances, names, context.temp_allocator)

	testing.expect(t, usage.has_data)
	testing.expect_value(t, usage.instances, 4)
	testing.expect_value(t, usage.instances_with_data, 3)
	testing.expect_value(t, len(usage.agents), 2)

	// Sorted by lifetime total: the worker first.
	w := usage.agents[0]
	testing.expect_value(t, w.agent_id, "agt_worker")
	testing.expect_value(t, w.agent_name, "Worker")
	testing.expect_value(t, len(w.instances), 3)
	testing.expect_value(t, w.live_instances, 2)
	// w1: 300000+130000 ctx, 7000+500 tool, 4000+900 out, 3 runs; w2: counted only.
	testing.expect_value(t, w.instances[0].lifetime, Chain_Token_Figures{context_tokens = 430000, est_tool_tokens = 7500, output_tokens = 4900, runs = 3})
	testing.expect(t, !w.instances[0].snapshot_counted)
	testing.expect_value(t, w.instances[1].lifetime, Chain_Token_Figures{context_tokens = 80000, est_tool_tokens = 300, output_tokens = 20, runs = 1})
	testing.expect(t, w.instances[1].snapshot_counted)
	testing.expect_value(t, w.instances[1].context_pct, -1) // stopped: no current %
	testing.expect(t, !w.instances[2].has_data)
	testing.expect_value(t, w.lifetime, Chain_Token_Figures{context_tokens = 510000, est_tool_tokens = 7800, output_tokens = 4920, runs = 4})
	testing.expect_value(t, w.context_pct, 65)
	testing.expect_value(t, w.context_window, 200000)
	testing.expect_value(t, w.context_instance_id, "inst_w1")

	c := usage.agents[1]
	testing.expect_value(t, c.agent_id, "agt_coord")
	testing.expect_value(t, c.lifetime, Chain_Token_Figures{context_tokens = 20000, est_tool_tokens = 40, runs = 1})
	testing.expect_value(t, c.context_pct, -1)

	testing.expect_value(t, usage.total, Chain_Token_Figures{context_tokens = 530000, est_tool_tokens = 7840, output_tokens = 4920, runs = 5})
	testing.expect_value(t, chain_token_figures_total(usage.total), 534920)
}

// Missing / partial data: no instances, instances without any token data,
// invalid snapshot JSON, a pre-T3r snapshot without run_count, and a live
// snapshot without a context figure yet.
@(test)
test_chain_token_usage_missing_and_partial_data :: proc(t: ^testing.T) {
	empty := chain_token_usage_aggregate(nil, nil, context.temp_allocator)
	testing.expect(t, !empty.has_data)
	testing.expect_value(t, len(empty.agents), 0)
	testing.expect_value(t, empty.total, Chain_Token_Figures{})

	no_data := chain_token_usage_aggregate([]Agent_Instance{
		{agent_instance_id = "inst_a", agent_id = "agt_a", runtime_status = "running"},
		{agent_instance_id = "inst_b", agent_id = "agt_a", runtime_status = "running", token_usage_json = `{"garbage":true}`},
	}, nil, context.temp_allocator)
	testing.expect(t, !no_data.has_data)
	testing.expect_value(t, len(no_data.agents), 1)
	testing.expect(t, !no_data.agents[0].has_data)
	testing.expect_value(t, no_data.agents[0].agent_name, "")
	testing.expect_value(t, no_data.agents[0].context_pct, -1)

	partial := chain_token_usage_aggregate([]Agent_Instance{
		// pre-T3r bridge (no run_count) next to stale counted totals: never "counted".
		{agent_instance_id = "inst_old", agent_id = "agt_a", runtime_status = "busy",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":10,"context_tokens":1000,"context_window":100000,"compactions":0,"updated_at_ms":1}`,
		 has_token_totals = true, token_total_context_tokens = 5, token_runs_counted = 1, token_totals_last_run = 1},
		// Live, no context reported yet: counted in tool tokens, no %.
		{agent_instance_id = "inst_new", agent_id = "agt_b", runtime_status = "running",
		 token_usage_json = `{"tool_calls":4,"est_tokens_total":80,"run_count":1,"compactions":0,"updated_at_ms":1}`},
		// Only counted totals (snapshot cleared / never stored).
		{agent_instance_id = "inst_tot", agent_id = "agt_b", runtime_status = "stopped",
		 has_token_totals = true, token_total_context_tokens = 70, token_total_est_tool_tokens = 7, token_total_output_tokens = 3, token_runs_counted = 1, token_totals_last_run = 1},
	}, nil, context.temp_allocator)
	testing.expect(t, partial.has_data)
	testing.expect_value(t, partial.instances_with_data, 3)
	a, b := partial.agents[0], partial.agents[1]
	if a.agent_id != "agt_a" do a, b = b, a
	testing.expect_value(t, a.lifetime, Chain_Token_Figures{context_tokens = 1005, est_tool_tokens = 10, runs = 2})
	testing.expect_value(t, a.context_pct, 1)
	testing.expect_value(t, b.lifetime, Chain_Token_Figures{context_tokens = 70, est_tool_tokens = 87, output_tokens = 3, runs = 2})
	testing.expect_value(t, b.context_pct, -1)
	testing.expect_value(t, b.live_instances, 1)
}

// Per-row thresholds: a stopped/historical 40/70 snapshot listed first must not
// leak onto a live 60/80 instance; the agent context carries the selected
// instance's own pair, and the summary prefers a live snapshot.
@(test)
test_chain_token_usage_per_row_thresholds :: proc(t: ^testing.T) {
	instances := []Agent_Instance{
		{agent_instance_id = "inst_old", agent_id = "agt_a", runtime_status = "stopped", kind = "agent",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":1,"context_tokens":150000,"context_window":200000,"warn_pct":40,"rollover_pct":70,"run_count":1,"compactions":0,"updated_at_ms":1}`},
		{agent_instance_id = "inst_live", agent_id = "agt_a", runtime_status = "running", kind = "agent",
		 token_usage_json = `{"tool_calls":1,"est_tokens_total":1,"context_tokens":150000,"context_window":200000,"warn_pct":60,"rollover_pct":80,"run_count":2,"compactions":0,"updated_at_ms":1}`},
	}
	usage := chain_token_usage_aggregate(instances, nil, context.temp_allocator)
	a := usage.agents[0]
	testing.expect_value(t, a.instances[0].snapshot.warn_pct, 40)
	testing.expect_value(t, a.instances[1].snapshot.warn_pct, 60)
	testing.expect_value(t, a.context_instance_id, "inst_live")
	testing.expect_value(t, a.context_warn_pct, 60)
	testing.expect_value(t, a.context_rollover_pct, 80)
	testing.expect_value(t, usage.warn_pct, 60)
	testing.expect_value(t, usage.rollover_pct, 80)
}

// An estimate-only live instance (Antigravity: metrics, no usage block) drives
// the "now" context with effective tokens and estimate provenance; the raw
// provider lifetime accounting stays untouched.
@(test)
test_chain_token_usage_estimate_context :: proc(t: ^testing.T) {
	usage := chain_token_usage_aggregate([]Agent_Instance{
		{agent_instance_id = "inst_est", agent_id = "agt_a", runtime_status = "running",
		 token_usage_json = `{"tool_calls":5,"est_tokens_total":100000,"context_source":"estimate","estimated_context_tokens":150000,"context_window":200000,"run_count":1,"compactions":0,"updated_at_ms":1}`},
	}, nil, context.temp_allocator)
	a := usage.agents[0]
	row := a.instances[0]
	testing.expect_value(t, row.context_pct, 75)
	testing.expect_value(t, row.context_tokens, 150000)
	testing.expect(t, row.context_estimate)
	testing.expect_value(t, a.context_pct, 75)
	testing.expect_value(t, a.context_tokens, 150000)
	testing.expect(t, a.context_estimate)
	// Lifetime context is provider-only: the estimate is not added.
	testing.expect_value(t, a.lifetime.context_tokens, 0)
	testing.expect_value(t, a.lifetime.est_tool_tokens, 100000)
}
