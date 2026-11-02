package domain

// Per-instance token usage (chain "Estimate agent tokens via extensions", T3r).
// The bridge reports a small snapshot on agent_instance_status.token_usage and,
// after a hub-requested stop or restart, the finished run's frozen
// token_usage_final. The hub stores only the latest snapshot (canonical JSON
// built here, never the bridge's raw text) and running lifetime totals.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Upper bound for any counter; larger (or negative/non-integer) values are
// rejected so a misbehaving bridge cannot poison the lifetime totals.
AGENT_TOKEN_USAGE_MAX :: 1_000_000_000_000
// Thresholds shared with the bridge's shipped config (warn / rollover %).
AGENT_TOKEN_WARN_PCT :: 60
AGENT_TOKEN_ROLLOVER_PCT :: 80

Agent_Token_Usage :: struct {
	tool_calls:          i64,
	est_tokens_total:    i64,
	has_context:         bool,
	context_tokens:      i64,
	context_window:      i64, // 0 = not reported
	window_source:       string, // static literal: override | config | default | ""
	has_output_total:    bool,
	output_tokens_total: i64,
	compactions:         i64,
	run_count:           int, // 0 = not reported
	updated_at_ms:       i64,
}

@(private = "file")
token_int :: proc(obj: json.Object, key: string, required: bool) -> (value: i64, present: bool, ok: bool) {
	raw, has := obj[key]
	if !has || raw == nil do return 0, false, !required
	#partial switch v in raw {
	case json.Integer:
		if v < 0 || v > AGENT_TOKEN_USAGE_MAX do return 0, true, false
		return i64(v), true, true
	case json.Float:
		if v < 0 || v > f64(AGENT_TOKEN_USAGE_MAX) || v != f64(i64(v)) do return 0, true, false
		return i64(v), true, true
	}
	return 0, true, false
}

// agent_token_usage_window_source maps a reported source onto a static literal.
agent_token_usage_window_source :: proc(source: string) -> string {
	switch source {
	case "override": return "override"
	case "config": return "config"
	case "default": return "default"
	}
	return ""
}

// agent_token_usage_from_json validates a token_usage / token_usage_final
// object (raw JSON text). tool_calls and est_tokens_total are required; every
// other member is optional. Unknown members are ignored.
agent_token_usage_from_json :: proc(raw: string) -> (Agent_Token_Usage, bool) {
	if strings.trim_space(raw) == "" do return {}, false
	value, err := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return {}, false
	obj, is_obj := value.(json.Object)
	if !is_obj do return {}, false
	u: Agent_Token_Usage
	ok: bool
	present: bool
	run: i64
	if u.tool_calls, _, ok = token_int(obj, "tool_calls", true); !ok do return {}, false
	if u.est_tokens_total, _, ok = token_int(obj, "est_tokens_total", true); !ok do return {}, false
	if u.context_tokens, u.has_context, ok = token_int(obj, "context_tokens", false); !ok do return {}, false
	if u.context_window, _, ok = token_int(obj, "context_window", false); !ok do return {}, false
	if u.output_tokens_total, u.has_output_total, ok = token_int(obj, "output_tokens_total", false); !ok do return {}, false
	if u.compactions, _, ok = token_int(obj, "compactions", false); !ok do return {}, false
	if u.updated_at_ms, _, ok = token_int(obj, "updated_at_ms", false); !ok do return {}, false
	if run, present, ok = token_int(obj, "run_count", false); !ok do return {}, false
	if present {
		if run > i64(max(i32)) do return {}, false
		u.run_count = int(run)
	}
	if source, is_str := obj["window_source"].(json.String); is_str do u.window_source = agent_token_usage_window_source(source)
	return u, true
}

// agent_token_usage_context_pct is context_tokens as a whole percentage of the
// window (floor), or -1 when either is unknown.
agent_token_usage_context_pct :: proc(u: Agent_Token_Usage) -> i64 {
	if !u.has_context || u.context_window <= 0 do return -1
	return u.context_tokens * 100 / u.context_window
}

// agent_token_usage_json renders the canonical snapshot the hub stores and
// serves. context_pct is recomputed from context_tokens and context_window.
agent_token_usage_json :: proc(u: Agent_Token_Usage, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, fmt.tprintf("{{\"tool_calls\":%d,\"est_tokens_total\":%d", u.tool_calls, u.est_tokens_total))
	if u.has_context do strings.write_string(&b, fmt.tprintf(",\"context_tokens\":%d", u.context_tokens))
	if u.context_window > 0 do strings.write_string(&b, fmt.tprintf(",\"context_window\":%d", u.context_window))
	if u.window_source != "" do strings.write_string(&b, fmt.tprintf(",\"window_source\":\"%s\"", u.window_source))
	if pct := agent_token_usage_context_pct(u); pct >= 0 do strings.write_string(&b, fmt.tprintf(",\"context_pct\":%d", pct))
	if u.has_output_total do strings.write_string(&b, fmt.tprintf(",\"output_tokens_total\":%d", u.output_tokens_total))
	if u.run_count > 0 do strings.write_string(&b, fmt.tprintf(",\"run_count\":%d", u.run_count))
	strings.write_string(&b, fmt.tprintf(",\"compactions\":%d,\"updated_at_ms\":%d}}", u.compactions, u.updated_at_ms))
	return strings.clone(strings.to_string(b), allocator)
}

// agent_token_totals_json renders the lifetime totals of inst, or "" when no
// run has been counted yet.
agent_token_totals_json :: proc(inst: Agent_Instance, allocator := context.allocator) -> string {
	if !inst.has_token_totals do return ""
	return fmt.aprintf("{{\"total_context_tokens\":%d,\"total_est_tool_tokens\":%d,\"total_output_tokens\":%d,\"runs_counted\":%d,\"last_run_counted\":%d}}",
		inst.token_total_context_tokens, inst.token_total_est_tool_tokens, inst.token_total_output_tokens, inst.token_runs_counted, inst.token_totals_last_run, allocator = allocator)
}
