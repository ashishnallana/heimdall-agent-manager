package main

// Version-control (VCS) provider abstraction for the bridge host.
//
// Powers the UI's per-project "changed files + diff" view (Phase 2 hub, Phase 3
// UI). The bridge is the only component with project-local filesystem access, so
// it shells out to the project's VCS and returns a provider-neutral shape the hub
// can relay and the UI can render without knowing whether the backend is git or
// jj.
//
// Design mirrors fs_management.odin: pure value structs, opaque base64 int-offset
// cursor pagination (shared bridge_fs_encode_cursor / bridge_fs_decode_cursor),
// and a bridge_vcs_handle_command dispatcher (see vcs_api.odin) that speaks the
// same command_id-cached, bridge_hub_send envelope as the fs_* commands.
//
// A provider is a proc-table struct; the registry is an ordered list and the first
// adapter whose detect() returns true for a path wins (git before jj).

import "core:os"
import "core:strings"
import "core:time"
import "core:path/filepath"

// --- shared value types --------------------------------------------------

VCS_Status :: struct {
	provider: string,
	branch:   string,
	remote:   string,
	ahead:    int,
	behind:   int,
	is_clean: bool,
}

// status: added | modified | deleted | renamed | untracked
VCS_Changed_File :: struct {
	path:      string,
	status:    string,
	staged:    bool,
	additions: int,
	deletions: int,
}

// op: "+" (added) | "-" (removed) | " " (context)
VCS_Diff_Line :: struct {
	op:   string,
	text: string,
}

VCS_Diff_Hunk :: struct {
	old_start: int,
	old_len:   int,
	new_start: int,
	new_len:   int,
	lines:     []VCS_Diff_Line,
}

// staging_model: "index" (git) | "none" (jj/hg — every change is implicitly staged)
// commit_model:  "branch" (git) | "revision" (jj)
// supported_actions: whitelist the UI consults before offering an action; a member
//   of {"diff","log","commit_diff","revert","stage","unstage","workspaces"}.
VCS_Capabilities :: struct {
	provider:          string,
	supports_staging:  bool,
	staging_model:     string,
	commit_model:      string,
	supports_amend:    bool,
	supports_upload:   bool,
	supports_sync:     bool,
	upload_label:      string,
	sync_label:        string,
	supported_actions: []string,
}

// A single commit/revision row for the vcs_log command.
VCS_Log_Entry :: struct {
	hash:          string,
	short_hash:    string,
	subject:       string,
	author:        string,
	date:          string,
	cl_number:     string,
	review_status: string,
}

// A worktree (git) / workspace (jj) row for the vcs_workspaces command.
VCS_Workspace :: struct {
	path:       string,
	label:      string,
	is_current: bool,
	is_locked:  bool,
}

// --- provider interface (proc-table struct) ------------------------------

VCS_Provider :: struct {
	name:          proc() -> string,
	detect:        proc(path: string) -> bool,
	status:        proc(path: string) -> (VCS_Status, bool),
	// returns (files, next_cursor, has_more, ok)
	changed_files: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool),
	// returns (hunks, next_cursor, has_more, ok)
	diff_file:     proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool),
	capabilities:  proc(path: string) -> VCS_Capabilities,
	// Write commands. Each returns (ok, msg); msg carries an error code on failure
	// (e.g. "untracked_file", "not_supported"). A nil proc pointer means the action
	// is unsupported and callers must treat it as "not_supported" before dispatch.
	stage_file:      proc(path, file: string) -> (ok: bool, msg: string),
	unstage_file:    proc(path, file: string) -> (ok: bool, msg: string),
	revert_file:     proc(path, file: string) -> (ok: bool, msg: string),
	// Write the full text of a working-tree file (editor save). Provider-agnostic
	// (both adapters just write the file relative to the repo root), but kept on the
	// proc-table for uniformity with the other write commands. Returns (ok, msg);
	// msg carries an error code on failure (e.g. "save_failed").
	save_file:       proc(path, file, content: string) -> (ok: bool, msg: string),
	// read-only. returns (entries, next_cursor, has_more, ok)
	log:             proc(path, cursor: string, limit: int) -> (entries: []VCS_Log_Entry, next_cursor: string, has_more: bool, ok: bool),
	// read-only. returns (hunks, next_cursor, has_more, ok)
	commit_diff:     proc(path, base_ref, head_ref, file, cursor: string, limit: int) -> (hunks: []VCS_Diff_Hunk, next_cursor: string, has_more: bool, ok: bool),
	// read-only. Flat list of files changed between base_ref and head_ref (name +
	// status + per-file +/- counts), for the Log tab's file-list selector. head_ref
	// "" or "WORKDIR" compares base_ref to the working tree; base_ref == head_ref is
	// an empty list. Returns (files, ok); nil proc = not supported.
	commit_diff_files: proc(path, base_ref, head_ref: string) -> (files: []VCS_Changed_File, ok: bool),
	// Write command. Commits the currently-staged changes with `message` (and optional amend). Returns ok
	// (true = commit succeeded). A nil proc pointer means the action is unsupported
	// and callers must treat it as "not_supported" before dispatch.
	commit:          proc(path, message: string, amend: bool) -> (ok: bool),
	// Write command. Uploads the current branch/chain of commits to Critique/remote.
	// code is the short machine code (e.g. "push_failed"); detail is an optional
	// human-readable excerpt of the tool's stderr, appended to the failure message.
	upload:          proc(path: string) -> (ok: bool, code: string, detail: string),
	// Write command. Syncs/rebases current branch against head. Same (code, detail)
	// convention as upload (code e.g. "sync_failed").
	sync:            proc(path: string) -> (ok: bool, code: string, detail: string),
	// read-only. returns (workspaces, ok)
	list_workspaces: proc(path: string) -> (workspaces: []VCS_Workspace, ok: bool),
	// read-only. returns file contents at a commit/revision (`git show <rev>:<file>`).
	show_file:       proc(path, rev, file: string) -> (content: string, ok: bool),
}

// --- registry ------------------------------------------------------------

// vcs_init is retained as an empty stub so the startup call site (main.odin) stays
// valid. The provider registry is no longer held in a global slice: detection now
// always builds a stack-local provider list (see vcs_detect_provider), which avoids
// a crash observed when the .detect proc pointer was loaded through the global
// slice indirection.
vcs_init :: proc() {}

// vcs_detect_provider returns the first provider that detects a VCS at `path`.
// ok=false means no known VCS is present (or path is empty). The provider list is
// always built as a stack-local array (git before jj), so the detector touches no
// shared global and is safe to call from multiple threads without any prior init.
vcs_detect_provider :: proc(path: string) -> (VCS_Provider, bool) {
	if path == "" do return VCS_Provider{}, false
	local := [2]VCS_Provider{vcs_git_provider(), vcs_jj_provider()}
	providers := local[:]
	for p in providers {
		if p.detect != nil && p.detect(path) do return p, true
	}
	return VCS_Provider{}, false
}

// --- shared helpers ------------------------------------------------------

// vcs_run_capture executes an argv (no shell) and returns its stdout, stderr,
// and whether the process ran and exited 0. Used by both adapters to shell out
// to git/jj; callers that need the failure detail (vcs_git_push/vcs_git_sync)
// use this so git stderr is preserved for the error response. The returned
// strings are owned by context.allocator; the caller must delete them.
// Local git/jj calls are bounded at VCS_LOCAL_TIMEOUT. Calls that talk to a remote
// (push, pull) get VCS_NETWORK_TIMEOUT, the same 120s the hub waits for them and the
// dispatcher allows (REQ-ERR-PROTO-B).
VCS_LOCAL_TIMEOUT :: 20 * time.Second
VCS_NETWORK_TIMEOUT :: 120 * time.Second

// vcs_process_runner is the subprocess runner behind vcs_run_capture; tests swap it
// to observe the argv and budget an operation actually runs with.
vcs_process_runner := bridge_process_run_capture

vcs_run_capture :: proc(args: []string, timeout: time.Duration = VCS_LOCAL_TIMEOUT) -> (out: string, err_out: string, ok: bool) {
	if len(args) == 0 do return "", "", false
	out, err_out, ok, _ = vcs_process_runner(args, timeout)
	return
}

// vcs_run executes an argv (no shell) and returns its stdout plus whether the
// process ran and exited 0; stderr is discarded. Thin wrapper over
// vcs_run_capture so all existing callers stay untouched. The returned string
// is owned by context.allocator.
vcs_run :: proc(args: []string) -> (out: string, ok: bool) {
	result, err_out, rok := vcs_run_capture(args)
	if len(err_out) > 0 do delete(err_out)
	return result, rok
}

VCS_ERROR_DETAIL_MAX :: 400

// vcs_error_detail reduces a command's stderr to a short human-readable excerpt
// for failure responses: surrounding whitespace is trimmed and the LAST
// VCS_ERROR_DETAIL_MAX bytes are kept — the tail is where the actual error is,
// and the cap keeps WS frames small. Returns "" for empty/whitespace-only input.
// The result is a fresh context.allocator clone; the caller owns it.
vcs_error_detail :: proc(stderr: string) -> string {
	trimmed := strings.trim_space(stderr)
	if trimmed == "" do return ""
	if len(trimmed) > VCS_ERROR_DETAIL_MAX {
		trimmed = trimmed[len(trimmed) - VCS_ERROR_DETAIL_MAX:]
	}
	return strings.clone(trimmed, context.allocator)
}

// vcs_write_file_impl writes `content` to <root>/<file>, creating/truncating it.
// Shared by every provider's save_file: writing a working-tree file is identical
// across git and jj (the VCS metadata is untouched — the edit is picked up by the
// next status/diff). Returns (ok, msg) with an error code on failure.
//
// The client-supplied `file` is UNTRUSTED, so we route the write through
// bridge_fs_write_file, which resolves the path within the repo `root` via
// bridge_fs_resolve_within (rejecting "..", symlink escapes, and out-of-root
// targets — surfaced as error_code "path_outside_root") and writes atomically via
// a temp file + rename. Without this containment a "../../.ssh/authorized_keys"
// path would escape the repo and let a caller write arbitrary files as the bridge
// process. This mirrors the fs_write_file command and the containment the VCS
// panel's own FS reads already go through.
vcs_write_file_impl :: proc(root, file, content: string) -> (ok: bool, msg: string) {
	if strings.trim_space(file) == "" do return false, "missing_file"
	res := bridge_fs_write_file(file, content, root)
	if !res.ok {
		if res.error_code == "path_outside_root" do return false, "path_outside_root"
		return false, "save_failed"
	}
	return true, ""
}

// vcs_dir_exists reports whether `path`/<sub> exists (used by detect()).
vcs_dir_exists :: proc(path, sub: string) -> bool {
	joined, jerr := filepath.join([]string{path, sub}, context.temp_allocator)
	if jerr != nil do return false
	return os.exists(joined)
}

// vcs_paginate_files applies opaque base64 int-offset cursor pagination to a
// fully-collected changed-file list, mirroring fs_management's page logic. Returns
// (page, next_cursor, has_more).
vcs_paginate_files :: proc(all: []VCS_Changed_File, cursor: string, limit, default_limit, max_limit: int) -> ([]VCS_Changed_File, string, bool) {
	page_limit := limit
	if page_limit <= 0 do page_limit = default_limit
	if page_limit > max_limit do page_limit = max_limit
	total := len(all)
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	return all[start:end], next_cursor, has_more
}

@(thread_local)
vcs_last_hunks_truncated: bool

// vcs_paginate_hunks is the hunk-list analogue of vcs_paginate_files.
vcs_paginate_hunks :: proc(all: []VCS_Diff_Hunk, cursor: string, limit, default_limit, max_limit: int) -> ([]VCS_Diff_Hunk, string, bool) {
	page_limit := limit
	if page_limit <= 0 do page_limit = default_limit
	if page_limit > max_limit do page_limit = max_limit
	total := len(all)
	vcs_last_hunks_truncated = max_limit > 0 && total > max_limit
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	return all[start:end], next_cursor, has_more
}

// vcs_paginate_log is the log-entry analogue of vcs_paginate_files/hunks.
vcs_paginate_log :: proc(all: []VCS_Log_Entry, cursor: string, limit, default_limit, max_limit: int) -> ([]VCS_Log_Entry, string, bool) {
	page_limit := limit
	if page_limit <= 0 do page_limit = default_limit
	if page_limit > max_limit do page_limit = max_limit
	total := len(all)
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	return all[start:end], next_cursor, has_more
}

// vcs_clean_path normalizes a path for equality comparison: made absolute against
// the cwd when possible, then lexically cleaned. Used by list_workspaces to decide
// which worktree is the queried one (git reports absolute worktree paths). Symlinks
// are not resolved — a purely lexical normalization, which is enough for the plain
// project paths the hub forwards.
vcs_clean_path :: proc(p: string) -> string {
	if p == "" do return ""
	base := p
	if abs, aerr := filepath.abs(p, context.temp_allocator); aerr == nil {
		base = abs
	}
	cleaned, cerr := filepath.clean(base, context.temp_allocator)
	if cerr != nil do return base
	return cleaned
}

// vcs_strip_branch_ref turns a "refs/heads/<name>" (or "refs/<...>") ref into a
// short human label, leaving anything without that prefix unchanged.
vcs_strip_branch_ref :: proc(ref: string) -> string {
	if strings.has_prefix(ref, "refs/heads/") do return ref[len("refs/heads/"):]
	if strings.has_prefix(ref, "refs/") do return ref[len("refs/"):]
	return ref
}

// vcs_parse_unified_diff parses a unified/`--git` diff into hunks. Lines before the
// first "@@" hunk header (the diff/index/---/+++ preamble) are ignored. Within a
// hunk, a leading '+' is an added line, '-' removed, ' ' (or empty) context; the
// "\ No newline at end of file" marker and any other non +/-/space line ends the
// current hunk's line collection defensively. Shared by the git and jj adapters
// since both emit the same unified format.
vcs_parse_unified_diff :: proc(diff: string) -> []VCS_Diff_Hunk {
	hunks := make([dynamic]VCS_Diff_Hunk, context.allocator)
	lines := strings.split_lines(diff, context.temp_allocator)
	cur_lines: [dynamic]VCS_Diff_Line
	have_hunk := false
	cur := VCS_Diff_Hunk{}

	flush :: proc(hunks: ^[dynamic]VCS_Diff_Hunk, cur: ^VCS_Diff_Hunk, cur_lines: ^[dynamic]VCS_Diff_Line, have_hunk: bool) {
		if !have_hunk do return
		cur.lines = cur_lines^[:]
		append(hunks, cur^)
	}

	for line in lines {
		if strings.has_prefix(line, "@@") {
			// Close the previous hunk, then parse this header.
			flush(&hunks, &cur, &cur_lines, have_hunk)
			cur = VCS_Diff_Hunk{}
			cur_lines = make([dynamic]VCS_Diff_Line, context.allocator)
			have_hunk = true
			vcs_parse_hunk_header(line, &cur)
			continue
		}
		if !have_hunk do continue // skip file-header preamble
		// A zero-length line is never diff content: real empty context/added lines
		// still carry their one-char prefix (" " / "+"). This is the trailing
		// split_lines artifact or a blank separator, so drop it.
		if len(line) == 0 do continue
		switch line[0] {
		case '+':
			append(&cur_lines, VCS_Diff_Line{op = "+", text = strings.clone(line[1:])})
		case '-':
			append(&cur_lines, VCS_Diff_Line{op = "-", text = strings.clone(line[1:])})
		case ' ':
			append(&cur_lines, VCS_Diff_Line{op = " ", text = strings.clone(line[1:])})
		case '\\':
			// "\ No newline at end of file" — metadata, not a content line.
			continue
		case:
			// Anything else (a stray file header inside a combined diff) closes the
			// current hunk defensively; a following "@@" starts a fresh one.
			flush(&hunks, &cur, &cur_lines, have_hunk)
			have_hunk = false
		}
	}
	flush(&hunks, &cur, &cur_lines, have_hunk)
	return hunks[:]
}

// vcs_parse_hunk_header fills the old/new start+len from a "@@ -a,b +c,d @@" header.
// A missing length ("@@ -a +c @@") defaults to 1, matching unified-diff semantics.
vcs_parse_hunk_header :: proc(header: string, hunk: ^VCS_Diff_Hunk) {
	// Strip the leading "@@ " and everything from the trailing " @@".
	body := header
	if strings.has_prefix(body, "@@") do body = body[2:]
	if end := strings.index(body, "@@"); end >= 0 do body = body[:end]
	body = strings.trim_space(body)
	// body is now like "-a,b +c,d". Split on space.
	parts := strings.fields(body, context.temp_allocator)
	for part in parts {
		if len(part) < 2 do continue
		sign := part[0]
		nums := part[1:]
		start, length := vcs_split_range(nums)
		switch sign {
		case '-':
			hunk.old_start = start
			hunk.old_len = length
		case '+':
			hunk.new_start = start
			hunk.new_len = length
		}
	}
}

// vcs_split_range parses "start,len" or "start" (len defaults to 1).
vcs_split_range :: proc(s: string) -> (start: int, length: int) {
	length = 1
	comma := strings.index_byte(s, ',')
	if comma < 0 {
		return vcs_atoi(s), 1
	}
	return vcs_atoi(s[:comma]), vcs_atoi(s[comma + 1:])
}

// vcs_atoi parses a non-negative base-10 int, returning 0 on any junk (diff hunk
// counts are always non-negative integers).
vcs_atoi :: proc(s: string) -> int {
	n := 0
	trimmed := strings.trim_space(s)
	if trimmed == "" do return 0
	for ch in trimmed {
		if ch < '0' || ch > '9' do return 0
		n = n * 10 + int(ch - '0')
	}
	return n
}
