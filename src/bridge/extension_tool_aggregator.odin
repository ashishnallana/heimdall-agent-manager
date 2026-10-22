package main

// Tool-call aggregation into `tool_activity` conversation messages
// (REQ-EXT-CONV-1/2).
//
// ham.ext.v1 tool.start / tool.end events are paired into compact call records
// and grouped per instance per turn. The aggregator emits one conversation
// message per flush:
//
//   - activity idle (the provider's Stop) or session end — the turn's final
//     message, including calls that never reported an end (status "running");
//   - subagent.stop — that subagent's group is nested into the next parent
//     message, which is flushed straight away;
//   - TOOL_AGG_FLUSH_INTERVAL_MS after the first unflushed call while calls are
//     flowing, or once TOOL_AGG_FLUSH_MAX_CALLS calls are waiting.
//
// The message is {message_type:"tool_activity", body:<one-line summary>,
// metadata:{calls, subagents, counts, turn_started_at, turn_ended_at, …}} and
// its metadata never exceeds TOOL_AGG_METADATA_MAX_BYTES: counts are always
// kept, per-call detail past the cap is dropped (counts.omitted says how much).
// Full inputs, responses and diffs stay in agent_extension_events; calls carry
// their tool use_id so the UI can find them there (the hub assigns event seqs
// after the bridge has forwarded them, so a seq is not known here).
//
// PROVIDER-AGNOSTIC: only ham.ext.v1 fields are read. The summary comes from
// well-known input keys (command, file_path, pattern, description, …) and the
// body's verbs from a small table of common tool names across harnesses; an
// unknown tool still counts, as "other".
//
// Memory: every string a Tool_Agg holds is owned by context.allocator at the
// time of the call; callers that keep the aggregator in global state pin the
// heap allocator (see extension_ingest.odin).

import json "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import contracts "odin_test:contracts"

TOOL_AGG_FLUSH_INTERVAL_MS :: i64(5000)
TOOL_AGG_FLUSH_MAX_CALLS :: 20
TOOL_AGG_METADATA_MAX_BYTES :: 4096
TOOL_AGG_SUMMARY_MAX_RUNES :: 120
// Per-group and running-call caps bound memory for a runaway turn; counts keep
// growing past them.
TOOL_AGG_GROUP_MAX_RECORDS :: 64
TOOL_AGG_RUNNING_MAX :: 128
// Header-level caps keep the fixed part of the metadata well under the byte cap.
TOOL_AGG_MAX_SUBAGENT_HEADERS :: 4
TOOL_AGG_MAX_BY_TOOL :: 10
TOOL_AGG_NAME_MAX_RUNES :: 64
TOOL_AGG_DESCRIPTION_MAX_RUNES :: 80
TOOL_AGG_PATH_MAX_RUNES :: 240
TOOL_AGG_EDITED_FILES_MAX :: 256
TOOL_AGG_READY_MAX :: 50
TOOL_AGG_MESSAGE_TYPE :: "tool_activity"

Tool_Agg_Status :: enum {
	Running,
	Ok,
	Error,
}

Tool_Agg_Category :: enum {
	Other,
	Edit,
	Command,
	Read,
	Search,
	Spawn,
}

Tool_Agg_Call :: struct {
	use_id:      string,
	tool:        string,
	summary:     string,
	agent_id:    string, // "" = the main agent
	agent_type:  string,
	file_path:   string,
	status:      Tool_Agg_Status,
	started_ms:  i64,
	duration_ms: i64,
	// Spawning calls (input/payload carries a description or subagent_type):
	spawn_type:  string, // payload.subagent_type
	spawn_desc:  string, // description, used to label the subagent group
	subagent_id: string, // linked subagent (subagent.start FIFO or tool.end payload.subagent_id)
}

Tool_Agg_Tool_Count :: struct {
	name:  string,
	count: int,
}

Tool_Agg_Tally :: struct {
	total, ok, error, running:              int,
	edits, commands, reads, searches, other: int,
	spawns:                                 int,
	edited_files:                           [dynamic]string,
	by_tool:                                [dynamic]Tool_Agg_Tool_Count,
}

Tool_Agg_Group :: struct {
	agent_id:    string,
	agent_type:  string,
	description: string,
	calls:       [dynamic]Tool_Agg_Call,
	dropped:     int, // records not retained past TOOL_AGG_GROUP_MAX_RECORDS
	tally:       Tool_Agg_Tally,
	stopped:     bool,
}

Tool_Agg_Message :: struct {
	body:          string,
	metadata_json: string,
	reason:        string,
}

Tool_Agg :: struct {
	running:          [dynamic]Tool_Agg_Call,
	main:             Tool_Agg_Group,
	subagents:        [dynamic]Tool_Agg_Group,
	turn_started_at:  string,
	first_pending_ms: i64, // first unflushed completed call; 0 = none
	ready:            [dynamic]Tool_Agg_Message,
	ready_dropped:    int,
}

// ---------------------------------------------------------------- lifecycle

tool_agg_call_destroy :: proc(c: ^Tool_Agg_Call) {
	delete(c.use_id); delete(c.tool); delete(c.summary); delete(c.agent_id); delete(c.agent_type)
	delete(c.file_path); delete(c.spawn_type); delete(c.spawn_desc); delete(c.subagent_id)
	c^ = {}
}

tool_agg_tally_destroy :: proc(t: ^Tool_Agg_Tally) {
	for f in t.edited_files do delete(f)
	delete(t.edited_files)
	for b in t.by_tool do delete(b.name)
	delete(t.by_tool)
	t^ = {}
}

tool_agg_group_destroy :: proc(g: ^Tool_Agg_Group) {
	delete(g.agent_id); delete(g.agent_type); delete(g.description)
	for &c in g.calls do tool_agg_call_destroy(&c)
	delete(g.calls)
	tool_agg_tally_destroy(&g.tally)
	g^ = {}
}

tool_agg_message_destroy :: proc(m: ^Tool_Agg_Message) {
	delete(m.body); delete(m.metadata_json); delete(m.reason)
	m^ = {}
}

tool_agg_destroy :: proc(a: ^Tool_Agg) {
	for &c in a.running do tool_agg_call_destroy(&c)
	delete(a.running)
	tool_agg_group_destroy(&a.main)
	for &g in a.subagents do tool_agg_group_destroy(&g)
	delete(a.subagents)
	delete(a.turn_started_at)
	for &m in a.ready do tool_agg_message_destroy(&m)
	delete(a.ready)
	a^ = {}
}

// tool_agg_take_ready moves the pending messages out; the caller owns them.
tool_agg_take_ready :: proc(a: ^Tool_Agg) -> [dynamic]Tool_Agg_Message {
	out := a.ready
	a.ready = {}
	return out
}

// ---------------------------------------------------------------- helpers

@(private = "file")
obj_get :: proc(obj: json.Object, key: string) -> json.Object {
	if obj == nil do return nil
	if o, ok := obj[key].(json.Object); ok do return o
	return nil
}

// obj_text returns a scalar (or an array of strings, space-joined) as text in
// the temp allocator; "" when missing.
@(private = "file")
obj_text :: proc(obj: json.Object, key: string) -> string {
	if obj == nil do return ""
	v, ok := obj[key]
	if !ok do return ""
	#partial switch x in v {
	case json.String:  return string(x)
	case json.Integer: return fmt.tprintf("%d", x)
	case json.Array:
		parts := make([dynamic]string, context.temp_allocator)
		for e in x {
			if s, is := e.(json.String); is do append(&parts, string(s))
		}
		return strings.join(parts[:], " ", context.temp_allocator)
	}
	return ""
}

@(private = "file")
obj_int :: proc(obj: json.Object, key: string) -> (i64, bool) {
	if obj == nil do return 0, false
	#partial switch x in obj[key] {
	case json.Integer: return i64(x), true
	case json.Float:   return i64(x), true
	}
	return 0, false
}

// tool_agg_clip collapses whitespace runs and cuts s to max runes, marking a cut
// with "…". The result is in the temp allocator.
tool_agg_clip :: proc(s: string, max_runes: int) -> string {
	fields := strings.fields(s, context.temp_allocator)
	collapsed := strings.join(fields, " ", context.temp_allocator)
	if utf8.rune_count_in_string(collapsed) <= max_runes do return collapsed
	n := 0
	for _, i in collapsed {
		if n == max_runes - 1 do return strings.concatenate({collapsed[:i], "…"}, context.temp_allocator)
		n += 1
	}
	return collapsed
}

// TOOL_AGG_SUMMARY_KEYS: the first non-empty input key wins. Ordered so a shell
// command beats its description and a search pattern beats its path.
@(rodata)
TOOL_AGG_SUMMARY_KEYS := [?]string{"command", "cmd", "file_path", "notebook_path", "pattern", "description", "url", "query", "path"}

// tool_agg_summary picks the one-line summary for a call (temp allocator).
tool_agg_summary :: proc(tool: string, input, payload: json.Object) -> string {
	for key in TOOL_AGG_SUMMARY_KEYS {
		if v := strings.trim_space(obj_text(input, key)); v != "" do return tool_agg_clip(v, TOOL_AGG_SUMMARY_MAX_RUNES)
	}
	if v := strings.trim_space(obj_text(payload, "description")); v != "" do return tool_agg_clip(v, TOOL_AGG_SUMMARY_MAX_RUNES)
	return tool_agg_clip(tool, TOOL_AGG_SUMMARY_MAX_RUNES)
}

// tool_agg_category buckets a tool name for the one-line body. The table names
// common tools across harnesses; anything else is Other.
tool_agg_category :: proc(tool: string) -> Tool_Agg_Category {
	switch strings.to_lower(tool, context.temp_allocator) {
	case "edit", "multiedit", "write", "notebookedit", "apply_patch", "write_file", "replace", "str_replace_editor", "create_file":
		return .Edit
	case "bash", "shell", "exec_command", "run_shell_command", "local_shell", "powershell":
		return .Command
	case "read", "read_file", "view", "notebookread", "read_many_files":
		return .Read
	case "grep", "glob", "search", "find", "ls", "list_directory", "search_file_content", "codebase_search", "websearch", "web_search":
		return .Search
	case "agent", "task", "spawn_agent":
		return .Spawn
	}
	return .Other
}

@(private = "file")
tally_add :: proc(t: ^Tool_Agg_Tally, c: Tool_Agg_Call) {
	t.total += 1
	switch c.status {
	case .Running: t.running += 1
	case .Ok:      t.ok += 1
	case .Error:   t.error += 1
	}
	cat := tool_agg_category(c.tool)
	if cat == .Other && (c.spawn_type != "" || c.spawn_desc != "") do cat = .Spawn
	switch cat {
	case .Edit:
		t.edits += 1
		if c.file_path != "" && len(t.edited_files) < TOOL_AGG_EDITED_FILES_MAX {
			seen := false
			for f in t.edited_files {
				if f == c.file_path { seen = true; break }
			}
			if !seen do append(&t.edited_files, strings.clone(c.file_path))
		}
	case .Command: t.commands += 1
	case .Read:    t.reads += 1
	case .Search:  t.searches += 1
	case .Spawn:   t.spawns += 1
	case .Other:   t.other += 1
	}
	for &b in t.by_tool {
		if b.name == c.tool { b.count += 1; return }
	}
	append(&t.by_tool, Tool_Agg_Tool_Count{name = strings.clone(c.tool), count = 1})
}

// tally_merge folds src into dst (dst keeps its own strings; src is untouched).
@(private = "file")
tally_merge :: proc(dst: ^Tool_Agg_Tally, src: Tool_Agg_Tally) {
	dst.total += src.total; dst.ok += src.ok; dst.error += src.error; dst.running += src.running
	dst.edits += src.edits; dst.commands += src.commands; dst.reads += src.reads
	dst.searches += src.searches; dst.other += src.other; dst.spawns += src.spawns
	outer: for f in src.edited_files {
		if len(dst.edited_files) >= TOOL_AGG_EDITED_FILES_MAX do break
		for d in dst.edited_files {
			if d == f do continue outer
		}
		append(&dst.edited_files, strings.clone(f))
	}
	outer2: for b in src.by_tool {
		for &d in dst.by_tool {
			if d.name == b.name { d.count += b.count; continue outer2 }
		}
		append(&dst.by_tool, Tool_Agg_Tool_Count{name = strings.clone(b.name), count = b.count})
	}
}

@(private = "file")
group_add :: proc(g: ^Tool_Agg_Group, c: Tool_Agg_Call) {
	tally_add(&g.tally, c)
	if len(g.calls) >= TOOL_AGG_GROUP_MAX_RECORDS {
		g.dropped += 1
		cc := c
		tool_agg_call_destroy(&cc)
		return
	}
	append(&g.calls, c)
}

@(private = "file")
subagent_group :: proc(a: ^Tool_Agg, agent_id, agent_type: string) -> ^Tool_Agg_Group {
	for &g in a.subagents {
		if g.agent_id == agent_id {
			if g.agent_type == "" && agent_type != "" do g.agent_type = strings.clone(agent_type)
			return &g
		}
	}
	append(&a.subagents, Tool_Agg_Group{agent_id = strings.clone(agent_id), agent_type = strings.clone(agent_type)})
	return &a.subagents[len(a.subagents) - 1]
}

@(private = "file")
group_pending_calls :: proc(g: Tool_Agg_Group) -> int {
	return len(g.calls) + g.dropped
}

// complete_call files a finished (or, at a final flush, abandoned) call into
// its group. Takes ownership of c's strings.
@(private = "file")
complete_call :: proc(a: ^Tool_Agg, c: Tool_Agg_Call, now: i64) {
	if c.agent_id == "" {
		group_add(&a.main, c)
		if a.first_pending_ms == 0 do a.first_pending_ms = now
	} else {
		group_add(subagent_group(a, c.agent_id, c.agent_type), c)
	}
}

@(private = "file")
find_running :: proc(a: ^Tool_Agg, use_id, agent_id, tool: string) -> int {
	if use_id != "" {
		for c, i in a.running do if c.use_id == use_id do return i
		return -1
	}
	// FIFO fallback per (agent_id, tool) for providers without use ids.
	for c, i in a.running {
		if c.use_id == "" && c.agent_id == agent_id && c.tool == tool do return i
	}
	return -1
}

// ---------------------------------------------------------------- observe

// tool_agg_observe feeds one validated ham.ext.v1 event (raw = its normalised
// JSON). It may queue messages in a.ready; tool_agg_tick handles the interval.
tool_agg_observe :: proc(a: ^Tool_Agg, ev: contracts.Ext_Event, raw: string, now: i64) {
	#partial switch ev.kind {
	case .Tool_Start, .Tool_End, .Activity, .Subagent_Start, .Subagent_Stop, .Session:
	case:
		return
	}
	value, perr := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != .None do return
	root, _ := value.(json.Object)
	tool := obj_get(root, "tool")
	input := obj_get(tool, "input")
	payload := obj_get(root, "payload")

	#partial switch ev.kind {
	case .Activity:
		state := strings.to_lower(strings.trim_space(ev.activity_state), context.temp_allocator)
		if state == "idle" {
			bg, _ := obj_int(payload, "background_running")
			tool_agg_flush(a, "idle", now, final = true, ts = ev.ts, keep_live_subagents = bg > 0)
		} else if state == "active" || state == "working" || state == "busy" {
			// A new prompt starts a new turn. Anything left from a turn whose
			// Stop never arrived is flushed first so turns do not blur.
			if obj_text(payload, "reason") == "user_prompt" {
				tool_agg_flush(a, "new_turn", now, final = true, ts = ev.ts, keep_live_subagents = true)
			}
			if a.turn_started_at == "" do a.turn_started_at = strings.clone(ev.ts)
		}
	case .Session:
		if obj_text(payload, "phase") == "end" do tool_agg_flush(a, "session_end", now, final = true, ts = ev.ts)
	case .Tool_Start:
		if a.turn_started_at == "" do a.turn_started_at = strings.clone(ev.ts)
		if len(a.running) >= TOOL_AGG_RUNNING_MAX {
			// A provider that never sends tool.end must not grow without bound:
			// the oldest call is filed as still running.
			old := a.running[0]
			ordered_remove(&a.running, 0)
			complete_call(a, old, now)
		}
		c := Tool_Agg_Call{
			use_id     = strings.clone(ev.tool_use_id),
			tool       = strings.clone(ev.tool_name),
			summary    = strings.clone(tool_agg_summary(ev.tool_name, input, payload)),
			agent_id   = strings.clone(ev.agent_id),
			agent_type = strings.clone(ev.agent_type),
			file_path  = strings.clone(tool_agg_file_path(input, payload)),
			status     = .Running,
			started_ms = now,
			spawn_type = strings.clone(obj_text(payload, "subagent_type")),
			spawn_desc = strings.clone(tool_agg_clip(obj_text(payload, "description"), TOOL_AGG_DESCRIPTION_MAX_RUNES)),
		}
		append(&a.running, c)
	case .Tool_End:
		if a.turn_started_at == "" do a.turn_started_at = strings.clone(ev.ts)
		status := Tool_Agg_Status.Error if obj_text(payload, "status") == "error" else Tool_Agg_Status.Ok
		idx := find_running(a, ev.tool_use_id, ev.agent_id, ev.tool_name)
		c: Tool_Agg_Call
		if idx >= 0 {
			c = a.running[idx]
			ordered_remove(&a.running, idx)
		} else {
			// An end without a start (the start was before the bridge came up):
			// build the record from the end event alone.
			c = Tool_Agg_Call{
				use_id     = strings.clone(ev.tool_use_id),
				tool       = strings.clone(ev.tool_name),
				summary    = strings.clone(tool_agg_summary(ev.tool_name, input, payload)),
				agent_id   = strings.clone(ev.agent_id),
				agent_type = strings.clone(ev.agent_type),
				file_path  = strings.clone(tool_agg_file_path(input, payload)),
				started_ms = now,
				spawn_desc = strings.clone(tool_agg_clip(obj_text(payload, "description"), TOOL_AGG_DESCRIPTION_MAX_RUNES)),
			}
		}
		c.status = status
		if d, ok := obj_int(payload, "duration_ms"); ok {
			c.duration_ms = d
		} else {
			c.duration_ms = max(i64(0), now - c.started_ms)
		}
		if sid := obj_text(payload, "subagent_id"); sid != "" {
			if c.subagent_id == "" do c.subagent_id = strings.clone(sid)
			for &g in a.subagents {
				if g.agent_id == sid && g.description == "" && c.spawn_desc != "" do g.description = strings.clone(c.spawn_desc)
			}
		}
		complete_call(a, c, now)
		if group_pending_calls(a.main) >= TOOL_AGG_FLUSH_MAX_CALLS do tool_agg_flush(a, "max_calls", now)
	case .Subagent_Start:
		if ev.agent_id == "" do return
		g := subagent_group(a, ev.agent_id, ev.agent_type)
		// Label the group from the oldest unlinked spawning call, preferring one
		// whose requested type matches.
		best := -1
		for c, i in a.running {
			if c.agent_id != "" || c.subagent_id != "" || (c.spawn_desc == "" && c.spawn_type == "") do continue
			if c.spawn_type == ev.agent_type { best = i; break }
			if best < 0 do best = i
		}
		if best >= 0 {
			a.running[best].subagent_id = strings.clone(ev.agent_id)
			if g.description == "" do g.description = strings.clone(a.running[best].spawn_desc)
		}
	case .Subagent_Stop:
		if ev.agent_id == "" do return
		g := subagent_group(a, ev.agent_id, ev.agent_type)
		g.stopped = true
		// The subagent's calls that never ended are filed as running.
		for i := len(a.running) - 1; i >= 0; i -= 1 {
			if a.running[i].agent_id == ev.agent_id {
				c := a.running[i]
				ordered_remove(&a.running, i)
				group_add(subagent_group(a, c.agent_id, c.agent_type), c)
			}
		}
		tool_agg_flush(a, "subagent_stop", now)
	}
}

@(rodata)
TOOL_AGG_PATH_KEYS := [?]string{"file_path", "notebook_path"}

// tool_agg_file_path returns the call's file path (temp allocator), if any.
tool_agg_file_path :: proc(input, payload: json.Object) -> string {
	for key in TOOL_AGG_PATH_KEYS {
		if v := strings.trim_space(obj_text(input, key)); v != "" do return tool_agg_clip(v, TOOL_AGG_PATH_MAX_RUNES)
	}
	if v := strings.trim_space(obj_text(payload, "file_path")); v != "" do return tool_agg_clip(v, TOOL_AGG_PATH_MAX_RUNES)
	return ""
}

// tool_agg_tick flushes the interval trigger: calls have been waiting for
// TOOL_AGG_FLUSH_INTERVAL_MS.
tool_agg_tick :: proc(a: ^Tool_Agg, now: i64) {
	if a.first_pending_ms > 0 && now - a.first_pending_ms >= TOOL_AGG_FLUSH_INTERVAL_MS {
		tool_agg_flush(a, "interval", now)
	}
}

// ---------------------------------------------------------------- flush

// tool_agg_flush renders the waiting calls into one message on a.ready.
//
//   final=false: completed main-agent calls plus every stopped subagent group;
//                running calls stay for a later message.
//   final=true:  everything, with unfinished calls as "running"; live subagent
//                groups are kept back when keep_live_subagents (background
//                subagents outlive the parent's Stop and flush on their own stop).
tool_agg_flush :: proc(a: ^Tool_Agg, reason: string, now: i64, final := false, ts := "", keep_live_subagents := false) {
	if final {
		for i := 0; i < len(a.running); {
			c := a.running[i]
			if c.agent_id != "" && keep_live_subagents {
				i += 1
				continue
			}
			ordered_remove(&a.running, i)
			if c.agent_id == "" do group_add(&a.main, c)
			else do group_add(subagent_group(a, c.agent_id, c.agent_type), c)
		}
	}
	emit := make([dynamic]int, context.temp_allocator)
	for g, i in a.subagents {
		if g.stopped || (final && !keep_live_subagents) do append(&emit, i)
	}
	if group_pending_calls(a.main) > 0 || len(emit) > 0 {
		groups := make([dynamic]^Tool_Agg_Group, context.temp_allocator)
		for i in emit do append(&groups, &a.subagents[i])
		ended := ts if final else ""
		msg := tool_agg_render(&a.main, groups[:], reason, final, a.turn_started_at, ended)
		if len(a.ready) >= TOOL_AGG_READY_MAX {
			tool_agg_message_destroy(&a.ready[0])
			ordered_remove(&a.ready, 0)
			a.ready_dropped += 1
		}
		append(&a.ready, msg)
	}
	// Reset what was emitted.
	tool_agg_group_destroy(&a.main)
	for i := len(emit) - 1; i >= 0; i -= 1 {
		tool_agg_group_destroy(&a.subagents[emit[i]])
		ordered_remove(&a.subagents, emit[i])
	}
	a.first_pending_ms = 0
	if final {
		delete(a.turn_started_at)
		a.turn_started_at = ""
	}
}

// ---------------------------------------------------------------- render

@(private = "file")
write_str :: proc(b: ^strings.Builder, key, value: string, comma := true) {
	if comma do strings.write_byte(b, ',')
	strings.write_byte(b, '"'); strings.write_string(b, key); strings.write_string(b, `":"`)
	bridge_local_write_json_string(b, value)
	strings.write_byte(b, '"')
}

@(private = "file")
write_int :: proc(b: ^strings.Builder, key: string, value: int, comma := true) {
	if comma do strings.write_byte(b, ',')
	strings.write_string(b, fmt.tprintf(`"%s":%d`, key, value))
}

@(private = "file")
status_name :: proc(s: Tool_Agg_Status) -> string {
	switch s {
	case .Running: return "running"
	case .Ok:      return "ok"
	case .Error:   return "error"
	}
	return "ok"
}

// render_call returns one call's JSON (temp allocator).
@(private = "file")
render_call :: proc(c: Tool_Agg_Call) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	write_str(&b, "tool", tool_agg_clip(c.tool, TOOL_AGG_NAME_MAX_RUNES), comma = false)
	write_str(&b, "summary", c.summary)
	write_str(&b, "status", status_name(c.status))
	strings.write_string(&b, fmt.tprintf(`,"duration_ms":%d`, c.duration_ms))
	if c.use_id != "" do write_str(&b, "use_id", tool_agg_clip(c.use_id, TOOL_AGG_NAME_MAX_RUNES))
	if c.file_path != "" do write_str(&b, "file_path", c.file_path)
	if c.subagent_id != "" do write_str(&b, "subagent_id", tool_agg_clip(c.subagent_id, TOOL_AGG_NAME_MAX_RUNES))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
render_counts :: proc(b: ^strings.Builder, t: Tool_Agg_Tally, subagents, omitted: int, with_by_tool: bool) {
	strings.write_byte(b, '{')
	write_int(b, "total", t.total, comma = false)
	write_int(b, "ok", t.ok); write_int(b, "error", t.error); write_int(b, "running", t.running)
	write_int(b, "edits", t.edits); write_int(b, "files_edited", len(t.edited_files))
	write_int(b, "commands", t.commands); write_int(b, "reads", t.reads); write_int(b, "searches", t.searches)
	write_int(b, "other", t.other); write_int(b, "subagents", subagents); write_int(b, "omitted", omitted)
	if with_by_tool {
		strings.write_string(b, `,"by_tool":{`)
		for e, i in t.by_tool {
			if i >= TOOL_AGG_MAX_BY_TOOL do break
			if i > 0 do strings.write_byte(b, ',')
			strings.write_byte(b, '"'); bridge_local_write_json_string(b, tool_agg_clip(e.name, TOOL_AGG_NAME_MAX_RUNES))
			strings.write_string(b, fmt.tprintf(`":%d`, e.count))
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, '}')
}

// tool_agg_body is the one-line human summary, e.g. "Edited 3 files · ran 2
// commands · 1 failed" (temp allocator).
tool_agg_body :: proc(t: Tool_Agg_Tally, subagents: int) -> string {
	plural :: proc(n: int, one, many: string) -> string {
		return fmt.tprintf("%d %s", n, one if n == 1 else many)
	}
	parts := make([dynamic]string, context.temp_allocator)
	if t.edits > 0 {
		files := len(t.edited_files)
		if files > 0 {
			append(&parts, fmt.tprintf("edited %s", plural(files, "file", "files")))
		} else {
			append(&parts, fmt.tprintf("made %s", plural(t.edits, "edit", "edits")))
		}
	}
	if t.commands > 0 do append(&parts, fmt.tprintf("ran %s", plural(t.commands, "command", "commands")))
	if t.reads > 0 do append(&parts, fmt.tprintf("read %s", plural(t.reads, "file", "files")))
	if t.searches > 0 do append(&parts, fmt.tprintf("searched %s", plural(t.searches, "time", "times")))
	if subagents > 0 do append(&parts, plural(subagents, "subagent", "subagents"))
	else if t.spawns > 0 do append(&parts, fmt.tprintf("spawned %s", plural(t.spawns, "subagent", "subagents")))
	if t.other > 0 do append(&parts, fmt.tprintf("used %s", plural(t.other, "other tool", "other tools")))
	if t.running > 0 do append(&parts, fmt.tprintf("%d still running", t.running))
	if t.error > 0 do append(&parts, fmt.tprintf("%d failed", t.error))
	if len(parts) == 0 do return plural(t.total, "tool call", "tool calls")
	line := strings.join(parts[:], " · ", context.temp_allocator)
	return strings.concatenate({strings.to_upper(line[:1], context.temp_allocator), line[1:]}, context.temp_allocator)
}

// tool_agg_render builds one message from the main group and the given subagent
// groups. The metadata is capped at TOOL_AGG_METADATA_MAX_BYTES by dropping
// per-call records (main calls first in order, then each subagent's). The
// returned strings are owned by context.allocator.
tool_agg_render :: proc(main: ^Tool_Agg_Group, groups: []^Tool_Agg_Group, reason: string, final: bool, turn_started_at, turn_ended_at: string) -> Tool_Agg_Message {
	// total lives in the temp allocator (its arrays and strings alike), so it is
	// never destroyed here.
	total: Tool_Agg_Tally
	{
		context.allocator = context.temp_allocator
		tally_merge(&total, main.tally)
		for g in groups do tally_merge(&total, g.tally)
	}
	omitted := main.dropped
	for g in groups do omitted += g.dropped

	headers := min(len(groups), TOOL_AGG_MAX_SUBAGENT_HEADERS)
	omitted_subagents := len(groups) - headers
	for g in groups[headers:] do omitted += group_pending_calls(g^)

	render :: proc(main: ^Tool_Agg_Group, groups: []^Tool_Agg_Group, headers: int, include: []bool, total: Tool_Agg_Tally, omitted, omitted_subagents: int, reason: string, final: bool, started, ended: string, with_by_tool: bool) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"v":1`)
		write_str(&b, "reason", reason)
		strings.write_string(&b, `,"final":`); strings.write_string(&b, "true" if final else "false")
		write_str(&b, "turn_started_at", started)
		write_str(&b, "turn_ended_at", ended)
		strings.write_string(&b, `,"counts":`)
		render_counts(&b, total, len(groups), omitted, with_by_tool)
		if omitted_subagents > 0 do write_int(&b, "omitted_subagents", omitted_subagents)
		k := 0
		strings.write_string(&b, `,"calls":[`)
		n := 0
		for c in main.calls {
			if include[k] {
				if n > 0 do strings.write_byte(&b, ',')
				strings.write_string(&b, render_call(c)); n += 1
			}
			k += 1
		}
		strings.write_string(&b, `],"subagents":[`)
		for g, gi in groups[:headers] {
			if gi > 0 do strings.write_byte(&b, ',')
			strings.write_byte(&b, '{')
			write_str(&b, "agent_id", tool_agg_clip(g.agent_id, TOOL_AGG_NAME_MAX_RUNES), comma = false)
			write_str(&b, "agent_type", tool_agg_clip(g.agent_type, TOOL_AGG_NAME_MAX_RUNES))
			write_str(&b, "description", tool_agg_clip(g.description, TOOL_AGG_DESCRIPTION_MAX_RUNES))
			write_str(&b, "status", "done" if g.stopped else "running")
			strings.write_string(&b, fmt.tprintf(`,"counts":{{"total":%d,"error":%d,"running":%d}}`, g.tally.total, g.tally.error, g.tally.running))
			strings.write_string(&b, `,"calls":[`)
			n = 0
			for c in g.calls {
				if include[k] {
					if n > 0 do strings.write_byte(&b, ',')
					strings.write_string(&b, render_call(c)); n += 1
				}
				k += 1
			}
			strings.write_string(&b, "]}")
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b)
	}

	// Candidate per-call records in display order.
	rendered := make([dynamic]string, context.temp_allocator)
	for c in main.calls do append(&rendered, render_call(c))
	for g in groups[:headers] do for c in g.calls do append(&rendered, render_call(c))
	include := make([]bool, len(rendered), context.temp_allocator)

	with_by_tool := true
	skeleton := render(main, groups, headers, include, total, omitted + len(rendered), omitted_subagents, reason, final, turn_started_at, turn_ended_at, with_by_tool)
	if len(skeleton) > TOOL_AGG_METADATA_MAX_BYTES / 2 {
		with_by_tool = false
		skeleton = render(main, groups, headers, include, total, omitted + len(rendered), omitted_subagents, reason, final, turn_started_at, turn_ended_at, with_by_tool)
	}
	// Greedy fill, in order; stop at the first record that does not fit so the
	// kept calls are a prefix (the newest are the ones dropped).
	budget := TOOL_AGG_METADATA_MAX_BYTES - len(skeleton)
	kept := 0
	for r, i in rendered {
		cost := len(r) + 1
		if cost > budget do break
		budget -= cost
		include[i] = true
		kept += 1
	}
	meta := render(main, groups, headers, include, total, omitted + len(rendered) - kept, omitted_subagents, reason, final, turn_started_at, turn_ended_at, with_by_tool)
	// The omitted count only shrinks, so meta is never longer than skeleton +
	// the kept records; this guard is belt and braces.
	for len(meta) > TOOL_AGG_METADATA_MAX_BYTES && kept > 0 {
		for i := len(include) - 1; i >= 0; i -= 1 {
			if include[i] { include[i] = false; kept -= 1; break }
		}
		meta = render(main, groups, headers, include, total, omitted + len(rendered) - kept, omitted_subagents, reason, final, turn_started_at, turn_ended_at, with_by_tool)
	}
	return Tool_Agg_Message{
		body          = strings.clone(tool_agg_body(total, len(groups))),
		metadata_json = strings.clone(meta),
		reason        = strings.clone(reason),
	}
}

// tool_agg_params renders the hub envelope params for one message.
tool_agg_params :: proc(m: Tool_Agg_Message, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"message_type":"`)
	strings.write_string(&b, TOOL_AGG_MESSAGE_TYPE)
	strings.write_string(&b, `","body":"`)
	bridge_local_write_json_string(&b, m.body)
	strings.write_string(&b, `","metadata":`)
	strings.write_string(&b, m.metadata_json)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
