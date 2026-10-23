package extension

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_diff_create_with_and_without_trailing_newline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	r := diff_create("/w/src/a.go", "/w", "one\ntwo\n")
	testing.expect_value(t, r.diff, "--- /dev/null\n+++ b/src/a.go\n@@ -0,0 +1,2 @@\n+one\n+two\n")
	testing.expect_value(t, r.additions, 2)
	testing.expect_value(t, r.deletions, 0)
	r2 := diff_create("/w/a", "/w", "one")
	testing.expect_value(t, r2.diff, "--- /dev/null\n+++ b/a\n@@ -0,0 +1,1 @@\n+one\n\\ No newline at end of file\n")
	testing.expect_value(t, diff_create("/w/empty", "/w", "").diff, "")
}

@(test)
test_diff_display_path_outside_cwd_is_absolute :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	o, n := diff_display_path("/etc/hosts", "/w")
	testing.expect_value(t, o, "/etc/hosts")
	testing.expect_value(t, n, "/etc/hosts")
	o2, n2 := diff_display_path("/w2/x", "/w") // a sibling prefix is not "under"
	testing.expect_value(t, o2, "/w2/x")
	testing.expect_value(t, n2, "/w2/x")
	o3, _ := diff_display_path("/w/x", "/w/")
	testing.expect_value(t, o3, "a/x")
}

@(test)
test_diff_string_edit_is_anchored_to_whole_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	original := "a\nfoo = 1\nb\n"
	r := diff_string_edits("/w/f", "/w", original, {{"= 1", "= 2"}})
	testing.expect_value(t, r.diff, "--- a/f\n+++ b/f\n@@ -2,1 +2,1 @@\n-foo = 1\n+foo = 2\n")
	// Without the original the bare strings are shown from line 1.
	r2 := diff_string_edits("/w/f", "/w", "", {{"x\ny", "z"}})
	testing.expect_value(t, r2.diff, "--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n-x\n-y\n+z\n")
	// Pure insertion of new lines at the end of an existing line.
	r3 := diff_string_edits("/w/f", "/w", "a\nb\n", {{"b\n", "b\nc\n"}})
	testing.expect_value(t, r3.diff, "--- a/f\n+++ b/f\n@@ -2,1 +2,2 @@\n-b\n+b\n+c\n")
	// No-op edits produce no diff.
	testing.expect_value(t, diff_string_edits("/w/f", "/w", "a", {{"a", "a"}}).diff, "")
}

@(test)
test_diff_replace_whole :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	r := diff_replace_whole("/w/f", "/w", "old\n", "new\nmore\n")
	testing.expect_value(t, r.diff, "--- a/f\n+++ b/f\n@@ -1,1 +1,2 @@\n-old\n+new\n+more\n")
	testing.expect_value(t, diff_replace_whole("/w/f", "/w", "same", "same").diff, "")
	// Emptying a file: the new range is empty and names line 0.
	r2 := diff_replace_whole("/w/f", "/w", "x\n", "")
	testing.expect_value(t, r2.diff, "--- a/f\n+++ b/f\n@@ -1,1 +0,0 @@\n-x\n")
}

@(test)
test_diff_binary_content_is_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	bin := "PNG\x00\x01\x02"
	r := diff_create("/w/i.png", "/w", bin)
	testing.expect(t, r.binary)
	testing.expect_value(t, r.diff, "")
	testing.expect(t, diff_replace_whole("/w/i.png", "/w", bin, "x").binary)
	testing.expect(t, diff_string_edits("/w/i.png", "/w", bin, {{"P", "Q"}}).binary)
	hunks := []Diff_Hunk{{1, 1, 1, 1, {"-a\x00", "+b"}}}
	testing.expect(t, diff_structured("/w/i.png", "/w", hunks).binary)
}

@(test)
test_diff_is_capped_at_64kb_with_marker :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	content := strings.repeat("0123456789abcdef\n", 10_000) // ~170KB
	r := diff_create("/w/big", "/w", content)
	testing.expect(t, r.truncated)
	testing.expect(t, len(r.diff) <= contracts.EXT_DIFF_MAX_BYTES + len(contracts.EXT_TRUNCATED_MARKER))
	testing.expect(t, strings.has_suffix(r.diff, contracts.EXT_TRUNCATED_MARKER))
	testing.expect_value(t, r.additions, 10_000) // counts are of the full diff
	small := diff_create("/w/s", "/w", "x\n")
	testing.expect(t, !small.truncated)
}

@(test)
test_diff_structured_patch_rendering_counts_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	hunks := []Diff_Hunk{
		{old_start = 1, old_lines = 2, new_start = 1, new_lines = 1, lines = {" keep", "-gone"}},
		{old_start = 10, old_lines = 0, new_start = 9, new_lines = 1, lines = {"+added"}},
	}
	r := diff_structured("/w/f", "/w", hunks)
	testing.expect_value(t, r.diff, "--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n keep\n-gone\n@@ -9,0 +9,1 @@\n+added\n")
	testing.expect_value(t, r.additions, 1)
	testing.expect_value(t, r.deletions, 1)
}
