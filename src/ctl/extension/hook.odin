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

import "core:os"
import "core:strconv"
import "core:strings"

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

// Send_Proc sends one bridge RPC and returns the raw response line.
Send_Proc :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (response: string, ok: bool)

Hook_Env :: struct {
	endpoint: string,
	token:    string,
	ts:       string, // RFC 3339 event time
	permission_timeout_ms: int, // 0 = PERMISSION_RELAY_TIMEOUT_MS
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
	case CLAUDE_PROVIDER:
		timeout := env.permission_timeout_ms
		if timeout <= 0 do timeout = PERMISSION_RELAY_TIMEOUT_MS
		mapped, err := claude_map_hook(raw, env.ts, timeout)
		if err != .None || len(mapped.events) == 0 do return ""
		if mapped.is_permission {
			response, ok := send(env.endpoint, env.token, "agent.extension.permission", mapped.events[0], timeout + PERMISSION_SOCKET_MARGIN_MS)
			if !ok do return ""
			return claude_permission_output_from_response(response)
		}
		_, _ = send(env.endpoint, env.token, "agent.extension.event", claude_event_params(mapped.events[:]), EVENT_SOCKET_TIMEOUT_MS)
		return ""
	}
	return ""
}
