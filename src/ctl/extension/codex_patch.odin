package extension

// Confirmed apply_patch operations. The callback does not contain deleted
// preimages or update hunk offsets: retain partial snippets without inventing
// either. No snapshots are read from disk. Failed/partial/truncated responses
// cannot confirm any operation.

import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

CODEX_PATCH_MAX_FILES :: 32
Codex_Patch_Edit :: struct {
	path, old_path, operation: string,
	lines: [dynamic]string,
	content: string,
}

codex_patch_path_valid :: proc(path: string) -> bool {
	if path == "" || len(path) > 4096 do return false
	for c in path do if c < 32 || c == 127 do return false
	return true
}

codex_parse_patch :: proc(raw: string) -> (edits: [dynamic]Codex_Patch_Edit, ok: bool) {
	if len(raw) > CODEX_HOOK_INPUT_MAX || diff_is_binary(raw) do return nil, false
	normalized, _ := strings.replace_all(raw, "\r\n", "\n")
	lines, _ := diff_split_lines(normalized)
	if len(lines) < 2 || lines[0] != "*** Begin Patch" || lines[len(lines)-1] != "*** End Patch" do return nil, false
	i := 1
	for i < len(lines)-1 {
		e: Codex_Patch_Edit
		head := lines[i]
		switch {
		case strings.has_prefix(head, "*** Add File: "):
			e.operation = "create"; e.path = head[len("*** Add File: "):]
		case strings.has_prefix(head, "*** Update File: "):
			e.operation = "update"; e.path = head[len("*** Update File: "):]
		case strings.has_prefix(head, "*** Delete File: "):
			e.operation = "delete"; e.path = head[len("*** Delete File: "):]
		case:
			return nil, false
		}
		if !codex_patch_path_valid(e.path) || len(edits) >= CODEX_PATCH_MAX_FILES do return nil, false
		i += 1
		if e.operation == "update" && i < len(lines)-1 && strings.has_prefix(lines[i], "*** Move to: ") {
			e.old_path = e.path
			e.path = lines[i][len("*** Move to: "):]
			e.operation = "move"
			if !codex_patch_path_valid(e.path) || e.path == e.old_path do return nil, false
			i += 1
		}
		content := strings.builder_make()
		saw_hunk, saw_line := false, false
		for i < len(lines)-1 && !strings.has_prefix(lines[i], "*** Add File: ") &&
				!strings.has_prefix(lines[i], "*** Update File: ") && !strings.has_prefix(lines[i], "*** Delete File: ") {
			line := lines[i]
			i += 1
			if e.operation == "delete" do return nil, false
			if e.operation == "create" {
				if len(line) == 0 || line[0] != '+' do return nil, false
				strings.write_string(&content, line[1:]); strings.write_byte(&content, '\n')
			} else {
				if line == "@@" || strings.has_prefix(line, "@@ ") {
					if saw_hunk && !saw_line do return nil, false
					saw_hunk = true; saw_line = false
					// Preserve the native anchor, never manufacture line numbers.
					append(&e.lines, line)
				} else if line == "*** End of File" {
					if !saw_hunk || !saw_line || i < len(lines)-1 && !strings.has_prefix(lines[i], "*** ") do return nil, false
					append(&e.lines, line)
				} else {
					if len(line) == 0 || (line[0] != '+' && line[0] != '-' && line[0] != ' ') do return nil, false
					// Native 0.162.0 permits an initial chunk without an @@ anchor.
					// Its offsets remain unknown, just like explicitly anchored chunks.
					saw_hunk = true
					saw_line = true
					append(&e.lines, line)
				}
			}
		}
		if (e.operation == "update" || e.operation == "move") && (!saw_hunk || !saw_line) do return nil, false
		e.content = strings.to_string(content)
		for prior in edits {
			if e.path == prior.path || e.path == prior.old_path || e.old_path != "" && (e.old_path == prior.path || e.old_path == prior.old_path) do return nil, false
		}
		append(&edits, e)
	}
	return edits, len(edits) > 0
}

codex_patch_confirmed :: proc(edits: []Codex_Patch_Edit, response: string) -> bool {
	if len(edits) == 0 || !strings.has_prefix(response, "Exit code: 0\nWall time: ") do return false
	marker :: "\nOutput:\nSuccess. Updated the following files:\n"
	at := strings.index(response, marker)
	if at < 0 do return false
	expected := strings.builder_make()
	// Native print_summary groups added, modified (including moved), then
	// deleted paths, preserving input order within each group.
	for op in ([]string{"A ", "M ", "D "}) {
		for e in edits {
			edit_op := "A " if e.operation == "create" else "D " if e.operation == "delete" else "M "
			if edit_op != op do continue
			strings.write_string(&expected, op); strings.write_string(&expected, e.path); strings.write_byte(&expected, '\n')
		}
	}
	// Exact complete per-path confirmation: no partial or extra operations.
	return response[at+len(marker):] == strings.to_string(expected)
}

codex_patch_events :: proc(root: json.Object, ts: string) -> (events: [dynamic]string) {
	edits, ok := codex_parse_patch(json_get_string(json_get_object(root, "tool_input"), "command"))
	if !ok || !codex_patch_confirmed(edits[:], json_get_string(root, "tool_response")) do return
	cwd := json_get_string(root, "cwd")
	for e in edits {
		p := pb_make()
		pb_str(&p, "file_path", e.path)
		pb_str(&p, "operation", e.operation)
		pb_str_nonempty(&p, "old_path", e.old_path)
		pb_str(&p, "provenance", "confirmed_apply_patch")
		pb_bool(&p, "partial", e.operation != "create")
		pb_bool(&p, "line_offsets_known", e.operation == "create")
		result: Diff_Result
		if e.operation == "create" {
			result = diff_create(e.path, cwd, e.content)
		} else if e.operation != "delete" {
			b := strings.builder_make()
			old_name, _ := diff_display_path(e.old_path if e.old_path != "" else e.path, cwd)
			_, new_name := diff_display_path(e.path, cwd)
			strings.write_string(&b, "--- "); strings.write_string(&b, old_name)
			strings.write_string(&b, "\n+++ "); strings.write_string(&b, new_name); strings.write_byte(&b, '\n')
			for line in e.lines {
				strings.write_string(&b, line); strings.write_byte(&b, '\n')
				if strings.has_prefix(line, "+") do result.additions += 1
				if strings.has_prefix(line, "-") do result.deletions += 1
			}
			result.diff, result.truncated = contracts.ext_truncate_diff(strings.to_string(b))
		} else {
			pb_str(&p, "diff_unavailable_reason", "deleted preimage absent from callback")
		}
		pb_str(&p, "diff", result.diff)
		pb_int(&p, "additions", result.additions)
		pb_int(&p, "deletions", result.deletions)
		pb_bool(&p, "diff_truncated", result.truncated)
		eb := ext_event_begin("file.edit", ts, root, CODEX_PROVIDER, CODEX_EXT_VERSION)
		ext_event_tool(&eb, root, nil, nil)
		append(&events, ext_event_end(&eb, pb_done(&p)))
	}
	return
}
