package extension

// Unified diffs for file.edit events (REQ-EXT-FILE-1).
//
// ham-ctl stays stateless: Claude Code (2.1.x) already hands PostToolUse the
// post-image hunks in tool_response.structuredPatch, so no pre-image snapshot is
// taken at PreToolUse. The fallbacks below cover payloads without a patch:
//   1. structuredPatch hunks               → rendered verbatim (authoritative)
//   2. Write create (no original)          → all-added diff from content
//   3. original + new full text            → one whole-file replace hunk
//   4. old_string/new_string (Edit, edits) → one hunk per edit, located in the
//                                            original when it is known
// Every result is capped at contracts.EXT_DIFF_MAX_BYTES and binary content
// (a NUL byte) is reported as binary with no diff body.
//
// All procs allocate with context.allocator; callers in ctl run them inside the
// temp arena of a one-shot process.

import "core:strings"
import "core:fmt"
import contracts "odin_test:contracts"

Diff_Hunk :: struct {
	old_start, old_lines: int,
	new_start, new_lines: int,
	lines:                []string, // each prefixed with ' ', '-', '+' or '\'
}

Diff_Result :: struct {
	diff:      string,
	additions: int,
	deletions: int,
	truncated: bool,
	binary:    bool,
}

diff_is_binary :: proc(s: string) -> bool {
	return strings.index_byte(s, 0) >= 0
}

// diff_display_path renders a file path for the ---/+++ headers: relative to cwd
// (with the conventional a/ b/ prefixes) when the file lives under it.
diff_display_path :: proc(path, cwd: string) -> (old_name, new_name: string) {
	rel := path
	if cwd != "" {
		root := strings.trim_right(cwd, "/")
		if strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/' {
			rel = path[len(root) + 1:]
			return strings.concatenate({"a/", rel}), strings.concatenate({"b/", rel})
		}
	}
	return rel, rel
}

// diff_split_lines splits text into lines without their terminators and reports
// whether the final line lacks a trailing newline.
diff_split_lines :: proc(text: string) -> (lines: [dynamic]string, no_final_newline: bool) {
	if text == "" do return lines, false
	rest := text
	for {
		i := strings.index_byte(rest, '\n')
		if i < 0 {
			append(&lines, rest)
			return lines, true
		}
		append(&lines, rest[:i])
		rest = rest[i + 1:]
		if rest == "" do return lines, false
	}
}

@(private = "file")
NO_NEWLINE_MARKER :: "\\ No newline at end of file"

@(private = "file")
diff_hunk_range :: proc(b: ^strings.Builder, start, count: int) {
	// Unified-diff convention: an empty range names the line BEFORE it.
	s := start
	if count == 0 && s > 0 do s -= 1
	fmt.sbprintf(b, "%d,%d", s, count)
}

// diff_render writes a unified diff for hunks, counts +/- lines and applies the
// size cap. An empty hunk list yields an empty diff.
diff_render :: proc(old_name, new_name: string, hunks: []Diff_Hunk) -> (res: Diff_Result) {
	if len(hunks) == 0 do return res
	b := strings.builder_make()
	fmt.sbprintf(&b, "--- %s\n+++ %s\n", old_name, new_name)
	for h in hunks {
		strings.write_string(&b, "@@ -")
		diff_hunk_range(&b, h.old_start, h.old_lines)
		strings.write_string(&b, " +")
		diff_hunk_range(&b, h.new_start, h.new_lines)
		strings.write_string(&b, " @@\n")
		for line in h.lines {
			if len(line) > 0 {
				switch line[0] {
				case '+': res.additions += 1
				case '-': res.deletions += 1
				}
			}
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	res.diff, res.truncated = contracts.ext_truncate_diff(strings.to_string(b))
	return res
}

@(private = "file")
diff_append_text_lines :: proc(out: ^[dynamic]string, prefix: string, text: string, mark_eof := true) -> int {
	lines, no_nl := diff_split_lines(text)
	for l in lines do append(out, strings.concatenate({prefix, l}))
	if no_nl && mark_eof do append(out, NO_NEWLINE_MARKER)
	return len(lines)
}

// diff_create is the all-added diff of a newly created file.
diff_create :: proc(path, cwd, content: string) -> Diff_Result {
	if diff_is_binary(content) do return {binary = true}
	_, new_name := diff_display_path(path, cwd)
	lines := make([dynamic]string)
	n := diff_append_text_lines(&lines, "+", content)
	if n == 0 do return {}
	hunks := []Diff_Hunk{{old_start = 0, old_lines = 0, new_start = 1, new_lines = n, lines = lines[:]}}
	return diff_render("/dev/null", new_name, hunks)
}

// diff_replace_whole is a single hunk replacing every line of old_text with
// new_text (used when only the full before/after texts are known).
diff_replace_whole :: proc(path, cwd, old_text, new_text: string) -> Diff_Result {
	if old_text == new_text do return {}
	if diff_is_binary(old_text) || diff_is_binary(new_text) do return {binary = true}
	old_name, new_name := diff_display_path(path, cwd)
	lines := make([dynamic]string)
	n_old := diff_append_text_lines(&lines, "-", old_text)
	n_new := diff_append_text_lines(&lines, "+", new_text)
	hunks := []Diff_Hunk{{old_start = 1, old_lines = n_old, new_start = 1, new_lines = n_new, lines = lines[:]}}
	return diff_render(old_name, new_name, hunks)
}

Diff_String_Edit :: struct {
	old_string: string,
	new_string: string,
}

// diff_string_edit_hunk builds the hunk for one old_string → new_string edit. When
// original is known and contains old_string, the hunk is widened to whole lines
// and anchored at its real line number; otherwise it starts at line 1 and shows
// the bare strings.
diff_string_edit_hunk :: proc(original: string, e: Diff_String_Edit) -> (h: Diff_Hunk) {
	old_text, new_text := e.old_string, e.new_string
	start := 1
	// Bare fragments are not file ends: no "\ No newline" markers for them.
	anchored := false
	if original != "" && e.old_string != "" {
		if idx := strings.index(original, e.old_string); idx >= 0 {
			line_begin := idx
			for line_begin > 0 && original[line_begin - 1] != '\n' do line_begin -= 1
			end := idx + len(e.old_string)
			line_end := end
			for line_end < len(original) && original[line_end] != '\n' do line_end += 1
			if line_end < len(original) do line_end += 1 // keep the newline
			start = strings.count(original[:line_begin], "\n") + 1
			old_text = original[line_begin:line_end]
			new_text = strings.concatenate({original[line_begin:idx], e.new_string, original[end:line_end]})
			anchored = true
		}
	}
	lines := make([dynamic]string)
	h.old_lines = diff_append_text_lines(&lines, "-", old_text, anchored)
	h.new_lines = diff_append_text_lines(&lines, "+", new_text, anchored)
	h.old_start = start
	h.new_start = start
	h.lines = lines[:]
	return h
}

// diff_string_edits renders Edit / MultiEdit edits without a structured patch.
diff_string_edits :: proc(path, cwd, original: string, edits: []Diff_String_Edit) -> Diff_Result {
	if diff_is_binary(original) do return {binary = true}
	for e in edits {
		if diff_is_binary(e.old_string) || diff_is_binary(e.new_string) do return {binary = true}
	}
	old_name, new_name := diff_display_path(path, cwd)
	hunks := make([dynamic]Diff_Hunk)
	for e in edits {
		if e.old_string == e.new_string do continue
		append(&hunks, diff_string_edit_hunk(original, e))
	}
	return diff_render(old_name, new_name, hunks[:])
}

// diff_structured renders Claude's structuredPatch hunks.
diff_structured :: proc(path, cwd: string, hunks: []Diff_Hunk) -> Diff_Result {
	for h in hunks {
		for l in h.lines do if diff_is_binary(l) do return {binary = true}
	}
	old_name, new_name := diff_display_path(path, cwd)
	return diff_render(old_name, new_name, hunks)
}
