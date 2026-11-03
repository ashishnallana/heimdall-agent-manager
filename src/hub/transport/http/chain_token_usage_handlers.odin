package http

// GET /api/v1/task-chains/{id}/token-usage (T10): per-agent and chain-total
// token usage of a task chain, aggregated from the T3r per-instance snapshot +
// lifetime totals (domain/chain_token_usage.odin). Read scope is the chain's
// (owner-scoped, same as the chain detail). Nothing is stored.
//
// Response data:
//   {chain_id, has_data, instances, instances_with_data, warn_pct, rollover_pct,
//    total: Figures,
//    agents: [{agent_id, agent_name, has_data, live_instances, lifetime: Figures,
//              context?: {pct, tokens, window, agent_instance_id},
//              instances: [{agent_instance_id, display_name, runtime_status, live,
//                           has_data, snapshot_counted, lifetime: Figures,
//                           counted?: Figures, run_count?, context_pct?,
//                           context_tokens?, context_window?, window_source?}]}]}
//   Figures = {total_tokens, context_tokens, est_tool_tokens, output_tokens, runs}
//   total_tokens = context_tokens (sum of each run's context) + output_tokens.

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"

task_chain_token_usage_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	// READ (REQ-SEC-3): owner-scoped, a same-owner non-member may view it.
	chain, got, err := taskchain_service.get_chain_for_read(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	if h.agents == nil || h.agents.agents == nil do return respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id)

	// Everything below is request-scoped.
	context.allocator = context.temp_allocator
	instances, list_err := iface.agent_list_instances_by_chain(h.agents.agents, chain.owner_user_id, string(chain.chain_id))
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	names := make(map[string]string, 8)
	for inst in instances {
		if inst.agent_id == "" do continue
		if _, seen := names[inst.agent_id]; seen do continue
		names[inst.agent_id] = ""
		if agent, agent_ok, _ := iface.agent_get(h.agents.agents, inst.agent_id); agent_ok && agent.owner_user_id == chain.owner_user_id {
			names[inst.agent_id] = agent.name
		}
	}
	usage := domain.chain_token_usage_aggregate(instances, names)
	b := strings.builder_make()
	write_chain_token_usage_json(&b, string(chain.chain_id), usage)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_chain_token_figures_json :: proc(b: ^strings.Builder, f: domain.Chain_Token_Figures) {
	strings.write_string(b, fmt.tprintf("{{\"total_tokens\":%d,\"context_tokens\":%d,\"est_tool_tokens\":%d,\"output_tokens\":%d,\"runs\":%d}}",
		domain.chain_token_figures_total(f), f.context_tokens, f.est_tool_tokens, f.output_tokens, f.runs))
}

@(private = "file")
write_json_str_field :: proc(b: ^strings.Builder, key, value: string, first := false) {
	if !first do strings.write_byte(b, ',')
	strings.write_byte(b, '"'); strings.write_string(b, key); strings.write_string(b, "\":\"")
	write_handler_json_string(b, value)
	strings.write_byte(b, '"')
}

write_chain_token_usage_json :: proc(b: ^strings.Builder, chain_id: string, usage: domain.Chain_Token_Usage) {
	strings.write_byte(b, '{')
	write_json_str_field(b, "chain_id", chain_id, true)
	strings.write_string(b, fmt.tprintf(",\"has_data\":%v,\"instances\":%d,\"instances_with_data\":%d,\"warn_pct\":%d,\"rollover_pct\":%d,\"total\":",
		usage.has_data, usage.instances, usage.instances_with_data,
		usage.warn_pct if usage.warn_pct > 0 else domain.AGENT_TOKEN_WARN_PCT,
		usage.rollover_pct if usage.rollover_pct > 0 else domain.AGENT_TOKEN_ROLLOVER_PCT))
	write_chain_token_figures_json(b, usage.total)
	strings.write_string(b, ",\"agents\":[")
	for agent, i in usage.agents {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '{')
		write_json_str_field(b, "agent_id", agent.agent_id, true)
		write_json_str_field(b, "agent_name", agent.agent_name)
		strings.write_string(b, fmt.tprintf(",\"has_data\":%v,\"live_instances\":%d,\"lifetime\":", agent.has_data, agent.live_instances))
		write_chain_token_figures_json(b, agent.lifetime)
		if agent.context_pct >= 0 {
			strings.write_string(b, fmt.tprintf(",\"context\":{{\"pct\":%d,\"tokens\":%d,\"window\":%d", agent.context_pct, agent.context_tokens, agent.context_window))
			if agent.context_estimate do write_json_str_field(b, "context_source", domain.AGENT_TOKEN_ESTIMATE_SOURCE)
			write_json_str_field(b, "agent_instance_id", agent.context_instance_id)
			if agent.context_warn_pct > 0 && agent.context_rollover_pct > 0 {
				strings.write_string(b, fmt.tprintf(",\"warn_pct\":%d,\"rollover_pct\":%d", agent.context_warn_pct, agent.context_rollover_pct))
			}
			strings.write_byte(b, '}')
		}
		strings.write_string(b, ",\"instances\":[")
		for row, j in agent.instances {
			if j > 0 do strings.write_byte(b, ',')
			write_chain_token_instance_json(b, row)
		}
		strings.write_string(b, "]}")
	}
	strings.write_string(b, "]}")
}

write_chain_token_instance_json :: proc(b: ^strings.Builder, row: domain.Chain_Token_Instance) {
	strings.write_byte(b, '{')
	write_json_str_field(b, "agent_instance_id", row.agent_instance_id, true)
	write_json_str_field(b, "display_name", row.display_name)
	if row.provider != "" do write_json_str_field(b, "provider", row.provider)
	write_json_str_field(b, "runtime_status", row.runtime_status)
	strings.write_string(b, fmt.tprintf(",\"live\":%v,\"has_data\":%v,\"snapshot_counted\":%v,\"lifetime\":", row.live, row.has_data, row.snapshot_counted))
	write_chain_token_figures_json(b, row.lifetime)
	if row.has_counted {
		strings.write_string(b, ",\"counted\":")
		write_chain_token_figures_json(b, row.counted)
	}
	if row.has_snapshot {
		s := row.snapshot
		if s.has_usage_supported do strings.write_string(b, fmt.tprintf(",\"usage_supported\":%v", s.usage_supported))
		if s.run_count > 0 do strings.write_string(b, fmt.tprintf(",\"run_count\":%d", s.run_count))
		if row.context_pct >= 0 do strings.write_string(b, fmt.tprintf(",\"context_pct\":%d", row.context_pct))
		if s.has_context do strings.write_string(b, fmt.tprintf(",\"context_tokens\":%d", s.context_tokens))
		if row.context_estimate {
			write_json_str_field(b, "context_source", domain.AGENT_TOKEN_ESTIMATE_SOURCE)
			strings.write_string(b, fmt.tprintf(",\"estimated_context_tokens\":%d", row.context_tokens))
		}
		if s.context_window > 0 do strings.write_string(b, fmt.tprintf(",\"context_window\":%d", s.context_window))
		if s.window_source != "" do write_json_str_field(b, "window_source", s.window_source)
		if s.warn_pct > 0 && s.rollover_pct > 0 do strings.write_string(b, fmt.tprintf(",\"warn_pct\":%d,\"rollover_pct\":%d", s.warn_pct, s.rollover_pct))
	}
	strings.write_byte(b, '}')
}
