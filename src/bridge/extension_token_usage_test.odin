package main

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// Token accumulator (extension_token_usage.odin): accumulation, both reset
// paths, compaction detection, the upstream throttle, and the two exposures
// (agent.extension.status and agent_instance_status.token_usage).

@(private = "file")
tok_event :: proc(event, session: string, extras: ..string) -> string {
	extra := strings.concatenate(extras, context.temp_allocator)
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"`, event, `","ts":"2026-11-02T06:00:00Z","session_id":"`, session, `"`, extra, `}`}, context.temp_allocator)
}

@(private = "file")
tok_metrics :: proc(est: string) -> string {
	return strings.concatenate({`,"tool":{"name":"Read","use_id":"tu_1"},"metrics":{"input_bytes":40,"response_bytes":400,"est_tokens":`, est, `}`}, context.temp_allocator)
}

@(private = "file")
tok_usage :: proc(ctx: string, extra := "") -> string {
	return strings.concatenate({`,"usage":{"context_tokens":`, ctx, extra, `,"source":"claude_transcript"}`}, context.temp_allocator)
}

// tok_apply parses raw and folds it into u (heap allocator, like the ingest path).
@(private = "file")
tok_apply :: proc(t: ^testing.T, u: ^Bridge_Ext_Token_Usage, raw: string, now: i64) -> bool {
	ev, err := contracts.ext_parse_event(raw)
	defer contracts.ext_event_destroy(&ev)
	testing.expect_value(t, err, contracts.Ext_Error.None)
	return bridge_ext_token_usage_apply(u, ev, now)
}

@(private = "file")
tok_rec :: proc(id: string) -> Bridge_Local_Agent_Token_Record {
	return Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
}

@(private = "file")
tok_ingest :: proc(t: ^testing.T, id, raw: string, now: i64) {
	res := bridge_ext_ingest(tok_rec(id), raw, now)
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 1)
}

// tok_take_queued removes id from the status push queue and reports whether it
// was queued. Other tests share the queue, so only this id is touched.
@(private = "file")
tok_take_queued :: proc(id: string) -> bool {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for q, i in bridge_runtime_status_outgoing {
		if q != id do continue
		ordered_remove(&bridge_runtime_status_outgoing, i)
		return true
	}
	return false
}

@(test)
test_ext_tokens_accumulate_tool_calls_and_usage :: proc(t: ^testing.T) {
	u: Bridge_Ext_Token_Usage
	defer bridge_ext_token_usage_destroy(&u)
	testing.expect(t, tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("110")), 1000))
	testing.expect(t, tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("90"), tok_usage("42000", `,"output_tokens_total":1234,"context_window":475000`)), 2000))
	// tool.end without metrics still counts as a call; tool.start counts nothing.
	testing.expect(t, tok_apply(t, &u, tok_event("tool.end", "s1", `,"tool":{"name":"Bash"}`), 3000))
	testing.expect(t, !tok_apply(t, &u, tok_event("tool.start", "s1", `,"tool":{"name":"Bash"}`), 4000))

	testing.expect_value(t, u.session_id, "s1")
	testing.expect_value(t, u.tool_calls, i64(3))
	testing.expect_value(t, u.est_tokens_total, i64(200))
	testing.expect(t, u.has_context)
	testing.expect_value(t, u.context_tokens, i64(42000))
	testing.expect_value(t, u.context_source, "claude_transcript")
	testing.expect_value(t, u.context_window, i64(475000))
	testing.expect_value(t, u.output_tokens_total, i64(1234))
	testing.expect_value(t, u.compactions, i64(0))
	testing.expect_value(t, u.updated_at_ms, i64(3000))

	// A Stop-style usage on a non-tool event updates context without a call, and
	// a usage without output_tokens_total keeps the previous total.
	testing.expect(t, tok_apply(t, &u, tok_event("activity", "s1", `,"payload":{"state":"idle"}`, tok_usage("50000")), 5000))
	testing.expect_value(t, u.tool_calls, i64(3))
	testing.expect_value(t, u.context_tokens, i64(50000))
	testing.expect_value(t, u.output_tokens_total, i64(1234))
	testing.expect_value(t, u.context_window, i64(475000))
}

@(test)
test_ext_tokens_reset_on_session_start :: proc(t: ^testing.T) {
	u: Bridge_Ext_Token_Usage
	defer bridge_ext_token_usage_destroy(&u)
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("100"), tok_usage("80000", `,"output_tokens_total":10`)), 1000)
	testing.expect(t, tok_apply(t, &u, tok_event("session", "s1", `,"payload":{"phase":"start","source":"clear"}`), 2000))
	testing.expect_value(t, u.session_id, "s1")
	testing.expect_value(t, u.tool_calls, i64(0))
	testing.expect_value(t, u.est_tokens_total, i64(0))
	testing.expect(t, !u.has_context)
	testing.expect(t, !u.has_output_total)
	testing.expect_value(t, u.compactions, i64(0))
	// The zeroed snapshot is itself a change the hub must see.
	testing.expect_value(t, u.updated_at_ms, i64(2000))
	testing.expect(t, u.dirty)

	// A session end does not reset.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("7")), 3000)
	_ = tok_apply(t, &u, tok_event("session", "s1", `,"payload":{"phase":"end"}`), 4000)
	testing.expect_value(t, u.tool_calls, i64(1))
}

@(test)
test_ext_tokens_reset_on_new_session_id :: proc(t: ^testing.T) {
	u: Bridge_Ext_Token_Usage
	defer bridge_ext_token_usage_destroy(&u)
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("100"), tok_usage("90000")), 1000)
	// An event without a session id neither resets nor adopts.
	_ = tok_apply(t, &u, tok_event("tool.end", "", tok_metrics("5")), 1500)
	testing.expect_value(t, u.tool_calls, i64(2))
	testing.expect_value(t, u.session_id, "s1")

	_ = tok_apply(t, &u, tok_event("tool.end", "s2", tok_metrics("30")), 2000)
	testing.expect_value(t, u.session_id, "s2")
	testing.expect_value(t, u.tool_calls, i64(1))
	testing.expect_value(t, u.est_tokens_total, i64(30))
	testing.expect(t, !u.has_context)
	// A dropped context across sessions is a reset, not a compaction.
	_ = tok_apply(t, &u, tok_event("tool.end", "s2", tok_usage("1000")), 3000)
	testing.expect_value(t, u.compactions, i64(0))
}

@(test)
test_ext_tokens_compaction_detection :: proc(t: ^testing.T) {
	u: Bridge_Ext_Token_Usage
	defer bridge_ext_token_usage_destroy(&u)
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("500"), tok_usage("150000")), 1000)
	// A 40% drop is not a compaction.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("90000")), 2000)
	testing.expect_value(t, u.compactions, i64(0))
	// Claude restarts the session with source=compact: no reset, est kept.
	_ = tok_apply(t, &u, tok_event("session", "s1", `,"payload":{"phase":"start","source":"compact"}`), 2500)
	testing.expect_value(t, u.est_tokens_total, i64(500))
	// Exactly 50% is a compaction; est_tokens_total and tool_calls are kept.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("20"), tok_usage("45000")), 3000)
	testing.expect_value(t, u.compactions, i64(1))
	testing.expect_value(t, u.est_tokens_total, i64(520))
	testing.expect_value(t, u.tool_calls, i64(3))
	testing.expect_value(t, u.context_tokens, i64(45000))
	// Growth after it, then a second deep drop.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("160000")), 4000)
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("30000")), 5000)
	testing.expect_value(t, u.compactions, i64(2))
}

@(test)
test_ext_tokens_push_throttle :: proc(t: ^testing.T) {
	u: Bridge_Ext_Token_Usage
	defer bridge_ext_token_usage_destroy(&u)
	testing.expect(t, !bridge_ext_token_push_due(u, 0), "nothing to send before any signal")

	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_metrics("10"), tok_usage("20000")), 1000)
	testing.expect(t, bridge_ext_token_push_due(u, 1000), "first snapshot goes at once")
	bridge_ext_token_mark_pushed(&u, 1000)
	testing.expect(t, !bridge_ext_token_push_due(u, 1000), "unchanged snapshot is never re-sent")

	// +9999 tokens (< 5pp of 200k) within 10 s waits for the interval.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("29999")), 2000)
	testing.expect(t, !bridge_ext_token_push_due(u, 2000))
	testing.expect(t, !bridge_ext_token_push_due(u, 10_999))
	testing.expect(t, bridge_ext_token_push_due(u, 11_000), "due once 10 s passed")
	bridge_ext_token_mark_pushed(&u, 11_000)

	// +10000 tokens = 5pp of the 200k default: immediate.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("39999")), 12_000)
	testing.expect(t, bridge_ext_token_push_due(u, 12_000))
	bridge_ext_token_mark_pushed(&u, 12_000)
	// A 5pp drop is immediate too.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("29999")), 13_000)
	testing.expect(t, bridge_ext_token_push_due(u, 13_000))
	bridge_ext_token_mark_pushed(&u, 13_000)

	// With a reported 475k window, 5pp is 23750 tokens.
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("50000", `,"context_window":475000`)), 14_000)
	testing.expect(t, !bridge_ext_token_push_due(u, 14_000), "20001 < 5pp of 475k")
	_ = tok_apply(t, &u, tok_event("tool.end", "s1", tok_usage("53749")), 14_500)
	testing.expect(t, bridge_ext_token_push_due(u, 14_500), "23750 = 5pp of 475k")
}

@(test)
test_ext_tokens_ingest_status_and_upstream_frame :: proc(t: ^testing.T) {
	id := "inst_test_ext_tokens_frame"
	bridge_runtime_mark_start_success(id)
	_ = tok_take_queued(id)
	now := bridge_runtime_now_ms()

	tok_ingest(t, id, tok_event("tool.end", "sess-tok", tok_metrics("110"), tok_usage("40000", `,"output_tokens_total":77`)), now)
	testing.expect(t, tok_take_queued(id), "first snapshot is queued for an immediate status push")
	// A small change inside the interval is held back...
	tok_ingest(t, id, tok_event("tool.end", "sess-tok", tok_metrics("90")), now + 1000)
	testing.expect(t, !tok_take_queued(id), "throttled inside 10 s")
	testing.expect_value(t, bridge_ext_token_enqueue_due(now + 5000, id), 0)
	// ...and released by the hub-loop sweep once the interval passed.
	testing.expect_value(t, bridge_ext_token_enqueue_due(now + 11_000, id), 1)
	testing.expect(t, tok_take_queued(id))
	testing.expect_value(t, bridge_ext_token_enqueue_due(now + 30_000, id), 0)

	// agent.extension.status shows every field.
	status := bridge_ext_status_json(id)
	defer delete(status)
	sv, serr := json.parse_string(status, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, serr, json.Error.None)
	sroot := sv.(json.Object)
	testing.expect_value(t, sroot["session_id"].(json.String), "sess-tok")
	tu := sroot["token_usage"].(json.Object)
	testing.expect_value(t, tu["tool_calls"].(json.Integer), 2)
	testing.expect_value(t, tu["est_tokens_total"].(json.Integer), 200)
	testing.expect_value(t, tu["context_tokens"].(json.Integer), 40000)
	testing.expect_value(t, tu["context_source"].(json.String), "claude_transcript")
	testing.expect_value(t, tu["output_tokens_total"].(json.Integer), 77)
	testing.expect_value(t, tu["compactions"].(json.Integer), 0)
	testing.expect_value(t, tu["updated_at_ms"].(json.Integer), json.Integer(now + 1000))
	_, has_window := tu["context_window"]
	testing.expect(t, !has_window, "context_window is omitted when the provider did not report one")

	// The upstream frame carries the same small object and nothing raw.
	frame := bridge_instance_status_json(id)
	defer delete(frame)
	fv, ferr := json.parse_string(frame, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, ferr, json.Error.None)
	froot := fv.(json.Object)
	testing.expect_value(t, froot["type"].(json.String), "agent_instance_status")
	ftu := froot["token_usage"].(json.Object)
	testing.expect_value(t, ftu["est_tokens_total"].(json.Integer), 200)
	testing.expect_value(t, ftu["context_tokens"].(json.Integer), 40000)
	_, has_session := ftu["session_id"]
	testing.expect(t, !has_session, "the provider session id stays local")
	testing.expect(t, !strings.contains(frame, "tu_1"), "no raw event content upstream")
}

@(test)
test_ext_tokens_absent_without_signals :: proc(t: ^testing.T) {
	id := "inst_test_ext_tokens_absent"
	bridge_runtime_mark_start_success(id)
	frame := bridge_instance_status_json(id)
	defer delete(frame)
	testing.expect(t, !strings.contains(frame, "token_usage"), "no member for an instance without extension token signals")
	status := bridge_ext_status_json(id)
	defer delete(status)
	testing.expect(t, strings.contains(status, `"token_usage":null`))
}
