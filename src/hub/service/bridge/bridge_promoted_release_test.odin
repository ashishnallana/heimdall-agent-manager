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

// catalog_test_resolve refreshes a fresh snapshot from the fake source, then
// resolves, so a test can change the source between steps and see the result.
catalog_test_resolve :: proc(cat: ^Bridge_Update_Catalog, bridge: domain.Bridge) -> Bridge_Update_Info {
	bridge_update_catalog_destroy(cat)
	_, _ = bridge_catalog_refresh(cat)
	return resolve_bridge_update_info(cat, bridge)
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {version = "1.0.0", machine_os = "linux", machine_arch = "amd64"})
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_source, "override")
	testing.expect_value(t, info.latest_version, "1.5.0")
	testing.expect(t, strings.contains(info.warning, "older than promoted release 2.0.0"))
	testing.expect(t, strings.contains(info.download_url, "/v1.5.0/"))
	testing.expect_value(t, info.latest_commit_sha, "")
	cat.override_download_url, cat.override_sha256 = "/operator-v1.5.tar.gz", "operator-sha"
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.download_url, "/operator-v1.5.tar.gz")
	testing.expect_value(t, info.sha256, "operator-sha")
	// During an outage a different-version manifest must never fill a pin's URL.
	source.fail = true
	cat.override_download_url, cat.override_sha256 = "", ""
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect_value(t, info.latest_version, "1.0.0")
	testing.expect_value(t, info.download_url, "/manifest-v1.tar.gz")
	testing.expect(t, strings.contains(info.fallback_reason, "connection timed out"))
	testing.expect(t, info.artifact_available)
	source.fail = false
	source.doc = "not JSON"
	info = catalog_test_resolve(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect(t, strings.contains(info.fallback_reason, "invalid release list"))
	source.doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64"))
	source.fail_sums = true
	info = catalog_test_resolve(&cat, {version = "0.9.0"})
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {machine_os = "termux", machine_arch = "arm64"})
	testing.expect_value(t, info.latest_source, "promoted")
	testing.expect_value(t, info.latest_version, "")
	testing.expect(t, !info.artifact_available)
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect(t, info.artifact_available, "binary marker and CRLF accepted")
	source.sums = fmt.tprintf("%s%s", source.sums, source.sums)
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect(t, !info.artifact_available, "duplicate checksum fails closed")
	source.sums = "not-a-hash  heimdall-local-linux-amd64-v2.0.0.tar.gz"
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect(t, !info.artifact_available, "malformed checksum fails closed")
	// A newer release with an unlisted bundle cannot displace an older verified one.
	source.doc = fmt.tprintf("[%s,%s]", catalog_test_release("v3.0.0", "linux-amd64"), catalog_test_release("v2.0.0", "linux-amd64"))
	source.sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA)
	info = catalog_test_resolve(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_version, "2.0.0")
	testing.expect(t, info.artifact_available)
}

@(test)
test_catalog_request_path_reads_snapshot_only :: proc(t: ^testing.T) {
	path := catalog_test_manifest(t)
	defer os.remove(path)
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "windows-amd64")),
		pin_doc = catalog_test_release("v1.5.0", "windows-amd64"),
		sums = fmt.tprintf("%s  heimdall-local-windows-amd64-v2.0.0.zip\n%s  heimdall-local-windows-amd64-v1.5.0.zip\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{manifest_path = path, release_get = catalog_test_get}
	defer bridge_update_catalog_destroy(&cat)
	br := domain.Bridge{version = "1.0.0", machine_os = "windows", machine_arch = "amd64"}
	// Before the first refresh: manifest fallback, no fetch, no wait.
	cold := resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, source.calls, 0)
	testing.expect_value(t, cold.latest_source, "manifest")
	testing.expect_value(t, cold.latest_version, "1.0.0")
	testing.expect(t, strings.contains(cold.fallback_reason, "not been loaded yet"))
	reachable, total := bridge_catalog_refresh(&cat)
	testing.expect_value(t, reachable, 7)
	testing.expect_value(t, total, 7)
	// Seven targets share one release list and one SHA256SUMS fetch.
	testing.expect_value(t, source.calls, 2)
	for _ in 0..<5 {
		info := resolve_bridge_update_info(&cat, br)
		testing.expect_value(t, info.latest_version, "2.0.0")
		testing.expect(t, strings.has_suffix(info.download_url, ".zip"))
		_ = resolve_bridge_update_info(&cat, {version = "1.0.0", machine_os = "termux", machine_arch = "arm64"})
	}
	// Unknown targets and an unrefreshed pin are misses, never fetches.
	unknown := resolve_bridge_update_info(&cat, {version = "1.0.0", machine_os = "plan9", machine_arch = "amd64"})
	testing.expect(t, strings.contains(unknown.fallback_reason, "plan9-amd64"))
	cat.override_version = "1.5.0"
	pinned := resolve_bridge_update_info(&cat, br)
	testing.expect_value(t, pinned.latest_source, "override")
	testing.expect(t, !pinned.artifact_available)
	testing.expect_value(t, source.calls, 2)
	// The next refresh picks the pin up; serving it still fetches nothing.
	_, _ = bridge_catalog_refresh(&cat)
	calls := source.calls
	pinned = resolve_bridge_update_info(&cat, br)
	testing.expect_value(t, pinned.latest_version, "1.5.0")
	testing.expect(t, pinned.artifact_available && strings.contains(pinned.download_url, "/v1.5.0/"))
	testing.expect_value(t, source.calls, calls)
}

@(test)
test_catalog_refresh_updates_and_failure_keeps_last_good :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n%s  heimdall-local-linux-amd64-v2.1.0.tar.gz\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get}
	defer bridge_update_catalog_destroy(&cat)
	_, _ = bridge_catalog_refresh(&cat)
	testing.expect_value(t, resolve_bridge_update_info(&cat, {version = "1.0.0"}).latest_version, "2.0.0")
	source.doc = fmt.tprintf("[%s,%s]", catalog_test_release("v2.1.0", "linux-amd64"), catalog_test_release("v2.0.0", "linux-amd64"))
	_, _ = bridge_catalog_refresh(&cat)
	testing.expect_value(t, resolve_bridge_update_info(&cat, {version = "1.0.0"}).latest_version, "2.1.0")
	// An outage, then a bad document: both keep serving the last good promotion.
	source.fail = true
	reachable, total := bridge_catalog_refresh(&cat)
	testing.expect_value(t, reachable, 0)
	testing.expect_value(t, total, 7)
	info := resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_version, "2.1.0")
	testing.expect_value(t, info.latest_source, "promoted")
	testing.expect_value(t, info.fallback_reason, "")
	testing.expect(t, info.artifact_available && info.update_available)
	source.fail = false
	source.doc = "not JSON"
	_, _ = bridge_catalog_refresh(&cat)
	testing.expect_value(t, resolve_bridge_update_info(&cat, {version = "1.0.0"}).latest_version, "2.1.0")
}

@(test)
test_catalog_failed_first_refresh_reports_reason_then_recovers :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{fail = true,
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get}
	defer bridge_update_catalog_destroy(&cat)
	_, _ = bridge_catalog_refresh(&cat)
	info := resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_source, "manifest")
	testing.expect(t, strings.contains(info.fallback_reason, "connection timed out"))
	source.fail = false
	_, _ = bridge_catalog_refresh(&cat)
	info = resolve_bridge_update_info(&cat, {version = "1.0.0"})
	testing.expect_value(t, info.latest_source, "promoted")
	testing.expect_value(t, info.latest_version, "2.0.0")
}

@(test)
test_catalog_refresher_thread_refreshes_and_stops :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s]", catalog_test_release("v2.0.0", "linux-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v2.0.0.tar.gz\n", CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get, refresh_interval = 10 * time.Millisecond}
	defer bridge_update_catalog_destroy(&cat)
	bridge_catalog_refresher_start(&cat)
	loaded := false
	for _ in 0..<200 {
		if _, ok := bridge_catalog_release(&cat, "linux-amd64", ""); ok {
			loaded = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, loaded, "startup refresh fills the snapshot")
	time.sleep(100 * time.Millisecond)
	stop_started := time.tick_now()
	bridge_catalog_refresher_stop(&cat)
	testing.expect(t, cat.refresher == nil)
	testing.expect(t, time.tick_since(stop_started) < time.Second, "stop wakes the interval wait")
	// Read only after join: the fake source is not synchronized.
	testing.expect(t, source.calls >= 4, "the interval refresh runs again")
	calls := source.calls
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, source.calls, calls)
	// The default interval is the documented 30 minutes.
	testing.expect_value(t, BRIDGE_CATALOG_REFRESH_INTERVAL, 30 * time.Minute)
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {version = "0.9.0"})
	testing.expect_value(t, info.latest_source, "override")
	testing.expect_value(t, info.latest_version, "v1.0.0")
	testing.expect_value(t, info.latest_commit_sha, "manifest-commit")
	testing.expect_value(t, info.download_url, "/manifest-v1.tar.gz")
	testing.expect_value(t, info.sha256, "manifest-sha")
	testing.expect(t, info.artifact_available && info.update_available)
	testing.expect(t, strings.contains(info.warning, "older than promoted release 2.0.0"))
	calls := source.calls
	_ = resolve_bridge_update_info(&cat, {version = "0.9.0"})
	testing.expect_value(t, source.calls, calls)
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {})
	testing.expect(t, !info.artifact_available)
	testing.expect(t, strings.contains(info.fallback_reason, "HTTP 404"))
	testing.expect(t, strings.contains(info.warning, "older than promoted"))
	source.fail_pin = false
	info = catalog_test_resolve(&cat, {})
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {})
	testing.expect(t, info.artifact_available)
	testing.expect_value(t, info.latest_source, "override")
	testing.expect(t, strings.contains(info.download_url, "/v1.5.0/"))
	source.pin_doc = catalog_test_release("v1.5.0", "linux-amd64", draft = true)
	info = catalog_test_resolve(&cat, {})
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
	defer bridge_update_catalog_destroy(&cat)
	info := catalog_test_resolve(&cat, {version = "0.9.0", machine_os = "linux", machine_arch = "arm64"})
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
