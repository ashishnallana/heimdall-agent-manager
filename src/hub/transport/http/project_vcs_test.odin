package http

// Unit tests for the project-scoped VCS relay wire contract and the worktree_path
// whitelist guard. project_vcs_command_json and vcs_workspaces_has_path are pure, so
// these lock the JSON the hub relays to the bridge and the membership check that
// backs the ?worktree_path override — without needing a live bridge/registry. The
// auth/owner/online guards in project_vcs_relay reuse the same primitives as
// project_fs_relay (resolve_fs_target, bridge_service.get_bridge,
// bridge_runtime_registry_has_live), which are covered by the service tests.

import "core:strings"
import "core:testing"

@(test)
test_vcs_command_timeout_ms_network_commands :: proc(t: ^testing.T) {
	for command_type in ([]string{"vcs_upload", "vcs_push", "vcs_sync", "vcs_pull"}) {
		testing.expectf(t, vcs_command_timeout_ms(command_type) == 120_000, "%s has 120-second timeout", command_type)
	}
}

@(test)
test_vcs_command_timeout_ms_default_commands :: proc(t: ^testing.T) {
	for command_type in ([]string{"vcs_status", "vcs_commit", "vcs_workspaces"}) {
		testing.expectf(t, vcs_command_timeout_ms(command_type) == 10_000, "%s retains 10-second timeout", command_type)
	}
}

@(test)
test_project_vcs_command_json_commit_diff_contract :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = "HEAD~1", send_base_ref = true,
		head_ref = "HEAD", send_head_ref = true,
		path = "src/main.odin", send_path = true,
		cursor = "c1", send_cursor = true,
		limit = 25, send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_pvcs_1", "/home/u/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_commit_diff\""), "type present")
	testing.expect(t, strings.contains(out, "\"command_id\":\"cmd_pvcs_1\""), "command_id present")
	testing.expect(t, strings.contains(out, "\"root\":\"/home/u/repo\""), "root present")
	testing.expect(t, strings.contains(out, "\"base_ref\":\"HEAD~1\""), "base_ref present")
	testing.expect(t, strings.contains(out, "\"head_ref\":\"HEAD\""), "head_ref present")
	testing.expect(t, strings.contains(out, "\"path\":\"src/main.odin\""), "path present")
	testing.expect(t, strings.contains(out, "\"cursor\":\"c1\""), "cursor present")
	testing.expect(t, strings.contains(out, "\"limit\":25"), "limit present")
}

// list_files mode (TASK-B): project_handle_vcs_commit_diff sets send_list_files=true
// and, when ?list_files=true, list_files=true with send_cursor/send_limit=false. The
// relayed body must then carry "list_files":true and NOT carry cursor/limit (the file
// list is not paginated).
@(test)
test_project_vcs_command_json_commit_diff_list_files :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = "abc123", send_base_ref = true,
		head_ref = "def456", send_head_ref = true,
		list_files = true, send_list_files = true,
		send_cursor = false, // handler drops cursor/limit in list_files mode
		send_limit = false,
	}
	out := project_vcs_command_json(cmd, "cmd_cd_lf", "/repo/root")
	testing.expect(t, strings.contains(out, "\"list_files\":true"), "list_files:true emitted")
	testing.expect(t, strings.contains(out, "\"base_ref\":\"abc123\""), "base_ref present")
	testing.expect(t, strings.contains(out, "\"head_ref\":\"def456\""), "head_ref present")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "cursor omitted in list_files mode")
	testing.expect(t, !strings.contains(out, "\"limit\""), "limit omitted in list_files mode")
}

// Default hunk mode (list_files=false, even with send_list_files=true) must NOT emit
// the list_files field, and still forwards cursor/limit — no regression.
@(test)
test_project_vcs_command_json_commit_diff_no_list_files :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = "HEAD~1", send_base_ref = true,
		head_ref = "HEAD", send_head_ref = true,
		list_files = false, send_list_files = true,
		cursor = "c1", send_cursor = true,
		limit = 50, send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_cd_nolf", "/repo")
	testing.expect(t, !strings.contains(out, "\"list_files\""), "list_files omitted when false")
	testing.expect(t, strings.contains(out, "\"cursor\":\"c1\""), "cursor still forwarded in hunk mode")
	testing.expect(t, strings.contains(out, "\"limit\":50"), "limit still forwarded in hunk mode")
}

// vcs_commit (TASK-E): project_handle_vcs_commit relays message with send_message=true.
// The body must carry "message":"<escaped>" and the command type vcs_commit.
@(test)
test_project_vcs_command_json_commit_message :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{
		command_type = "vcs_commit",
		message = "fix: repair the "+`"parser"`, send_message = true,
	}
	out := project_vcs_command_json(cmd, "cmd_commit_1", "/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_commit\""), "type is vcs_commit")
	// The embedded quotes must be JSON-escaped by write_handler_json_string.
	testing.expect(t, strings.contains(out, "\"message\":\"fix: repair the \\\"parser\\\"\""), "message present and escaped")
	testing.expect(t, !strings.contains(out, "\"path\""), "no path field for commit")
}

// An empty message (or send_message=false) must NOT emit the message field.
@(test)
test_project_vcs_command_json_commit_omits_empty_message :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{command_type = "vcs_commit", message = "", send_message = true}
	out := project_vcs_command_json(cmd, "cmd_commit_2", "/repo")
	testing.expect(t, !strings.contains(out, "\"message\""), "empty message omitted")
}

@(test)
test_project_vcs_command_json_omits_unset_refs :: proc(t: ^testing.T) {
	// vcs_log-style command: no refs, no path.
	cmd := Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = "", send_cursor = true,
		limit = 50, send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_pvcs_2", "/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_log\""), "type present")
	testing.expect(t, strings.contains(out, "\"limit\":50"), "limit present")
	testing.expect(t, !strings.contains(out, "\"base_ref\""), "omit base_ref when unset")
	testing.expect(t, !strings.contains(out, "\"head_ref\""), "omit head_ref when unset")
	testing.expect(t, !strings.contains(out, "\"path\""), "omit path when unset")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "omit cursor when empty")
}

@(test)
test_vcs_workspaces_has_path_matches :: proc(t: ^testing.T) {
	reply := "{\"type\":\"vcs_workspaces_result\",\"command_id\":\"c\",\"ok\":true,\"provider\":\"git\",\"workspaces\":[{\"path\":\"/home/u/repo\",\"label\":\"main\",\"is_current\":true,\"is_locked\":false},{\"path\":\"/home/u/wt/feature\",\"label\":\"feature\",\"is_current\":false,\"is_locked\":false}],\"error\":{\"code\":\"\",\"message\":\"\"}}"
	testing.expect(t, vcs_workspaces_has_path(reply, "/home/u/repo"), "current workspace matches")
	testing.expect(t, vcs_workspaces_has_path(reply, "/home/u/wt/feature"), "secondary workspace matches")
	testing.expect(t, !vcs_workspaces_has_path(reply, "/home/u/wt/other"), "unlisted path rejected")
	testing.expect(t, !vcs_workspaces_has_path(reply, "/home/u"), "prefix of a workspace is not a match")
}

@(test)
test_vcs_workspaces_has_path_empty_or_missing :: proc(t: ^testing.T) {
	empty := "{\"type\":\"vcs_workspaces_result\",\"ok\":false,\"provider\":\"\",\"workspaces\":[],\"error\":{\"code\":\"no_vcs\",\"message\":\"x\"}}"
	testing.expect(t, !vcs_workspaces_has_path(empty, "/home/u/repo"), "empty list matches nothing")
	missing := "{\"type\":\"vcs_workspaces_result\",\"ok\":false}"
	testing.expect(t, !vcs_workspaces_has_path(missing, "/home/u/repo"), "absent workspaces array matches nothing")
}

// --- TASK-2-TEST: per-endpoint command-JSON contracts (all 6 new endpoints) -----
// The hub VCS endpoints are thin WS relays: each handler maps request query/body onto
// a Project_Vcs_Command and project_vcs_command_json builds the exact WS body relayed
// to the bridge (the bridge reply is then forwarded verbatim — see project_vcs_relay).
// These tests construct each command the SAME way its handler does (query_value /
// query_int / json_string on a request string), so they exercise the real query->body
// mapping, not just hand-set struct fields. Git semantics (entries, hunks, has_more,
// is_current, not_supported, untracked_file) live on the bridge and are covered by the
// bridge tests (src/bridge/vcs_test.odin, vcs_api_test.odin, vcs_integration_test.odin).

// HT-LOG (wire contract): project_handle_vcs_log builds vcs_log with limit (default 50)
// always emitted and cursor omitted when empty.
@(test)
test_project_vcs_command_json_log_defaults :: proc(t: ^testing.T) {
	q := "" // no cursor, no limit -> handler defaults limit to 50
	cmd := Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = query_value(q, "cursor"), send_cursor = true,
		limit = query_int(q, "limit", 50), send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_log_1", "/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_log\""), "type present")
	testing.expect(t, strings.contains(out, "\"root\":\"/repo\""), "root present")
	testing.expect(t, strings.contains(out, "\"limit\":50"), "limit defaults to 50")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "empty cursor omitted")
}

// HT-LOG-3 (pagination wire): a follow-up page carries the caller's limit and cursor.
@(test)
test_project_vcs_command_json_log_pagination :: proc(t: ^testing.T) {
	q := "limit=2&cursor=abc123"
	cmd := Project_Vcs_Command{
		command_type = "vcs_log",
		cursor = query_value(q, "cursor"), send_cursor = true,
		limit = query_int(q, "limit", 50), send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_log_2", "/repo")
	testing.expect(t, strings.contains(out, "\"limit\":2"), "limit parsed from query")
	testing.expect(t, strings.contains(out, "\"cursor\":\"abc123\""), "cursor forwarded when set")
}

// HT-CDIFF (wire contract): project_handle_vcs_commit_diff always sends base_ref,
// head_ref and path (file). The hub forwards these VERBATIM — the empty/WORKDIR
// head_ref -> worktree semantic is the bridge's, so head_ref="WORKDIR" and an absent
// file (path:"") are emitted as-is rather than omitted.
@(test)
test_project_vcs_command_json_commit_diff_workdir_verbatim :: proc(t: ^testing.T) {
	q := "base_ref=HEAD~1&head_ref=WORKDIR" // no file
	cmd := Project_Vcs_Command{
		command_type = "vcs_commit_diff",
		base_ref = query_value(q, "base_ref"), send_base_ref = true,
		head_ref = query_value(q, "head_ref"), send_head_ref = true,
		path = query_value(q, "file"), send_path = true,
		cursor = query_value(q, "cursor"), send_cursor = true,
		limit = query_int(q, "limit", 50), send_limit = true,
	}
	out := project_vcs_command_json(cmd, "cmd_cd_1", "/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_commit_diff\""), "type present")
	testing.expect(t, strings.contains(out, "\"base_ref\":\"HEAD~1\""), "base_ref forwarded")
	testing.expect(t, strings.contains(out, "\"head_ref\":\"WORKDIR\""), "head_ref forwarded verbatim (bridge maps WORKDIR)")
	testing.expect(t, strings.contains(out, "\"path\":\"\""), "absent file forwarded as empty path")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "empty cursor omitted")
	testing.expect(t, strings.contains(out, "\"limit\":50"), "limit defaults to 50")
}

// HT-WS (wire contract): project_handle_vcs_workspaces sends only type + root.
@(test)
test_project_vcs_command_json_workspaces_minimal :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{command_type = "vcs_workspaces"}
	out := project_vcs_command_json(cmd, "cmd_ws_1", "/home/u/repo")
	testing.expect(t, strings.contains(out, "\"type\":\"vcs_workspaces\""), "type present")
	testing.expect(t, strings.contains(out, "\"root\":\"/home/u/repo\""), "root present")
	testing.expect(t, !strings.contains(out, "\"path\""), "no path")
	testing.expect(t, !strings.contains(out, "\"base_ref\""), "no base_ref")
	testing.expect(t, !strings.contains(out, "\"limit\""), "no limit")
	testing.expect(t, !strings.contains(out, "\"cursor\""), "no cursor")
}

// HT-STAGE/UNSTAGE/REVERT (wire contract): the shared write handler maps the POST body
// {"file":"<rel>"} onto the command's path field. json_string(body,"file") is the exact
// extraction the handler uses.
@(test)
test_project_vcs_command_json_write_endpoints_map_file_to_path :: proc(t: ^testing.T) {
	body := "{\"file\":\"src/main.odin\"}"
	for cmd_type in ([]string{"vcs_stage", "vcs_unstage", "vcs_revert"}) {
		cmd := Project_Vcs_Command{
			command_type = cmd_type,
			path = json_string(body, "file"), send_path = true,
		}
		out := project_vcs_command_json(cmd, "cmd_w_1", "/repo")
		testing.expectf(t, strings.contains(out, strings.concatenate({"\"type\":\"", cmd_type, "\""})), "type %s present", cmd_type)
		testing.expectf(t, strings.contains(out, "\"path\":\"src/main.odin\""), "%s maps body file -> path", cmd_type)
		testing.expectf(t, strings.contains(out, "\"root\":\"/repo\""), "%s root present", cmd_type)
		testing.expectf(t, !strings.contains(out, "\"base_ref\""), "%s no refs", cmd_type)
	}
}

// HT-STAGE-2 / HT-UNSTAGE-2 (wire contract): an empty/missing file body yields an empty
// path forwarded to the bridge (which returns ok:false); the hub does not reject here.
@(test)
test_project_vcs_command_json_write_empty_file :: proc(t: ^testing.T) {
	cmd := Project_Vcs_Command{
		command_type = "vcs_stage",
		path = json_string("{}", "file"), send_path = true,
	}
	out := project_vcs_command_json(cmd, "cmd_w_2", "/repo")
	testing.expect(t, strings.contains(out, "\"path\":\"\""), "missing file -> empty path forwarded")
}

// --- TASK-2-TEST: worktree_path whitelist guard (hub-unique security logic) ------
// project_vcs_effective_root resolves the repo root, honoring ?worktree_path only when
// it is absolute AND advertised in the bridge's vcs_workspaces list. The empty and
// non-absolute branches return before any bridge round-trip, so they are unit-testable
// with a zero-value Bridge_Handlers (never dereferenced on these paths).

// HT-WT-3: absent worktree_path keeps the project root unchanged.
@(test)
test_worktree_path_empty_uses_project_root :: proc(t: ^testing.T) {
	bh: Bridge_Handlers
	req := Request{query = ""}
	root, ok, err := project_vcs_effective_root(&bh, req, "brg_x", "/home/u/repo")
	testing.expect(t, ok, "empty worktree_path accepted")
	testing.expect(t, root == "/home/u/repo", "effective root is project root")
	testing.expect(t, err.code == .None, "no error")
}

// HT-WT-3 (whitespace): a blank worktree_path is trimmed to empty and uses the root.
@(test)
test_worktree_path_blank_uses_project_root :: proc(t: ^testing.T) {
	bh: Bridge_Handlers
	req := Request{query = "worktree_path=%20%20"}
	root, ok, err := project_vcs_effective_root(&bh, req, "brg_x", "/home/u/repo")
	testing.expect(t, ok, "blank worktree_path accepted")
	testing.expect(t, root == "/home/u/repo", "effective root is project root")
	testing.expect(t, err.code == .None, "no error")
}

// Path-traversal guard: a non-absolute worktree_path is rejected with 400 before any
// bridge lookup (it can never match an absolute workspace path anyway).
@(test)
test_worktree_path_non_absolute_rejected :: proc(t: ^testing.T) {
	bh: Bridge_Handlers
	req := Request{query = "worktree_path=..%2Fescape"}
	root, ok, err := project_vcs_effective_root(&bh, req, "brg_x", "/home/u/repo")
	testing.expect(t, !ok, "non-absolute worktree_path rejected")
	testing.expect(t, root == "", "no effective root on rejection")
	testing.expect(t, err.code == .Validation_Failed, "validation_failed (400)")
	testing.expect(t, strings.contains(err.details_json, "worktree_path_not_in_workspaces"), "machine code in details")
	testing.expect(t, strings.contains(err.details_json, "../escape"), "rejected path echoed in details")
}

// HT-WT-1 / HT-WT-2: the membership decision that backs the whitelist. In-list paths
// are accepted (the effective root becomes the worktree); out-of-list paths are refused
// with the shared 400. This is the decision project_vcs_effective_root makes on the
// bridge's vcs_workspaces reply once an absolute worktree_path passes the prefix guard.
@(test)
test_worktree_path_whitelist_accept_and_reject :: proc(t: ^testing.T) {
	reply := "{\"type\":\"vcs_workspaces_result\",\"ok\":true,\"provider\":\"git\",\"workspaces\":[{\"path\":\"/home/u/repo\",\"label\":\"main\",\"is_current\":true},{\"path\":\"/home/u/wt/feature\",\"label\":\"feature\",\"is_current\":false}],\"error\":{\"code\":\"\",\"message\":\"\"}}"
	// HT-WT-1: a path the bridge advertises is accepted.
	testing.expect(t, vcs_workspaces_has_path(reply, "/home/u/wt/feature"), "HT-WT-1: listed worktree accepted")
	// HT-WT-2: a path NOT advertised is rejected -> shared 400.
	testing.expect(t, !vcs_workspaces_has_path(reply, "/home/u/wt/rogue"), "HT-WT-2: unlisted worktree rejected")
	err := worktree_path_rejected_error("/home/u/wt/rogue")
	testing.expect(t, err.code == .Validation_Failed, "HT-WT-2: rejection is 400")
	testing.expect(t, err.message == "worktree_path_not_in_workspaces", "HT-WT-2: machine code")
	testing.expect(t, strings.contains(err.details_json, "\"path\":\"/home/u/wt/rogue\""), "HT-WT-2: offending path echoed")
}
