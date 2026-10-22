package extension

import json "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_codex_patch_parser_confirms_whole_result_and_preserves_known_snippets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	patch := "*** Begin Patch\n*** Add File: a.txt\n+α\n+\n*** Update File: b.txt\n*** Move to: c.txt\n@@ anchor\n-old\n+new\n*** Delete File: d.txt\n*** End Patch\n"
	edits, ok := codex_parse_patch(patch)
	testing.expect(t, ok)
	testing.expect_value(t, len(edits), 3)
	if len(edits) != 3 do return
	testing.expect_value(t, edits[0].content, "α\n\n")
	testing.expect_value(t, edits[1].old_path, "b.txt")
	testing.expect_value(t, edits[1].path, "c.txt")
	success :: "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nA a.txt\nM c.txt\nD d.txt\n"
	testing.expect(t, codex_patch_confirmed(edits[:], success))
	for response in ([]string{"", "Success. Updated the following files:\nA a.txt\n", "Exit code: 1\n"+success, success[:len(success)-3], success+"M extra.txt\n"}) {
		testing.expect(t, !codex_patch_confirmed(edits[:], response), response)
	}
	crlf, _ := strings.replace_all(patch, "\n", "\r\n")
	crlf_edits, crlf_ok := codex_parse_patch(crlf)
	testing.expect(t, crlf_ok)
	testing.expect_value(t, len(crlf_edits), 3)
}

@(test)
test_codex_patch_rejects_malformed_binary_duplicate_and_unbounded_inputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for patch in ([]string{"", "*** Begin Patch\n*** End Patch", "*** Begin Patch\n*** Delete File: a\n+bad\n*** End Patch",
		"*** Begin Patch\n*** Update File: a\n-old\n+new\n*** End Patch",
		"*** Begin Patch\n*** Add File: a\n+x\n*** Add File: a\n+y\n*** End Patch",
		"*** Begin Patch\n*** Add File: a\n+\x00\n*** End Patch",
		"*** Begin Patch\n*** Update File: a\n@@\n*** End Patch",
		"*** Begin Patch\n*** Add File: a\n+x\n*** End Patch\ntrailer"}) {
		_, ok := codex_parse_patch(patch)
		testing.expect(t, !ok, patch)
	}
	_, ok := codex_parse_patch(strings.repeat("x", CODEX_HOOK_INPUT_MAX+1))
	testing.expect(t, !ok)
	b := strings.builder_make()
	strings.write_string(&b, "*** Begin Patch\n")
	for i in 0..<CODEX_PATCH_MAX_FILES+1 {
		strings.write_string(&b, "*** Add File: ")
		// Distinct paths; exercise the file-count cap, not duplicate rejection.
		for _ in 0..<i+1 do strings.write_byte(&b, 'a')
		strings.write_string(&b, "\n+x\n")
	}
	strings.write_string(&b, "*** End Patch")
	_, ok = codex_parse_patch(strings.to_string(b))
	testing.expect(t, !ok)
}

@(test)
test_codex_delete_has_no_fabricated_preimage :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	root := make(json.Object)
	input := make(json.Object)
	root["session_id"] = json.String("s")
	root["tool_name"] = json.String("apply_patch")
	input["command"] = json.String("*** Begin Patch\n*** Delete File: gone.txt\n*** End Patch")
	root["tool_input"] = input
	root["tool_response"] = json.String("Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nD gone.txt\n")
	events := codex_patch_events(root, TS)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect(t, strings.contains(events[0], `"diff":""`))
		testing.expect(t, strings.contains(events[0], `"partial":true`))
		testing.expect(t, strings.contains(events[0], `"diff_unavailable_reason"`))
	}
}
