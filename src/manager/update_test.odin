// Tests for heimdall update (REQ-DIST-4).
//
// Pure tests cover the checksum parser, version comparison and the binary
// swap procedures (atomic install, self-update rollback, sibling ordering).
// The staged-download tests run a real loopback HTTP mock serving a built
// on-the-fly release tarball, covering the checksum-ok path, the tampered
// checksum fail-closed path and the incomplete-bundle refusal. Nothing here
// touches the real heimdall-bridge service: the swap tests only operate on
// temp install dirs and the stage tests never reach the service stop/start.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

// ---- pure helpers ----

@(test)
test_manager_update_normalized_tag :: proc(t: ^testing.T) {
	testing.expect(t, manager_update_normalized_tag("v0.2.0") == "0.2.0", "strips one leading v")
	testing.expect(t, manager_update_normalized_tag("V1.2.3") == "1.2.3", "strips leading V")
	testing.expect(t, manager_update_normalized_tag("0.1.0") == "0.1.0", "bare version untouched")
	testing.expect(t, manager_update_normalized_tag("  v2.0.0  ") == "2.0.0", "surrounding whitespace trimmed")
}

@(test)
test_manager_update_versions_equal :: proc(t: ^testing.T) {
	testing.expect(t, manager_update_versions_equal("v0.2.0", "0.2.0"), "tag vs app version")
	testing.expect(t, manager_update_versions_equal("0.2.0", "0.2.0"), "identical")
	testing.expect(t, !manager_update_versions_equal("v0.1.0", "0.2.0"), "different versions")
}

@(test)
test_manager_update_parse_checksum :: proc(t: ^testing.T) {
	sums := "1111111111111111111111111111111111111111111111111111111111111111  other.tar.gz\r\n" +
		"aaaa  heimdall-local-linux-amd64.tar.gz\n" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *binary.tar.gz\n"

	got := manager_update_parse_checksum(sums, "heimdall-local-linux-amd64.tar.gz")
	testing.expect(t, got == "aaaa", "two-space format matched")
	if got != "" do delete(got)

	got = manager_update_parse_checksum(sums, "binary.tar.gz")
	testing.expect(t, got == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "star format matched")
	if got != "" do delete(got)

	got = manager_update_parse_checksum(sums, "missing.tar.gz")
	testing.expect(t, got == "", "absent filename yields empty")
	if got != "" do delete(got)

	got = manager_update_parse_checksum("   \ntabs\t\tthe-name.tar.gz\n", "the-name.tar.gz")
	testing.expect(t, got == "tabs", "tab separator matched")
	if got != "" do delete(got)
}

@(test)
test_manager_update_sha256_hex :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-sha")
	defer manager_test_cleanup(dir)
	path := fmt.tprintf("%s/hello.txt", dir)
	testing.expect(t, os.write_entire_file(path, "hello", os.Permissions{.Read_User, .Write_User}) == nil, "wrote fixture")

	hex_str, ok := manager_update_sha256_hex(path)
	testing.expect(t, ok, "digest computed")
	testing.expect(
		t,
		hex_str == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
		"matches the known SHA-256 of \"hello\"",
	)
	if hex_str != "" do delete(hex_str)

	missing, missing_ok := manager_update_sha256_hex(fmt.tprintf("%s/nope.txt", dir))
	testing.expect(t, !missing_ok && missing == "", "unreadable file reports failure")
}

// ---- binary swap ----

manager_update_test_script :: proc(name, version: string) -> string {
	return fmt.tprintf("#!/bin/sh\necho \"%s %s\"\n", name, version)
}

manager_update_test_write_script :: proc(t: ^testing.T, path, name, version: string, executable: bool) {
	perms: os.Permissions = {.Read_User, .Write_User, .Read_Group, .Read_Other}
	if executable {
		perms = {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}
	}
	testing.expect(t, os.write_entire_file(path, manager_update_test_script(name, version), perms) == nil, fmt.tprintf("wrote %s", path))
}

manager_update_test_install_fixture :: proc(t: ^testing.T, dir: string) -> string {
	install_dir := fmt.tprintf("%s/install", dir)
	testing.expect(t, os.make_directory_all(install_dir) == nil, "mkdir install dir")
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-bridge", install_dir), "ham-bridge", "0.1.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-ctl", install_dir), "ham-ctl", "0.1.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/heimdall", install_dir), "heimdall", "0.1.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-pty-host", install_dir), "ham-pty-host", "0.1.0", true)
	return install_dir
}

manager_update_test_bundle_fixture :: proc(t: ^testing.T, dir: string, with_pty := true) -> string {
	bundle_bin := fmt.tprintf("%s/bundle/bin", dir)
	testing.expect(t, os.make_directory_all(bundle_bin) == nil, "mkdir bundle bin")
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-bridge", bundle_bin), "ham-bridge", "0.2.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-ctl", bundle_bin), "ham-ctl", "0.2.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/heimdall", bundle_bin), "heimdall", "0.2.0", true)
	if with_pty {
		manager_update_test_write_script(t, fmt.tprintf("%s/ham-pty-host", bundle_bin), "ham-pty-host", "0.2.0", true)
	}
	return bundle_bin
}

manager_update_test_expect_contains :: proc(t: ^testing.T, path, needle, msg: string) {
	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, msg)
	if err != nil do return
	testing.expect(t, strings.contains(string(data), needle), msg)
	delete(data)
}

@(test)
test_manager_update_install_one :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-one")
	defer manager_test_cleanup(dir)
	install_dir := fmt.tprintf("%s/install", dir)
	testing.expect(t, os.make_directory_all(install_dir) == nil, "mkdir install dir")

	target := fmt.tprintf("%s/ham-bridge", install_dir)
	testing.expect(t, os.write_entire_file(target, "old", os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil, "seed old binary")

	staged := fmt.tprintf("%s/staged-ham-bridge", dir)
	manager_update_test_write_script(t, staged, "ham-bridge", "0.2.0", true)

	testing.expect(t, manager_update_install_one(install_dir, staged, "ham-bridge"), "install succeeds")
	manager_update_test_expect_contains(t, target, "0.2.0", "target now holds the new binary")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/.heimdall-update-ham-bridge.tmp", install_dir)), "no temp file left behind")
	fi, serr := os.stat(target, context.allocator)
	testing.expect(t, serr == nil, "stat replaced target")
	if serr == nil {
		testing.expect(t, manager_permissions_mode(fi.mode) & 0o100 != 0, "target keeps the executable bit")
		os.file_info_delete(fi, context.allocator)
	}

	// installing from a missing staged file fails without touching the target
	testing.expect(t, !manager_update_install_one(install_dir, fmt.tprintf("%s/missing", dir), "ham-bridge"), "missing staged file fails")
	manager_update_test_expect_contains(t, target, "0.2.0", "target survives the failed install")
}

@(test)
test_manager_update_install_self :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-self")
	defer manager_test_cleanup(dir)
	install_dir := fmt.tprintf("%s/install", dir)
	testing.expect(t, os.make_directory_all(install_dir) == nil, "mkdir install dir")

	current := fmt.tprintf("%s/heimdall", install_dir)
	manager_update_test_write_script(t, current, "heimdall", "0.1.0", true)
	staged := fmt.tprintf("%s/staged-heimdall", dir)
	manager_update_test_write_script(t, staged, "heimdall", "0.2.0", true)

	testing.expect(t, manager_update_install_self(install_dir, staged), "self update succeeds")
	manager_update_test_expect_contains(t, current, "0.2.0", "heimdall replaced")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/heimdall.old", install_dir)), "heimdall.old removed on success")

	// failure path: missing staged binary restores the old executable
	manager_update_test_write_script(t, current, "heimdall", "0.3.0", true)
	testing.expect(t, !manager_update_install_self(install_dir, fmt.tprintf("%s/none", dir)), "missing staged self fails")
	manager_update_test_expect_contains(t, current, "0.3.0", "old heimdall restored after failed install")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/heimdall.old", install_dir)), "no heimdall.old left after rollback")
}

@(test)
test_manager_update_swap_all :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-swap")
	defer manager_test_cleanup(dir)
	install_dir := manager_update_test_install_fixture(t, dir)
	bundle_bin := manager_update_test_bundle_fixture(t, dir, with_pty = true)

	plan := Manager_Update_Plan{install_dir = install_dir}
	updated := make([dynamic]string, 0, 4)
	defer delete(updated)
	testing.expect(t, manager_update_swap_all(&plan, bundle_bin, &updated), "swap succeeds")
	testing.expect(t, len(updated) == 4, "all four binaries reported updated")
	testing.expect(t, updated[len(updated) - 1] == "heimdall", "heimdall updated last")
	names := []string{"ham-bridge", "ham-ctl", "ham-pty-host", "heimdall"}
	for name in names {
		manager_update_test_expect_contains(t, fmt.tprintf("%s/%s", install_dir, name), "0.2.0", fmt.tprintf("%s replaced", name))
	}
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/heimdall.old", install_dir)), "no heimdall.old left behind")
}

@(test)
test_manager_update_swap_all_optional_pty_host :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-swap-pty")
	defer manager_test_cleanup(dir)
	install_dir := manager_update_test_install_fixture(t, dir)
	bundle_bin := manager_update_test_bundle_fixture(t, dir, with_pty = false)

	plan := Manager_Update_Plan{install_dir = install_dir}
	updated := make([dynamic]string, 0, 4)
	defer delete(updated)
	testing.expect(t, manager_update_swap_all(&plan, bundle_bin, &updated), "swap succeeds without a bundled pty host")
	testing.expect(t, len(updated) == 3, "three binaries updated")
	manager_update_test_expect_contains(t, fmt.tprintf("%s/ham-pty-host", install_dir), "0.1.0", "installed ham-pty-host left alone when the bundle ships none")
}

// ---- staged download against a loopback mock ----

Manager_Update_Test_Mock :: struct {
	listener:         net.TCP_Socket,
	sums_response:    [dynamic]byte, // full prebuilt HTTP response (test thread memory)
	tarball_response: [dynamic]byte,
	max_requests:     int,
	served:           int,
}

manager_update_test_mock_thread :: proc(data: rawptr) {
	mock := cast(^Manager_Update_Test_Mock)data
	buffer: [MANAGER_TEST_MOCK_REQUEST_CAPACITY]byte
	for mock.served < mock.max_requests {
		client, _, aerr := net.accept_tcp(mock.listener)
		if aerr != nil do return
		_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
		length := manager_test_mock_read_request(client, buffer[:])
		if length <= 0 {
			net.close(client)
			continue
		}
		mock.served += 1
		if strings.contains(string(buffer[:length]), "SHA256SUMS") {
			manager_update_test_send_all(client, mock.sums_response[:])
		} else {
			manager_update_test_send_all(client, mock.tarball_response[:])
		}
		net.close(client)
	}
}

manager_update_test_send_all :: proc(client: net.TCP_Socket, data: []byte) {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(client, data[off:])
		if err != nil || n <= 0 do return
		off += n
	}
}

// manager_update_test_mock_start builds the two canned responses from a real
// tarball file on disk and serves them on the loopback listener. The caller
// must join with manager_update_test_mock_join.
manager_update_test_mock_start :: proc(
	t: ^testing.T,
	tarball_path, tarball_name, digest: string,
	sums_digest: string,
	max_requests := 2,
) -> (^Manager_Update_Test_Mock, int, ^thread.Thread) {
	raw, rerr := os.read_entire_file(tarball_path, context.allocator)
	testing.expect(t, rerr == nil, "fixture tarball readable")
	if rerr != nil do return nil, 0, nil
	defer delete(raw)

	tarball_head := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(raw))
	sums_text := fmt.tprintf("%s  %s\n", sums_digest, tarball_name)
	sums_head := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(sums_text), sums_text)

	listener, port, lok := manager_test_loopback_listener()
	if !lok {
		testing.expect(t, lok, "loopback listener available")
		return nil, 0, nil
	}
	mock := new(Manager_Update_Test_Mock)
	mock.listener = listener
	mock.max_requests = max_requests
	mock.tarball_response = make([dynamic]byte, 0, len(tarball_head) + len(raw))
	append(&mock.tarball_response, ..transmute([]byte)tarball_head)
	append(&mock.tarball_response, ..raw)
	mock.sums_response = make([dynamic]byte, 0, len(sums_head))
	append(&mock.sums_response, ..transmute([]byte)sums_head)
	return mock, port, thread.create_and_start_with_data(mock, manager_update_test_mock_thread)
}

manager_update_test_mock_join :: proc(mock: ^Manager_Update_Test_Mock, handle: ^thread.Thread) {
	if handle != nil {
		thread.join(handle)
		thread.destroy(handle)
	}
	if mock != nil {
		net.close(mock.listener)
		delete(mock.sums_response)
		delete(mock.tarball_response)
		free(mock)
	}
}

// manager_update_test_build_tarball assembles a release-bundle directory and
// tars it up, returning the tarball path and its SHA-256 hex (heap string).
manager_update_test_build_tarball :: proc(t: ^testing.T, dir: string, target: string, with_pty := true) -> (string, string) {
	bundle := fmt.tprintf("%s/bundle-%s", dir, target)
	bundle_bin := fmt.tprintf("%s/bin", bundle)
	testing.expect(t, os.make_directory_all(bundle_bin) == nil, "mkdir bundle bin")
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-bridge", bundle_bin), "ham-bridge", "0.2.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-ctl", bundle_bin), "ham-ctl", "0.2.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/heimdall", bundle_bin), "heimdall", "0.2.0", true)
	if with_pty {
		manager_update_test_write_script(t, fmt.tprintf("%s/ham-pty-host", bundle_bin), "ham-pty-host", "0.2.0", true)
	}
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/README.md", bundle), "release notes\n", os.Permissions_Read_All) == nil, "wrote README")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/LICENSE", bundle), "license\n", os.Permissions_Read_All) == nil, "wrote LICENSE")
	metadata := "{\"product\": \"heimdall-local\", \"version\": \"0.2.0\"}\n"
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/METADATA.json", bundle), metadata, os.Permissions_Read_All) == nil, "wrote METADATA")

	tarball_name := fmt.tprintf("heimdall-local-%s.tar.gz", target)
	tarball_path := fmt.tprintf("%s/%s", dir, tarball_name)
	out, err_out, ok := manager_run_capture({"tar", "-czf", tarball_path, "-C", bundle, "."})
	testing.expect(t, ok, fmt.tprintf("tar succeeded: %s", err_out))
	if out != "" do delete(out)
	if err_out != "" do delete(err_out)
	digest, hash_ok := manager_update_sha256_hex(tarball_path)
	testing.expect(t, hash_ok, "fixture tarball hashed")
	return tarball_path, digest
}

manager_update_test_stage_plan :: proc(dir: string, port: int, target: string) -> (Manager_Update_Plan, Manager_Update_Release) {
	base := fmt.tprintf("http://127.0.0.1:%d", port)
	tarball_name := fmt.tprintf("heimdall-local-%s.tar.gz", target)
	plan := Manager_Update_Plan{
		source = Manager_Update_Source{kind = .Mirror, mirror_base = strings.clone(base)},
		target = target,
		stage_root = fmt.tprintf("%s/updates", dir),
		install_dir = fmt.tprintf("%s/install", dir),
		platform = .Linux,
		unit = "heimdall-manager-selftest-update",
	}
	release := Manager_Update_Release{
		version = "",
		tarball_name = tarball_name,
		tarball_url = fmt.tprintf("%s/%s", base, tarball_name),
		sums_url = fmt.tprintf("%s/SHA256SUMS", base),
	}
	return plan, release
}

@(test)
test_manager_update_prepare_stage_checksum_ok :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-stage-ok")
	defer manager_test_cleanup(dir)
	target := fmt.tprintf("%s-%s", manager_os_string(), manager_arch_string())
	tarball_path, digest := manager_update_test_build_tarball(t, dir, target)
	defer delete(digest)

	mock, port, handle := manager_update_test_mock_start(t, tarball_path, fmt.tprintf("heimdall-local-%s.tar.gz", target), digest, digest)
	if mock == nil do return
	defer manager_update_test_mock_join(mock, handle)

	plan, release := manager_update_test_stage_plan(dir, port, target)
	defer delete(plan.source.mirror_base)
	testing.expect(t, manager_update_prepare_stage(&plan, &release), "stage prepared")
	testing.expect(t, mock.served == 2, "mock served sums + tarball")
	bin_dir := fmt.tprintf("%s/stage/extract/bin", plan.stage_root)
	testing.expect(t, manager_is_dir(bin_dir), "bundle extracted")
	names := []string{"ham-bridge", "ham-ctl", "heimdall", "ham-pty-host"}
	for name in names {
		testing.expect(t, manager_path_exists(fmt.tprintf("%s/%s", bin_dir, name)), fmt.tprintf("extracted %s", name))
	}
}

@(test)
test_manager_update_prepare_stage_checksum_mismatch :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-stage-tamper")
	defer manager_test_cleanup(dir)
	target := fmt.tprintf("%s-%s", manager_os_string(), manager_arch_string())
	tarball_path, digest := manager_update_test_build_tarball(t, dir, target)
	defer delete(digest)

	mock, port, handle := manager_update_test_mock_start(
		t, tarball_path, fmt.tprintf("heimdall-local-%s.tar.gz", target), digest,
		"0000000000000000000000000000000000000000000000000000000000000000",
	)
	if mock == nil do return
	defer manager_update_test_mock_join(mock, handle)

	plan, release := manager_update_test_stage_plan(dir, port, target)
	defer delete(plan.source.mirror_base)
	testing.expect(t, !manager_update_prepare_stage(&plan, &release), "tampered checksum aborts the stage")
	testing.expect(t, !manager_path_exists(plan.stage_root), "staging directory removed on failure")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/install", dir)), "install dir never created")
}

@(test)
test_manager_update_prepare_stage_incomplete_bundle :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-stage-incomplete")
	defer manager_test_cleanup(dir)
	target := fmt.tprintf("%s-%s", manager_os_string(), manager_arch_string())
	// Build a bundle whose ham-ctl is a directory, so bin/ham-ctl exists as a
	// path but refuses to execute -- the required-binary execution check must
	// reject it.
	bundle_bin := fmt.tprintf("%s/bundle/bin", dir)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/ham-ctl", bundle_bin)) == nil, "ham-ctl as decoy directory")
	manager_update_test_write_script(t, fmt.tprintf("%s/ham-bridge", bundle_bin), "ham-bridge", "0.2.0", true)
	manager_update_test_write_script(t, fmt.tprintf("%s/heimdall", bundle_bin), "heimdall", "0.2.0", true)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/README.md", bundle_bin), "x\n", os.Permissions_Read_All) == nil, "wrote README")

	tarball_name := fmt.tprintf("heimdall-local-%s.tar.gz", target)
	tarball_path := fmt.tprintf("%s/%s", dir, tarball_name)
	out, err_out, ok := manager_run_capture({"tar", "-czf", tarball_path, "-C", fmt.tprintf("%s/bundle", dir), "."})
	testing.expect(t, ok, fmt.tprintf("tar succeeded: %s", err_out))
	if out != "" do delete(out)
	if err_out != "" do delete(err_out)
	digest, hash_ok := manager_update_sha256_hex(tarball_path)
	testing.expect(t, hash_ok, "fixture tarball hashed")
	defer delete(digest)

	mock, port, handle := manager_update_test_mock_start(t, tarball_path, tarball_name, digest, digest)
	if mock == nil do return
	defer manager_update_test_mock_join(mock, handle)

	plan, release := manager_update_test_stage_plan(dir, port, target)
	defer delete(plan.source.mirror_base)
	testing.expect(t, !manager_update_prepare_stage(&plan, &release), "non-executable required binary aborts the stage")
	testing.expect(t, !manager_path_exists(plan.stage_root), "staging directory removed on failure")
}

// ---- resolve: URL shapes ----

@(test)
test_manager_update_resolve_release_mirror_urls :: proc(t: ^testing.T) {
	plan := Manager_Update_Plan{
		source = Manager_Update_Source{kind = .Mirror, mirror_base = strings.clone("http://127.0.0.1:49999")},
		version = "v9.9.9",
		target = "linux-amd64",
	}
	defer delete(plan.source.mirror_base)
	release, ok := manager_update_resolve_release(&plan)
	testing.expect(t, ok, "mirror resolution needs no network")
	testing.expect(t, release.tarball_name == "heimdall-local-linux-amd64.tar.gz", "mirror tarball is unversioned")
	testing.expect(t, release.tarball_url == "http://127.0.0.1:49999/heimdall-local-linux-amd64.tar.gz", "mirror tarball url")
	testing.expect(t, release.sums_url == "http://127.0.0.1:49999/SHA256SUMS", "mirror sums url")
}

// REQ-T13-3: a release whose SHA256SUMS has no bundle for this target is "not
// available for this target". Only SHA256SUMS is fetched -- no tarball of any
// other target is downloaded -- and nothing is staged.
@(test)
test_manager_update_prepare_stage_target_not_available :: proc(t: ^testing.T) {
	dir := manager_test_tmp_dir("update-stage-termux-missing")
	defer manager_test_cleanup(dir)
	tarball_path, digest := manager_update_test_build_tarball(t, dir, "linux-arm64")
	defer delete(digest)

	mock, port, handle := manager_update_test_mock_start(t, tarball_path, "heimdall-local-linux-arm64.tar.gz", digest, digest, max_requests = 1)
	if mock == nil do return
	defer manager_update_test_mock_join(mock, handle)

	plan, release := manager_update_test_stage_plan(dir, port, "termux-arm64")
	defer delete(plan.source.mirror_base)
	testing.expect_value(t, release.tarball_name, "heimdall-local-termux-arm64.tar.gz")
	testing.expect(t, !manager_update_prepare_stage(&plan, &release), "missing target aborts")
	testing.expect_value(t, mock.served, 1)
	testing.expect(t, !manager_path_exists(plan.stage_root), "staging directory removed")
}

@(test)
test_manager_update_tarball_name_and_release_assets :: proc(t: ^testing.T) {
	testing.expect_value(t, manager_update_tarball_name("termux-arm64", "v0.3.30"), "heimdall-local-termux-arm64-v0.3.30.tar.gz")
	testing.expect_value(t, manager_update_tarball_name("termux-arm64", ""), "heimdall-local-termux-arm64.tar.gz")
	body := `{"tag_name":"v0.3.30","assets":[{"name":"heimdall-local-linux-arm64-v0.3.30.tar.gz"},{"name": "SHA256SUMS"}]}`
	testing.expect(t, manager_update_release_lists_asset(body, "heimdall-local-linux-arm64-v0.3.30.tar.gz"), "linux asset listed")
	testing.expect(t, !manager_update_release_lists_asset(body, "heimdall-local-termux-arm64-v0.3.30.tar.gz"), "termux asset not listed")
	testing.expect(t, !manager_update_release_lists_asset(body, "heimdall-local-linux-arm64-v0.3.3.tar.gz"), "exact name only")
}

// REQ-T13-3: on Termux the swap is bracketed by `sv down|up`, never systemctl.
@(test)
test_manager_update_runit_service :: proc(t: ^testing.T) {
	dir := "/data/data/com.termux/files/usr/var/service/ham-bridge"
	argv := manager_runit_verb_argv("stop", dir)
	defer delete(argv)
	testing.expect_value(t, len(argv), 3)
	if len(argv) == 3 {
		testing.expect_value(t, argv[0], "sv")
		testing.expect_value(t, argv[1], "down")
		testing.expect_value(t, argv[2], dir)
	}
	up := manager_runit_verb_argv("start", dir)
	defer delete(up)
	if len(up) == 3 do testing.expect_value(t, up[1], "up")
	testing.expect(t, manager_runit_verb_argv("enable", dir) == nil, "unknown verb yields no command")

	running := manager_parse_sv_status("run: /data/data/com.termux/files/usr/var/service/ham-bridge: (pid 4242) 45s; run: log: (pid 98) 300s\n", true)
	testing.expect(t, running.loaded && running.active, "run: is active")
	testing.expect_value(t, running.pid, 4242)
	down := manager_parse_sv_status("down: /data/data/com.termux/files/usr/var/service/ham-bridge: 3s, normally up\n", true)
	testing.expect(t, down.loaded && !down.active, "down: is loaded but inactive")
	missing := manager_parse_sv_status("", false)
	testing.expect(t, !missing.loaded && !missing.active, "sv failure is neither loaded nor active")
}

// REQ-T13-3: a linux build that finds itself under Termux refuses to plan an
// update at all rather than resolving linux-* (or guessing termux-*).
@(test)
test_manager_update_build_plan_refuses_linux_build_on_termux :: proc(t: ^testing.T) {
	when contracts.RELEASE_TARGET == "" && ODIN_OS == .Linux {
		sync.mutex_lock(&manager_test_env_mutex)
		defer sync.mutex_unlock(&manager_test_env_mutex)
		prev, had_prev := os.lookup_env("TERMUX_VERSION", context.allocator)
		defer if had_prev do delete(prev)
		testing.expect(t, os.set_env("TERMUX_VERSION", "0.118.0") == nil, "set TERMUX_VERSION")
		defer if had_prev { _ = os.set_env("TERMUX_VERSION", prev) } else { _ = os.unset_env("TERMUX_VERSION") }
		_, ok := manager_update_build_plan({"update"}, .Linux)
		testing.expect(t, !ok, "plan refused for a non-termux build on Termux")
	}
}
