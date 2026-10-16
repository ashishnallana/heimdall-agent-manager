package vcs

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

git_is_hex_pair :: proc(text: string) -> bool {
	if len(text) != 2 do return false
	for r in text {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) do return false
	}
	return true
}

git_is_probable_artifact_blob_path :: proc(path: string) -> bool {
	parts := strings.split(strings.trim_space(path), "/")
	defer delete(parts)
	if len(parts) < 3 do return false
	for i in 0..<(len(parts) - 2) {
		artifact_id := parts[i + 2]
		if !git_is_hex_pair(parts[i]) || !git_is_hex_pair(parts[i + 1]) do continue
		if len(artifact_id) != 36 || !strings.has_prefix(artifact_id, "art_") do continue
		hex_suffix := artifact_id[len("art_"):]
		valid_hex := true
		for r in hex_suffix {
			if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
				valid_hex = false
				break
			}
		}
		if valid_hex do return true
	}
	return false
}

git_detect :: proc(repo_path: string) -> Vcs_Detect_Result {
	root, ok, msg := vcs_run([]string{"git", "-C", repo_path, "rev-parse", "--show-toplevel"})
	if !ok do return Vcs_Detect_Result{kind = .Git, ok = false, message = msg}
	base, base_ok, _ := vcs_run([]string{"git", "-C", repo_path, "symbolic-ref", "--short", "HEAD"})
	if !base_ok || base == "" do base = "main"
	return Vcs_Detect_Result{kind = .Git, repo_root = root, base_ref = base, ok = true, message = "git repository detected"}
}

git_workspace_add :: proc(repo, name, base_ref, worktree_root: string) -> (Vcs_Workspace_Handle, bool, string) {
	effective_base := base_ref
	if effective_base == "" do effective_base = "main"
	path := vcs_workspace_path(worktree_root, name)
	branch_name := git_workspace_branch_name(name)
	_ = os.make_directory_all(vcs_workspace_parent(path))
	_, _, _ = vcs_run([]string{"git", "-C", repo, "fetch", "--quiet", "origin", effective_base})
	_, ok, msg := vcs_run([]string{"git", "-C", repo, "worktree", "add", path, "-b", branch_name, effective_base})
	if !ok {
		_, ok, msg = vcs_run([]string{"git", "-C", repo, "worktree", "add", path, branch_name})
		if !ok do return Vcs_Workspace_Handle{}, false, msg
	}
	return Vcs_Workspace_Handle{path = path, branch_or_change = branch_name, base_ref = effective_base, kind = .Git}, true, "git worktree created"
}

git_workspace_branch_name :: proc(name: string) -> string {
	clean, _ := strings.replace_all(name, "/", "-")
	clean, _ = strings.replace_all(clean, "@", "-")
	clean, _ = strings.replace_all(clean, " ", "-")
	clean = strings.trim(clean, "-.")
	if clean == "" do clean = "heimdall-workspace"
	return strings.clone(fmt.tprintf("heimdall-%s", clean))
}

git_workspace_remove :: proc(handle: Vcs_Workspace_Handle, force: bool) -> (bool, string) {
	cmd := []string{"git", "-C", handle.path, "worktree", "remove", handle.path}
	if force do cmd = []string{"git", "-C", handle.path, "worktree", "remove", "--force", handle.path}
	ok, msg := vcs_run_ok(cmd)
	if !ok && !force do return false, msg
	if force {
		_, _ = vcs_run_ok([]string{"git", "-C", handle.path, "branch", "-D", handle.branch_or_change})
	}
	return true, "git worktree removed"
}

git_workspace_status :: proc(handle: Vcs_Workspace_Handle) -> (Vcs_Status, bool, string) {
	out, ok, msg := vcs_run([]string{"git", "-C", handle.path, "status", "--porcelain=v1", "-uall"})
	if !ok do return Vcs_Status{}, false, msg
	files := make([dynamic]Vcs_File_Change)
	modified, added, deleted, untracked, conflicted := 0, 0, 0, 0, 0
	for line in strings.split(out, "\n") {
		if strings.trim_space(line) == "" do continue
		status := strings.trim_space(line[:2])
		path := strings.trim_space(line[3:])
		if strings.contains(status, "U") || status == "AA" || status == "DD" { conflicted += 1 }
		else if strings.contains(status, "A") { added += 1 }
		else if strings.contains(status, "D") { deleted += 1 }
		else if strings.contains(status, "?") { untracked += 1 }
		else { modified += 1 }
		append(&files, Vcs_File_Change{path = strings.clone(path), status = strings.clone(status)})
	}
	git_apply_numstat(handle, &files, fmt.tprintf("%s...HEAD", handle.base_ref))
	ahead, behind := 0, 0
	counts, counts_ok, _ := vcs_run([]string{"git", "-C", handle.path, "rev-list", "--left-right", "--count", fmt.tprintf("%s...HEAD", handle.base_ref)})
	if counts_ok {
		parts := strings.fields(counts)
		if len(parts) >= 2 {
			if n, n_ok := strconv.parse_int(parts[0]); n_ok do behind = int(n)
			if n, n_ok := strconv.parse_int(parts[1]); n_ok do ahead = int(n)
		}
	}
	return Vcs_Status{ahead_commits = ahead, behind_commits = behind, files = files[:], is_conflicted = conflicted > 0, summary_line = vcs_summary_from_files(files[:], 0)}, true, "git status ok"
}

git_workspace_diff :: proc(handle: Vcs_Workspace_Handle, path: string) -> (string, bool, string) {
	builder := strings.builder_make()
	committed, committed_ok, committed_msg := git_diff_revspec(handle.path, fmt.tprintf("%s...HEAD", handle.base_ref), path)
	if !committed_ok do return "", false, committed_msg
	if committed != "" {
		strings.write_string(&builder, committed)
		strings.write_string(&builder, "\n")
	}
	tracked, tracked_ok, tracked_msg := git_diff_revspec(handle.path, "HEAD", path)
	if !tracked_ok do return "", false, tracked_msg
	if tracked != "" {
		strings.write_string(&builder, tracked)
		strings.write_string(&builder, "\n")
	}
	untracked, untracked_ok, untracked_msg := git_untracked_diff(handle.path, path)
	if !untracked_ok do return "", false, untracked_msg
	if untracked != "" {
		strings.write_string(&builder, untracked)
		strings.write_string(&builder, "\n")
	}
	return vcs_truncate_diff(strings.to_string(builder)), true, "git diff ok"
}

git_repo_head_sha :: proc(repo: string) -> (string, bool, string) {
	out, ok, msg := vcs_run([]string{"git", "-C", repo, "rev-parse", "--verify", "HEAD"})
	if !ok do return "", false, msg
	return strings.clone(strings.trim_space(out)), true, "git head sha ok"
}

git_worktree_add_detached :: proc(repo, path, rev: string) -> (bool, string) {
	target_rev := strings.trim_space(rev)
	if target_rev == "" do target_rev = "HEAD"
	_ = os.make_directory_all(vcs_workspace_parent(path))
	return vcs_run_ok([]string{"git", "-C", repo, "worktree", "add", "--detach", path, target_rev})
}

git_worktree_remove_force :: proc(repo, path: string) -> (bool, string) {
	base_repo := strings.trim_space(repo)
	if base_repo == "" do base_repo = path
	ok, msg := vcs_run_ok([]string{"git", "-C", base_repo, "worktree", "remove", "--force", path})
	_, _ = vcs_run_ok([]string{"git", "-C", base_repo, "worktree", "prune"})
	return ok, msg
}

git_repo_is_clean :: proc(repo: string) -> bool {
	out, ok, _ := vcs_run([]string{"git", "-C", repo, "status", "--porcelain=v1", "-uall"})
	if !ok do return false
	for line in strings.split(out, "\n") {
		if strings.trim_space(line) == "" || len(line) < 3 do continue
		status := strings.trim_space(line[:2])
		path := strings.trim_space(line[3:])
		if strings.contains(status, "?") && git_is_probable_artifact_blob_path(path) do continue
		return false
	}
	return true
}

git_commit_subjects_since :: proc(repo, base_sha: string) -> (string, bool) {
	base := strings.trim_space(base_sha)
	if base == "" do return "", false
	out, ok, _ := vcs_run([]string{"git", "-C", repo, "log", "--reverse", "--format=%s", fmt.tprintf("%s..HEAD", base)})
	if !ok do return "", false
	subjects := make([dynamic]string, context.temp_allocator)
	for line in strings.split(out, "\n") {
		s := strings.trim_space(line)
		if s != "" do append(&subjects, s)
	}
	if len(subjects) == 0 do return "", false
	return strings.clone(strings.join(subjects[:], "; ", context.temp_allocator)), true
}

git_repo_status :: proc(repo, diff_base_sha: string) -> (Vcs_Status, bool, string) {
	out, ok, msg := vcs_run([]string{"git", "-C", repo, "status", "--porcelain=v1", "-uall"})
	if !ok do return Vcs_Status{}, false, msg
	files := make([dynamic]Vcs_File_Change)
	conflicted := 0
	for line in strings.split(out, "\n") {
		if strings.trim_space(line) == "" || len(line) < 3 do continue
		status := strings.trim_space(line[:2])
		path := strings.trim_space(line[3:])
		if strings.contains(status, "?") && git_is_probable_artifact_blob_path(path) do continue
		if strings.contains(status, "U") || status == "AA" || status == "DD" do conflicted += 1
		append(&files, Vcs_File_Change{path = strings.clone(path), status = strings.clone(status)})
	}
	base := strings.trim_space(diff_base_sha)
	if base != "" do git_apply_repo_numstat(repo, &files, fmt.tprintf("%s..HEAD", base))
	git_apply_repo_numstat(repo, &files, "HEAD")
	return Vcs_Status{files = files[:], is_conflicted = conflicted > 0, summary_line = vcs_summary_from_files(files[:], conflicted)}, true, "git repo status ok"
}

git_repo_diff :: proc(repo, path, diff_base_sha: string) -> (Vcs_Repo_Diff, bool, string) {
	base := strings.trim_space(diff_base_sha)
	mode := "repo_uncommitted"
	label := "Uncommitted changes"
	builder := strings.builder_make()
	if base != "" {
		mode = "repo_baseline"
		label = "Changes since chain started (whole repo)"
		committed, ok, msg := git_diff_revspec(repo, fmt.tprintf("%s..HEAD", base), path)
		if !ok do return Vcs_Repo_Diff{}, false, msg
		if committed != "" {
			strings.write_string(&builder, committed)
			strings.write_string(&builder, "\n")
		}
	}
	tracked, tracked_ok, tracked_msg := git_diff_revspec(repo, "HEAD", path)
	if !tracked_ok do return Vcs_Repo_Diff{}, false, tracked_msg
	if tracked != "" {
		strings.write_string(&builder, tracked)
		strings.write_string(&builder, "\n")
	}
	untracked, untracked_ok, untracked_msg := git_untracked_diff(repo, path)
	if !untracked_ok do return Vcs_Repo_Diff{}, false, untracked_msg
	if untracked != "" {
		strings.write_string(&builder, untracked)
		strings.write_string(&builder, "\n")
	}
	return Vcs_Repo_Diff{diff = vcs_truncate_diff(strings.to_string(builder)), mode = strings.clone(mode), label = strings.clone(label), base_sha = strings.clone(base)}, true, "git repo diff ok"
}

git_diff_revspec :: proc(repo, revspec, path: string) -> (string, bool, string) {
	if path == "" {
		return vcs_run([]string{"git", "-C", repo, "diff", revspec})
	}
	return vcs_run([]string{"git", "-C", repo, "diff", revspec, "--", path})
}

git_untracked_diff :: proc(repo, path: string) -> (string, bool, string) {
	out: string
	ok: bool
	msg: string
	if path == "" {
		out, ok, msg = vcs_run([]string{"git", "-C", repo, "ls-files", "--others", "--exclude-standard"})
	} else {
		out, ok, msg = vcs_run([]string{"git", "-C", repo, "ls-files", "--others", "--exclude-standard", "--", path})
	}
	if !ok do return "", false, msg
	builder := strings.builder_make()
	for line in strings.split(out, "\n") {
		file := strings.trim_space(line)
		if file == "" do continue
		if git_is_probable_artifact_blob_path(file) do continue
		diff, diff_ok, diff_msg := git_diff_no_index(repo, file)
		if !diff_ok do return "", false, diff_msg
		if diff != "" {
			strings.write_string(&builder, diff)
			strings.write_string(&builder, "\n")
		}
	}
	return strings.to_string(builder), true, "git untracked diff ok"
}

git_diff_no_index :: proc(repo, file: string) -> (string, bool, string) {
	cmd := []string{"git", "-C", repo, "diff", "--no-index", "--", "/dev/null", file}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil do return "", false, "command failed to start"
	out := strings.trim_right(string(stdout), "\r\n")
	if state.success || out != "" do return strings.clone(out), true, "ok"
	msg := strings.trim_space(string(stderr))
	if msg == "" do msg = "command failed"
	return "", false, vcs_safe_message(msg)
}

git_workspace_pull_base :: proc(handle: Vcs_Workspace_Handle) -> (bool, string) {
	_, _ = vcs_run_ok([]string{"git", "-C", handle.path, "fetch", "origin", handle.base_ref})
	return vcs_run_ok([]string{"git", "-C", handle.path, "rebase", fmt.tprintf("origin/%s", handle.base_ref)})
}

git_merge_preview :: proc(handle: Vcs_Workspace_Handle, target: string) -> (Vcs_Merge_Preview, bool, string) {
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	cmds := make([dynamic]string)
	append(&cmds, strings.clone(fmt.tprintf("git -C <repo> switch %s", effective_target)))
	append(&cmds, strings.clone(fmt.tprintf("git -C <repo> merge --no-ff %s", handle.branch_or_change)))
	append(&cmds, strings.clone(fmt.tprintf("git -C <repo> push origin %s", effective_target)))
	_, _, _ = vcs_run([]string{"git", "-C", handle.path, "fetch", "origin", effective_target})
	base_ref := fmt.tprintf("origin/%s", effective_target)
	_, remote_ok, _ := vcs_run([]string{"git", "-C", handle.path, "rev-parse", "--verify", base_ref})
	if !remote_ok do base_ref = effective_target
	branch_ref := handle.branch_or_change
	out, ok, _ := vcs_run([]string{"git", "-C", handle.path, "merge-tree", "--write-tree", "--name-only", base_ref, branch_ref})
	conflicts := make([dynamic]string)
	if !ok {
		for line in strings.split(out, "\n") {
			trimmed := strings.trim_space(line)
			if trimmed != "" do append(&conflicts, strings.clone(trimmed))
		}
		return Vcs_Merge_Preview{can_fast_forward = false, conflicts = conflicts[:], commands = cmds[:], summary = fmt.tprintf("Merge preview found %d conflict(s)", len(conflicts))}, true, "git merge preview ok"
	}
	return Vcs_Merge_Preview{can_fast_forward = true, conflicts = conflicts[:], commands = cmds[:], summary = fmt.tprintf("Merge preview clean for %s into %s", handle.branch_or_change, effective_target)}, true, "git merge preview ok"
}

git_apply_numstat :: proc(handle: Vcs_Workspace_Handle, files: ^[dynamic]Vcs_File_Change, revspec: string) {
	git_apply_repo_numstat(handle.path, files, revspec)
}

git_apply_repo_numstat :: proc(repo: string, files: ^[dynamic]Vcs_File_Change, revspec: string) {
	out, ok, _ := vcs_run([]string{"git", "-C", repo, "diff", "--numstat", revspec})
	if !ok do return
	for line in strings.split(out, "\n") {
		parts := strings.fields(line)
		if len(parts) < 3 do continue
		path := parts[2]
		adds := 0; dels := 0
		if n, n_ok := strconv.parse_int(parts[0]); n_ok do adds = int(n)
		if n, n_ok := strconv.parse_int(parts[1]); n_ok do dels = int(n)
		found := false
		for i in 0..<len(files^) {
			if files^[i].path == path {
				files^[i].adds = adds; files^[i].dels = dels; found = true
			}
		}
		if !found do append(files, Vcs_File_Change{path = strings.clone(path), status = "", adds = adds, dels = dels})
	}
}

git_merge_execute :: proc(handle: Vcs_Workspace_Handle, target: string) -> (bool, string) {
	// Operator-gated local merge only. The branch is checked out in the linked
	// worktree, so we merge it into <target> in the main working tree.
	// Per INV-4 we never push automatically; the push recipe stays a manual
	// command shown in merge_preview.commands[].
	effective_target := target
	if effective_target == "" do effective_target = handle.base_ref
	if effective_target == "" do effective_target = "main"
	common, ok, msg := vcs_run([]string{"git", "-C", handle.path, "rev-parse", "--git-common-dir"})
	if !ok do return false, msg
	repo_root := common
	if strings.has_suffix(repo_root, "/.git") do repo_root = repo_root[:len(repo_root) - len("/.git")]
	else if repo_root == ".git" do repo_root = strings.clone(".")
	if sw_ok, sw_msg := vcs_run_ok([]string{"git", "-C", repo_root, "switch", effective_target}); !sw_ok {
		return false, sw_msg
	}
	merge_msg := fmt.tprintf("Merge %s into %s (heimdall)", handle.branch_or_change, effective_target)
	if m_ok, m_msg := vcs_run_ok([]string{"git", "-C", repo_root, "merge", "--no-ff", "-m", merge_msg, handle.branch_or_change}); !m_ok {
		_, _ = vcs_run_ok([]string{"git", "-C", repo_root, "merge", "--abort"})
		return false, m_msg
	}
	return true, "git merge completed locally; push manually when ready"
}
