package bridge

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import httpc "odin_test:lib/httpc"

// A structured request seam keeps tests offline and the outbound HTTP boundary intact.
Bridge_Catalog_Get :: #type proc(req: httpc.Request) -> (body: string, ok: bool, reason: string)

bridge_catalog_http_get :: proc(req: httpc.Request) -> (body: string, ok: bool, reason: string) {
	resp, err := httpc.send(req, context.temp_allocator)
	if err != .None do return "", false, httpc.error_string(err)
	if resp.status != 200 do return "", false, fmt.tprintf("HTTP %d", resp.status)
	return string(resp.body), true, ""
}

Bridge_Catalog_Asset :: struct { name: string }
Bridge_Catalog_Release :: struct {
	tag_name: string,
	draft, prerelease: bool,
	assets: []Bridge_Catalog_Asset,
}

bridge_catalog_bundle :: proc(target, tag: string) -> string {
	ext := ".zip" if strings.has_prefix(target, "windows-") else ".tar.gz"
	return fmt.tprintf("heimdall-local-%s-%s%s", target, tag, ext)
}

// Match the desktop's VERSION_PATTERN: tags are safe single path segments.
bridge_catalog_tag_valid :: proc(tag: string) -> bool {
	if tag == "" || tag == "." || tag == ".." do return false
	for c in tag {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') do return false
	}
	return true
}

bridge_catalog_digest :: proc(sums, name: string) -> string {
	found := 0
	digest := ""
	rest := sums
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 || strings.trim_left(fields[1], "*") != name do continue
		if len(fields[0]) != 64 do return ""
		if _, ok := hex.decode(transmute([]byte)fields[0], context.temp_allocator); !ok do return ""
		digest = strings.to_lower(fields[0], context.temp_allocator)
		found += 1
	}
	return digest if found == 1 else ""
}

bridge_catalog_request :: proc(base: string, path: []string, query: []httpc.Query_Param = nil) -> httpc.Request {
	u, _ := httpc.parse_url(base)
	headers := make([]httpc.Header, 2, context.temp_allocator)
	headers[0], headers[1] = httpc.accept("application/vnd.github+json"), httpc.user_agent("ham-hub")
	return {method = .GET, url = u, path = path, query = query,
		headers = headers,
		timeout_ms = 5_000, connect_timeout_ms = 2_000, max_redirects = 5, max_response_bytes = 4 * 1024 * 1024}
}

bridge_catalog_fetch_release :: proc(get: Bridge_Catalog_Get, target, pin: string) -> (info: Bridge_Update_Info, reachable: bool) {
	info.target, info.latest_source = target, "promoted"
	req := bridge_catalog_request("https://api.github.com", {"repos", "tanmayv", "heimdall-agent-manager", "releases"}, {{"per_page", "30"}})
	if pin != "" {
		if !bridge_catalog_tag_valid(pin) {
			info.fallback_reason = "invalid operator release tag"
			return info, true
		}
		tag := pin if strings.has_prefix(pin, "v") else fmt.tprintf("v%s", pin)
		req = bridge_catalog_request("https://api.github.com", {"repos", "tanmayv", "heimdall-agent-manager", "releases", "tags", tag})
	}
	doc, ok, reason := get(req)
	if !ok {
		info.fallback_reason = fmt.tprintf("cannot resolve promoted releases: %s", reason)
		return info, false
	}
	releases: []Bridge_Catalog_Release
	if pin == "" {
		if err := json.unmarshal_string(doc, &releases, allocator = context.temp_allocator); err != nil {
			info.fallback_reason = fmt.tprintf("release source returned an invalid release list: %v", err)
			return info, false
		}
	} else {
		releases = make([]Bridge_Catalog_Release, 1, context.temp_allocator)
		if json.unmarshal_string(doc, &releases[0], allocator = context.temp_allocator) != nil {
			info.fallback_reason = "release source returned invalid release metadata"
			return info, false
		}
	}
	// GitHub lists newest promotions first, matching the desktop's latestRelease.
	for release in releases {
		if release.draft || (pin == "" && release.prerelease) || !bridge_catalog_tag_valid(release.tag_name) do continue
		if pin != "" && strings.trim_prefix(pin, "v") != strings.trim_prefix(release.tag_name, "v") do continue
		name := bridge_catalog_bundle(target, release.tag_name)
		has_bundle, has_sums := false, false
		for asset in release.assets {
			if asset.name == name do has_bundle = true
			if asset.name == "SHA256SUMS" do has_sums = true
		}
		if !has_bundle || !has_sums do continue
		path := []string{"tanmayv", "heimdall-agent-manager", "releases", "download", release.tag_name, "SHA256SUMS"}
		sums, fetched, detail := get(bridge_catalog_request("https://github.com", path))
		if !fetched {
			info.fallback_reason = fmt.tprintf("cannot fetch SHA256SUMS for %s: %s", release.tag_name, detail)
			return info, false
		}
		digest := bridge_catalog_digest(sums, name)
		if digest == "" do continue
		path[len(path)-1] = name
		bundle_req := bridge_catalog_request("https://github.com", path)
		url, url_err := httpc.build_url(bundle_req.url, bundle_req.path, allocator = context.temp_allocator)
		if url_err != .None do continue
		info.latest_version = strings.trim_prefix(release.tag_name, "v")
		info.download_url, info.sha256 = url, digest
		info.artifact_available = true
		return info, true
	}
	if pin != "" {
		info.warning = fmt.tprintf("Pinned release %s has no verified artifact for %s", pin, target)
	} else {
		info.warning = fmt.tprintf("No promoted release has a verified artifact for %s", target)
	}
	return info, true
}

Bridge_Catalog_Cache_Entry :: struct {
	at: time.Time,
	populated, reachable: bool,
	pin: string,
	info: Bridge_Update_Info,
}

bridge_catalog_copy_info :: proc(info: Bridge_Update_Info, allocator: mem.Allocator) -> Bridge_Update_Info {
	result := info
	result.target = strings.clone(info.target, allocator)
	result.latest_version = strings.clone(info.latest_version, allocator)
	result.latest_commit_sha = strings.clone(info.latest_commit_sha, allocator)
	result.latest_source = strings.clone(info.latest_source, allocator)
	result.download_url = strings.clone(info.download_url, allocator)
	result.sha256 = strings.clone(info.sha256, allocator)
	result.warning = strings.clone(info.warning, allocator)
	result.fallback_reason = strings.clone(info.fallback_reason, allocator)
	return result
}

bridge_catalog_cache_entry_destroy :: proc(entry: ^Bridge_Catalog_Cache_Entry) {
	if !entry.populated do return
	context.allocator = runtime.default_allocator()
	delete(entry.pin)
	delete(entry.info.target)
	delete(entry.info.latest_version)
	delete(entry.info.latest_commit_sha)
	delete(entry.info.latest_source)
	delete(entry.info.download_url)
	delete(entry.info.sha256)
	delete(entry.info.warning)
	delete(entry.info.fallback_reason)
	entry^ = {}
}

bridge_update_catalog_destroy :: proc(catalog: ^Bridge_Update_Catalog) {
	for &entry in catalog.cache do bridge_catalog_cache_entry_destroy(&entry)
}

bridge_catalog_release :: proc(catalog: ^Bridge_Update_Catalog, target, pin: string) -> (Bridge_Update_Info, bool) {
	if catalog == nil || catalog.release_get == nil {
		return Bridge_Update_Info{target = target, latest_source = "promoted", fallback_reason = "release source is not configured"}, false
	}
	index := -1
	targets := [7]string{"linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "termux-arm64", "windows-amd64", "windows-arm64"}
	for candidate, i in targets {
		if candidate == target do index = i * 2
	}
	if !catalog.cache_enabled || index < 0 do return bridge_catalog_fetch_release(catalog.release_get, target, pin)
	if pin != "" do index += 1
	// Serialize cold lookups as well: many bridge rows must not stampede GitHub.
	// Cold targets share this lock across bounded HTTP calls; the five-minute
	// cache includes failures so outages do not repeat the delay for every row.
	sync.mutex_lock(&catalog.cache_mutex)
	defer sync.mutex_unlock(&catalog.cache_mutex)
	entry := &catalog.cache[index]
	if entry.populated && entry.pin == pin && time.since(entry.at) < 5 * time.Minute {
		return bridge_catalog_copy_info(entry.info, context.temp_allocator), entry.reachable
	}
	info, reachable := bridge_catalog_fetch_release(catalog.release_get, target, pin)
	bridge_catalog_cache_entry_destroy(entry)
	entry^ = {at = time.now(), populated = true, reachable = reachable,
		pin = strings.clone(pin, runtime.default_allocator()), info = bridge_catalog_copy_info(info, runtime.default_allocator())}
	return info, reachable
}
