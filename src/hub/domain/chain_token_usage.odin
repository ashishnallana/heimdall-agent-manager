package domain

// Per-chain token usage (chain "Estimate agent tokens via extensions", T10).
// Aggregates the T3r per-instance token data of every agent instance seated on
// a task chain into one row per durable agent (agent_id), with that agent's
// instances underneath, plus a chain total. Pure: callers pass the instances
// (agent_list_instances_by_chain) and the agent display names.
//
// Lifetime figures of one instance are its counted totals (token_total_*, one
// finished run added at each hub stop/restart) PLUS the latest snapshot when
// that snapshot's run is not counted yet (the live run, or a run that exited on
// its own and has not been restarted). A snapshot whose run_count is already
// <= token_totals_last_run is the frozen final of a counted run, so adding it
// again would double count it.

import "core:slice"
import "core:strings"

Chain_Token_Figures :: struct {
	context_tokens:  i64, // sum over runs of each run's (last) context size
	est_tool_tokens: i64,
	output_tokens:   i64,
	runs:            int, // counted runs + the uncounted latest run, if any
}

// chain_token_figures_total is the single "tokens used" number the UI and CLI
// show: context (sum of runs) + output.
chain_token_figures_total :: proc(f: Chain_Token_Figures) -> i64 {
	return f.context_tokens + f.output_tokens
}

chain_token_figures_add :: proc(dst: ^Chain_Token_Figures, src: Chain_Token_Figures) {
	dst.context_tokens += src.context_tokens
	dst.est_tool_tokens += src.est_tool_tokens
	dst.output_tokens += src.output_tokens
	dst.runs += src.runs
}

Chain_Token_Instance :: struct {
	// Borrowed from the source Agent_Instance (not owned).
	agent_instance_id: string,
	agent_id:          string,
	display_name:      string,
	provider:          string,
	runtime_status:    string,
	live:              bool, // runtime is active (see agent_runtime_status_live)
	has_data:          bool, // a snapshot or counted totals exist
	has_snapshot:      bool,
	snapshot:          Agent_Token_Usage,
	// snapshot_counted: the snapshot's run is already in the counted totals.
	snapshot_counted:  bool,
	has_counted:       bool,
	counted:           Chain_Token_Figures,
	lifetime:          Chain_Token_Figures,
	// context_pct: current % of window, -1 unless live with a known context.
	context_pct:       i64,
	// Tokens behind context_pct (provider figure, else the bridge estimate) and
	// whether that figure is an estimate.
	context_tokens:    i64,
	context_estimate:  bool,
}

Chain_Token_Agent :: struct {
	agent_id:       string,
	agent_name:     string, // borrowed; "" when unknown
	instances:      [dynamic]Chain_Token_Instance,
	has_data:       bool,
	lifetime:       Chain_Token_Figures,
	live_instances: int,
	// Highest current context % among the agent's live instances (-1 = none),
	// and the instance/window it belongs to.
	context_pct:          i64,
	context_tokens:       i64,
	context_estimate:     bool,
	context_window:       i64,
	context_instance_id:  string,
	// Thresholds of the snapshot that supplied context_* (0 = absent -> fallback).
	context_warn_pct:     int,
	context_rollover_pct: int,
}

Chain_Token_Usage :: struct {
	agents:              [dynamic]Chain_Token_Agent,
	total:               Chain_Token_Figures,
	has_data:            bool,
	instances:           int,
	instances_with_data: int,
	warn_pct:            int, // summary only: first LIVE snapshot reporting them, else first any; per-row values are authoritative; 0 = none
	rollover_pct:        int,
}

// agent_runtime_status_live mirrors the active runtime list of
// agent_list_active_runtime_instances: a current context % is only meaningful
// for an instance whose process is (or is about to be) running.
agent_runtime_status_live :: proc(status: string) -> bool {
	switch status {
	case "launching", "starting", "running", "idle", "busy", "blocked", "stopping":
		return true
	}
	return false
}

// chain_token_instance_from computes one instance's row. Invalid snapshot JSON
// is treated as no snapshot.
chain_token_instance_from :: proc(inst: Agent_Instance) -> Chain_Token_Instance {
	row := Chain_Token_Instance{
		agent_instance_id = inst.agent_instance_id,
		agent_id = inst.agent_id,
		display_name = inst.display_name,
		provider = inst.provider,
		runtime_status = inst.runtime_status,
		live = agent_runtime_status_live(inst.runtime_status),
		context_pct = -1,
	}
	if inst.has_token_totals {
		row.has_counted = true
		row.counted = Chain_Token_Figures{
			context_tokens = inst.token_total_context_tokens,
			est_tool_tokens = inst.token_total_est_tool_tokens,
			output_tokens = inst.token_total_output_tokens,
			runs = inst.token_runs_counted,
		}
	}
	row.lifetime = row.counted
	if inst.token_usage_json != "" {
		if u, ok := agent_token_usage_from_json(inst.token_usage_json); ok {
			row.has_snapshot = true
			row.snapshot = u
			// run_count 0 = generation unknown (pre-T3r bridge): such a run is
			// never counted by the hub, so it is always uncounted here.
			row.snapshot_counted = u.run_count > 0 && inst.has_token_totals && u.run_count <= inst.token_totals_last_run
			if !row.snapshot_counted {
				live_run := Chain_Token_Figures{est_tool_tokens = u.est_tokens_total, runs = 1}
				if u.has_context do live_run.context_tokens = u.context_tokens
				if u.has_output_total do live_run.output_tokens = u.output_tokens_total
				chain_token_figures_add(&row.lifetime, live_run)
			}
			if row.live {
				row.context_pct = agent_token_usage_context_pct(u)
				row.context_tokens, row.context_estimate, _ = agent_token_usage_effective_context(u)
			}
		}
	}
	row.has_data = row.has_snapshot || row.has_counted
	return row
}

// chain_token_usage_aggregate groups instances by agent_id. agent_names maps
// agent_id -> display name (may be nil). Agents are ordered by lifetime total
// (desc), then agent_id; instances keep the input order. Kind-"agent" rows are
// expected (tool instances carry no token data and are skipped when given).
// Everything is allocated with allocator; strings are borrowed from the inputs.
chain_token_usage_aggregate :: proc(instances: []Agent_Instance, agent_names: map[string]string, allocator := context.allocator) -> Chain_Token_Usage {
	out := Chain_Token_Usage{agents = make([dynamic]Chain_Token_Agent, allocator)}
	index := make(map[string]int, 8, context.temp_allocator)
	summary_live := false
	for inst in instances {
		if inst.kind != "" && inst.kind != "agent" do continue
		row := chain_token_instance_from(inst)
		slot, seen := index[inst.agent_id]
		if !seen {
			slot = len(out.agents)
			index[inst.agent_id] = slot
			name := ""
			if agent_names != nil do name = agent_names[inst.agent_id]
			append(&out.agents, Chain_Token_Agent{agent_id = inst.agent_id, agent_name = name, instances = make([dynamic]Chain_Token_Instance, allocator), context_pct = -1})
		}
		agent := &out.agents[slot]
		append(&agent.instances, row)
		out.instances += 1
		if row.live do agent.live_instances += 1
		if !row.has_data do continue
		if row.has_snapshot && row.snapshot.warn_pct > 0 && row.snapshot.rollover_pct > 0 {
			if row.live && !summary_live {
				out.warn_pct, out.rollover_pct, summary_live = row.snapshot.warn_pct, row.snapshot.rollover_pct, true
			} else if out.warn_pct == 0 {
				out.warn_pct, out.rollover_pct = row.snapshot.warn_pct, row.snapshot.rollover_pct
			}
		}
		agent.has_data = true
		out.has_data = true
		out.instances_with_data += 1
		chain_token_figures_add(&agent.lifetime, row.lifetime)
		chain_token_figures_add(&out.total, row.lifetime)
		if row.context_pct > agent.context_pct {
			agent.context_pct = row.context_pct
			agent.context_tokens = row.context_tokens
			agent.context_estimate = row.context_estimate
			agent.context_window = row.snapshot.context_window
			agent.context_instance_id = row.agent_instance_id
			agent.context_warn_pct = row.snapshot.warn_pct
			agent.context_rollover_pct = row.snapshot.rollover_pct
		}
	}
	slice.sort_by(out.agents[:], proc(a, b: Chain_Token_Agent) -> bool {
		ta, tb := chain_token_figures_total(a.lifetime), chain_token_figures_total(b.lifetime)
		if ta != tb do return ta > tb
		return strings.compare(a.agent_id, b.agent_id) < 0
	})
	return out
}
