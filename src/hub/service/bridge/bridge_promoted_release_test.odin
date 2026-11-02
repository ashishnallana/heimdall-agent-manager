package bridge

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import httpc "odin_test:lib/httpc"

CATALOG_TEST_SHA :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
Catalog_Test_Source :: struct {
	doc, sums, pin_doc: string,
	fail, fail_sums, fail_pin: bool,
	calls: int,
}

catalog_test_get :: proc(req: httpc.Request) -> (string, bool, string) {
	source := cast(^Catalog_Test_Source)context.user_ptr
	source.calls += 1
	if source.fail do return "", false, "connection timed out"
	if req.path[len(req.path)-1] == "SHA256SUMS" {
		if source.fail_sums do return "", false, "HTTP 503"
		return source.sums, true, ""
	}
	if len(req.path) == 6 && req.path[4] == "tags" {
		if source.fail_pin do return "", false, "HTTP 404"
		return source.pin_doc, true, ""
	}
	return source.doc, true, ""
}

catalog_test_release :: proc(tag, target: string, pre := false, draft := false) -> string {
	release := Bridge_Catalog_Release{tag_name = tag, prerelease = pre, draft = draft,
		assets = {{name = "SHA256SUMS"}, {name = bridge_catalog_bundle(target, tag)}}}
	doc, _ := json.marshal(release, allocator = context.temp_allocator)
	return string(doc)
}

catalog_test_manifest :: proc(t: ^testing.T) -> string {
	path := fmt.tprintf("/tmp/promoted_catalog_%d_%d.json", os.get_pid(), time.now()._nsec)
	doc := `{"version":"1.0.0","commit_sha":"manifest-commit","targets":{"linux-amd64":{"tarball_url":"/manifest-v1.tar.gz","sha256":"manifest-sha"}}}`
	testing.expect(t, os.write_entire_file(path, transmute([]byte)doc) == nil)
	return path
}

@(test)
test_catalog_promoted_beats_manifest_ignores_prerelease_and_draft :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s,%s,%s]", catalog_test_release("v3.0.0", "linux-amd64", pre = true),
			catalog_test_release("v2.5.0", "linux-amd64", draft = true), catalog_test_release("v2.0.0", "linux-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get}
	info := resolve_bridge_update_info(&cat, {version = "1.0.0", machine_os = "linux", machine_arch = "amd64"})
	testing.expect_value(t, info.latest_version, "2.0.0")
	testing.expect_value(t, info.latest_source, "promoted")
	testing.expect_value(t, info.latest_commit_sha, "")
	testing.expect_value(t, info.download_url, "https://github.com/tanmayv/heimdall-agent-manager/releases/download/v2.0.0/heimdall-local-linux-amd64-v2.0.0.tar.gz")
	testing.expect_value(t, info.sha256, CATALOG_TEST_SHA)
	testing.expect(t, info.update_available && info.artifact_available)
	testing.expect_value(t, info.fallback_reason, "")
}

@(test)
test_catalog_override_pin_warns_and_never_mixes_manifest_artifact :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		pin_doc = catalog_test_release("v1.5.0", "linux-amd64"),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n%s  heimdall-local-linux-amd64-v1.5.0.tar.gz\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get, override_version = "1.5.0"}
	info := resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_source, "override")
	testing.expect_value(t, info.latest_version, "1.5.0")
	testing.expect(t, strings.contains(info.warning, "older than promoted release 2.0.0"))
	testing.expect(t, strings.contains(info.download_url, "/v1.5.0/"))
	testing.expect_value(t, info.latest_commit_sha, "")
	cat.override_download_url, cat.override_sha256 = "/operator-v1.5.tar.gz", "operator-sha"
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.download_url, "/operator-v1.5.tar.gz")
	testing.expect_value(t, info.sha256, "operator-sha")
	// During an outage a different-version manifest must never fill a pin's URL.
	source.fail = true
	cat.override_download_url, cat.override_sha256 = "", ""
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_version, "1.5.0")
	testing.expect(t, !info.artifact_available)
	testing.expect_value(t, info.download_url, "")
}

@(test)
test_catalog_unreachable_source_falls_back_with_reason :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{fail = true}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get}
	info := resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect_value(t, info.latest_version, "1.0.0")
	testing.expect_value(t, info.download_url, "/manifest-v1.tar.gz")
	testing.expect(t, strings.contains(info.fallback_reason, "connection timed out"))
	testing.expect(t, info.artifact_available)
	source.fail = false
	source.doc = "not JSON"
	info = resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect(t, strings.contains(info.fallback_reason, "invalid release list"))
	source.doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64"))
	source.fail_sums = true
	info = resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect(t, strings.contains(info.fallback_reason, "cannot fetch SHA256SUMS for v2.0.0: HTTP 503"))
}

@(test)
test_catalog_requires_exact_target_and_unique_sha256sum :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		sums = fmt.tprintf("%s *heimdall-local-linux-amd64-v2.0.0.tar.gz\r\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get}
	info := resolve_bridge_update_info(&cat, {machine_os = "termux", machine_arch = "arm64"})
	testing.expect_value(t, info.latest_source, "promoted")
	testing.expect_value(t, info.latest_version, "")
	testing.expect(t, !info.artifact_available)
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect(t, info.artifact_available, "binary marker and CRLF accepted")
	source.sums = fmt.tprintf("%s%s", source.sums, source.sums)
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect(t, !info.artifact_available, "duplicate checksum fails closed")
	source.sums = "not-a-hash  heimdall-local-linux-amd64-v2.0.0.tar.gz"
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect(t, !info.artifact_available, "malformed checksum fails closed")
	// A newer release with an unlisted bundle cannot displace an older verified one.
	source.doc = fmt.tprintf("[%s,%s]", catalog_test_release("v3.0.0", "linux-amd64"), catalog_test_release("v2.0.0", "linux-amd64"))
	source.sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA)
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_version, "2.0.0")
	testing.expect(t, info.artifact_available)
}

@(test)
test_catalog_cache_refresh_and_windows_asset :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "windows-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-windows-amd64-v2.0.0.zip\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get, cache_enabled = true}
	defer bridge_update_catalog_destroy(&cat)
	br := domain.Bridge{version = "1.0.0", machine_os = "windows", machine_arch = "amd64"}
	first := resolve_bridge_update_info(&cat, br)
	testing.expect(t, strings.has_suffix(first.download_url, ".zip"))
	second := resolve_bridge_update_info(&cat, br)
	testing.expect_value(t, second.latest_version, "2.0.0")
	testing.expect_value(t, source.calls, 2)
	// Expiry also caches failures briefly; an outage must fall back, not serve stale promotion metadata.
	cat.cache[10].at = {}
	source.fail = true
	third := resolve_bridge_update_info(&cat, br)
	testing.expect_value(t, third.latest_source, "manifest")
	testing.expect_value(t, source.calls, 3)
	_ = resolve_bridge_update_info(&cat, br)
	testing.expect_value(t, source.calls, 3)
	testing.expect_value(t, first.latest_version, "2.0.0")
}

@(test)
test_catalog_pin_preserves_matching_manifest_artifact :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		pin_doc = catalog_test_release("v1.0.0", "linux-amd64", pre = true),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get, override_version = "v1.0.0"}
	info := resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "override")
	testing.expect_value(t, info.latest_version, "v1.0.0")
	testing.expect_value(t, info.latest_commit_sha, "manifest-commit")
	testing.expect_value(t, info.download_url, "/manifest-v1.tar.gz")
	testing.expect_value(t, info.sha256, "manifest-sha")
	testing.expect(t, info.artifact_available && info.update_available)
	testing.expect(t, strings.contains(info.warning, "older than promoted release 2.0.0"))
	testing.expect(t, source.calls == 2, "matching manifest pin does not require a tag lookup")
}

@(test)
test_catalog_pin_lookup_failure_explained_alongside_age_warning :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		pin_doc = catalog_test_release("v1.5.0", "linux-amd64"),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA),
		fail_pin = true,
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get, override_version = "1.5.0"}
	info := resolve_bridge_update_info(&cat, {})
	testing.expect(t, !info.artifact_available)
	testing.expect(t, strings.contains(info.fallback_reason, "HTTP 404"))
	testing.expect(t, strings.contains(info.warning, "older than promoted"))
	source.fail_pin = false
	info = resolve_bridge_update_info(&cat, {})
	testing.expect(t, !info.artifact_available)
	testing.expect(t, strings.contains(info.warning, "Pinned release 1.5.0 has no verified artifact for linux-amd64"))
	testing.expect(t, strings.contains(info.warning, "older than promoted"))
}

@(test)
test_catalog_explicit_prerelease_pin_requires_verified_artifact :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		pin_doc = catalog_test_release("v1.5.0", "linux-amd64", pre = true),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n%s  heimdall-local-linux-amd64-v1.5.0.tar.gz\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get, override_version = "1.5.0"}
	info := resolve_bridge_update_info(&cat, {})
	testing.expect(t, info.artifact_available)
	testing.expect_value(t, info.latest_source, "override")
	testing.expect(t, strings.contains(info.download_url, "/v1.5.0/"))
	source.pin_doc = catalog_test_release("v1.5.0", "linux-amd64", draft = true)
	info = resolve_bridge_update_info(&cat, {})
	testing.expect(t, !info.artifact_available, "explicit pins still reject drafts")
}

@(test)
test_catalog_matching_manifest_pin_fetches_missing_target :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-arm64")),
		pin_doc = catalog_test_release("v1.0.0", "linux-arm64"),
		sums = fmt.tprintf("%s  heimdall-local-linux-arm64-v2.0.0.tar.gz\n%s  heimdall-local-linux-arm64-v1.0.0.tar.gz\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get, override_version = "v1.0.0"}
	info := resolve_bridge_update_info(&cat, {version = "0.9.0", machine_os = "linux", machine_arch = "arm64"})
	testing.expect_value(t, info.latest_source, "override")
	testing.expect_value(t, info.latest_version, "v1.0.0")
	testing.expect_value(t, info.target, "linux-arm64")
	testing.expect_value(t, info.latest_commit_sha, "")
	testing.expect_value(t, info.download_url, "https://github.com/tanmayv/heimdall-agent-manager/releases/download/v1.0.0/heimdall-local-linux-arm64-v1.0.0.tar.gz")
	testing.expect_value(t, info.sha256, CATALOG_TEST_SHA)
	testing.expect(t, info.artifact_available && info.update_available)
	testing.expect(t, strings.contains(info.warning, "older than promoted release 2.0.0"))
	testing.expect_value(t, info.fallback_reason, "")
	testing.expect_value(t, source.calls, 4)
}
