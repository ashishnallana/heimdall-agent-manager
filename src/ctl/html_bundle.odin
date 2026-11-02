package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import hb "odin_test:lib/html_bundle"

// ── Static HTML bundle artifacts: ham-ctl packaging ─────────────────────────
// The format core (limits, path grammar, type allowlist, ZIP reader/writer,
// manifest, entry rule) lives in src/lib/html_bundle and is shared with the Hub's
// MCP artifacts.create entry/files path. This file keeps only the filesystem
// packaging used by `artifact create --kind html-bundle`. The aliases keep
// existing call sites and tests unchanged.
HTML_BUNDLE_KIND :: hb.HTML_BUNDLE_KIND
HTML_BUNDLE_CONTENT_TYPE :: hb.HTML_BUNDLE_CONTENT_TYPE
HTML_BUNDLE_MANIFEST :: hb.HTML_BUNDLE_MANIFEST
HTML_BUNDLE_FORMAT_VERSION :: hb.HTML_BUNDLE_FORMAT_VERSION
HTML_BUNDLE_MAX_ARCHIVE :: hb.HTML_BUNDLE_MAX_ARCHIVE
HTML_BUNDLE_MAX_EXPANDED :: hb.HTML_BUNDLE_MAX_EXPANDED
HTML_BUNDLE_MAX_ENTRIES :: hb.HTML_BUNDLE_MAX_ENTRIES
HTML_BUNDLE_MAX_MEMBER :: hb.HTML_BUNDLE_MAX_MEMBER
HTML_BUNDLE_MAX_MANIFEST :: hb.HTML_BUNDLE_MAX_MANIFEST
HTML_BUNDLE_MAX_PATH :: hb.HTML_BUNDLE_MAX_PATH
HTML_BUNDLE_ALLOWED_EXTENSIONS :: hb.HTML_BUNDLE_ALLOWED_EXTENSIONS
Html_Bundle_Member :: hb.Html_Bundle_Member
Html_Bundle_Archive :: hb.Html_Bundle_Archive
Html_Bundle_File :: hb.Html_Bundle_File
Html_Bundle_Result :: hb.Html_Bundle_Result
html_bundle_is_html :: hb.html_bundle_is_html
html_bundle_member_type_allowed :: hb.html_bundle_member_type_allowed
html_bundle_unsupported_type_error :: hb.html_bundle_unsupported_type_error
html_bundle_is_nested_archive :: hb.html_bundle_is_nested_archive
html_bundle_validate_path :: hb.html_bundle_validate_path
html_bundle_validate_member_set :: hb.html_bundle_validate_member_set
html_bundle_parse_zip :: hb.html_bundle_parse_zip
html_bundle_read_member :: hb.html_bundle_read_member
html_bundle_manifest_json :: hb.html_bundle_manifest_json
html_bundle_parse_manifest :: hb.html_bundle_parse_manifest
html_bundle_resolve_entry :: hb.html_bundle_resolve_entry
html_bundle_write_zip :: hb.html_bundle_write_zip
html_bundle_append_manifest :: hb.html_bundle_append_manifest
html_bundle_from_zip :: hb.html_bundle_from_zip
ZIP_LOCAL_SIG :: hb.ZIP_LOCAL_SIG
ZIP_CENTRAL_SIG :: hb.ZIP_CENTRAL_SIG
ZIP_EOCD_SIG :: hb.ZIP_EOCD_SIG
ZIP_FLAG_ENCRYPTED :: hb.ZIP_FLAG_ENCRYPTED
// reported, never followed, so nothing outside root can be packed.
@(private = "file")
html_bundle_collect :: proc(root, rel: string, files: ^[dynamic]Html_Bundle_File, skipped: ^[dynamic]string, total: ^int) -> string {
	dir := rel == "" ? root : fmt.tprintf("%s/%s", root, rel)
	infos, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if read_err != nil do return fmt.tprintf("cannot read directory %q", dir)
	for info in infos {
		if info.name == "" || info.name == "." || info.name == ".." do continue
		child := rel == "" ? strings.clone(info.name, context.temp_allocator) : fmt.tprintf("%s/%s", rel, info.name)
		// Re-check with lstat: the listing's type must not be trusted to mean "not a link".
		st, st_err := os.lstat(info.fullpath, context.temp_allocator)
		if st_err != nil do return fmt.tprintf("cannot stat %q", child)
		#partial switch st.type {
		case .Symlink:
			append(skipped, child)
			continue
		case .Directory:
			if reason := html_bundle_validate_path(child); reason != "" do return fmt.tprintf("%s: %q", reason, child)
			if err := html_bundle_collect(root, child, files, skipped, total); err != "" do return err
			continue
		case .Regular:
		case:
			append(skipped, child)
			continue
		}
		if reason := html_bundle_validate_path(child); reason != "" do return fmt.tprintf("%s: %q", reason, child)
		if html_bundle_is_nested_archive(child) do return fmt.tprintf("%q is an archive; nested archives are not allowed", child)
		if !html_bundle_member_type_allowed(child) do return html_bundle_unsupported_type_error(child)
		if st.size > HTML_BUNDLE_MAX_MEMBER do return fmt.tprintf("%q is %d bytes; the per-member limit is %d (15 MiB)", child, st.size, HTML_BUNDLE_MAX_MEMBER)
		if len(files) + 1 > HTML_BUNDLE_MAX_ENTRIES do return fmt.tprintf("directory has more than %d files", HTML_BUNDLE_MAX_ENTRIES)
		data, data_err := os.read_entire_file(info.fullpath, context.temp_allocator)
		if data_err != nil do return fmt.tprintf("cannot read %q", child)
		if len(data) > HTML_BUNDLE_MAX_MEMBER do return fmt.tprintf("%q is %d bytes; the per-member limit is %d (15 MiB)", child, len(data), HTML_BUNDLE_MAX_MEMBER)
		total^ += len(data)
		if total^ > HTML_BUNDLE_MAX_EXPANDED do return fmt.tprintf("directory content exceeds %d bytes (50 MiB)", HTML_BUNDLE_MAX_EXPANDED)
		append(files, Html_Bundle_File{path = child, data = data})
	}
	return ""
}

// html_bundle_from_directory packs root (relative paths preserved, sorted, symlinks
// excluded) plus a generated or validated manifest into a stored ZIP.
html_bundle_from_directory :: proc(root, flag_entry: string, allocator := context.allocator) -> (result: Html_Bundle_Result, err: string) {
	if !os.is_dir(root) do return result, fmt.tprintf("--directory %q is not a directory", root)
	files := make([dynamic]Html_Bundle_File, context.temp_allocator)
	result.skipped_symlinks = make([dynamic]string, context.temp_allocator)
	total := 0
	if walk_err := html_bundle_collect(strings.trim_right(root, "/"), "", &files, &result.skipped_symlinks, &total); walk_err != "" do return result, walk_err
	slice.sort_by(files[:], proc(a, b: Html_Bundle_File) -> bool { return a.path < b.path })

	manifest_entry := ""
	paths := make([dynamic]string, context.temp_allocator)
	content_files := make([dynamic]Html_Bundle_File, context.temp_allocator)
	for f in files {
		if f.path == HTML_BUNDLE_MANIFEST {
			entry, manifest_err := html_bundle_parse_manifest(f.data)
			if manifest_err != "" do return result, manifest_err
			manifest_entry = entry
			continue
		}
		append(&paths, f.path)
		append(&content_files, f)
	}
	entry, entry_err := html_bundle_resolve_entry(manifest_entry, flag_entry, paths[:])
	if entry_err != "" do return result, entry_err

	// The manifest goes first and is always regenerated in canonical form.
	packed := make([dynamic]Html_Bundle_File, context.temp_allocator)
	append(&packed, Html_Bundle_File{path = HTML_BUNDLE_MANIFEST, data = transmute([]byte)html_bundle_manifest_json(entry, context.temp_allocator)})
	append(&packed, ..content_files[:])
	result.zip = html_bundle_write_zip(packed[:], allocator)
	if len(result.zip) > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("packed bundle is %d bytes; the limit is %d (15 MB = 15 MiB, stored without compression)", len(result.zip), HTML_BUNDLE_MAX_ARCHIVE)
	result.entry = entry
	result.files = len(content_files)
	for p in paths do if html_bundle_is_html(p) do result.pages += 1
	return result, ""
}

// html_bundle_package_from_args is the CLI front: exactly one of --directory or --file,
// optional --entry. Returns the archive bytes or an actionable error.
// --directory and --entry only mean something for html-bundle; any other kind would
// silently drop them and create an empty artifact.
html_bundle_flags_error :: proc(args: []string, kind: string) -> string {
	if kind == HTML_BUNDLE_KIND do return ""
	for flag in ([]string{"--directory", "--entry"}) {
		if has_flag(args, flag) do return fmt.tprintf("%s is only valid with --kind %s (got --kind %s)", flag, HTML_BUNDLE_KIND, kind)
	}
	return ""
}

html_bundle_package_from_args :: proc(args: []string, allocator := context.allocator) -> (result: Html_Bundle_Result, err: string) {
	directory := option_value(args, "--directory", "")
	file := option_value(args, "--file", "")
	entry := option_value(args, "--entry", "")
	if has_flag(args, "--stdin") || option_value(args, "--content", "") != "" do return result, "html-bundle takes --directory <path> or --file <bundle.zip>, not --content/--stdin"
	if directory != "" && file != "" do return result, "html-bundle takes --directory or --file, not both"
	if directory != "" do return html_bundle_from_directory(directory, entry, allocator)
	if file != "" {
		st, st_err := os.stat(file, context.temp_allocator)
		if st_err != nil || st.type != .Regular do return result, fmt.tprintf("cannot read --file %q", file)
		size := st.size
		if size > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("--file %q is %d bytes; the limit is %d (15 MB = 15 MiB)", file, size, HTML_BUNDLE_MAX_ARCHIVE)
		data, read_err := os.read_entire_file(file, context.temp_allocator)
		if read_err != nil do return result, fmt.tprintf("cannot read --file %q", file)
		return html_bundle_from_zip(data, entry, allocator)
	}
	return result, "html-bundle needs --directory <path> or --file <bundle.zip>"
}
