package main

// Sandboxed filesystem directory management for the bridge host.
//
// Powers the UI's bridge-aware directory picker (browse + create project paths)
// and the "is this project path present on bridge X?" check. All operations are
// confined to a configured trusted root (default $HOME) — see the security model
// in docs/plans/bridge-directory-management.md.
//
// v1 capabilities: list a directory, stat a path, mkdir -p. No file contents, no
// delete/rename, no browsing outside the root.

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:time"
import "core:c/libc"
import base64 "core:encoding/base64"
import json "core:encoding/json"
import ws "odin_test:lib/ws"
import cfg_lib "odin_test:lib/config"
import vault "odin_test:lib/vault"

// The resolved (symlink-free, absolute) sandbox root. Set once at startup by
// bridge_fs_init. Empty means FS management is effectively disabled (deny all).
bridge_fs_root: string

// Configured chunk size for paginated fs_read_file reads. Default 16_000.
bridge_fs_read_page_bytes: i64 = BRIDGE_FS_READ_PAGE_BYTES

// bridge_fs_init resolves the configured fs_root (or $HOME when unset) to a real
// absolute path and stores it. Call once at startup.
bridge_fs_init :: proc(configured_root: string, read_page_bytes: i64 = BRIDGE_FS_READ_PAGE_BYTES) {
	// Effective page is gated on the TLS backend (REQ-4): the larger page is only
	// safe under socat. Under the s_client fallback the effective page is hard-
	// clamped to the safe BRIDGE_FS_READ_PAGE_BYTES ceiling regardless of config —
	// this also fixes the historical mismatch where the nix/config default (16000)
	// exceeded the ~11 KB s_client ceiling and could itself trigger the teardown.
	if bridge_tls_backend_is_socat() {
		if read_page_bytes > 0 {
			bridge_fs_read_page_bytes = read_page_bytes
		} else {
			bridge_fs_read_page_bytes = BRIDGE_FS_READ_PAGE_BYTES_SOCAT
		}
	} else {
		page := read_page_bytes if read_page_bytes > 0 else BRIDGE_FS_READ_PAGE_BYTES
		if page > BRIDGE_FS_READ_PAGE_BYTES do page = BRIDGE_FS_READ_PAGE_BYTES
		bridge_fs_read_page_bytes = page
	}
	home := cfg_lib.home_dir()
	root := strings.trim_space(configured_root)
	// Default to $HOME when unset. Also expand a bare "~" or "~/..." to $HOME
	// (bridge_expand_home only handles the "~/" form, so handle bare "~" here).
	if root == "" || root == "~" {
		root = home != "" ? home : "/"
	} else {
		root = bridge_expand_home(root)
	}
	// Resolve symlinks + make absolute so containment compares real paths. NOTE:
	// os.get_absolute_path only makes the path absolute — it does NOT resolve
	// symlinks. That matters because project-root overrides are canonicalized via
	// bridge_fs_realpath_existing_prefix (which DOES follow symlinks), so on a host
	// where the root traverses a symlink (e.g. macOS /tmp -> /private/tmp) the two
	// would never prefix-match and every project-scoped fs op would fail with
	// path_outside_root. Resolve the existing prefix here too so both sides compare
	// the same real path.
	bridge_fs_root = bridge_fs_canonicalize_existing(root)
	fmt.printfln("bridge fs sandbox root: %s (chunk_size: %d bytes)", bridge_fs_root, bridge_fs_read_page_bytes)
}

Bridge_Fs_Entry :: struct {
	name:        string `json:"name"`,
	is_dir:      bool   `json:"is_dir"`,
	hidden:      bool   `json:"hidden"`,
	has_git:     bool   `json:"has_git"`,
	size:        i64    `json:"size"`,    // bytes for regular files; 0 for dirs
	modified_at: string `json:"modified_at"`, // RFC3339 UTC
}

Bridge_Fs_List_Result :: struct {
	ok:          bool,
	path:        string, // canonical absolute path actually listed
	root:        string, // sandbox root (for UI breadcrumb bounds)
	parent:      string, // parent within root, or "" if path == root
	entries:     []Bridge_Fs_Entry,
	next_cursor: string, // opaque base64 offset for the next page ("" when none)
	has_more:    bool,
	truncated:   bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Read_File_Result :: struct {
	ok:          bool,
	path:        string,
	viewable:    bool,
	content:     string,
	encoding:    string, // "utf8" | "base64" | ""
	mime:        string,
	size:        i64,
	modified_at: string,
	truncated:   bool,
	// Byte-range pagination (utf8 text only). offset = byte offset of the first
	// byte of `content` within the file; bytes_returned = number of file bytes
	// this chunk covers (may be < len(content) is impossible, but may be trimmed
	// back from the requested limit to a UTF-8 boundary); eof = this chunk reaches
	// end of file. Callers page by requesting offset += bytes_returned until eof.
	offset:         i64,
	bytes_returned: i64,
	eof:            bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Create_File_Result :: struct {
	ok:          bool,
	path:        string,
	created:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Write_File_Result :: struct {
	ok:            bool,
	path:          string,
	bytes_written: int,
	modified_at:   string,
	within_root:   bool,
	error_code:    string,
	message:       string,
}

Bridge_Fs_Write_Item :: struct {
	path:    string `json:"path"`,
	content: string `json:"content"`,
}

Bridge_Fs_Saved_Item :: struct {
	path:          string `json:"path"`,
	bytes_written: int    `json:"bytes_written"`,
	modified_at:   string `json:"modified_at"`,
}

Bridge_Fs_Error_Item :: struct {
	path:       string `json:"path"`,
	error_code: string `json:"error_code"`,
	message:    string `json:"message"`,
}

Bridge_Fs_Batch_Write_Result :: struct {
	ok:         bool,
	saved:      []Bridge_Fs_Saved_Item,
	errors:     []Bridge_Fs_Error_Item,
	error_code: string,
	message:    string,
}

Bridge_Fs_Move_Result :: struct {
	ok:          bool,
	from:        string,
	to:          string,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Delete_Result :: struct {
	ok:          bool,
	path:        string,
	deleted:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Stat_Result :: struct {
	ok:          bool, // request itself succeeded (within root, no fatal error)
	path:        string,
	exists:      bool,
	is_dir:      bool,
	has_git:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Mkdir_Result :: struct {
	ok:          bool,
	path:        string,
	created:     bool, // false if it already existed as a dir (idempotent)
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Find_Files_Result :: struct {
	ok:         bool,
	root:       string,
	files:      []string,
	truncated:  bool,
	error_code: string,
	message:    string,
}

Bridge_Fs_Grep_Match :: struct {
	path:        string `json:"path"`,
	line_number: int    `json:"line_number"`,
	line:        string `json:"line"`,
}

Bridge_Fs_Grep_Result :: struct {
	ok:         bool,
	root:       string,
	matches:    []Bridge_Fs_Grep_Match,
	truncated:  bool,
	error_code: string,
	message:    string,
}

Bridge_Fs_Error_Wire :: Bridge_Result_Error

// --- Wire Command Structs (incoming over WS) ------------------------------

Bridge_Fs_List_Command :: struct {
	type:           string      `json:"type"`,
	command_id:     string      `json:"command_id"`,
	path:           string      `json:"path"`,
	include_hidden: Maybe(bool) `json:"include_hidden"`,
	cursor:         string      `json:"cursor"`,
	limit:          int         `json:"limit"`,
	root:           string      `json:"root"`,
	instance_id:    string      `json:"instance_id"`,
}

Bridge_Fs_Read_Command :: struct {
	type:        string `json:"type"`,
	command_id:  string `json:"command_id"`,
	path:        string `json:"path"`,
	root:        string `json:"root"`,
	offset:      i64    `json:"offset"`,
	limit:       i64    `json:"limit"`,
	instance_id: string `json:"instance_id"`,
}

Bridge_Fs_Create_File_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	path:       string `json:"path"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Write_File_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	path:       string `json:"path"`,
	content:    string `json:"content"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Batch_Write_Command :: struct {
	type:       string                 `json:"type"`,
	command_id: string                 `json:"command_id"`,
	root:       string                 `json:"root"`,
	files:      []Bridge_Fs_Write_Item `json:"files"`,
}

Bridge_Fs_Move_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	from:       string `json:"from"`,
	to:         string `json:"to"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Delete_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	path:       string `json:"path"`,
	recursive:  bool   `json:"recursive"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Stat_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	path:       string `json:"path"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Mkdir_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	path:       string `json:"path"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Find_Files_Command :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	query:      string `json:"query"`,
	limit:      int    `json:"limit"`,
	root:       string `json:"root"`,
}

Bridge_Fs_Grep_Command :: struct {
	type:           string `json:"type"`,
	command_id:     string `json:"command_id"`,
	query:          string `json:"query"`,
	case_sensitive: bool   `json:"case_sensitive"`,
	limit:          int    `json:"limit"`,
	max_results:    int    `json:"max_results"`,
	root:           string `json:"root"`,
}

// --- Wire Response Structs (outgoing over WS) -----------------------------

Bridge_Fs_List_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	path:        string               `json:"path"`,
	root:        string               `json:"root"`,
	parent:      string               `json:"parent"`,
	truncated:   bool                 `json:"truncated"`,
	has_more:    bool                 `json:"has_more"`,
	next_cursor: Maybe(string)        `json:"next_cursor"`,
	entries:     []Bridge_Fs_Entry    `json:"entries"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Read_Result_Wire :: struct {
	type:           string               `json:"type"`,
	command_id:     string               `json:"command_id"`,
	ok:             bool                 `json:"ok"`,
	path:           string               `json:"path"`,
	viewable:       bool                 `json:"viewable"`,
	content:        Maybe(string)        `json:"content,omitempty"`,
	encoding:       Maybe(string)        `json:"encoding,omitempty"`,
	mime:           string               `json:"mime"`,
	size:           i64                  `json:"size"`,
	offset:         i64                  `json:"offset"`,
	bytes_returned: i64                  `json:"bytes_returned"`,
	eof:            bool                 `json:"eof"`,
	modified_at:    string               `json:"modified_at"`,
	truncated:      bool                 `json:"truncated"`,
	error:          Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Create_File_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	path:        string               `json:"path"`,
	created:     bool                 `json:"created"`,
	within_root: bool                 `json:"within_root"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Write_Result_Wire :: struct {
	type:          string               `json:"type"`,
	command_id:    string               `json:"command_id"`,
	ok:            bool                 `json:"ok"`,
	path:          string               `json:"path"`,
	bytes_written: int                  `json:"bytes_written"`,
	modified_at:   string               `json:"modified_at"`,
	within_root:   bool                 `json:"within_root"`,
	error:         Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Batch_Write_Result_Wire :: struct {
	type:       string                 `json:"type"`,
	command_id: string                 `json:"command_id"`,
	ok:         bool                   `json:"ok"`,
	saved:      []Bridge_Fs_Saved_Item `json:"saved"`,
	errors:     []Bridge_Fs_Error_Item `json:"errors"`,
	error:      Bridge_Fs_Error_Wire   `json:"error"`,
}

Bridge_Fs_Move_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	from:        string               `json:"from"`,
	to:          string               `json:"to"`,
	within_root: bool                 `json:"within_root"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Delete_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	path:        string               `json:"path"`,
	deleted:     bool                 `json:"deleted"`,
	within_root: bool                 `json:"within_root"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Stat_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	path:        string               `json:"path"`,
	exists:      bool                 `json:"exists"`,
	is_dir:      bool                 `json:"is_dir"`,
	has_git:     bool                 `json:"has_git"`,
	within_root: bool                 `json:"within_root"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Mkdir_Result_Wire :: struct {
	type:        string               `json:"type"`,
	command_id:  string               `json:"command_id"`,
	ok:          bool                 `json:"ok"`,
	path:        string               `json:"path"`,
	created:     bool                 `json:"created"`,
	within_root: bool                 `json:"within_root"`,
	error:       Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Find_Files_Result_Wire :: struct {
	type:       string               `json:"type"`,
	command_id: string               `json:"command_id"`,
	ok:         bool                 `json:"ok"`,
	root:       string               `json:"root"`,
	truncated:  bool                 `json:"truncated"`,
	files:      []string             `json:"files"`,
	error:      Bridge_Fs_Error_Wire `json:"error"`,
}

Bridge_Fs_Grep_Result_Wire :: struct {
	type:       string                 `json:"type"`,
	command_id: string                 `json:"command_id"`,
	ok:         bool                   `json:"ok"`,
	root:       string                 `json:"root"`,
	truncated:  bool                   `json:"truncated"`,
	matches:    []Bridge_Fs_Grep_Match `json:"matches"`,
	error:      Bridge_Fs_Error_Wire   `json:"error"`,
}

BRIDGE_FS_MAX_ENTRIES :: 2000
BRIDGE_FS_DEFAULT_LIMIT :: 200
BRIDGE_FS_MAX_VIEW_BYTES :: 1_000_000 // 1 MB read-file total-size view cap
// Default per-request byte window for paginated text reads. Capped at 8000 as a
// hotfix for the openssl-s_client TLS transport: the bridge streams a hub-runtime
// result larger than 6000B as multiple ~8KB WS "chunk" frames, and `openssl
// s_client` (used for the wss:// hub link) reads its stdin in 16384-byte chunks and
// SHUTS DOWN the TLS connection on any burst that needs a second read — so a result
// whose frames total >16KB (an ~16000B page → 3+ chunk frames) tears down the link
// and 409-times-out. An 8000B page fits in ≤2 chunk frames (~11.6KB on the wire, one
// s_client read), so it always survives. Proper fix is a binary-safe TLS transport
// (socat / in-process libssl); until then keep this ≤~11000. Smaller pages also give
// snappier first-paint + smoother scroll-to-load. The UI pages by requesting
// offset += bytes_returned until eof.
BRIDGE_FS_READ_PAGE_BYTES :: 8_000
// Per-request fs-read page when the bridge->hub TLS transport is socat
// (HAM_TLS_BACKEND=socat, the default). socat pumps full-duplex and does not tear
// the TLS link down on multi-read bursts, so the ~16 KB s_client ceiling above is
// gone. 131072 (128 KiB) is well over that ceiling (proving the fix), a power of
// two that bounds per-page memory, and still leaves BRIDGE_FS_MAX_VIEW_BYTES (1 MB)
// spanning ~8 pages so pagination is still exercised. Under the s_client fallback
// bridge_fs_init clamps the effective page back down to BRIDGE_FS_READ_PAGE_BYTES.
BRIDGE_FS_READ_PAGE_BYTES_SOCAT :: 131_072

// bridge_tls_backend_is_socat reports whether the bridge->hub TLS transport uses
// socat (the default) rather than the legacy `openssl s_client` fallback. Mirrors
// the HAM_TLS_BACKEND toggle read by the two argv builders (src/lib/ws/ws.odin and
// src/lib/http_client/http_client.odin): only the exact value "s_client" selects
// the legacy path; anything else (unset/empty/"socat"/unknown) means socat. SHARED
// CONTRACT — keep this rule identical to those builders.
bridge_tls_backend_is_socat :: proc() -> bool {
	backend := strings.to_lower(strings.trim_space(os.get_env("HAM_TLS_BACKEND", context.temp_allocator)))
	return backend != "s_client"
}

// --- helpers -------------------------------------------------------------

// bridge_fs_format_mtime converts a File_Info modification time to RFC3339 UTC,
// reusing the scheduler's civil-date formatter (same package).
bridge_fs_format_mtime :: proc(t: time.Time) -> string {
	ms := time.to_unix_nanoseconds(t) / 1_000_000
	return action_scheduler_format_rfc3339_utc(ms)
}

// bridge_fs_entry_less orders entries dirs-first, then name ascending. Stable
// ordering is required so cursor offsets stay meaningful across pages.
bridge_fs_entry_less :: proc(a, b: Bridge_Fs_Entry) -> bool {
	if a.is_dir != b.is_dir do return a.is_dir // dirs before files
	return strings.compare(a.name, b.name) < 0
}

// bridge_fs_decode_cursor decodes an opaque base64 offset. Empty cursor => 0.
// A malformed cursor is treated as offset 0 (fail-open to the first page).
bridge_fs_decode_cursor :: proc(cursor: string) -> int {
	if cursor == "" do return 0
	decoded, err := base64.decode(cursor, allocator = context.temp_allocator)
	if err != nil do return 0
	s := strings.trim_space(string(decoded))
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' do return 0
		n = n * 10 + int(ch - '0')
	}
	return n
}

// bridge_fs_encode_cursor encodes an integer offset as an opaque base64 token.
bridge_fs_encode_cursor :: proc(offset: int) -> string {
	s := fmt.tprintf("%d", offset)
	return base64.encode(transmute([]byte)s)
}

// bridge_fs_mime_for_ext maps a lowercase file extension to (mime, encoding).
// encoding is "utf8" for text/code, "base64" for supported images, "" (with
// mime "application/octet-stream") for unknown/binary types.
bridge_fs_mime_for_ext :: proc(name: string) -> (mime: string, encoding: string) {
	lower := strings.to_lower(name, context.temp_allocator)
	dot := strings.last_index_byte(lower, '.')
	ext := ""
	if dot >= 0 do ext = lower[dot + 1:]
	switch ext {
	// images -> base64
	case "png":  return "image/png", "base64"
	case "jpg", "jpeg": return "image/jpeg", "base64"
	case "gif":  return "image/gif", "base64"
	case "webp": return "image/webp", "base64"
	case "svg":  return "image/svg+xml", "base64"
	// text/code -> utf8
	case "md", "markdown": return "text/markdown", "utf8"
	case "txt", "text", "log": return "text/plain", "utf8"
	case "json": return "application/json", "utf8"
	case "js", "mjs", "cjs": return "text/javascript", "utf8"
	case "ts", "tsx": return "text/typescript", "utf8"
	case "jsx": return "text/jsx", "utf8"
	case "html", "htm": return "text/html", "utf8"
	case "css": return "text/css", "utf8"
	case "odin": return "text/x-odin", "utf8"
	case "go": return "text/x-go", "utf8"
	case "py": return "text/x-python", "utf8"
	case "rs": return "text/x-rust", "utf8"
	case "c", "h": return "text/x-c", "utf8"
	case "cpp", "cc", "cxx", "hpp", "hxx": return "text/x-c++", "utf8"
	case "cs": return "text/x-csharp", "utf8"
	case "java": return "text/x-java", "utf8"
	case "kt", "kts": return "text/x-kotlin", "utf8"
	case "swift": return "text/x-swift", "utf8"
	case "rb": return "text/x-ruby", "utf8"
	case "php": return "text/x-php", "utf8"
	case "lua": return "text/x-lua", "utf8"
	case "r": return "text/x-r", "utf8"
	case "zig": return "text/x-zig", "utf8"
	case "nix": return "text/x-nix", "utf8"
	case "sh", "bash", "zsh", "fish": return "text/x-shellscript", "utf8"
	case "toml": return "text/x-toml", "utf8"
	case "yaml", "yml": return "text/x-yaml", "utf8"
	case "xml": return "text/xml", "utf8"
	case "csv": return "text/csv", "utf8"
	case "sql": return "text/x-sql", "utf8"
	case "graphql", "gql": return "text/x-graphql", "utf8"
	case "proto": return "text/x-proto", "utf8"
	case "diff", "patch": return "text/x-diff", "utf8"
	case "vue": return "text/x-vue", "utf8"
	case "svelte": return "text/x-svelte", "utf8"
	case "scss": return "text/x-scss", "utf8"
	case "sass": return "text/x-sass", "utf8"
	case "less": return "text/x-less", "utf8"
	case "jsonc": return "application/json", "utf8"
	case "ini", "conf", "cfg": return "text/plain", "utf8"
	case "env": return "text/plain", "utf8"
	case "gitignore", "dockerignore": return "text/plain", "utf8"
	case:
		return "application/octet-stream", ""
	}
}

// --- containment ---------------------------------------------------------

// bridge_fs_resolve_within canonicalizes `requested` (which may not exist yet) and
// checks that it is the root or a descendant of it. Returns the canonical absolute
// path and whether it is contained. Handles ~-expansion, relative paths (against
// root), `..`, and symlink escapes (by resolving the deepest existing ancestor).
bridge_fs_resolve_within :: proc(requested: string, sandbox_root: string = "") -> (canonical: string, within: bool) {
	// sandbox_root lets project-scoped commands re-sandbox to a project root that is
	// itself contained within the global bridge_fs_root; "" falls back to the global root.
	root := sandbox_root if sandbox_root != "" else bridge_fs_root
	if root == "" do return "", false
	req := strings.trim_space(requested)
	// Empty request means "the root itself".
	if req == "" || req == "~" do return strings.clone(root), true
	expanded := bridge_expand_home(req)
	// Relative paths resolve against the root, not the process cwd.
	if !filepath.is_abs(expanded) {
		joined, jerr := filepath.join([]string{root, expanded}, context.allocator)
		if jerr != nil do return "", false
		expanded = joined
	}
	// Resolve the deepest EXISTING ancestor to a real path (defeats symlink escape),
	// then re-append the non-existent tail (needed for mkdir of a new dir).
	real_prefix, tail := bridge_fs_realpath_existing_prefix(expanded)
	if real_prefix == "" do return "", false
	full := real_prefix
	if tail != "" {
		joined, jerr := filepath.join([]string{real_prefix, tail}, context.allocator)
		if jerr != nil do return "", false
		full = joined
	}
	cleaned, cerr := filepath.clean(full, context.allocator)
	if cerr != nil do return "", false
	if !bridge_fs_is_within_root(cleaned, root) do return "", false
	return cleaned, true
}

// bridge_fs_realpath_existing_prefix walks up `path` until it finds an existing
// ancestor, resolves that ancestor to its real (symlink-free) absolute form, and
// returns (real_ancestor, remaining_tail) where tail is the not-yet-existing
// suffix (may be "").
bridge_fs_realpath_existing_prefix :: proc(path: string) -> (real_prefix: string, tail: string) {
	cleaned, cerr := filepath.clean(path, context.allocator)
	if cerr != nil do return "", ""
	cursor := cleaned
	suffix_parts := make([dynamic]string)
	defer delete(suffix_parts)
	for {
		if os.exists(cursor) {
			resolved, rerr := os.get_absolute_path(cursor, context.allocator)
			if rerr != nil do return "", ""
			// Reassemble the suffix in forward order.
			tail_parts := make([dynamic]string)
			defer delete(tail_parts)
			for i := len(suffix_parts) - 1; i >= 0; i -= 1 do append(&tail_parts, suffix_parts[i])
			joined_tail := strings.join(tail_parts[:], "/", context.allocator)
			return resolved, joined_tail
		}
		dir := filepath.dir(cursor)
		base := filepath.base(cursor)
		if dir == cursor || base == "" || base == "." || base == "/" {
			// Reached the top without finding an existing ancestor.
			return "", ""
		}
		append(&suffix_parts, base)
		cursor = dir
	}
}

// bridge_fs_canonicalize_existing resolves symlinks on the existing prefix of
// `path` and re-appends any not-yet-existing tail, yielding a canonical absolute
// path suitable for containment comparisons. This matters on hosts where a root
// traverses a symlink (e.g. macOS /tmp -> /private/tmp): a raw, unresolved root
// would never prefix-match a symlink-resolved request. Falls back to
// os.get_absolute_path (absolute, not symlink-resolved) when nothing on the path
// exists yet, and finally to a clone of the input if even that fails. Always
// returns a freshly allocated string.
bridge_fs_canonicalize_existing :: proc(path: string) -> string {
	real_prefix, tail := bridge_fs_realpath_existing_prefix(path)
	if real_prefix != "" {
		if tail != "" {
			if joined, jerr := filepath.join([]string{real_prefix, tail}, context.allocator); jerr == nil do return joined
		}
		return real_prefix
	}
	if resolved, err := os.get_absolute_path(path, context.allocator); err == nil do return resolved
	return strings.clone(path)
}

bridge_fs_is_within_root :: proc(abs_path: string, sandbox_root: string = "") -> bool {
	root := sandbox_root if sandbox_root != "" else bridge_fs_root
	if root == "" do return false
	if abs_path == root do return true
	// Must be a strict descendant: root + "/" prefix.
	prefix := strings.concatenate({root, "/"}, context.allocator)
	defer delete(prefix)
	return strings.has_prefix(abs_path, prefix)
}

// bridge_fs_resolve_command_root picks the sandbox root for a filesystem command.
// Normally it defers to bridge_fs_effective_root (which requires the override to be
// contained within the global bridge_fs_root). When `prevalidated` is true the
// caller has already resolved + contained the root itself (e.g. an instance run
// dir outside bridge_fs_root), so it is used verbatim — the per-request path is
// still re-sandboxed to it by bridge_fs_resolve_within at the call site.
bridge_fs_resolve_command_root :: proc(sandbox_root: string, prevalidated: bool) -> (root: string, ok: bool) {
	if prevalidated {
		root = strings.trim_space(sandbox_root)
		return root, root != ""
	}
	return bridge_fs_effective_root(sandbox_root)
}

// bridge_fs_run_dir_root resolves an agent instance's run directory to a canonical
// sandbox root and validates it is contained within the bridge's instances base
// (<local_endpoint_run_dir>/instances). The run dir lives OUTSIDE the global
// bridge_fs_root, so it is validated against the instances base instead. This is
// defense-in-depth: bridge_runtime_default_run_dir already sanitizes the id via
// bridge_runtime_safe_part, so a malformed id cannot escape the base.
bridge_fs_run_dir_root :: proc(instance_id: string) -> (root: string, ok: bool) {
	id := strings.trim_space(instance_id)
	if id == "" do return "", false
	// run_dir + base are temporaries used only for the containment check below; the
	// returned `canonical` is separately allocated, so free these to avoid a per-
	// request leak.
	run_dir := bridge_runtime_default_run_dir(id)
	defer delete(run_dir, context.allocator)
	base_root := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base_root == "" do base_root = bridge_scratch_local_default(context.temp_allocator)
	base_raw := strings.concatenate({base_root, "/instances"}, context.allocator)
	defer delete(base_raw, context.allocator)
	// Canonicalize the instances base (symlink-resolve its existing prefix) BEFORE
	// the containment check. bridge_fs_resolve_within symlink-resolves the requested
	// run_dir, so on hosts where the base traverses a symlink (e.g. macOS
	// /tmp -> /private/tmp) a raw base would never prefix-match and every run-dir op
	// would fail with path_outside_root. Mirrors bridge_fs_init's global-root resolve.
	base := bridge_fs_canonicalize_existing(base_raw)
	defer delete(base, context.allocator)
	canonical, within := bridge_fs_resolve_within(run_dir, base)
	if !within do return "", false
	return canonical, true
}

// bridge_fs_effective_root resolves an optional project-root override to a canonical
// absolute path. It accepts any valid existing directory on the host (e.g. task chain
// directories or external project roots), or falls back to global bridge_fs_root if empty.
// Subpath containment within the returned root is enforced by bridge_fs_resolve_within.
bridge_fs_effective_root :: proc(root_override: string) -> (root: string, ok: bool) {
	trimmed := strings.trim_space(root_override)
	if trimmed == "" do return bridge_fs_root, bridge_fs_root != ""

	// If within global bridge_fs_root, accept
	canonical, within := bridge_fs_resolve_within(trimmed)
	if within do return canonical, true

	// Allow any existing directory on the host as a valid task chain / project root
	can := bridge_fs_canonicalize_existing(trimmed)
	if os.exists(can) && os.is_dir(can) {
		return can, true
	}
	delete(can)

	return "", false
}

// --- operations ----------------------------------------------------------

// bridge_fs_list_dir lists a single directory with server-side hidden filtering,
// dirs-first/name-asc sorting, and opaque cursor pagination. `limit` <= 0 uses the
// default; it is clamped to BRIDGE_FS_MAX_ENTRIES. `cursor` is an opaque base64
// offset into the sorted list.
//
// `root_prevalidated` lets a caller pass a sandbox_root that the caller has ALREADY
// resolved + contained (e.g. an agent instance run dir that lives OUTSIDE the
// global bridge_fs_root); the requested path is still re-sandboxed to it below.
bridge_fs_list_dir :: proc(requested: string, include_hidden: bool = true, cursor: string = "", limit: int = BRIDGE_FS_DEFAULT_LIMIT, sandbox_root: string = "", root_prevalidated := false, deadline_ns: i64 = 0) -> Bridge_Fs_List_Result {
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_List_Result{ok = false, root = sandbox_root, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}
	root, root_ok := bridge_fs_resolve_command_root(sandbox_root, root_prevalidated)
	if !root_ok {
		return Bridge_Fs_List_Result{ok = false, root = bridge_fs_root, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_List_Result{ok = false, root = root, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "path_not_found", message = "Path does not exist"}
	}
	if !os.is_dir(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "path_not_directory", message = "Path is not a directory"}
	}
	infos, rerr := os.read_directory_by_path(canonical, -1, context.allocator)
	if rerr != nil {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "read_failed", message = "Could not read directory"}
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}
	// Build the full filtered set first so sort + cursor operate on a stable order.
	all := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for info in infos {
		if bridge_command_deadline_expired(deadline_ns) {
			for entry in all do delete(entry.name)
			delete(all)
			return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
		}
		name := info.name
		if name == "" || name == "." || name == ".." do continue
		hidden := len(name) > 0 && name[0] == '.'
		if !include_hidden && hidden do continue
		is_dir := info.type == .Directory
		has_git := false
		if is_dir {
			git_dir := strings.concatenate({info.fullpath, "/.git"}, context.allocator)
			has_git = os.exists(git_dir)
			delete(git_dir)
		}
		size := i64(0)
		if !is_dir do size = info.size
		append(&all, Bridge_Fs_Entry{
			name        = strings.clone(name),
			is_dir      = is_dir,
			hidden      = hidden,
			has_git     = has_git,
			size        = size,
			modified_at = bridge_fs_format_mtime(info.modification_time),
		})
	}
	// Sort: dirs-first, then name asc (stable for cursor paging).
	slice.sort_by(all[:], bridge_fs_entry_less)
	total := len(all)
	// Clamp the page size.
	page_limit := limit
	if page_limit <= 0 do page_limit = BRIDGE_FS_DEFAULT_LIMIT
	if page_limit > BRIDGE_FS_MAX_ENTRIES do page_limit = BRIDGE_FS_MAX_ENTRIES
	// Decode + clamp the cursor offset.
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	page := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for i in start..<end do append(&page, all[i])
	for i in 0..<start do delete(all[i].name)
	for i in end..<total do delete(all[i].name)
	delete(all)
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	parent := ""
	if canonical != root {
		p := filepath.dir(canonical)
		if bridge_fs_is_within_root(p, root) do parent = p
	}
	return Bridge_Fs_List_Result{
		ok = true, path = canonical, root = root, parent = parent,
		entries = page[:], next_cursor = next_cursor, has_more = has_more,
		truncated = false,
	}
}

// bridge_fs_read_file returns a bounded, type-gated view of a regular file. Text
// is returned as utf8; supported images as base64; oversized files as viewable
// false + file_too_large; unknown/binary as viewable false + unsupported_type.
//
// Byte-range pagination (utf8 text only): `offset`/`limit` request a chunk so a
// large file can be streamed page-by-page over the size-limited WS relay instead
// of one huge frame that times out. limit <= 0 uses BRIDGE_FS_READ_PAGE_BYTES.
// The returned chunk is trimmed back to a UTF-8 char boundary; bytes_returned is
// the actual file bytes covered (caller's next offset = offset + bytes_returned)
// and eof marks the final chunk. base64/images ignore offset/limit (returned
// whole, still under the 1MB cap). The whole file (up to the cap) is still capped
// by BRIDGE_FS_MAX_VIEW_BYTES on total size.
// bridge_fs_vault_snapshot is the single status+keyring read each fs command takes
// (finding L2).
bridge_fs_vault_snapshot :: proc() -> (Vault_Status, vault.Vault_Keyring) {
	when ODIN_TEST {
		if bridge_fs_test_vault_hook != nil do return bridge_fs_test_vault_hook()
	}
	return bridge_vault_status_and_key()
}

// Test builds only (consulted under `when ODIN_TEST` above; always nil otherwise):
// per test thread (Odin runs each test on its own thread), the vault state the fs
// commands of THAT test see, injected explicitly instead of read from the process
// environment or the keystore.
@(thread_local)
bridge_fs_test_vault_hook: proc() -> (Vault_Status, vault.Vault_Keyring)

bridge_fs_read_file :: proc(requested: string, sandbox_root: string = "", offset: i64 = 0, limit: i64 = 0, root_prevalidated := false) -> Bridge_Fs_Read_File_Result {
	root, root_ok := bridge_fs_resolve_command_root(sandbox_root, root_prevalidated)
	if !root_ok {
		return Bridge_Fs_Read_File_Result{ok = false, path = requested, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Read_File_Result{ok = false, path = requested, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	// One snapshot of status AND keyring (finding L2): a lock between a status check
	// and a later key read must not let the content leave in plaintext.
	vault_status, vault_kr := bridge_fs_vault_snapshot()
	defer vault.keyring_wipe(&vault_kr)
	if vault_status != .Unlocked {
		delete(canonical)
		return Bridge_Fs_Read_File_Result{
			ok = false,
			path = requested,
			error_code = "vault_locked",
			message = "Bridge vault is locked. Unseal required to read files.",
		}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "path_not_found", message = "Path does not exist"}
	}
	info, ierr := os.stat(canonical, context.allocator)
	if ierr != nil {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "read_failed", message = "Could not stat file"}
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "not_a_file", message = "Path is not a regular file"}
	}
	mime, encoding := bridge_fs_mime_for_ext(info.name)
	modified_at := bridge_fs_format_mtime(info.modification_time)
	// Unknown/binary types: gate before reading any bytes.
	if encoding == "" {
		return Bridge_Fs_Read_File_Result{ok = true, path = canonical, viewable = false, mime = mime, size = info.size, modified_at = modified_at, error_code = "unsupported_type", message = "File type is not viewable"}
	}
	// Total-size cap: metadata still populated, but no content read.
	if info.size > BRIDGE_FS_MAX_VIEW_BYTES {
		return Bridge_Fs_Read_File_Result{ok = true, path = canonical, viewable = false, mime = mime, size = info.size, modified_at = modified_at, error_code = "file_too_large", message = "File exceeds the maximum viewable size"}
	}
	data, derr := os.read_entire_file_from_path(canonical, context.allocator)
	if derr != nil {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, mime = mime, size = info.size, modified_at = modified_at, error_code = "read_failed", message = "Could not read file"}
	}
	defer delete(data, context.allocator)

	result: Bridge_Fs_Read_File_Result
	// base64/images: return whole (already bounded by the size cap); no paging.
	if encoding == "base64" {
		content := base64.encode(data)
		result = Bridge_Fs_Read_File_Result{
			ok = true, path = canonical, viewable = true, content = content,
			encoding = encoding, mime = mime, size = info.size, modified_at = modified_at,
			offset = 0, bytes_returned = info.size, eof = true,
		}
	} else {
		// utf8 text: return the [offset, offset+page) byte window, trimmed to a valid
		// UTF-8 boundary so a multi-byte rune isn't split across chunks.
		total := i64(len(data))
		start := offset
		if start < 0 do start = 0
		if start > total do start = total
		page := limit
		if page <= 0 do page = bridge_fs_read_page_bytes
		end := start + page
		if end > total do end = total
		// Trim `end` back off the middle of a multi-byte UTF-8 sequence (a continuation
		// byte has the top bits 10xxxxxx). Never trim below `start`.
		for end > start && end < total && (data[end] & 0xC0) == 0x80 {
			end -= 1
		}
		chunk := string(data[start:end])
		result = Bridge_Fs_Read_File_Result{
			ok = true, path = canonical, viewable = true, content = strings.clone(chunk),
			encoding = encoding, mime = mime, size = info.size, modified_at = modified_at,
			offset = start, bytes_returned = end - start, eof = end >= total,
		}
	}

	encrypted, enc_ok := bridge_encrypt_vault_text(result.content, &vault_kr)
	delete(result.content)
	if !enc_ok {
		// Fail closed: the content never leaves in plaintext.
		result.content = ""
		result.ok = false
		result.viewable = false
		result.error_code = "encryption_failed"
		result.message = "Could not encrypt file content"
		return result
	}
	result.content = encrypted

	return result
}

// bridge_fs_create_file creates an empty regular file. The parent directory must
// already exist within the sandbox root. Existing path => path_exists.
bridge_fs_create_file :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Create_File_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Create_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Create_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if canonical == root {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists", message = "Path already exists"}
	}
	if os.exists(canonical) {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists", message = "Path already exists"}
	}
	parent := filepath.dir(canonical)
	if !os.exists(parent) || !os.is_dir(parent) {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_not_found", message = "Parent directory does not exist"}
	}
	if err := os.write_entire_file_from_string(canonical, ""); err != nil {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "write_failed", message = "Could not create file"}
	}
	return Bridge_Fs_Create_File_Result{ok = true, path = canonical, created = true, within_root = true}
}

// bridge_fs_write_file writes `content` (sealed for this bridge and `requested`,
// see below) to `requested` atomically.
// The parent directory must exist within the sandbox root.
// Target cannot be a directory. Outside root => path_outside_root.
bridge_fs_write_file :: proc(requested: string, content: string, sandbox_root: string = "") -> Bridge_Fs_Write_File_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Write_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Write_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if canonical == root {
		return Bridge_Fs_Write_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_is_directory", message = "Target path is the root directory"}
	}
	if os.exists(canonical) && os.is_dir(canonical) {
		return Bridge_Fs_Write_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_is_directory", message = "Target path is a directory"}
	}
	parent := filepath.dir(canonical)
	if !os.exists(parent) || !os.is_dir(parent) {
		return Bridge_Fs_Write_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_not_found", message = "Parent directory does not exist"}
	}

	vault_status, vault_kr := bridge_fs_vault_snapshot()
	defer vault.keyring_wipe(&vault_kr)
	if vault_status != .Unlocked {
		return Bridge_Fs_Write_File_Result{
			ok = false,
			path = requested,
			within_root = true,
			error_code = "vault_locked",
			message = "Bridge vault is locked. Unseal required to write files.",
		}
	}

	// File content always arrives sealed for THIS bridge and THIS target path
	// (heimdall-fs-write-v2 AAD, finding N4) under the current epoch; plaintext, a
	// content envelope, or a token for another path or bridge is refused.
	decrypted, dec_ok := vault.fs_write_open(content, &vault_kr, bridge_config.daemon_id, requested, vault_kr.current_epoch, context.allocator)
	if !dec_ok {
		return Bridge_Fs_Write_File_Result{
			ok = false,
			path = requested,
			within_root = true,
			error_code = "invalid_vault_key",
			message = "File content must be vault-encrypted for this bridge and path",
		}
	}
	defer {
		crypto.zero_explicit(raw_data(decrypted), len(decrypted))
		delete(decrypted)
	}
	payload_to_write := string(decrypted)

	temp_name := fmt.tprintf(".tmp_write_%d_%s", time.to_unix_nanoseconds(time.now()), filepath.base(canonical))
	temp_path, jerr := filepath.join([]string{parent, temp_name}, context.allocator)
	if jerr != nil {
		temp_path = strings.concatenate({parent, "/", temp_name}, context.allocator)
	}
	defer delete(temp_path, context.allocator)

	written_cleanly := false
	if err := os.write_entire_file_from_string(temp_path, payload_to_write); err == nil {
		temp_c := strings.clone_to_cstring(temp_path, context.temp_allocator)
		canon_c := strings.clone_to_cstring(canonical, context.temp_allocator)
		if libc.rename(temp_c, canon_c) == 0 {
			written_cleanly = true
		} else {
			_ = os.remove(temp_path)
		}
	}

	if !written_cleanly {
		if err := os.write_entire_file_from_string(canonical, payload_to_write); err != nil {
			return Bridge_Fs_Write_File_Result{ok = false, path = canonical, within_root = true, error_code = "write_failed", message = "Could not write file"}
		}
	}

	modified_at := ""
	if info, ierr := os.stat(canonical, context.allocator); ierr == nil {
		modified_at = bridge_fs_format_mtime(info.modification_time)
		os.file_info_delete(info, context.allocator)
	} else {
		modified_at = action_scheduler_format_rfc3339_utc(time.to_unix_nanoseconds(time.now()) / 1_000_000)
	}

	return Bridge_Fs_Write_File_Result{
		ok = true,
		path = canonical,
		bytes_written = len(payload_to_write),
		modified_at = modified_at,
		within_root = true,
	}
}

// bridge_fs_batch_write writes multiple files atomically within the sandbox root.
// Returns saved list for succeeded files and errors list for failed files.
bridge_fs_batch_write :: proc(files: [dynamic]Bridge_Fs_Write_Item, sandbox_root: string = "") -> Bridge_Fs_Batch_Write_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Batch_Write_Result{
			ok = false,
			saved = make([]Bridge_Fs_Saved_Item, 0),
			errors = make([]Bridge_Fs_Error_Item, 0),
			error_code = "path_outside_root",
			message = "Project root is outside the allowed root",
		}
	}

	saved_dyn := make([dynamic]Bridge_Fs_Saved_Item, context.allocator)
	errors_dyn := make([dynamic]Bridge_Fs_Error_Item, context.allocator)

	for item in files {
		res := bridge_fs_write_file(item.path, item.content, root)
		if res.ok {
			append(&saved_dyn, Bridge_Fs_Saved_Item{
				path = res.path,
				bytes_written = res.bytes_written,
				modified_at = res.modified_at,
			})
		} else {
			append(&errors_dyn, Bridge_Fs_Error_Item{
				path = strings.clone(item.path),
				error_code = strings.clone(res.error_code),
				message = strings.clone(res.message),
			})
		}
	}

	ok := len(errors_dyn) == 0
	err_code := ""
	err_msg := ""
	if !ok {
		err_code = "batch_write_partial"
		err_msg = fmt.tprintf("%d of %d file(s) failed to save", len(errors_dyn), len(files))
	}

	return Bridge_Fs_Batch_Write_Result{
		ok = ok,
		saved = saved_dyn[:],
		errors = errors_dyn[:],
		error_code = err_code,
		message = err_msg,
	}
}

// bridge_fs_move renames/moves a path. Both endpoints are sandboxed; the source
// must exist and the destination must not (dest_exists). Works for files + dirs.
bridge_fs_move :: proc(from_req, to_req: string, sandbox_root: string = "") -> Bridge_Fs_Move_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Move_Result{ok = false, from = from_req, to = to_req, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	from_canonical, from_within := bridge_fs_resolve_within(from_req, root)
	if !from_within {
		return Bridge_Fs_Move_Result{ok = false, from = from_req, to = to_req, within_root = false, error_code = "path_outside_root", message = "Source path is outside the allowed root"}
	}
	to_canonical, to_within := bridge_fs_resolve_within(to_req, root)
	if !to_within {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_req, within_root = false, error_code = "path_outside_root", message = "Destination path is outside the allowed root"}
	}
	if from_canonical == root {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "cannot_delete_root", message = "Cannot move the root itself"}
	}
	if !os.exists(from_canonical) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "path_not_found", message = "Source path does not exist"}
	}
	if os.exists(to_canonical) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "dest_exists", message = "Destination already exists"}
	}
	to_parent := filepath.dir(to_canonical)
	if !os.exists(to_parent) || !os.is_dir(to_parent) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "path_not_found", message = "Destination parent directory does not exist"}
	}
	from_c := strings.clone_to_cstring(from_canonical, context.temp_allocator)
	to_c := strings.clone_to_cstring(to_canonical, context.temp_allocator)
	if libc.rename(from_c, to_c) != 0 {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "move_failed", message = "Could not move path"}
	}
	return Bridge_Fs_Move_Result{ok = true, from = from_canonical, to = to_canonical, within_root = true}
}

// bridge_fs_delete removes a file or directory. Non-empty directories require
// recursive=true (else dir_not_empty). The sandbox root itself is never deletable.
bridge_fs_remove_all_with_deadline :: proc(path: string, deadline_ns: i64) -> (ok, timed_out: bool) {
	if bridge_command_deadline_expired(deadline_ns) do return false, true
	if !os.is_dir(path) {
		return os.remove(path) == nil, false
	}
	infos, rerr := os.read_directory_by_path(path, -1, context.allocator)
	if rerr != nil do return false, false
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos {
		if info.name == "" || info.name == "." || info.name == ".." do continue
		if bridge_command_deadline_expired(deadline_ns) do return false, true
		if info.type == .Directory {
			child_ok, child_timeout := bridge_fs_remove_all_with_deadline(info.fullpath, deadline_ns)
			if !child_ok do return false, child_timeout
		} else if os.remove(info.fullpath) != nil {
			return false, false
		}
	}
	if bridge_command_deadline_expired(deadline_ns) do return false, true
	return os.remove(path) == nil, false
}

bridge_fs_delete :: proc(requested: string, recursive: bool, sandbox_root: string = "", deadline_ns: i64 = 0) -> Bridge_Fs_Delete_Result {
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_Delete_Result{ok = false, path = requested, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Delete_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Delete_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if canonical == root {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "cannot_delete_root", message = "Cannot delete the root directory"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "path_not_found", message = "Path does not exist"}
	}
	if os.is_dir(canonical) {
		if !recursive {
			infos, rerr := os.read_directory_by_path(canonical, -1, context.allocator)
			if rerr != nil {
				return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not inspect directory"}
			}
			non_empty := false
			for info in infos {
				if info.name == "" || info.name == "." || info.name == ".." do continue
				non_empty = true
				break
			}
			os.file_info_slice_delete(infos, context.allocator)
			if non_empty {
				return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "dir_not_empty", message = "Directory is not empty"}
			}
		}
		removed, timed_out := bridge_fs_remove_all_with_deadline(canonical, deadline_ns)
		if timed_out {
			return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
		}
		if !removed {
			return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not delete directory"}
		}
		return Bridge_Fs_Delete_Result{ok = true, path = canonical, deleted = true, within_root = true}
	}
	if err := os.remove(canonical); err != nil {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not delete file"}
	}
	return Bridge_Fs_Delete_Result{ok = true, path = canonical, deleted = true, within_root = true}
}

bridge_fs_stat :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Stat_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Stat_Result{ok = true, path = requested, exists = false, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Stat_Result{ok = true, path = requested, exists = false, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	exists := os.exists(canonical)
	is_dir := exists && os.is_dir(canonical)
	has_git := is_dir && bridge_path_has_git_root(canonical)
	return Bridge_Fs_Stat_Result{ok = true, path = canonical, exists = exists, is_dir = is_dir, has_git = has_git, within_root = true}
}

bridge_fs_make_dir :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Mkdir_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Mkdir_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Mkdir_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if os.exists(canonical) {
		if os.is_dir(canonical) {
			return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = false, within_root = true}
		}
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists_not_dir", message = "A non-directory already exists at this path"}
	}
	if err := bridge_make_directory_all(canonical); err != nil {
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "mkdir_failed", message = "Could not create directory"}
	}
	return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = true, within_root = true}
}

bridge_fs_fuzzy_match :: proc(pattern, text: string) -> bool {
	if len(pattern) == 0 do return true
	if len(text) < len(pattern) do return false
	p_idx := 0
	for i in 0..<len(text) {
		t_char := text[i]
		if t_char >= 'A' && t_char <= 'Z' do t_char += 32
		p_char := pattern[p_idx]
		if p_char >= 'A' && p_char <= 'Z' do p_char += 32
		if t_char == p_char {
			p_idx += 1
			if p_idx == len(pattern) do return true
		}
	}
	return false
}

bridge_fs_contains_case_insensitive :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 do return true
	if len(haystack) < len(needle) do return false
	h_len := len(haystack)
	n_len := len(needle)
	first_lower := needle[0]
	if first_lower >= 'A' && first_lower <= 'Z' do first_lower += 32
	first_upper := first_lower
	if first_upper >= 'a' && first_upper <= 'z' do first_upper -= 32

	for i := 0; i <= h_len - n_len; i += 1 {
		b := haystack[i]
		if b == first_lower || b == first_upper {
			match := true
			for j := 1; j < n_len; j += 1 {
				hb := haystack[i + j]
				nb := needle[j]
				if hb >= 'A' && hb <= 'Z' do hb += 32
				if nb >= 'A' && nb <= 'Z' do nb += 32
				if hb != nb {
					match = false
					break
				}
			}
			if match do return true
		}
	}
	return false
}

bridge_fs_is_search_ignored_dir :: proc(name: string) -> bool {
	return name == ".git" || name == "node_modules" || name == "dist" || name == "build" || name == ".build"
}

bridge_fs_find_files :: proc(query: string, limit: int, sandbox_root: string = "", deadline_ns: i64 = 0) -> Bridge_Fs_Find_Files_Result {
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_Find_Files_Result{ok = false, root = sandbox_root, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Find_Files_Result{ok = false, root = sandbox_root, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within("", root)
	if !within {
		return Bridge_Fs_Find_Files_Result{ok = false, root = root, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if !os.exists(canonical) || !os.is_dir(canonical) {
		delete(canonical)
		return Bridge_Fs_Find_Files_Result{ok = false, root = root, error_code = "path_not_directory", message = "Path is not a directory"}
	}

	max_results := limit
	if max_results <= 0 do max_results = 100
	if max_results > 1000 do max_results = 1000

	query_trim := strings.trim_space(query)
	query_lower := strings.to_lower(query_trim, context.temp_allocator)

	results := make([dynamic]string, context.allocator)
	truncated := false

	dir_queue := make([dynamic]string, context.allocator)
	defer {
		for d in dir_queue do delete(d, context.allocator)
		delete(dir_queue)
	}
	append(&dir_queue, canonical)

	q_head := 0
	for q_head < len(dir_queue) {
		if bridge_command_deadline_expired(deadline_ns) {
			return Bridge_Fs_Find_Files_Result{ok = false, root = root, files = results[:], truncated = true, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
		}
		curr_dir := dir_queue[q_head]
		q_head += 1

		infos, rerr := os.read_directory_by_path(curr_dir, -1, context.allocator)
		if rerr != nil do continue

		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
			return strings.compare(a.name, b.name) < 0
		})

		for info in infos {
			if bridge_command_deadline_expired(deadline_ns) {
				truncated = true
				break
			}
			name := info.name
			if name == "" || name == "." || name == ".." do continue
			if info.type == .Directory {
				if bridge_fs_is_search_ignored_dir(name) do continue
				sub_canonical, sub_within := bridge_fs_resolve_within(info.fullpath, root)
				if sub_within && os.is_dir(sub_canonical) {
					append(&dir_queue, sub_canonical)
				} else {
					delete(sub_canonical)
				}
			} else {
				rel := info.fullpath
				if strings.has_prefix(rel, canonical) {
					rel = rel[len(canonical):]
					for len(rel) > 0 && rel[0] == '/' {
						rel = rel[1:]
					}
				}
				matches := false
				if query_trim == "" {
					matches = true
				} else {
					rel_lower := strings.to_lower(rel, context.temp_allocator)
					matches = strings.contains(rel_lower, query_lower) || bridge_fs_fuzzy_match(query_lower, rel_lower)
				}
				if matches {
					append(&results, strings.clone(rel, context.allocator))
					if len(results) >= max_results {
						truncated = true
						break
					}
				}
			}
		}
		os.file_info_slice_delete(infos, context.allocator)
		if truncated do break
	}
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_Find_Files_Result{ok = false, root = root, files = results[:], truncated = true, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}

	return Bridge_Fs_Find_Files_Result{
		ok = true,
		root = root,
		files = results[:],
		truncated = truncated,
	}
}

bridge_fs_grep :: proc(query: string, case_sensitive: bool, max_results: int, sandbox_root: string = "", deadline_ns: i64 = 0) -> Bridge_Fs_Grep_Result {
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_Grep_Result{ok = false, root = sandbox_root, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Grep_Result{ok = false, root = sandbox_root, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within("", root)
	if !within {
		return Bridge_Fs_Grep_Result{ok = false, root = root, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	vault_status, vault_kr := bridge_fs_vault_snapshot()
	defer vault.keyring_wipe(&vault_kr)
	if vault_status != .Unlocked {
		delete(canonical)
		return Bridge_Fs_Grep_Result{ok = false, root = root, error_code = "vault_locked", message = "Bridge vault is locked. Unseal required."}
	}

	if len(query) == 0 {
		delete(canonical)
		return Bridge_Fs_Grep_Result{
			ok = true,
			root = root,
			matches = make([]Bridge_Fs_Grep_Match, 0, context.allocator),
			truncated = false,
		}
	}

	limit := max_results
	if limit <= 0 do limit = 100
	if limit > 1000 do limit = 1000

	matches := make([dynamic]Bridge_Fs_Grep_Match, context.allocator)
	truncated := false

	dir_queue := make([dynamic]string, context.allocator)
	defer {
		for d in dir_queue do delete(d, context.allocator)
		delete(dir_queue)
	}
	append(&dir_queue, canonical)

	q_head := 0
	for q_head < len(dir_queue) {
		if bridge_command_deadline_expired(deadline_ns) {
			return Bridge_Fs_Grep_Result{ok = false, root = root, matches = matches[:], truncated = true, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
		}
		curr_dir := dir_queue[q_head]
		q_head += 1

		infos, rerr := os.read_directory_by_path(curr_dir, -1, context.allocator)
		if rerr != nil do continue

		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
			return strings.compare(a.name, b.name) < 0
		})

		for info in infos {
			if bridge_command_deadline_expired(deadline_ns) {
				truncated = true
				break
			}
			name := info.name
			if name == "" || name == "." || name == ".." do continue
			if info.type == .Directory {
				if bridge_fs_is_search_ignored_dir(name) do continue
				sub_canonical, sub_within := bridge_fs_resolve_within(info.fullpath, root)
				if sub_within && os.is_dir(sub_canonical) {
					append(&dir_queue, sub_canonical)
				} else {
					delete(sub_canonical)
				}
			} else {
				if info.size <= 0 || info.size > 2_000_000 do continue
				_, encoding := bridge_fs_mime_for_ext(name)
				if encoding == "base64" do continue

				data, derr := os.read_entire_file_from_path(info.fullpath, context.allocator)
				if derr != nil do continue

				if encoding != "utf8" {
					check_len := len(data) if len(data) < 512 else 512
					is_bin := false
					for b in data[:check_len] {
						if b == 0 {
							is_bin = true
							break
						}
					}
					if is_bin {
						delete(data, context.allocator)
						continue
					}
				}

				content := string(data)
				has_needle := false
				if case_sensitive {
					has_needle = strings.contains(content, query)
				} else {
					has_needle = bridge_fs_contains_case_insensitive(content, query)
				}
				if !has_needle {
					delete(data, context.allocator)
					continue
				}

				rel := info.fullpath
				if strings.has_prefix(rel, canonical) {
					rel = rel[len(canonical):]
					for len(rel) > 0 && rel[0] == '/' {
						rel = rel[1:]
					}
				}

				line_number := 1
				line_start := 0
				for idx := 0; idx < len(content); idx += 1 {
					if bridge_command_deadline_expired(deadline_ns) {
						truncated = true
						break
					}
					if content[idx] == '\n' || idx == len(content) - 1 {
						line_end := idx
						if content[idx] != '\n' {
							line_end = idx + 1
						}
						raw_line := content[line_start:line_end]
						if len(raw_line) > 0 && raw_line[len(raw_line) - 1] == '\r' {
							raw_line = raw_line[:len(raw_line) - 1]
						}

						matched := false
						if case_sensitive {
							matched = strings.contains(raw_line, query)
						} else {
							matched = bridge_fs_contains_case_insensitive(raw_line, query)
						}

						if matched {
							line_str := raw_line
							if len(line_str) > 500 {
								line_str = line_str[:500]
							}
							append(&matches, Bridge_Fs_Grep_Match{
								path = strings.clone(rel, context.allocator),
								line_number = line_number,
								line = strings.clone(line_str, context.allocator),
							})
							if len(matches) >= limit {
								truncated = true
								break
							}
						}

						line_number += 1
						line_start = idx + 1
					}
				}
				delete(data, context.allocator)
				if truncated do break
			}
		}
		os.file_info_slice_delete(infos, context.allocator)
		if truncated do break
	}
	if bridge_command_deadline_expired(deadline_ns) {
		return Bridge_Fs_Grep_Result{ok = false, root = root, matches = matches[:], truncated = true, error_code = "deadline_exceeded", message = "Filesystem command deadline exceeded"}
	}

	for &m in matches {
		encrypted, enc_ok := bridge_encrypt_vault_text(m.line, &vault_kr, context.allocator)
		delete(m.line)
		// Fail closed: never return a matched line in plaintext.
		m.line = encrypted if enc_ok else strings.clone(vault.FAILED_MARKER)
	}

	return Bridge_Fs_Grep_Result{
		ok = true,
		root = root,
		matches = matches[:],
		truncated = truncated,
	}
}

// --- WS command handling (Hub -> Bridge) ---------------------------------

// bridge_fs_handle_command dispatches the fs_* command types over the runtime WS.
// Returns true if `type` was an fs command (handled), false otherwise. Results are
// cached by command_id for idempotent replay, matching the other command handlers.
bridge_fs_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	deadline_ns := bridge_command_worker_deadline_ns(conn)
	switch type {
	case "fs_list_dir":
		cmd: Bridge_Fs_List_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		include_hidden := cmd.include_hidden.? or_else true
		limit := cmd.limit if cmd.limit > 0 else BRIDGE_FS_DEFAULT_LIMIT
		result := bridge_fs_list_dir(cmd.path, include_hidden, cmd.cursor, limit, cmd.root, deadline_ns = deadline_ns)
		defer bridge_fs_list_result_delete(&result)
		out := bridge_fs_list_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_stat":
		cmd: Bridge_Fs_Stat_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_stat(cmd.path, cmd.root)
		out := bridge_fs_stat_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_make_dir":
		cmd: Bridge_Fs_Mkdir_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_make_dir(cmd.path, cmd.root)
		out := bridge_fs_mkdir_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_read_file":
		cmd: Bridge_Fs_Read_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_read_file(cmd.path, cmd.root, cmd.offset, cmd.limit)
		defer delete(result.content)
		out := bridge_fs_read_file_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "agent_run_dir_list":
		// READ-ONLY listing of an agent instance's run dir (the context materialized
		// for the agent). include_hidden defaults true so dotfiles/.heimdall are shown.
		cmd: Bridge_Fs_List_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		include_hidden := cmd.include_hidden.? or_else true
		limit := cmd.limit if cmd.limit > 0 else BRIDGE_FS_DEFAULT_LIMIT
		root, root_ok := bridge_fs_run_dir_root(cmd.instance_id)
		result: Bridge_Fs_List_Result
		if !root_ok {
			result = Bridge_Fs_List_Result{ok = false, error_code = "path_outside_root", message = "Run directory is outside the allowed root"}
		} else {
			result = bridge_fs_list_dir(cmd.path, include_hidden, cmd.cursor, limit, root, true, deadline_ns)
		}
		defer bridge_fs_list_result_delete(&result)
		out := bridge_fs_list_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "agent_run_dir_read":
		// READ-ONLY bounded view of a single file inside an agent instance's run dir.
		cmd: Bridge_Fs_Read_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		root, root_ok := bridge_fs_run_dir_root(cmd.instance_id)
		result: Bridge_Fs_Read_File_Result
		if !root_ok {
			result = Bridge_Fs_Read_File_Result{ok = false, path = cmd.path, error_code = "path_outside_root", message = "Run directory is outside the allowed root"}
		} else {
			result = bridge_fs_read_file(cmd.path, root, cmd.offset, cmd.limit, true)
		}
		defer delete(result.content)
		out := bridge_fs_read_file_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_create_file":
		cmd: Bridge_Fs_Create_File_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_create_file(cmd.path, cmd.root)
		out := bridge_fs_create_file_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_write_file":
		cmd: Bridge_Fs_Write_File_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_write_file(cmd.path, cmd.content, cmd.root)
		out := bridge_fs_write_file_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_batch_write":
		cmd: Bridge_Fs_Batch_Write_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		files := make([dynamic]Bridge_Fs_Write_Item, len(cmd.files), context.temp_allocator)
		copy(files[:], cmd.files)
		result := bridge_fs_batch_write(files, cmd.root)
		defer bridge_fs_batch_write_result_delete(&result)
		out := bridge_fs_batch_write_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_move":
		cmd: Bridge_Fs_Move_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_move(cmd.from, cmd.to, cmd.root)
		out := bridge_fs_move_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_delete":
		cmd: Bridge_Fs_Delete_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		result := bridge_fs_delete(cmd.path, cmd.recursive, cmd.root, deadline_ns)
		out := bridge_fs_delete_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_find_files":
		cmd: Bridge_Fs_Find_Files_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		limit := cmd.limit if cmd.limit > 0 else 100
		result := bridge_fs_find_files(cmd.query, limit, cmd.root, deadline_ns)
		defer bridge_fs_find_files_result_delete(&result)
		out := bridge_fs_find_files_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	case "fs_grep":
		cmd: Bridge_Fs_Grep_Command
		if err := json.unmarshal_string(text, &cmd, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
			return false
		}
		if cached, ok := bridge_runtime_cached_command(cmd.command_id); ok { _ = bridge_hub_send(conn, cached); return true }
		limit := cmd.max_results if cmd.max_results > 0 else (cmd.limit if cmd.limit > 0 else 100)
		result := bridge_fs_grep(cmd.query, cmd.case_sensitive, limit, cmd.root, deadline_ns)
		defer bridge_fs_grep_result_delete(&result)
		out := bridge_fs_grep_result_json(cmd.command_id, result)
		defer delete(out)
		bridge_runtime_cache_command(cmd.command_id, out)
		_ = bridge_hub_send(conn, out)
		return true
	}
	return false
}

bridge_fs_list_result_json :: proc(command_id: string, r: Bridge_Fs_List_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_List_Result_Wire{
		type        = "fs_list_dir_result",
		command_id  = command_id,
		ok          = r.ok,
		path        = r.path,
		root        = r.root,
		parent      = r.parent,
		truncated   = r.truncated,
		has_more    = r.has_more,
		next_cursor = r.next_cursor if r.next_cursor != "" else nil,
		entries     = r.entries,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_read_file_result_json :: proc(command_id: string, r: Bridge_Fs_Read_File_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Read_Result_Wire{
		type           = "fs_read_file_result",
		command_id     = command_id,
		ok             = r.ok,
		path           = r.path,
		viewable       = r.viewable,
		mime           = r.mime,
		size           = r.size,
		offset         = r.offset,
		bytes_returned = r.bytes_returned,
		eof            = r.eof,
		modified_at    = r.modified_at,
		truncated      = r.truncated,
		error          = bridge_result_error(r.error_code, r.message),
	}
	if r.viewable {
		wire.content = r.content
		wire.encoding = r.encoding
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_create_file_result_json :: proc(command_id: string, r: Bridge_Fs_Create_File_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Create_File_Result_Wire{
		type        = "fs_create_file_result",
		command_id  = command_id,
		ok          = r.ok,
		path        = r.path,
		created     = r.created,
		within_root = r.within_root,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_move_result_json :: proc(command_id: string, r: Bridge_Fs_Move_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Move_Result_Wire{
		type        = "fs_move_result",
		command_id  = command_id,
		ok          = r.ok,
		from        = r.from,
		to          = r.to,
		within_root = r.within_root,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_delete_result_json :: proc(command_id: string, r: Bridge_Fs_Delete_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Delete_Result_Wire{
		type        = "fs_delete_result",
		command_id  = command_id,
		ok          = r.ok,
		path        = r.path,
		deleted     = r.deleted,
		within_root = r.within_root,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_stat_result_json :: proc(command_id: string, r: Bridge_Fs_Stat_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Stat_Result_Wire{
		type        = "fs_stat_result",
		command_id  = command_id,
		ok          = r.ok,
		path        = r.path,
		exists      = r.exists,
		is_dir      = r.is_dir,
		has_git     = r.has_git,
		within_root = r.within_root,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_mkdir_result_json :: proc(command_id: string, r: Bridge_Fs_Mkdir_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Mkdir_Result_Wire{
		type        = "fs_make_dir_result",
		command_id  = command_id,
		ok          = r.ok,
		path        = r.path,
		created     = r.created,
		within_root = r.within_root,
		error       = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_write_file_result_json :: proc(command_id: string, r: Bridge_Fs_Write_File_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Write_Result_Wire{
		type          = "fs_write_file_result",
		command_id    = command_id,
		ok            = r.ok,
		path          = r.path,
		bytes_written = r.bytes_written,
		modified_at   = r.modified_at,
		within_root   = r.within_root,
		error         = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_batch_write_result_json :: proc(command_id: string, r: Bridge_Fs_Batch_Write_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Batch_Write_Result_Wire{
		type       = "fs_batch_write_result",
		command_id = command_id,
		ok         = r.ok,
		saved      = r.saved,
		errors     = r.errors,
		error      = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_find_files_result_json :: proc(command_id: string, r: Bridge_Fs_Find_Files_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Find_Files_Result_Wire{
		type       = "fs_find_files_result",
		command_id = command_id,
		ok         = r.ok,
		root       = r.root,
		truncated  = r.truncated,
		files      = r.files,
		error      = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_grep_result_json :: proc(command_id: string, r: Bridge_Fs_Grep_Result, allocator := context.allocator) -> string {
	wire := Bridge_Fs_Grep_Result_Wire{
		type       = "fs_grep_result",
		command_id = command_id,
		ok         = r.ok,
		root       = r.root,
		truncated  = r.truncated,
		matches    = r.matches,
		error      = bridge_result_error(r.error_code, r.message),
	}
	data, err := json.marshal(wire, allocator = context.temp_allocator)
	if err != nil do return ""
	return strings.clone(string(data), allocator)
}

bridge_fs_find_files_result_delete :: proc(r: ^Bridge_Fs_Find_Files_Result) {
	if r == nil do return
	for f in r.files {
		delete(f)
	}
	delete(r.files)
}

bridge_fs_grep_result_delete :: proc(r: ^Bridge_Fs_Grep_Result) {
	if r == nil do return
	for m in r.matches {
		delete(m.path)
		delete(m.line)
	}
	delete(r.matches)
}

bridge_fs_batch_write_result_delete :: proc(r: ^Bridge_Fs_Batch_Write_Result) {
	if r == nil do return
	for s in r.saved {
		delete(s.path)
	}
	delete(r.saved)
	for e in r.errors {
		delete(e.path)
		delete(e.error_code)
		delete(e.message)
	}
	delete(r.errors)
}

bridge_fs_list_result_delete :: proc(r: ^Bridge_Fs_List_Result) {
	if r == nil do return
	for e in r.entries {
		delete(e.name)
	}
	delete(r.entries)
}
