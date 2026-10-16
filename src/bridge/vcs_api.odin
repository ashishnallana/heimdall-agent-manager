package main

// VCS command handlers (Hub -> Bridge) for the VCS commands, plus their
// typed JSON serialization. Mirrors bridge_fs_handle_command in fs_management.odin:
// each read command is idempotent (results cached by command_id) and replies over the
// runtime WS with the same chunk-safe bridge_hub_send envelope.
//
// Commands:
//   vcs_capabilities  params: {root}                      -> provider + supports_staging
//   vcs_status        params: {root}                      -> branch/remote/ahead/behind/clean
//   vcs_files         params: {root, cursor?, limit?}     -> paginated changed files
//   vcs_diff          params: {root, path|file, cursor?, limit?}-> paginated diff hunks
//
// vcs_commit_diff has two modes: the default returns paginated diff hunks; with
// list_files:true it returns a flat "files":[] list (path/status/+/-) between the
// two refs instead, for the Log tab's file-list selector.
//
// On a path with no recognized VCS, every command returns {ok:false,
// error:{code:"no_vcs"}}. The provider is resolved per request via
// vcs_detect_provider; the caller-supplied path is home-expanded (so "~/proj"
// resolves) but NOT otherwise sandboxed — the task scopes these commands to plain
// detection. (Adding bridge_fs_root containment here would be a straightforward
// follow-up if the hub ever forwards untrusted paths.)

import "core:fmt"
import "core:strings"
import json "core:encoding/json"
import ws "odin_test:lib/ws"

VCS_FILES_DEFAULT_LIMIT :: 100
VCS_FILES_MAX_LIMIT :: 500
VCS_DIFF_DEFAULT_LIMIT :: 50
VCS_DIFF_MAX_LIMIT :: 200
VCS_LOG_DEFAULT_LIMIT :: 100
VCS_LOG_MAX_LIMIT :: 500

// --- Wire Command Structs (incoming over WS) ------------------------------

Bridge_Vcs_Capabilities_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
}

Bridge_Vcs_Status_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
}

Bridge_Vcs_Files_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	cursor:     string `json:"cursor"`,
	limit:      int    `json:"limit"`,
}

Bridge_Vcs_Diff_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	path:       string `json:"path"`,
	file:       string `json:"file"`,
	cursor:     string `json:"cursor"`,
	limit:      int    `json:"limit"`,
}

Bridge_Vcs_Stage_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	path:       string `json:"path"`,
}

Bridge_Vcs_Unstage_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	path:       string `json:"path"`,
}

Bridge_Vcs_Revert_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	path:       string `json:"path"`,
}

Bridge_Vcs_Save_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	path:       string `json:"path"`,
	content:    string `json:"content"`,
}

Bridge_Vcs_Commit_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	message:    string `json:"message"`,
	amend:      bool   `json:"amend"`,
}

Bridge_Vcs_Upload_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
}

Bridge_Vcs_Sync_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
}

Bridge_Vcs_Log_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	cursor:     string `json:"cursor"`,
	limit:      int    `json:"limit"`,
}

Bridge_Vcs_Commit_Diff_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
	base_ref:   string `json:"base_ref"`,
	head_ref:   string `json:"head_ref"`,
	path:       string `json:"path"`,
	file:       string `json:"file"`,
	list_files: bool   `json:"list_files"`,
	cursor:     string `json:"cursor"`,
	limit:      int    `json:"limit"`,
}

Bridge_Vcs_Workspaces_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	root:       string `json:"root"`,
}

// --- Wire Response Structs (outgoing over WS) -----------------------------

Bridge_Vcs_Error_Wire :: Bridge_Result_Error

Bridge_Vcs_Capabilities_Result_Wire :: struct {
	type:              string                `json:"type"`,
	command_id:        string                `json:"command_id"`,
	ok:                bool                  `json:"ok"`,
	provider:          string                `json:"provider"`,
	supports_staging:  bool                  `json:"supports_staging"`,
	supports_amend:    bool                  `json:"supports_amend"`,
	supports_upload:   bool                  `json:"supports_upload"`,
	supports_sync:     bool                  `json:"supports_sync"`,
	upload_label:      string                `json:"upload_label"`,
	sync_label:        string                `json:"sync_label"`,
	staging_model:     string                `json:"staging_model"`,
	commit_model:      string                `json:"commit_model"`,
	supported_actions: []string              `json:"supported_actions"`,
	error:             Bridge_Vcs_Error_Wire `json:"error"`,
}

Bridge_Vcs_Status_Result_Wire :: struct {
	type:       string                `json:"type"`,
	command_id: string                `json:"command_id"`,
	ok:         bool                  `json:"ok"`,
	provider:   string                `json:"provider"`,
	branch:     string                `json:"branch"`,
	remote:     string                `json:"remote"`,
	ahead:      int                   `json:"ahead"`,
	behind:     int                   `json:"behind"`,
	is_clean:   bool                  `json:"is_clean"`,
	error:      Bridge_Vcs_Error_Wire `json:"error"`,
}

Bridge_Vcs_Changed_File_Wire :: struct {
	path:      string `json:"path"`,
	status:    string `json:"status"`,
	staged:    bool   `json:"staged"`,
	additions: int    `json:"additions"`,
	deletions: int    `json:"deletions"`,
}

Bridge_Vcs_Files_Result_Wire :: struct {
	type:        string                         `json:"type"`,
	command_id:  string                         `json:"command_id"`,
	ok:          bool                           `json:"ok"`,
	provider:    string                         `json:"provider"`,
	cursor:      string                         `json:"cursor"`,
	limit:       int                            `json:"limit"`,
	has_more:    bool                           `json:"has_more"`,
	next_cursor: Maybe(string)                  `json:"next_cursor"`,
	files:       []Bridge_Vcs_Changed_File_Wire `json:"files"`,
	error:       Bridge_Vcs_Error_Wire          `json:"error"`,
}

Bridge_Vcs_Diff_Line_Wire :: struct {
	op:   string `json:"op"`,
	text: string `json:"text"`,
}

Bridge_Vcs_Diff_Hunk_Wire :: struct {
	old_start: int                        `json:"old_start"`,
	old_len:   int                        `json:"old_len"`,
	new_start: int                        `json:"new_start"`,
	new_len:   int                        `json:"new_len"`,
	lines:     []Bridge_Vcs_Diff_Line_Wire `json:"lines"`,
}

Bridge_Vcs_Diff_Result_Wire :: struct {
	type:        string                      `json:"type"`,
	command_id:  string                      `json:"command_id"`,
	ok:          bool                        `json:"ok"`,
	provider:    string                      `json:"provider"`,
	file:        string                      `json:"file"`,
	cursor:      string                      `json:"cursor"`,
	limit:       int                         `json:"limit"`,
	has_more:    bool                        `json:"has_more"`,
	next_cursor: Maybe(string)               `json:"next_cursor"`,
	hunks:       []Bridge_Vcs_Diff_Hunk_Wire `json:"hunks"`,
	error:       Bridge_Vcs_Error_Wire       `json:"error"`,
}

Bridge_Vcs_Mutation_Result_Wire :: struct {
	type:       string                `json:"type"`,
	command_id: string                `json:"command_id"`,
	ok:         bool                  `json:"ok"`,
	provider:   string                `json:"provider,omitempty"`,
	error:      Bridge_Vcs_Error_Wire `json:"error"`,
}

Bridge_Vcs_Log_Entry_Wire :: struct {
	hash:          string `json:"hash"`,
	short_hash:    string `json:"short_hash"`,
	subject:       string `json:"subject"`,
	author:        string `json:"author"`,
	date:          string `json:"date"`,
	cl_number:     string `json:"cl_number,omitempty"`,
	review_status: string `json:"review_status,omitempty"`,
}

Bridge_Vcs_Log_Result_Wire :: struct {
	type:        string                      `json:"type"`,
	command_id:  string                      `json:"command_id"`,
	ok:          bool                        `json:"ok"`,
	provider:    string                      `json:"provider"`,
	has_more:    bool                        `json:"has_more"`,
	next_cursor: Maybe(string)               `json:"next_cursor"`,
	entries:     []Bridge_Vcs_Log_Entry_Wire `json:"entries"`,
	error:       Bridge_Vcs_Error_Wire       `json:"error"`,
}

Bridge_Vcs_Commit_File_Wire :: struct {
	path:      string `json:"path"`,
	status:    string `json:"status"`,
	additions: int    `json:"additions"`,
	deletions: int    `json:"deletions"`,
}

Bridge_Vcs_Commit_Diff_Files_Result_Wire :: struct {
	type:       string                        `json:"type"`,
	command_id: string                        `json:"command_id"`,
	ok:         bool                          `json:"ok"`,
	provider:   string                        `json:"provider"`,
	list_files: bool                          `json:"list_files"`,
	base_ref:   string                        `json:"base_ref"`,
	head_ref:   string                        `json:"head_ref"`,
	files:      []Bridge_Vcs_Commit_File_Wire `json:"files"`,
	error:      Bridge_Vcs_Error_Wire         `json:"error"`,
}

Bridge_Vcs_Commit_Diff_Result_Wire :: struct {
	type:        string                      `json:"type"`,
	command_id:  string                      `json:"command_id"`,
	ok:          bool                        `json:"ok"`,
	provider:    string                      `json:"provider"`,
	file:        string                      `json:"file"`,
	base_ref:    string                      `json:"base_ref"`,
	head_ref:    string                      `json:"head_ref"`,
	cursor:      string                      `json:"cursor"`,
	limit:       int                         `json:"limit"`,
	has_more:    bool                        `json:"has_more"`,
	next_cursor: Maybe(string)               `json:"next_cursor"`,
	hunks:       []Bridge_Vcs_Diff_Hunk_Wire `json:"hunks"`,
	error:       Bridge_Vcs_Error_Wire       `json:"error"`,
}

Bridge_Vcs_Workspace_Entry_Wire :: struct {
	path:       string `json:"path"`,
	label:      string `json:"label"`,
	is_current: bool   `json:"is_current"`,
	is_locked:  bool   `json:"is_locked"`,
}

Bridge_Vcs_Workspaces_Result_Wire :: struct {
	type:       string                            `json:"type"`,
	command_id: string                            `json:"command_id"`,
	ok:         bool                              `json:"ok"`,
	provider:   string                            `json:"provider"`,
	workspaces: []Bridge_Vcs_Workspace_Entry_Wire `json:"workspaces"`,
	error:      Bridge_Vcs_Error_Wire             `json:"error"`,
}

// --- Wire Conversion Helpers ----------------------------------------------

@(private)
vcs_to_wire_files :: proc(files: []VCS_Changed_File) -> []Bridge_Vcs_Changed_File_Wire {
	if len(files) == 0 do return []Bridge_Vcs_Changed_File_Wire{}
	out := make([]Bridge_Vcs_Changed_File_Wire, len(files), context.temp_allocator)
	for f, i in files {
		out[i] = Bridge_Vcs_Changed_File_Wire{
			path      = f.path,
			status    = f.status,
			staged    = f.staged,
			additions = f.additions,
			deletions = f.deletions,
		}
	}
	return out
}

@(private)
vcs_to_wire_hunks :: proc(hunks: []VCS_Diff_Hunk) -> []Bridge_Vcs_Diff_Hunk_Wire {
	if len(hunks) == 0 do return []Bridge_Vcs_Diff_Hunk_Wire{}
	out := make([]Bridge_Vcs_Diff_Hunk_Wire, len(hunks), context.temp_allocator)
	for h, i in hunks {
		lines := make([]Bridge_Vcs_Diff_Line_Wire, len(h.lines), context.temp_allocator)
		for l, j in h.lines {
			lines[j] = Bridge_Vcs_Diff_Line_Wire{
				op   = l.op,
				text = l.text,
			}
		}
		out[i] = Bridge_Vcs_Diff_Hunk_Wire{
			old_start = h.old_start,
			old_len   = h.old_len,
			new_start = h.new_start,
			new_len   = h.new_len,
			lines     = lines,
		}
	}
	return out
}

@(private)
vcs_to_wire_log_entries :: proc(entries: []VCS_Log_Entry) -> []Bridge_Vcs_Log_Entry_Wire {
	if len(entries) == 0 do return []Bridge_Vcs_Log_Entry_Wire{}
	out := make([]Bridge_Vcs_Log_Entry_Wire, len(entries), context.temp_allocator)
	for e, i in entries {
		out[i] = Bridge_Vcs_Log_Entry_Wire{
			hash          = e.hash,
			short_hash    = e.short_hash,
			subject       = e.subject,
			author        = e.author,
			date          = e.date,
			cl_number     = e.cl_number,
			review_status = e.review_status,
		}
	}
	return out
}

@(private)
vcs_to_wire_commit_files :: proc(files: []VCS_Changed_File) -> []Bridge_Vcs_Commit_File_Wire {
	if len(files) == 0 do return []Bridge_Vcs_Commit_File_Wire{}
	out := make([]Bridge_Vcs_Commit_File_Wire, len(files), context.temp_allocator)
	for f, i in files {
		out[i] = Bridge_Vcs_Commit_File_Wire{
			path      = f.path,
			status    = f.status,
			additions = f.additions,
			deletions = f.deletions,
		}
	}
	return out
}

@(private)
vcs_to_wire_workspaces :: proc(workspaces: []VCS_Workspace) -> []Bridge_Vcs_Workspace_Entry_Wire {
	if len(workspaces) == 0 do return []Bridge_Vcs_Workspace_Entry_Wire{}
	out := make([]Bridge_Vcs_Workspace_Entry_Wire, len(workspaces), context.temp_allocator)
	for w, i in workspaces {
		out[i] = Bridge_Vcs_Workspace_Entry_Wire{
			path       = w.path,
			label      = w.label,
			is_current = w.is_current,
			is_locked  = w.is_locked,
		}
	}
	return out
}

// bridge_vcs_handle_command dispatches the vcs_* command types over the runtime
// WS. Returns true if `type` was a vcs command (handled), false otherwise. Results
// are cached by command_id for idempotent replay, matching the fs_* handlers.
bridge_vcs_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "vcs_capabilities":
		cmd: Bridge_Vcs_Capabilities_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_capabilities_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_status":
		cmd: Bridge_Vcs_Status_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_status_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_files":
		cmd: Bridge_Vcs_Files_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_files_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_diff":
		cmd: Bridge_Vcs_Diff_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_diff_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	// --- write commands: mutations are NOT idempotent, so they are never cached. ---
	case "vcs_stage":
		cmd: Bridge_Vcs_Stage_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_stage_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_unstage":
		cmd: Bridge_Vcs_Unstage_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_unstage_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_revert":
		cmd: Bridge_Vcs_Revert_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_revert_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_save_file":
		cmd: Bridge_Vcs_Save_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_save_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_commit":
		cmd: Bridge_Vcs_Commit_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_commit_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_upload", "vcs_push":
		cmd: Bridge_Vcs_Upload_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_upload_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_sync", "vcs_pull":
		cmd: Bridge_Vcs_Sync_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		out := bridge_vcs_sync_json(cmd.command_id, text)
		defer delete(out)
		_ = bridge_hub_send(conn, out)
		return true
	// --- read-only commands: cached by command_id like the other read handlers. ---
	case "vcs_log":
		cmd: Bridge_Vcs_Log_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_log_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_commit_diff":
		cmd: Bridge_Vcs_Commit_Diff_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_commit_diff_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "vcs_workspaces":
		cmd: Bridge_Vcs_Workspaces_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		out := bridge_vcs_workspaces_json(cmd.command_id, text)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	}
	return false
}

// vcs_request_path extracts and home-expands the "root" param.
vcs_request_path :: proc(root: string) -> string {
	raw := strings.trim_space(root)
	if raw == "" do return ""
	return bridge_expand_home(raw)
}

// vcs_clamp_limit mirrors the pagination clamp so the response can echo the
// effective limit that was actually applied.
vcs_clamp_limit :: proc(limit, default_limit, max_limit: int) -> int {
	l := limit
	if l <= 0 do l = default_limit
	if l > max_limit do l = max_limit
	return l
}

// --- vcs_capabilities ----------------------------------------------------

bridge_vcs_capabilities_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Capabilities_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Capabilities_Result_Wire{
			type              = "vcs_capabilities_result",
			command_id        = cid,
			ok                = false,
			provider          = "",
			supports_staging  = false,
			supports_amend    = false,
			supports_upload   = false,
			supports_sync     = false,
			upload_label      = "",
			sync_label        = "",
			staging_model     = "",
			commit_model      = "",
			supported_actions = []string{},
			error             = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	caps := provider.capabilities(path)
	actions := caps.supported_actions if caps.supported_actions != nil else []string{}
	wire := Bridge_Vcs_Capabilities_Result_Wire{
		type              = "vcs_capabilities_result",
		command_id        = cid,
		ok                = true,
		provider          = caps.provider,
		supports_staging  = caps.supports_staging,
		supports_amend    = caps.supports_amend,
		supports_upload   = caps.supports_upload,
		supports_sync     = caps.supports_sync,
		upload_label      = caps.upload_label,
		sync_label        = caps.sync_label,
		staging_model     = caps.staging_model,
		commit_model      = caps.commit_model,
		supported_actions = actions,
		error             = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_status ----------------------------------------------------------

bridge_vcs_status_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Status_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Status_Result_Wire{
			type       = "vcs_status_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			branch     = "",
			remote     = "",
			ahead      = 0,
			behind     = 0,
			is_clean   = false,
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	st, sok := provider.status(path)
	if !sok {
		wire := Bridge_Vcs_Status_Result_Wire{
			type       = "vcs_status_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			branch     = "",
			remote     = "",
			ahead      = 0,
			behind     = 0,
			is_clean   = false,
			error      = bridge_result_error("status_failed", "Could not read VCS status"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	wire := Bridge_Vcs_Status_Result_Wire{
		type       = "vcs_status_result",
		command_id = cid,
		ok         = true,
		provider   = st.provider,
		branch     = st.branch,
		remote     = st.remote,
		ahead      = st.ahead,
		behind     = st.behind,
		is_clean   = st.is_clean,
		error      = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_files -----------------------------------------------------------

bridge_vcs_files_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Files_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	eff_limit := vcs_clamp_limit(cmd.limit, VCS_FILES_DEFAULT_LIMIT, VCS_FILES_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Files_Result_Wire{
			type        = "vcs_files_result",
			command_id  = cid,
			ok          = false,
			provider    = "",
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			files       = []Bridge_Vcs_Changed_File_Wire{},
			error       = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	files, next_cursor, has_more, fok := provider.changed_files(path, cmd.cursor, eff_limit)
	if !fok {
		wire := Bridge_Vcs_Files_Result_Wire{
			type        = "vcs_files_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			files       = []Bridge_Vcs_Changed_File_Wire{},
			error       = bridge_result_error("files_failed", "Could not list changed files"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	next_cursor_val: Maybe(string) = next_cursor if next_cursor != "" else nil
	wire := Bridge_Vcs_Files_Result_Wire{
		type        = "vcs_files_result",
		command_id  = cid,
		ok          = true,
		provider    = provider.name(),
		cursor      = cmd.cursor,
		limit       = eff_limit,
		has_more    = has_more,
		next_cursor = next_cursor_val,
		files       = vcs_to_wire_files(files),
		error       = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_diff ------------------------------------------------------------

bridge_vcs_diff_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Diff_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	file := strings.trim_space(cmd.path) if strings.trim_space(cmd.path) != "" else strings.trim_space(cmd.file)
	eff_limit := vcs_clamp_limit(cmd.limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Diff_Result_Wire{
			type        = "vcs_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = "",
			file        = file,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if file == "" {
		wire := Bridge_Vcs_Diff_Result_Wire{
			type        = "vcs_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			file        = "",
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("missing_file", "The 'file' parameter is required for vcs_diff"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	hunks, next_cursor, has_more, dok := provider.diff_file(path, file, cmd.cursor, eff_limit)
	if !dok {
		wire := Bridge_Vcs_Diff_Result_Wire{
			type        = "vcs_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			file        = file,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("diff_failed", "Could not read file diff"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	next_cursor_val: Maybe(string) = next_cursor if next_cursor != "" else nil
	wire := Bridge_Vcs_Diff_Result_Wire{
		type        = "vcs_diff_result",
		command_id  = cid,
		ok          = true,
		provider    = provider.name(),
		file        = file,
		cursor      = cmd.cursor,
		limit       = eff_limit,
		has_more    = has_more,
		next_cursor = next_cursor_val,
		hunks       = vcs_to_wire_hunks(hunks),
		error       = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_stage / vcs_unstage / vcs_revert (write commands) ---------------

bridge_vcs_stage_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_stage_result", "stage", allocator)
}

bridge_vcs_unstage_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_unstage_result", "unstage", allocator)
}

bridge_vcs_revert_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	return bridge_vcs_write_action_json(command_id, text, "vcs_revert_result", "revert", allocator)
}

// bridge_vcs_write_action_json is the shared body for the three write commands,
// which differ only in result `type` and which provider proc runs. Params: repo in
// "root", file in "path" (matching vcs_diff). A nil proc pointer or a "not_supported"
// msg both surface error code "not_supported"; the provider's own failure msg
// (e.g. "untracked_file") becomes the error code otherwise.
bridge_vcs_write_action_json :: proc(command_id, text, result_type, action: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Stage_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	file := strings.trim_space(cmd.path)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = result_type,
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if file == "" {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = result_type,
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("missing_file", "The 'path' parameter is required"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	supported := true
	aok := false
	msg := ""
	switch action {
	case "stage":
		if provider.stage_file == nil { supported = false } else { aok, msg = provider.stage_file(path, file) }
	case "unstage":
		if provider.unstage_file == nil { supported = false } else { aok, msg = provider.unstage_file(path, file) }
	case "revert":
		if provider.revert_file == nil { supported = false } else { aok, msg = provider.revert_file(path, file) }
	}
	if !supported {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = result_type,
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("not_supported", "Action not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	err_wire: Bridge_Vcs_Error_Wire
	if aok {
		err_wire = bridge_result_error("", "")
	} else {
		code := msg if msg != "" else "action_failed"
		err_wire = bridge_result_error(code, vcs_action_error_message(code))
	}
	wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = result_type,
		command_id = cid,
		ok         = aok,
		provider   = provider.name(),
		error      = err_wire,
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_save_file (write command) ---------------------------------------
// Editor save: writes the full text of a working-tree file. Params: repo in "root",
// relative file in "path" (uniform with the other write commands), buffer in
// "content". Never cached (mutation). Result type "vcs_save_file_result".
bridge_vcs_save_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Save_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	file := strings.trim_space(cmd.path)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_save_file_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if file == "" {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_save_file_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("missing_file", "The 'path' parameter is required"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.save_file == nil {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_save_file_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("not_supported", "Save is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	aok, msg := provider.save_file(path, file, cmd.content)
	err_wire: Bridge_Vcs_Error_Wire
	if aok {
		err_wire = bridge_result_error("", "")
	} else {
		code := msg if msg != "" else "save_failed"
		err_wire = bridge_result_error(code, vcs_action_error_message(code))
	}
	wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = "vcs_save_file_result",
		command_id = cid,
		ok         = aok,
		provider   = provider.name(),
		error      = err_wire,
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_commit (write command) ------------------------------------------
// Commits the currently-staged changes with the client-supplied "message". Params:
// repo in "root", message in "message". Never cached (mutation). Result type
// "vcs_commit_result". A nil provider.commit proc surfaces "not_supported"; an empty
// message surfaces "missing_message"; a failed git commit surfaces "commit_failed".
bridge_vcs_commit_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Commit_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	message := strings.trim_space(cmd.message)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_commit_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if message == "" {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_commit_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("missing_message", "The 'message' parameter is required"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.commit == nil {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_commit_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("not_supported", "Commit is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	aok := provider.commit(path, message, cmd.amend)
	err_wire: Bridge_Vcs_Error_Wire
	if aok {
		err_wire = bridge_result_error("", "")
	} else {
		err_wire = bridge_result_error("commit_failed", vcs_action_error_message("commit_failed"))
	}
	wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = "vcs_commit_result",
		command_id = cid,
		ok         = aok,
		provider   = provider.name(),
		error      = err_wire,
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_upload (write command) ------------------------------------------
// Uploads the current branch/chain of commits (e.g. `hg upload chain` for fig).
// Params: repo in "root". Never cached (mutation). Result type "vcs_upload_result".
bridge_vcs_upload_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Upload_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_upload_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.upload == nil {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_upload_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("not_supported", "Upload is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	aok, code, detail := provider.upload(path)
	err_wire: Bridge_Vcs_Error_Wire
	if aok {
		err_wire = bridge_result_error("", "")
	} else {
		err_code := code if code != "" else "upload_failed"
		msg := vcs_action_error_message(err_code)
		if detail != "" {
			msg = fmt.tprintf("%s — %s", msg, detail)
			delete(detail)
		}
		err_wire = bridge_result_error(err_code, msg)
	}
	wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = "vcs_upload_result",
		command_id = cid,
		ok         = aok,
		provider   = provider.name(),
		error      = err_wire,
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_sync (write command) --------------------------------------------
// Syncs current branch/worktree with upstream head (e.g. `hg sync` or `git pull --rebase`).
// Params: repo in "root". Never cached (mutation). Result type "vcs_sync_result".
bridge_vcs_sync_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Sync_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_sync_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.sync == nil {
		wire := Bridge_Vcs_Mutation_Result_Wire{
			type       = "vcs_sync_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			error      = bridge_result_error("not_supported", "Sync is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	aok, code, detail := provider.sync(path)
	err_wire: Bridge_Vcs_Error_Wire
	if aok {
		err_wire = bridge_result_error("", "")
	} else {
		err_code := code if code != "" else "sync_failed"
		msg := vcs_action_error_message(err_code)
		if detail != "" {
			msg = fmt.tprintf("%s — %s", msg, detail)
			delete(detail)
		}
		err_wire = bridge_result_error(err_code, msg)
	}
	wire := Bridge_Vcs_Mutation_Result_Wire{
		type       = "vcs_sync_result",
		command_id = cid,
		ok         = aok,
		provider   = provider.name(),
		error      = err_wire,
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// vcs_action_error_message maps a write-action error code to a human message.
vcs_action_error_message :: proc(code: string) -> string {
	switch code {
	case "not_supported":     return "Action not supported by this provider"
	case "untracked_file":    return "File is untracked and cannot be reverted"
	case "stage_failed":      return "Could not stage file"
	case "unstage_failed":    return "Could not unstage file"
	case "revert_failed":     return "Could not revert file"
	case "save_failed":       return "Could not save file"
	case "commit_failed":     return "Could not create commit (nothing staged, or git rejected it)"
	case "upload_failed":     return "Could not upload changes to remote/Critique"
	case "sync_failed":       return "Could not sync repository with head"
	case "push_failed":       return "Could not push commits to remote repository"
	case "pull_failed":       return "Could not pull commits from remote repository"
	case "missing_message":   return "The 'message' parameter is required"
	case "missing_file":      return "The 'path' parameter is required"
	case "path_outside_root": return "File path is outside the repository root"
	case:                     return "VCS action failed"
	}
}

// --- vcs_log -------------------------------------------------------------

bridge_vcs_log_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Log_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	eff_limit := vcs_clamp_limit(cmd.limit, VCS_LOG_DEFAULT_LIMIT, VCS_LOG_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Log_Result_Wire{
			type        = "vcs_log_result",
			command_id  = cid,
			ok          = false,
			provider    = "",
			has_more    = false,
			next_cursor = nil,
			entries     = []Bridge_Vcs_Log_Entry_Wire{},
			error       = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.log == nil {
		wire := Bridge_Vcs_Log_Result_Wire{
			type        = "vcs_log_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			has_more    = false,
			next_cursor = nil,
			entries     = []Bridge_Vcs_Log_Entry_Wire{},
			error       = bridge_result_error("not_supported", "Log is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	entries, next_cursor, has_more, lok := provider.log(path, cmd.cursor, eff_limit)
	if !lok {
		wire := Bridge_Vcs_Log_Result_Wire{
			type        = "vcs_log_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			has_more    = false,
			next_cursor = nil,
			entries     = []Bridge_Vcs_Log_Entry_Wire{},
			error       = bridge_result_error("log_failed", "Could not read commit log"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	next_cursor_val: Maybe(string) = next_cursor if next_cursor != "" else nil
	wire := Bridge_Vcs_Log_Result_Wire{
		type        = "vcs_log_result",
		command_id  = cid,
		ok          = true,
		provider    = provider.name(),
		has_more    = has_more,
		next_cursor = next_cursor_val,
		entries     = vcs_to_wire_log_entries(entries),
		error       = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_commit_diff -----------------------------------------------------
// Same shape as vcs_diff_result (type "vcs_commit_diff_result"), plus the base/head
// refs echoed back for correlation. Params: repo in "root", optional file in "path"|"file",
// refs in "base_ref"/"head_ref" (head_ref "WORKDIR" or absent = compare to worktree).

bridge_vcs_commit_diff_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Commit_Diff_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	base_ref := strings.trim_space(cmd.base_ref)
	head_ref := strings.trim_space(cmd.head_ref)
	file := strings.trim_space(cmd.path) if strings.trim_space(cmd.path) != "" else strings.trim_space(cmd.file)
	list_files := cmd.list_files
	eff_limit := vcs_clamp_limit(cmd.limit, VCS_DIFF_DEFAULT_LIMIT, VCS_DIFF_MAX_LIMIT)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Commit_Diff_Result_Wire{
			type        = "vcs_commit_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = "",
			file        = file,
			base_ref    = base_ref,
			head_ref    = head_ref,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if base_ref == "" {
		wire := Bridge_Vcs_Commit_Diff_Result_Wire{
			type        = "vcs_commit_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			file        = file,
			base_ref    = base_ref,
			head_ref    = head_ref,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("invalid_ref", "The 'base_ref' parameter is required"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	// File-list mode: return the flat list of changed files (name + status + +/-
	// counts) instead of diff hunks. The response echoes "list_files":true and a
	// "files":[] array (never "hunks"); the hub relays it verbatim and the UI's Log
	// tab renders the selector before loading any per-file diff.
	if list_files {
		if provider.commit_diff_files == nil {
			wire := Bridge_Vcs_Commit_Diff_Files_Result_Wire{
				type       = "vcs_commit_diff_result",
				command_id = cid,
				ok         = false,
				provider   = provider.name(),
				list_files = true,
				base_ref   = base_ref,
				head_ref   = head_ref,
				files      = []Bridge_Vcs_Commit_File_Wire{},
				error      = bridge_result_error("not_supported", "Commit diff file list is not supported by this provider"),
			}
			data, err := json.marshal(wire, allocator = context.temp_allocator)
			if err != nil do return ""
			return strings.clone(string(data), allocator)
		}
		files, dok := provider.commit_diff_files(path, base_ref, head_ref)
		if !dok {
			wire := Bridge_Vcs_Commit_Diff_Files_Result_Wire{
				type       = "vcs_commit_diff_result",
				command_id = cid,
				ok         = false,
				provider   = provider.name(),
				list_files = true,
				base_ref   = base_ref,
				head_ref   = head_ref,
				files      = []Bridge_Vcs_Commit_File_Wire{},
				error      = bridge_result_error("invalid_ref", "Could not diff the requested revisions"),
			}
			data, err := json.marshal(wire, allocator = context.temp_allocator)
			if err != nil do return ""
			return strings.clone(string(data), allocator)
		}
		wire := Bridge_Vcs_Commit_Diff_Files_Result_Wire{
			type       = "vcs_commit_diff_result",
			command_id = cid,
			ok         = true,
			provider   = provider.name(),
			list_files = true,
			base_ref   = base_ref,
			head_ref   = head_ref,
			files      = vcs_to_wire_commit_files(files),
			error      = bridge_result_error("", ""),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.commit_diff == nil {
		wire := Bridge_Vcs_Commit_Diff_Result_Wire{
			type        = "vcs_commit_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			file        = file,
			base_ref    = base_ref,
			head_ref    = head_ref,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("not_supported", "Commit diff is not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	hunks, next_cursor, has_more, dok := provider.commit_diff(path, base_ref, head_ref, file, cmd.cursor, eff_limit)
	if !dok {
		wire := Bridge_Vcs_Commit_Diff_Result_Wire{
			type        = "vcs_commit_diff_result",
			command_id  = cid,
			ok          = false,
			provider    = provider.name(),
			file        = file,
			base_ref    = base_ref,
			head_ref    = head_ref,
			cursor      = cmd.cursor,
			limit       = eff_limit,
			has_more    = false,
			next_cursor = nil,
			hunks       = []Bridge_Vcs_Diff_Hunk_Wire{},
			error       = bridge_result_error("invalid_ref", "Could not diff the requested revisions"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	next_cursor_val: Maybe(string) = next_cursor if next_cursor != "" else nil
	wire := Bridge_Vcs_Commit_Diff_Result_Wire{
		type        = "vcs_commit_diff_result",
		command_id  = cid,
		ok          = true,
		provider    = provider.name(),
		file        = file,
		base_ref    = base_ref,
		head_ref    = head_ref,
		cursor      = cmd.cursor,
		limit       = eff_limit,
		has_more    = has_more,
		next_cursor = next_cursor_val,
		hunks       = vcs_to_wire_hunks(hunks),
		error       = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

// --- vcs_workspaces ------------------------------------------------------

bridge_vcs_workspaces_json :: proc(command_id, text: string, allocator := context.allocator) -> string {
	cmd: Bridge_Vcs_Workspaces_Command
	_ = json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	cid := command_id if command_id != "" else cmd.command_id
	path := vcs_request_path(cmd.root)
	provider, ok := vcs_detect_provider(path)
	if !ok {
		wire := Bridge_Vcs_Workspaces_Result_Wire{
			type       = "vcs_workspaces_result",
			command_id = cid,
			ok         = false,
			provider   = "",
			workspaces = []Bridge_Vcs_Workspace_Entry_Wire{},
			error      = bridge_result_error("no_vcs", "No supported version control system found at path"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	if provider.list_workspaces == nil {
		wire := Bridge_Vcs_Workspaces_Result_Wire{
			type       = "vcs_workspaces_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			workspaces = []Bridge_Vcs_Workspace_Entry_Wire{},
			error      = bridge_result_error("not_supported", "Workspaces are not supported by this provider"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	workspaces, wok := provider.list_workspaces(path)
	if !wok {
		wire := Bridge_Vcs_Workspaces_Result_Wire{
			type       = "vcs_workspaces_result",
			command_id = cid,
			ok         = false,
			provider   = provider.name(),
			workspaces = []Bridge_Vcs_Workspace_Entry_Wire{},
			error      = bridge_result_error("workspaces_failed", "Could not list workspaces"),
		}
		data, err := json.marshal(wire, allocator = context.temp_allocator)
		if err != nil do return ""
		return strings.clone(string(data), allocator)
	}
	wire := Bridge_Vcs_Workspaces_Result_Wire{
		type       = "vcs_workspaces_result",
		command_id = cid,
		ok         = true,
		provider   = provider.name(),
		workspaces = vcs_to_wire_workspaces(workspaces),
		error      = bridge_result_error("", ""),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}
