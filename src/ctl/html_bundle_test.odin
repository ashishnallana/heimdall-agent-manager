package main

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// ── REQ-BUNDLE-1/2/5: html-bundle packaging and validation ──────────────────

// 100000 x 'a' as a raw deflate stream (115 bytes): a real compressed member, and a
// small-archive / large-expansion input when its declared size is understated.
HB_DEFLATE_100K_A_HEX :: "edc13101000000c2a0aceb5fc21a1e4001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000af06"
HB_DEFLATE_100K_A_CRC :: 0x1be2fa87

Hb_Test_Entry :: struct {
	name:          string,
	data:          []byte, // member bytes as stored (already deflated when method = 8)
	method:        u16,
	flags:         u16,
	declared_size: int,  // -1: len(data)
	crc:           u32,  // 0: crc of data
	external:      u32,
	made_by:       u16,
}

hb_put16 :: proc(b: ^[dynamic]byte, v: u16) { append(b, byte(v), byte(v >> 8)) }
hb_put32 :: proc(b: ^[dynamic]byte, v: u32) { append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)) }

// hb_test_zip writes an archive with full control over names, flags, methods and
// declared sizes, so the tests can express malformed and hostile inputs.
hb_test_zip :: proc(entries: []Hb_Test_Entry) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	offsets := make([]int, len(entries), context.temp_allocator)
	for e, i in entries {
		offsets[i] = len(out)
		size := e.declared_size < 0 ? len(e.data) : e.declared_size
		crc := e.crc != 0 ? e.crc : hash.crc32(e.data)
		hb_put32(&out, ZIP_LOCAL_SIG); hb_put16(&out, 20); hb_put16(&out, e.flags); hb_put16(&out, e.method)
		hb_put16(&out, 0); hb_put16(&out, 0x21); hb_put32(&out, crc)
		hb_put32(&out, u32(len(e.data))); hb_put32(&out, u32(size))
		hb_put16(&out, u16(len(e.name))); hb_put16(&out, 0)
		append(&out, ..transmute([]byte)e.name)
		append(&out, ..e.data)
	}
	cd := len(out)
	for e, i in entries {
		size := e.declared_size < 0 ? len(e.data) : e.declared_size
		crc := e.crc != 0 ? e.crc : hash.crc32(e.data)
		hb_put32(&out, ZIP_CENTRAL_SIG); hb_put16(&out, e.made_by); hb_put16(&out, 20); hb_put16(&out, e.flags); hb_put16(&out, e.method)
		hb_put16(&out, 0); hb_put16(&out, 0x21); hb_put32(&out, crc)
		hb_put32(&out, u32(len(e.data))); hb_put32(&out, u32(size))
		hb_put16(&out, u16(len(e.name))); hb_put16(&out, 0); hb_put16(&out, 0); hb_put16(&out, 0); hb_put16(&out, 0)
		hb_put32(&out, e.external); hb_put32(&out, u32(offsets[i]))
		append(&out, ..transmute([]byte)e.name)
	}
	cd_size := len(out) - cd
	hb_put32(&out, ZIP_EOCD_SIG); hb_put16(&out, 0); hb_put16(&out, 0)
	hb_put16(&out, u16(len(entries))); hb_put16(&out, u16(len(entries)))
	hb_put32(&out, u32(cd_size)); hb_put32(&out, u32(cd)); hb_put16(&out, 0)
	return out[:]
}

hb_entry :: proc(name: string, data: string) -> Hb_Test_Entry {
	return Hb_Test_Entry{name = name, data = transmute([]byte)data, declared_size = -1}
}

HB_MANIFEST_INDEX :: `{"format_version":1,"entrypoint":"index.html"}`

hb_tmp_root :: proc(t: ^testing.T, label: string) -> string {
	root := fmt.tprintf("%s/.cache/heimdall-tests/hb-%s-%d-%p", os.get_env("HOME", context.temp_allocator), label, os.get_pid(), t)
	os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil, "temp root must be created")
	return root
}

hb_write :: proc(t: ^testing.T, root, rel, content: string) {
	path := fmt.tprintf("%s/%s", root, rel)
	if slash := strings.last_index_byte(path, '/'); slash > 0 do os.make_directory_all(path[:slash])
	testing.expect(t, os.write_entire_file(path, transmute([]byte)content) == nil, "fixture file must be written")
}

hb_member_paths :: proc(archive: Html_Bundle_Archive) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for m in archive.members do append(&out, m.path)
	return out[:]
}

hb_expect_error :: proc(t: ^testing.T, err, needle: string, loc := #caller_location) {
	testing.expectf(t, err != "" && strings.contains(err, needle), "expected error containing %q, got %q", needle, err, loc = loc)
}

@(test)
test_html_bundle_directory_packs_relative_paths_and_skips_symlinks :: proc(t: ^testing.T) {
	root := hb_tmp_root(t, "dir")
	defer os.remove_all(root)
	outside := hb_tmp_root(t, "outside")
	defer os.remove_all(outside)
	hb_write(t, outside, "secret.txt", "outside the root")
	hb_write(t, root, "index.html", `<a href="docs/page2.html#s">next</a>`)
	hb_write(t, root, "docs/page2.html", `<link rel="stylesheet" href="../css/site.css"><h1 id="s">2</h1>`)
	hb_write(t, root, "css/site.css", `@import "base.css"; body{background:url(/img/bg.png)}`)
	hb_write(t, root, "css/base.css", `@font-face{font-family:x;src:url(../fonts/x.woff2)}`)
	hb_write(t, root, "img/bg.png", "\x89PNG\r\n\x1a\n\x00\xff")
	hb_write(t, root, "fonts/x.woff2", "wOF2\x00\x01")
	link_target := strings.clone_to_cstring(outside, context.temp_allocator)
	link_path := strings.clone_to_cstring(fmt.tprintf("%s/leak", root), context.temp_allocator)
	testing.expect(t, posix.symlink(link_target, link_path) == .OK, "symlink fixture")
	file_link := strings.clone_to_cstring(fmt.tprintf("%s/secret.txt", outside), context.temp_allocator)
	file_link_path := strings.clone_to_cstring(fmt.tprintf("%s/secret.txt", root), context.temp_allocator)
	testing.expect(t, posix.symlink(file_link, file_link_path) == .OK, "file symlink fixture")

	result, err := html_bundle_from_directory(root, "", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, result.entry, "index.html")
	testing.expect_value(t, result.pages, 2)
	testing.expect_value(t, result.files, 6)
	testing.expect(t, slice.contains(result.skipped_symlinks[:], "leak") && slice.contains(result.skipped_symlinks[:], "secret.txt"), "symlinks are skipped and reported")

	archive, parse_err := html_bundle_parse_zip(result.zip)
	testing.expect_value(t, parse_err, "")
	paths := hb_member_paths(archive)
	testing.expect_value(t, paths[0], HTML_BUNDLE_MANIFEST)
	testing.expect(t, slice.equal(paths[1:], []string{"css/base.css", "css/site.css", "docs/page2.html", "fonts/x.woff2", "img/bg.png", "index.html"}), "relative paths preserved and sorted")
	for p in paths do testing.expectf(t, !strings.contains(p, "secret") && !strings.contains(p, "leak"), "nothing behind a symlink is packed: %s", p)

	manifest, _ := html_bundle_read_member(&archive, archive.members[0], context.temp_allocator)
	testing.expect_value(t, string(manifest), HB_MANIFEST_INDEX + "\n")
	png, _ := html_bundle_read_member(&archive, archive.members[5], context.temp_allocator)
	testing.expect_value(t, string(png), "\x89PNG\r\n\x1a\n\x00\xff")

	// Deterministic: the same tree packs to the same bytes.
	again, _ := html_bundle_from_directory(root, "", context.temp_allocator)
	testing.expect(t, slice.equal(again.zip, result.zip), "packing is deterministic")
	// And the packed archive is itself a valid prepared bundle, returned unchanged.
	reread, reread_err := html_bundle_from_zip(result.zip, "", context.temp_allocator)
	testing.expect_value(t, reread_err, "")
	testing.expect(t, slice.equal(reread.zip, result.zip), "a bundle with a manifest is uploaded byte-identical")
}

@(test)
test_html_bundle_entry_resolution :: proc(t: ^testing.T) {
	entry, err := html_bundle_resolve_entry("", "", []string{"a.html", "index.html", "x/index.html"})
	testing.expect_value(t, err, ""); testing.expect_value(t, entry, "index.html")
	entry, err = html_bundle_resolve_entry("", "", []string{"docs/only.htm", "style.css"})
	testing.expect_value(t, err, ""); testing.expect_value(t, entry, "docs/only.htm")
	entry, err = html_bundle_resolve_entry("", "b.html", []string{"a.html", "b.html"})
	testing.expect_value(t, err, ""); testing.expect_value(t, entry, "b.html")
	entry, err = html_bundle_resolve_entry("b.html", "b.html", []string{"a.html", "b.html"})
	testing.expect_value(t, err, ""); testing.expect_value(t, entry, "b.html")
	entry, err = html_bundle_resolve_entry("b.html", "", []string{"index.html", "b.html"})
	testing.expect_value(t, entry, "b.html") // manifest wins over the index.html default

	_, err = html_bundle_resolve_entry("", "", []string{"a.html", "b.html"})
	hb_expect_error(t, err, "choose one with --entry")
	hb_expect_error(t, err, "a.html, b.html")
	_, err = html_bundle_resolve_entry("a.html", "b.html", []string{"a.html", "b.html"})
	hb_expect_error(t, err, "conflicts with heimdall-artifact.json")
	_, err = html_bundle_resolve_entry("", "style.css", []string{"style.css", "index.html"})
	hb_expect_error(t, err, "is not an HTML file")
	_, err = html_bundle_resolve_entry("", "index.html", []string{"Index.html"})
	hb_expect_error(t, err, "case-sensitive")
	_, err = html_bundle_resolve_entry("missing.html", "", []string{"index.html"})
	hb_expect_error(t, err, "does not exist")
	_, err = html_bundle_resolve_entry("", "", []string{"style.css"})
	hb_expect_error(t, err, "no HTML file")
}

@(test)
test_html_bundle_directory_manifest_and_entry_flag :: proc(t: ^testing.T) {
	root := hb_tmp_root(t, "manifest")
	defer os.remove_all(root)
	hb_write(t, root, "a.html", "a")
	hb_write(t, root, "b.html", "b")
	_, err := html_bundle_from_directory(root, "", context.temp_allocator)
	hb_expect_error(t, err, "choose one with --entry")
	result, ok_err := html_bundle_from_directory(root, "b.html", context.temp_allocator)
	testing.expect_value(t, ok_err, "")
	testing.expect_value(t, result.entry, "b.html")

	hb_write(t, root, HTML_BUNDLE_MANIFEST, `{"format_version":1,"entrypoint":"a.html"}`)
	_, err = html_bundle_from_directory(root, "b.html", context.temp_allocator)
	hb_expect_error(t, err, "conflicts")
	result, ok_err = html_bundle_from_directory(root, "", context.temp_allocator)
	testing.expect_value(t, ok_err, "")
	testing.expect_value(t, result.entry, "a.html")
	testing.expect_value(t, result.files, 2) // the manifest is regenerated, not packed twice

	hb_write(t, root, HTML_BUNDLE_MANIFEST, `{"format_version":2,"entrypoint":"a.html"}`)
	_, err = html_bundle_from_directory(root, "", context.temp_allocator)
	hb_expect_error(t, err, "format_version 2 is not supported")

	_, err = html_bundle_from_directory(fmt.tprintf("%s/a.html", root), "", context.temp_allocator)
	hb_expect_error(t, err, "is not a directory")
}

@(test)
test_html_bundle_manifest_is_strict :: proc(t: ^testing.T) {
	entry, err := html_bundle_parse_manifest(transmute([]byte)string(` { "entrypoint" : "x/y.html", "format_version" : 1 } `))
	testing.expect_value(t, err, ""); testing.expect_value(t, entry, "x/y.html")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`{"format_version":1,"entrypoint":"a.html"} {}`))
	hb_expect_error(t, err, "single JSON object")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`{"format_version":1,"entrypoint":"a.html","title":"x"}`))
	hb_expect_error(t, err, "unsupported field")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`{"format_version":"1","entrypoint":"a.html"}`))
	hb_expect_error(t, err, "integer format_version")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`{"format_version":1}`))
	hb_expect_error(t, err, "string entrypoint")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`{"format_version":1,"entrypoint":"a.html","entrypoint":"b.html"}`))
	hb_expect_error(t, err, "single JSON object")
	_, err = html_bundle_parse_manifest(transmute([]byte)string(`[1]`))
	hb_expect_error(t, err, "single JSON object")
}

@(test)
test_html_bundle_prepared_zip_gets_manifest_without_touching_members :: proc(t: ^testing.T) {
	deflated, _ := hex.decode(transmute([]byte)string(HB_DEFLATE_100K_A_HEX), context.temp_allocator)
	original := hb_test_zip([]Hb_Test_Entry{
		hb_entry("index.html", "<p>home</p>"),
		hb_entry("docs/", ""),
		{name = "docs/big.txt", data = deflated, method = 8, declared_size = 100000, crc = HB_DEFLATE_100K_A_CRC},
	})
	result, err := html_bundle_from_zip(original, "", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, result.entry, "index.html")
	archive, parse_err := html_bundle_parse_zip(original)
	testing.expect_value(t, parse_err, "")
	testing.expect(t, slice.equal(result.zip[:archive.cd_offset], original[:archive.cd_offset]), "existing local records are copied byte-for-byte")
	completed, completed_err := html_bundle_parse_zip(result.zip)
	testing.expect_value(t, completed_err, "")
	testing.expect(t, slice.equal(hb_member_paths(completed), []string{"index.html", "docs/", "docs/big.txt", HTML_BUNDLE_MANIFEST}), "manifest appended after the original members")
	big, big_err := html_bundle_read_member(&completed, completed.members[2], context.temp_allocator)
	testing.expect_value(t, big_err, "")
	testing.expect_value(t, len(big), 100000)

	// With --entry the generated manifest records it.
	with_entry := hb_test_zip([]Hb_Test_Entry{hb_entry("a.html", "a"), hb_entry("b.html", "b")})
	_, err = html_bundle_from_zip(with_entry, "", context.temp_allocator)
	hb_expect_error(t, err, "choose one with --entry")
	chosen, chosen_err := html_bundle_from_zip(with_entry, "b.html", context.temp_allocator)
	testing.expect_value(t, chosen_err, "")
	reparsed, _ := html_bundle_parse_zip(chosen.zip)
	manifest, _ := html_bundle_read_member(&reparsed, reparsed.members[2], context.temp_allocator)
	testing.expect_value(t, string(manifest), `{"format_version":1,"entrypoint":"b.html"}` + "\n")

	// An archive that already has a manifest is returned unchanged; a conflicting --entry fails.
	complete := hb_test_zip([]Hb_Test_Entry{hb_entry(HTML_BUNDLE_MANIFEST, HB_MANIFEST_INDEX), hb_entry("index.html", "x"), hb_entry("other.html", "y")})
	same, same_err := html_bundle_from_zip(complete, "index.html", context.temp_allocator)
	testing.expect_value(t, same_err, "")
	testing.expect(t, slice.equal(same.zip, complete), "byte-identical when the manifest exists")
	_, err = html_bundle_from_zip(complete, "other.html", context.temp_allocator)
	hb_expect_error(t, err, "conflicts")
	missing := hb_test_zip([]Hb_Test_Entry{hb_entry(HTML_BUNDLE_MANIFEST, `{"format_version":1,"entrypoint":"gone.html"}`), hb_entry("index.html", "x")})
	_, err = html_bundle_from_zip(missing, "", context.temp_allocator)
	hb_expect_error(t, err, "does not exist")
}

@(test)
test_html_bundle_rejects_unsafe_archives :: proc(t: ^testing.T) {
	ok := hb_entry("index.html", "x")
	check :: proc(t: ^testing.T, entries: []Hb_Test_Entry, needle: string, loc := #caller_location) {
		_, err := html_bundle_from_zip(hb_test_zip(entries), "", context.temp_allocator)
		hb_expect_error(t, err, needle, loc)
	}
	check(t, {ok, hb_entry("../evil.html", "x")}, "path traversal")
	check(t, {ok, hb_entry("a/../../evil.css", "x")}, "path traversal")
	check(t, {ok, hb_entry("/etc/passwd", "x")}, "absolute member path")
	check(t, {ok, hb_entry("C:/x.css", "x")}, "drive-qualified")
	check(t, {ok, hb_entry("a\\b.css", "x")}, "backslash")
	check(t, {ok, hb_entry("a//b.css", "x")}, "empty segment")
	check(t, {ok, hb_entry("./a.css", "x")}, "path traversal")
	check(t, {ok, hb_entry("a\x01.css", "x")}, "control character")
	check(t, {ok, hb_entry("caf\xc3\xa9.css", "x")}, "not ASCII and not flagged UTF-8")
	check(t, {ok, hb_entry("index.html", "y")}, "duplicate member path")
	check(t, {ok, hb_entry("a", "x"), hb_entry("a/b.css", "y")}, "both a file and a directory")
	check(t, {ok, hb_entry("site.zip", "x")}, "nested archive")
	check(t, {ok, hb_entry("blob.bin", "PK\x03\x04rest")}, "nested archive")
	check(t, {ok, {name = "s.css", data = transmute([]byte)string("x"), declared_size = -1, flags = ZIP_FLAG_ENCRYPTED}}, "encrypted")
	check(t, {ok, {name = "s.css", data = transmute([]byte)string("x"), declared_size = -1, method = 12}}, "unsupported compression method 12")
	check(t, {ok, {name = "link.css", data = transmute([]byte)string("/etc/passwd"), declared_size = -1, made_by = 3 << 8, external = u32(0o120777) << 16}}, "symbolic link")
	check(t, {ok, {name = "s.css", data = transmute([]byte)string("abc"), declared_size = -1, crc = 0x12345678}}, "CRC-32")
	check(t, {ok, {name = "s.css", data = transmute([]byte)string("abc"), declared_size = 2}}, "mismatched sizes")
	check(t, {ok, {name = "big.css", data = transmute([]byte)string("x"), method = 8, declared_size = HTML_BUNDLE_MAX_MEMBER + 1}}, "per-member limit")

	// Actual expansion is checked, not just the declaration: 115 bytes that inflate to
	// 100000 while claiming 1000 are rejected.
	deflated, _ := hex.decode(transmute([]byte)string(HB_DEFLATE_100K_A_HEX), context.temp_allocator)
	check(t, {ok, {name = "bomb.txt", data = deflated, method = 8, declared_size = 1000, crc = HB_DEFLATE_100K_A_CRC}}, "expands to 100000 bytes but declares 1000")
	check(t, {ok, {name = "corrupt.txt", data = transmute([]byte)string("\xff\xff\xff"), method = 8, declared_size = 10}}, "could not be inflated")

	// Declared expansion past 50 MiB fails before any member is read.
	many := make([dynamic]Hb_Test_Entry, context.temp_allocator)
	append(&many, ok)
	for i in 0 ..< 6 do append(&many, Hb_Test_Entry{name = fmt.tprintf("f%d.bin", i), data = transmute([]byte)string("x"), method = 8, declared_size = HTML_BUNDLE_MAX_MEMBER})
	check(t, many[:], "expands past")

	entries := make([dynamic]Hb_Test_Entry, context.temp_allocator)
	for i in 0 ..< HTML_BUNDLE_MAX_ENTRIES + 1 do append(&entries, hb_entry(fmt.tprintf("p%d.html", i), "x"))
	check(t, entries[:], "entries; the limit is 1000")

	_, err := html_bundle_from_zip(transmute([]byte)string("<html>not a zip</html>"), "", context.temp_allocator)
	hb_expect_error(t, err, "not a ZIP archive")
	big := make([]byte, HTML_BUNDLE_MAX_ARCHIVE + 1, context.temp_allocator)
	_, err = html_bundle_from_zip(big, "", context.temp_allocator)
	hb_expect_error(t, err, "the limit is")
}

@(test)
test_html_bundle_cli_args :: proc(t: ^testing.T) {
	_, err := html_bundle_package_from_args([]string{"--kind", "html-bundle"})
	hb_expect_error(t, err, "needs --directory")
	_, err = html_bundle_package_from_args([]string{"--directory", "/tmp", "--file", "/tmp/x.zip"})
	hb_expect_error(t, err, "not both")
	_, err = html_bundle_package_from_args([]string{"--directory", "/tmp", "--content", "<p>"})
	hb_expect_error(t, err, "not --content/--stdin")
	_, err = html_bundle_package_from_args([]string{"--file", "/nonexistent/bundle.zip"})
	hb_expect_error(t, err, "cannot read --file")
}

@(test)
test_html_bundle_flags_rejected_for_other_kinds :: proc(t: ^testing.T) {
	hb_expect_error(t, html_bundle_flags_error([]string{"--kind", "file", "--directory", "./site"}, "file"), "--directory is only valid with --kind html-bundle")
	hb_expect_error(t, html_bundle_flags_error([]string{"--entry", "a.html"}, "markdown"), "--entry is only valid with --kind html-bundle")
	testing.expect_value(t, html_bundle_flags_error([]string{"--directory", "./site", "--entry", "a.html"}, HTML_BUNDLE_KIND), "")
	testing.expect_value(t, html_bundle_flags_error([]string{"--file", "x.zip"}, "file"), "")
}

@(test)
test_html_bundle_create_params_seal_the_archive_bytes :: proc(t: ^testing.T) {
	root := hb_tmp_root(t, "create")
	defer os.remove_all(root)
	hb_write(t, root, "index.html", "<h1>hi</h1>")
	expected, pack_err := html_bundle_from_directory(root, "", context.temp_allocator)
	testing.expect_value(t, pack_err, "")

	out := ctl_agentmode_artifact_create_params([]string{
		"--name", "site", "--kind", "html-bundle", "--directory", root,
		"--vault-keyring", tkr_b64(TEST_ARTIFACT_VAULT_KEY),
	})
	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)
	testing.expect_value(t, string(obj["kind"].(json.String)), HTML_BUNDLE_KIND)
	testing.expect_value(t, string(obj["content_type"].(json.String)), HTML_BUNDLE_CONTENT_TYPE)
	armored, _ := base64.decode(string(obj["content_base64"].(json.String)), allocator = context.temp_allocator)
	plain, res := ctl_vault_open(string(armored), tkr(TEST_ARTIFACT_VAULT_KEY), context.temp_allocator)
	testing.expect(t, res == .Ok, "archive must be sealed")
	testing.expect(t, plain == string(expected.zip), "sealed payload is exactly the packed archive")
}
