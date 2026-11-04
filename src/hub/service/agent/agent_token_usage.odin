package agent

// Per-instance token usage from bridge status frames (T3r). The latest
// snapshot replaces the stored one; a finished run's final usage is added to
// the lifetime totals once per run (the repository's conditional UPDATE is the
// de-dup guard, keyed by run_count). No history is kept (migration 125 intent).

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

Token_Usage_Apply_Result :: struct {
	snapshot_saved: bool,
	totals_added:   bool,
}

// apply_bridge_token_usage handles the token members of one
// agent_instance_status frame from bridge_id. usage_raw / final_raw are the raw
// token_usage / token_usage_final objects ("" when absent). Invalid objects are
// ignored. Both writes are scoped to instances pinned to bridge_id.
apply_bridge_token_usage :: proc(service: ^Agent_Service, bridge_id, instance_id, usage_raw, final_raw: string) -> (res: Token_Usage_Apply_Result, err: domain.Domain_Error) {
	if service == nil || service.agents == nil || bridge_id == "" || instance_id == "" do return
	if usage_raw != "" {
		if u, ok := domain.agent_token_usage_from_json(usage_raw); ok {
			canonical := domain.agent_token_usage_json(u, context.temp_allocator)
			now := platform.clock_now(service.clock)
			res.snapshot_saved, err = iface.agent_update_token_usage(service.agents, instance_id, bridge_id, canonical, now)
			if err.code != .None do return
		}
	}
	if final_raw != "" {
		if f, ok := domain.agent_token_usage_from_json(final_raw); ok && f.run_count > 0 {
			ctx := f.context_tokens if f.has_context else 0
			out := f.output_tokens_total if f.has_output_total else 0
			res.totals_added, err = iface.agent_add_token_totals(service.agents, instance_id, bridge_id, f.run_count, ctx, f.est_tokens_total, out)
		}
	}
	return
}
