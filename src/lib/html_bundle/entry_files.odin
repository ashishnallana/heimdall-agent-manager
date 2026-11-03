package html_bundle

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// ── JSON entry/files input (MCP artifacts.create) ──────────────────────────
// A client such as the Claude browser sends a static site as
//   {"entry":"index.html","files":{"index.html":{"text":"<!doctype html>..."},
//    "logo.png":{"base64":"iVBOR...","type":"image/png"}}}
// html_bundle_from_entry_files validates that object and packs it into the existing
// html-bundle format (stored ZIP + heimdall-artifact.json), then re-validates the
// archive with html_bundle_from_zip, so the result passes exactly the checks the
// ham-ctl --file path and the viewer apply.
//
// Per-file object: exactly one of "text" (UTF-8 string, stored as its bytes) or
// "base64" (RFC 4648 standard alphabet with padding, canonical, no whitespace), plus
// an optional "type" that must equal the member's media type by extension.

// html_bundle_media_type maps an allowlisted extension to its media type ("" if the
// extension is not on HTML_BUNDLE_ALLOWED_EXTENSIONS).
html_bundle_media_type :: proc(path: string) -> string {
	if !html_bundle_member_type_allowed(path) do return ""
	dot := strings.last_index_byte(path, '.')
	switch strings.to_lower(path[dot + 1:], context.temp_allocator) {
	case "html", "htm": return "text/html"
	case "css": return "text/css"
	case "js", "mjs": return "text/javascript"
	case "json", "map": return "application/json"
	case "txt": return "text/plain"
	case "md": return "text/markdown"
	case "xml": return "application/xml"
	case "csv": return "text/csv"
	case "webmanifest": return "application/manifest+json"
	case "png": return "image/png"
	case "jpg", "jpeg": return "image/jpeg"
	case "gif": return "image/gif"
	case "webp": return "image/webp"
	case "avif": return "image/avif"
	case "bmp": return "image/bmp"
	case "ico": return "image/vnd.microsoft.icon"
	case "svg": return "image/svg+xml"
	case "woff": return "font/woff"
	case "woff2": return "font/woff2"
	case "ttf": return "font/ttf"
	case "otf": return "font/otf"
	case "eot": return "application/vnd.ms-fontobject"
	}
	return ""
}

// html_bundle_type_matches accepts the canonical media type and the common aliases
// clients emit for the same extension.
@(private = "file")
type_matches :: proc(path, declared: string) -> bool {
	expected := html_bundle_media_type(path)
	if declared == expected do return true
	switch declared {
	case "application/javascript": return expected == "text/javascript"
	case "image/x-icon": return expected == "image/vnd.microsoft.icon"
	case "text/xml": return expected == "application/xml"
	case "application/font-woff": return expected == "font/woff"
	}
	return false
}

// html_bundle_decode_base64 decodes canonical standard base64 only: length a
// multiple of 4, standard alphabet, '=' padding only at the end, and re-encoding the
// result must reproduce the input (rejects non-zero trailing bits and whitespace).
html_bundle_decode_base64 :: proc(text: string, allocator := context.allocator) -> ([]byte, bool) {
	if len(text) % 4 != 0 do return nil, false
	for i in 0 ..< len(text) {
		c := text[i]
		ok := c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/'
		if c == '=' do ok = i >= len(text) - 2 && (i == len(text) - 1 || text[len(text) - 1] == '=')
		if !ok do return nil, false
	}
	if text == "" do return make([]byte, 0, allocator), true
	decoded, err := base64.decode(text, allocator = allocator)
	if err != nil do return nil, false
	again, again_err := base64.encode(decoded, allocator = context.temp_allocator)
	if again_err != nil || again != text {
		delete(decoded, allocator)
		return nil, false
	}
	return decoded, true
}

// html_bundle_from_entry_files validates the JSON entry/files input and returns the
// packed archive. Errors are short, client-facing reasons naming the offending member.
html_bundle_from_entry_files :: proc(entry: string, files: json.Object, allocator := context.allocator) -> (result: Html_Bundle_Result, err: string) {
	if entry == "" do return result, "entry is required"
	if len(files) == 0 do return result, "files must name at least one member"
	if len(files) >= HTML_BUNDLE_MAX_ENTRIES do return result, fmt.tprintf("files has %d members; the limit is %d", len(files), HTML_BUNDLE_MAX_ENTRIES - 1)
	members := make([dynamic]Html_Bundle_File, 0, len(files) + 1, context.temp_allocator)
	total := 0
	for path, raw in files {
		if path_err := html_bundle_validate_path(path); path_err != "" do return result, fmt.tprintf("files %q: %s", path, path_err)
		if strings.has_suffix(path, "/") do return result, fmt.tprintf("files %q: directory entries are not allowed", path)
		if path == HTML_BUNDLE_MANIFEST do return result, fmt.tprintf("files %q: reserved name; the manifest is generated from entry", path)
		if html_bundle_is_nested_archive(path) do return result, fmt.tprintf("member %q is a nested archive; nested archives are not allowed", path)
		if !html_bundle_member_type_allowed(path) do return result, html_bundle_unsupported_type_error(path)
		spec, is_object := raw.(json.Object)
		if !is_object do return result, fmt.tprintf("files %q must be an object with text or base64", path)
		text_value, has_text := spec["text"]
		base64_value, has_base64 := spec["base64"]
		for key in spec do if key != "text" && key != "base64" && key != "type" do return result, fmt.tprintf("files %q has unsupported field %q", path, key)
		if has_text == has_base64 do return result, fmt.tprintf("files %q needs exactly one of text or base64", path)
		if type_value, has_type := spec["type"]; has_type {
			declared, is_string := type_value.(json.String)
			if !is_string || !type_matches(path, string(declared)) do return result, fmt.tprintf("files %q: type must be %q for this extension", path, html_bundle_media_type(path))
		}
		data: []byte
		if has_text {
			text, is_string := text_value.(json.String)
			if !is_string || !utf8.valid_string(string(text)) do return result, fmt.tprintf("files %q: text must be a UTF-8 string", path)
			data = transmute([]byte)string(text)
		} else {
			encoded, is_string := base64_value.(json.String)
			if !is_string do return result, fmt.tprintf("files %q: base64 must be a string", path)
			if len(encoded) > (HTML_BUNDLE_MAX_MEMBER + 2) / 3 * 4 do return result, fmt.tprintf("files %q is larger than %d bytes (15 MB = 15 MiB)", path, HTML_BUNDLE_MAX_MEMBER)
			decoded, decoded_ok := html_bundle_decode_base64(string(encoded), context.temp_allocator)
			if !decoded_ok do return result, fmt.tprintf("files %q: invalid base64 (standard alphabet, padded, no whitespace)", path)
			data = decoded
		}
		if len(data) > HTML_BUNDLE_MAX_MEMBER do return result, fmt.tprintf("files %q is larger than %d bytes (15 MB = 15 MiB)", path, HTML_BUNDLE_MAX_MEMBER)
		total += len(data)
		if total > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("files total more than %d bytes; the artifact limit is 15 MB = 15 MiB", HTML_BUNDLE_MAX_ARCHIVE)
		append(&members, Html_Bundle_File{path = path, data = data})
	}
	paths := make([]string, len(members), context.temp_allocator)
	for m, i in members do paths[i] = m.path
	if _, entry_err := html_bundle_resolve_entry("", entry, paths); entry_err != "" do return result, entry_err
	manifest := html_bundle_manifest_json(entry, context.temp_allocator)
	append(&members, Html_Bundle_File{path = HTML_BUNDLE_MANIFEST, data = transmute([]byte)manifest})
	// Deterministic bytes: the same input always packs to the same archive.
	slice.sort_by(members[:], proc(a, b: Html_Bundle_File) -> bool { return a.path < b.path })
	archive := html_bundle_write_zip(members[:], context.temp_allocator)
	if len(archive) > HTML_BUNDLE_MAX_ARCHIVE do return result, fmt.tprintf("packed bundle is %d bytes; the artifact limit is %d (15 MB = 15 MiB)", len(archive), HTML_BUNDLE_MAX_ARCHIVE)
	// Same structural/member/manifest/entry checks as a prepared --file archive
	// (file/directory clashes, nested-archive magic bytes, expanded size).
	return html_bundle_from_zip(archive, entry, allocator)
}
