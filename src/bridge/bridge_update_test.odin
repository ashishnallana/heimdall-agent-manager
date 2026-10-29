package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import httpc "odin_test:lib/httpc"

// REQ-BUPD-4: bridge_update_progress_json frame serialization
@(test)
test_bridge_update_progress_json_format :: proc(t: ^testing.T) {
	frame := bridge_update_progress_json("cmd_upd_123", "brg_test", "downloading", 45, "Downloading update package")
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"bridge_update_progress\""), "type is bridge_update_progress")
	testing.expect(t, strings.contains(frame, "\"command_id\":\"cmd_upd_123\""), "command_id is correct")
	testing.expect(t, strings.contains(frame, "\"bridge_id\":\"brg_test\""), "bridge_id is correct")
	testing.expect(t, strings.contains(frame, "\"stage\":\"downloading\""), "stage is downloading")
	testing.expect(t, strings.contains(frame, "\"progress_percent\":45"), "progress_percent is 45")
	testing.expect(t, strings.contains(frame, "\"message\":\"Downloading update package\""), "message matches")
}

// ---- update tarball download (httpc) ----

@(thread_local) bridge_update_test_calls: int
@(thread_local) bridge_update_test_seen_url: string

bridge_update_test_dl_success :: proc(req: httpc.Request, dest_path: string) -> (int, httpc.Error) {
	bridge_update_test_calls += 1
	if req.method != .GET || req.max_redirects <= 0 || req.timeout_ms <= 0 do return 0, .Invalid_Url
	full, _ := httpc.build_url(req.url, allocator = context.temp_allocator)
	if req.relay_target != "" do full = req.relay_target
	bridge_update_test_seen_url = full
	if os.write_entire_file_from_string(dest_path, "release-bytes") != nil do return 0, .Io
	return 200, .None
}

bridge_update_test_dl_404 :: proc(req: httpc.Request, dest_path: string) -> (int, httpc.Error) {
	bridge_update_test_calls += 1
	return 404, .None
}

bridge_update_test_dl_timeout :: proc(req: httpc.Request, dest_path: string) -> (int, httpc.Error) {
	bridge_update_test_calls += 1
	return 0, .Timeout
}

bridge_update_test_dl_flaky :: proc(req: httpc.Request, dest_path: string) -> (int, httpc.Error) {
	bridge_update_test_calls += 1
	if bridge_update_test_calls == 1 do return 502, .None
	_ = os.write_entire_file_from_string(dest_path, "release-bytes")
	return 200, .None
}

bridge_update_test_path :: proc(label: string) -> string {
	return fmt.aprintf(
		"/tmp/ham-bridge-update-%s-%d-%d.tar.gz",
		label,
		os.get_pid(),
		time.to_unix_nanoseconds(time.now()),
	)
}

@(test)
bridge_update_download_success :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("success")
	defer { _ = os.remove(dest); delete(dest) }
	bridge_update_test_calls = 0
	ok, detail := bridge_update_download("https://github.com/example/repo/releases/download/v1/bundle.tar.gz", dest, bridge_update_test_dl_success)
	testing.expect(t, ok, detail)
	testing.expect_value(t, bridge_update_test_calls, 1)
	testing.expect_value(t, bridge_update_test_seen_url, "https://github.com/example/repo/releases/download/v1/bundle.tar.gz")
	data, read_err := os.read_entire_file(dest, context.allocator)
	defer delete(data)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(data), "release-bytes")
}

@(test)
bridge_update_download_hub_relative_target_is_forwarded :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("relative")
	defer { _ = os.remove(dest); delete(dest) }
	ok, detail := bridge_update_download("/api/v1/bridge/update/bundle?target=linux-amd64", dest, bridge_update_test_dl_success)
	testing.expect(t, ok, detail)
	testing.expect_value(t, bridge_update_test_seen_url, "/api/v1/bridge/update/bundle?target=linux-amd64")
	bad, _ := bridge_update_download("ftp://example/bundle", dest, bridge_update_test_dl_success)
	testing.expect(t, !bad, "a non-http(s) URL is refused before any transfer")
}

@(test)
bridge_update_download_reports_http_error_without_retrying_4xx :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("failure")
	defer { _ = os.remove(dest); delete(dest) }
	bridge_update_test_calls = 0
	ok, detail := bridge_update_download("https://github.com/example/repo/releases/download/v1/missing.tar.gz", dest, bridge_update_test_dl_404)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(detail, "HTTP 404"), detail)
	testing.expect_value(t, bridge_update_test_calls, 1)
	testing.expect(t, !os.exists(dest), "failed download must not publish destination")
}

@(test)
bridge_update_download_retries_transient_failures :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("flaky")
	defer { _ = os.remove(dest); delete(dest) }
	bridge_update_test_calls = 0
	ok, detail := bridge_update_download("https://github.com/example/repo/releases/download/v1/bundle.tar.gz", dest, bridge_update_test_dl_flaky)
	testing.expect(t, ok, detail)
	testing.expect_value(t, bridge_update_test_calls, 2)
}

@(test)
bridge_update_download_reports_timeout :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("timeout")
	defer { _ = os.remove(dest); delete(dest) }
	bridge_update_test_calls = 0
	ok, detail := bridge_update_download("https://github.com/example/repo/releases/download/v1/slow.tar.gz", dest, bridge_update_test_dl_timeout)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(detail, "timed out (no progress for 30 seconds"), detail)
	testing.expect_value(t, bridge_update_test_calls, BRIDGE_UPDATE_DOWNLOAD_ATTEMPTS)
}
