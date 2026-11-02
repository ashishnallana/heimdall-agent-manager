package main

// Setup discovery returns metadata and short project summaries, never session bodies.
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:unicode/utf8"
import json "core:encoding/json"
import cfg_lib "odin_test:lib/config"
import ws "odin_test:lib/ws"

Session_Project :: struct {
	source: string,
	path: string, // Codex cwd, or Claude's encoded project folder name
	sessions: int,
	last_session_at: string,
	canonical_path: string,
	description: string,
}
Session_Projects_Result :: struct {
	type: string,
	command_id: string,
	ok: bool,
	projects: [dynamic]Session_Project,
	truncated: bool,
}

// A bounded prefix avoids reading multi-GB conversations. session_meta is normally
// the first line. Malformed lines do not prevent later metadata from being found.
session_project_codex_cwd :: proc(path: string, truncated: ^bool = nil) -> string {
	f, err := os.open(path, {.Read})
	if err != nil do return ""
	defer os.close(f)
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	used := 0
	for used < len(buf) {
		n, read_err := os.read(f, buf[used:])
		if n > 0 do used += n
		if read_err != nil || n <= 0 do break
	}
	lines := strings.split(string(buf[:used]), "\n")
	defer delete(lines)
	for line in lines {
		meta: struct {type: string, payload: struct {cwd: string}}
		if json.unmarshal_string(line, &meta, json.DEFAULT_SPECIFICATION, context.allocator) != nil {
			delete(meta.type); delete(meta.payload.cwd); continue
		}
		defer { delete(meta.type); delete(meta.payload.cwd) }
		if meta.type == "session_meta" && filepath.is_abs(meta.payload.cwd) do return strings.clone(meta.payload.cwd)
	}
	if used == len(buf) && truncated != nil do truncated^ = true
	return ""
}

// Filesystem canonicalization uses scratch allocations internally. Keep them
// within the worker's temporary arena, returning only the owned resolved path.
session_project_resolve :: proc(path, root: string) -> (string, bool) {
	owned := context.allocator
	context.allocator = context.temp_allocator
	when ODIN_OS == .Windows {
		effective_root := root if root != "" else bridge_fs_root
		requested := strings.trim_space(path)
		if requested == "" || requested == "~" { requested = effective_root }
		else { requested = bridge_expand_home(requested) }
		if !filepath.is_abs(requested) {
			requested = filepath.join([]string{effective_root, requested}, context.temp_allocator) or_else ""
		}
		actual, exists := session_project_windows_realpath(requested)
		actual_root, root_exists := session_project_windows_realpath(effective_root)
		if !exists || !root_exists || !bridge_fs_is_within_root(actual, actual_root) do return "", false
		return strings.clone(actual, owned), true
	} else {
		resolved, within := bridge_fs_resolve_within(path, root)
		return strings.clone(resolved, owned), within
	}
}

session_project_path_equal :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		left, _ := strings.replace_all(a, "\\", "/", context.temp_allocator)
		right, _ := strings.replace_all(b, "\\", "/", context.temp_allocator)
		return strings.equal_fold(strings.trim_right(left, "/"), strings.trim_right(right, "/"))
	} else {
		return a == b
	}
}

session_projects_discover :: proc(home, sandbox_root: string, deadline_ns: i64 = 0) -> Session_Projects_Result {
	result := Session_Projects_Result{type = "session_projects_result", ok = true}
	result.projects = make([dynamic]Session_Project)
	// Only fixed provider history roots are accepted. No caller supplied paths.
	remaining := 20_000
	for source in ([]string{"Codex", "Claude Code"}) {
		suffix := "/.codex/sessions" if source == "Codex" else "/.claude/projects"
		requested := strings.concatenate({home, suffix}, context.temp_allocator)
		root, within := session_project_resolve(requested, sandbox_root)
		defer delete(root)
		if !within || !os.is_dir(root) do continue
		queue := make([dynamic]string)
		append(&queue, strings.clone(root))
		defer { for dir in queue do delete(dir); delete(queue) }
		for index := 0; index < len(queue); index += 1 {
			if remaining <= 0 || bridge_command_deadline_expired(deadline_ns) { result.truncated = true; break }
			infos, err := os.read_directory_by_path(queue[index], remaining + 1, context.allocator)
			if err != nil do continue
			for info in infos {
				if remaining <= 0 || bridge_command_deadline_expired(deadline_ns) { result.truncated = true; break }
				remaining -= 1
				// Do not follow symlinks out of history or into cycles.
				if info.type == .Directory {
					if source == "Codex" || index == 0 {
						canonical, allowed := session_project_resolve(info.fullpath, root)
						if allowed && session_project_path_equal(canonical, info.fullpath) { append(&queue, canonical) } else { delete(canonical) }
					}
					continue
				}
				if info.type != .Regular || !strings.has_suffix(info.name, ".jsonl") do continue
				path := ""
				if source == "Codex" {
					if !strings.has_prefix(info.name, "rollout-") do continue
					path = session_project_codex_cwd(info.fullpath, &result.truncated)
					if path == "" do continue
					canonical, allowed := session_project_resolve(path, sandbox_root)
					delete(path)
					if !allowed || !os.is_dir(canonical) { delete(canonical); continue }
					path = canonical
				} else {
					if index == 0 do continue
					path = strings.clone(filepath.base(queue[index]))
				}
				found := -1
				for project, i in result.projects {
					if project.source == source && project.path == path { found = i; break }
				}
				if found < 0 {
					append(&result.projects, Session_Project{source = source, path = path})
					found = len(result.projects) - 1
				} else { delete(path) }
				project := &result.projects[found]
				project.sessions += 1
				stamp := strings.clone(bridge_fs_format_mtime(info.modification_time))
				if stamp > project.last_session_at {
					delete(project.last_session_at)
					project.last_session_at = stamp
				} else { delete(stamp) }
			}
			os.file_info_slice_delete(infos, context.allocator)
		}
	}
	// A single scan has a 1 MiB instruction-file budget. Summaries are computed
	// once per canonical folder, independent of provider and session count.
	read_budget := 1024 * 1024
	resolve_budget := 20_000
	summaries := make(map[string]string)
	defer delete(summaries)
	for &project in result.projects {
		if bridge_command_deadline_expired(deadline_ns) { result.truncated = true; break }
		canonical := strings.clone(project.path) if project.source == "Codex" else session_project_claude_path(project.path, sandbox_root, deadline_ns, &resolve_budget)
		if canonical == "" do continue
		project.canonical_path = canonical
		if summary, cached := summaries[canonical]; cached {
			project.description = strings.clone(summary)
		} else {
			project.description = session_project_description(canonical, &read_budget)
			summaries[canonical] = project.description
		}
	}
	return result
}

session_projects_destroy :: proc(result: ^Session_Projects_Result) {
	for project in result.projects { delete(project.path); delete(project.last_session_at); delete(project.canonical_path); delete(project.description) }
	delete(result.projects)
}

bridge_session_projects_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	if type != "session_projects" do return false
	cmd: struct {command_id: string}
	if json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil do return false
	if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
	home := cfg_lib.home_dir(context.temp_allocator)
	result := session_projects_discover(home, bridge_fs_root, bridge_command_worker_deadline_ns(conn))
	defer session_projects_destroy(&result)
	result.command_id = cmd.command_id
	out, err := json.marshal(result)
	if err != nil do return false
	defer delete(out)
	bridge_runtime_cache_command(cmd.command_id, string(out))
	_ = bridge_hub_send(conn, string(out))
	return true
}

// Claude folder names are lossy. Walk only matching encoded prefixes inside the
// canonical sandbox; ambiguous matches are omitted rather than guessing.
session_project_encode :: proc(path: string) -> string {
	out := make([]u8, len(path), context.temp_allocator)
	used := 0
	for c in path {
		out[used] = u8(c) if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') else '-'
		used += 1
		// Claude's JavaScript encoding replaces each UTF-16 code unit.
		if c > 0xffff { out[used] = '-'; used += 1 }
	}
	return string(out[:used])
}

session_project_claude_path :: proc(encoded, sandbox_root: string, deadline_ns: i64, scan_budget: ^int = nil) -> string {
	root, allowed := session_project_resolve("", sandbox_root)
	defer delete(root)
	if !allowed || !strings.has_prefix(encoded, session_project_encode(root)) do return ""
	queue := make([dynamic]string)
	append(&queue, strings.clone(root))
	defer { for path in queue do delete(path); delete(queue) }
	answer := ""
	remaining := 2048
	for index := 0; index < len(queue); index += 1 {
		if remaining <= 0 || (scan_budget != nil && scan_budget^ <= 0) || bridge_command_deadline_expired(deadline_ns) { delete(answer); return "" }
		dir := queue[index]
		if session_project_encode(dir) == encoded {
			canonical, within := session_project_resolve(dir, sandbox_root)
			if within {
				if answer != "" && answer != canonical { delete(answer); delete(canonical); return "" }
				delete(answer)
				answer = canonical
			} else { delete(canonical) }
			continue
		}
		infos, err := os.read_directory_by_path(dir, remaining + 1, context.allocator)
		if err != nil do continue
		for info in infos {
			remaining -= 1
			if scan_budget != nil { scan_budget^ -= 1 }
			if remaining <= 0 || (scan_budget != nil && scan_budget^ <= 0) do break
			// Symlink aliases may be matched, but traversal stays within the root.
			key := session_project_encode(info.fullpath)
			if !strings.has_prefix(encoded, key) || (len(encoded) > len(key) && encoded[len(key)] != '-') do continue
			canonical, within := session_project_resolve(info.fullpath, sandbox_root)
			if within && os.is_dir(canonical) { append(&queue, strings.clone(info.fullpath)) }
			delete(canonical)
		}
		os.file_info_slice_delete(infos, context.allocator)
		if remaining <= 0 || (scan_budget != nil && scan_budget^ <= 0) { delete(answer); return "" }
	}
	return answer
}

// Conservative Markdown extraction: explicit Description fields, or prose in an
// opening/Overview/About/Description section. Commands, lists and later agent
// instruction sections are never used. No model or instruction execution occurs.
session_project_summary :: proc(body: string) -> string {
	if !utf8.valid_string(body) do return ""
	for c in body { if c < 32 && c != '\n' && c != '\r' && c != '\t' do return "" }
	lines := strings.split(body, "\n", context.temp_allocator)
	paragraph := ""
	eligible := true
	fenced := false
	for raw in lines {
		line := strings.trim_space(raw)
		if strings.has_prefix(line, "```") || strings.has_prefix(line, "~~~") { fenced = !fenced; if paragraph != "" { eligible = false }; continue }
		if fenced do continue
		// Explicit project metadata takes precedence over opening prose.
		field := strings.trim_left(line, "-* ")
		if strings.has_prefix(field, "Description:") || strings.has_prefix(field, "**Description**:") {
			at := strings.index_byte(field, ':')
			value := strings.trim_space(field[at+1:])
			if value != "" { return session_project_summary_clean(value) }
		}
		if strings.has_prefix(line, "#") {
			heading := strings.trim_space(strings.trim_left(line, "#"))
			lower := strings.to_lower(heading, context.temp_allocator)
			eligible = paragraph == "" && (strings.has_prefix(line, "# ") || lower == "overview" || lower == "about" || lower == "description" || lower == "project overview")
			continue
		}
		if line == "" {
			if paragraph != "" { eligible = false }
			continue
		}
		if !eligible || strings.has_prefix(line, "-") || strings.has_prefix(line, "*") || strings.has_prefix(line, ">") || strings.has_prefix(line, "|") || strings.has_prefix(line, "<") do continue
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.contains(lower, "you are ") || strings.contains(lower, "you must ") || strings.contains(lower, "instructions") || strings.has_prefix(lower, "run ") || strings.has_prefix(lower, "always ") || strings.has_prefix(lower, "never ") do continue
		if paragraph == "" {
			declarative := strings.has_prefix(lower, "a ") || strings.has_prefix(lower, "an ")
			for verb in ([]string{" is ", " are ", " provides ", " implements ", " helps ", " enables ", " manages ", " tracks ", " offers ", " combines ", " supports ", " contains "}) {
				if strings.contains(lower, verb) { declarative = true; break }
			}
			if !declarative do continue
			paragraph = line
		}
		else { paragraph = strings.concatenate({paragraph, " ", line}, context.temp_allocator) }
	}
	return session_project_summary_clean(paragraph)
}

session_project_summary_clean :: proc(value: string) -> string {
	// Normalize whitespace and bound the returned summary without splitting UTF-8.
	words := strings.fields(value, context.temp_allocator)
	text := strings.join(words, " ", context.temp_allocator)
	if len(text) < 12 do return ""
	if len(text) > 320 {
		end := 317
		for end > 0 && (transmute([]u8)text)[end] & 0xc0 == 0x80 { end -= 1 }
		text = strings.concatenate({text[:end], "..."}, context.temp_allocator)
	}
	return strings.clone(text)
}

session_project_description :: proc(project: string, read_budget: ^int) -> string {
	for name in ([]string{"AGENTS.md", "CLAUDE.md", "CLAUDE.m"}) {
		if read_budget^ < 16 * 1024 do return ""
		requested := strings.concatenate({project, "/", name}, context.temp_allocator)
		canonical, allowed := session_project_resolve(requested, project)
		defer delete(canonical)
		if !allowed do continue
		info, stat_err := os.stat(canonical, context.temp_allocator)
		if stat_err != nil || info.type != .Regular || info.size > 16 * 1024 do continue
		file, err := os.open(canonical, {.Read})
		if err != nil do continue
		buf := make([]u8, 16 * 1024 + 1)
		used := 0
		for used < len(buf) {
			n, read_err := os.read(file, buf[used:])
			if n > 0 do used += n
			if read_err != nil || n <= 0 do break
		}
		os.close(file)
		read_budget^ -= 16 * 1024
		summary := ""
		if used <= 16 * 1024 { summary = session_project_summary(string(buf[:used])) }
		delete(buf)
		if summary != "" do return summary
	}
	return ""
}
