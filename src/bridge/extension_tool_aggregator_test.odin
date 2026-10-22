package main

import "base:runtime"
import json "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-EXT-CONV-1/2: tool.start/tool.end pairing, call summaries, flush triggers,
// subagent nesting and the metadata size cap of `tool_activity` messages.

@(private = "file")
agg_event :: proc(event, extra: string) -> string {
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"`, event, `","ts":"2026-10-22T06:00:00Z","session_id":"sess-1"`, extra, `}`}, context.temp_allocator)
}

@(private = "file")
agg_feed :: proc(t: ^testing.T, a: ^Tool_Agg, raw: string, now: i64) {
	ev, err := contracts.ext_parse_event(raw)
	defer contracts.ext_event_destroy(&ev)
	testing.expect_value(t, err, contracts.Ext_Error.None)
	tool_agg_observe(a, ev, raw, now)
}

@(private = "file")
agg_start :: proc(t: ^testing.T, a: ^Tool_Agg, tool, use_id, input: string, now: i64, agent := "", payload := "{}") {
	agent_part := strings.concatenate({`,"agent":{"id":"`, agent, `","type":"Explore"}`}, context.temp_allocator) if agent != "" else ""
	use := strings.concatenate({`,"use_id":"`, use_id, `"`}, context.temp_allocator) if use_id != "" else ""
	agg_feed(t, a, agg_event("tool.start", strings.concatenate({agent_part, `,"tool":{"name":"`, tool, `"`, use, `,"input":`, input, `},"payload":`, payload}, context.temp_allocator)), now)
}

@(private = "file")
agg_end :: proc(t: ^testing.T, a: ^Tool_Agg, tool, use_id: string, now: i64, agent := "", payload := `{"status":"ok"}`, input := "{}") {
	agent_part := strings.concatenate({`,"agent":{"id":"`, agent, `","type":"Explore"}`}, context.temp_allocator) if agent != "" else ""
	use := strings.concatenate({`,"use_id":"`, use_id, `"`}, context.temp_allocator) if use_id != "" else ""
	agg_feed(t, a, agg_event("tool.end", strings.concatenate({agent_part, `,"tool":{"name":"`, tool, `"`, use, `,"input":`, input, `},"payload":`, payload}, context.temp_allocator)), now)
}

@(private = "file")
agg_idle :: proc(t: ^testing.T, a: ^Tool_Agg, now: i64, background := 0) {
	payload := `{"state":"idle","reason":"stop","background_running":1}` if background > 0 else `{"state":"idle","reason":"stop","background_running":0}`
	agg_feed(t, a, strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","event":"activity","ts":"2026-10-22T06:05:00Z","payload":`, payload, `}`}, context.temp_allocator), now)
}

// agg_meta parses a message's metadata (temp allocator).
@(private = "file")
agg_meta :: proc(t: ^testing.T, m: Tool_Agg_Message) -> json.Object {
	v, err := json.parse_string(m.metadata_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	obj, _ := v.(json.Object)
	return obj
}

@(private = "file")
arr :: proc(o: json.Object, key: string) -> json.Array {
	a, _ := o[key].(json.Array)
	return a
}

@(private = "file")
str :: proc(o: json.Value, key: string) -> string {
	obj, _ := o.(json.Object)
	s, _ := obj[key].(json.String)
	return string(s)
}

@(private = "file")
boolean :: proc(o: json.Value, key: string) -> bool {
	obj, _ := o.(json.Object)
	b, _ := obj[key].(json.Boolean)
	return bool(b)
}

num :: proc(o: json.Value, key: string) -> i64 {
	obj, _ := o.(json.Object)
	n, _ := obj[key].(json.Integer)
	return i64(n)
}

@(test)
test_tool_agg_pairs_by_use_id_and_fifo_fallback :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_start(t, &a, "Bash", "tu_1", `{"command":"make"}`, 1000)
	agg_start(t, &a, "Read", "tu_2", `{"file_path":"/r/a.odin"}`, 1100)
	// Ends arrive out of order; use_id pairs them. payload.duration_ms wins over
	// the bridge-measured duration.
	agg_end(t, &a, "Read", "tu_2", 1300)
	agg_end(t, &a, "Bash", "tu_1", 2000, payload = `{"status":"error","duration_ms":777}`)
	// No use ids: FIFO per (agent, tool).
	agg_start(t, &a, "Grep", "", `{"pattern":"first"}`, 3000)
	agg_start(t, &a, "Grep", "", `{"pattern":"second"}`, 3100)
	agg_end(t, &a, "Grep", "", 3500)
	testing.expect_value(t, len(a.running), 1)
	testing.expect_value(t, a.running[0].summary, "second")
	agg_idle(t, &a, 4000)

	testing.expect_value(t, len(a.ready), 1)
	meta := agg_meta(t, a.ready[0])
	calls := arr(meta, "calls")
	testing.expect_value(t, len(calls), 4)
	testing.expect_value(t, str(calls[0], "tool"), "Read")
	testing.expect_value(t, str(calls[0], "status"), "ok")
	testing.expect_value(t, num(calls[0], "duration_ms"), 200)
	testing.expect_value(t, str(calls[0], "file_path"), "/r/a.odin")
	testing.expect_value(t, str(calls[1], "tool"), "Bash")
	testing.expect_value(t, str(calls[1], "status"), "error")
	testing.expect_value(t, num(calls[1], "duration_ms"), 777)
	testing.expect_value(t, str(calls[1], "use_id"), "tu_1")
	testing.expect_value(t, str(calls[2], "summary"), "first")
	testing.expect_value(t, str(calls[2], "status"), "ok")
	// The call that never ended (e.g. a denied permission: no PostToolUse) is
	// closed as interrupted once the agent stopped, never left running.
	testing.expect_value(t, str(calls[3], "summary"), "second")
	testing.expect_value(t, str(calls[3], "status"), "error")
	testing.expect(t, boolean(calls[3], "interrupted"), "unended call is marked interrupted")
	testing.expect_value(t, len(a.running), 0)
}

@(test)
test_tool_agg_summaries :: proc(t: ^testing.T) {
	parse :: proc(s: string) -> json.Object {
		v, _ := json.parse_string(s, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		o, _ := v.(json.Object)
		return o
	}
	// Bash: the command (whitespace collapsed), not its description, ≤120 runes.
	testing.expect_value(t, tool_agg_summary("Bash", parse(`{"command":"git  status\n--short","description":"Show status"}`), nil), "git status --short")
	long := strings.repeat("é", 300, context.temp_allocator)
	s := tool_agg_summary("Bash", parse(strings.concatenate({`{"command":"`, long, `"}`}, context.temp_allocator)), nil)
	testing.expect_value(t, strings.rune_count(s), TOOL_AGG_SUMMARY_MAX_RUNES)
	testing.expect(t, strings.has_suffix(s, "…"))
	testing.expect_value(t, tool_agg_summary("Edit", parse(`{"file_path":"/w/x.odin","old_string":"a","new_string":"b"}`), nil), "/w/x.odin")
	testing.expect_value(t, tool_agg_summary("Write", parse(`{"file_path":"/w/y.ts","content":"zzz"}`), nil), "/w/y.ts")
	testing.expect_value(t, tool_agg_summary("Read", parse(`{"file_path":"/w/z.md"}`), nil), "/w/z.md")
	testing.expect_value(t, tool_agg_summary("Grep", parse(`{"pattern":"TODO","path":"src"}`), nil), "TODO")
	testing.expect_value(t, tool_agg_summary("Glob", parse(`{"pattern":"**/*.odin"}`), nil), "**/*.odin")
	testing.expect_value(t, tool_agg_summary("Agent", parse(`{"description":"Find callers","prompt":"long prompt"}`), nil), "Find callers")
	testing.expect_value(t, tool_agg_summary("Agent", nil, parse(`{"description":"From payload"}`)), "From payload")
	testing.expect_value(t, tool_agg_summary("TodoWrite", parse(`{"todos":[]}`), nil), "TodoWrite")
	// Array-valued commands (other harnesses) are joined.
	testing.expect_value(t, tool_agg_summary("shell", parse(`{"command":["ls","-la"]}`), nil), "ls -la")
}

@(test)
test_tool_agg_idle_flush_body_and_turn_bounds :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_feed(t, &a, `{"schema":"ham.ext.v1","provider":"claude","event":"activity","ts":"2026-10-22T06:00:00Z","payload":{"state":"active","reason":"user_prompt"}}`, 500)
	agg_start(t, &a, "Edit", "e1", `{"file_path":"/w/a.odin"}`, 1000)
	agg_end(t, &a, "Edit", "e1", 1100)
	agg_start(t, &a, "Edit", "e2", `{"file_path":"/w/a.odin"}`, 1200)
	agg_end(t, &a, "Edit", "e2", 1300)
	agg_start(t, &a, "Write", "e3", `{"file_path":"/w/b.odin"}`, 1400)
	agg_end(t, &a, "Write", "e3", 1500)
	agg_start(t, &a, "Bash", "b1", `{"command":"odin build"}`, 1600)
	agg_end(t, &a, "Bash", "b1", 1700, payload = `{"status":"error"}`)
	testing.expect_value(t, len(a.ready), 0)
	agg_idle(t, &a, 2000)

	testing.expect_value(t, len(a.ready), 1)
	m := a.ready[0]
	testing.expect_value(t, m.body, "Edited 2 files · ran 1 command · 1 failed")
	testing.expect_value(t, m.reason, "idle")
	meta := agg_meta(t, m)
	testing.expect_value(t, meta["final"].(json.Boolean), true)
	testing.expect_value(t, string(meta["turn_started_at"].(json.String)), "2026-10-22T06:00:00Z")
	testing.expect_value(t, string(meta["turn_ended_at"].(json.String)), "2026-10-22T06:05:00Z")
	counts := meta["counts"]
	testing.expect_value(t, num(counts, "total"), 4)
	testing.expect_value(t, num(counts, "edits"), 3)
	testing.expect_value(t, num(counts, "files_edited"), 2)
	testing.expect_value(t, num(counts, "commands"), 1)
	testing.expect_value(t, num(counts, "error"), 1)
	testing.expect_value(t, num(counts, "omitted"), 0)
	by_tool, _ := counts.(json.Object)["by_tool"].(json.Object)
	testing.expect_value(t, by_tool["Edit"].(json.Integer), 2)

	// The next turn starts fresh.
	testing.expect_value(t, a.turn_started_at, "")
	agg_idle(t, &a, 3000)
	testing.expect_value(t, len(a.ready), 1) // nothing new → no empty message
}

@(test)
test_tool_agg_flushes_at_max_calls_and_interval :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_start(t, &a, "Bash", "long", `{"command":"sleep 100"}`, 900)
	for i in 0..<TOOL_AGG_FLUSH_MAX_CALLS {
		id := strings.concatenate({"r", strings.repeat("x", i + 1, context.temp_allocator)}, context.temp_allocator)
		agg_start(t, &a, "Read", id, `{"file_path":"/f"}`, 1000)
		agg_end(t, &a, "Read", id, 1001)
	}
	testing.expect_value(t, len(a.ready), 1)
	meta := agg_meta(t, a.ready[0])
	testing.expect_value(t, a.ready[0].reason, "max_calls")
	testing.expect_value(t, meta["final"].(json.Boolean), false)
	testing.expect_value(t, len(arr(meta, "calls")), TOOL_AGG_FLUSH_MAX_CALLS)
	// The running call is not in a non-final flush; it waits.
	testing.expect_value(t, len(a.running), 1)
	testing.expect_value(t, a.first_pending_ms, 0)

	// Interval: one call waits, nothing flushes until 5s have passed.
	agg_start(t, &a, "Grep", "g1", `{"pattern":"x"}`, 2000)
	agg_end(t, &a, "Grep", "g1", 2100)
	tool_agg_tick(&a, 2100 + TOOL_AGG_FLUSH_INTERVAL_MS - 1)
	testing.expect_value(t, len(a.ready), 1)
	tool_agg_tick(&a, 2100 + TOOL_AGG_FLUSH_INTERVAL_MS)
	testing.expect_value(t, len(a.ready), 2)
	testing.expect_value(t, a.ready[1].reason, "interval")
	testing.expect_value(t, a.ready[1].body, "Searched 1 time")
	// An idle tick with nothing waiting does nothing.
	tool_agg_tick(&a, 99999)
	testing.expect_value(t, len(a.ready), 2)
}

@(test)
test_tool_agg_nests_subagent_group_on_subagent_stop :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_start(t, &a, "Agent", "ag1", `{"description":"Find callers","subagent_type":"Explore"}`, 1000, payload = `{"description":"Find callers","subagent_type":"Explore"}`)
	agg_feed(t, &a, agg_event("subagent.start", `,"agent":{"id":"sub-1","type":"Explore"},"payload":{}`), 1100)
	agg_start(t, &a, "Grep", "s1", `{"pattern":"proc_x"}`, 1200, agent = "sub-1")
	agg_end(t, &a, "Grep", "s1", 1300, agent = "sub-1")
	agg_start(t, &a, "Read", "s2", `{"file_path":"/w/x.odin"}`, 1400, agent = "sub-1")
	agg_end(t, &a, "Read", "s2", 1500, agent = "sub-1")
	// Subagent calls do not count toward the parent's interval.
	testing.expect_value(t, a.first_pending_ms, 0)
	agg_feed(t, &a, agg_event("subagent.stop", `,"agent":{"id":"sub-1","type":"Explore"},"payload":{}`), 1600)

	testing.expect_value(t, len(a.ready), 1)
	m := a.ready[0]
	testing.expect_value(t, m.reason, "subagent_stop")
	testing.expect_value(t, m.body, "Read 1 file · searched 1 time · 1 subagent")
	meta := agg_meta(t, m)
	testing.expect_value(t, len(arr(meta, "calls")), 0) // the Agent call itself is still running
	subs := arr(meta, "subagents")
	testing.expect_value(t, len(subs), 1)
	testing.expect_value(t, str(subs[0], "agent_id"), "sub-1")
	testing.expect_value(t, str(subs[0], "agent_type"), "Explore")
	testing.expect_value(t, str(subs[0], "description"), "Find callers")
	testing.expect_value(t, str(subs[0], "status"), "done")
	sub_calls := arr(subs[0].(json.Object), "calls")
	testing.expect_value(t, len(sub_calls), 2)
	testing.expect_value(t, str(sub_calls[0], "summary"), "proc_x")
	testing.expect_value(t, len(a.subagents), 0)

	// The parent Agent call ends later and lands in the main list, linked.
	agg_end(t, &a, "Agent", "ag1", 1700, payload = `{"status":"ok","subagent_id":"sub-1","description":"Find callers"}`)
	agg_idle(t, &a, 1800)
	testing.expect_value(t, len(a.ready), 2)
	meta2 := agg_meta(t, a.ready[1])
	calls := arr(meta2, "calls")
	testing.expect_value(t, len(calls), 1)
	testing.expect_value(t, str(calls[0], "summary"), "Find callers")
	testing.expect_value(t, str(calls[0], "subagent_id"), "sub-1")
	testing.expect_value(t, a.ready[1].body, "Spawned 1 subagent")
}

@(test)
test_tool_agg_keeps_background_subagent_across_stop :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_feed(t, &a, agg_event("subagent.start", `,"agent":{"id":"bg-1","type":"general"},"payload":{}`), 1000)
	agg_start(t, &a, "Bash", "b1", `{"command":"npm test"}`, 1100, agent = "bg-1")
	agg_start(t, &a, "Read", "m1", `{"file_path":"/m"}`, 1150)
	agg_end(t, &a, "Read", "m1", 1160)
	// The parent stops while the background subagent still runs.
	agg_idle(t, &a, 1200, background = 1)
	testing.expect_value(t, len(a.ready), 1)
	meta := agg_meta(t, a.ready[0])
	testing.expect_value(t, len(arr(meta, "subagents")), 0)
	testing.expect_value(t, len(arr(meta, "calls")), 1)
	testing.expect_value(t, len(a.subagents), 1)
	testing.expect_value(t, len(a.running), 1) // the subagent's Bash call survives

	agg_end(t, &a, "Bash", "b1", 1300, agent = "bg-1")
	agg_feed(t, &a, agg_event("subagent.stop", `,"agent":{"id":"bg-1","type":"general"},"payload":{}`), 1400)
	testing.expect_value(t, len(a.ready), 2)
	subs := arr(agg_meta(t, a.ready[1]), "subagents")
	testing.expect_value(t, len(subs), 1)
	testing.expect_value(t, str(subs[0], "agent_id"), "bg-1")
	testing.expect_value(t, len(arr(subs[0].(json.Object), "calls")), 1)
}

@(test)
test_tool_agg_metadata_capped_at_4kb :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	cmd := strings.repeat("c", 200, context.temp_allocator)
	n := 0
	// Many subagents with long descriptions, many long commands: the metadata
	// must stay ≤ 4KB and keep the full counts.
	for s in 0..<6 {
		id := strings.concatenate({"sub-", strings.repeat("s", s + 1, context.temp_allocator)}, context.temp_allocator)
		agg_feed(t, &a, agg_event("subagent.start", strings.concatenate({`,"agent":{"id":"`, id, `","type":"Explore"},"payload":{}`}, context.temp_allocator)), 100)
		for i in 0..<10 {
			use := strings.concatenate({id, "-", strings.repeat("u", i + 1, context.temp_allocator)}, context.temp_allocator)
			agg_start(t, &a, "Bash", use, strings.concatenate({`{"command":"`, cmd, `"}`}, context.temp_allocator), 200, agent = id)
			agg_end(t, &a, "Bash", use, 300, agent = id)
			n += 1
		}
	}
	for i in 0..<15 {
		use := strings.concatenate({"m-", strings.repeat("u", i + 1, context.temp_allocator)}, context.temp_allocator)
		agg_start(t, &a, "Bash", use, strings.concatenate({`{"command":"`, cmd, `"}`}, context.temp_allocator), 400)
		agg_end(t, &a, "Bash", use, 500)
		n += 1
	}
	agg_idle(t, &a, 600)
	testing.expect_value(t, len(a.ready), 1)
	m := a.ready[0]
	testing.expect(t, len(m.metadata_json) <= TOOL_AGG_METADATA_MAX_BYTES)
	meta := agg_meta(t, m)
	counts := meta["counts"]
	testing.expect_value(t, num(counts, "total"), i64(n))
	testing.expect_value(t, num(counts, "subagents"), 6)
	testing.expect_value(t, num(meta, "omitted_subagents"), 2)
	kept := len(arr(meta, "calls"))
	for s in arr(meta, "subagents") do kept += len(arr(s.(json.Object), "calls"))
	testing.expect(t, kept > 0)
	testing.expect_value(t, num(counts, "omitted"), i64(n - kept))
	testing.expect_value(t, m.body, "Ran 75 commands · 6 subagents")
}

@(test)
test_tool_agg_group_record_cap_keeps_counts :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_feed(t, &a, agg_event("subagent.start", `,"agent":{"id":"big","type":"Explore"},"payload":{}`), 1)
	for i in 0..<TOOL_AGG_GROUP_MAX_RECORDS + 6 {
		agg_end(t, &a, "Read", "", 2, agent = "big", input = `{"file_path":"/x"}`)
		_ = i
	}
	testing.expect_value(t, len(a.subagents[0].calls), TOOL_AGG_GROUP_MAX_RECORDS)
	testing.expect_value(t, a.subagents[0].dropped, 6)
	agg_feed(t, &a, agg_event("subagent.stop", `,"agent":{"id":"big","type":"Explore"},"payload":{}`), 3)
	meta := agg_meta(t, a.ready[0])
	testing.expect_value(t, num(meta["counts"], "total"), i64(TOOL_AGG_GROUP_MAX_RECORDS + 6))
	testing.expect(t, len(a.ready[0].metadata_json) <= TOOL_AGG_METADATA_MAX_BYTES)
}

@(test)
test_tool_agg_ingest_queues_message_and_params :: proc(t: ^testing.T) {
	// Through the real ingest path (own instance id: tests run in parallel).
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_tool_agg_ingest", instance_token = "tok_test", role = .Agent}
	params := strings.concatenate({`{"events":[`,
		agg_event("tool.start", `,"tool":{"name":"Bash","use_id":"t1","input":{"command":"ls"}},"payload":{}`), ",",
		agg_event("tool.end", `,"tool":{"name":"Bash","use_id":"t1","input":{"command":"ls"}},"payload":{"status":"ok","duration_ms":5}`), ",",
		`{"schema":"ham.ext.v1","provider":"claude","event":"activity","ts":"2026-10-22T06:01:00Z","payload":{"state":"idle"}}`,
		`]}`}, context.temp_allocator)
	res := bridge_ext_ingest(rec, params, 1000)
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 3)

	sync.mutex_lock(&bridge_ext_mutex)
	msgs: [dynamic]Tool_Agg_Message
	for &s in bridge_ext_states {
		if s.agent_instance_id == rec.agent_instance_id do msgs = tool_agg_take_ready(&s.tools)
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	defer {
		// The ingest path owns its state in the heap allocator.
		context.allocator = runtime.heap_allocator()
		for &m in msgs do tool_agg_message_destroy(&m)
		delete(msgs)
	}
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) != 1 do return
	testing.expect_value(t, msgs[0].body, "Ran 1 command")
	p := tool_agg_params(msgs[0], context.temp_allocator)
	v, err := json.parse_string(p, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	obj, _ := v.(json.Object)
	testing.expect_value(t, str(obj, "message_type"), "tool_activity")
	testing.expect_value(t, str(obj, "body"), "Ran 1 command")
	md, _ := obj["metadata"].(json.Object)
	testing.expect_value(t, len(arr(md, "calls")), 1)
}

@(test)
test_tool_agg_instance_terminal_flushes_running_calls :: proc(t: ^testing.T) {
	// A kill mid-turn sends no Stop: the terminal status closes the turn out.
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_tool_agg_terminal", instance_token = "tok_test", role = .Agent}
	params := strings.concatenate({`{"events":[`,
		agg_event("tool.start", `,"tool":{"name":"Bash","use_id":"t1","input":{"command":"sleep 100"}},"payload":{}`),
		`]}`}, context.temp_allocator)
	res := bridge_ext_ingest(rec, params, 1000)
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 1)

	bridge_ext_instance_terminal(rec.agent_instance_id, 2000)
	bridge_ext_instance_terminal("inst_tool_agg_unknown", 2000) // no state: no-op

	sync.mutex_lock(&bridge_ext_mutex)
	msgs: [dynamic]Tool_Agg_Message
	for &s in bridge_ext_states {
		if s.agent_instance_id == rec.agent_instance_id do msgs = tool_agg_take_ready(&s.tools)
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	defer {
		context.allocator = runtime.heap_allocator()
		for &m in msgs do tool_agg_message_destroy(&m)
		delete(msgs)
	}
	testing.expect_value(t, len(msgs), 1)
	if len(msgs) != 1 do return
	md := agg_meta(t, msgs[0])
	testing.expect_value(t, str(md, "reason"), "agent_stopped")
	calls := arr(md, "calls")
	testing.expect_value(t, len(calls), 1)
	if len(calls) == 1 {
		testing.expect_value(t, str(calls[0], "status"), "error")
		testing.expect(t, boolean(calls[0], "interrupted"), "agent stopped: call interrupted")
	}
}

@(test)
test_tool_agg_completed_unknown_is_neither_success_nor_running :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_start(t, &a, "Bash", "stdout-only", `{"command":"exit 7"}`, 1000)
	agg_end(t, &a, "Bash", "stdout-only", 2000, payload = `{"status":"completed","outcome":"unknown"}`)
	agg_idle(t, &a, 3000)
	testing.expect_value(t, len(a.running), 0)
	testing.expect_value(t, len(a.ready), 1)
	if len(a.ready) != 1 do return
	meta := agg_meta(t, a.ready[0])
	calls := arr(meta, "calls")
	if len(calls) != 1 { testing.expect_value(t, len(calls), 1); return }
	testing.expect_value(t, str(calls[0], "status"), "completed")
	counts := meta["counts"]
	testing.expect_value(t, num(counts, "ok"), 0)
	testing.expect_value(t, num(counts, "error"), 0)
	testing.expect_value(t, num(counts, "running"), 0)
	testing.expect_value(t, num(counts, "completed"), 1)
}


@(test)
test_tool_agg_unknown_background_count_preserves_known_child :: proc(t: ^testing.T) {
	a: Tool_Agg
	defer tool_agg_destroy(&a)
	agg_feed(t, &a, agg_event("subagent.start", `,"agent":{"id":"child","type":"default"},"payload":{}`), 1000)
	agg_start(t, &a, "Bash", "child-live", `{"command":"sleep 2"}`, 1100, agent="child")
	agg_feed(t, &a, agg_event("activity", `,"payload":{"state":"idle","reason":"stop"}`), 1200)
	testing.expect_value(t, len(a.running), 1)
	if len(a.running) == 1 do testing.expect_value(t, a.running[0].agent_id, "child")
	agg_end(t, &a, "Bash", "child-live", 1300, agent="child", payload=`{"status":"completed"}`)
	testing.expect_value(t, len(a.running), 0)
}
