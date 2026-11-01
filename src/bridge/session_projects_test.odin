package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import json "core:encoding/json"
import cfg_lib "odin_test:lib/config"

session_test_root :: proc(t: ^testing.T) -> string {
	home: string
	{ context.allocator = context.temp_allocator; home = cfg_lib.home_dir() }
	root := fmt.aprintf("%s/.cache/heimdall-tests/session-projects-%d", home, time.to_unix_nanoseconds(time.now()))
	testing.expect(t, os.make_directory_all(root) == nil)
	canonical, allowed := session_project_resolve(root, root)
	if !testing.expect(t, allowed && canonical != "", "fixture root must canonicalize inside itself") {
		delete(canonical)
		return root // keep failed fixtures confined to this unique test directory
	}
	delete(root)
	return canonical
}
session_test_seed :: proc(t: ^testing.T, root, rel, body: string) {
	full := fmt.tprintf("%s/%s", root, rel)
	_ = os.make_directory_all(full[:strings.last_index_byte(full, '/')])
	testing.expect(t, os.write_entire_file_from_string(full, body) == nil)
}

@(test)
session_projects_empty_and_sandbox :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect(t, r.ok)
	testing.expect_value(t, len(r.projects), 0)
	wire, marshal_err := json.marshal(r)
	defer delete(wire)
	testing.expect(t, marshal_err == nil && strings.contains(string(wire), `"projects":[]`))
	_ = os.make_directory_all(fmt.tprintf("%s/.codex/sessions", root))
	r2 := session_projects_discover(root, fmt.tprintf("%s/elsewhere", root))
	defer session_projects_destroy(&r2)
	testing.expect_value(t, len(r2.projects), 0)
}

@(test)
session_projects_metadata_and_malformed :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	cwd := fmt.tprintf("%s/code/app", root)
	_ = os.make_directory_all(cwd)
	meta := struct {type: string, payload: struct {cwd: string}}{type = "session_meta"}
	meta.payload.cwd = cwd
	data, _ := json.marshal(meta, allocator = context.temp_allocator)
	session_test_seed(t, root, ".codex/sessions/2026/10/rollout-a.jsonl", fmt.tprintf("bad json\n%s\n", string(data)))
	session_test_seed(t, root, ".codex/sessions/2026/10/rollout-b.jsonl", string(data))
	session_test_seed(t, root, ".codex/sessions/rollout-bad.jsonl", "{bad")
	session_test_seed(t, root, ".codex/sessions/ignored.jsonl", string(data))
	session_test_seed(t, root, ".codex/sessions/rollout-relative.jsonl", "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"relative\"}}")
	session_test_seed(t, root, ".claude/projects/-home-me-app/a.jsonl", "malformed session contents are never read")
	session_test_seed(t, root, ".claude/projects/-home-me-app/b.jsonl", "")
	session_test_seed(t, root, ".claude/projects/-home-me-app/memory/a.jsonl", "not a session")
	session_test_seed(t, root, ".claude/projects/empty/note.txt", "")
	older := time.unix(1_700_000_000, 0)
	newer := time.unix(1_700_003_600, 0)
	for rel in ([]string{".codex/sessions/2026/10/rollout-a.jsonl", ".claude/projects/-home-me-app/a.jsonl"}) {
		testing.expect(t, os.change_times(fmt.tprintf("%s/%s", root, rel), older, older) == nil)
	}
	for rel in ([]string{".codex/sessions/2026/10/rollout-b.jsonl", ".claude/projects/-home-me-app/b.jsonl"}) {
		testing.expect(t, os.change_times(fmt.tprintf("%s/%s", root, rel), newer, newer) == nil)
	}
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	if !testing.expect_value(t, len(r.projects), 2) do return
	for project in r.projects {
		testing.expect_value(t, project.sessions, 2)
		testing.expect_value(t, project.last_session_at, bridge_fs_format_mtime(newer))
		if project.source == "Codex" { testing.expect(t, session_project_path_equal(project.path, cwd)) }
		else { testing.expect_value(t, project.path, "-home-me-app") }
	}
	r.command_id = "test"
	wire, err := json.marshal(r)
	defer delete(wire)
	testing.expect(t, err == nil)
	testing.expect(t, !strings.contains(string(wire), "malformed session contents"))
}

@(test)
session_projects_deadline_and_unreadable :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	session_test_seed(t, root, ".codex/sessions/rollout-bad.jsonl", "{")
	testing.expect_value(t, session_project_codex_cwd(fmt.tprintf("%s/missing", root)), "")
	testing.expect_value(t, session_project_codex_cwd(fmt.tprintf("%s/.codex/sessions/rollout-bad.jsonl", root)), "")
	r := session_projects_discover(root, root, time.to_unix_nanoseconds(time.now()) - 1)
	defer session_projects_destroy(&r)
	testing.expect(t, r.truncated)
	testing.expect_value(t, len(r.projects), 0)
}


// Symlinked files and directories cannot escape fixed history roots.
@(test)
session_projects_ignores_symlink_history :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows { return }
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	session_test_seed(t, root, "outside/rollout-secret.jsonl", fmt.tprintf(`{{"type":"session_meta","payload":{{"cwd":"%s"}}}}`, root))
	_ = os.make_directory_all(fmt.tprintf("%s/.codex/sessions", root))
	testing.expect(t, os.symlink(fmt.tprintf("%s/outside", root), fmt.tprintf("%s/.codex/sessions/escape", root)) == nil)
	testing.expect(t, os.symlink(fmt.tprintf("%s/outside/rollout-secret.jsonl", root), fmt.tprintf("%s/.codex/sessions/rollout-link.jsonl", root)) == nil)
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect_value(t, len(r.projects), 0)
}

@(test)
session_projects_reports_prefix_limit :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	data := make([]byte, 256 * 1024 + 1)
	defer delete(data)
	for &byte in data do byte = 'x'
	session_test_seed(t, root, ".codex/sessions/rollout-large.jsonl", string(data))
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect(t, r.truncated, "incomplete metadata prefix must be visible to the user")
	testing.expect_value(t, len(r.projects), 0)
}

@(test)
session_projects_description_sources_and_bounds :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	project := fmt.tprintf("%s/code/app", root)
	_ = os.make_directory_all(project)
	budget := 1024 * 1024
	expectations := []string{"A legacy project summary.", "A Claude project summary.", "An agents project summary."}
	for source, i in ([]string{"CLAUDE.m", "CLAUDE.md", "AGENTS.md"}) {
		expected := expectations[i]
		session_test_seed(t, project, source, fmt.tprintf("# Project\n\n%s\n\n## Instructions\nNever expose this instruction text.", expected))
		summary := session_project_description(project, &budget)
		testing.expect_value(t, summary, expected)
		delete(summary)
	}
	// Oversized AGENTS and malformed CLAUDE fall through to the literal fallback.
	large := make([]u8, 16 * 1024 + 1)
	defer delete(large)
	for &byte in large do byte = 'x'
	session_test_seed(t, project, "AGENTS.md", string(large))
	malformed := []u8{0xff, 0x00}
	session_test_seed(t, project, "CLAUDE.md", string(malformed))
	summary := session_project_description(project, &budget)
	testing.expect_value(t, summary, "A legacy project summary.")
	delete(summary)
	session_test_seed(t, project, "CLAUDE.md", "")
	session_test_seed(t, project, "AGENTS.md", "# Instructions\n\nAlways run the tests.\nNever publish.\n")
	summary = session_project_description(project, &budget)
	testing.expect_value(t, summary, "A legacy project summary.")
	delete(summary)
	budget = 0
	testing.expect_value(t, session_project_description(project, &budget), "")
	budget = 1024 * 1024
	testing.expect_value(t, session_project_description(fmt.tprintf("%s/missing", root), &budget), "")
	when ODIN_OS != .Windows {
		session_test_seed(t, project, "AGENTS.md", "An unreadable project description.")
		path := fmt.tprintf("%s/AGENTS.md", project)
		testing.expect(t, os.chmod(path, {}) == nil)
		defer _ = os.chmod(path, {.Read_User, .Write_User})
		summary = session_project_description(project, &budget)
		testing.expect_value(t, summary, "A legacy project summary.")
		delete(summary)
	}
}

@(test)
session_projects_description_privacy_and_format :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	project := fmt.tprintf("%s/project", root)
	_ = os.make_directory_all(project)
	session_test_seed(t, root, "secret.md", "# Secret\n\nA private description outside the project.")
	when ODIN_OS != .Windows {
		testing.expect(t, os.symlink(fmt.tprintf("%s/secret.md", root), fmt.tprintf("%s/AGENTS.md", project)) == nil)
	}
	session_test_seed(t, project, "CLAUDE.md", "# Agent instructions\n\n## Project\n- Name: App\n- Description: A useful service for tracking jobs.\n\n## Build\nRun secret command.")
	budget := 1024 * 1024
	summary := session_project_description(project, &budget)
	testing.expect_value(t, summary, "A useful service for tracking jobs.")
	delete(summary)
	summary = session_project_summary("# App\n\nApp is a useful service\nfor tracking jobs.\n\n## Architecture\nSensitive implementation details.")
	testing.expect_value(t, summary, "App is a useful service for tracking jobs.")
	delete(summary)
	summary = session_project_summary(strings.repeat("App is useful. ", 100, context.temp_allocator))
	testing.expect(t, len(summary) <= 320 && strings.has_suffix(summary, "..."))
	delete(summary)
	testing.expect_value(t, session_project_summary("# Rules\n\nYou are a helpful engineer.\nAlways run tests."), "")
}

@(test)
session_projects_canonical_cross_provider_descriptions :: proc(t: ^testing.T) {
	testing.expect_value(t, session_project_encode("/café/日/😀"), "-caf------")
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	cwd := fmt.tprintf("%s/code/app", root)
	_ = os.make_directory_all(cwd)
	session_test_seed(t, cwd, "AGENTS.md", "# App\n\nApp is a calendar service.\n\n## Instructions\nNever return this body.")
	meta := struct {type: string, payload: struct {cwd: string}}{type = "session_meta"}
	meta.payload.cwd = cwd
	data, _ := json.marshal(meta, allocator = context.temp_allocator)
	session_test_seed(t, root, ".codex/sessions/rollout-a.jsonl", string(data))
	encoded := session_project_encode(cwd)
	session_test_seed(t, root, fmt.tprintf(".claude/projects/%s/session.jsonl", encoded), "SESSION SECRET")
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	if !testing.expect_value(t, len(r.projects), 2) do return
	for project in r.projects {
		testing.expect(t, session_project_path_equal(project.canonical_path, cwd))
		testing.expect_value(t, project.description, "App is a calendar service.")
	}
	wire, err := json.marshal(r)
	defer delete(wire)
	testing.expect(t, err == nil && !strings.contains(string(wire), "SESSION SECRET") && !strings.contains(string(wire), "Never return"))
	// The encoding is ambiguous: refuse to assign a canonical path or read files.
	_ = os.make_directory_all(fmt.tprintf("%s/code-app", root))
	resolved := session_project_claude_path(encoded, root, 0)
	testing.expect_value(t, resolved, "")
	delete(resolved)
	budget := 0
	testing.expect_value(t, session_project_claude_path(encoded, root, 0, &budget), "")
}
