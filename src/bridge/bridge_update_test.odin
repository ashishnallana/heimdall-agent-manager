package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import httpc "odin_test:lib/httpc"

bridge_update_test_spawn_args: [dynamic]string

bridge_update_test_capture_spawn :: proc(argv: []string) -> bool {
	for arg in argv do append(&bridge_update_test_spawn_args, strings.clone(arg))
	return true
}

bridge_update_test_clear_spawn_args :: proc() {
	for arg in bridge_update_test_spawn_args do delete(arg)
	delete(bridge_update_test_spawn_args)
}

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

// REQ-BUPD-FIX-5: update launch is an injectable argv boundary. This pins the
// exact process identity forwarded to the supervisor without running the script.
@(test)
test_bridge_update_supervisor_launch_uses_structured_argv_and_exact_pid :: proc(t: ^testing.T) {
	bridge_update_test_clear_spawn_args()
	defer bridge_update_test_clear_spawn_args()

	ok := bridge_update_launch_supervisor(
		"/tmp/update scripts/apply-bridge-update.sh",
		"/tmp/data dir",
		"/tmp/stage dir",
		"49323",
		"https://hub.example.test/path?value=one&next=two",
		"424242",
		bridge_update_test_capture_spawn,
		"/tmp/bridge with spaces/pty-host.sock",
	)
	testing.expect(t, ok, "injected supervisor launcher succeeds")
	testing.expect_value(t, len(bridge_update_test_spawn_args), 14)
	if len(bridge_update_test_spawn_args) != 14 do return
	testing.expect_value(t, bridge_update_test_spawn_args[0], "bash")
	testing.expect_value(t, bridge_update_test_spawn_args[1], "/tmp/update scripts/apply-bridge-update.sh")
	testing.expect_value(t, bridge_update_test_spawn_args[3], "/tmp/data dir")
	testing.expect_value(t, bridge_update_test_spawn_args[5], "/tmp/stage dir")
	testing.expect_value(t, bridge_update_test_spawn_args[7], "49323")
	testing.expect_value(t, bridge_update_test_spawn_args[9], "https://hub.example.test/path?value=one&next=two")
	testing.expect_value(t, bridge_update_test_spawn_args[10], "--bridge-pid")
	testing.expect_value(t, bridge_update_test_spawn_args[11], "424242")
	testing.expect_value(t, bridge_update_test_spawn_args[12], "--pty-host-socket")
	testing.expect_value(t, bridge_update_test_spawn_args[13], "/tmp/bridge with spaces/pty-host.sock")
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

// The PTY-host cleanup failure must say why it failed, not only that it did:
// a missing interpreter (exit 127) and a timeout are different operator actions.
@(test)
test_bridge_update_pty_stop_failure_reports_cause :: proc(t: ^testing.T) {
	missing := bridge_update_pty_stop_failure(127, false, "bash: line 1: python3: command not found\n")
	testing.expect_value(t, missing, "failed to stop bridge-owned PTY host (exit 127: bash: line 1: python3: command not found); update aborted before restart")

	survivors := bridge_update_pty_stop_failure(1, false, "[apply-bridge-update] stopping bridge-owned PTY processes: 42\nBridge-owned PTY processes did not stop; refusing binary swap.\n\n")
	testing.expect_value(t, survivors, "failed to stop bridge-owned PTY host (exit 1: Bridge-owned PTY processes did not stop; refusing binary swap.); update aborted before restart")

	timed_out := bridge_update_pty_stop_failure(-1, true, "partial output")
	testing.expect_value(t, timed_out, "failed to stop bridge-owned PTY host: cleanup timed out; update aborted before restart")

	silent := bridge_update_pty_stop_failure(3, false, "  \n")
	testing.expect_value(t, silent, "failed to stop bridge-owned PTY host (exit 3); update aborted before restart")

	// Bounded, and never split inside a UTF-8 sequence.
	long := strings.concatenate({strings.repeat("a", BRIDGE_UPDATE_PTY_STOP_DETAIL_LIMIT - 1, context.temp_allocator), "é tail"}, context.temp_allocator)
	bounded := bridge_update_pty_stop_failure(1, false, long)
	expected := fmt.tprintf("failed to stop bridge-owned PTY host (exit 1: %s); update aborted before restart", strings.repeat("a", BRIDGE_UPDATE_PTY_STOP_DETAIL_LIMIT - 1, context.temp_allocator))
	testing.expect_value(t, bounded, expected)
}
