package domain

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_agent_token_usage_canonicalizes_and_validates :: proc(t: ^testing.T) {
	u, ok := agent_token_usage_from_json(`{"tool_calls":4,"est_tokens_total":1200,"context_tokens":130000,"context_source":"claude_transcript","context_window":200000,"window_source":"override","context_pct":99,"output_tokens_total":70,"compactions":1,"run_count":3,"updated_at_ms":1700,"extra":"ignored"}`)
	testing.expect(t, ok)
	// context_pct is recomputed (65), context_source and unknown members dropped.
	testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), `{"tool_calls":4,"est_tokens_total":1200,"context_tokens":130000,"context_window":200000,"window_source":"override","context_pct":65,"output_tokens_total":70,"run_count":3,"compactions":1,"updated_at_ms":1700}`)

	// Minimal snapshot (no context reported yet): no pct, no window source.
	u, ok = agent_token_usage_from_json(`{"tool_calls":0,"est_tokens_total":0,"window_source":"bogus","compactions":0,"updated_at_ms":5}`)
	testing.expect(t, ok)
	testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), `{"tool_calls":0,"est_tokens_total":0,"compactions":0,"updated_at_ms":5}`)

	for bad in ([]string{``, `[]`, `{"est_tokens_total":1}`, `{"tool_calls":-1,"est_tokens_total":1}`, `{"tool_calls":1,"est_tokens_total":"9"}`, `{"tool_calls":1,"est_tokens_total":1,"context_tokens":1.5}`, `{"tool_calls":1,"est_tokens_total":10000000000000}`}) {
		_, ok = agent_token_usage_from_json(bad)
		testing.expectf(t, !ok, "rejects %q", bad)
	}
	testing.expect_value(t, agent_token_totals_json(Agent_Instance{}, context.temp_allocator), "")
}

@(test)
test_agent_token_usage_usage_supported_round_trip :: proc(t: ^testing.T) {
	for flag in ([]string{"true", "false"}) {
		raw := fmt.tprintf(`{{"tool_calls":1,"est_tokens_total":2,"usage_supported":%s,"compactions":0,"updated_at_ms":9}}`, flag)
		u, ok := agent_token_usage_from_json(raw)
		testing.expect(t, ok)
		testing.expect(t, u.has_usage_supported)
		testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), fmt.tprintf(`{{"tool_calls":1,"est_tokens_total":2,"usage_supported":%s,"compactions":0,"updated_at_ms":9}}`, flag))
	}
	// Absent or non-boolean: omitted from the canonical JSON.
	for raw in ([]string{`{"tool_calls":1,"est_tokens_total":2,"compactions":0,"updated_at_ms":9}`, `{"tool_calls":1,"est_tokens_total":2,"usage_supported":"yes","compactions":0,"updated_at_ms":9}`}) {
		u, ok := agent_token_usage_from_json(raw)
		testing.expect(t, ok)
		testing.expect(t, !u.has_usage_supported)
		testing.expect(t, !strings.contains(agent_token_usage_json(u, context.temp_allocator), "usage_supported"))
	}
}

@(test)
test_agent_token_usage_thresholds_round_trip :: proc(t: ^testing.T) {
	u, ok := agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":2,"warn_pct":30,"rollover_pct":60,"compactions":0,"updated_at_ms":9}`)
	testing.expect(t, ok)
	testing.expect_value(t, u.warn_pct, 30)
	testing.expect_value(t, u.rollover_pct, 60)
	testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), `{"tool_calls":1,"est_tokens_total":2,"warn_pct":30,"rollover_pct":60,"compactions":0,"updated_at_ms":9}`)
	// Out-of-range values are dropped (consumers fall back to the defaults).
	u, ok = agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":2,"warn_pct":0,"rollover_pct":500,"compactions":0,"updated_at_ms":9}`)
	testing.expect(t, ok)
	testing.expect_value(t, u.warn_pct, 0)
	testing.expect_value(t, u.rollover_pct, 0)
}
