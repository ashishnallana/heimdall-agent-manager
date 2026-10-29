package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import httpc "odin_test:lib/httpc"

RELEASE_TEST_LIST :: `[
 {"tag_name":"v0.9.0","draft":false,"prerelease":true,"assets":[{"name":"SHA256SUMS"},{"name":"heimdall-local-linux-amd64-v0.9.0.tar.gz"}]},
 {"tag_name":"v0.8.1","draft":true,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"heimdall-local-linux-amd64-v0.8.1.tar.gz"}]},
 {"tag_name":"v0.8.0","draft":false,"prerelease":false,"assets":[{"name":"heimdall-local-linux-amd64-v0.8.0.tar.gz"}]},
 {"tag_name":"v0.7.0","draft":false,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"heimdall-local-linux-amd64-v0.7.0.tar.gz"},{"name":"heimdall-local-windows-amd64-v0.7.0.zip"}]}
]`

@(test)
test_release_select_latest_promoted :: proc(t: ^testing.T) {
	// Skips the prerelease, the draft and the release without SHA256SUMS.
	tag, err := bridge_release_select(RELEASE_TEST_LIST, "linux-amd64", "latest")
	testing.expect_value(t, err, "")
	testing.expect_value(t, tag, "v0.7.0")
	tag, err = bridge_release_select(RELEASE_TEST_LIST, "windows-amd64", "latest")
	testing.expect_value(t, tag, "v0.7.0")
	_, err = bridge_release_select(RELEASE_TEST_LIST, "darwin-arm64", "latest")
	testing.expect(t, strings.contains(err, "no promoted release"), err)
}

@(test)
test_release_select_explicit :: proc(t: ^testing.T) {
	// An explicit tag may be a prerelease (canary candidate)...
	tag, err := bridge_release_select(RELEASE_TEST_LIST, "linux-amd64", "v0.9.0")
	testing.expect_value(t, err, "")
	testing.expect_value(t, tag, "v0.9.0")
	// ...but never a draft, an unverifiable release or an unknown tag.
	_, err = bridge_release_select(RELEASE_TEST_LIST, "linux-amd64", "v0.8.1")
	testing.expect(t, strings.contains(err, "draft"), err)
	_, err = bridge_release_select(RELEASE_TEST_LIST, "linux-amd64", "v0.8.0")
	testing.expect(t, strings.contains(err, "cannot be verified"), err)
	_, err = bridge_release_select(RELEASE_TEST_LIST, "linux-amd64", "v9.9.9")
	testing.expect(t, strings.contains(err, "not found"), err)
	// The single-object form GitHub returns for /releases/tags/<tag>.
	tag, err = bridge_release_select(`{"tag_name":"v0.7.0","draft":false,"prerelease":false,"assets":[{"name":"SHA256SUMS"},{"name":"heimdall-local-linux-amd64-v0.7.0.tar.gz"}]}`, "linux-amd64", "v0.7.0")
	testing.expect_value(t, tag, "v0.7.0")
	_, err = bridge_release_select(`{"message":"Not Found"`, "linux-amd64", "latest")
	testing.expect(t, err != "", "malformed document must be refused")
	testing.expect(t, !bridge_release_tag_valid("../v1"), "path tags are invalid")
}

@(test)
test_release_expected_sha256 :: proc(t: ^testing.T) {
	a := strings.repeat("a", 64, context.temp_allocator)
	b := strings.repeat("B", 64, context.temp_allocator)
	sums := fmt.tprintf("%s  x.tar.gz\r\n%s *y.zip\n", a, b)
	d, ok := bridge_release_expected_sha256(sums, "x.tar.gz")
	testing.expect(t, ok)
	testing.expect_value(t, d, a)
	d, ok = bridge_release_expected_sha256(sums, "y.zip")
	testing.expect_value(t, d, strings.to_lower(b, context.temp_allocator))
	_, ok = bridge_release_expected_sha256(sums, "z.tar.gz")
	testing.expect(t, !ok, "unlisted file")
	_, ok = bridge_release_expected_sha256(fmt.tprintf("%s  x.tar.gz\n%s  x.tar.gz\n", a, a), "x.tar.gz")
	testing.expect(t, !ok, "duplicate entries are ambiguous")
	_, ok = bridge_release_expected_sha256("zz  x.tar.gz\n", "x.tar.gz")
	testing.expect(t, !ok, "malformed digest")
}

@(test)
test_release_verify_file_mismatch :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/ham-release-verify-%d", "/tmp", os.get_pid())
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/b.tar.gz", dir)
	_ = os.write_entire_file(path, transmute([]byte)string("hello"))
	good := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  b.tar.gz\n"
	ok, detail := bridge_release_verify_file(path, good, "b.tar.gz")
	testing.expect(t, ok, detail)
	bad := fmt.tprintf("%s  b.tar.gz\n", strings.repeat("0", 64, context.temp_allocator))
	ok, detail = bridge_release_verify_file(path, bad, "b.tar.gz")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(detail, "mismatch"), detail)
}

release_test_get :: proc(url: string) -> (string, bool, string) {
	if strings.has_suffix(url, "/SHA256SUMS") {
		return fmt.tprintf("%s  heimdall-local-linux-amd64-v0.7.0.tar.gz\n", strings.repeat("0", 64, context.temp_allocator)), true, ""
	}
	if strings.contains(url, "/releases?") do return RELEASE_TEST_LIST, true, ""
	return "", false, "HTTP 404"
}

release_test_download :: proc(req: httpc.Request, dest: string) -> (int, httpc.Error) {
	_ = os.write_entire_file(dest, transmute([]byte)string("tampered"))
	return 200, .None
}

@(test)
test_release_fetch_refuses_unverified_bundle :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/ham-release-fetch-%d", "/tmp", os.get_pid())
	_ = bridge_make_directory_all(dir)
	defer os.remove_all(dir)
	bundle, tag, err := bridge_release_fetch("latest", "linux-amd64", dir, release_test_get, release_test_download)
	testing.expect_value(t, tag, "v0.7.0")
	testing.expect_value(t, bundle, "")
	testing.expect(t, strings.contains(err, "SHA-256 mismatch"), err)
	testing.expect(t, !os.exists(fmt.tprintf("%s/heimdall-local-linux-amd64-v0.7.0.tar.gz", dir)), "a failed bundle is removed")
	_, _, err = bridge_release_fetch("v9.9.9", "linux-amd64", dir, release_test_get, release_test_download)
	testing.expect(t, strings.contains(err, "cannot list releases"), err)
	_, _, err = bridge_release_fetch("../x", "linux-amd64", dir, release_test_get, release_test_download)
	testing.expect(t, strings.contains(err, "invalid release tag"), err)
}
