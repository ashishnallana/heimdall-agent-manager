#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// Lives in its own file because it needs posix.symlink, which Windows does not have
// (Odin type-checks _test files in `odin build` too, so this broke the Windows build).

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
