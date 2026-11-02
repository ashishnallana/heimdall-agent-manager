package main

// `ham-bridge update --version <tag|latest>`: resolve a GitHub release, download
// this target's bundle and the release's SHA256SUMS, verify the bundle, unpack it
// and hand the directory to the --bundle update path (setup transaction with
// bin.bak rollback). This is the only release resolve/download/verify code on
// the bridge side; scripts/install.sh and scripts/install.ps1 carry the minimal
// bootstrap copy needed before ham-bridge exists.
//
// "latest" picks the newest promoted release (not draft, not prerelease) that
// carries SHA256SUMS and this target's bundle. An explicit tag may name a
// prerelease (a canary candidate) but never a draft, and must carry both assets.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import httpc "odin_test:lib/httpc"

BRIDGE_RELEASE_REPO :: "tanmayv/heimdall-agent-manager"
BRIDGE_RELEASE_SUMS :: "SHA256SUMS"

// bridge_release_bundle_name is the release asset for target at tag: a zip on
// Windows (scripts/install.ps1 reads it with .NET), a tarball everywhere else.
bridge_release_bundle_name :: proc(target, tag: string, allocator := context.temp_allocator) -> string {
	ext := ".zip" if strings.has_prefix(target, "windows-") else ".tar.gz"
	return fmt.aprintf("heimdall-local-%s-%s%s", target, tag, ext, allocator = allocator)
}

// bridge_release_tag_valid matches install.sh's tag check: [A-Za-z0-9._-]+.
bridge_release_tag_valid :: proc(tag: string) -> bool {
	if tag == "" || tag == "." || tag == ".." do return false
	for c in transmute([]byte)tag {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
		case: return false
		}
	}
	return true
}

// bridge_release_select picks the release tag from a GitHub releases document
// (the list, or a single release object for an explicit tag). want is "latest"
// or a tag. err is a user-facing reason when nothing qualifies.
bridge_release_select :: proc(doc, target, want: string) -> (tag: string, err: string) {
	value, perr := json.parse_string(doc, parse_integers = true, allocator = context.temp_allocator)
	if perr != .None do return "", "GitHub did not return a release list"
	releases: [dynamic]json.Object
	releases.allocator = context.temp_allocator
	#partial switch v in value {
	case json.Array:
		for item in v {
			if obj, ok := item.(json.Object); ok do append(&releases, obj)
		}
	case json.Object:
		append(&releases, v)
	case:
		return "", "GitHub did not return a release list"
	}
	latest := want == "" || want == "latest"
	for rel in releases {
		name, _ := rel["tag_name"].(json.String)
		if !latest && name != want do continue
		draft, _ := rel["draft"].(json.Boolean)
		pre, _ := rel["prerelease"].(json.Boolean)
		if draft || (latest && pre) || !bridge_release_tag_valid(name) {
			if !latest do return "", fmt.tprintf("release %s is a draft or has an invalid tag; refusing it", want)
			continue
		}
		bundle := bridge_release_bundle_name(target, name)
		has_sums, has_bundle := false, false
		assets, _ := rel["assets"].(json.Array)
		for a in assets {
			obj, _ := a.(json.Object)
			n, _ := obj["name"].(json.String)
			if n == BRIDGE_RELEASE_SUMS do has_sums = true
			if n == bundle do has_bundle = true
		}
		if has_sums && has_bundle do return name, ""
		if !latest do return "", fmt.tprintf("release %s has no %s or %s; it cannot be verified for this machine", want, bundle, BRIDGE_RELEASE_SUMS)
	}
	if latest do return "", fmt.tprintf("no promoted release carries a %s bundle and %s", target, BRIDGE_RELEASE_SUMS)
	return "", fmt.tprintf("release %s not found", want)
}

// bridge_release_expected_sha256 returns the digest SHA256SUMS lists for name.
// Exactly one well-formed entry must match (a leading '*' binary marker and
// CRLF line ends are accepted), as in install.sh.
bridge_release_expected_sha256 :: proc(sums, name: string) -> (digest: string, ok: bool) {
	found := 0
	rest := sums
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(strings.trim_right(line, "\r"), context.temp_allocator)
		if len(fields) != 2 do continue
		if strings.trim_left(fields[1], "*") != name do continue
		if len(fields[0]) != 64 do return "", false
		if _, hex_ok := hex.decode(transmute([]byte)fields[0], context.temp_allocator); !hex_ok do return "", false
		digest = strings.to_lower(fields[0], context.temp_allocator)
		found += 1
	}
	return digest, found == 1
}

// bridge_release_verify_file checks path against the SHA256SUMS entry for name.
bridge_release_verify_file :: proc(path, sums, name: string) -> (ok: bool, detail: string) {
	expected, listed := bridge_release_expected_sha256(sums, name)
	if !listed do return false, fmt.tprintf("%s does not list %s exactly once", BRIDGE_RELEASE_SUMS, name)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return false, fmt.tprintf("cannot read %s", path)
	defer delete(data)
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	actual := string(hex.encode(digest[:], context.temp_allocator))
	if actual != expected do return false, fmt.tprintf("SHA-256 mismatch for %s (expected %s, got %s)", name, expected, actual)
	return true, ""
}

// Bridge_Release_Get fetches a small document (release list, SHA256SUMS); tests
// script it. download is the bundle transport (bridge_update_download's seam).
Bridge_Release_Get :: #type proc(url: string) -> (body: string, ok: bool, detail: string)

bridge_release_http_get :: proc(url: string) -> (body: string, ok: bool, detail: string) {
	u, uerr := httpc.parse_url(url)
	if uerr != .None do return "", false, "invalid URL"
	req := httpc.Request{
		method = .GET, url = u, timeout_ms = 60_000, connect_timeout_ms = 15_000,
		max_redirects = BRIDGE_UPDATE_DOWNLOAD_MAX_REDIRECTS,
		headers = {httpc.accept("application/vnd.github+json"), httpc.user_agent("ham-bridge")},
	}
	resp, err := bridge_hub_http_send_alloc(req, context.temp_allocator)
	if err != .None do return "", false, httpc.error_string(err)
	if resp.status != 200 do return "", false, fmt.tprintf("HTTP %d", resp.status)
	return string(resp.body), true, ""
}

// bridge_release_fetch resolves want, downloads and verifies this target's
// bundle into work_dir and unpacks it under work_dir/bundle. Nothing outside
// work_dir is touched; any failure leaves the install as it was.
bridge_release_fetch :: proc(
	want, target, work_dir: string,
	get: Bridge_Release_Get = bridge_release_http_get,
	download: Bridge_Update_Download = httpc.download_to_file,
) -> (bundle_dir: string, tag: string, err: string) {
	if want != "latest" && !bridge_release_tag_valid(want) do return "", "", fmt.tprintf("invalid release tag %q", want)
	api := fmt.tprintf("https://api.github.com/repos/%s/releases", BRIDGE_RELEASE_REPO)
	url := fmt.tprintf("%s?per_page=30", api) if want == "latest" else fmt.tprintf("%s/tags/%s", api, want)
	doc, ok, detail := get(url)
	if !ok do return "", "", fmt.tprintf("cannot list releases (%s)", detail)
	tag, err = bridge_release_select(doc, target, want)
	if err != "" do return "", "", err
	base := fmt.tprintf("https://github.com/%s/releases/download/%s", BRIDGE_RELEASE_REPO, tag)
	sums: string
	sums, ok, detail = get(fmt.tprintf("%s/%s", base, BRIDGE_RELEASE_SUMS))
	if !ok do return "", tag, fmt.tprintf("cannot download %s for %s (%s)", BRIDGE_RELEASE_SUMS, tag, detail)
	name := bridge_release_bundle_name(target, tag)
	if _, listed := bridge_release_expected_sha256(sums, name); !listed {
		return "", tag, fmt.tprintf("%s of %s does not list %s exactly once; refusing an unverifiable bundle", BRIDGE_RELEASE_SUMS, tag, name)
	}
	archive := fmt.tprintf("%s/%s", work_dir, name)
	if dl_ok, dl_err := bridge_update_download(fmt.tprintf("%s/%s", base, name), archive, download); !dl_ok {
		return "", tag, dl_err
	}
	if v_ok, v_err := bridge_release_verify_file(archive, sums, name); !v_ok {
		_ = os.remove(archive)
		return "", tag, fmt.tprintf("%s; nothing was changed", v_err)
	}
	bundle_dir = fmt.tprintf("%s/bundle", work_dir)
	if bridge_make_directory_all(bundle_dir) != nil do return "", tag, fmt.tprintf("cannot create %s", bundle_dir)
	// bsdtar (macOS, Windows 10+ tar.exe) and GNU tar both read the tarball; bsdtar the zip.
	out, errout, ran, _ := bridge_process_run_capture({"tar", "-xf", archive, "-C", bundle_dir}, 120 * time.Second)
	defer {delete(out); delete(errout)}
	if !ran do return "", tag, fmt.tprintf("cannot unpack %s: %s", name, strings.trim_space(errout))
	return bundle_dir, tag, ""
}
