package extension

import json "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

codex_image_callbacks :: proc() -> json.Array {
	v, _ := json.parse_string(#load("testdata/codex/image_callbacks.json", string), .JSON, true)
	return v.(json.Array)
}

@(test)
test_codex_native_image_callbacks_keep_identity_without_image_data :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	starts := make(map[string]bool)
	ends := make(map[string]bool)
	for row in codex_image_callbacks() {
		root := row.(json.Object)
		raw, _ := json.marshal(root)
		mapped, err := codex_map_hook(string(raw), TS)
		testing.expect_value(t, err, Codex_Error.None)
		testing.expect_value(t, len(mapped.events), 1)
		if len(mapped.events) != 1 do continue
		ev, parse_err := contracts.ext_parse_event(mapped.events[0])
		testing.expect_value(t, parse_err, contracts.Ext_Error.None)
		if json_get_string(root, "hook_event_name") == "Stop" {
			testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Activity)
			continue
		}
		id := json_get_string(root, "tool_use_id")
		testing.expect_value(t, ev.tool_use_id, id)
		testing.expect_value(t, ev.tool_name, "view_image")
		testing.expect(t, !strings.contains(mapped.events[0], "image_url"))
		testing.expect(t, !strings.contains(mapped.events[0], "base64"))
		if ev.kind == .Tool_Start do starts[id] = true
		if ev.kind == .Tool_End {
			testing.expect(t, starts[id], "native completion pairs with its own start")
			testing.expect(t, strings.contains(mapped.events[0], `"status":"completed"`))
			ends[id] = true
		}
	}
	testing.expect_value(t, len(starts), 4)
	testing.expect_value(t, len(ends), 2)
	// Actual missing/invalid-image calls have no PostToolUse in this release.
	// Stop remains activity only; never manufacture successful completions.
	testing.expect(t, !ends["exec-image-1"] && !ends["exec-image-2"])
}

@(test)
test_codex_large_native_image_completion_is_bounded_and_payload_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	root: json.Object
	for row in codex_image_callbacks() {
		o := row.(json.Object)
		if json_get_string(o, "hook_event_name") == "PostToolUse" do root = o
	}
	testing.expect(t, root != nil)
	if root == nil do return
	// Same native array/data-URL envelope; generate bytes rather than committing
	// a multi-megabyte image. Actual capture was 2,361,718 bytes.
	response := root["tool_response"].(json.Array)
	image := response[0].(json.Object)
	image["image_url"] = json.String(strings.concatenate({"data:application/octet-stream;base64,", strings.repeat("A", 2_400_000)}))
	raw, _ := json.marshal(root)
	testing.expect(t, len(raw) > 1024*1024)
	mapped, err := codex_map_hook(string(raw), TS)
	testing.expect_value(t, err, Codex_Error.None)
	if err != .None || len(mapped.events) != 1 do return
	ev, parse_err := contracts.ext_parse_event(mapped.events[0])
	testing.expect_value(t, parse_err, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.Tool_End)
	testing.expect_value(t, ev.tool_use_id, "exec-image-4")
	testing.expect(t, len(mapped.events[0]) < 2048)
	testing.expect(t, !strings.contains(mapped.events[0], "image_url"))
	testing.expect(t, !strings.contains(mapped.events[0], "base64"))

	// Accept exactly the explicit stdin cap, reject one byte beyond it.
	delete_key(&root, "tool_response")
	delete_key(&root, "tool_input")
	raw, _ = json.marshal(root)
	root["padding"] = json.String(strings.repeat("x", HOOK_INPUT_MAX-len(raw)-13))
	boundary, _ := json.marshal(root)
	testing.expect_value(t, len(boundary), HOOK_INPUT_MAX)
	metadata_free, at_cap := codex_map_hook(string(boundary), TS)
	testing.expect_value(t, at_cap, Codex_Error.None)
	testing.expect_value(t, len(metadata_free.events), 1)
	if len(metadata_free.events) == 1 {
		identity, _ := contracts.ext_parse_event(metadata_free.events[0])
		testing.expect_value(t, identity.tool_use_id, "exec-image-4")
		testing.expect_value(t, identity.kind, contracts.Ext_Event_Kind.Tool_End)
	}
	_, over_cap := codex_map_hook(strings.concatenate({string(boundary), " "}), TS)
	testing.expect_value(t, over_cap, Codex_Error.Too_Large)
}
