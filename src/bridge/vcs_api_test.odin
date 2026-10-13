package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import json "core:encoding/json"

// Crash-regression + payload-correctness tests for the VCS bridge command
// handlers. These feed the exact JSON payloads the hub sends (see
// src/hub/service/bridge_handlers.odin) straight into the bridge_vcs_*_json procs
// and assert (a) the handler returns without crashing and (b) the output JSON
// carries the expected ok/provider/error fields.
//
// Two production crashes motivated these:
//   - 4486bc3: empty "root" path fed to the handlers (GPF).
//   - dabdef75: vcs_detect_provider returned a slice over a function-local array
//     (global slice), crashing on the next command.
// Tests #1/#2/#4/#5/#6 reproduce the empty/missing-path conditions to prove no
// GPF; #7 guards the old wrong-JSON-key regression (handler reads "path", not the
// legacy "file"); #3 confirms a real git repo still resolves to provider "git".

// 1. Empty root must fail safe to no_vcs (crash regression: empty path).
@(test)
vcs_api_capabilities_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t1", `{"command_id":"t1","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root must return no_vcs error")
}

// 2. Nonexistent path must fail safe to no_vcs (crash regression: bad path).
@(test)
vcs_api_capabilities_nonexistent_path_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t2", `{"command_id":"t2","root":"/tmp/definitely-not-a-vcs-path-heimdall-test"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "nonexistent path must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "nonexistent path must return no_vcs error")
}

// 3. A real git repo resolves and reports provider "git".
@(test)
vcs_api_capabilities_git_repo_returns_provider :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_capabilities_json("t3", `{"command_id":"t3","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "git repo must return ok:true")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "git repo must report provider git")
}

// 4. Missing "root" key entirely (old hub bug) must fail safe to no_vcs.
@(test)
vcs_api_capabilities_missing_root_key_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_capabilities_json("t4", `{"command_id":"t4"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing root key must return ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "missing root key must return no_vcs error")
}

// 5. Empty root on vcs_files must fail safe (crash regression: empty path).
@(test)
vcs_api_files_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_files_json("t5", `{"command_id":"t5","root":"","cursor":"","limit":0}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root files must return ok:false")
}

// 6. Empty root on vcs_diff must fail safe (crash regression: empty path).
@(test)
vcs_api_diff_empty_root_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_diff_json("t6", `{"command_id":"t6","root":"","path":"README.md","cursor":"","limit":0}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root diff must return ok:false")
}

// 7. Real repo but no "path" key must fail safe, not crash (regression for the
// old wrong-key bug: the handler reads "path", and an absent path is rejected).
@(test)
vcs_api_diff_missing_path_key_no_crash :: proc(t: ^testing.T) {
	out := bridge_vcs_diff_json("t7", `{"command_id":"t7","root":"/home/tanmay/heimdall-agent-manager"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing path key must return ok:false")
}

// --- new VCS command handlers (TASK-1-TEST Part A) ------------------------
// Coverage for the vcs_stage/unstage/revert/log/commit_diff/workspaces handlers added
// in TASK-1. Empty-root cases prove the shared no_vcs fail-safe. Detection-only cases
// (missing-file, jj not_supported, same-ref) run against a hermetic marker repo — a
// temp dir carrying just a .git/.jj entry, which vcs_detect_provider recognizes without
// the real tool, and whose handler path returns before any subprocess runs. The
// real-repo cases run against this checkout and skip (like
// vcs_api_capabilities_git_repo_returns_provider) when it is not a git repo. The
// vcs_test_* helpers live in vcs_integration_test.odin (same package).
//
// vcs_stage_not_cached (task item): the write handlers must NOT be command_id-cached,
// because a mutation is not idempotent. This is enforced in vcs_api.odin —
// bridge_vcs_handle_command's vcs_stage/vcs_unstage/vcs_revert cases call
// bridge_vcs_*_json DIRECTLY, with no bridge_runtime_cached_command lookup or
// bridge_runtime_cache_command store (unlike every read handler). Verified by
// inspection of the dispatch; it needs a live ws.Connection to exercise at runtime, so
// there is no hermetic assertion for it here.

@(test)
vcs_api_capabilities_new_fields :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_capabilities_json("c", `{"command_id":"c","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "git repo returns ok:true")
	testing.expect(t, strings.contains(out, `"staging_model":"index"`), "git staging_model is index")
	testing.expect(t, strings.contains(out, `"supports_upload":true`), "git supports_upload is true")
	testing.expect(t, strings.contains(out, `"supports_sync":true`), "git supports_sync is true")
	testing.expect(t, strings.contains(out, `"upload_label":"Push"`), "git upload_label is Push")
	testing.expect(t, strings.contains(out, `"sync_label":"Pull"`), "git sync_label is Pull")
	testing.expect(t, strings.contains(out, `"stage"`), "supported_actions include stage")
	testing.expect(t, strings.contains(out, `"unstage"`), "supported_actions include unstage")
	testing.expect(t, strings.contains(out, `"workspaces"`), "supported_actions include workspaces")
	testing.expect(t, strings.contains(out, `"sync"`), "supported_actions include sync")
	testing.expect(t, strings.contains(out, `"push"`), "supported_actions include push")
	testing.expect(t, strings.contains(out, `"pull"`), "supported_actions include pull")
}

@(test)
vcs_api_stage_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_stage_json("s", `{"command_id":"s","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root stage ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root stage -> no_vcs")
}

@(test)
vcs_api_stage_empty_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("stage-empty-file", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_stage_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s","path":""}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty file stage ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "empty file -> missing_file")
}

@(test)
vcs_api_unstage_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_unstage_json("u", `{"command_id":"u","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root unstage ok:false")
}

@(test)
vcs_api_unstage_not_supported_jj :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("unstage-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_unstage_json("u", fmt.tprintf(`{{"command_id":"u","root":"%s","path":"f.txt"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj unstage ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj unstage -> not_supported")
}

@(test)
vcs_api_revert_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_revert_json("r", `{"command_id":"r","root":"","path":"f.txt"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root revert ok:false")
}

@(test)
vcs_api_revert_missing_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("revert-missing", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_revert_json("r", fmt.tprintf(`{{"command_id":"r","root":"%s","path":""}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing file revert ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "missing file -> missing_file")
}

@(test)
vcs_api_log_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_log_json("l", `{"command_id":"l","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root log ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root log -> no_vcs")
}

@(test)
vcs_api_log_real_repo :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_log_json("l", `{"command_id":"l","root":".","limit":5}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "log ok:true on real repo")
	testing.expect(t, strings.contains(out, `"entries":[`), "entries is an array")
}

@(test)
vcs_api_commit_diff_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":"","base_ref":"HEAD"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root commit_diff ok:false")
}

@(test)
vcs_api_commit_diff_same_ref :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-diff-same", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_diff_json("cd", fmt.tprintf(`{{"command_id":"cd","root":"%s","base_ref":"HEAD","head_ref":"HEAD"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "base_ref == head_ref -> ok:true")
	testing.expect(t, strings.contains(out, `"hunks":[]`), "base_ref == head_ref -> empty hunks")
}

// list_files mode: a real repo with list_files:true returns "list_files":true and a
// "files":[ array (never "hunks"). Skips when this checkout is not a git repo.
@(test)
vcs_api_commit_diff_list_files_real :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":".","base_ref":"HEAD~1","head_ref":"HEAD","list_files":true}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "list_files real repo -> ok:true")
	testing.expect(t, strings.contains(out, `"list_files":true`), "response echoes list_files:true")
	testing.expect(t, strings.contains(out, `"files":[`), "response carries a files array")
	testing.expect(t, !strings.contains(out, `"hunks":`), "list_files response has no hunks field")
	// Well-formedness: list_files is a bare bool token, so it must be immediately
	// followed by a proper key separator (,"base_ref"), never a stray quote (`true"`).
	testing.expect(t, strings.contains(out, `"list_files":true,"base_ref":`), "list_files:true is followed by a clean key separator")
	testing.expect(t, !strings.contains(out, `true",`), "no stray quote after the list_files bool (malformed-JSON guard)")
	testing.expect(t, strings.contains(out, `"head_ref":"HEAD"`), "head_ref echoed back verbatim")
}

// no-regression: list_files absent (default false) still returns the hunk shape.
@(test)
vcs_api_commit_diff_hunks_default :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_commit_diff_json("cd", `{"command_id":"cd","root":".","base_ref":"HEAD~1","head_ref":"HEAD"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "default mode real repo -> ok:true")
	testing.expect(t, strings.contains(out, `"hunks":[`), "default mode carries a hunks array")
	testing.expect(t, !strings.contains(out, `"list_files":true`), "default mode does not set list_files")
}

// jj provider has commit_diff_files=nil, so list_files mode on a .jj marker repo
// must fail safe to not_supported (detection-only path, no jj binary needed).
@(test)
vcs_api_commit_diff_list_files_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-diff-files-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_diff_json("cd", fmt.tprintf(`{{"command_id":"cd","root":"%s","base_ref":"HEAD","head_ref":"HEAD~1","list_files":true}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj list_files -> ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"list_files":true`), "error still echoes list_files:true")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj list_files -> not_supported")
}

// vcs_commit handler: empty root -> no_vcs (fail-safe, no crash).
@(test)
vcs_api_commit_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_commit_json("cm", `{"command_id":"cm","root":"","message":"x"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root commit ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root commit -> no_vcs")
}

// vcs_commit handler: a real (marker) git repo but an empty message -> missing_message,
// before any git runs.
@(test)
vcs_api_commit_missing_message :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-missing-msg", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_json("cm", fmt.tprintf(`{{"command_id":"cm","root":"%s","message":""}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty message commit ok:false")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "provider resolves to git")
	testing.expect(t, strings.contains(out, `"code":"missing_message"`), "empty message -> missing_message")
}

// vcs_commit handler: jj provider has commit=nil -> not_supported (detection-only path).
@(test)
vcs_api_commit_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("commit-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_commit_json("cm", fmt.tprintf(`{{"command_id":"cm","root":"%s","message":"hi"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj commit ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj commit -> not_supported")
}

@(test)
vcs_api_workspaces_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_workspaces_json("w", `{"command_id":"w","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root workspaces ok:false")
}

@(test)
vcs_api_workspaces_real_repo :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_workspaces_json("w", `{"command_id":"w","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "workspaces ok:true on real repo")
	testing.expect(t, strings.contains(out, `"is_current":true`), "the queried worktree is current")
}

@(test)
vcs_api_upload_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_upload_json("u", `{"command_id":"u","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root upload ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root upload -> no_vcs")
}

@(test)
vcs_api_sync_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_sync_json("s", `{"command_id":"s","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root sync ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root sync -> no_vcs")
}

@(test)
vcs_api_upload_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("upload-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_upload_json("u", fmt.tprintf(`{{"command_id":"u","root":"%s"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj upload ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj upload -> not_supported")
}

@(test)
vcs_api_sync_jj_not_supported :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("sync-jj", ".jj")
	defer vcs_test_rm(repo)
	out := bridge_vcs_sync_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "jj sync ok:false")
	testing.expect(t, strings.contains(out, `"provider":"jj"`), "provider resolves to jj")
	testing.expect(t, strings.contains(out, `"code":"not_supported"`), "jj sync -> not_supported")
}

// --- REQ-VCS-2: push/pull failure responses carry git stderr detail -------

// vcs_error_detail: short stderr is trimmed and passes through untruncated.
@(test)
vcs_error_detail_short :: proc(t: ^testing.T) {
	d := vcs_error_detail("fatal: boom\n")
	defer delete(d)
	testing.expect(t, d == "fatal: boom", "short stderr trimmed, not truncated")
}

// vcs_error_detail: whitespace-only stderr yields no excerpt at all.
@(test)
vcs_error_detail_whitespace_only :: proc(t: ^testing.T) {
	d := vcs_error_detail("  \n\t \n")
	testing.expect(t, d == "", "whitespace-only stderr yields empty detail")
}

// vcs_error_detail: >400 bytes keeps the TAIL (where the actual error is),
// dropping the head.
@(test)
vcs_error_detail_caps_tail :: proc(t: ^testing.T) {
	head := strings.repeat("A", 100, context.allocator)
	tail := strings.repeat("B", 500, context.allocator)
	defer delete(head)
	defer delete(tail)
	input := strings.concatenate([]string{head, tail}, context.allocator)
	defer delete(input)
	d := vcs_error_detail(input)
	defer delete(d)
	want := strings.repeat("B", 400, context.allocator)
	defer delete(want)
	testing.expect(t, len(d) == 400, "detail capped at 400 bytes")
	testing.expect(t, !strings.contains(d, "A"), "head of long stderr dropped")
	testing.expect(t, d == want, "tail bytes kept exactly")
}

// Upload against a repo with NO remote: git exits non-zero fast; the response
// keeps code "push_failed" and the message embeds the real git stderr (the
// 404-byte stderr survives the 400-byte tail cap with this fragment intact).
@(test)
vcs_api_upload_no_remote_captures_stderr :: proc(t: ^testing.T) {
	repo, ok := vcs_test_git_repo("upload-noremote")
	defer vcs_test_rm(repo)
	if !ok do return
	if !vcs_test_git("git", "-C", repo, "commit", "--allow-empty", "-m", "init") do return
	out := bridge_vcs_upload_json("u", fmt.tprintf(`{{"command_id":"u","root":"%s"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "no-remote upload ok:false")
	testing.expect(t, strings.contains(out, `"code":"push_failed"`), "no-remote upload code push_failed")
	testing.expect(t, strings.contains(out, "No configured push destination"), "failure message embeds real git stderr")
}

// Sync against a repo with no upstream: git pull --rebase exits non-zero; the
// response keeps code "sync_failed" and embeds the real git stderr.
@(test)
vcs_api_sync_no_remote_captures_stderr :: proc(t: ^testing.T) {
	repo, ok := vcs_test_git_repo("sync-noremote")
	defer vcs_test_rm(repo)
	if !ok do return
	if !vcs_test_git("git", "-C", repo, "commit", "--allow-empty", "-m", "init") do return
	out := bridge_vcs_sync_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "no-upstream sync ok:false")
	testing.expect(t, strings.contains(out, `"code":"sync_failed"`), "no-upstream sync code sync_failed")
	testing.expect(t, strings.contains(out, "no tracking information"), "failure message embeds real git stderr")
}

// Escaping contract: git stderr containing a double quote and newlines must be
// emitted as valid escaped JSON in the frame (\" and \n via json_write_string).
// The upstream remote is a nonexistent local path containing a quote, so git
// echoes both in its fatal line — fully local, no network.
@(test)
vcs_api_upload_failure_escapes_stderr :: proc(t: ^testing.T) {
	repo, ok := vcs_test_git_repo("upload-escape")
	defer vcs_test_rm(repo)
	if !ok do return
	if !vcs_test_git("git", "-C", repo, "commit", "--allow-empty", "-m", "init") do return
	bad_remote := strings.concatenate([]string{repo, "/no\"pe"}, context.allocator)
	defer delete(bad_remote)
	if !vcs_test_git("git", "-C", repo, "remote", "add", "origin", bad_remote) do return
	if !vcs_test_git("git", "-C", repo, "config", "branch.main.remote", "origin") do return
	if !vcs_test_git("git", "-C", repo, "config", "branch.main.merge", "refs/heads/main") do return
	out := bridge_vcs_upload_json("u", fmt.tprintf(`{{"command_id":"u","root":"%s"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "quote-remote upload ok:false")
	testing.expect(t, strings.contains(out, `\"`), "quote in stderr escaped in the frame")
	testing.expect(t, strings.contains(out, `\n`), "newline in stderr escaped in the frame")
}

// --- REQ-P2-VCS: Typed structs, key-ordering, whitespace, escaping, zero-leaks ---

@(test)
vcs_api_status_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_status_json("s1", `{"command_id":"s1","root":""}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"type":"vcs_status_result"`), "result type is vcs_status_result")
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root status ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root status -> no_vcs")
}

@(test)
vcs_api_status_real_repo :: proc(t: ^testing.T) {
	if !vcs_git_detect(".") do return
	out := bridge_vcs_status_json("s2", `{"command_id":"s2","root":"."}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"type":"vcs_status_result"`), "result type is vcs_status_result")
	testing.expect(t, strings.contains(out, `"ok":true`), "real repo status ok:true")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "provider resolves to git")
	testing.expect(t, strings.contains(out, `"branch"`), "status contains branch")
}

@(test)
vcs_api_key_ordering_resilience :: proc(t: ^testing.T) {
	// Root before command_id
	out1 := bridge_vcs_capabilities_json("", `{"root":"","command_id":"rev_1"}`)
	defer delete(out1)
	testing.expect(t, strings.contains(out1, `"command_id":"rev_1"`), "command_id extracted when at end")
	testing.expect(t, strings.contains(out1, `"no_vcs"`), "root evaluated correctly")

	// Limit and cursor before command_id and root
	out2 := bridge_vcs_files_json("", `{"limit":42,"cursor":"cur_123","command_id":"rev_2","root":""}`)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, `"command_id":"rev_2"`), "command_id extracted")
	testing.expect(t, strings.contains(out2, `"cursor":"cur_123"`), "cursor extracted")
	testing.expect(t, strings.contains(out2, `"limit":42`), "limit extracted")

	// Commit command with message before root
	repo := vcs_test_make_marker_repo("key-order-cm", ".git")
	defer vcs_test_rm(repo)
	out3 := bridge_vcs_commit_json("", fmt.tprintf(`{{"message":"","root":"%s","command_id":"rev_3"}}`, repo))
	defer delete(out3)
	testing.expect(t, strings.contains(out3, `"command_id":"rev_3"`), "command_id extracted")
	testing.expect(t, strings.contains(out3, `"missing_message"`), "message evaluated correctly")
}

@(test)
vcs_api_whitespace_tolerance :: proc(t: ^testing.T) {
	payload := `
	{
		"type":        "vcs_files",
		"command_id":  "ws_cmd_1",
		"root":        "",
		"cursor":      "page_1",
		"limit":       25
	}
	`
	out := bridge_vcs_files_json("", payload)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"command_id":"ws_cmd_1"`), "multiline formatted json parsed")
	testing.expect(t, strings.contains(out, `"cursor":"page_1"`), "cursor preserved")
	testing.expect(t, strings.contains(out, `"limit":25`), "limit preserved")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "error returned cleanly")
}

@(test)
vcs_api_special_characters_commit_message :: proc(t: ^testing.T) {
	raw := `{"command_id":"c_spec","root":".","message":"feat(core): \"quoted text\" \\ and \n newline \t tab and \u2764 unicode 🚀"}`
	cmd: Bridge_Vcs_Commit_Command
	err := json.unmarshal_string(raw, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil, "unmarshaling commit command succeeded")
	testing.expect(t, strings.contains(cmd.message, `"quoted text"`), "quotes unescaped properly")
	testing.expect(t, strings.contains(cmd.message, `\ and`), "backslash preserved properly")
	testing.expect(t, strings.contains(cmd.message, "\n newline"), "newline decoded properly")
	testing.expect(t, strings.contains(cmd.message, "❤"), "unicode decoded properly")
	testing.expect(t, strings.contains(cmd.message, "🚀"), "multibyte utf-8 decoded properly")
}

@(test)
vcs_api_special_characters_diff_hunks :: proc(t: ^testing.T) {
	lines := make([]Bridge_Vcs_Diff_Line_Wire, 3, context.temp_allocator)
	lines[0] = Bridge_Vcs_Diff_Line_Wire{op = "-", text = "func old() { return \"hello \\ world\"; }"}
	lines[1] = Bridge_Vcs_Diff_Line_Wire{op = "+", text = "func new() { return \"hello \\ world \u2764 🚀\"; }"}
	lines[2] = Bridge_Vcs_Diff_Line_Wire{op = " ", text = "var end = 0;"}
	hunks := make([]Bridge_Vcs_Diff_Hunk_Wire, 1, context.temp_allocator)
	hunks[0] = Bridge_Vcs_Diff_Hunk_Wire{
		old_start = 1,
		old_len   = 2,
		new_start = 1,
		new_len   = 2,
		lines     = lines,
	}
	wire := Bridge_Vcs_Diff_Result_Wire{
		type        = "vcs_diff_result",
		command_id  = "cmd_spec_diff",
		ok          = true,
		provider    = "git",
		file        = "src/special\"name\\path.odin",
		cursor      = "",
		limit       = 50,
		has_more    = false,
		next_cursor = nil,
		hunks       = hunks,
		error       = Bridge_Vcs_Error_Wire{code = "", message = ""},
	}
	data, merr := json.marshal(wire, allocator = context.temp_allocator)
	testing.expect(t, merr == nil, "diff result marshaled successfully")
	json_str := string(data)
	testing.expect(t, strings.contains(json_str, `"src/special\"name\\path.odin"`), "file name quotes and backslashes escaped in json")
	testing.expect(t, strings.contains(json_str, `\"hello \\ world`), "diff line escaped in json")

	// Round-trip back into struct
	decoded: Bridge_Vcs_Diff_Result_Wire
	uerr := json.unmarshal_string(json_str, &decoded, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, uerr == nil, "diff result unmarshaled cleanly")
	testing.expect(t, decoded.file == "src/special\"name\\path.odin", "file path round-tripped exactly")
	testing.expect(t, len(decoded.hunks) == 1, "hunks length preserved")
	testing.expect(t, decoded.hunks[0].lines[1].text == "func new() { return \"hello \\ world ❤ 🚀\"; }", "diff text round-tripped exactly")
}

@(test)
vcs_api_zero_tracking_allocator_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	// Call each of the handlers and verify that deleting the result leaves 0 net allocated bytes
	{
		out := bridge_vcs_capabilities_json("t1", `{"command_id":"t1","root":""}`)
		delete(out)
	}
	{
		out := bridge_vcs_status_json("t2", `{"command_id":"t2","root":""}`)
		delete(out)
	}
	{
		out := bridge_vcs_files_json("t3", `{"command_id":"t3","root":"","cursor":"","limit":10}`)
		delete(out)
	}
	{
		out := bridge_vcs_diff_json("t4", `{"command_id":"t4","root":"","file":"f.txt"}`)
		delete(out)
	}
	{
		out := bridge_vcs_log_json("t5", `{"command_id":"t5","root":""}`)
		delete(out)
	}
	{
		out := bridge_vcs_workspaces_json("t6", `{"command_id":"t6","root":""}`)
		delete(out)
	}
	{
		out := bridge_vcs_stage_json("t7", `{"command_id":"t7","root":"","path":"a.txt"}`)
		delete(out)
	}
	{
		out := bridge_vcs_commit_diff_json("t8", `{"command_id":"t8","root":"","base_ref":"HEAD"}`)
		delete(out)
	}

	testing.expect(t, len(track.allocation_map) == 0, fmt.tprintf("expected 0 leaks, got %d leaks", len(track.allocation_map)))
	testing.expect(t, len(track.bad_free_array) == 0, fmt.tprintf("expected 0 bad frees, got %d bad frees", len(track.bad_free_array)))
}

@(test)
vcs_api_wire_struct_roundtrips :: proc(t: ^testing.T) {
	// Capabilities
	caps_wire := Bridge_Vcs_Capabilities_Result_Wire{
		type              = "vcs_capabilities_result",
		command_id        = "c1",
		ok                = true,
		provider          = "git",
		supports_staging  = true,
		supports_amend    = true,
		supports_upload   = true,
		supports_sync     = true,
		upload_label      = "Push",
		sync_label        = "Pull",
		staging_model     = "index",
		commit_model      = "branch",
		supported_actions = []string{"stage", "unstage", "commit"},
		error             = Bridge_Vcs_Error_Wire{code = "", message = ""},
	}
	caps_json, _ := json.marshal(caps_wire, allocator = context.temp_allocator)
	caps_dec: Bridge_Vcs_Capabilities_Result_Wire
	_ = json.unmarshal_string(string(caps_json), &caps_dec, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, caps_dec.ok == true, "caps roundtrip ok")
	testing.expect(t, caps_dec.upload_label == "Push", "caps roundtrip upload_label")
	testing.expect(t, len(caps_dec.supported_actions) == 3, "caps roundtrip supported_actions")

	// Status
	stat_wire := Bridge_Vcs_Status_Result_Wire{
		type       = "vcs_status_result",
		command_id = "s1",
		ok         = true,
		provider   = "git",
		branch     = "main",
		remote     = "origin/main",
		ahead      = 2,
		behind     = 1,
		is_clean   = false,
		error      = Bridge_Vcs_Error_Wire{code = "", message = ""},
	}
	stat_json, _ := json.marshal(stat_wire, allocator = context.temp_allocator)
	stat_dec: Bridge_Vcs_Status_Result_Wire
	_ = json.unmarshal_string(string(stat_json), &stat_dec, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, stat_dec.ahead == 2, "status roundtrip ahead")
	testing.expect(t, stat_dec.behind == 1, "status roundtrip behind")
	testing.expect(t, stat_dec.branch == "main", "status roundtrip branch")

	// Mutation
	mut_wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = "vcs_commit_result",
		command_id = "m1",
		ok         = true,
		provider   = "git",
		error      = Bridge_Vcs_Error_Wire{code = "", message = ""},
	}
	mut_json, _ := json.marshal(mut_wire, allocator = context.temp_allocator)
	mut_dec: Bridge_Vcs_Mutation_Result_Wire
	_ = json.unmarshal_string(string(mut_json), &mut_dec, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, mut_dec.ok == true, "mutation roundtrip ok")
	testing.expect(t, mut_dec.provider == "git", "mutation roundtrip provider")

	// Workspaces
	ws_wire := Bridge_Vcs_Workspaces_Result_Wire{
		type       = "vcs_workspaces_result",
		command_id = "w1",
		ok         = true,
		provider   = "git",
		workspaces = []Bridge_Vcs_Workspace_Entry_Wire{
			{path = "/tmp/repo", label = "main", is_current = true, is_locked = false},
		},
		error      = Bridge_Vcs_Error_Wire{code = "", message = ""},
	}
	ws_json, _ := json.marshal(ws_wire, allocator = context.temp_allocator)
	ws_dec: Bridge_Vcs_Workspaces_Result_Wire
	_ = json.unmarshal_string(string(ws_json), &ws_dec, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, len(ws_dec.workspaces) == 1, "workspaces roundtrip count")
	testing.expect(t, ws_dec.workspaces[0].is_current == true, "workspaces roundtrip is_current")
}

vcs_save_test_pin_tmp_root :: proc() {
	bridge_fs_root = bridge_fs_canonicalize_existing("/tmp")
}

@(test)
vcs_api_save_empty_root :: proc(t: ^testing.T) {
	out := bridge_vcs_save_json("s", `{"command_id":"s","root":"","path":"f.txt","content":"x"}`)
	defer delete(out)
	testing.expect(t, strings.contains(out, `"type":"vcs_save_file_result"`), "result type is vcs_save_file_result")
	testing.expect(t, strings.contains(out, `"ok":false`), "empty root save ok:false")
	testing.expect(t, strings.contains(out, `"no_vcs"`), "empty root save -> no_vcs")
}

@(test)
vcs_api_save_missing_file :: proc(t: ^testing.T) {
	repo := vcs_test_make_marker_repo("save-missing", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s","path":"","content":"x"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "missing file save ok:false")
	testing.expect(t, strings.contains(out, `"code":"missing_file"`), "empty path -> missing_file")
}

@(test)
vcs_api_save_writes_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	vcs_save_test_pin_tmp_root()
	repo := vcs_test_make_marker_repo("save-write", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s","path":"hello.txt","content":"hello world"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "save writes -> ok:true")
	testing.expect(t, strings.contains(out, `"provider":"git"`), "provider resolves to git")
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/hello.txt", repo), context.allocator)
	testing.expect(t, rerr == nil, "saved file exists on disk")
	testing.expect(t, string(data) == "hello world", "file content matches the saved buffer")
}

@(test)
vcs_api_save_unescapes_content :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	vcs_save_test_pin_tmp_root()
	repo := vcs_test_make_marker_repo("save-nl", ".git")
	defer vcs_test_rm(repo)
	out := bridge_vcs_save_json("s", fmt.tprintf("{{\"command_id\":\"s\",\"root\":\"%s\",\"path\":\"nl.txt\",\"content\":\"a\\nb\"}}", repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":true`), "save (escaped content) -> ok:true")
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/nl.txt", repo), context.allocator)
	testing.expect(t, rerr == nil, "saved file exists on disk")
	testing.expect(t, string(data) == "a\nb", "escaped newline decoded to a real newline")
}

@(test)
vcs_api_save_rejects_path_traversal :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	vcs_save_test_pin_tmp_root()
	repo := vcs_test_make_marker_repo("save-escape", ".git")
	defer vcs_test_rm(repo)
	escaped := "/tmp/ham-vcs-save-escape-PWNED.txt"
	_ = os.remove(escaped)
	out := bridge_vcs_save_json("s", fmt.tprintf(`{{"command_id":"s","root":"%s","path":"../ham-vcs-save-escape-PWNED.txt","content":"pwn"}}`, repo))
	defer delete(out)
	testing.expect(t, strings.contains(out, `"ok":false`), "traversal save must be rejected")
	testing.expect(t, strings.contains(out, `"code":"path_outside_root"`), "traversal -> path_outside_root")
	testing.expect(t, !os.exists(escaped), "escaped file must not exist on disk")
}



