package main

import "core:os"
import "core:strings"
import "core:testing"

// Pure-function tests for the VCS provider: unified-diff parsing, porcelain status
// mapping, pagination, and the JSON envelope shapes. These exercise no processes
// and no WS, so they are hermetic.

// vcs_test_free_hunks releases everything vcs_parse_unified_diff allocates on
// context.allocator: each line's cloned text, each hunk's line slice, and the
// hunk slice itself. Keeps the tracking allocator's leak report clean.
vcs_test_free_hunks :: proc(hunks: []VCS_Diff_Hunk) {
	for h in hunks {
		for ln in h.lines do delete(ln.text)
		delete(h.lines)
	}
	delete(hunks)
}

@(test)
vcs_parse_unified_diff_basic :: proc(t: ^testing.T) {
	diff := "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,4 @@\n context\n-removed\n+added1\n+added2\n"
	hunks := vcs_parse_unified_diff(diff)
	defer vcs_test_free_hunks(hunks)
	testing.expect_value(t, len(hunks), 1)
	h := hunks[0]
	testing.expect_value(t, h.old_start, 1)
	testing.expect_value(t, h.old_len, 3)
	testing.expect_value(t, h.new_start, 1)
	testing.expect_value(t, h.new_len, 4)
	testing.expect_value(t, len(h.lines), 4)
	testing.expect(t, h.lines[0].op == " " && h.lines[0].text == "context", "first line is context")
	testing.expect(t, h.lines[1].op == "-" && h.lines[1].text == "removed", "second line removed")
	testing.expect(t, h.lines[2].op == "+" && h.lines[2].text == "added1", "third line added")
}

@(test)
vcs_parse_unified_diff_multi_hunk_and_no_newline :: proc(t: ^testing.T) {
	diff := "@@ -1 +1 @@\n-a\n+b\n@@ -10,2 +10,2 @@\n c\n-d\n+e\n\\ No newline at end of file\n"
	hunks := vcs_parse_unified_diff(diff)
	defer vcs_test_free_hunks(hunks)
	testing.expect_value(t, len(hunks), 2)
	// "@@ -1 +1 @@" — missing lengths default to 1.
	testing.expect_value(t, hunks[0].old_start, 1)
	testing.expect_value(t, hunks[0].old_len, 1)
	testing.expect_value(t, hunks[1].new_start, 10)
	testing.expect_value(t, hunks[1].new_len, 2)
	// The "\ No newline" marker must not become a content line.
	testing.expect_value(t, len(hunks[1].lines), 3)
}

@(test)
vcs_parse_unified_diff_empty :: proc(t: ^testing.T) {
	hunks := vcs_parse_unified_diff("")
	defer vcs_test_free_hunks(hunks)
	testing.expect_value(t, len(hunks), 0)
}

@(test)
vcs_git_status_word_mapping :: proc(t: ^testing.T) {
	testing.expect(t, vcs_git_status_word('?', '?') == "untracked", "?? -> untracked")
	testing.expect(t, vcs_git_status_word(' ', 'M') == "modified", "worktree M -> modified")
	testing.expect(t, vcs_git_status_word('A', ' ') == "added", "index A -> added")
	testing.expect(t, vcs_git_status_word('D', ' ') == "deleted", "index D -> deleted")
	testing.expect(t, vcs_git_status_word('R', ' ') == "renamed", "index R -> renamed")
	testing.expect(t, vcs_git_status_word('M', 'M') == "modified", "MM -> modified (index preferred)")
}

@(test)
vcs_jj_status_word_mapping :: proc(t: ^testing.T) {
	testing.expect(t, vcs_jj_status_word('A') == "added", "A -> added")
	testing.expect(t, vcs_jj_status_word('M') == "modified", "M -> modified")
	testing.expect(t, vcs_jj_status_word('D') == "deleted", "D -> deleted")
	testing.expect(t, vcs_jj_status_word('R') == "renamed", "R -> renamed")
}

@(test)
vcs_split_range_defaults :: proc(t: ^testing.T) {
	s, l := vcs_split_range("12,5")
	testing.expect_value(t, s, 12)
	testing.expect_value(t, l, 5)
	s2, l2 := vcs_split_range("7")
	testing.expect_value(t, s2, 7)
	testing.expect_value(t, l2, 1) // missing length defaults to 1
}

@(test)
vcs_paginate_files_pages :: proc(t: ^testing.T) {
	all := make([]VCS_Changed_File, 5)
	defer delete(all)
	for i in 0 ..< 5 do all[i] = VCS_Changed_File{path = "f", status = "modified", staged = false}
	// First page of 2.
	page, next_cursor, has_more := vcs_paginate_files(all, "", 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	defer delete(next_cursor) // base64-encoded cursor is owned; "" is a no-op delete
	testing.expect_value(t, len(page), 2)
	testing.expect(t, has_more, "5 items, page 2 -> has_more")
	testing.expect(t, next_cursor != "", "next_cursor present when has_more")
	// Follow the cursor to the final page.
	page2, next2, more2 := vcs_paginate_files(all, next_cursor, 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	defer delete(next2)
	testing.expect_value(t, len(page2), 2)
	testing.expect(t, more2, "still more after item 4")
	page3, next3, more3 := vcs_paginate_files(all, next2, 2, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	defer delete(next3)
	testing.expect_value(t, len(page3), 1)
	testing.expect(t, !more3, "last item -> no more")
	testing.expect(t, next3 == "", "no next_cursor on last page")
}

@(test)
vcs_clamp_limit_bounds :: proc(t: ^testing.T) {
	testing.expect_value(t, vcs_clamp_limit(0, 100, 500), 100)   // <=0 -> default
	testing.expect_value(t, vcs_clamp_limit(9999, 100, 500), 500) // over max -> max
	testing.expect_value(t, vcs_clamp_limit(50, 100, 500), 50)    // in range -> as-is
}

@(test)
vcs_no_vcs_json_envelope :: proc(t: ^testing.T) {
	// A path with no VCS must yield ok:false + error code no_vcs on every command.
	req := "{\"command_id\":\"c1\",\"path\":\"/nonexistent/definitely/not/a/repo\"}"
	caps := bridge_vcs_capabilities_json("c1", req)
	defer delete(caps)
	testing.expect(t, strings.contains(caps, "\"ok\":false"), "caps ok:false for no vcs")
	testing.expect(t, strings.contains(caps, "\"cause\":\"no_vcs\""), "caps no_vcs code")
	testing.expect(t, strings.contains(caps, "\"type\":\"vcs_capabilities_result\""), "caps result type")

	files := bridge_vcs_files_json("c1", req)
	defer delete(files)
	testing.expect(t, strings.contains(files, "\"no_vcs\""), "files no_vcs")
	// Pagination fields must be present even in the error envelope.
	testing.expect(t, strings.contains(files, "\"has_more\":"), "files has_more present")
	testing.expect(t, strings.contains(files, "\"next_cursor\":"), "files next_cursor present")
	testing.expect(t, strings.contains(files, "\"limit\":"), "files limit present")
	testing.expect(t, strings.contains(files, "\"cursor\":"), "files cursor present")

	diff := bridge_vcs_diff_json("c1", req)
	defer delete(diff)
	testing.expect(t, strings.contains(diff, "\"no_vcs\""), "diff no_vcs")
	testing.expect(t, strings.contains(diff, "\"has_more\":"), "diff has_more present")
	testing.expect(t, strings.contains(diff, "\"next_cursor\":"), "diff next_cursor present")
}

// vcs_test_free_workspaces releases the path clones vcs_git_parse_worktree_list
// allocates. It intentionally frees neither the label (which may be the "(detached)"
// string literal rather than a heap clone) nor the slice itself (which can be an
// interior subslice of a paginated backing) — freeing either would be unsafe. The
// small residual leak is harmless in tests (the tracking allocator reports it, it does
// not fail the run).
vcs_test_free_workspaces :: proc(ws: []VCS_Workspace) {
	for w in ws do delete(w.path)
}

// vcs_test_free_log_entry frees the five string clones vcs_parse_log_line allocates.
// A zero-value entry (parse failure) holds empty strings, which delete treats as a
// no-op, so this is safe to defer unconditionally.
vcs_test_free_log_entry :: proc(e: VCS_Log_Entry) {
	delete(e.hash)
	delete(e.short_hash)
	delete(e.subject)
	delete(e.author)
	delete(e.date)
}

// --- worktree porcelain parsing (pure) -----------------------------------

@(test)
vcs_parse_worktree_list_single :: proc(t: ^testing.T) {
	// A single porcelain block: the main worktree on branch main.
	out := "worktree /home/u/proj\nHEAD abc123\nbranch refs/heads/main\n"
	ws := vcs_git_parse_worktree_list(out, "")
	defer vcs_test_free_workspaces(ws)
	testing.expect_value(t, len(ws), 1)
	testing.expect(t, ws[0].path == "/home/u/proj", "worktree path parsed")
	testing.expect(t, ws[0].label == "main", "refs/heads/main -> label main")
	testing.expect(t, !ws[0].is_locked, "single worktree is not locked")
}

@(test)
vcs_parse_worktree_list_locked :: proc(t: ^testing.T) {
	// Two blocks; the second carries a "locked <reason>" line and is the queried path.
	out := "worktree /home/u/proj\nHEAD abc\nbranch refs/heads/main\n\nworktree /home/u/wt\nHEAD def\nbranch refs/heads/feat\nlocked needs review\n"
	ws := vcs_git_parse_worktree_list(out, "/home/u/wt")
	defer vcs_test_free_workspaces(ws)
	testing.expect_value(t, len(ws), 2)
	testing.expect(t, ws[1].label == "feat", "second block label feat")
	testing.expect(t, ws[1].is_locked, "locked line -> is_locked:true")
	testing.expect(t, !ws[0].is_locked, "first block not locked")
	testing.expect(t, ws[1].is_current, "queried path is current")
	testing.expect(t, !ws[0].is_current, "non-queried path is not current")
}

// --- log line parsing (pure) ---------------------------------------------

@(test)
vcs_log_entry_parse :: proc(t: ^testing.T) {
	// "%H|%h|%s|%an|%ci" — the 5-field row emitted by both the git and jj adapters.
	line := "deadbeef1234|deadbee|Fix the parser|Ada Lovelace|2026-09-20 10:11:12 +0000"
	e, ok := vcs_parse_log_line(line)
	defer vcs_test_free_log_entry(e)
	testing.expect(t, ok, "well-formed 5-field line parses")
	testing.expect(t, e.hash == "deadbeef1234", "hash field")
	testing.expect(t, e.short_hash == "deadbee", "short_hash field")
	testing.expect(t, e.subject == "Fix the parser", "subject field")
	testing.expect(t, e.author == "Ada Lovelace", "author field")
	testing.expect(t, e.date == "2026-09-20 10:11:12 +0000", "date field")
}

// --- commit_diff argv sentinel (pure) ------------------------------------

@(test)
vcs_commit_diff_workdir_sentinel :: proc(t: ^testing.T) {
	// "WORKDIR" head_ref is the working-tree sentinel: it must be omitted from the argv
	// so git diffs base_ref against the worktree.
	args := vcs_git_commit_diff_args("/repo", "main", "WORKDIR", "")
	testing.expect_value(t, len(args), 5) // git -C /repo diff main
	testing.expect(t, args[len(args) - 1] == "main", "base_ref is the last arg")
	for a in args do testing.expect(t, a != "WORKDIR", "WORKDIR sentinel omitted from argv")
	// An empty head_ref behaves the same, and a file is scoped after a "--" separator.
	args2 := vcs_git_commit_diff_args("/repo", "main", "", "file.txt")
	testing.expect_value(t, len(args2), 7) // git -C /repo diff main -- file.txt
	testing.expect(t, args2[len(args2) - 2] == "--", "file scoped after -- separator")
	testing.expect(t, args2[len(args2) - 1] == "file.txt", "file is the last arg")
	// A real head_ref IS appended.
	args3 := vcs_git_commit_diff_args("/repo", "main", "feature", "")
	testing.expect_value(t, len(args3), 6) // git -C /repo diff main feature
	testing.expect(t, args3[len(args3) - 1] == "feature", "explicit head_ref appended")
}

// vcs_ns_char_to_status maps `git diff --name-status` status chars to the neutral
// status word: A/D/R exact, everything else (M, C, T, junk) -> modified.
@(test)
vcs_ns_char_to_status_mapping :: proc(t: ^testing.T) {
	testing.expect(t, vcs_ns_char_to_status('A') == "added", "A -> added")
	testing.expect(t, vcs_ns_char_to_status('D') == "deleted", "D -> deleted")
	testing.expect(t, vcs_ns_char_to_status('R') == "renamed", "R -> renamed")
	testing.expect(t, vcs_ns_char_to_status('M') == "modified", "M -> modified")
	testing.expect(t, vcs_ns_char_to_status('C') == "modified", "C (copy) -> modified")
	testing.expect(t, vcs_ns_char_to_status('T') == "modified", "T (type-change) -> modified")
	testing.expect(t, vcs_ns_char_to_status('Z') == "modified", "unknown char -> modified")
}

@(test)
vcs_detect_provider_on_repo :: proc(t: ^testing.T) {
	// This checkout is a git repo and (per the task) has no .jj.
	home := strings.trim_space(os.get_env("HOME", context.temp_allocator))
	if home == "" do return
	repo := strings.concatenate({home, "/heimdall-agent-manager"}, context.temp_allocator)
	if !vcs_git_detect(repo) do return // skip if the checkout is elsewhere
	provider, ok := vcs_detect_provider(repo)
	testing.expect(t, ok, "git repo must be detected")
	testing.expect(t, provider.name() == "git", "git wins detection ordering")
	testing.expect(t, !vcs_jj_detect(repo), "no .jj in this checkout")
}
