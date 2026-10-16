package main

// Git adapter for the VCS provider interface (see vcs_provider.odin).
//
// Every operation shells out with `git -C <path> ...` via vcs_run (no shell), so
// no chdir and no global git state. Detection is a cheap os.exists(path/.git)
// probe. All commands fail soft: a missing upstream, no origin remote, or a
// non-git path degrade to empty/zero values rather than surfacing an error.

import "core:strings"

// Static-storage action whitelist so vcs_git_capabilities can hand out a slice with
// package lifetime (a slice of a proc-local composite literal would dangle).
vcs_git_actions := [12]string{"diff", "log", "commit_diff", "revert", "stage", "unstage", "workspaces", "amend", "sync", "upload", "push", "pull"}

// vcs_git_provider returns the git proc-table.
vcs_git_provider :: proc() -> VCS_Provider {
	return VCS_Provider{
		name            = vcs_git_name,
		detect          = vcs_git_detect,
		status          = vcs_git_status,
		changed_files   = vcs_git_changed_files,
		diff_file       = vcs_git_diff_file,
		capabilities    = vcs_git_capabilities,
		stage_file      = vcs_git_stage_file,
		unstage_file    = vcs_git_unstage_file,
		revert_file     = vcs_git_revert_file,
		save_file       = vcs_git_save_file,
		log               = vcs_git_log,
		commit_diff       = vcs_git_commit_diff,
		commit_diff_files = vcs_git_commit_diff_files,
		commit            = vcs_git_commit,
		upload            = vcs_git_push,
		sync              = vcs_git_sync,
		list_workspaces   = vcs_git_list_workspaces,
	}
}

vcs_git_name :: proc() -> string {
	return "git"
}

// vcs_git_detect reports whether `path` is a git working tree (has a .git entry —
// a directory for a normal repo, a file for a worktree/submodule).
vcs_git_detect :: proc(path: string) -> bool {
	return vcs_dir_exists(path, ".git")
}

vcs_git_capabilities :: proc(path: string) -> VCS_Capabilities {
	return VCS_Capabilities{
		provider          = "git",
		supports_staging  = true,
		staging_model     = "index",
		commit_model      = "branch",
		supports_amend    = true,
		supports_upload   = true,
		supports_sync     = true,
		upload_label      = "Push",
		sync_label        = "Pull",
		supported_actions = vcs_git_actions[:],
	}
}

// vcs_git_status collects branch, origin remote, ahead/behind vs upstream, and the
// clean flag. ok=false only when the repo could not be inspected at all (git
// status itself failed); individual sub-queries degrade to empty/zero.
vcs_git_status :: proc(path: string) -> (VCS_Status, bool) {
	st := VCS_Status{provider = "git"}

	// is_clean: `git status --porcelain` empty. This is also our liveness probe —
	// if it fails, the path is not a usable git repo.
	porcelain, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
	if !ok do return st, false
	st.is_clean = strings.trim_space(porcelain) == ""

	if branch, bok := vcs_run([]string{"git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"}); bok {
		st.branch = strings.trim_space(branch)
	}
	if remote, rok := vcs_run([]string{"git", "-C", path, "remote", "get-url", "origin"}); rok {
		st.remote = strings.trim_space(remote)
	}
	if ahead, aok := vcs_run([]string{"git", "-C", path, "rev-list", "--count", "@{u}..HEAD"}); aok {
		st.ahead = vcs_atoi(strings.trim_space(ahead))
	}
	if behind, bok := vcs_run([]string{"git", "-C", path, "rev-list", "--count", "HEAD..@{u}"}); bok {
		st.behind = vcs_atoi(strings.trim_space(behind))
	}
	return st, true
}

// vcs_git_changed_files parses `git status --porcelain` into the neutral changed-
// file shape, joins per-file addition/deletion counts from `git diff --numstat`,
// then paginates (default 100, max 500).
vcs_git_changed_files :: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "status", "--porcelain"})
	if !ok do return nil, "", false, false

	// Per-file +/- counts. Unstaged edits show up in `diff HEAD` numstat; staged-
	// only changes need the `--cached HEAD` pass. A later entry wins on overlap,
	// but a path is normally only in one of the two sets.
	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "HEAD"})
	vcs_git_numstat_into(&stats, path, []string{"git", "-C", path, "diff", "--numstat", "--cached", "HEAD"})

	all := make([dynamic]VCS_Changed_File, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if len(line) < 4 do continue // "XY p" is the shortest meaningful record
		x := line[0]
		y := line[1]
		// Porcelain v1: index status, worktree status, a space, then the path at
		// column 3.
		raw_path := line[3:]
		// Renamed/copied records read "old -> new"; keep the destination path.
		if arrow := strings.index(raw_path, " -> "); arrow >= 0 {
			raw_path = raw_path[arrow + 4:]
		}
		status := vcs_git_status_word(x, y)
		// staged when the index column carries a real (non-space, non-untracked)
		// status.
		staged := x != ' ' && x != '?'
		clean_path := strings.clone(strings.trim_space(raw_path))
		// Untracked files never appear in numstat; they stay 0/0.
		counts := stats[clean_path] // zero value {0, 0} when absent
		append(&all, VCS_Changed_File{
			path      = clean_path,
			status    = status,
			staged    = staged,
			additions = counts[0],
			deletions = counts[1],
		})
	}
	page, next_cursor, has_more := vcs_paginate_files(all[:], cursor, limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_git_numstat_into runs a `git diff --numstat` argv and folds its per-file
// "<additions>\t<deletions>\t<path>" rows into `stats` (keyed by path). A binary
// file reports "-\t-\t<path>", which vcs_atoi maps to 0/0. Fails soft: a git
// error leaves `stats` untouched. Keys are temp-allocated (only read within the
// changed-files build, which allocates its cloned paths from the same lookup).
vcs_git_numstat_into :: proc(stats: ^map[string][2]int, repo: string, args: []string) {
	out, ok := vcs_run(args)
	if !ok do return
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if len(line) == 0 do continue
		// Tab-separated: additions, deletions, path.
		first := strings.index_byte(line, '\t')
		if first < 0 do continue
		rest := line[first + 1:]
		second := strings.index_byte(rest, '\t')
		if second < 0 do continue
		add_s := line[:first]
		del_s := rest[:second]
		file := strings.trim_space(rest[second + 1:])
		if file == "" do continue
		stats[file] = [2]int{vcs_atoi(add_s), vcs_atoi(del_s)}
	}
}

// vcs_git_status_word maps a porcelain (index, worktree) status pair to one of
// added|modified|deleted|renamed|untracked. Untracked ("??") wins; otherwise the
// index column is preferred, falling back to the worktree column.
vcs_git_status_word :: proc(x, y: u8) -> string {
	if x == '?' || y == '?' do return "untracked"
	code := x
	if code == ' ' do code = y
	switch code {
	case 'A': return "added"
	case 'M': return "modified"
	case 'D': return "deleted"
	case 'R': return "renamed"
	case 'C': return "added"    // copied — surfaced as an addition
	case 'T': return "modified" // type-change — closest neutral bucket
	case:     return "modified"
	}
}

// vcs_git_diff_file parses `git diff HEAD -- <file>` into hunks, then paginates
// (default 50, max 200).
vcs_git_diff_file :: proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "diff", "HEAD", "--", file})
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// --- write commands ------------------------------------------------------

// vcs_git_stage_file stages one path into the index (`git add -- <file>`).
vcs_git_stage_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	if _, rok := vcs_run([]string{"git", "-C", path, "add", "--", file}); !rok {
		return false, "stage_failed"
	}
	return true, ""
}

// vcs_git_unstage_file removes one path's staged changes. Normally
// `git restore --staged`, but on an initial commit there is no HEAD to restore
// from, so we detect that (rev-parse --verify HEAD fails) and fall back to
// `git rm --cached`, which simply drops the path from the index.
vcs_git_unstage_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	if _, hok := vcs_run([]string{"git", "-C", path, "rev-parse", "--verify", "HEAD"}); !hok {
		if _, rok := vcs_run([]string{"git", "-C", path, "rm", "--cached", "--", file}); !rok {
			return false, "unstage_failed"
		}
		return true, ""
	}
	if _, rok := vcs_run([]string{"git", "-C", path, "restore", "--staged", "--", file}); !rok {
		return false, "unstage_failed"
	}
	return true, ""
}

// vcs_git_revert_file discards a tracked file's working-tree changes
// (`git restore -- <file>`). An untracked file has no committed/indexed version to
// restore to, so `git restore` cannot revert it; we detect that up front
// (ls-files --error-unmatch exits non-zero for an untracked path) and report the
// distinct "untracked_file" code instead of a generic failure.
vcs_git_revert_file :: proc(path, file: string) -> (ok: bool, msg: string) {
	if _, tok := vcs_run([]string{"git", "-C", path, "ls-files", "--error-unmatch", "--", file}); !tok {
		return false, "untracked_file"
	}
	if _, rok := vcs_run([]string{"git", "-C", path, "restore", "--", file}); !rok {
		return false, "revert_failed"
	}
	return true, ""
}

// vcs_git_save_file writes the editor buffer back to the working-tree file. This is
// a plain filesystem write (no git command) — the change surfaces on the next
// vcs_status/vcs_diff like any other working-tree edit.
vcs_git_save_file :: proc(path, file, content: string) -> (ok: bool, msg: string) {
	return vcs_write_file_impl(path, file, content)
}

// --- log -----------------------------------------------------------------

// vcs_git_log lists commits newest-first via `git log --format=%H|%h|%s|%an|%ci`,
// one commit per line, then paginates over the parsed entries.
vcs_git_log :: proc(path, cursor: string, limit: int) -> ([]VCS_Log_Entry, string, bool, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "log", "--format=%H|%h|%s|%an|%ci"})
	if !ok do return nil, "", false, false
	all := make([dynamic]VCS_Log_Entry, context.allocator)
	lines := strings.split_lines(out, context.temp_allocator)
	for line in lines {
		if strings.trim_space(line) == "" do continue
		if e, eok := vcs_parse_log_line(line); eok do append(&all, e)
	}
	page, next_cursor, has_more := vcs_paginate_log(all[:], cursor, limit, VCS_LOG_DEFAULT_LIMIT, VCS_LOG_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_parse_log_line parses one log row: either the standard 5-field shape
// ("%H|%h|%s|%an|%ci") or the Google/Fig 7-field shape ("%H|%h|%s|%an|%ci|%cl|%status").
// The hashes and date do not contain '|'; any extra middle pipes are retained in subject.
vcs_parse_log_line :: proc(line: string) -> (VCS_Log_Entry, bool) {
	p1 := strings.index_byte(line, '|')
	if p1 < 0 do return {}, false
	hash := line[:p1]
	rest := line[p1 + 1:]
	p2 := strings.index_byte(rest, '|')
	if p2 < 0 do return {}, false
	short_hash := rest[:p2]
	tail := rest[p2 + 1:] // "<subject>|<author>|<date>" OR "<subject>|<author>|<date>|<clnumber>|<review_status>"

	parts := strings.split(tail, "|", context.temp_allocator)
	if len(parts) >= 5 {
		review_status := strings.trim_space(parts[len(parts) - 1])
		cl_num := strings.trim_space(parts[len(parts) - 2])
		date := strings.trim_space(parts[len(parts) - 3])
		author := strings.trim_space(parts[len(parts) - 4])
		subj_parts := parts[:len(parts) - 4]
		subject := strings.join(subj_parts, "|", context.temp_allocator)
		return VCS_Log_Entry{
			hash          = strings.clone(strings.trim_space(hash)),
			short_hash    = strings.clone(strings.trim_space(short_hash)),
			subject       = strings.clone(subject),
			author        = strings.clone(author),
			date          = strings.clone(date),
			cl_number     = strings.clone(cl_num),
			review_status = strings.clone(review_status),
		}, true
	}

	last := strings.last_index_byte(tail, '|')
	if last < 0 do return {}, false
	date := tail[last + 1:]
	before_date := tail[:last] // "<subject>|<author>"
	alast := strings.last_index_byte(before_date, '|')
	if alast < 0 do return {}, false
	author := before_date[alast + 1:]
	subject := before_date[:alast]
	return VCS_Log_Entry{
		hash          = strings.clone(strings.trim_space(hash)),
		short_hash    = strings.clone(strings.trim_space(short_hash)),
		subject       = strings.clone(subject),
		author        = strings.clone(author),
		date          = strings.clone(strings.trim_space(date)),
		cl_number     = "",
		review_status = "",
	}, true
}

// --- commit_diff ---------------------------------------------------------

// vcs_git_commit_diff diffs base_ref against head_ref (optionally scoped to one
// file). head_ref == "WORKDIR" (or empty) omits the head so git compares base to
// the working tree; base_ref == head_ref is an empty diff by definition. A git
// error (e.g. an unknown ref) surfaces as ok=false, which the caller maps to the
// "invalid_ref" error code.
vcs_git_commit_diff :: proc(path, base_ref, head_ref, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool) {
	if base_ref == head_ref do return nil, "", false, true
	args := vcs_git_commit_diff_args(path, base_ref, head_ref, file)
	out, ok := vcs_run(args[:])
	if !ok do return nil, "", false, false
	hunks := vcs_parse_unified_diff(out)
	page, next_cursor, has_more := vcs_paginate_hunks(hunks, cursor, limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	return page, next_cursor, has_more, true
}

// vcs_git_commit_diff_args builds the `git -C <path> diff <base_ref> [head_ref] [-- <file>]`
// argv for a commit diff. A head_ref of "" or the "WORKDIR" sentinel is omitted so git
// diffs base_ref against the working tree; a non-empty file scopes the diff after a "--"
// separator. Split out of vcs_git_commit_diff (pure, builds argv only) so the sentinel
// handling is unit-testable. Allocates on context.temp_allocator, matching the previous
// inline build — the caller passes args[:] straight to vcs_run in the same scope.
vcs_git_commit_diff_args :: proc(path, base_ref, head_ref, file: string) -> [dynamic]string {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "git", "-C", path, "diff", base_ref)
	if head_ref != "" && head_ref != "WORKDIR" do append(&args, head_ref)
	if file != "" do append(&args, "--", file)
	return args
}

// vcs_ns_char_to_status maps a `git diff --name-status` status char to the neutral
// status word. A/D/R are exact; M, C, T, and anything else collapse to "modified"
// (the closest neutral bucket, matching vcs_git_status_word's fallbacks).
vcs_ns_char_to_status :: proc(sc: rune) -> string {
	switch sc {
	case 'A': return "added"
	case 'D': return "deleted"
	case 'R': return "renamed"
	case:     return "modified" // M, C, T, and anything else
	}
}

// vcs_git_commit_diff_files lists the files changed between base_ref and head_ref
// (the file-list mode of vcs_commit_diff): `git diff --name-status` for path+status
// and `git diff --numstat` for +/- counts, joined by path. head_ref "" or "WORKDIR"
// omits the head so git compares base_ref to the working tree; base_ref == head_ref
// is an empty list by definition. A git error (e.g. an unknown ref) surfaces as
// ok=false, which the caller maps to "invalid_ref". The returned slice and its path
// strings are owned by context.allocator.
vcs_git_commit_diff_files :: proc(path, base_ref, head_ref: string) -> ([]VCS_Changed_File, bool) {
	if base_ref == head_ref do return []VCS_Changed_File{}, true
	// Run git diff --name-status base_ref [head_ref] for path + status.
	ns_args := make([dynamic]string, context.temp_allocator)
	append(&ns_args, "git", "-C", path, "diff", "--name-status", base_ref)
	if head_ref != "" && head_ref != "WORKDIR" do append(&ns_args, head_ref)
	ns_out, ns_ok := vcs_run(ns_args[:])
	if !ns_ok do return nil, false
	// Run git diff --numstat base_ref [head_ref] for +/- counts.
	num_args := make([dynamic]string, context.temp_allocator)
	append(&num_args, "git", "-C", path, "diff", "--numstat", base_ref)
	if head_ref != "" && head_ref != "WORKDIR" do append(&num_args, head_ref)
	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_git_numstat_into(&stats, path, num_args[:])
	// Parse --name-status lines: "<sc>\t<path>" or "<sc>\t<old>\t<new>" for renames.
	all := make([dynamic]VCS_Changed_File, context.allocator)
	for raw in strings.split_lines(ns_out, context.temp_allocator) {
		line := strings.trim_space(raw)
		if len(line) == 0 do continue
		sc := rune(line[0])
		rest := strings.trim_left(line[1:], "\t ")
		// Renames/copies read "<sc>\t<old>\t<new>": the destination is the last
		// tab-separated segment.
		file_path := rest
		if tab := strings.last_index_byte(rest, '\t'); tab >= 0 {
			file_path = strings.trim_space(rest[tab + 1:])
		}
		if file_path == "" do continue
		file_path = strings.clone(file_path)
		counts := stats[file_path] // zero value {0, 0} when absent (renames, binaries)
		append(&all, VCS_Changed_File{
			path      = file_path,
			status    = vcs_ns_char_to_status(sc),
			staged    = false,
			additions = counts[0],
			deletions = counts[1],
		})
	}
	return all[:], true
}

// --- commit --------------------------------------------------------------

// vcs_git_commit commits the currently-staged changes with `message` (and optional amend)
// (`git -C path commit [-m <message>] [--amend]`). Returns ok=true only on exit 0; a git error
// (nothing staged, bad identity, hook rejection, ...) surfaces as ok=false, which the
// caller maps to the "commit_failed" error code. The caller guards against an empty
// message before dispatch, so `message` is always non-empty here.
vcs_git_commit :: proc(path, message: string, amend: bool = false) -> (ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", path, "commit")
	if amend {
		append(&cmd, "--amend")
	}
	append(&cmd, "-m", message)
	_, rok := vcs_run(cmd[:])
	return rok
}

// vcs_git_push pushes committed changes to upstream remote. On failure it returns
// "push_failed" plus a stderr excerpt (vcs_error_detail) so the failure response
// can show WHY the push failed instead of only the generic message.
vcs_git_push :: proc(path: string) -> (ok: bool, code: string, detail: string) {
	out, stderr, rok := vcs_run_capture([]string{"git", "-C", path, "push"}, VCS_NETWORK_TIMEOUT)
	if len(out) > 0 do delete(out)
	if !rok {
		d := vcs_error_detail(stderr)
		if len(stderr) > 0 do delete(stderr)
		return false, "push_failed", d
	}
	if len(stderr) > 0 do delete(stderr)
	return true, "", ""
}

// vcs_git_sync pulls latest changes from upstream with rebase. Same (code,
// detail) convention as vcs_git_push ("sync_failed").
vcs_git_sync :: proc(path: string) -> (ok: bool, code: string, detail: string) {
	out, stderr, rok := vcs_run_capture([]string{"git", "-C", path, "pull", "--rebase"}, VCS_NETWORK_TIMEOUT)
	if len(out) > 0 do delete(out)
	if !rok {
		d := vcs_error_detail(stderr)
		if len(stderr) > 0 do delete(stderr)
		return false, "sync_failed", d
	}
	if len(stderr) > 0 do delete(stderr)
	return true, "", ""
}

// --- workspaces ----------------------------------------------------------

// vcs_git_list_workspaces parses `git worktree list --porcelain`. Records are
// blank-line-separated blocks of "worktree <path>", "HEAD <sha>",
// "branch refs/heads/<name>", and an optional "locked [reason]" / "detached".
// is_current is set on the worktree whose path matches the queried path (both
// normalized via vcs_clean_path); label is the branch short-name, or "(detached)".
vcs_git_list_workspaces :: proc(path: string) -> ([]VCS_Workspace, bool) {
	out, ok := vcs_run([]string{"git", "-C", path, "worktree", "list", "--porcelain"})
	if !ok do return nil, false
	return vcs_git_parse_worktree_list(out, vcs_clean_path(path)), true
}

// vcs_git_parse_worktree_list parses `git worktree list --porcelain` output into the
// workspace rows, marking the block whose path equals `want` (an already-cleaned path)
// as is_current. Split out of vcs_git_list_workspaces (pure, no subprocess) so the
// record splitting and the branch/locked handling are unit-testable.
vcs_git_parse_worktree_list :: proc(out, want: string) -> []VCS_Workspace {
	all := make([dynamic]VCS_Workspace, context.allocator)
	cur := VCS_Workspace{}
	have := false
	lines := strings.split_lines(out, context.temp_allocator)
	for raw in lines {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, "worktree ") {
			if have {
				vcs_git_finalize_workspace(&cur, want)
				append(&all, cur)
			}
			cur = VCS_Workspace{path = strings.clone(strings.trim_space(line[len("worktree "):]))}
			have = true
			continue
		}
		if !have do continue
		if strings.has_prefix(line, "branch ") {
			ref := strings.trim_space(line[len("branch "):])
			cur.label = strings.clone(vcs_strip_branch_ref(ref))
		} else if line == "locked" || strings.has_prefix(line, "locked ") {
			cur.is_locked = true
		}
		// "HEAD <sha>", "bare", "detached", "prunable ..." carry nothing we surface.
	}
	if have {
		vcs_git_finalize_workspace(&cur, want)
		append(&all, cur)
	}
	return all[:]
}

// vcs_git_finalize_workspace fills the derived fields once a worktree block ends.
vcs_git_finalize_workspace :: proc(w: ^VCS_Workspace, want: string) {
	if w.label == "" do w.label = "(detached)"
	w.is_current = vcs_clean_path(w.path) == want
}
