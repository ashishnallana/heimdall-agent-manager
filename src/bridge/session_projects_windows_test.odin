#+build windows
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import json "core:encoding/json"
import win "core:sys/windows"

session_test_junction :: proc(t: ^testing.T, link, target: string) -> bool {
	quoted_link, _ := strings.replace_all(link, "'", "''", context.temp_allocator)
	quoted_target, _ := strings.replace_all(target, "'", "''", context.temp_allocator)
	script := fmt.tprintf("$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path '%s' -Target '%s' | Out-Null", quoted_link, quoted_target)
	wide := win.utf8_to_utf16(script, context.temp_allocator)
	utf16 := make([]byte, len(wide)*2, context.temp_allocator)
	for c, i in wide { utf16[i*2] = u8(c); utf16[i*2+1] = u8(c >> 8) }
	encoded := base64.encode(utf16, base64.ENC_TABLE, context.temp_allocator)
	out, errout, ok, _ := bridge_process_run_capture({"powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded}, 10*time.Second)
	defer { delete(out); delete(errout) }
	return testing.expect(t, ok, fmt.tprintf("create an isolated NTFS junction without elevated symlink privileges: %s", errout))
}

@(test)
session_projects_windows_junction_escape_and_alias :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	sandbox := fmt.tprintf("%s/sandbox", root)
	outside := fmt.tprintf("%s/outside", root)
	project := fmt.tprintf("%s/project with spaces", sandbox)
	_ = os.make_directory_all(project)
	_ = os.make_directory_all(fmt.tprintf("%s/private", outside))
	link := fmt.tprintf("%s/escape", sandbox)
	if !session_test_junction(t, link, outside) do return
	escape := fmt.tprintf("%s/private", link)
	resolved, allowed := session_project_resolve(escape, sandbox)
	delete(resolved)
	testing.expect(t, !allowed, "a descendant of an escaping junction must not pass sandbox containment")
	meta := struct {type: string, payload: struct {cwd: string}}{type = "session_meta", payload = {cwd = escape}}
	data := json.marshal(meta, allocator = context.temp_allocator) or_else nil
	session_test_seed(t, sandbox, ".codex/sessions/2026/rollout-escape.jsonl", string(data))
	meta.payload.cwd = project
	data = json.marshal(meta, allocator = context.temp_allocator) or_else nil
	session_test_seed(t, sandbox, ".codex/sessions/2026/rollout-owned.jsonl", string(data))
	result := session_projects_discover(sandbox, sandbox)
	defer session_projects_destroy(&result)
	if testing.expect_value(t, len(result.projects), 1) {
		testing.expect(t, session_project_path_equal(result.projects[0].path, project), "nested native traversal retains the real project")
	}
	alias := fmt.tprintf("%s/alias", sandbox)
	if !session_test_junction(t, alias, project) do return
	canonical, inside := session_project_resolve(alias, sandbox)
	defer delete(canonical)
	testing.expect(t, inside && session_project_path_equal(canonical, project), "an in-sandbox alias resolves to one actual project")
}
