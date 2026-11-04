package extension

// Pre-clip tool metrics and transcript-tail usage (ham.ext.v1 metrics/usage).

import json "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

@(private = "file")
UTS :: "2026-11-02T16:00:00.000Z"

@(private = "file")
CLAUDE_TAIL :: #load("testdata/transcripts/claude_tail.jsonl", string)
@(private = "file")
CODEX_TAIL :: #load("testdata/transcripts/codex_tail.jsonl", string)

// Expected figures for the fixtures above.
@(private = "file")
CLAUDE_CTX :: 2 + 2087 + 95340 // msg_02: the last main-chain, non-synthetic usage
@(private = "file")
CLAUDE_OUT :: 50 + 428 // msg_01 deduplicated (max of 5/50) + msg_02
@(private = "file")
CODEX_CTX :: 240023 - 126

@(private = "file")
scratch_dir :: proc(t: ^testing.T, name: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do home, _ = os.temp_dir(context.temp_allocator)
	base := fmt.tprintf("%s/.cache/heimdall-tests", home)
	_ = os.make_directory_all(base)
	dir := fmt.tprintf("%s/ext-usage-%s-%d", base, name, time.to_unix_nanoseconds(time.now()))
	err := os.make_directory_all(dir)
	testing.expectf(t, err == nil, "mkdir %s: %v", dir, err)
	return dir
}

@(private = "file")
write_file :: proc(t: ^testing.T, path, content: string) {
	err := os.write_entire_file_from_string(path, content)
	testing.expectf(t, err == nil, "write %s: %v", path, err)
}

// without_first_line drops the fixture's deliberately cut first line, giving
// the content of a small, intact transcript.
@(private = "file")
without_first_line :: proc(s: string) -> string {
	nl := strings.index_byte(s, '\n')
	return s[nl + 1:] if nl >= 0 else ""
}

@(private = "file")
parse_one :: proc(t: ^testing.T, raw: string) -> contracts.Ext_Event {
	ev, err := contracts.ext_parse_event(raw)
	testing.expectf(t, err == .None, "event must satisfy ham.ext.v1 (%v): %s", err, raw)
	return ev
}

@(private = "file")
with_transcript :: proc(raw, path: string) -> string {
	v, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	root := v.(json.Object)
	root["transcript_path"] = json.String(path)
	data, _ := json.marshal(root)
	return string(data)
}

// ---- metrics ----------------------------------------------------------------

@(test)
test_json_encoded_len_matches_compact_marshal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	raw := `{"a":"x\"y\\z\n\t\u0001","b":[1,-20,true,false,null,{"c":"é"}],"d":{}}`
	v, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
	// raw is already compact JSON written with json_write_string's escapes.
	testing.expect_value(t, json_encoded_len(v), i64(len(raw)))
	testing.expect_value(t, json_encoded_len(nil), i64(0))
	testing.expect_value(t, json_encoded_len(json.String("ab")), i64(4))
}

@(test)
test_claude_tool_end_metrics_report_pre_clip_size :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	big_in := strings.repeat("i", 10_000)
	big_out := strings.repeat("o", 20_000)
	raw := fmt.tprintf(`{{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"tu1","tool_input":{{"command":"%s"}},"tool_response":{{"stdout":"%s","usage":{{"x":1}}}}}}`, big_in, big_out)
	mapped, err := claude_map_hook(raw, UTS)
	testing.expect_value(t, err, Claude_Error.None)
	testing.expect_value(t, len(mapped.events), 1)
	if len(mapped.events) != 1 do return
	ev := parse_one(t, mapped.events[0])
	testing.expect(t, ev.has_metrics)
	want_in := i64(len(`{"command":""}`) + 10_000)
	want_out := i64(len(`{"stdout":"","usage":{"x":1}}`) + 20_000)
	testing.expect_value(t, ev.metrics.input_bytes, want_in)
	testing.expect_value(t, ev.metrics.response_bytes, want_out)
	testing.expect_value(t, ev.metrics.est_tokens, (want_in + want_out + 3) / 4)
	testing.expect(t, !ev.has_usage, "no transcript_path → no usage")
	// Clipping is unchanged: the forwarded strings are still capped at 4 KiB.
	v, _ := json.parse_string(mapped.events[0], json.DEFAULT_SPECIFICATION, true)
	tool := json_get_object(v.(json.Object), "tool")
	cmd := json_get_string(json_get_object(tool, "input"), "command")
	testing.expect(t, len(cmd) < CLAUDE_TOOL_STRING_MAX + 64 && strings.has_suffix(cmd, EXT_CLIP_MARKER))
	testing.expect(t, !json_has(json_get_object(tool, "response"), "usage"), "dropped keys stay dropped")
}

@(test)
test_claude_tool_failure_metrics_measure_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	raw := `{"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tu1","tool_input":{"command":"false"},"error":"exit 1"}`
	mapped, _ := claude_map_hook(raw, UTS)
	if len(mapped.events) != 1 do return
	ev := parse_one(t, mapped.events[0])
	testing.expect(t, ev.has_metrics)
	testing.expect_value(t, ev.metrics.input_bytes, i64(len(`{"command":"false"}`)))
	testing.expect_value(t, ev.metrics.response_bytes, i64(len(`"exit 1"`)))
}

@(test)
test_codex_tool_end_metrics_include_dropped_image :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	img := strings.repeat("A", 8_000)
	raw := fmt.tprintf(`{{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"view_image","tool_use_id":"tu1","tool_input":{{"path":"/x.png"}},"tool_response":"%s"}}`, img)
	mapped, err := codex_map_hook(raw, UTS)
	testing.expect_value(t, err, Codex_Error.None)
	if len(mapped.events) != 1 do return
	ev := parse_one(t, mapped.events[0])
	testing.expect(t, ev.has_metrics)
	testing.expect_value(t, ev.metrics.input_bytes, i64(len(`{"path":"/x.png"}`)))
	testing.expect_value(t, ev.metrics.response_bytes, i64(8_002))
	testing.expect(t, !strings.contains(mapped.events[0], img[:100]), "image bytes are still not forwarded")
	// tool.start carries no metrics.
	pre, _ := codex_map_hook(`{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"tu2","tool_input":{"command":"ls"}}`, UTS)
	if len(pre.events) == 1 do testing.expect(t, !parse_one(t, pre.events[0]).has_metrics)
}

@(test)
test_antigravity_tool_end_metrics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	mapped, err := antigravity_map_hook(#load("testdata/antigravity/post_tool_use.json", string), UTS)
	testing.expect_value(t, err, Antigravity_Error.None)
	found := false
	for e in mapped.events {
		ev := parse_one(t, e)
		if ev.kind != .Tool_End do continue
		found = true
		testing.expect(t, ev.has_metrics)
		testing.expect(t, ev.metrics.input_bytes > 0 && ev.metrics.response_bytes > 0)
		testing.expect_value(t, ev.metrics.est_tokens, contracts.ext_est_tokens(ev.metrics.input_bytes, ev.metrics.response_bytes))
		testing.expect(t, !ev.has_usage, "antigravity has no usage source")
	}
	testing.expect(t, found)
}

// ---- transcript tail parsing ------------------------------------------------

@(test)
test_claude_usage_from_intact_small_transcript :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	u, ok := claude_usage_from_tail(without_first_line(CLAUDE_TAIL), true)
	testing.expect(t, ok)
	testing.expect_value(t, u.context_tokens, i64(CLAUDE_CTX))
	testing.expect(t, u.has_output_tokens_total)
	testing.expect_value(t, u.output_tokens_total, i64(CLAUDE_OUT))
	testing.expect_value(t, u.source, USAGE_SOURCE_CLAUDE)
	testing.expect(t, !u.has_context_window)
}

@(test)
test_claude_usage_partial_window_omits_output_total :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// Cut first line (as a mid-file window would be without dropping it) and a
	// cut last line: context still comes from the last complete usage.
	u, ok := claude_usage_from_tail(CLAUDE_TAIL, false)
	testing.expect(t, ok)
	testing.expect_value(t, u.context_tokens, i64(CLAUDE_CTX))
	testing.expect(t, !u.has_output_tokens_total, "a partial window is not a session total")
	// Even from the file start, a corrupt usage line makes the sum unreliable.
	u2, ok2 := claude_usage_from_tail(CLAUDE_TAIL, true)
	testing.expect(t, ok2)
	testing.expect(t, !u2.has_output_tokens_total)
}

@(test)
test_claude_usage_absent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	_, ok := claude_usage_from_tail(#load("testdata/transcripts/claude_no_usage.jsonl", string), true)
	testing.expect(t, !ok)
	_, ok = claude_usage_from_tail("", true)
	testing.expect(t, !ok)
	_, ok = claude_usage_from_tail("not json\n{\"usage\":\n", true)
	testing.expect(t, !ok)
}

@(test)
test_codex_usage_from_tail_uses_last_token_count_with_info :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	u, ok := codex_usage_from_tail(CODEX_TAIL)
	testing.expect(t, ok)
	testing.expect_value(t, u.context_tokens, i64(CODEX_CTX))
	testing.expect(t, u.has_output_tokens_total)
	testing.expect_value(t, u.output_tokens_total, i64(45014))
	testing.expect(t, u.has_context_window)
	testing.expect_value(t, u.context_window, i64(475000))
	testing.expect_value(t, u.source, USAGE_SOURCE_CODEX)
	_, ok = codex_usage_from_tail(#load("testdata/transcripts/codex_no_usage.jsonl", string))
	testing.expect(t, !ok, "info:null token_count events carry no usage")
}

@(test)
test_transcript_tail_reads_only_the_window :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "tail")
	defer _ = os.remove_all(dir)
	// 80 KiB of older assistant entries that would change both figures if read.
	b := strings.builder_make()
	old := `{{"type":"assistant","isSidechain":false,"message":{{"id":"msg_old_%d","model":"m","usage":{{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1000}}}}}}` + "\n"
	for i := 0; strings.builder_len(b) < 80 * 1024; i += 1 do fmt.sbprintf(&b, old, i)
	strings.write_string(&b, CLAUDE_TAIL)
	path := fmt.tprintf("%s/session.jsonl", dir)
	write_file(t, path, strings.to_string(b))

	data, from_start, ok := transcript_tail(path)
	testing.expect(t, ok)
	testing.expect(t, !from_start)
	testing.expect(t, len(data) <= TRANSCRIPT_TAIL_MAX)
	testing.expect(t, strings.has_prefix(string(data), `{"type":"assistant"`), "the cut first line is dropped")

	u, uok := claude_transcript_usage(path)
	testing.expect(t, uok)
	testing.expect_value(t, u.context_tokens, i64(CLAUDE_CTX))
	testing.expect(t, !u.has_output_tokens_total)

	// A small intact file is read whole and yields the exact output total.
	small := fmt.tprintf("%s/small.jsonl", dir)
	write_file(t, small, without_first_line(CLAUDE_TAIL))
	us, sok := claude_transcript_usage(small)
	testing.expect(t, sok && us.has_output_tokens_total)
	testing.expect_value(t, us.output_tokens_total, i64(CLAUDE_OUT))
}

@(test)
test_transcript_usage_omission_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "omit")
	defer _ = os.remove_all(dir)
	garbage := fmt.tprintf("%s/garbage.jsonl", dir)
	write_file(t, garbage, "\x00\x01 not json {\"usage\": [\n\"token_count\"\n")
	empty := fmt.tprintf("%s/empty.jsonl", dir)
	write_file(t, empty, "")
	// One line longer than the window: no complete line survives the cut.
	oneline := fmt.tprintf("%s/oneline.jsonl", dir)
	write_file(t, oneline, strings.repeat("x", TRANSCRIPT_TAIL_MAX + 10))
	for p in ([]string{"", "   ", fmt.tprintf("%s/missing.jsonl", dir), dir, garbage, empty, oneline}) {
		_, cok := claude_transcript_usage(p)
		testing.expectf(t, !cok, "claude usage must be omitted for %q", p)
		_, xok := codex_transcript_usage(p)
		testing.expectf(t, !xok, "codex usage must be omitted for %q", p)
	}
}

// ---- adapter wiring ---------------------------------------------------------

@(test)
test_claude_stop_and_tool_end_carry_usage :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "claude-map")
	defer _ = os.remove_all(dir)
	path := fmt.tprintf("%s/s.jsonl", dir)
	write_file(t, path, without_first_line(CLAUDE_TAIL))

	for fixture in ([]string{
		#load("testdata/claude/stop_background.json", string),
		#load("testdata/claude/post_tool_use_edit.json", string),
		#load("testdata/claude/post_tool_use_failure.json", string),
	}) {
		mapped, err := claude_map_hook(with_transcript(fixture, path), UTS)
		testing.expect_value(t, err, Claude_Error.None)
		if len(mapped.events) == 0 do continue
		ev := parse_one(t, mapped.events[0])
		testing.expect(t, ev.has_usage)
		testing.expect_value(t, ev.usage.context_tokens, i64(CLAUDE_CTX))
		testing.expect_value(t, ev.usage.output_tokens_total, i64(CLAUDE_OUT))
		testing.expect_value(t, ev.usage.source, USAGE_SOURCE_CLAUDE)
		testing.expect_value(t, ev.has_metrics, ev.kind == .Tool_End)
		// The fixtures' real transcript_path does not exist here: usage omitted.
		plain, _ := claude_map_hook(fixture, UTS)
		if len(plain.events) > 0 do testing.expect(t, !parse_one(t, plain.events[0]).has_usage)
	}
	// Non-tool.end / non-Stop events never read the transcript.
	pre, _ := claude_map_hook(with_transcript(#load("testdata/claude/pre_tool_use_agent.json", string), path), UTS)
	if len(pre.events) > 0 {
		ev := parse_one(t, pre.events[0])
		testing.expect(t, !ev.has_usage && !ev.has_metrics)
	}
}

@(test)
test_codex_stop_and_tool_end_carry_usage :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "codex-map")
	defer _ = os.remove_all(dir)
	path := fmt.tprintf("%s/rollout.jsonl", dir)
	write_file(t, path, CODEX_TAIL)
	for raw in ([]string{
		fmt.tprintf(`{{"session_id":"s1","hook_event_name":"Stop","transcript_path":"%s"}}`, path),
		fmt.tprintf(`{{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"tu1","tool_input":{{"command":"ls"}},"tool_response":"a","transcript_path":"%s"}}`, path),
	}) {
		mapped, err := codex_map_hook(raw, UTS)
		testing.expect_value(t, err, Codex_Error.None)
		if len(mapped.events) != 1 do continue
		ev := parse_one(t, mapped.events[0])
		testing.expect(t, ev.has_usage)
		testing.expect_value(t, ev.usage.context_tokens, i64(CODEX_CTX))
		testing.expect_value(t, ev.usage.context_window, i64(475000))
		testing.expect_value(t, ev.transcript_path, path)
	}
	missing, _ := codex_map_hook(`{"session_id":"s1","hook_event_name":"Stop","transcript_path":"/nonexistent/rollout.jsonl"}`, UTS)
	if len(missing.events) == 1 do testing.expect(t, !parse_one(t, missing.events[0]).has_usage)
}

@(test)
test_hook_stdout_stays_empty_with_bad_transcript :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	env := Hook_Env{endpoint = "unix:/nonexistent", token = "tok", ts = UTS}
	send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
		return "", false
	}
	for provider in ([]string{CLAUDE_PROVIDER, CODEX_PROVIDER}) {
		for path in ([]string{"/nonexistent/x.jsonl", "/"}) {
			raw := fmt.tprintf(`{{"session_id":"s1","hook_event_name":"Stop","transcript_path":"%s"}}`, path)
			testing.expect_value(t, hook_run(provider, raw, env, send), "")
		}
	}
}

// ---- contract ---------------------------------------------------------------

@(test)
test_contract_metrics_usage_optional_and_backward_compatible :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	old := `{"schema":"ham.ext.v1","provider":"claude","event":"tool.end","ts":"t","session_id":"s","agent":{},"tool":{"name":"Bash"},"payload":{}}`
	ev := parse_one(t, old)
	testing.expect(t, !ev.has_metrics && !ev.has_usage)

	full := `{"schema":"ham.ext.v1","provider":"codex","event":"tool.end","ts":"t","session_id":"s","agent":{},"tool":{"name":"Bash"},"metrics":{"input_bytes":10,"response_bytes":7,"est_tokens":5},"usage":{"context_tokens":1234,"output_tokens_total":56,"context_window":475000,"source":"codex_rollout"},"payload":{}}`
	ev = parse_one(t, full)
	testing.expect(t, ev.has_metrics)
	testing.expect_value(t, ev.metrics, contracts.Ext_Tool_Metrics{10, 7, 5})
	testing.expect(t, ev.has_usage && ev.usage.has_output_tokens_total && ev.usage.has_context_window)
	testing.expect_value(t, ev.usage.context_tokens, i64(1234))
	testing.expect_value(t, ev.usage.output_tokens_total, i64(56))
	testing.expect_value(t, ev.usage.source, "codex_rollout")

	// Malformed optional blocks are ignored, never fatal; est_tokens is derived when absent.
	odd := `{"schema":"ham.ext.v1","provider":"claude","event":"activity","ts":"t","session_id":"s","agent":{},"metrics":{"input_bytes":9,"response_bytes":0},"usage":{"context_tokens":"lots"},"payload":{"state":"idle"}}`
	ev = parse_one(t, odd)
	testing.expect(t, ev.has_metrics && !ev.has_usage)
	testing.expect_value(t, ev.metrics.est_tokens, i64(3))
	ev = parse_one(t, `{"schema":"ham.ext.v1","provider":"claude","event":"activity","metrics":[1],"usage":{"context_tokens":-1},"payload":{}}`)
	testing.expect(t, !ev.has_metrics && !ev.has_usage)

	// The bridge's batch normaliser keeps both blocks.
	split, serr := contracts.ext_split_events(full)
	testing.expect_value(t, serr, contracts.Ext_Error.None)
	if len(split) == 1 do testing.expect(t, parse_one(t, split[0]).has_usage)
}

// ---- latency ----------------------------------------------------------------

// The hook budget is the 500 ms bridge RPC timeout; usage reading must add a
// small constant cost regardless of transcript size. ~10 MB transcript, median
// of several Stop mappings with vs without the transcript.
@(test)
test_transcript_usage_latency_on_10mb_transcript :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "latency")
	defer _ = os.remove_all(dir)
	b := strings.builder_make()
	entry := `{{"type":"assistant","isSidechain":false,"message":{{"id":"msg_%d","model":"claude-opus-5-5","role":"assistant","content":[{{"type":"text","text":"%s"}}],"usage":{{"input_tokens":3,"cache_creation_input_tokens":200,"cache_read_input_tokens":%d,"output_tokens":120}}}}}}` + "\n"
	filler := strings.repeat("lorem ipsum ", 80)
	for i := 0; strings.builder_len(b) < 10 * 1000 * 1000; i += 1 do fmt.sbprintf(&b, entry, i, filler, 90_000 + i)
	path := fmt.tprintf("%s/big.jsonl", dir)
	write_file(t, path, strings.to_string(b))
	size := strings.builder_len(b)

	with := fmt.tprintf(`{{"session_id":"s1","hook_event_name":"Stop","transcript_path":"%s"}}`, path)
	without := `{"session_id":"s1","hook_event_name":"Stop"}`
	RUNS :: 15
	median :: proc(raw: string) -> time.Duration {
		d: [RUNS]time.Duration
		for i in 0 ..< RUNS {
			start := time.tick_now()
			_, _ = claude_map_hook(raw, UTS)
			d[i] = time.tick_since(start)
		}
		for i in 1 ..< RUNS do for j := i; j > 0 && d[j] < d[j - 1]; j -= 1 do d[j], d[j - 1] = d[j - 1], d[j]
		return d[RUNS / 2]
	}
	base := median(without)
	full := median(with)
	added := full - base
	read_start := time.tick_now()
	u, ok := claude_transcript_usage(path)
	read_one := time.tick_since(read_start)
	testing.expect(t, ok)
	testing.expect(t, u.context_tokens > 90_000)
	log.infof("transcript usage latency: file=%d bytes, Stop map median %v without / %v with transcript (added %v), single read %v",
		size, base, full, added, read_one)
	testing.expectf(t, added < 50 * time.Millisecond, "added hook latency %v must stay far below the 500 ms RPC budget", added)
}

// ---- usage-source table -----------------------------------------------------

@(test)
test_usage_source_table_covers_readers_and_antigravity_has_none :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := scratch_dir(t, "table")
	defer _ = os.remove_all(dir)
	claude_path := fmt.tprintf("%s/claude.jsonl", dir)
	codex_path := fmt.tprintf("%s/codex.jsonl", dir)
	write_file(t, claude_path, without_first_line(CLAUDE_TAIL))
	write_file(t, codex_path, CODEX_TAIL)
	missing := fmt.tprintf("%s/missing.jsonl", dir)

	Case :: struct { provider, path, source: string, ctx: i64 }
	for c in ([]Case{
		{CLAUDE_PROVIDER, claude_path, USAGE_SOURCE_CLAUDE, CLAUDE_CTX},
		{CODEX_PROVIDER, codex_path, USAGE_SOURCE_CODEX, CODEX_CTX},
	}) {
		reader, has := usage_reader_for(c.provider)
		testing.expectf(t, has, "%s must have a usage reader", c.provider)
		if !has do continue
		root := fmt.tprintf(`{{"session_id":"s","transcript_path":"%s"}}`, c.path)
		val, perr := json.parse_string(root)
		testing.expect_value(t, perr, json.Error.None)
		u, ok := reader(val.(json.Object))
		testing.expectf(t, ok, "%s fixture must yield usage", c.provider)
		testing.expect_value(t, u.context_tokens, c.ctx)
		testing.expect_value(t, u.source, c.source)

		// Reader present but transcript unreadable: counter instead of usage.
		eb := ext_event_begin("activity", UTS, val.(json.Object), c.provider, "x")
		bad, _ := json.parse_string(fmt.tprintf(`{{"session_id":"s","transcript_path":"%s"}}`, missing))
		ext_event_finish_usage(&eb, c.provider, bad.(json.Object), true)
		ev := parse_one(t, ext_event_end(&eb, "{}"))
		testing.expect(t, !ev.has_usage && ev.usage_unavailable)
		// want_usage=false emits nothing.
		eb2 := ext_event_begin("activity", UTS, val.(json.Object), c.provider, "x")
		ext_event_finish_usage(&eb2, c.provider, bad.(json.Object), false)
		ev2 := parse_one(t, ext_event_end(&eb2, "{}"))
		testing.expect(t, !ev2.has_usage && !ev2.usage_unavailable)
	}
	_, has := usage_reader_for(ANTIGRAVITY_PROVIDER)
	testing.expect(t, !has, "antigravity has no usage reader")
	root, _ := json.parse_string(`{"session_id":"s","transcript_path":"/x"}`)
	eb := ext_event_begin("activity", UTS, root.(json.Object), ANTIGRAVITY_PROVIDER, "x")
	ext_event_finish_usage(&eb, ANTIGRAVITY_PROVIDER, root.(json.Object), true)
	ev := parse_one(t, ext_event_end(&eb, "{}"))
	testing.expect(t, !ev.has_usage && !ev.usage_unavailable)
}
