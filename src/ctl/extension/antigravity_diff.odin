package extension

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

// antigravity_diff_replace_content builds a unified diff for replace_file_content.
// TargetContent and ReplacementContent are formatted as removal and addition chunks.
// Anchored at start_line when start_line > 0.
antigravity_diff_replace_content :: proc(path, cwd, target_content, replacement_content: string, start_line: int) -> Diff_Result {
	if diff_is_binary(target_content) || diff_is_binary(replacement_content) do return {binary = true}
	if target_content == replacement_content do return {}
	old_name, new_name := diff_display_path(path, cwd)
	h := diff_string_edit_hunk("", Diff_String_Edit{old_string = target_content, new_string = replacement_content})
	if start_line > 0 {
		h.old_start = start_line
		h.new_start = start_line
	}
	hunks := []Diff_Hunk{h}
	return diff_render(old_name, new_name, hunks)
}

// antigravity_file_edit_event extracts file mutation details from write_to_file
// or replace_file_content in PostToolUse, and synthesises a file.edit event
// with a unified diff capped at contracts.EXT_DIFF_MAX_BYTES (64KB).
antigravity_file_edit_event :: proc(root: json.Object, ts: string) -> (string, bool) {
	tool_name := json_get_string(root, "tool_name")
	if tool_name != "write_to_file" && tool_name != "replace_file_content" do return "", false

	tool_call := json_get_object(root, "toolCall")
	if tool_call == nil do tool_call = json_get_object(root, "tool_call")
	args: json.Object
	if tool_call != nil {
		args = json_get_object(tool_call, "args")
	}
	if args == nil do args = json_get_object(root, "tool_input")
	if args == nil do args = json_get_object(root, "toolInput")
	if args == nil do args = json_get_object(root, "args")
	if args == nil do return "", false

	path := json_get_string(args, "TargetFile")
	if path == "" do path = json_get_string(args, "target_file")
	if path == "" do path = json_get_string(args, "file_path")
	if path == "" do path = json_get_string(args, "filePath")
	if path == "" do path = json_get_string(args, "path")
	if path == "" do return "", false

	cwd := json_get_string(root, "cwd")

	operation := "edit"
	source := "content"
	res: Diff_Result

	switch tool_name {
	case "write_to_file":
		content := json_get_string(args, "CodeContent")
		if content == "" do content = json_get_string(args, "code_content")
		if content == "" do content = json_get_string(args, "content")

		is_append := json_get_bool(args, "Append") || json_get_bool(args, "append")
		is_overwrite := json_get_bool(args, "Overwrite") || json_get_bool(args, "overwrite")

		if is_append {
			operation = "append"
		} else if is_overwrite {
			operation = "update"
		} else {
			operation = "create"
		}

		source = "content"
		res = diff_create(path, cwd, content)

	case "replace_file_content":
		operation = "edit"
		source = "strings"

		target_content := json_get_string(args, "TargetContent")
		if target_content == "" do target_content = json_get_string(args, "target_content")
		if target_content == "" do target_content = json_get_string(args, "old_string")
		if target_content == "" do target_content = json_get_string(args, "old_content")

		replacement_content := json_get_string(args, "ReplacementContent")
		if replacement_content == "" do replacement_content = json_get_string(args, "replacement_content")
		if replacement_content == "" do replacement_content = json_get_string(args, "new_string")
		if replacement_content == "" do replacement_content = json_get_string(args, "new_content")

		start_line := 0
		if sl, ok := json_get_int(args, "StartLine"); ok do start_line = sl
		else if sl2, ok2 := json_get_int(args, "start_line"); ok2 do start_line = sl2

		res = antigravity_diff_replace_content(path, cwd, target_content, replacement_content, start_line)
	}

	p := pb_make()
	pb_str(&p, "file_path", path)
	pb_str(&p, "operation", operation)
	pb_str(&p, "diff", res.diff)
	pb_str(&p, "diff_source", source)
	pb_int(&p, "additions", res.additions)
	pb_int(&p, "deletions", res.deletions)
	if res.truncated do pb_bool(&p, "diff_truncated", true)
	if res.binary do pb_bool(&p, "binary", true)
	eb := ext_event_begin("file.edit", ts, root, ANTIGRAVITY_PROVIDER, ANTIGRAVITY_EXT_VERSION)
	ext_event_tool(&eb, root, nil, nil)
	return ext_event_end(&eb, pb_done(&p)), true
}
