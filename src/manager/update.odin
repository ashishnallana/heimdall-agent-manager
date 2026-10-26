// heimdall update: in-place binary update for non-hub nodes (REQ-DIST-4).
//
// Fetches the release manifest (GitHub Releases by default, or a static
// mirror via --hub following the install.sh convention), streams the release
// tarball and SHA256SUMS into a staging directory under the config dir
// (<config-dir>/updates/stage, i.e. ~/.config/heimdall/updates/stage by
// default), verifies the SHA-256 before anything is extracted, validates the
// staged binaries by executing them, then — only after staging is proven —
// stops the heimdall-bridge service, atomically replaces the installed
// binaries (including heimdall itself via the heimdall.old dance, which is
// safe for a running process on POSIX), restarts the service and cleans the
// staging directory. On checksum/validation failure nothing is extracted,
// the service is never touched and the staging directory is removed.
package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"

// Release source (same GitHub repo as scripts/install.sh; mirror layout
// matches install.sh --hub: unversioned heimdall-local-<target>.tar.gz and
// SHA256SUMS served from the mirror root).
MANAGER_UPDATE_GITHUB_REPO :: "tanmayv/heimdall-agent-manager" // for messages
MANAGER_UPDATE_GITHUB_OWNER :: "tanmayv"
MANAGER_UPDATE_GITHUB_NAME :: "heimdall-agent-manager"
MANAGER_UPDATE_API_BASE :: "https://api.github.com"
MANAGER_UPDATE_DOWNLOAD_BASE :: "https://github.com"
MANAGER_UPDATE_TIMEOUT_MS :: 60000 // connect / stall budget; downloads tolerate slow links (total: httpc.LONG_TRANSFER_TIMEOUT_MS)
MANAGER_UPDATE_MANIFEST_TIMEOUT_MS :: 20000
// GitHub release assets redirect to objects.githubusercontent.com.
MANAGER_UPDATE_MAX_REDIRECTS :: 5

// Binaries every release bundle must ship (package-local-binary-tarball.sh
// required_entries). ham-pty-host stays optional there (PTYH-4), so a bundle
// without it updates everything else and leaves the installed PTY host alone.
// openssl is deliberately absent: it is a generic name heimdall does not own,
// and refreshing a bundled copy could clobber a system openssl in a shared
// install dir. REQ-INST-21 retired the bundled-openssl machinery; the updater
// leaves any openssl it finds untouched — the optional loop installs only
// staged files and deletes nothing.
MANAGER_UPDATE_REQUIRED_BINS :: []string{"ham-bridge", "ham-ctl", "heimdall"}
MANAGER_UPDATE_OPTIONAL_BINS :: []string{"ham-pty-host"}

Manager_Update_Source_Kind :: enum {
	GitHub, // api.github.com manifest + versioned release assets
	Mirror, // static mirror per install.sh --hub (unversioned files)
}

Manager_Update_Source :: struct {
	kind:        Manager_Update_Source_Kind,
	mirror_base: string, // trimmed base URL when kind == .Mirror
}

// Manager_Update_Plan carries every dependency of the update flow so tests
// can inject a mock release server, a temp install dir, a temp stage dir and
// a sacrificial service identity (never the real heimdall-bridge unit).
Manager_Update_Plan :: struct {
	source:      Manager_Update_Source,
	version:     string, // requested pin ("" = latest; GitHub only)
	check_only:  bool,
	target:      string, // release target, e.g. linux-amd64
	stage_root:  string, // <config-dir>/updates
	install_dir: string, // directory holding heimdall and its siblings
	platform:    Manager_Platform,
	unit:        string, // systemd user unit (Linux)
	label:       string, // launchd label (Darwin)
	plist_path:  string,
	runit_dir:   string, // termux-services service dir (Termux); replaces unit when set
}

// The runit service install.sh creates on Termux ($PREFIX/var/service/<name>).
MANAGER_RUNIT_SERVICE :: "ham-bridge"

manager_print_update_usage :: proc() {
	fmt.println("usage: heimdall update [--check] [--version <tag>] [--hub <url>]")
	fmt.println("")
	fmt.println("Checks for and applies binary updates for this node (heimdall, ham-bridge,")
	fmt.println("ham-pty-host, ham-ctl). Downloads are checksum-verified before extraction;")
	fmt.println("the bridge service is stopped around the binary swap and restarted after.")
	fmt.println("")
	fmt.println("Without flags, updates to the latest GitHub release:")
	fmt.println("  --check         report current vs latest version without downloading")
	fmt.println("  --version <tag> update to release <tag> instead of the latest")
	fmt.println("  --hub <url>     use a static release mirror serving heimdall-local-<target>.tar.gz")
	fmt.println("                  and SHA256SUMS (same layout as install.sh --hub)")
}

// ---- plan construction ----

manager_update_command :: proc(args: []string) -> int {
	platform := manager_host_platform()
	if platform == .Unsupported {
		fmt.eprintln("heimdall: update is only supported on Linux and macOS")
		return 1
	}
	plan, ok := manager_update_build_plan(args, platform)
	if !ok do return 1
	if plan.check_only {
		return manager_update_check(&plan)
	}
	return manager_update_perform(&plan)
}

manager_update_build_plan :: proc(args: []string, platform: Manager_Platform) -> (Manager_Update_Plan, bool) {
	plan := Manager_Update_Plan{
		platform   = platform,
		unit       = MANAGER_SERVICE_UNIT,
		label      = MANAGER_LAUNCHD_LABEL,
		plist_path = manager_launchd_plist_path(),
	}
	// Test hook (mirrors the sacrificial-unit pattern of service_test.odin):
	// let an isolated run target a throwaway service identity. Never set in
	// production; the real heimdall-bridge unit hosts the running runtime.
	if override := strings.trim_space(os.get_env("HEIMDALL_MANAGER_UPDATE_UNIT", context.temp_allocator)); override != "" {
		plan.unit = strings.clone(override)
	}
	if override := strings.trim_space(os.get_env("HEIMDALL_MANAGER_UPDATE_LABEL", context.temp_allocator)); override != "" {
		plan.label = strings.clone(override)
	}

	hub := strings.trim_right(strings.trim_space(manager_option_value(args, "--hub", "")), "/")
	if hub != "" {
		if !manager_hub_url_supported(hub) {
			fmt.eprintln("heimdall update --hub must be an http:// or https:// base URL")
			return plan, false
		}
		plan.source = Manager_Update_Source{kind = .Mirror, mirror_base = strings.clone(hub)}
	} else {
		plan.source = Manager_Update_Source{kind = .GitHub}
	}
	plan.version = strings.trim_space(manager_option_value(args, "--version", ""))
	plan.check_only = manager_has_flag(args, "--check")
	// REQ-T13-3: the same target resolution as the bridge. The termux bundle
	// carries HAM_RELEASE_TARGET=termux-arm64; a linux build running under
	// Termux must not fetch either bundle, since it cannot tell how it was
	// installed. Never fall back from termux-* to linux-*: the glibc bundle
	// dies on Android's seccomp filter.
	termux_version := os.get_env("TERMUX_VERSION", context.temp_allocator)
	prefix := os.get_env("PREFIX", context.temp_allocator)
	on_termux := contracts.termux_env_detected(termux_version, prefix)
	native := fmt.tprintf("%s-%s", manager_os_string(), manager_arch_string())
	target, update_blocked := contracts.release_target_resolve(contracts.RELEASE_TARGET, native, on_termux)
	if update_blocked {
		fmt.eprintfln("heimdall update: this heimdall runs under Termux but is not the %s build; self-update is refused.", target)
		fmt.eprintln("  Reinstall with install.sh, which installs the Termux bundle.")
		return plan, false
	}
	plan.target = strings.clone(target)
	if on_termux {
		// termux-services supervises the bridge; there is no systemd here.
		plan.runit_dir = fmt.aprintf("%s/var/service/%s", prefix, MANAGER_RUNIT_SERVICE)
		if override := strings.trim_space(os.get_env("HEIMDALL_MANAGER_UPDATE_RUNIT_DIR", context.temp_allocator)); override != "" {
			plan.runit_dir = strings.clone(override)
		}
		plan.unit = plan.runit_dir
	}

	config_path := manager_config_path(args)
	plan.stage_root = fmt.tprintf("%s/updates", manager_dir_of(config_path))

	exe_path, exe_err := os.get_executable_path(context.allocator)
	if exe_err != nil || strings.trim_space(exe_path) == "" {
		exe_path, _ = manager_bin_on_path("heimdall")
	}
	if strings.trim_space(exe_path) == "" {
		fmt.eprintln("heimdall update: cannot resolve the running heimdall executable path")
		return plan, false
	}
	plan.install_dir = strings.clone(manager_dir_of(exe_path))
	if exe_path != "" do delete(exe_path)
	if !manager_is_dir(plan.install_dir) {
		fmt.eprintfln("heimdall update: install directory %s does not exist", plan.install_dir)
		return plan, false
	}
	return plan, true
}

// ---- version helpers ----

// manager_update_normalized_tag strips one leading 'v' so release tags like
// "v0.2.0" compare against APP_VERSION "0.2.0".
manager_update_normalized_tag :: proc(tag: string) -> string {
	trimmed := strings.trim_space(tag)
	if strings.has_prefix(trimmed, "v") || strings.has_prefix(trimmed, "V") {
		return trimmed[1:]
	}
	return trimmed
}

manager_update_versions_equal :: proc(a, b: string) -> bool {
	return manager_update_normalized_tag(a) == manager_update_normalized_tag(b)
}

// ---- release resolution ----

Manager_Update_Release :: struct {
	version:    string, // tag (GitHub) or pin (Mirror/"")
	tarball_url: httpc.Url,
	sums_url:    httpc.Url,
	tarball_name: string,
}

// manager_update_tarball_name is the release asset for target, versioned for
// GitHub releases (heimdall-local-<target>-<tag>.tar.gz), unversioned on a
// mirror (tag == "").
manager_update_tarball_name :: proc(target, tag: string) -> string {
	if tag == "" do return fmt.tprintf("heimdall-local-%s.tar.gz", target)
	return fmt.tprintf("heimdall-local-%s-%s.tar.gz", target, tag)
}

// manager_update_release_lists_asset reports whether a GitHub release JSON
// body names asset among its files (a quoted exact file name).
manager_update_release_lists_asset :: proc(release_json, asset: string) -> bool {
	return strings.contains(release_json, fmt.tprintf("\"%s\"", asset))
}

// manager_update_fetch_latest_version queries the GitHub Releases manifest
// for the newest (or pinned) release tag, and whether that release ships the
// bundle for plan.target (REQ-T13-3): (tag, has_target, ok). ok=false means
// the caller must abort; the error paths print diagnostics.
manager_update_fetch_latest_version :: proc(plan: ^Manager_Update_Plan, pin: string) -> (string, bool, bool) {
	api, url_err := httpc.parse_url(MANAGER_UPDATE_API_BASE)
	if url_err != .None do return "", false, false
	latest := [?]string{"repos", MANAGER_UPDATE_GITHUB_OWNER, MANAGER_UPDATE_GITHUB_NAME, "releases", "latest"}
	pinned := [?]string{"repos", MANAGER_UPDATE_GITHUB_OWNER, MANAGER_UPDATE_GITHUB_NAME, "releases", "tags", pin}
	path := pinned[:] if pin != "" else latest[:]
	// GitHub rejects REST calls without a User-Agent (HTTP 403).
	headers := [?]httpc.Header{httpc.user_agent("heimdall-update"), httpc.accept("application/vnd.github+json")}
	resp, err := httpc.send({method = .GET, url = api, path = path, headers = headers[:], timeout_ms = MANAGER_UPDATE_MANIFEST_TIMEOUT_MS})
	defer httpc.response_destroy(&resp)
	if err != .None {
		fmt.eprintfln("heimdall update: could not reach %s (%s) — check network", MANAGER_UPDATE_API_BASE, httpc.error_string(err))
		return "", false, false
	}
	body := httpc.text(resp)
	switch resp.status {
	case 200:
		tag := manager_extract_json_string(body, "tag_name", "")
		if tag == "" {
			fmt.eprintln("heimdall update: release manifest has no tag_name — aborting")
			return "", false, false
		}
		has_target := manager_update_release_lists_asset(body, manager_update_tarball_name(plan.target, tag))
		return strings.clone(tag), has_target, true
	case 404:
		if pin != "" {
			fmt.eprintfln("heimdall update: release %q not found on %s", pin, MANAGER_UPDATE_GITHUB_REPO)
		} else {
			fmt.eprintfln("heimdall update: no published release found on %s yet — nothing to update to", MANAGER_UPDATE_GITHUB_REPO)
		}
		return "", false, false
	case:
		fmt.eprintfln("heimdall update: manifest request failed with HTTP %d — %s", resp.status, body)
		return "", false, false
	}
}

// manager_update_asset_url is base + dir segments + file name, rendered and
// re-parsed by httpc (temp-allocated).
manager_update_asset_url :: proc(base: httpc.Url, dir: []string, file: string) -> (httpc.Url, bool) {
	segments := make([dynamic]string, 0, len(dir) + 1, context.temp_allocator)
	append(&segments, ..dir)
	append(&segments, file)
	text, err := httpc.build_url(base, segments[:], allocator = context.temp_allocator)
	if err != .None do return {}, false
	u, perr := httpc.parse_url(text)
	return u, perr == .None
}

manager_update_resolve_release :: proc(plan: ^Manager_Update_Plan) -> (Manager_Update_Release, bool) {
	release := Manager_Update_Release{}
	switch plan.source.kind {
	case .GitHub:
		tag, has_target, ok := manager_update_fetch_latest_version(plan, plan.version)
		if !ok do return release, false
		if !has_target && !manager_update_versions_equal(tag, contracts.APP_VERSION) {
			fmt.eprintfln("heimdall update: release %s is not available for target %s — nothing to install", tag, plan.target)
			delete(tag)
			return release, false
		}
		release.version = tag
		release.tarball_name = manager_update_tarball_name(plan.target, tag)
		download, url_err := httpc.parse_url(MANAGER_UPDATE_DOWNLOAD_BASE)
		if url_err != .None do return release, false
		release_dir := [?]string{MANAGER_UPDATE_GITHUB_OWNER, MANAGER_UPDATE_GITHUB_NAME, "releases", "download", tag}
		tarball_ok, sums_ok: bool
		release.tarball_url, tarball_ok = manager_update_asset_url(download, release_dir[:], release.tarball_name)
		release.sums_url, sums_ok = manager_update_asset_url(download, release_dir[:], "SHA256SUMS")
		if !tarball_ok || !sums_ok do return release, false
	case .Mirror:
		release.version = plan.version
		release.tarball_name = manager_update_tarball_name(plan.target, "")
		mirror, url_err := httpc.parse_url(plan.source.mirror_base)
		if url_err != .None do return release, false
		tarball_ok, sums_ok: bool
		release.tarball_url, tarball_ok = manager_update_asset_url(mirror, nil, release.tarball_name)
		release.sums_url, sums_ok = manager_update_asset_url(mirror, nil, "SHA256SUMS")
		if !tarball_ok || !sums_ok do return release, false
	}
	return release, true
}

// ---- --check ----

manager_update_check :: proc(plan: ^Manager_Update_Plan) -> int {
	fmt.println(manager_version_line())
	fmt.println("")
	fmt.printfln("  current version: %s", contracts.APP_VERSION)
	switch plan.source.kind {
	case .GitHub:
		tag, has_target, ok := manager_update_fetch_latest_version(plan, plan.version)
		if !ok do return 1
		defer delete(tag)
		fmt.printfln("  target:          %s", plan.target)
		fmt.printfln("  latest release:  %s", tag)
		if manager_update_versions_equal(tag, contracts.APP_VERSION) {
			fmt.println("  status:          up to date")
			return 0
		}
		if !has_target {
			fmt.printfln("  status:          %s is not available for target %s", tag, plan.target)
			return 0
		}
		fmt.println("  status:          update available (run: heimdall update)")
		return 0
	case .Mirror:
		mirror, url_err := httpc.parse_url(plan.source.mirror_base)
		if url_err != .None {
			fmt.eprintfln("  mirror:          %s is not a valid URL", plan.source.mirror_base)
			return 1
		}
		resp, err := httpc.send({method = .GET, url = mirror, path = {"SHA256SUMS"}, timeout_ms = MANAGER_UPDATE_MANIFEST_TIMEOUT_MS})
		defer httpc.response_destroy(&resp)
		if err != .None {
			fmt.eprintfln("  mirror:          %s unreachable (%s)", plan.source.mirror_base, httpc.error_string(err))
			return 1
		}
		if resp.status != 200 {
			fmt.eprintfln("  mirror:          SHA256SUMS request failed with HTTP %d", resp.status)
			return 1
		}
		fmt.println("  latest release:  (unversioned mirror)")
		fmt.println("  status:          mirror reachable; run 'heimdall update --hub <url>' to apply")
		return 0
	}
	return 1
}

// ---- checksum helpers ----

// manager_update_parse_checksum extracts the expected hex digest for
// `filename` from a sha256sum-format file. Each line is "<hex>  <name>" or
// "<hex> *<name>" (the '*' marks binary mode). Parsed manually so no
// per-line heap slice is allocated; returns a heap clone ("" when absent).
manager_update_parse_checksum :: proc(sums, filename: string) -> string {
	text := sums
	for line in strings.split_lines_iterator(&text) {
		rest := strings.trim_left(line, " \t")
		hex_end := strings.index_any(rest, " \t")
		if hex_end <= 0 do continue
		digest := rest[:hex_end]
		rest = strings.trim_left(rest[hex_end:], " \t")
		rest = strings.trim_right(rest, " \t\r")
		rest = strings.trim_prefix(rest, "*")
		if rest != "" && strings.equal_fold(rest, filename) {
			return strings.clone(digest)
		}
	}
	return ""
}

manager_update_sha256_hex :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", false
	defer delete(data)
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, string(data), digest[:])
	hex_str := hex.encode(digest[:])
	defer delete(hex_str)
	return strings.to_lower(string(hex_str), context.allocator), true
}

// ---- staged download + validation ----

// manager_update_prepare_stage downloads, checksum-verifies, extracts and
// validates the release bundle inside stage_root/stage. Every failure path
// removes the staging directory and leaves the install untouched.
manager_update_prepare_stage :: proc(plan: ^Manager_Update_Plan, release: ^Manager_Update_Release) -> bool {
	stage_dir := fmt.tprintf("%s/stage", plan.stage_root)
	_ = os.remove_all(plan.stage_root)
	if os.make_directory_all(stage_dir) != nil {
		fmt.eprintfln("heimdall update: cannot create staging directory %s", stage_dir)
		return false
	}
	// from here on, failure paths must clean the staging directory
	ok := manager_update_prepare_stage_inner(plan, release, stage_dir)
	if !ok do _ = os.remove_all(plan.stage_root)
	return ok
}

manager_update_prepare_stage_inner :: proc(plan: ^Manager_Update_Plan, release: ^Manager_Update_Release, stage_dir: string) -> bool {
	sums_path := fmt.tprintf("%s/SHA256SUMS", stage_dir)
	tarball_path := fmt.tprintf("%s/%s", stage_dir, release.tarball_name)

	fmt.printfln("heimdall update: downloading %s", httpc.url_string(release.sums_url))
	status, dl_err := httpc.download_to_file({method = .GET, url = release.sums_url, timeout_ms = httpc.LONG_TRANSFER_TIMEOUT_MS, connect_timeout_ms = MANAGER_UPDATE_TIMEOUT_MS, stall_timeout_ms = MANAGER_UPDATE_TIMEOUT_MS, max_redirects = MANAGER_UPDATE_MAX_REDIRECTS}, sums_path)
	if dl_err != .None || status != 200 {
		fmt.eprintfln("heimdall update: SHA256SUMS download failed (HTTP %d) — aborting", status)
		return false
	}

	sums_data, serr := os.read_entire_file(sums_path, context.allocator)
	if serr != nil {
		fmt.eprintln("heimdall update: cannot read downloaded SHA256SUMS — aborting")
		return false
	}
	defer delete(sums_data)
	// REQ-T13-3: a release without this target's bundle is "not available for
	// this target". Checked before the tarball download, and never retried
	// with another target's bundle.
	expected := manager_update_parse_checksum(string(sums_data), release.tarball_name)
	if expected == "" {
		fmt.eprintfln("heimdall update: release %s is not available for target %s (SHA256SUMS has no entry for %s) — aborting", release.version if release.version != "" else "(mirror)", plan.target, release.tarball_name)
		return false
	}
	defer delete(expected)

	fmt.printfln("heimdall update: downloading %s", httpc.url_string(release.tarball_url))
	status, dl_err = httpc.download_to_file({method = .GET, url = release.tarball_url, timeout_ms = httpc.LONG_TRANSFER_TIMEOUT_MS, connect_timeout_ms = MANAGER_UPDATE_TIMEOUT_MS, stall_timeout_ms = MANAGER_UPDATE_TIMEOUT_MS, max_redirects = MANAGER_UPDATE_MAX_REDIRECTS}, tarball_path)
	if dl_err != .None || status != 200 {
		fmt.eprintfln("heimdall update: tarball download failed (HTTP %d) — aborting", status)
		return false
	}

	// Verify the checksum BEFORE anything is extracted (fail-closed, the same
	// contract as install.sh: a corrupt or hostile tarball never reaches the
	// filesystem as an installed binary).
	actual, hash_ok := manager_update_sha256_hex(tarball_path)
	if !hash_ok {
		fmt.eprintln("heimdall update: cannot hash downloaded tarball — aborting")
		return false
	}
	defer delete(actual)
	if !strings.equal_fold(strings.trim_space(expected), actual) {
		fmt.eprintfln("heimdall update: SHA-256 mismatch for %s", release.tarball_name)
		fmt.eprintfln("  expected: %s", strings.trim_space(expected))
		fmt.eprintfln("  actual:   %s", actual)
		fmt.eprintln("  aborting before extraction (staging artifacts removed)")
		return false
	}
	fmt.printfln("heimdall update: checksum verified (%s)", actual)

	extract_dir := fmt.tprintf("%s/extract", stage_dir)
	if os.make_directory_all(extract_dir) != nil {
		fmt.eprintfln("heimdall update: cannot create %s", extract_dir)
		return false
	}
	_, _, tar_ok := manager_run_capture({"tar", "-xzf", tarball_path, "-C", extract_dir})
	if !tar_ok {
		fmt.eprintln("heimdall update: tarball extraction failed — aborting")
		return false
	}

	bundle_bin := fmt.tprintf("%s/bin", extract_dir)
	for name in MANAGER_UPDATE_REQUIRED_BINS {
		candidate := fmt.tprintf("%s/%s", bundle_bin, name)
		if !manager_path_exists(candidate) {
			fmt.eprintfln("heimdall update: release bundle is missing bin/%s; refusing to install an incomplete bundle", name)
			return false
		}
	}
	// Validate the staged binaries actually execute on this host before the
	// service is touched (catches arch mismatch / truncated binaries).
	for name in MANAGER_UPDATE_REQUIRED_BINS {
		staged := fmt.tprintf("%s/%s", bundle_bin, name)
		_, _, run_ok := manager_run_capture({staged, "--version"})
		if !run_ok {
			fmt.eprintfln("heimdall update: staged %s does not execute (`--version` failed) — aborting before service stop", name)
			return false
		}
	}

	metadata_path := fmt.tprintf("%s/METADATA.json", extract_dir)
	if data, merr := os.read_entire_file(metadata_path, context.allocator); merr == nil {
		bundled := manager_extract_json_string(string(data), "version", "")
		delete(data)
		if bundled != "" && release.version != "" && !manager_update_versions_equal(bundled, release.version) {
			fmt.printfln("heimdall update: warning: bundle METADATA version %s does not match release %s (continuing)", bundled, release.version)
		}
	}
	return true
}

// ---- binary swap ----

// manager_update_copy_file streams src to dest (fresh file, mode 0755) in
// chunks so multi-tens-of-MB binaries never load fully into memory.
manager_update_copy_file :: proc(src, dest: string) -> bool {
	src_file, open_err := os.open(src, os.File_Flags{.Read})
	if open_err != nil do return false
	defer os.close(src_file)
	out, create_err := os.open(dest, os.File_Flags{.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	if create_err != nil do return false
	defer os.close(out)
	buf: [65536]byte
	for {
		n, rerr := os.read(src_file, buf[:])
		if n > 0 {
			written, werr := os.write(out, buf[:n])
			if werr != nil || written != n do return false
		}
		// os.read reports end-of-file as the .EOF error, not (0, nil)
		if rerr != nil do return rerr == .EOF
		if n == 0 do return true
	}
}

// manager_update_install_one atomically replaces install_dir/name with the
// staged binary: copy to a temp file in the SAME directory, then rename over
// the target (rename within one directory is atomic and cannot hit EXDEV,
// which a cross-filesystem rename from the staging dir could).
manager_update_install_one :: proc(install_dir, staged_path, name: string) -> bool {
	tmp := fmt.tprintf("%s/.heimdall-update-%s.tmp", install_dir, name)
	_ = os.remove(tmp)
	if !manager_update_copy_file(staged_path, tmp) {
		_ = os.remove(tmp)
		return false
	}
	if os.chmod(tmp, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) != nil {
		_ = os.remove(tmp)
		return false
	}
	target := fmt.tprintf("%s/%s", install_dir, name)
	if os.rename(tmp, target) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

// manager_update_install_self replaces the RUNNING heimdall: the current
// binary moves to heimdall.old, the staged binary is installed as heimdall,
// and heimdall.old is removed. On install failure the old binary is moved
// back. POSIX unlink/rename semantics keep the running process image valid
// throughout, so this procedure survives updating itself.
manager_update_install_self :: proc(install_dir, staged_path: string) -> bool {
	current := fmt.tprintf("%s/heimdall", install_dir)
	old := fmt.tprintf("%s/heimdall.old", install_dir)
	_ = os.remove(old)
	if os.rename(current, old) != nil {
		fmt.eprintfln("heimdall update: cannot move %s to heimdall.old", current)
		return false
	}
	if !manager_update_install_one(install_dir, staged_path, "heimdall") {
		fmt.eprintln("heimdall update: installing the new heimdall failed — restoring heimdall.old")
		_ = os.rename(old, current)
		return false
	}
	_ = os.remove(old)
	return true
}

// manager_update_swap_all replaces the sibling binaries and then heimdall
// itself. Returns the list of updated binary names for the summary.
manager_update_swap_all :: proc(plan: ^Manager_Update_Plan, bundle_bin: string, updated: ^[dynamic]string) -> bool {
	for name in MANAGER_UPDATE_REQUIRED_BINS {
		if name == "heimdall" do continue // self-update last
		staged := fmt.tprintf("%s/%s", bundle_bin, name)
		if !manager_update_install_one(plan.install_dir, staged, name) {
			fmt.eprintfln("heimdall update: replacing %s failed", name)
			return false
		}
		append(updated, name)
	}
	for name in MANAGER_UPDATE_OPTIONAL_BINS {
		staged := fmt.tprintf("%s/%s", bundle_bin, name)
		if !manager_path_exists(staged) do continue
		if !manager_update_install_one(plan.install_dir, staged, name) {
			fmt.eprintfln("heimdall update: replacing %s failed", name)
			return false
		}
		append(updated, name)
	}
	staged_self := fmt.tprintf("%s/heimdall", bundle_bin)
	if !manager_update_install_self(plan.install_dir, staged_self) {
		return false
	}
	append(updated, "heimdall")
	return true
}

// ---- service stop/start around the swap ----

manager_update_service_state :: proc(plan: ^Manager_Update_Plan) -> Manager_Service_State {
	if plan.runit_dir != "" {
		out, _, ok := manager_run_capture({"sv", "status", plan.runit_dir})
		defer if out != "" do delete(out)
		return manager_parse_sv_status(out, ok)
	}
	return manager_service_state(plan.platform, plan.unit, plan.label, plan.plist_path)
}

// manager_runit_verb_argv maps the lifecycle verbs onto termux-services.
// `sv down` (not a plain kill) keeps runsv from respawning the old binary while
// it is being swapped; `sv up` brings it back.
manager_runit_verb_argv :: proc(verb, runit_dir: string) -> []string {
	sv_verb: string
	switch verb {
	case "stop":
		sv_verb = "down"
	case "start":
		sv_verb = "up"
	case "restart":
		sv_verb = "restart"
	case:
		return nil
	}
	argv := make([dynamic]string, 0, 3)
	append(&argv, "sv", sv_verb, runit_dir)
	return argv[:]
}

// manager_parse_sv_status reads runit's `sv status` line, e.g.
// "run: /…/ham-bridge: (pid 123) 45s; run: log: (pid 98) 300s" or
// "down: /…/ham-bridge: 3s, normally up".
manager_parse_sv_status :: proc(out: string, ok: bool) -> Manager_Service_State {
	state := Manager_Service_State{detail = "unavailable"}
	if !ok do return state
	line := strings.trim_space(out)
	if nl := strings.index_byte(line, '\n'); nl >= 0 do line = line[:nl]
	state.loaded = strings.has_prefix(line, "run:") || strings.has_prefix(line, "down:") || strings.has_prefix(line, "finish:")
	state.active = strings.has_prefix(line, "run:")
	state.detail = "active" if state.active else "inactive"
	if i := strings.index(line, "(pid "); i >= 0 {
		rest := line[i + len("(pid "):]
		if j := strings.index_byte(rest, ')'); j > 0 {
			if pid, pok := strconv.parse_int(rest[:j], 10); pok do state.pid = pid
		}
	}
	return state
}

manager_update_service_verb :: proc(plan: ^Manager_Update_Plan, verb: string) -> bool {
	state := manager_update_service_state(plan)
	argv: []string
	if plan.runit_dir != "" {
		argv = manager_runit_verb_argv(verb, plan.runit_dir)
	} else {
		argv = manager_service_verb_argv(verb, plan.unit, plan.label, plan.plist_path, plan.platform, manager_current_uid(), state.loaded)
	}
	if len(argv) == 0 {
		fmt.eprintfln("heimdall update: no service command for %q on this platform", verb)
		return false
	}
	if _, found := manager_bin_on_path(argv[0]); !found {
		fmt.eprintfln("heimdall update: %s not found on PATH", argv[0])
		return false
	}
	_, _, ok := manager_run_capture(argv)
	return ok
}

// manager_update_stop_service stops the bridge service when it is running and
// confirms it reached the inactive state. A still-running service blocks the
// swap (fail safe: never replace binaries under a live service).
manager_update_stop_service :: proc(plan: ^Manager_Update_Plan, was_active: ^bool) -> bool {
	state := manager_update_service_state(plan)
	was_active^ = state.active
	if !state.active do return true
	fmt.printfln("heimdall update: stopping %s service (pid %d)", plan.unit, state.pid)
	if !manager_update_service_verb(plan, "stop") {
		fmt.eprintln("heimdall update: service stop failed — aborting before binary swap")
		return false
	}
	// systemctl --user stop is synchronous; poll briefly for launchd parity
	for i := 0; i < 25; i += 1 {
		state = manager_update_service_state(plan)
		if !state.active do return true
		time.sleep(200 * time.Millisecond)
	}
	fmt.eprintln("heimdall update: service did not stop in time — aborting before binary swap")
	return false
}

manager_update_start_service :: proc(plan: ^Manager_Update_Plan) -> bool {
	if !manager_update_service_verb(plan, "start") {
		return false
	}
	for i := 0; i < 25; i += 1 {
		state := manager_update_service_state(plan)
		if state.active do return true
		time.sleep(200 * time.Millisecond)
	}
	return false
}

// ---- orchestration ----

manager_update_perform :: proc(plan: ^Manager_Update_Plan) -> int {
	fmt.printfln("heimdall update: current version %s, target %s", contracts.APP_VERSION, plan.target)
	release, ok := manager_update_resolve_release(plan)
	if !ok do return 1
	// release.version is a clone only in the GitHub branch (the mirror branch
	// aliases plan.version). NOTE: defer is block-scoped in Odin — this must
	// stay the `defer if` form; `if cond do defer ...` or a braced body would
	// run the delete immediately (use-after-free below).
	defer if plan.source.kind == .GitHub do delete(release.version)
	if release.version != "" {
		if manager_update_versions_equal(release.version, contracts.APP_VERSION) {
			fmt.printfln("heimdall update: already up to date (%s)", contracts.APP_VERSION)
			return 0
		}
		fmt.printfln("heimdall update: target release: %s", release.version)
	}

	if !manager_update_prepare_stage(plan, &release) do return 1
	stage_dir := fmt.tprintf("%s/stage", plan.stage_root)
	bundle_bin := fmt.tprintf("%s/extract/bin", stage_dir)

	was_active := false
	if !manager_update_stop_service(plan, &was_active) {
		_ = os.remove_all(plan.stage_root)
		return 1
	}

	updated := make([dynamic]string, 0, 4)
	defer delete(updated)
	if !manager_update_swap_all(plan, bundle_bin, &updated) {
		// best effort: bring the service back even though the swap failed
		if was_active && manager_update_start_service(plan) {
			fmt.eprintln("heimdall update: bridge service restarted with previous binaries")
		}
		_ = os.remove_all(plan.stage_root)
		return 1
	}

	if was_active {
		fmt.printfln("heimdall update: starting %s service", plan.unit)
		if !manager_update_start_service(plan) {
			fmt.eprintln("heimdall update: binaries updated but the bridge service did not come back — check 'heimdall logs'")
			_ = os.remove_all(plan.stage_root)
			return 1
		}
		fmt.println("heimdall update: bridge service restarted")
	} else {
		fmt.println("heimdall update: bridge service was not running; start it with 'heimdall start'")
	}

	_ = os.remove_all(plan.stage_root)
	fmt.printfln("heimdall update: updated %s in %s", strings.join(updated[:], ", "), plan.install_dir)
	if release.version != "" {
		fmt.printfln("heimdall update SUCCESS: %s -> %s", contracts.APP_VERSION, release.version)
	} else {
		fmt.println("heimdall update SUCCESS: bundle applied (unversioned mirror)")
	}
	return 0
}
