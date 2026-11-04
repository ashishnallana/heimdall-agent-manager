package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// T3r: the agent instance API carries token_usage / token_totals only when present.
@(test)
test_agent_instance_json_token_usage_and_totals :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	write_agent_instance_json(&b, domain.Agent_Instance{agent_instance_id = "inst_a", runtime_status = "running"})
	plain := strings.to_string(b)
	testing.expect(t, !strings.contains(plain, "token_usage") && !strings.contains(plain, "token_totals"), "absent data is omitted")

	inst := domain.Agent_Instance{
		agent_instance_id = "inst_a", runtime_status = "running",
		token_usage_json = `{"tool_calls":2,"est_tokens_total":40,"context_tokens":130000,"context_window":200000,"window_source":"config","context_pct":65,"run_count":3,"compactions":0,"updated_at_ms":9}`,
		token_usage_updated_at = "2026-11-02T10:00:00Z",
		has_token_totals = true, token_total_context_tokens = 300000, token_total_est_tool_tokens = 9000, token_total_output_tokens = 1200, token_runs_counted = 2, token_totals_last_run = 2,
	}
	b2 := strings.builder_make(context.temp_allocator)
	write_agent_instance_json(&b2, inst)
	v, err := json.parse_string(strings.to_string(b2), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := v.(json.Object)
	tu := root["token_usage"].(json.Object)
	testing.expect_value(t, tu["context_pct"].(json.Integer), 65)
	testing.expect_value(t, tu["context_window"].(json.Integer), 200000)
	testing.expect_value(t, tu["window_source"].(json.String), "config")
	testing.expect_value(t, root["token_usage_updated_at"].(json.String), "2026-11-02T10:00:00Z")
	tt := root["token_totals"].(json.Object)
	testing.expect_value(t, tt["total_context_tokens"].(json.Integer), 300000)
	testing.expect_value(t, tt["total_est_tool_tokens"].(json.Integer), 9000)
	testing.expect_value(t, tt["total_output_tokens"].(json.Integer), 1200)
	testing.expect_value(t, tt["runs_counted"].(json.Integer), 2)
}
