package extension

// `ham-ctl extension hook <provider>` core, independent of the socket transport
// so it can be tested with a fake.
//
// Contract with the harness (REQ-EXT-CLAUDE-1, REQ-EXT-PERM-1):
//   - no bridge endpoint or agent token  → return "" without sending anything;
//   - non-permission events              → fire-and-forget with a short socket
//                                          timeout; stdout stays EMPTY (Claude
//                                          feeds SessionStart / UserPromptSubmit
//                                          stdout to the model);
//   - permission.request                 → block on agent.extension.permission
//                                          and return the provider's decision
//                                          JSON, or "" for no decision.
// Every failure fails open: "" and exit 0, never a block.
//
// Restart safety (REQ-EXT-BLK-1): the blocked hook process is the source of truth
// for its permission blocker. It picks a stable blocker_id up front and, when the
// bridge socket drops or the call fails with a transport error before the
// deadline (bridge restart), reconnects with backoff (250ms → 2s) and
// re-registers the SAME id with the remaining timeout until the deadline, so the
// bridge's in-memory blocker list rebuilds itself.

import "core:fmt"
import "core:encoding/json"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import agent_runtime "odin_test:lib/agent_runtime"

HOOK_INPUT_MAX :: 16 * 1024 * 1024

// EVENT_SOCKET_TIMEOUT_MS bounds a non-permission round trip to the bridge.
EVENT_SOCKET_TIMEOUT_MS :: 500
// PERMISSION_RELAY_TIMEOUT_MS is how long the bridge waits for a UI decision.
// The plugin's PermissionRequest hook timeout (extensions/claude-code/hooks/
// hooks.json, 330s) must stay above it plus PERMISSION_SOCKET_MARGIN_MS.
PERMISSION_RELAY_TIMEOUT_MS :: 300_000
PERMISSION_RELAY_TIMEOUT_MIN_MS :: 1_000
PERMISSION_SOCKET_MARGIN_MS :: 15_000
// PERMISSION_TIMEOUT_ENV lowers the relay wait (it is clamped to at most
// PERMISSION_RELAY_TIMEOUT_MS so the hook budget always covers it).
PERMISSION_TIMEOUT_ENV :: "HEIMDALL_EXT_PERMISSION_TIMEOUT_MS"
// Re-registration backoff after a transport failure.
PERMISSION_RETRY_BACKOFF_MIN_MS :: 250
PERMISSION_RETRY_BACKOFF_MAX_MS :: 2_000

// Send_Proc sends one bridge RPC and returns the raw response line.
Send_Proc :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (response: string, ok: bool)

Hook_Env :: struct {
	endpoint: string,
	token:    string,
	ts:       string, // RFC 3339 event time
	permission_timeout_ms: int, // 0 = PERMISSION_RELAY_TIMEOUT_MS
	// Seams for tests; nil/"" = real clock, real sleep, a fresh random id.
	now_ms:     proc() -> i64,
	sleep_ms:   proc(ms: int),
	blocker_id: string,
	ctl_bin:    string, // HEIMDALL_CTL_BIN: its absolute path also counts as ham-ctl
}

new_blocker_id :: proc() -> string {
	return fmt.aprintf("blk_%016x%08x", rand.uint64(), u32(rand.uint32()))
}

@(private = "file")
real_now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private = "file")
real_sleep_ms :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// Permission_Reply classifies an agent.extension.permission response.
Permission_Reply :: enum {
	Final, // the bridge answered (a decision, "none", or a request error)
	Retry, // transport failure or a bridge that is not ready: re-register
}

// permission_reply_kind: ok:true and bad_request are final; anything that is not
// a parseable bridge reply (socket closed mid-wait, empty read) or a transient
// error code is retried.
permission_reply_kind :: proc(response: string, ok: bool) -> Permission_Reply {
	if !ok do return .Retry
	value, err := json.parse_string(strings.trim_space(response), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return .Retry
	root, is_obj := value.(json.Object)
	if !is_obj do return .Retry
	if json_get_bool(root, "ok") do return .Final
	code := json_get_string(root, "code")
	if code == "" do code = json_get_string(json_get_object(root, "error"), "code")
	if code == "bad_request" || code == "forbidden" || code == "method_not_allowed" do return .Final
	return .Retry
}

// relay_permission blocks on agent.extension.permission for one blocker_id,
// re-registering it after transport failures until the deadline. build renders
// the event for the remaining timeout.
relay_permission :: proc(env: Hook_Env, send: Send_Proc, timeout_ms: int, build: proc(remaining_ms: int, blocker_id: string, raw: string, ts: string) -> (string, bool), raw: string, render: proc(response: string) -> string) -> string {
	now := env.now_ms if env.now_ms != nil else real_now_ms
	sleep := env.sleep_ms if env.sleep_ms != nil else real_sleep_ms
	blocker_id := env.blocker_id if env.blocker_id != "" else new_blocker_id()
	deadline := now() + i64(timeout_ms)
	backoff := PERMISSION_RETRY_BACKOFF_MIN_MS
	for {
		remaining := int(deadline - now())
		if remaining < PERMISSION_RELAY_TIMEOUT_MIN_MS do return ""
		event, ok := build(remaining, blocker_id, raw, env.ts)
		if !ok do return ""
		response, sent := send(env.endpoint, env.token, "agent.extension.permission", event, remaining + PERMISSION_SOCKET_MARGIN_MS)
		if permission_reply_kind(response, sent) == .Final do return render(response)
		if int(deadline - now()) < backoff + PERMISSION_RELAY_TIMEOUT_MIN_MS do return ""
		sleep(backoff)
		backoff = min(backoff * 2, PERMISSION_RETRY_BACKOFF_MAX_MS)
	}
}

@(private = "file")
claude_build_permission :: proc(remaining_ms: int, blocker_id: string, raw: string, ts: string) -> (string, bool) {
	mapped, err := claude_map_hook(raw, ts, remaining_ms, blocker_id)
	if err != .None || len(mapped.events) == 0 || !mapped.is_permission do return "", false
	return mapped.events[0], true
}

env_ready :: proc(env: Hook_Env) -> bool {
	return strings.trim_space(env.endpoint) != "" && strings.trim_space(env.token) != ""
}

// permission_timeout_from_env reads PERMISSION_TIMEOUT_ENV, clamped.
permission_timeout_from_env :: proc() -> int {
	raw := os.get_env(PERMISSION_TIMEOUT_ENV, context.temp_allocator)
	v, ok := strconv.parse_int(strings.trim_space(raw))
	if !ok || v <= 0 do return PERMISSION_RELAY_TIMEOUT_MS
	return clamp(v, PERMISSION_RELAY_TIMEOUT_MIN_MS, PERMISSION_RELAY_TIMEOUT_MS)
}

// hook_run maps provider's native hook JSON and delivers it. The returned string
// is exactly what ham-ctl prints to stdout ("" = print nothing).
hook_run :: proc(provider, raw: string, env: Hook_Env, send: Send_Proc) -> string {
	if !env_ready(env) do return ""
	switch provider {
	case CODEX_PROVIDER:
		timeout := env.permission_timeout_ms
		if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
		mapped, err := codex_map_hook(raw, env.ts, timeout)
		if err != .None || len(mapped.events) == 0 do return ""
		if mapped.is_permission {
			return relay_permission(env, send, timeout, codex_build_permission, raw, codex_permission_output_from_response)
		}
		_, _ = send(env.endpoint, env.token, "agent.extension.event", event_params(mapped.events[:]), EVENT_SOCKET_TIMEOUT_MS)
		return ""
	case CLAUDE_PROVIDER:
		timeout := env.permission_timeout_ms
		if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
		mapped, err := claude_map_hook(raw, env.ts, timeout)
		if err != .None || len(mapped.events) == 0 do return ""
		if mapped.is_permission {
			// A lone ham-ctl invocation is the agent talking to Heimdall itself:
			// approve it locally, with no blocker and no event.
			if claude_permission_is_ham_ctl(raw, env.ctl_bin) do return claude_permission_output("allow", "")
			return relay_permission(env, send, timeout, claude_build_permission, raw, claude_permission_output_from_response)
		}
		_, _ = send(env.endpoint, env.token, "agent.extension.event", event_params(mapped.events[:]), EVENT_SOCKET_TIMEOUT_MS)
		return ""
	case ANTIGRAVITY_PROVIDER:
		timeout := env.permission_timeout_ms
		if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
		else do timeout = min(timeout, PERMISSION_RELAY_TIMEOUT_MS)
		mapped, err := antigravity_map_hook(raw, env.ts, timeout)
		if err != .None || len(mapped.events) == 0 do return ""
		if mapped.is_permission {
			if antigravity_permission_is_ham_ctl(raw, env.ctl_bin) do return antigravity_permission_output("allow", "")
			out := relay_permission(env, send, timeout, antigravity_build_permission, raw, antigravity_permission_output_from_response)
			if out == "" do return `{"decision":"ask"}`
			return out
		}
		_, _ = send(env.endpoint, env.token, "agent.extension.event", event_params(mapped.events[:]), EVENT_SOCKET_TIMEOUT_MS)
		return ""
	}
	return ""
}

// is_ham_ctl_command reports whether a shell command is exactly one ham-ctl
// invocation of an allowlisted, side-effect-bounded verb, so it can be approved
// without asking the user.
//   - Program: only the bridge-issued ctl_bin (HEIMDALL_CTL_BIN), written as its
//     absolute path, as $HEIMDALL_CTL_BIN, or as ./bin/ham-ctl (the run-dir shim) when that
//     resolves (against the hook's cwd) to ctl_bin. A bare `ham-ctl` goes through
//     PATH and never matches; nothing matches when ctl_bin is unknown.
//   - Shape: no chaining, pipe, background, subshell, substitution, redirect,
//     brace or newline, and no `$` after the program, so `ham-ctl x && rm -rf ~`
//     never matches.
//   - Verb: HAM_CTL_AUTO_APPROVE_VERBS only. `shell run|serve` (arbitrary command
//     execution through the hub) and anything that reconfigures agents, bridges or
//     fleets (hub, agents, bridge, task-chain, ...) always ask.
is_ham_ctl_command :: proc(command, ctl_bin, cwd: string) -> bool {
	cmd := strings.trim_space(command)
	if cmd == "" || strings.trim_space(ctl_bin) == "" do return false
	for ch in cmd {
		switch ch {
		case ';', '&', '|', '`', '<', '>', '\n', '\r', '(', ')', '{', '}':
			return false
		}
	}
	fields := strings.fields(cmd, context.temp_allocator)
	if len(fields) < 2 do return false
	head := fields[0]
	for f in fields[1:] {
		if strings.contains_rune(f, '$') do return false
	}
	if !ham_ctl_head_is_ctl_bin(head, ctl_bin, cwd) do return false
	if ham_ctl_args_override_connection(fields[1:]) do return false
	group := fields[1]
	verb := fields[2] if len(fields) > 2 else ""
	for allowed in HAM_CTL_AUTO_APPROVE_VERBS {
		if allowed.group != group do continue
		if allowed.verb != "*" && allowed.verb != verb do continue
		return true
	}
	return false
}

Ham_Ctl_Verb :: struct {
	group, verb: string, // verb "*" = every verb of the group
}

// HAM_CTL_AUTO_APPROVE_VERBS: the agent's own coordination traffic with Heimdall.
// Nothing here may write something that later acts on the agent's behalf, so
// only task read/comment verbs are listed (create/update/publish change what
// other agents are asked to do). `review` always asks:
// `review post --on-behalf-of user` records a verdict as the user, and shell
// quoting makes a flag deny-list unreliable.
HAM_CTL_AUTO_APPROVE_VERBS :: [?]Ham_Ctl_Verb{
	{"chat", "read"}, {"chat", "send"},
	{"lease", "*"},
	{"task", "show"}, {"task", "fetch"}, {"task", "list"}, {"task", "comments"}, {"task", "comment"},
	{"extension", "*"}, {"search", "*"},
	{"memory", "propose"}, {"memory", "list"}, {"memory", "show"}, {"memory", "content"},
	{"agent", "start-success"},
	{"issue", "list"}, {"issue", "show"}, {"issue", "create"}, {"issue", "vote"},
}

@(private = "file")
ham_ctl_head_is_ctl_bin :: proc(head, ctl_bin, cwd: string) -> bool {
	switch head {
	case "$HEIMDALL_CTL_BIN", "\"$HEIMDALL_CTL_BIN\"":
		return true
	case agent_runtime.CTL_SHIM_INVOCATION, agent_runtime.CTL_SHIM_PATH:
		if strings.trim_space(cwd) == "" do return false
		joined, _ := filepath.join({cwd, head}, context.temp_allocator)
		clean_bin, _ := filepath.clean(ctl_bin, context.temp_allocator)
		return joined == clean_bin
	}
	clean_head, _ := filepath.clean(head, context.temp_allocator)
	clean_bin, _ := filepath.clean(ctl_bin, context.temp_allocator)
	return filepath.is_abs(head) && clean_head == clean_bin
}

// HAM_CTL_CONNECTION_FLAGS redirect where ham-ctl connects or whose identity it
// uses (e.g. `--bridge-endpoint tcp:evil:1` would send the agent token away,
// `--agent-token` would act as another agent). Never auto-approved.
HAM_CTL_CONNECTION_FLAGS :: [?]string{
	"--bridge-endpoint", "--agent-token", "--token", "--user-token",
	"--hub", "--hub-url", "--daemon-url", "--config", "--agent-mode", "--wrapper-bin",
}

// ham_ctl_args_override_connection: bash strips quotes and backslashes before
// ham-ctl sees argv, so each word is unquoted before comparing; a glob in a
// flag-like word could expand to one of the flags, so it fails safe too.
@(private = "file")
ham_ctl_args_override_connection :: proc(args: []string) -> bool {
	for f in args {
		word, _ := strings.remove_all(f, "'", context.temp_allocator)
		word, _ = strings.remove_all(word, "\"", context.temp_allocator)
		word, _ = strings.remove_all(word, "\\", context.temp_allocator)
		if !strings.has_prefix(word, "--") do continue
		if strings.contains_any(word, "*?[") do return true
		name := word
		if eq := strings.index_byte(word, '='); eq >= 0 do name = word[:eq]
		for flag in HAM_CTL_CONNECTION_FLAGS do if name == flag do return true
	}
	return false
}
