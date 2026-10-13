package vcs_backend_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import vcs "odin_test:lib/vcs"

@(test)
test_vcs_backend :: proc(t: ^testing.T) {
	_ = t
	run_vcs_backend_tests()
}

main :: proc() {
	run_vcs_backend_tests()
}

run_vcs_backend_tests :: proc() {
	root := "/tmp/ham-vcs-backend-test"
	origin := "/tmp/ham-vcs-backend-origin.git"
	worktrees := "/tmp/ham-vcs-backend-worktrees"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", root, origin, worktrees}}, context.allocator)
	_ = os.make_directory_all(root)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "init", "-b", "main", root}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "config", "user.email", "test@example.com"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "config", "user.name", "Test User"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", root), "hello\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "commit", "-m", "init"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "clone", "--bare", root, origin}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "remote", "add", "origin", origin}}, context.allocator)

	backend := vcs.vcs_backend_for(.Git)
	detected := backend.detect(root)
	if !detected.ok {
		fmt.println("git detect failed", detected.message)
		os.exit(1)
	}
	baseline_sha, baseline_ok, baseline_msg := backend.repo_head_sha(root)
	if !baseline_ok || baseline_sha == "" {
		fmt.println("git repo_head_sha failed", baseline_msg)
		os.exit(1)
	}
	handle: vcs.Vcs_Workspace_Handle
	ok: bool
	msg: string
	handle, ok, msg = backend.workspace_add(root, "team/test-chain", detected.base_ref, worktrees)
	if !ok {
		fmt.println("git workspace_add failed", msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", handle.path), "branch change\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", handle.path, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", handle.path, "commit", "-m", "branch change"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", root), "main change\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "commit", "-m", "main change"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", fmt.tprintf("--git-dir=%s", origin), "fetch", "--update-head-ok", root, "+main:main"}}, context.allocator)
	status: vcs.Vcs_Status
	status, ok, msg = backend.workspace_status(handle)
	if !ok {
		fmt.println("git workspace_status failed", msg)
		os.exit(1)
	}
	if status.ahead_commits < 1 || len(status.files) == 0 || status.files[0].adds == 0 {
		fmt.println("git status missing ahead/adds", status.ahead_commits, len(status.files))
		os.exit(1)
	}
	workspace_diff: string
	workspace_diff, ok, msg = backend.workspace_diff(handle, "README.md")
	if !ok || !strings.contains(workspace_diff, "branch change") || strings.contains(workspace_diff, "main change") {
		fmt.println("git workspace_diff failed or changed semantics", ok, msg)
		os.exit(1)
	}
	_ = os.make_directory_all(fmt.tprintf("%s/src/ui/components", root))
	_ = os.write_entire_file(fmt.tprintf("%s/src/ui/components/App.tsx", root), "before\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "add", "src/ui/components/App.tsx"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", root, "commit", "-m", "add app"}}, context.allocator)
	tracked_baseline_sha, tracked_baseline_ok, tracked_baseline_msg := backend.repo_head_sha(root)
	if !tracked_baseline_ok || tracked_baseline_sha == "" {
		fmt.println("git tracked baseline sha failed", tracked_baseline_msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/src/ui/components/App.tsx", root), "after\n")
	tracked_status: vcs.Vcs_Status
	tracked_status, ok, msg = backend.repo_status(root, tracked_baseline_sha)
	if !ok {
		fmt.println("git tracked repo_status failed", msg)
		os.exit(1)
	}
	tracked_actual_count, tracked_bogus_count := 0, 0
	for f in tracked_status.files {
		if f.path == "src/ui/components/App.tsx" do tracked_actual_count += 1
		if f.path == "rc/ui/components/App.tsx" do tracked_bogus_count += 1
	}
	if len(tracked_status.files) != 1 || tracked_actual_count != 1 || tracked_bogus_count != 0 {
		fmt.println("git tracked repo_status path parsing regressed", len(tracked_status.files), tracked_actual_count, tracked_bogus_count)
		for f in tracked_status.files {
			fmt.println("git tracked repo_status file", f.path, f.status, f.adds, f.dels)
		}
		os.exit(1)
	}
	tracked_diff: vcs.Vcs_Repo_Diff
	tracked_diff, ok, msg = backend.repo_diff(root, "src/ui/components/App.tsx", tracked_baseline_sha)
	if !ok || !strings.contains(tracked_diff.diff, "src/ui/components/App.tsx") || !strings.contains(tracked_diff.diff, "+after") {
		fmt.println("git tracked repo_diff failed", ok, msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", root), "dirty tracked\n")
	_ = os.write_entire_file(fmt.tprintf("%s/untracked.txt", root), "untracked file\n")
	repo_status: vcs.Vcs_Status
	repo_status, ok, msg = backend.repo_status(root, baseline_sha)
	if !ok || len(repo_status.files) < 2 {
		fmt.println("git repo_status baseline failed", ok, msg, len(repo_status.files))
		os.exit(1)
	}
	repo_diff: vcs.Vcs_Repo_Diff
	repo_diff, ok, msg = backend.repo_diff(root, "", baseline_sha)
	if !ok || repo_diff.mode != "repo_baseline" || repo_diff.label != "Changes since chain started (whole repo)" || repo_diff.base_sha != baseline_sha || !strings.contains(repo_diff.diff, "main change") || !strings.contains(repo_diff.diff, "dirty tracked") || !strings.contains(repo_diff.diff, "untracked file") {
		fmt.println("git repo_diff baseline failed", ok, msg, repo_diff.mode, repo_diff.label)
		os.exit(1)
	}
	repo_diff, ok, msg = backend.repo_diff(root, "", "")
	if !ok || repo_diff.mode != "repo_uncommitted" || repo_diff.label != "Uncommitted changes" || repo_diff.base_sha != "" || !strings.contains(repo_diff.diff, "dirty tracked") || !strings.contains(repo_diff.diff, "untracked file") {
		fmt.println("git repo_diff fallback failed", ok, msg, repo_diff.mode, repo_diff.label)
		os.exit(1)
	}
	preview: vcs.Vcs_Merge_Preview
	preview, ok, msg = backend.merge_preview(handle, "main")
	if !ok || len(preview.commands) == 0 || len(preview.conflicts) == 0 {
		fmt.println("git merge_preview failed", msg, len(preview.conflicts))
		os.exit(1)
	}
	fmt.println("git ok", detected.repo_root, handle.path, handle.branch_or_change, status.summary_line, "conflicts", len(preview.conflicts))

	jj_state, _, _, jj_err := os.process_exec(os.Process_Desc{command = []string{"jj", "--version"}}, context.allocator)
	if jj_err != nil || !jj_state.success {
		fmt.println("jj skip command unavailable")
		return
	}

	jj_root := "/tmp/ham-vcs-jj-backend-test"
	jj_workspaces := "/tmp/ham-vcs-jj-workspaces"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", jj_root, jj_workspaces}}, context.allocator)
	_ = os.make_directory_all(jj_root)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "init", "-b", "main", jj_root}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "config", "user.email", "test@example.com"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "config", "user.name", "Test User"}}, context.allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README.md", jj_root), "hello\n")
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "add", "README.md"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"git", "-C", jj_root, "commit", "-m", "init"}}, context.allocator)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"jj", "git", "init", "--colocate", jj_root}}, context.allocator)
	jj := vcs.vcs_backend_for(.Jj)
	jj_detected := jj.detect(jj_root)
	if !jj_detected.ok {
		fmt.println("jj detect failed", jj_detected.message)
		os.exit(1)
	}
	jj_handle: vcs.Vcs_Workspace_Handle
	jj_ok: bool
	jj_msg: string
	jj_handle, jj_ok, jj_msg = jj.workspace_add(jj_root, "team/test-chain", jj_detected.base_ref, jj_workspaces)
	if !jj_ok {
		fmt.println("jj workspace_add failed", jj_msg)
		os.exit(1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/jj-change.txt", jj_handle.path), "change\n")
	jj_status: vcs.Vcs_Status
	jj_status, jj_ok, jj_msg = jj.workspace_status(jj_handle)
	if !jj_ok {
		fmt.println("jj workspace_status failed", jj_msg)
		os.exit(1)
	}
	jj_has_adds := false
	for f in jj_status.files {
		if f.adds > 0 do jj_has_adds = true
	}
	if len(jj_status.files) == 0 || !jj_has_adds {
		fmt.println("jj status missing adds", len(jj_status.files))
		os.exit(1)
	}
	_, jj_ok, jj_msg = jj.workspace_diff(jj_handle, "jj-change.txt")
	if !jj_ok {
		fmt.println("jj workspace_diff failed", jj_msg)
		os.exit(1)
	}
	jj_preview: vcs.Vcs_Merge_Preview
	jj_preview, jj_ok, jj_msg = jj.merge_preview(jj_handle, jj_detected.base_ref)
	if !jj_ok || len(jj_preview.commands) == 0 {
		fmt.println("jj merge_preview failed", jj_msg)
		os.exit(1)
	}
	fmt.println("jj ok", jj_detected.repo_root, jj_handle.path, jj_handle.branch_or_change, jj_status.summary_line)

	if os.get_env("HEIMDALL_RUN_LIVE_CITC_TEST", context.allocator) != "1" {
		fmt.println("fig skip: HEIMDALL_RUN_LIVE_CITC_TEST!=1")
		return
	}

	hg_state, _, _, hg_err := os.process_exec(os.Process_Desc{command = []string{"hg", "help", "citc"}}, context.allocator)
	if hg_err != nil || !hg_state.success {
		fmt.println("fig skip: hg citc unavailable")
		return
	}

	fig := vcs.vcs_backend_for(.Fig)
	fig_handle: vcs.Vcs_Workspace_Handle
	fig_ok: bool
	fig_msg: string

	// Clean up any leftover workspace from previous run
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"hg", "citc", "-d", "heimdall_backend_test_temp"}}, context.allocator)

	// Create a unique temporary workspace
	ws_name := "backend_test_temp"
	fig_handle, fig_ok, fig_msg = fig.workspace_add("", ws_name, "", "")
	if !fig_ok {
		fmt.println("fig workspace_add failed:", fig_msg)
		os.exit(1)
	}

	// Ensure we cleanup at the end
	defer {
		remove_ok, remove_msg := fig.workspace_remove(fig_handle, true)
		if !remove_ok {
			fmt.println("fig workspace_remove cleanup failed:", remove_msg)
		}
	}

	fig_detected := fig.detect(fig_handle.path)
	if !fig_detected.ok {
		fmt.println("fig detect failed:", fig_detected.message)
		os.exit(1)
	}

	// Write an untracked file
	test_file_path := fmt.tprintf("%s/test_untracked.txt", fig_handle.path)
	_ = os.write_entire_file(test_file_path, "untracked data\n")

	// Add the file to mercury
	_, _, _, _ = os.process_exec(os.Process_Desc{
		command = []string{"hg", "--cwd", fig_handle.path, "add", "test_untracked.txt"},
	}, context.allocator)

	fig_status: vcs.Vcs_Status
	fig_status, fig_ok, fig_msg = fig.workspace_status(fig_handle)
	if !fig_ok {
		fmt.println("fig workspace_status failed:", fig_msg)
		os.exit(1)
	}

	has_added := false
	for f in fig_status.files {
		if f.path == "test_untracked.txt" && f.status == "A" {
			has_added = true
		}
	}
	if !has_added {
		fmt.println("fig status failed to detect added file")
		os.exit(1)
	}

	// Test diff
	fig_diff: string
	fig_diff, fig_ok, fig_msg = fig.workspace_diff(fig_handle, "test_untracked.txt")
	if !fig_ok || !strings.contains(fig_diff, "untracked data") {
		fmt.println("fig workspace_diff failed:", fig_msg, fig_diff)
		os.exit(1)
	}

	// Test merge preview
	fig_preview: vcs.Vcs_Merge_Preview
	fig_preview, fig_ok, fig_msg = fig.merge_preview(fig_handle, "")
	if !fig_ok || len(fig_preview.commands) == 0 {
		fmt.println("fig merge_preview failed:", fig_msg)
		os.exit(1)
	}

	// Try removing without force (should fail since we have added files)
	try_remove_ok, try_remove_msg := fig.workspace_remove(fig_handle, false)
	if try_remove_ok {
		fmt.println("fig workspace_remove should have failed without force, but succeeded")
		os.exit(1)
	}

	fmt.println("fig ok", fig_detected.repo_root, fig_handle.path, fig_handle.branch_or_change, fig_status.summary_line)
}

