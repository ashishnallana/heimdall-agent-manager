package main

// `ham-ctl extension` — the harness-extension surface (REQ-EXT-CLAUDE-1).
//
//   extension hook <provider>   native hook JSON on stdin → ham.ext.v1 → bridge
//   extension event --stdin     canonical ham.ext.v1 event(s) on stdin → bridge
//   extension status            agent.extension.status for this instance
//
// `hook` and `event` run inside the provider's hook processes, so they never
// block it: with no HEIMDALL_* env they exit 0 silently, non-permission RPCs use
// a 500ms socket timeout without the hub-retry loop, and every failure exits 0.
// Provider mapping lives in src/ctl/extension/<provider>.odin.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import local_socket "odin_test:lib/local_socket"
import ext "extension"

ctl_extension_command :: proc(cmd: []string, args: []string) {
	verb := cmd[1] if len(cmd) > 1 else ""
	if verb == "" || verb == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_help_extension()
		return
	}
	env := ext.Hook_Env{
		endpoint = agent_mode_endpoint(args),
		token = agent_mode_token(args),
		ctl_bin = os.get_env_alloc("HEIMDALL_CTL_BIN", context.temp_allocator),
	}
	switch verb {
	case "hook":
		if !ext.env_ready(env) do return
		provider := cmd[2] if len(cmd) > 2 else ""
		raw, ok := ctl_extension_read_stdin()
		if !ok do return
		env.ts = ctl_extension_now_rfc3339()
		env.permission_timeout_ms = ext.permission_timeout_from_env()
		out := ext.hook_run(provider, raw, env, ctl_extension_send)
		if out != "" do fmt.println(out)
	case "event":
		if !ext.env_ready(env) do return
		if !has_flag(args, "--stdin") {
			fmt.eprintln("ham-ctl extension event: pass the ham.ext.v1 event(s) on stdin with --stdin")
			return
		}
		raw, ok := ctl_extension_read_stdin()
		if !ok || strings.trim_space(raw) == "" do return
		response, sent := ctl_extension_send(env.endpoint, env.token, "agent.extension.event", strings.trim_space(raw), ext.EVENT_SOCKET_TIMEOUT_MS)
		if sent do fmt.println(strings.trim_space(response))
	case "status":
		if !ext.env_ready(env) {
			fmt.println(`{"ok":false,"message":"extension status requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
			os.exit(1)
		}
		ctl_agent_call(env.endpoint, env.token, "agent.extension.status", "{}")
	case:
		print_help_extension()
		os.exit(2)
	}
}

// ctl_extension_read_stdin reads fd 0 directly. Opening /dev/stdin (as the other
// --stdin verbs do) fails when stdin is a socket, which is what Node-based
// harnesses such as Claude Code hand their hook processes.
ctl_extension_read_stdin :: proc() -> (string, bool) {
	out := make([dynamic]byte, 0, 64 * 1024)
	buf: [64 * 1024]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 do append(&out, ..buf[:n])
		if len(out) > ext.HOOK_INPUT_MAX do return "", false
		if err != nil || n <= 0 do break
	}
	return string(out[:]), true
}

ctl_extension_now_rfc3339 :: proc() -> string {
	now := time.now()
	y, mon, d := time.date(now)
	h, mi, s := time.clock(now)
	ms := (time.time_to_unix_nano(now) / 1_000_000) % 1000
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mon), d, h, mi, s, ms)
}

// ctl_extension_send is ext.Send_Proc over the local bridge endpoint with a hard
// receive timeout and NO hub_unreachable retry (unlike ctl_agent_local_call).
ctl_extension_send :: proc(endpoint, token, method, params: string, timeout_ms: int) -> (string, bool) {
	line := ctl_agent_jsonl_request(token, method, params)
	timeout := time.Duration(timeout_ms) * time.Millisecond
	if strings.has_prefix(endpoint, "unix:") {
		path := strings.trim_prefix(endpoint, "unix:")
		if strings.trim_space(path) == "" || !local_socket.path_fits(path) do return "", false
		sock, ok := local_socket.dial(path)
		if !ok do return "", false
		defer local_socket.close(sock)
		_ = local_socket.set_recv_timeout(sock, timeout)
		if local_socket.send(sock, transmute([]byte)line) < 0 do return "", false
		return ctl_agent_recv_unix(sock)
	}
	if strings.has_prefix(endpoint, "tcp:") {
		parts := strings.split(endpoint, ":", context.temp_allocator)
		if len(parts) != 3 do return "", false
		port, port_ok := strconv_parse_int_agent(parts[2])
		if !port_ok do return "", false
		address := net.IP4_Loopback
		if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
		socket, err := net.dial_tcp(address, int(port))
		if err != nil do return "", false
		defer net.close(socket)
		_ = net.set_option(socket, .Receive_Timeout, timeout)
		_ = net.set_option(socket, .Send_Timeout, timeout)
		if _, send_err := net.send_tcp(socket, transmute([]byte)line); send_err != nil do return "", false
		return ctl_agent_recv_tcp(socket)
	}
	return "", false
}

print_help_extension :: proc() {
	fmt.println("ham-ctl extension — harness extension bridge (provider hooks → ham.ext.v1)")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  hook <provider>    Read the provider's native hook JSON on stdin, map it to")
	fmt.println("                     ham.ext.v1 and send it to the local Bridge. Providers: claude, codex.")
	fmt.println("                     PermissionRequest blocks on agent.extension.permission and")
	fmt.println("                     prints the provider's allow/deny JSON (nothing = no decision).")
	fmt.println("                     Every other event prints nothing (500ms socket timeout).")
	fmt.println("  event --stdin      Send canonical ham.ext.v1 event(s) on stdin (one object or")
	fmt.println("                     {\"events\":[…]}) via agent.extension.event; prints the reply.")
	fmt.println("  status             Show agent.extension.status for this instance (provider,")
	fmt.println("                     version, capabilities, counters, activity source).")
	fmt.println("")
	fmt.println("Outside a Heimdall-launched agent (no HEIMDALL_BRIDGE_ENDPOINT / HEIMDALL_AGENT_TOKEN)")
	fmt.println("`hook` and `event` exit 0 with no output, so a provider is never blocked.")
	fmt.println("HEIMDALL_EXT_PERMISSION_TIMEOUT_MS lowers the permission wait (default/max 300000).")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  echo \"$HOOK_JSON\" | ham-ctl extension hook <claude|codex>")
	fmt.println("  ham-ctl extension event --stdin < event.json")
	fmt.println("  ham-ctl extension status")
}
