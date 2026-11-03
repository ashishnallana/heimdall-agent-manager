package http

import "core:strings"
import "core:testing"

// The bridge-scoped GET /bridges/{id}/fs/file relay sends the bridge's existing
// fs_read_file command WITHOUT a project root (so the bridge sandboxes the path to
// its fs_root) and forwards the byte-range page only when one was asked for.
@(test)
test_bridge_fs_command_json_read_file_page :: proc(t: ^testing.T) {
	plain := bridge_fs_command_json("fs_read_file", "cmd_1", "/home/u/repo/AGENTS.md")
	defer delete(plain)
	testing.expect_value(t, plain, `{"type":"fs_read_file","command_id":"cmd_1","path":"/home/u/repo/AGENTS.md"}`)
	testing.expect(t, !strings.contains(plain, `"root"`), "no project root: the bridge sandboxes to fs_root")

	paged := bridge_fs_command_json("fs_read_file", "cmd_2", "a \"b\".md", 8192, 4096)
	defer delete(paged)
	testing.expect_value(t, paged, `{"type":"fs_read_file","command_id":"cmd_2","path":"a \"b\".md","offset":8192,"limit":4096}`)

	// list/stat/mkdir keep their exact previous body.
	list := bridge_fs_command_json("fs_list_dir", "cmd_3", "")
	defer delete(list)
	testing.expect_value(t, list, `{"type":"fs_list_dir","command_id":"cmd_3","path":""}`)
}
