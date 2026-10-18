package bridge

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

Bridge_Manifest_Target_Wire :: struct {
	tarball_url: string `json:"tarball_url"`,
	sha256:      string `json:"sha256"`,
}

Bridge_Update_Manifest_Wire :: struct {
	version:    string                                 `json:"version"`,
	commit_sha: string                                 `json:"commit_sha"`,
	targets:    map[string]Bridge_Manifest_Target_Wire `json:"targets"`,
}

Bridge_Update_Target :: struct {
	tarball_url: string,
	sha256:      string,
}

Bridge_Update_Info :: struct {
	update_available:  bool,
	latest_version:    string,
	latest_commit_sha: string,
	target:            string,
	download_url:      string,
	sha256:            string,
	// artifact_available is false when the catalog has no verified bundle for
	// target (REQ-T13-2). There is never a fallback to another target: a
	// termux-arm64 bridge given the glibc linux-arm64 bundle cannot start.
	artifact_available: bool,
}

Bridge_Update_Catalog :: struct {
	manifest_path:         string,
	override_version:      string,
	override_commit_sha:   string,
	override_download_url: string,
	override_sha256:       string,
}

normalize_bridge_target :: proc(os_name, arch_name: string) -> string {
	os_clean := strings.to_lower(strings.trim_space(os_name), context.temp_allocator)
	arch_clean := strings.to_lower(strings.trim_space(arch_name), context.temp_allocator)
	if arch_clean == "x86_64" do arch_clean = "amd64"
	if arch_clean == "aarch64" do arch_clean = "arm64"
	if os_clean == "" do os_clean = "linux"
	if arch_clean == "" do arch_clean = "amd64"
	return fmt.tprintf("%s-%s", os_clean, arch_clean)
}

// canonical_bridge_platform makes the bridge hello's `target` field the
// authoritative machine identity. Released bridges already send this field,
// while older clients may still send separate os/arch values. Only targets for
// which release artifacts exist are accepted; display strings such as
// "Linux 6.18.49 amd64" must never become artifact lookup keys.
//
// termux-* is its own platform (os "termux"), not linux: the Termux bundle is
// a static-musl build and the glibc linux-* bundle dies under Android's
// seccomp filter, so the stored machine_os must keep the two apart.
canonical_bridge_platform :: proc(os_name, arch_name, target: string) -> (canonical_os, canonical_arch: string, ok: bool) {
	candidate := strings.to_lower(strings.trim_space(target), context.temp_allocator)
	if candidate == "" {
		candidate = normalize_bridge_target(os_name, arch_name)
	}
	switch candidate {
	case "linux-amd64", "linux-x86_64":
		return "linux", "amd64", true
	case "linux-arm64", "linux-aarch64":
		return "linux", "arm64", true
	case "darwin-amd64", "darwin-x86_64":
		return "darwin", "amd64", true
	case "darwin-arm64", "darwin-aarch64":
		return "darwin", "arm64", true
	case "termux-arm64", "termux-aarch64":
		return "termux", "arm64", true
	case "windows-amd64", "windows-x86_64":
		return "windows", "amd64", true
	case "windows-arm64", "windows-aarch64":
		return "windows", "arm64", true
	}
	return "", "", false
}

parse_semver_part :: proc(s: string) -> (int, bool) {
	clean := strings.trim_space(s)
	if strings.has_prefix(clean, "v") || strings.has_prefix(clean, "V") {
		clean = clean[1:]
	}
	digit_len := 0
	for i := 0; i < len(clean); i += 1 {
		if clean[i] >= '0' && clean[i] <= '9' {
			digit_len += 1
		} else {
			break
		}
	}
	if digit_len == 0 do return 0, false
	val, ok := strconv.parse_int(clean[:digit_len], 10)
	return val, ok
}

compare_semver :: proc(v1, v2: string) -> int {
	v1_clean := strings.trim_space(v1)
	if strings.has_prefix(v1_clean, "v") || strings.has_prefix(v1_clean, "V") {
		v1_clean = v1_clean[1:]
	}
	v2_clean := strings.trim_space(v2)
	if strings.has_prefix(v2_clean, "v") || strings.has_prefix(v2_clean, "V") {
		v2_clean = v2_clean[1:]
	}
	if v1_clean == v2_clean do return 0

	p1 := strings.split(v1_clean, ".", context.temp_allocator)
	p2 := strings.split(v2_clean, ".", context.temp_allocator)

	for i := 0; i < 3; i += 1 {
		num1 := 0
		ok1 := false
		if i < len(p1) {
			num1, ok1 = parse_semver_part(p1[i])
		}
		num2 := 0
		ok2 := false
		if i < len(p2) {
			num2, ok2 = parse_semver_part(p2[i])
		}
		if ok1 && ok2 {
			if num1 < num2 do return -1
			if num1 > num2 do return 1
		} else if ok1 && !ok2 {
			if num1 > 0 do return 1
		} else if !ok1 && ok2 {
			if num2 > 0 do return -1
		}
	}
	return 0
}

is_bridge_update_available :: proc(bridge_version, bridge_commit, latest_version, latest_commit: string) -> bool {
	if latest_version == "" do return false
	if bridge_version == "" do return true
	cmp := compare_semver(bridge_version, latest_version)
	if cmp < 0 do return true
	if cmp > 0 do return false

	if bridge_version != latest_version do return true

	if latest_commit != "" && bridge_commit != "" && bridge_commit != latest_commit {
		return true
	}
	return false
}

resolve_bridge_update_info :: proc(catalog: ^Bridge_Update_Catalog, bridge: domain.Bridge) -> Bridge_Update_Info {
	target := normalize_bridge_target(bridge.machine_os, bridge.machine_arch)
	latest_version := contracts.APP_VERSION
	latest_commit_sha := contracts.GIT_COMMIT
	// There is deliberately no synthetic fallback URL. The Hub has never served
	// /api/v1/updates/bundle/*, so inventing that path turns missing target
	// metadata into a late Bridge-side 404. A catalog miss stays empty and is
	// rejected before dispatch by send_bridge_update.
	download_url := ""
	sha256 := ""

	manifest_path := ""
	if catalog != nil {
		if catalog.override_version != "" do latest_version = catalog.override_version
		if catalog.override_commit_sha != "" do latest_commit_sha = catalog.override_commit_sha
		if catalog.override_download_url != "" do download_url = catalog.override_download_url
		if catalog.override_sha256 != "" do sha256 = catalog.override_sha256
		manifest_path = catalog.manifest_path
	}

	env_path := os.get_env("HEIMDALL_UPDATE_MANIFEST_PATH", context.allocator)
	defer if env_path != "" do delete(env_path)
	if manifest_path == "" && env_path != "" {
		manifest_path = env_path
	}
	if manifest_path != "" && os.exists(manifest_path) {
		if data, err := os.read_entire_file(manifest_path, context.temp_allocator); err == nil {
			manifest_text := string(data)
			manifest: Bridge_Update_Manifest_Wire
			if json_err := json.unmarshal_string(manifest_text, &manifest, json.DEFAULT_SPECIFICATION, context.temp_allocator); json_err == nil {
				if manifest.version != "" && (catalog == nil || catalog.override_version == "") {
					latest_version = manifest.version
				}
				if manifest.commit_sha != "" && (catalog == nil || catalog.override_commit_sha == "") {
					latest_commit_sha = manifest.commit_sha
				}
				if manifest.targets != nil {
					if target_info, ok := manifest.targets[target]; ok {
						if target_info.tarball_url != "" && (catalog == nil || catalog.override_download_url == "") {
							download_url = target_info.tarball_url
						}
						if target_info.sha256 != "" && (catalog == nil || catalog.override_sha256 == "") {
							sha256 = target_info.sha256
						}
					}
				}
			}
		}
	}

	// update_available still means "a newer release exists"; artifact_available
	// says whether that release can be installed on this target. Together they
	// let the UI say "not available for this target" instead of "up to date".
	artifact_available := strings.trim_space(download_url) != "" && strings.trim_space(sha256) != ""
	avail := is_bridge_update_available(bridge.version, bridge.commit_sha, latest_version, latest_commit_sha)

	return Bridge_Update_Info{
		update_available = avail,
		latest_version = latest_version,
		latest_commit_sha = latest_commit_sha,
		target = target,
		download_url = download_url,
		sha256 = sha256,
		artifact_available = artifact_available,
	}
}
