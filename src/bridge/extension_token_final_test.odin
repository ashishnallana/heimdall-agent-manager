package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Final token usage of a finished run (T3r): captured at a hub stop or restart,
// tagged with the run's launch generation, and carried on agent_instance_status
// as token_usage_final until a newer run's final replaces it.

@(private = "file")
fin_ingest :: proc(t: ^testing.T, id, raw: string, now: i64) {
	res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, raw, now)
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 1)
}

@(private = "file")
fin_event :: proc(session, est, ctx: string) -> string {
	return strings.concatenate({
		`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"`, session,
		`","tool":{"name":"Read","use_id":"tu_1"},"metrics":{"input_bytes":40,"response_bytes":400,"est_tokens":`, est,
		`},"usage":{"context_tokens":`, ctx, `,"output_tokens_total":50,"source":"claude_transcript"}}`,
	}, context.temp_allocator)
}

// fin_fields renders the token members of a status frame as a JSON object.
@(private = "file")
fin_fields :: proc(t: ^testing.T, id: string, run_count: int) -> json.Object {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"x":0`)
	bridge_ext_token_usage_field(&b, id, run_count)
	strings.write_string(&b, "}")
	v, err := json.parse_string(strings.to_string(b), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	return v.(json.Object)
}

@(test)
test_ext_token_final_captured_tagged_and_kept :: proc(t: ^testing.T) {
	id := "inst_test_ext_token_final"
	now := bridge_runtime_now_ms()
	fin_ingest(t, id, fin_event("sess-fin", "300", "120000"), now)

	root := fin_fields(t, id, 3)
	live := root["token_usage"].(json.Object)
	testing.expect_value(t, live["run_count"].(json.Integer), 3)
	testing.expect_value(t, live["est_tokens_total"].(json.Integer), 300)
	_, has_final := root["token_usage_final"]
	testing.expect(t, !has_final, "no final before a stop or restart")

	// A hub stop freezes the run's usage as its final.
	testing.expect(t, bridge_ext_token_capture_final(id, 3))
	root = fin_fields(t, id, 3)
	final := root["token_usage_final"].(json.Object)
	testing.expect_value(t, final["run_count"].(json.Integer), 3)
	testing.expect_value(t, final["context_tokens"].(json.Integer), 120000)
	testing.expect_value(t, final["est_tokens_total"].(json.Integer), 300)
	testing.expect_value(t, final["output_tokens_total"].(json.Integer), 50)
	testing.expect_value(t, final["context_window"].(json.Integer), 200000)

	// An older generation never overwrites a newer final; unknown runs are ignored.
	testing.expect(t, !bridge_ext_token_capture_final(id, 2))
	testing.expect(t, !bridge_ext_token_capture_final(id, 0))
	testing.expect(t, !bridge_ext_token_capture_final("inst_test_ext_token_final_none", 5))

	// A restart (genuine relaunch) re-freezes the same run and zeroes the live
	// counters; the zeroed snapshot still goes upstream, the final stays.
	testing.expect(t, bridge_ext_token_capture_final(id, 3, reset_live = true, now = now + 5))
	root = fin_fields(t, id, 4)
	live = root["token_usage"].(json.Object)
	testing.expect_value(t, live["run_count"].(json.Integer), 4)
	testing.expect_value(t, live["tool_calls"].(json.Integer), 0)
	testing.expect_value(t, live["est_tokens_total"].(json.Integer), 0)
	_, has_ctx := live["context_tokens"]
	testing.expect(t, !has_ctx, "the new run has no context yet")
	testing.expect_value(t, live["context_window"].(json.Integer), 200000)
	final = root["token_usage_final"].(json.Object)
	testing.expect_value(t, final["run_count"].(json.Integer), 3)
	testing.expect_value(t, final["est_tokens_total"].(json.Integer), 300)

	// The next run accumulates from zero and its own stop replaces the final.
	fin_ingest(t, id, fin_event("sess-fin-2", "40", "9000"), now + 10)
	testing.expect(t, bridge_ext_token_capture_final(id, 4))
	final = fin_fields(t, id, 4)["token_usage_final"].(json.Object)
	testing.expect_value(t, final["run_count"].(json.Integer), 4)
	testing.expect_value(t, final["est_tokens_total"].(json.Integer), 40)
	testing.expect_value(t, final["context_tokens"].(json.Integer), 9000)
}

@(test)
test_ext_token_final_absent_without_signals :: proc(t: ^testing.T) {
	id := "inst_test_ext_token_final_absent"
	testing.expect(t, !bridge_ext_token_capture_final(id, 1, reset_live = true))
	root := fin_fields(t, id, 1)
	_, has_live := root["token_usage"]
	_, has_final := root["token_usage_final"]
	testing.expect(t, !has_live && !has_final)
}
