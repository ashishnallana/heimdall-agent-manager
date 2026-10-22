package extension

import "core:strings"
import "core:testing"

// REQ-EXT-BLK-1: a blocked PermissionRequest hook re-registers the SAME
// blocker_id with the remaining timeout after the bridge socket drops (bridge
// restart), with 250ms → 2s backoff, until its deadline.
//
// One test proc on purpose: the fake transport and clock are package globals and
// tests run in parallel threads.

@(private = "file")
rr_now: i64
@(private = "file")
rr_sleeps: [dynamic]int
@(private = "file")
rr_params: [dynamic]string
@(private = "file")
rr_script: []string // per call: "" = transport failure, else the response line

@(private = "file")
rr_reset :: proc(script: []string) {
	rr_now = 1_000_000
	clear(&rr_sleeps)
	clear(&rr_params)
	rr_script = script
}

@(private = "file")
rr_now_ms :: proc() -> i64 { return rr_now }

@(private = "file")
rr_sleep :: proc(ms: int) {
	append(&rr_sleeps, ms)
	rr_now += i64(ms)
}

@(private = "file")
rr_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	i := len(rr_params)
	append(&rr_params, strings.clone(params))
	// Each failed attempt costs some time (connect + the dropped read).
	rr_now += 100
	if i >= len(rr_script) || rr_script[i] == "" do return "", false
	return rr_script[i], true
}

@(private = "file")
rr_env :: proc(timeout_ms: int) -> Hook_Env {
	return Hook_Env{endpoint = "unix:/tmp/x.sock", token = "tok", ts = "2026-10-22T06:00:00Z", permission_timeout_ms = timeout_ms, now_ms = rr_now_ms, sleep_ms = rr_sleep}
}

@(private = "file")
rr_payload_int :: proc(params, key: string) -> int {
	i := strings.index(params, strings.concatenate({`"`, key, `":`}, context.temp_allocator))
	if i < 0 do return -1
	rest := params[i + len(key) + 3:]
	n := 0
	for ch in rest {
		if ch < '0' || ch > '9' do break
		n = n * 10 + int(ch - '0')
	}
	return n
}

@(test)
test_hook_permission_reregisters_same_blocker_after_disconnect :: proc(t: ^testing.T) {
	raw := #load("testdata/claude/permission_request.json", string)
	allow := `{"v":1,"id":"1","ok":true,"data":{"request_id":"x","decision":"allow","message":""}}`

	// 1. Two dropped connections (bridge restarting), then the decision.
	script1 := []string{"", "", allow}
	rr_reset(script1)
	out := hook_run("claude", raw, rr_env(10_000), rr_send)
	testing.expect(t, strings.contains(out, `"behavior":"allow"`), out)
	testing.expect_value(t, len(rr_params), 3)
	testing.expect_value(t, len(rr_sleeps), 2)
	if len(rr_sleeps) == 2 {
		testing.expect_value(t, rr_sleeps[0], 250)
		testing.expect_value(t, rr_sleeps[1], 500)
	}
	if len(rr_params) == 3 {
		first := rr_params[0]
		bi := strings.index(first, `"blocker_id":"blk_`)
		testing.expectf(t, bi >= 0, "blocker_id missing: %s", first)
		if bi >= 0 {
			id := first[bi:bi + len(`"blocker_id":"blk_`) + 24 + 1]
			for p in rr_params[1:] do testing.expectf(t, strings.contains(p, id), "re-registration changed the id: %s", p)
		}
		// The remaining timeout shrinks with every attempt.
		t0 := rr_payload_int(rr_params[0], "timeout_ms")
		t2 := rr_payload_int(rr_params[2], "timeout_ms")
		testing.expect_value(t, t0, 10_000)
		testing.expect(t, t2 > 0 && t2 < t0, "remaining timeout must shrink")
	}

	// 2. A bridge that never comes back: retries stop at the deadline, backoff caps at 2s.
	rr_reset(nil)
	out = hook_run("claude", raw, rr_env(12_000), rr_send)
	testing.expect_value(t, out, "")
	testing.expect(t, len(rr_params) >= 4, "keeps retrying until the deadline")
	for s in rr_sleeps do testing.expect(t, s <= PERMISSION_RETRY_BACKOFF_MAX_MS)
	testing.expect(t, rr_now <= 1_000_000 + 12_000 + 200, "never runs past the hook deadline")

	// 3. Final replies stop at once: "none" (no decision) and bad_request.
	none := `{"v":1,"id":"1","ok":true,"data":{"decision":"none"}}`
	script3 := []string{none}
	rr_reset(script3)
	testing.expect_value(t, hook_run("claude", raw, rr_env(10_000), rr_send), "")
	testing.expect_value(t, len(rr_params), 1)
	bad := `{"v":1,"id":"1","ok":false,"error":{"code":"bad_request","message":"nope"}}`
	script4 := []string{bad}
	rr_reset(script4)
	testing.expect_value(t, hook_run("claude", raw, rr_env(10_000), rr_send), "")
	testing.expect_value(t, len(rr_params), 1)
	testing.expect_value(t, permission_reply_kind(`{"ok":false,"error":{"code":"hub_unreachable"}}`, true), Permission_Reply.Retry)
	testing.expect_value(t, permission_reply_kind("", true), Permission_Reply.Retry)

	// 4. A caller-pinned id is used verbatim.
	script5 := []string{allow}
	rr_reset(script5)
	env := rr_env(10_000)
	env.blocker_id = "blk_pinned"
	_ = hook_run("claude", raw, env, rr_send)
	if len(rr_params) == 1 do testing.expect(t, strings.contains(rr_params[0], `"blocker_id":"blk_pinned"`), rr_params[0])
}
