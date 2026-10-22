package extension

import json "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

codex_callbacks :: proc() -> json.Array {
	v, _ := json.parse_string(#load("testdata/codex/callbacks.json", string), json.DEFAULT_SPECIFICATION, true)
	rows, _ := v.(json.Array)
	return rows
}

@(test)
test_codex_actual_release_callbacks_satisfy_contract :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	rows := codex_callbacks()
	testing.expect(t, len(rows) >= 70)
	events := make(map[string]int)
	sources := make(map[string]bool)
	children := make(map[string]bool)
	edits := make(map[string]int)
	for row in rows {
		root, _ := row.(json.Object)
		b, _ := json.marshal(row)
		mapped, err := codex_map_hook(string(b), TS, 10_000, "blk_fixture")
		testing.expect_value(t, err, Codex_Error.None)
		name := json_get_string(root, "hook_event_name")
		if name == "PreCompact" || name == "PostCompact" {
			testing.expect_value(t, len(mapped.events), 0)
			continue
		}
		testing.expect(t, len(mapped.events) > 0, name)
		for raw in mapped.events {
			ev, e := contracts.ext_parse_event(raw)
			testing.expect_value(t, e, contracts.Ext_Error.None)
			testing.expect_value(t, ev.provider, "codex")
			testing.expect_value(t, ev.session_id, json_get_string(root, "session_id"))
			testing.expect_value(t, ev.agent_id, json_get_string(root, "agent_id"))
			events[contracts.ext_event_kind_name(ev.kind)] += 1
			v, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true)
			o, _ := v.(json.Object)
			p := json_get_object(o, "payload")
			if ev.kind == .File_Edit {
				edits[json_get_string(p, "operation")] += 1
				testing.expect(t, ev.file_path != "")
				if json_get_string(p, "operation") != "create" do testing.expect(t, json_get_bool(p, "partial"))
			}
			if ev.kind == .Tool_End {
				testing.expect_value(t, json_get_string(p, "status"), "completed")
				testing.expect_value(t, json_get_string(p, "outcome"), "unknown")
			}
		}
		if name == "SessionStart" do sources[json_get_string(root, "source")] = true
		if name == "PermissionRequest" && json_get_string(root, "agent_id") != "" do children[json_get_string(root, "agent_id")] = true
	}
	for name in ([]string{"hello", "session", "activity", "tool.start", "tool.end", "subagent.start", "subagent.stop", "permission.request", "file.edit"}) {
		testing.expect(t, events[name] > 0, name)
	}
	for source in ([]string{"startup", "clear", "resume", "fork"}) do testing.expect(t, sources[source], source)
	testing.expect_value(t, len(children), 2)
	for op in ([]string{"create","update","delete","move"}) do testing.expect_value(t, edits[op], 1)
}

@(test)
test_codex_unknown_invalid_bounded_and_native_decisions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for raw in ([]string{"[]", "{", `{"hook_event_name":"Stop"}`}) {
		_, err := codex_map_hook(raw, TS)
		testing.expect_value(t, err, Codex_Error.Malformed_Json)
	}
	_, err := codex_map_hook(strings.repeat("x", CODEX_HOOK_INPUT_MAX+1), TS)
	testing.expect_value(t, err, Codex_Error.Too_Large)
	unknown, _ := codex_map_hook(`{"session_id":"s","hook_event_name":"Notification"}`, TS)
	testing.expect_value(t, len(unknown.events), 0)
	testing.expect(t, strings.contains(codex_permission_output_from_response(`{"ok":true,"data":{"decision":"allow"}}`), `"behavior":"allow"`))
	testing.expect(t, strings.contains(codex_permission_output_from_response(`{"ok":true,"data":{"data":{"decision":"deny","message":"no"}}}`), `"behavior":"deny"`))
	for raw in ([]string{"", "{}", `{"ok":false,"data":{"decision":"allow"}}`, `{"ok":true,"data":{"decision":"none"}}`, `{"ok":true,"data":{"decision":"ask"}}`}) {
		testing.expect_value(t, codex_permission_output_from_response(raw), "")
	}
}
