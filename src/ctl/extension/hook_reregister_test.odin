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
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
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

	// Codex uses the same retry contract with its own renderer; no local
	// ham-ctl exception, even when the native command is a coordination call.
	codex_raw := `{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"$HEIMDALL_CTL_BIN chat read"}}`
	codex_script := []string{"", allow}
	rr_reset(codex_script)
	env = rr_env(10_000)
	env.blocker_id = "blk_codex_stable"
	env.ctl_bin = "/issued/ham-ctl"
	testing.expect(t, strings.contains(hook_run("codex", codex_raw, env, rr_send), `"behavior":"allow"`))
	testing.expect_value(t, len(rr_params), 2)
	for p in rr_params {
		testing.expect(t, strings.contains(p, `"blocker_id":"blk_codex_stable"`))
		testing.expect(t, strings.contains(p, `"provider":"codex"`))
	}
	rr_reset(nil)
	testing.expect_value(t, hook_run("codex", codex_raw, rr_env(12_000), rr_send), "")
	for reply in ([]string{none, bad, `{"ok":true,"data":{"decision":"deny","message":"no"}}`}) {
		script := []string{reply}
		rr_reset(script)
		result := hook_run("codex", codex_raw, rr_env(10_000), rr_send)
		testing.expect_value(t, len(rr_params), 1)
		if strings.contains(reply, `"deny"`) {
			testing.expect(t, strings.contains(result, `"behavior":"deny"`))
		} else {
			testing.expect_value(t, result, "")
		}
	}

	// 5. Antigravity (REQ-EXT-AGY-3): PreToolUse permission relay, stable blocker_id,
	// backoff retry on disconnect, and fallback to {"decision":"ask"}.
	agy_raw := `{"hookEventName":"PreToolUse","conversationId":"s_agy","permissionMode":"ask","stepIdx":4,"toolCall":{"name":"run_command","args":{"CommandLine":"curl https://evil.com","Cwd":"/repo"}}}`
	agy_script := []string{"", "", allow}
	rr_reset(agy_script)
	env = rr_env(10_000)
	env.blocker_id = "blk_agy_stable"
	env.ctl_bin = "/issued/ham-ctl"
	agy_out := hook_run("antigravity", agy_raw, env, rr_send)
	testing.expect_value(t, agy_out, `{"decision":"allow"}`)
	testing.expect_value(t, len(rr_params), 3)
	testing.expect_value(t, len(rr_sleeps), 2)
	if len(rr_sleeps) == 2 {
		testing.expect_value(t, rr_sleeps[0], 250)
		testing.expect_value(t, rr_sleeps[1], 500)
	}
	for p in rr_params {
		testing.expect(t, strings.contains(p, `"blocker_id":"blk_agy_stable"`))
		testing.expect(t, strings.contains(p, `"provider":"antigravity"`))
	}
	t0_agy := rr_payload_int(rr_params[0], "timeout_ms")
	t2_agy := rr_payload_int(rr_params[2], "timeout_ms")
	testing.expect_value(t, t0_agy, 10_000)
	testing.expect(t, t2_agy > 0 && t2_agy < t0_agy, "remaining timeout must shrink")

	// Antigravity fallback to {"decision":"ask"} when transport never recovers
	rr_reset(nil)
	testing.expect_value(t, hook_run("antigravity", agy_raw, rr_env(12_000), rr_send), `{"decision":"ask"}`)

	// Bridge returns deny with custom reason
	deny_reply := `{"ok":true,"data":{"decision":"deny","message":"forbidden operation"}}`
	rr_reset([]string{deny_reply})
	testing.expect_value(t, hook_run("antigravity", agy_raw, rr_env(10_000), rr_send), `{"decision":"deny","reason":"forbidden operation"}`)

	// Bridge returns deny without message: defaults to "Denied in Heimdall"
	deny_no_msg := `{"ok":true,"data":{"decision":"deny"}}`
	rr_reset([]string{deny_no_msg})
	testing.expect_value(t, hook_run("antigravity", agy_raw, rr_env(10_000), rr_send), `{"decision":"deny","reason":"Denied in Heimdall"}`)

	// Bridge returns none or error: falls back to {"decision":"ask"}
	for reply in ([]string{none, bad}) {
		script := []string{reply}
		rr_reset(script)
		result := hook_run("antigravity", agy_raw, rr_env(10_000), rr_send)
		testing.expect_value(t, len(rr_params), 1)
		testing.expect_value(t, result, `{"decision":"ask"}`)
	}

	// Local ham-ctl auto-approval: allowlisted coordination command approves locally with 0 bridge calls
	agy_ham_ctl := `{"hookEventName":"PreToolUse","conversationId":"s_agy","permissionMode":"ask","stepIdx":5,"toolCall":{"name":"run_command","args":{"CommandLine":"$HEIMDALL_CTL_BIN chat read","Cwd":"/repo"}}}`
	rr_reset([]string{deny_reply})
	testing.expect_value(t, hook_run("antigravity", agy_ham_ctl, env, rr_send), `{"decision":"allow"}`)
	testing.expect_value(t, len(rr_params), 0)
}
