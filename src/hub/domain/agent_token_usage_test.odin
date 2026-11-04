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

@(test)
test_agent_token_usage_reported_window_source :: proc(t: ^testing.T) {
	u, ok := agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":2,"context_tokens":50000,"context_window":258400,"window_source":"reported","reported_window":258400,"window_mismatch":true,"compactions":0,"updated_at_ms":5}`)
	testing.expect(t, ok)
	testing.expect_value(t, u.window_source, "reported")
	testing.expect_value(t, u.reported_window, i64(258400))
	testing.expect(t, u.window_mismatch)
	testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), `{"tool_calls":1,"est_tokens_total":2,"context_tokens":50000,"context_window":258400,"window_source":"reported","reported_window":258400,"window_mismatch":true,"context_pct":19,"compactions":0,"updated_at_ms":5}`)

	u, ok = agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":2,"window_source":"config","compactions":0,"updated_at_ms":5}`)
	testing.expect(t, ok)
	testing.expect_value(t, u.reported_window, i64(0))
	testing.expect(t, !u.window_mismatch)
}

@(test)
test_agent_token_usage_estimate_fields :: proc(t: ^testing.T) {
	// Estimate only: accepted, pct recomputed from the estimate.
	u, ok := agent_token_usage_from_json(`{"tool_calls":3,"est_tokens_total":100000,"context_source":"estimate","estimated_context_tokens":150000,"context_window":200000,"context_pct":1,"compactions":0,"updated_at_ms":9}`)
	testing.expect(t, ok)
	testing.expect_value(t, agent_token_usage_context_pct(u), i64(75))
	testing.expect_value(t, agent_token_usage_json(u, context.temp_allocator), `{"tool_calls":3,"est_tokens_total":100000,"context_source":"estimate","estimated_context_tokens":150000,"context_window":200000,"context_pct":75,"compactions":0,"updated_at_ms":9}`)
	// Provider-reported tokens win over a stale estimate.
	u, ok = agent_token_usage_from_json(`{"tool_calls":3,"est_tokens_total":100000,"context_tokens":20000,"context_source":"estimate","estimated_context_tokens":150000,"context_window":200000,"compactions":0,"updated_at_ms":9}`)
	testing.expect(t, ok)
	testing.expect_value(t, agent_token_usage_context_pct(u), i64(10))
	testing.expect(t, !strings.contains(agent_token_usage_json(u, context.temp_allocator), "estimate"))
	// Invalid estimate rejected.
	_, ok = agent_token_usage_from_json(`{"tool_calls":3,"est_tokens_total":1,"context_source":"estimate","estimated_context_tokens":-1,"compactions":0,"updated_at_ms":9}`)
	testing.expect(t, !ok)
}

// Regression (T15): the bridge stamps updated_at_ms with epoch milliseconds
// (~1.8e12 today). The counter cap (1e12) used to reject that value, so every
// real snapshot was dropped and the instance JSON token_usage stayed null.
@(test)
test_agent_token_usage_accepts_epoch_millisecond_timestamp :: proc(t: ^testing.T) {
	// Verbatim shape of a live claude snapshot (T10b) with a real epoch-ms stamp.
	raw := `{"tool_calls":4,"est_tokens_total":1257,"context_tokens":52162,"context_source":"claude_transcript","context_window":1000000,"window_source":"config","warn_pct":40,"rollover_pct":70,"context_pct":5,"usage_supported":true,"run_count":1,"compactions":0,"updated_at_ms":1793775000000}`
	u, ok := agent_token_usage_from_json(raw)
	testing.expect(t, ok, "a live snapshot with epoch-ms updated_at_ms is accepted")
	testing.expect_value(t, u.updated_at_ms, i64(1793775000000))
	testing.expect(t, strings.contains(agent_token_usage_json(u, context.temp_allocator), `"updated_at_ms":1793775000000`))
	// Counters keep their cap; only the timestamp has a wider bound.
	_, ok = agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":1,"compactions":0,"updated_at_ms":-1}`)
	testing.expect(t, !ok, "negative timestamp rejected")
	_, ok = agent_token_usage_from_json(`{"tool_calls":1,"est_tokens_total":1,"compactions":0,"updated_at_ms":1000000000000000000}`)
	testing.expect(t, !ok, "absurd timestamp rejected")
}
