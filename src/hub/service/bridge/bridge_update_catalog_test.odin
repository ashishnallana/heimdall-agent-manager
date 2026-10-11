package bridge

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// REQ-P2-CATALOG: Valid manifest parsing with multiple targets via typed wire structs
@(test)
test_bridge_update_catalog_manifest_valid_parsing :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_valid_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"1.5.0","commit_sha":"sha_valid_123","targets":{"linux-amd64":{"tarball_url":"https://example.com/bundles/linux-amd64.tar.gz","sha256":"hash_linux_amd64"},"darwin-arm64":{"tarball_url":"https://example.com/bundles/darwin-arm64.tar.gz","sha256":"hash_darwin_arm64"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}

	// 1. Linux amd64
	br_linux := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "1.4.0",
		commit_sha = "sha_old",
	}
	info_linux := resolve_bridge_update_info(&cat, br_linux)
	testing.expect(t, info_linux.update_available, "update available for older linux bridge")
	testing.expect_value(t, info_linux.latest_version, "1.5.0")
	testing.expect_value(t, info_linux.latest_commit_sha, "sha_valid_123")
	testing.expect_value(t, info_linux.download_url, "https://example.com/bundles/linux-amd64.tar.gz")
	testing.expect_value(t, info_linux.sha256, "hash_linux_amd64")

	// 2. Darwin arm64
	br_darwin := domain.Bridge{
		machine_os = "darwin",
		machine_arch = "arm64",
		version = "1.5.0",
		commit_sha = "sha_valid_123",
	}
	info_darwin := resolve_bridge_update_info(&cat, br_darwin)
	testing.expect(t, !info_darwin.update_available, "darwin bridge already up to date")
	testing.expect_value(t, info_darwin.latest_version, "1.5.0")
	testing.expect_value(t, info_darwin.latest_commit_sha, "sha_valid_123")
	testing.expect_value(t, info_darwin.download_url, "https://example.com/bundles/darwin-arm64.tar.gz")
	testing.expect_value(t, info_darwin.sha256, "hash_darwin_arm64")
}

// REQ-P2-CATALOG: Manifest JSON key reordering and formatting resilience
@(test)
test_bridge_update_catalog_manifest_key_reordering :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_reorder_%d_%d.json", os.get_pid(), time.now()._nsec)
	// Keys reversed: targets first, then commit_sha, then version. Inside target: sha256 before tarball_url.
	manifest_content := `
	{
		"targets": {
			"linux-amd64": {
				"sha256": "hash_reordered",
				"tarball_url": "/custom/path/bundle.tar.gz"
			}
		},
		"commit_sha": "reordered_commit_999",
		"version": "2.0.0"
	}
	`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest with reordered keys")
	defer os.remove(manifest_path)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "1.9.9",
	}
	info := resolve_bridge_update_info(&cat, br)
	testing.expect(t, info.update_available, "update available from reordered JSON")
	testing.expect_value(t, info.latest_version, "2.0.0")
	testing.expect_value(t, info.latest_commit_sha, "reordered_commit_999")
	testing.expect_value(t, info.download_url, "/custom/path/bundle.tar.gz")
	testing.expect_value(t, info.sha256, "hash_reordered")
}

// REQ-P2-CATALOG: Missing target handling fails closed without inventing a route
@(test)
test_bridge_update_catalog_missing_target_fallback :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_missing_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"1.8.0","commit_sha":"sha_missing_target","targets":{"darwin-arm64":{"tarball_url":"/darwin.tar.gz","sha256":"sha_darwin"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}
	// Requesting linux-amd64 which is NOT in targets
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "1.0.0",
	}
	info := resolve_bridge_update_info(&cat, br)
	testing.expect(t, info.update_available, "update available")
	testing.expect_value(t, info.latest_version, "1.8.0")
	testing.expect_value(t, info.latest_commit_sha, "sha_missing_target")
	// A catalog miss must remain empty. send_bridge_update rejects it before a
	// command reaches the Bridge, instead of dispatching a guaranteed 404.
	testing.expect_value(t, info.download_url, "")
	testing.expect_value(t, info.sha256, "")
}

// REQ-P2-CATALOG: Target architecture and OS normalization
@(test)
test_bridge_update_catalog_target_normalization :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_norm_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"1.2.0","commit_sha":"sha_norm","targets":{"linux-amd64":{"tarball_url":"/url-linux-amd64","sha256":"sha-amd64"},"darwin-arm64":{"tarball_url":"/url-darwin-arm64","sha256":"sha-arm64"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}

	// Machine reporting "Linux" and "x86_64" -> normalizes to linux-amd64
	br_x86 := domain.Bridge{
		machine_os = "Linux",
		machine_arch = "x86_64",
		version = "1.0.0",
	}
	info_x86 := resolve_bridge_update_info(&cat, br_x86)
	testing.expect_value(t, info_x86.download_url, "/url-linux-amd64")
	testing.expect_value(t, info_x86.sha256, "sha-amd64")

	// Machine reporting "Darwin" and "aarch64" -> normalizes to darwin-arm64
	br_arm := domain.Bridge{
		machine_os = "Darwin",
		machine_arch = "aarch64",
		version = "1.0.0",
	}
	info_arm := resolve_bridge_update_info(&cat, br_arm)
	testing.expect_value(t, info_arm.download_url, "/url-darwin-arm64")
	testing.expect_value(t, info_arm.sha256, "sha-arm64")
}

// REQ-P2-CATALOG: Catalog overrides take precedence over manifest file
@(test)
test_bridge_update_catalog_overrides_precedence :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_override_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"1.0.0","commit_sha":"sha_manifest","targets":{"linux-amd64":{"tarball_url":"/manifest_url","sha256":"manifest_sha"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
		override_version = "9.9.9",
		override_commit_sha = "sha_override",
		override_download_url = "/override_url",
		override_sha256 = "override_sha",
	}
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "1.0.0",
	}
	info := resolve_bridge_update_info(&cat, br)
	testing.expect(t, info.update_available, "override version triggers update")
	testing.expect_value(t, info.latest_version, "9.9.9")
	testing.expect_value(t, info.latest_commit_sha, "sha_override")
	testing.expect_value(t, info.download_url, "/override_url")
	testing.expect_value(t, info.sha256, "override_sha")
}

// REQ-P2-CATALOG: Semver comparisons and update availability semantics
@(test)
test_bridge_update_catalog_semver_comparisons :: proc(t: ^testing.T) {
	// compare_semver checks
	testing.expect_value(t, compare_semver("0.1.0", "0.2.0"), -1)
	testing.expect_value(t, compare_semver("0.2.0", "0.1.0"), 1)
	testing.expect_value(t, compare_semver("0.2.0", "0.2.0"), 0)
	testing.expect_value(t, compare_semver("v1.0.0", "1.0.0"), 0)
	testing.expect_value(t, compare_semver("1.0.0", "V1.0.0"), 0)
	testing.expect_value(t, compare_semver("0.1.9", "0.2.0"), -1)
	testing.expect_value(t, compare_semver("1.10.0", "1.9.0"), 1)
	testing.expect_value(t, compare_semver("2.0.0", "1.99.99"), 1)

	// is_bridge_update_available checks
	testing.expect(t, is_bridge_update_available("0.1.0", "c1", "0.2.0", "c2"), "older semver must report update available")
	testing.expect(t, !is_bridge_update_available("0.2.0", "c1", "0.2.0", "c1"), "identical version and commit must not report update available")
	testing.expect(t, is_bridge_update_available("0.2.0", "c1", "0.2.0", "c2"), "different commit with same version must report update available")
	testing.expect(t, is_bridge_update_available("", "", "0.2.0", "c2"), "empty bridge version must report update available")
	testing.expect(t, !is_bridge_update_available("0.3.0", "c1", "0.2.0", "c2"), "newer bridge semver must not report update available")
	testing.expect(t, !is_bridge_update_available("0.1.0", "c1", "", "c2"), "empty latest version must report no update")
}

// REQ-P2-CATALOG: Tracking allocator asserts zero heap memory leaks and zero bad frees
@(test)
test_bridge_update_catalog_tracking_allocator_clean :: proc(t: ^testing.T) {
	manifest_path := fmt.tprintf("/tmp/test_catalog_track_%d_%d.json", os.get_pid(), time.now()._nsec)
	manifest_content := `{"version":"2.5.0","commit_sha":"sha_tracking_test","targets":{"linux-amd64":{"tarball_url":"/bundle.tar.gz","sha256":"hash_track"}}}`
	write_err := os.write_entire_file(manifest_path, transmute([]byte)manifest_content)
	testing.expect(t, write_err == nil, "wrote test manifest")
	defer os.remove(manifest_path)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	cat := Bridge_Update_Catalog{
		manifest_path = manifest_path,
	}
	br := domain.Bridge{
		machine_os = "linux",
		machine_arch = "amd64",
		version = "1.0.0",
		commit_sha = "c_old",
	}

	for _ in 0..<10 {
		info := resolve_bridge_update_info(&cat, br)
		testing.expect(t, info.update_available, "update should be available")
		testing.expect_value(t, info.latest_version, "2.5.0")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	if len(track.allocation_map) > 0 {
		for _, v in track.allocation_map {
			fmt.printf("LEAK: %v bytes at %v\n", v.size, v.location)
		}
		testing.fail_now(t, "Memory leak detected in bridge update catalog resolution")
	}

	testing.expect_value(t, len(track.bad_free_array), 0)
	if len(track.bad_free_array) > 0 {
		testing.fail_now(t, "Bad free detected in bridge update catalog resolution")
	}
}

// REQ-T13-2: termux-arm64 is its own platform. Its hello is accepted, stored as
// os "termux", and resolved to the termux bundle only -- never to linux-arm64.
@(test)
test_bridge_update_catalog_termux_target_never_falls_back_to_linux :: proc(t: ^testing.T) {
	os_name, arch_name, ok := canonical_bridge_platform("", "", "termux-arm64")
	testing.expect(t, ok, "termux-arm64 hello target accepted")
	testing.expect_value(t, os_name, "termux")
	testing.expect_value(t, arch_name, "arm64")
	os_name, arch_name, ok = canonical_bridge_platform("linux", "aarch64", "Termux-AArch64")
	testing.expect(t, ok, "termux-aarch64 spelling accepted and authoritative over os/arch")
	testing.expect_value(t, os_name, "termux")
	testing.expect_value(t, arch_name, "arm64")
	testing.expect_value(t, normalize_bridge_target("termux", "arm64"), "termux-arm64")

	termux := domain.Bridge{machine_os = "termux", machine_arch = "arm64", version = "0.3.29"}
	linux := domain.Bridge{machine_os = "linux", machine_arch = "arm64", version = "0.3.29"}

	// A release that predates the termux bundle: newer, but not installable here.
	old_path := fmt.tprintf("/tmp/test_catalog_termux_old_%d_%d.json", os.get_pid(), time.now()._nsec)
	old_manifest := `{"version":"0.3.30","commit_sha":"c30","targets":{"linux-arm64":{"tarball_url":"https://example.com/heimdall-local-linux-arm64-v0.3.30.tar.gz","sha256":"hash_linux_arm64"}}}`
	testing.expect(t, os.write_entire_file(old_path, transmute([]byte)old_manifest) == nil, "wrote manifest without termux")
	defer os.remove(old_path)
	cat := Bridge_Update_Catalog{manifest_path = old_path}

	info := resolve_bridge_update_info(&cat, termux)
	testing.expect_value(t, info.target, "termux-arm64")
	testing.expect(t, info.update_available, "a newer release exists")
	testing.expect(t, !info.artifact_available, "but it is not available for termux-arm64")
	testing.expect_value(t, info.download_url, "")
	testing.expect_value(t, info.sha256, "")

	linux_info := resolve_bridge_update_info(&cat, linux)
	testing.expect(t, linux_info.artifact_available, "linux-arm64 still resolves its own bundle")

	// A release that ships the termux bundle: each target gets its own asset.
	new_path := fmt.tprintf("/tmp/test_catalog_termux_new_%d_%d.json", os.get_pid(), time.now()._nsec)
	new_manifest := `{"version":"0.3.31","commit_sha":"c31","targets":{"linux-arm64":{"tarball_url":"https://example.com/heimdall-local-linux-arm64-v0.3.31.tar.gz","sha256":"hash_linux_arm64"},"termux-arm64":{"tarball_url":"https://example.com/heimdall-local-termux-arm64-v0.3.31.tar.gz","sha256":"hash_termux_arm64"}}}`
	testing.expect(t, os.write_entire_file(new_path, transmute([]byte)new_manifest) == nil, "wrote manifest with termux")
	defer os.remove(new_path)
	cat.manifest_path = new_path

	info = resolve_bridge_update_info(&cat, termux)
	testing.expect(t, info.artifact_available, "termux bundle available")
	testing.expect_value(t, info.download_url, "https://example.com/heimdall-local-termux-arm64-v0.3.31.tar.gz")
	testing.expect_value(t, info.sha256, "hash_termux_arm64")
	linux_info = resolve_bridge_update_info(&cat, linux)
	testing.expect_value(t, linux_info.download_url, "https://example.com/heimdall-local-linux-arm64-v0.3.31.tar.gz")
	testing.expect_value(t, linux_info.sha256, "hash_linux_arm64")
}
