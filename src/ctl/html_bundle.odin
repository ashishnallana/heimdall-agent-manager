package main

import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// ── Static HTML bundle artifacts (REQ-BUNDLE-1/2/5) ─────────────────────────
// An html-bundle artifact is a ZIP holding a static site plus the reserved manifest
// `heimdall-artifact.json` = {"format_version":1,"entrypoint":"<member>.html"}.
// `artifact create --kind html-bundle` builds one from --directory, or validates (and,
// when it lacks a manifest, completes) a prepared --file ZIP. The archive bytes are then
// sealed as-is, so the viewer's Download returns exactly these bytes.
//
// The same rules are enforced again in the viewer (src/ui/utils/htmlBundle.ts); keep the
// limits, path grammar and manifest shape in step with it.

HTML_BUNDLE_KIND           :: "html-bundle"
HTML_BUNDLE_CONTENT_TYPE   :: "application/zip"
HTML_BUNDLE_MANIFEST       :: "heimdall-artifact.json"
HTML_BUNDLE_FORMAT_VERSION :: 1
HTML_BUNDLE_MAX_ARCHIVE    :: 10 * 1024 * 1024
HTML_BUNDLE_MAX_EXPANDED   :: 50 * 1024 * 1024
HTML_BUNDLE_MAX_ENTRIES    :: 1000
HTML_BUNDLE_MAX_MEMBER     :: 10 * 1024 * 1024
HTML_BUNDLE_MAX_MANIFEST   :: 64 * 1024
HTML_BUNDLE_MAX_PATH       :: 1024

ZIP_LOCAL_SIG   :: 0x04034b50
ZIP_CENTRAL_SIG :: 0x02014b50
ZIP_EOCD_SIG    :: 0x06054b50
ZIP_EOCD_SIZE   :: 22
ZIP_FLAG_ENCRYPTED :: 0x0001
ZIP_FLAG_UTF8      :: 0x0800

Html_Bundle_Member :: struct {
	path:            string,
	is_dir:          bool,
	method:          u16,
	flags:           u16,
	crc:             u32,
	compressed:      int,
	size:            int,
	local_offset:    int,
	data_offset:     int,
	central_record:  []byte, // the raw central directory record, reused when appending
}

Html_Bundle_Archive :: struct {
	data:    []byte,
	members: [dynamic]Html_Bundle_Member,
	cd_offset: int,
}

// html_bundle_is_html is the member-type test for entrypoints and page lists. The
// extension check is case-insensitive; member paths themselves stay case-sensitive.
html_bundle_is_html :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".html") || strings.has_suffix(lower, ".htm")
}

// html_bundle_is_nested_archive rejects archives inside the bundle by name; the
// viewer additionally checks magic bytes.
html_bundle_is_nested_archive :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for ext in ([]string{".zip", ".jar", ".war", ".apk", ".gz", ".tgz", ".tar", ".bz2", ".xz", ".7z", ".rar", ".zst"}) {
		if strings.has_suffix(lower, ext) do return true
	}
	return false
}

// html_bundle_validate_path enforces the member path grammar: relative, '/'-separated,
// no empty, '.' or '..' segments, no backslashes, drive letters or control characters,
// valid UTF-8. Returns "" when the path is acceptable, else the reason.
html_bundle_validate_path :: proc(path: string) -> string {
	if path == "" do return "empty member path"
	if len(path) > HTML_BUNDLE_MAX_PATH do return "member path is too long"
	if !utf8.valid_string(path) do return "member path is not valid UTF-8"
	if path[0] == '/' do return "absolute member path"
	if len(path) >= 2 && path[1] == ':' do return "drive-qualified member path"
	for i in 0 ..< len(path) {
		c := path[i]
		if c < 0x20 || c == 0x7f do return "control character in member path"
		if c == '\\' do return "backslash in member path"
	}
	trimmed := strings.trim_suffix(path, "/")
	for segment in strings.split(trimmed, "/", context.temp_allocator) {
		if segment == "" do return "empty segment in member path"
		if segment == "." || segment == ".." do return "path traversal in member path"
	}
	return ""
}

// html_bundle_validate_member_set checks duplicates and file/directory clashes over the
// complete member list (paths already passed html_bundle_validate_path).
html_bundle_validate_member_set :: proc(members: []Html_Bundle_Member) -> string {
	if len(members) > HTML_BUNDLE_MAX_ENTRIES do return fmt.tprintf("archive has %d entries; the limit is %d", len(members), HTML_BUNDLE_MAX_ENTRIES)
	files := make(map[string]bool, allocator = context.temp_allocator)
	dirs := make(map[string]bool, allocator = context.temp_allocator)
	for m in members {
		key := strings.trim_suffix(m.path, "/")
		if key in files || (m.is_dir && key in dirs) do return fmt.tprintf("duplicate member path %q", key)
		if !m.is_dir && key in dirs do return fmt.tprintf("member %q is both a file and a directory", key)
		if m.is_dir do dirs[key] = true
		else do files[key] = true
	}
	for m in members {
		if m.is_dir do continue
		// Every ancestor of a file is implicitly a directory, so no file may sit there.
		p := m.path
		for {
			slash := strings.last_index_byte(p, '/')
			if slash < 0 do break
			p = p[:slash]
			if p in files do return fmt.tprintf("member %q is both a file and a directory", p)
		}
	}
	return ""
}

// ── ZIP reading ────────────────────────────────────────────────────────────

@(private = "file")
le16 :: proc(b: []byte, off: int) -> u16 { v, _ := endian.get_u16(b[off:], .Little); return v }
@(private = "file")
le32 :: proc(b: []byte, off: int) -> u32 { v, _ := endian.get_u32(b[off:], .Little); return v }

// html_bundle_parse_zip reads the central directory and checks every structural rule
// that does not need the member bytes: limits, method, encryption, Zip64, symlinks,
// local header consistency, overlapping members and path grammar.
html_bundle_parse_zip :: proc(data: []byte) -> (archive: Html_Bundle_Archive, err: string) {
	archive.data = data
	archive.members = make([dynamic]Html_Bundle_Member, context.temp_allocator)
	if len(data) > HTML_BUNDLE_MAX_ARCHIVE do return archive, fmt.tprintf("archive is %d bytes; the limit is %d (10 MiB)", len(data), HTML_BUNDLE_MAX_ARCHIVE)
	if len(data) < ZIP_EOCD_SIZE do return archive, "not a ZIP archive (too short)"
	eocd := -1
	lowest := max(0, len(data) - ZIP_EOCD_SIZE - 0xffff)
	for i := len(data) - ZIP_EOCD_SIZE; i >= lowest; i -= 1 {
		if le32(data, i) == ZIP_EOCD_SIG && i + ZIP_EOCD_SIZE + int(le16(data, i + 20)) == len(data) {
			eocd = i
			break
		}
	}
	if eocd < 0 do return archive, "not a ZIP archive (no end of central directory record)"
	if le16(data, eocd + 4) != 0 || le16(data, eocd + 6) != 0 do return archive, "multi-disk ZIP archives are not supported"
	count := int(le16(data, eocd + 10))
	if count != int(le16(data, eocd + 8)) do return archive, "multi-disk ZIP archives are not supported"
	cd_size := int(le32(data, eocd + 12))
	cd_offset := int(le32(data, eocd + 16))
	if count == 0xffff || cd_size == 0xffffffff || cd_offset == 0xffffffff do return archive, "Zip64 archives are not supported"
	if count > HTML_BUNDLE_MAX_ENTRIES do return archive, fmt.tprintf("archive has %d entries; the limit is %d", count, HTML_BUNDLE_MAX_ENTRIES)
	if cd_offset + cd_size > eocd do return archive, "corrupt ZIP archive (central directory out of range)"
	archive.cd_offset = cd_offset

	pos := cd_offset
	total := 0
	for _ in 0 ..< count {
		if pos + 46 > cd_offset + cd_size || le32(data, pos) != ZIP_CENTRAL_SIG do return archive, "corrupt ZIP archive (bad central directory record)"
		made_by := le16(data, pos + 4)
		flags := le16(data, pos + 8)
		method := le16(data, pos + 10)
		crc := le32(data, pos + 16)
		csize := int(le32(data, pos + 20))
		usize := int(le32(data, pos + 24))
		name_len := int(le16(data, pos + 28))
		extra_len := int(le16(data, pos + 30))
		comment_len := int(le16(data, pos + 32))
		external := le32(data, pos + 38)
		local := int(le32(data, pos + 42))
		record_end := pos + 46 + name_len + extra_len + comment_len
		if record_end > cd_offset + cd_size do return archive, "corrupt ZIP archive (central directory record out of range)"
		name := string(data[pos + 46:pos + 46 + name_len])
		if flags & ZIP_FLAG_ENCRYPTED != 0 do return archive, fmt.tprintf("member %q is encrypted; encrypted ZIPs are not supported", name)
		if csize == 0xffffffff || usize == 0xffffffff || local == 0xffffffff do return archive, "Zip64 archives are not supported"
		if method != 0 && method != 8 do return archive, fmt.tprintf("member %q uses unsupported compression method %d (only stored and deflate)", name, method)
		if flags & ZIP_FLAG_UTF8 == 0 {
			for i in 0 ..< len(name) do if name[i] >= 0x80 do return archive, fmt.tprintf("member path %q is not ASCII and not flagged UTF-8", name)
		}
		if reason := html_bundle_validate_path(name); reason != "" do return archive, fmt.tprintf("%s: %q", reason, name)
		// Unix 'version made by' carries st_mode in the high half of the external attributes.
		if made_by >> 8 == 3 && (external >> 16) & 0o170000 == 0o120000 do return archive, fmt.tprintf("member %q is a symbolic link; links are not allowed", name)
		is_dir := strings.has_suffix(name, "/")
		if is_dir && usize != 0 do return archive, fmt.tprintf("directory member %q has content", name)
		if !is_dir && html_bundle_is_nested_archive(name) do return archive, fmt.tprintf("member %q is a nested archive; nested archives are not allowed", name)
		if usize > HTML_BUNDLE_MAX_MEMBER do return archive, fmt.tprintf("member %q declares %d bytes; the per-member limit is %d (10 MiB)", name, usize, HTML_BUNDLE_MAX_MEMBER)
		if method == 0 && csize != usize do return archive, fmt.tprintf("stored member %q has mismatched sizes", name)
		total += usize
		if total > HTML_BUNDLE_MAX_EXPANDED do return archive, fmt.tprintf("archive expands past %d bytes (50 MiB)", HTML_BUNDLE_MAX_EXPANDED)

		if local + 30 > cd_offset || le32(data, local) != ZIP_LOCAL_SIG do return archive, fmt.tprintf("corrupt ZIP archive (bad local header for %q)", name)
		local_name_len := int(le16(data, local + 26))
		local_extra_len := int(le16(data, local + 28))
		data_offset := local + 30 + local_name_len + local_extra_len
		if data_offset > cd_offset || string(data[local + 30:local + 30 + local_name_len]) != name do return archive, fmt.tprintf("corrupt ZIP archive (local header disagrees for %q)", name)
		if le16(data, local + 6) & ZIP_FLAG_ENCRYPTED != 0 do return archive, fmt.tprintf("member %q is encrypted; encrypted ZIPs are not supported", name)
		if data_offset + csize > cd_offset do return archive, fmt.tprintf("corrupt ZIP archive (data for %q out of range)", name)
		append(&archive.members, Html_Bundle_Member{
			path = name, is_dir = is_dir, method = method, flags = flags, crc = crc,
			compressed = csize, size = usize, local_offset = local, data_offset = data_offset,
			central_record = data[pos:record_end],
		})
		pos = record_end
	}
	// Members must not overlap: overlapping local records are the classic way to make a
	// small archive expand far past its size.
	sorted := slice.clone(archive.members[:], context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Html_Bundle_Member) -> bool { return a.local_offset < b.local_offset })
	for i in 1 ..< len(sorted) {
		if sorted[i].local_offset < sorted[i - 1].data_offset + sorted[i - 1].compressed do return archive, fmt.tprintf("corrupt ZIP archive (members %q and %q overlap)", sorted[i - 1].path, sorted[i].path)
	}
	if reason := html_bundle_validate_member_set(archive.members[:]); reason != "" do return archive, reason
	return archive, ""
}

// Bounded_Allocator caps what inflate may allocate, so a member whose actual expansion
// exceeds its declared size fails instead of exhausting memory.
@(private = "file")
Bounded_Allocator :: struct {
	backing: mem.Allocator,
	used:    int,
	limit:   int,
}

@(private = "file")
bounded_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	b := (^Bounded_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if b.used + size > b.limit do return nil, .Out_Of_Memory
		res, err := b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err == nil do b.used += size
		return res, err
	case .Resize, .Resize_Non_Zeroed:
		if b.used - old_size + size > b.limit do return nil, .Out_Of_Memory
		res, err := b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err == nil do b.used += size - old_size
		return res, err
	case .Free:
		b.used -= old_size
	}
	return b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// html_bundle_read_member returns a member's bytes, inflating deflate members under a
// hard allocation cap and checking the actual size and CRC-32 against the directory.
html_bundle_read_member :: proc(archive: ^Html_Bundle_Archive, m: Html_Bundle_Member, allocator := context.allocator) -> (out: []byte, err: string) {
	raw := archive.data[m.data_offset:m.data_offset + m.compressed]
	if m.method == 0 {
		out = slice.clone(raw, allocator)
	} else {
		// inflate pre-sizes its output to max(declared, 1 MiB); any growth past that means
		// the member expands beyond its declaration, so the cap allows no growth at all.
		bounded := Bounded_Allocator{backing = allocator, limit = max(m.size, compress.COMPRESS_OUTPUT_ALLOCATE_MIN) + 64 * 1024}
		bounded_alloc := mem.Allocator{procedure = bounded_allocator_proc, data = &bounded}
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 0, bounded_alloc)
		inflate_err := zlib.inflate_from_byte_array_raw(raw, &buf, expected_output_size = m.size)
		if inflate_err != nil {
			bytes.buffer_destroy(&buf)
			return nil, fmt.tprintf("member %q could not be inflated (corrupt, or larger than declared)", m.path)
		}
		inflated := bytes.buffer_to_bytes(&buf)
		out = slice.clone(inflated, allocator)
		bytes.buffer_destroy(&buf)
	}
	if len(out) != m.size {
		delete(out, allocator)
		return nil, fmt.tprintf("member %q expands to %d bytes but declares %d", m.path, len(out), m.size)
	}
	if hash.crc32(out) != m.crc {
		delete(out, allocator)
		return nil, fmt.tprintf("member %q fails its CRC-32 check", m.path)
	}
	return out, ""
}

// ── Manifest ───────────────────────────────────────────────────────────────

html_bundle_manifest_json :: proc(entrypoint: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"format_version":1,"entrypoint":"`)
	json_write_string(&b, entrypoint)
	strings.write_string(&b, "\"}\n")
	return strings.to_string(b)
}

// html_bundle_parse_manifest accepts exactly one JSON object with exactly the keys
// format_version (integer 1) and entrypoint (string). Anything else is an error so
// that a future format bump is never silently misread.
html_bundle_parse_manifest :: proc(data: []byte) -> (entrypoint: string, err: string) {
	if len(data) > HTML_BUNDLE_MAX_MANIFEST do return "", HTML_BUNDLE_MANIFEST + " is larger than 64 KiB"
	text := string(data)
	if !utf8.valid_string(text) do return "", HTML_BUNDLE_MANIFEST + " is not valid UTF-8"
	// Core's error paths free with context.allocator: keep the whole tree on temp.
	context.allocator = context.temp_allocator
	parser := json.make_parser_from_string(text, .JSON, true, context.temp_allocator)
	value, parse_err := json.parse_value(&parser)
	object, is_object := value.(json.Object)
	if parse_err != nil || !is_object || parser.curr_token.kind != .EOF do return "", HTML_BUNDLE_MANIFEST + " must be a single JSON object"
	for key in object {
		if key != "format_version" && key != "entrypoint" do return "", fmt.tprintf("%s has unsupported field %q", HTML_BUNDLE_MANIFEST, key)
	}
	version, version_ok := object["format_version"].(json.Integer)
	if !version_ok do return "", HTML_BUNDLE_MANIFEST + " needs an integer format_version"
	if version != HTML_BUNDLE_FORMAT_VERSION do return "", fmt.tprintf("%s format_version %d is not supported (expected 1)", HTML_BUNDLE_MANIFEST, version)
	entry, entry_ok := object["entrypoint"].(json.String)
	if !entry_ok || entry == "" do return "", HTML_BUNDLE_MANIFEST + " needs a string entrypoint"
	return strings.clone(string(entry), context.temp_allocator), ""
}

// html_bundle_resolve_entry implements the entry rule shared with the viewer:
//   manifest + --entry must agree; else manifest; else --entry; else root index.html;
//   else the sole HTML file; else an error listing the candidates.
// The chosen entry must name an existing HTML member.
html_bundle_resolve_entry :: proc(manifest_entry, flag_entry: string, files: []string) -> (entry: string, err: string) {
	entry = manifest_entry
	if manifest_entry != "" && flag_entry != "" && manifest_entry != flag_entry {
		return "", fmt.tprintf("--entry %q conflicts with %s entrypoint %q; drop --entry or fix the manifest", flag_entry, HTML_BUNDLE_MANIFEST, manifest_entry)
	}
	if entry == "" do entry = flag_entry
	pages := make([dynamic]string, context.temp_allocator)
	for f in files do if html_bundle_is_html(f) do append(&pages, f)
	if entry == "" {
		if slice.contains(files, "index.html") {
			entry = "index.html"
		} else if len(pages) == 1 {
			entry = pages[0]
		} else if len(pages) == 0 {
			return "", "bundle contains no HTML file"
		} else {
			slice.sort(pages[:])
			shown := pages[:min(len(pages), 10)]
			return "", fmt.tprintf("bundle has no root index.html and %d HTML files (%s%s); choose one with --entry <relative.html>", len(pages), strings.join(shown, ", ", context.temp_allocator), len(pages) > 10 ? ", …" : "")
		}
	}
	if !html_bundle_is_html(entry) do return "", fmt.tprintf("entry %q is not an HTML file (.html or .htm)", entry)
	if !slice.contains(files, entry) do return "", fmt.tprintf("entry %q does not exist in the bundle (paths are case-sensitive)", entry)
	return entry, ""
}

// ── ZIP writing (stored; core has inflate but no deflate) ──────────────────

Html_Bundle_File :: struct {
	path: string,
	data: []byte,
}

// 1980-01-01 00:00 in DOS format: fixed so the same tree always packs to the same bytes.
@(private = "file") ZIP_DOS_TIME :: u16(0)
@(private = "file") ZIP_DOS_DATE :: u16((0 << 9) | (1 << 5) | 1)

@(private = "file")
put16 :: proc(b: ^[dynamic]byte, v: u16) { append(b, byte(v), byte(v >> 8)) }
@(private = "file")
put32 :: proc(b: ^[dynamic]byte, v: u32) { append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)) }

@(private = "file")
write_local_stored :: proc(out: ^[dynamic]byte, path: string, data: []byte, crc: u32) {
	put32(out, ZIP_LOCAL_SIG)
	put16(out, 20)
	put16(out, ZIP_FLAG_UTF8)
	put16(out, 0)
	put16(out, ZIP_DOS_TIME)
	put16(out, ZIP_DOS_DATE)
	put32(out, crc)
	put32(out, u32(len(data)))
	put32(out, u32(len(data)))
	put16(out, u16(len(path)))
	put16(out, 0)
	append(out, ..transmute([]byte)path)
	append(out, ..data)
}

@(private = "file")
write_central_stored :: proc(out: ^[dynamic]byte, path: string, size: int, crc: u32, offset: int) {
	put32(out, ZIP_CENTRAL_SIG)
	put16(out, (3 << 8) | 20) // made by Unix, spec 2.0
	put16(out, 20)
	put16(out, ZIP_FLAG_UTF8)
	put16(out, 0)
	put16(out, ZIP_DOS_TIME)
	put16(out, ZIP_DOS_DATE)
	put32(out, crc)
	put32(out, u32(size))
	put32(out, u32(size))
	put16(out, u16(len(path)))
	put16(out, 0)
	put16(out, 0)
	put16(out, 0)
	put16(out, 0)
	put32(out, u32(0o100644) << 16) // regular file, rw-r--r--
	put32(out, u32(offset))
	append(out, ..transmute([]byte)path)
}

@(private = "file")
write_eocd :: proc(out: ^[dynamic]byte, count, cd_size, cd_offset: int) {
	put32(out, ZIP_EOCD_SIG)
	put16(out, 0)
	put16(out, 0)
	put16(out, u16(count))
	put16(out, u16(count))
	put32(out, u32(cd_size))
	put32(out, u32(cd_offset))
	put16(out, 0)
}

// html_bundle_write_zip packs files (already validated, sorted by the caller) as a
// stored ZIP.
html_bundle_write_zip :: proc(files: []Html_Bundle_File, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	offsets := make([]int, len(files), context.temp_allocator)
	crcs := make([]u32, len(files), context.temp_allocator)
	for f, i in files {
		offsets[i] = len(out)
		crcs[i] = hash.crc32(f.data)
		write_local_stored(&out, f.path, f.data, crcs[i])
	}
	cd_offset := len(out)
	for f, i in files do write_central_stored(&out, f.path, len(f.data), crcs[i], offsets[i])
	write_eocd(&out, len(files), len(out) - cd_offset, cd_offset)
	return out[:]
}

// html_bundle_append_manifest adds the manifest to a prepared archive that lacks one.
// Every existing local record (header + data) is copied byte-for-byte, the manifest is
// written after them, and the central directory is rebuilt from the original records.
html_bundle_append_manifest :: proc(archive: ^Html_Bundle_Archive, manifest: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	append(&out, ..archive.data[:archive.cd_offset])
	manifest_offset := len(out)
	crc := hash.crc32(manifest)
	write_local_stored(&out, HTML_BUNDLE_MANIFEST, manifest, crc)
	cd_offset := len(out)
	for m in archive.members do append(&out, ..m.central_record)
	write_central_stored(&out, HTML_BUNDLE_MANIFEST, len(manifest), crc, manifest_offset)
	write_eocd(&out, len(archive.members) + 1, len(out) - cd_offset, cd_offset)
	return out[:]
}

// ── Packaging entry points ─────────────────────────────────────────────────

Html_Bundle_Result :: struct {
	zip:              []byte,
	entry:            string,
	pages:            int,
	files:            int,
	skipped_symlinks: [dynamic]string,
}

// html_bundle_from_zip validates a prepared archive (structure, every member's actual
// bytes, manifest, entry) and returns it unchanged, or with a manifest appended when it
// had none.
html_bundle_from_zip :: proc(data: []byte, flag_entry: string, allocator := context.allocator) -> (result: Html_Bundle_Result, err: string) {
	archive, parse_err := html_bundle_parse_zip(data)
	if parse_err != "" do return result, parse_err
	files := make([dynamic]string, context.temp_allocator)
	manifest_entry := ""
	has_manifest := false
	actual_total := 0
	for m in archive.members {
		if m.is_dir do continue
		content, read_err := html_bundle_read_member(&archive, m, context.temp_allocator)
		if read_err != "" do return result, read_err
		actual_total += len(content)
		if actual_total > HTML_BUNDLE_MAX_EXPANDED do return result, fmt.tprintf("archive expands past %d bytes (50 MiB)", HTML_BUNDLE_MAX_EXPANDED)
		if len(content) >= 4 && content[0] == 'P' && content[1] == 'K' && content[2] == 3 && content[3] == 4 do return result, fmt.tprintf("member %q is a nested archive; nested archives are not allowed", m.path)
		if m.path == HTML_BUNDLE_MANIFEST {
			has_manifest = true
			entry, manifest_err := html_bundle_parse_manifest(content)
			if manifest_err != "" do return result, manifest_err
			manifest_entry = entry
			continue
		}
		append(&files, m.path)
	}
	entry, entry_err := html_bundle_resolve_entry(manifest_entry, flag_entry, files[:])
	if entry_err != "" do return result, entry_err
	result.entry = entry
	result.files = len(files)
	for f in files do if html_bundle_is_html(f) do result.pages += 1
	if has_manifest {
		result.zip = slice.clone(data, allocator)
	} else {
		manifest := html_bundle_manifest_json(entry, context.temp_allocator)
		result.zip = html_bundle_append_manifest(&archive, transmute([]byte)manifest, allocator)
		if len(result.zip) > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("archive with manifest is %d bytes; the limit is %d (10 MiB)", len(result.zip), HTML_BUNDLE_MAX_ARCHIVE)
	}
	return result, ""
}

// html_bundle_collect walks root without following symlinks: links are skipped and
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
		if st.size > HTML_BUNDLE_MAX_MEMBER do return fmt.tprintf("%q is %d bytes; the per-member limit is %d (10 MiB)", child, st.size, HTML_BUNDLE_MAX_MEMBER)
		if len(files) + 1 > HTML_BUNDLE_MAX_ENTRIES do return fmt.tprintf("directory has more than %d files", HTML_BUNDLE_MAX_ENTRIES)
		data, data_err := os.read_entire_file(info.fullpath, context.temp_allocator)
		if data_err != nil do return fmt.tprintf("cannot read %q", child)
		if len(data) > HTML_BUNDLE_MAX_MEMBER do return fmt.tprintf("%q is %d bytes; the per-member limit is %d (10 MiB)", child, len(data), HTML_BUNDLE_MAX_MEMBER)
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
	if len(result.zip) > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("packed bundle is %d bytes; the limit is %d (10 MiB, stored without compression)", len(result.zip), HTML_BUNDLE_MAX_ARCHIVE)
	result.entry = entry
	result.files = len(content_files)
	for p in paths do if html_bundle_is_html(p) do result.pages += 1
	return result, ""
}

// html_bundle_package_from_args is the CLI front: exactly one of --directory or --file,
// optional --entry. Returns the archive bytes or an actionable error.
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
		if size > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("--file %q is %d bytes; the limit is %d (10 MiB)", file, size, HTML_BUNDLE_MAX_ARCHIVE)
		data, read_err := os.read_entire_file(file, context.temp_allocator)
		if read_err != nil do return result, fmt.tprintf("cannot read --file %q", file)
		return html_bundle_from_zip(data, entry, allocator)
	}
	return result, "html-bundle needs --directory <path> or --file <bundle.zip>"
}
