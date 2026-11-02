#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

// BR-2 runtime-layer tests: the flag gate, env-pair conversion, and spawn-request
// assembly. These exercise the mapping logic without a live daemon (control-plane
// round-trips against a real ham-pty-host are covered by the daemon's own HOST-1
// integration tests + the codec tests here).

@(test)
pty_host_flag_truthy_parsing :: proc(t: ^testing.T) {
	testing.expect(t, bridge_pty_host_truthy("1"), "1 is truthy")
	testing.expect(t, bridge_pty_host_truthy("true"), "true is truthy")
	testing.expect(t, bridge_pty_host_truthy("TRUE"), "TRUE is truthy")
	testing.expect(t, bridge_pty_host_truthy(" on "), "on (padded) is truthy")
	testing.expect(t, bridge_pty_host_truthy("yes"), "yes is truthy")
	testing.expect(t, !bridge_pty_host_truthy("0"), "0 is falsey")
	testing.expect(t, !bridge_pty_host_truthy("false"), "false is falsey")
	testing.expect(t, !bridge_pty_host_truthy(""), "empty is falsey")
	testing.expect(t, !bridge_pty_host_truthy("nope"), "garbage is falsey")
}

@(test)
pty_host_always_enabled :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old_pty := bridge_config.pty_host_runtime
	defer { bridge_config.pty_host_runtime = old_pty }

	// DEL-1: ham-pty-host is the only agent-launch runtime; the tmux path was
	// removed, so bridge_pty_host_runtime_enabled() is always true regardless of
	// the (now no-op) config flag / env override.
	old := os.get_env_alloc("HEIMDALL_BRIDGE_PTY_HOST", context.allocator)
	defer {
		if strings.trim_space(old) != "" { _ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", old) } else { _ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST") }
	}
	_ = os.unset_env("HEIMDALL_BRIDGE_PTY_HOST")
	bridge_config.pty_host_runtime = false
	testing.expect(t, bridge_pty_host_runtime_enabled(), "always enabled even with config false + no env")

	_ = os.set_env("HEIMDALL_BRIDGE_PTY_HOST", "0")
	testing.expect(t, bridge_pty_host_runtime_enabled(), "env 0 no longer re-enables the removed tmux path")

	bridge_config.pty_host_runtime = false
}

@(test)
pty_host_env_pairs_splits_on_first_eq :: proc(t: ^testing.T) {
	env := []string{
		"HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/b.sock",
		"HEIMDALL_AGENT_TOKEN=hlat_a=b=c", // value contains '='
		"NO_EQUALS_SKIPPED",
		"=leading-eq-skipped",
		"HEIMDALL_CTL_BIN=/run/bin/ham-ctl",
	}
	pairs := bridge_pty_host_env_pairs(env)
	defer { for kv in pairs { delete(kv[0]); delete(kv[1]) }; delete(pairs) }

	testing.expect_value(t, len(pairs), 3)
	testing.expect_value(t, pairs[0][0], "HEIMDALL_BRIDGE_ENDPOINT")
	testing.expect_value(t, pairs[0][1], "unix:/tmp/b.sock")
	// split on FIRST '=' only => value keeps the remaining '='s
	testing.expect_value(t, pairs[1][0], "HEIMDALL_AGENT_TOKEN")
	testing.expect_value(t, pairs[1][1], "hlat_a=b=c")
	testing.expect_value(t, pairs[2][0], "HEIMDALL_CTL_BIN")
	testing.expect_value(t, pairs[2][1], "/run/bin/ham-ctl")
}

@(test)
pty_host_message_notice_rendering :: proc(t: ^testing.T) {
	m := bridge_pty_host_message_notice("inst_sender")
	defer delete(m)
	testing.expect_value(t, m, "New message from inst_sender \u2014 run './bin/ham-ctl chat read' to view.")
	// sender_display_name preferred when provided
	m_dn := bridge_pty_host_message_notice("inst_sender", "Alice")
	defer delete(m_dn)
	testing.expect_value(t, m_dn, "New message from Alice \u2014 run './bin/ham-ctl chat read' to view.")
	// blank sender defaults to "user"
	m2 := bridge_pty_host_message_notice("  ")
	defer delete(m2)
	testing.expect(t, strings.contains(m2, "New message from user "), "blank sender => user")
}

@(test)
pty_host_task_nudge_notice_rendering :: proc(t: ^testing.T) {
	n := bridge_pty_host_task_nudge_notice("task_123", "assignee")
	defer delete(n)
	testing.expect_value(t, n, "Nudge: you have been nudged on task_123 (assignee). Run './bin/ham-ctl task list' and complete your assignment.")
	// with task title
	n_title := bridge_pty_host_task_nudge_notice("task_123", "assignee", "Fix the bug")
	defer delete(n_title)
	testing.expect_value(t, n_title, "Nudge: you have been nudged on \"Fix the bug\" (task_123) (assignee). Run './bin/ham-ctl task list' and complete your assignment.")
	// blank defaults
	n2 := bridge_pty_host_task_nudge_notice("", "")
	defer delete(n2)
	testing.expect(t, strings.contains(n2, "nudged on unknown (participant)"), "blank task/role defaults")
}

// MEM-6: the delivered line prefers the hub's human_message verbatim, falling back
// to the legacy generated notice when it is absent/blank.
@(test)
pty_host_task_nudge_line_prefers_human_message :: proc(t: ^testing.T) {
	hm := bridge_pty_host_task_nudge_line("task_9", "assignee", `[Review Requested] @coder #1 submitted for review "Fix bug" (task_9)`)
	defer delete(hm)
	testing.expect_value(t, hm, `[Review Requested] @coder #1 submitted for review "Fix bug" (task_9)`)

	lg := bridge_pty_host_task_nudge_line("task_9", "assignee", "")
	defer delete(lg)
	testing.expect(t, strings.contains(lg, "you have been nudged on task_9 (assignee)"), "empty human_message falls back to legacy notice")

	blank := bridge_pty_host_task_nudge_line("task_9", "reviewer", "   ")
	defer delete(blank)
	testing.expect(t, strings.contains(blank, "nudged on task_9 (reviewer)"), "whitespace human_message falls back to legacy notice")
}

@(test)
pty_host_paste_wrap_sanitizes_notice :: proc(t: ^testing.T) {
	plain := bridge_pty_host_paste_wrap("hello")
	defer delete(plain)
	testing.expect_value(t, plain, "\x1b[200~hello\x1b[201~")

	sanitized := bridge_pty_host_paste_wrap("a\x1bb\rc\nd\r\ne")
	defer delete(sanitized)
	testing.expect_value(t, sanitized, "\x1b[200~abcde\x1b[201~")

	terminator := bridge_pty_host_paste_wrap("before\x1b[201~after")
	defer delete(terminator)
	testing.expect_value(t, terminator, "\x1b[200~before[201~after\x1b[201~")

	empty := bridge_pty_host_paste_wrap("")
	defer delete(empty)
	testing.expect_value(t, empty, "\x1b[200~\x1b[201~")
}

@(test)
pty_host_provider_gate_codex_only :: proc(t: ^testing.T) {
	instances := []string{"inst_codex_gate", "inst_claude_gate", "inst_copilot_gate", "inst_antigravity_gate", "inst_unknown_provider_gate"}
	defer for instance in instances do bridge_pty_host_untrack_instance_provider(instance)

	bridge_pty_host_track_instance_provider(instances[0], "codex")
	bridge_pty_host_track_instance_provider(instances[1], "claude")
	bridge_pty_host_track_instance_provider(instances[2], "copilot")
	bridge_pty_host_track_instance_provider(instances[3], "antigravity")
	bridge_pty_host_track_instance_provider(instances[4], "unknown")

	testing.expect(t, bridge_pty_host_instance_wants_bracketed_paste(instances[0]), "codex uses bracketed paste")
	for instance in instances[1:] {
		testing.expect(t, !bridge_pty_host_instance_wants_bracketed_paste(instance), "non-codex provider keeps raw delivery")
	}
	testing.expect(t, !bridge_pty_host_instance_wants_bracketed_paste("inst_not_tracked"), "unknown instance keeps raw delivery")
}

@(test)
pty_host_deliver_line_gates_bracketed_paste :: proc(t: ^testing.T) {
	sock_path := fmt.tprintf("/tmp/test_deliver_line_paste_%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(sock_path)))
	defer _ = posix.unlink(cstring(raw_data(sock_path)))

	listener_fd := posix.socket(.UNIX, .STREAM)
	testing.expect(t, listener_fd >= 0, "socket create failed")
	defer posix.close(listener_fd)

	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for ch, i in sock_path do addr.sun_path[i] = c.char(ch)
	addr.sun_path[len(sock_path)] = 0
	testing.expect_value(t, posix.bind(listener_fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))), posix.result.OK)
	testing.expect_value(t, posix.listen(listener_fd, 8), posix.result.OK)

	Server_Ctx :: struct {
		listener_fd: posix.FD,
		payloads:    [4][]byte,
		count:       int,
		allocator:   runtime.Allocator,
	}
	ctx := Server_Ctx{listener_fd = listener_fd, allocator = runtime.heap_allocator()}
	defer for payload in ctx.payloads do if len(payload) > 0 do delete(payload, ctx.allocator)
	th := thread.create_and_start_with_data(rawptr(&ctx), proc(data: rawptr) {
		s := (^Server_Ctx)(data)
		context.allocator = s.allocator
		for s.count < len(s.payloads) {
			client := posix.accept(s.listener_fd, nil, nil)
			if client < 0 do break
			payload, ok := pty_host_read_frame(client)
			if ok {
				s.payloads[s.count] = payload
				s.count += 1
			}
			posix.close(client)
		}
	})
	defer thread.destroy(th)

	bridge_pty_host_track_instance_provider("inst_codex_line", "codex")
	defer bridge_pty_host_untrack_instance_provider("inst_codex_line")
	bridge_pty_host_track_instance_provider("inst_claude_line", "claude")
	defer bridge_pty_host_untrack_instance_provider("inst_claude_line")

	testing.expect(t, bridge_pty_host_deliver_line(sock_path, "inst_codex_line", "line\r\n\x1b[201~tail"), "codex delivery succeeds")
	testing.expect(t, bridge_pty_host_deliver_line(sock_path, "inst_claude_line", "raw\r\n\x1bbytes"), "non-codex delivery succeeds")
	thread.join(th)

	testing.expect_value(t, ctx.count, 4)
	if ctx.count == 4 {
		codex_data_offset := 1 + 4 + len("inst_codex_line")
		raw_data_offset := 1 + 4 + len("inst_claude_line")
		testing.expect_value(t, string(ctx.payloads[0][codex_data_offset:]), "\x1b[200~line[201~tail\x1b[201~")
		testing.expect_value(t, ctx.payloads[1][0], u8(PTY_HOST_T_KEY))
		testing.expect_value(t, ctx.payloads[1][len(ctx.payloads[1]) - 1], u8(1))
		testing.expect_value(t, string(ctx.payloads[2][raw_data_offset:]), "raw\r\n\x1bbytes")
		testing.expect_value(t, ctx.payloads[3][0], u8(PTY_HOST_T_KEY))
		testing.expect_value(t, ctx.payloads[3][len(ctx.payloads[3]) - 1], u8(1))
	}
}

// pty_host_delivery_maps_push_to_input_enter proves the delivery primitive's wire
// shape: a notice becomes Input(instance, text) followed by Key(instance, Enter) —
// the host analog of tmux.send_text(pane, text, enter=true).
@(test)
pty_host_delivery_maps_push_to_input_enter :: proc(t: ^testing.T) {
	notice := bridge_pty_host_message_notice("user")
	defer delete(notice)

	input := pty_host_encode_input("inst_a", transmute([]byte)notice)
	defer delete(input)
	ip := pty_host_test_reframe(t, input)
	testing.expect_value(t, ip[0], u8(PTY_HOST_T_INPUT))
	// tag + u32 len(6) + "inst_a" + raw notice bytes
	testing.expect_value(t, len(ip), 1 + 4 + 6 + len(notice))

	key := pty_host_encode_key("inst_a", .Enter)
	defer delete(key)
	kp := pty_host_test_reframe(t, key)
	want := []byte{PTY_HOST_T_KEY, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 1}
	testing.expect_value(t, len(kp), len(want))
	for i in 0..<len(want) do testing.expect_value(t, kp[i], want[i])
}

// pty_host_user_message_interrupts_with_esc pins the wire shape of the ESC key
// that bridge_pty_host_deliver_message sends BEFORE typing a user-message notice.
// Pressing ESC first interrupts the agent's current turn so it drops to an
// input-ready prompt and picks up the just-arrived user message ASAP. The key
// tag byte is the Esc discriminant (2), which must stay in sync with proto.rs.
@(test)
pty_host_user_message_interrupts_with_esc :: proc(t: ^testing.T) {
	esc := pty_host_encode_key("inst_a", .Esc)
	defer delete(esc)
	ep := pty_host_test_reframe(t, esc)
	want := []byte{PTY_HOST_T_KEY, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 2}
	testing.expect_value(t, len(ep), len(want))
	for i in 0..<len(want) do testing.expect_value(t, ep[i], want[i])
}

// pty_host_nudge_payload_allocator is the allocator the two deliver_task_nudge
// tests below use for frame payloads, on BOTH sides of their accept thread.
//
// A thread started by thread.create_and_start_with_data does not inherit the
// starting thread's context. Letting the implicit context.allocator stand would
// therefore allocate each payload from the default heap on the accept thread and
// free it through the test runner's per-test tracking allocator on the test
// thread -- a `+++ bad free`, followed by `free(): invalid pointer`, which
// aborted the whole src/bridge suite before it could print its result.
//
// The heap allocator rather than the test's own context allocator: the runner's
// per-test allocator is a mem.Rollback_Stack, serialised only incidentally by the
// tracking allocator's mutex and left unguarded under
// -define:ODIN_TEST_TRACK_MEMORY=false, so sharing it across threads would trade
// the bad free for a data race.
pty_host_nudge_payload_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// pty_host_deliver_task_nudge_interrupt_sends_esc verifies that
// bridge_pty_host_deliver_task_nudge sends the ESC key frame when interrupt is true.
@(test)
pty_host_deliver_task_nudge_interrupt_sends_esc :: proc(t: ^testing.T) {
	sock_path := fmt.tprintf("/tmp/test_nudge_esc_%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(sock_path)))
	defer _ = posix.unlink(cstring(raw_data(sock_path)))

	listener_fd := posix.socket(.UNIX, .STREAM)
	testing.expect(t, listener_fd >= 0, "socket create failed")
	defer posix.close(listener_fd)

	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(sock_path) do addr.sun_path[i] = c.char(sock_path[i])
	addr.sun_path[len(sock_path)] = 0
	bind_res := posix.bind(listener_fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr)))
	testing.expect_value(t, bind_res, posix.result.OK)
	listen_res := posix.listen(listener_fd, 8)
	testing.expect_value(t, listen_res, posix.result.OK)

	Server_Ctx :: struct {
		listener_fd:       posix.FD,
		first_payload:     []byte,
		total_conns:       int,
		// Named explicitly because frame payloads cross a thread boundary: they
		// are allocated on the accept thread below and freed on the test thread.
		// See the note above pty_host_nudge_payload_allocator.
		payload_allocator: runtime.Allocator,
	}
	ctx := Server_Ctx{listener_fd = listener_fd, payload_allocator = pty_host_nudge_payload_allocator()}
	defer if len(ctx.first_payload) > 0 do delete(ctx.first_payload, ctx.payload_allocator)

	th := thread.create_and_start_with_data(rawptr(&ctx), proc(data: rawptr) {
		s := (^Server_Ctx)(data)
		context.allocator = s.payload_allocator
		for s.total_conns < 3 {
			client := posix.accept(s.listener_fd, nil, nil)
			if client < 0 do break
			s.total_conns += 1
			payload, ok := pty_host_read_frame(client)
			if ok && s.total_conns == 1 {
				s.first_payload = payload
			} else if ok {
				delete(payload, s.payload_allocator)
			}
			posix.close(client)
		}
	})
	defer thread.destroy(th)

	delivered := bridge_pty_host_deliver_task_nudge(sock_path, "inst_worker", "task_test_1", "worker", "human notice", "Test Title", true)
	testing.expect(t, delivered, "deliver_task_nudge with interrupt should succeed")

	thread.join(th)

	testing.expect_value(t, ctx.total_conns, 3)
	want_esc := []byte{PTY_HOST_T_KEY, 0, 0, 0, 11, 'i', 'n', 's', 't', '_', 'w', 'o', 'r', 'k', 'e', 'r', 2}
	testing.expect_value(t, len(ctx.first_payload), len(want_esc))
	for i in 0..<len(want_esc) {
		if i < len(ctx.first_payload) {
			testing.expect_value(t, ctx.first_payload[i], want_esc[i])
		}
	}
}

// pty_host_deliver_task_nudge_no_interrupt_no_esc verifies that
// bridge_pty_host_deliver_task_nudge does NOT send ESC when interrupt is false.
@(test)
pty_host_deliver_task_nudge_no_interrupt_no_esc :: proc(t: ^testing.T) {
	sock_path := fmt.tprintf("/tmp/test_nudge_no_esc_%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(sock_path)))
	defer _ = posix.unlink(cstring(raw_data(sock_path)))

	listener_fd := posix.socket(.UNIX, .STREAM)
	testing.expect(t, listener_fd >= 0, "socket create failed")
	defer posix.close(listener_fd)

	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(sock_path) do addr.sun_path[i] = c.char(sock_path[i])
	addr.sun_path[len(sock_path)] = 0
	bind_res := posix.bind(listener_fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr)))
	testing.expect_value(t, bind_res, posix.result.OK)
	listen_res := posix.listen(listener_fd, 8)
	testing.expect_value(t, listen_res, posix.result.OK)

	Server_Ctx :: struct {
		listener_fd:       posix.FD,
		first_payload:     []byte,
		total_conns:       int,
		// Named explicitly because frame payloads cross a thread boundary: they
		// are allocated on the accept thread below and freed on the test thread.
		// See the note above pty_host_nudge_payload_allocator.
		payload_allocator: runtime.Allocator,
	}
	ctx := Server_Ctx{listener_fd = listener_fd, payload_allocator = pty_host_nudge_payload_allocator()}
	defer if len(ctx.first_payload) > 0 do delete(ctx.first_payload, ctx.payload_allocator)

	th := thread.create_and_start_with_data(rawptr(&ctx), proc(data: rawptr) {
		s := (^Server_Ctx)(data)
		context.allocator = s.payload_allocator
		for s.total_conns < 2 {
			client := posix.accept(s.listener_fd, nil, nil)
			if client < 0 do break
			s.total_conns += 1
			payload, ok := pty_host_read_frame(client)
			if ok && s.total_conns == 1 {
				s.first_payload = payload
			} else if ok {
				delete(payload, s.payload_allocator)
			}
			posix.close(client)
		}
	})
	defer thread.destroy(th)

	delivered := bridge_pty_host_deliver_task_nudge(sock_path, "inst_worker", "task_test_1", "worker", "human notice", "Test Title", false)
	testing.expect(t, delivered, "deliver_task_nudge without interrupt should succeed")

	thread.join(th)

	testing.expect_value(t, ctx.total_conns, 2)
	testing.expect(t, len(ctx.first_payload) > 0, "first payload non-empty")
	if len(ctx.first_payload) > 0 {
		testing.expect_value(t, ctx.first_payload[0], u8(PTY_HOST_T_INPUT))
	}
}

@(test)
pty_host_build_spawn_from_profile :: proc(t: ^testing.T) {
	// Requires a runnable provider profile. Use the resolved default provider; if
	// none is runnable in this build/test env, skip (the assembly logic is still
	// covered by the codec's Spawn tests).
	bridge_provider_store_init()
	env := []string{"HEIMDALL_AGENT_TOKEN=hlat_x", "HEIMDALL_CTL_BIN=/run/bin/ham-ctl"}
	req, ok := bridge_pty_host_build_spawn("inst_test", "/tmp/run/inst_test", "", "", "hlat_x", env, "test-agent #1")
	if !ok do return // no runnable provider in this environment; nothing to assert
	defer bridge_pty_host_spawn_request_delete(req)

	testing.expect_value(t, req.instance, "inst_test")
	testing.expect_value(t, req.display_name, "test-agent #1")
	testing.expect(t, req.has_display_name, "display_name present")
	testing.expect_value(t, req.cwd, "/tmp/run/inst_test")
	testing.expect(t, req.has_cwd, "cwd present")
	testing.expect(t, len(req.argv) > 0, "argv non-empty")
	testing.expect_value(t, len(req.env), 2)
	testing.expect_value(t, req.rows, u16(25))
	testing.expect_value(t, req.cols, u16(80))
	testing.expect_value(t, req.rows, u16(PTY_HOST_DEFAULT_ROWS))
	testing.expect_value(t, req.cols, u16(PTY_HOST_DEFAULT_COLS))
}

@(test)
pty_host_build_spawn_carries_optional_timeout :: proc(t: ^testing.T) {
	bridge_provider_store_init()
	env := []string{"HEIMDALL_AGENT_TOKEN=hlat_x"}
	req, ok := bridge_pty_host_build_spawn("inst_test_timeout", "/tmp/run/inst_test_timeout", "", "", "hlat_x", env, "Provider test", 120)
	if !ok do return
	defer bridge_pty_host_spawn_request_delete(req)

	testing.expect(t, req.has_timeout_seconds, "timeout present")
	testing.expect_value(t, req.timeout_seconds, u64(120))
}

@(test)
pty_host_raw_input_framing :: proc(t: ^testing.T) {
	data := "echo hello\n"
	frame := pty_host_encode_input("inst_a", transmute([]byte)data)
	defer delete(frame)
	ip := pty_host_test_reframe(t, frame)
	testing.expect_value(t, ip[0], u8(PTY_HOST_T_INPUT))
	// tag + u32 len(6) + "inst_a" + raw data bytes
	testing.expect_value(t, len(ip), 1 + 4 + 6 + len(data))
	// Verify raw data bytes match exactly
	testing.expect_value(t, string(ip[11:]), data)
}

@(test)
pty_host_deliver_raw_input_rejects_empty :: proc(t: ^testing.T) {
	data := "test input"
	testing.expect(t, !bridge_pty_host_deliver_raw_input("", data), "empty instance fails")
	testing.expect(t, !bridge_pty_host_deliver_raw_input("", "inst_a", data), "empty socket fails")
	testing.expect(t, !bridge_pty_host_deliver_raw_input("/nonexistent.sock", "", data), "empty instance with socket fails")
}

@(test)
agent_pty_input_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields
	cmd_top := `{"type":"agent_pty_input","command_id":"cmd_input_1","agent_instance_id":"inst_test","data":"cmd1"}`
	bridge_runtime_cache_command("cmd_input_1", `{"command_id":"cmd_input_1","status":"cached_ok"}`)
	bridge_hub_handle_agent_pty_input(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_input_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields
	cmd_nested := `{"type":"agent_pty_input","command_id":"cmd_input_2","payload":{"agent_instance_id":"","data":""}}`
	bridge_hub_handle_agent_pty_input(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_input_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expect(t, strings.contains(res, "failed"), "empty instance fails gracefully")
}

@(test)
pty_host_resize_framing :: proc(t: ^testing.T) {
	frame := pty_host_encode_resize("inst_a", 24, 100)
	defer delete(frame)
	pl := pty_host_test_reframe(t, frame)
	// Resize: tag(PTY_HOST_T_RESIZE) + u32 len(6) + "inst_a" + u16 rows(24) + u16 cols(100)
	want := []byte{PTY_HOST_T_RESIZE, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'a', 0, 24, 0, 100}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
}

@(test)
pty_host_deliver_resize_rejects_invalid :: proc(t: ^testing.T) {
	testing.expect(t, !bridge_pty_host_deliver_resize("", 24, 100), "empty instance fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("inst_a", 0, 100), "zero rows fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("inst_a", 24, 0), "zero cols fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("", "inst_a", 24, 100), "empty socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "", 24, 100), "empty instance with socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "inst_a", 0, 100), "zero rows with socket fails")
	testing.expect(t, !bridge_pty_host_deliver_resize("/nonexistent.sock", "inst_a", 24, 0), "zero cols with socket fails")
}

@(test)
agent_pty_resize_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields
	cmd_top := `{"type":"agent_pty_resize","command_id":"cmd_resize_1","agent_instance_id":"inst_test","rows":24,"cols":100}`
	bridge_runtime_cache_command("cmd_resize_1", `{"command_id":"cmd_resize_1","status":"cached_ok"}`)
	bridge_hub_handle_agent_pty_resize(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_resize_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields
	cmd_nested := `{"type":"agent_pty_resize","command_id":"cmd_resize_2","payload":{"agent_instance_id":"","rows":24,"cols":100}}`
	bridge_hub_handle_agent_pty_resize(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_resize_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expect(t, strings.contains(res, "failed"), "empty instance fails gracefully")

	// 3. Nested payload with zero dimensions
	cmd_zero := `{"type":"agent_pty_resize","command_id":"cmd_resize_3","payload":{"agent_instance_id":"inst_test","rows":0,"cols":100}}`
	bridge_hub_handle_agent_pty_resize(nil, cmd_zero)
	res3, res3_ok := bridge_runtime_cached_command("cmd_resize_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "zero rows fails gracefully")

	// 4. Also verify dispatch through bridge_hub_handle_command
	cmd_dispatch := `{"type":"agent_pty_resize","command_id":"cmd_resize_4","agent_instance_id":"","rows":24,"cols":100}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_resize_4")
	testing.expect(t, res4_ok, "command dispatched through bridge_hub_handle_command and cached")
	testing.expect(t, strings.contains(res4, "failed"), "empty instance fails gracefully")
}

@(test)
shell_pty_input_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields with shell_id
	cmd_top := `{"type":"shell_pty_input","command_id":"cmd_shell_input_1","shell_id":"sh_test","data":"echo hello"}`
	bridge_runtime_cache_command("cmd_shell_input_1", `{"command_id":"cmd_shell_input_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_pty_input(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_shell_input_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Nested payload fields with shell_id
	cmd_nested := `{"type":"shell_pty_input","command_id":"cmd_shell_input_2","payload":{"shell_id":"","data":""}}`
	bridge_hub_handle_shell_pty_input(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_shell_input_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res, "failed"), "empty shell_id fails gracefully, got: %s", res)

	// 3. Fallback to agent_instance_id when shell_id is omitted
	cmd_fallback := `{"type":"shell_pty_input","command_id":"cmd_shell_input_3","payload":{"agent_instance_id":"","data":""}}`
	bridge_hub_handle_shell_pty_input(nil, cmd_fallback)
	res3, res3_ok := bridge_runtime_cached_command("cmd_shell_input_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res3, "failed"), "empty fallback agent_instance_id fails gracefully, got: %s", res3)

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_pty_input","command_id":"cmd_shell_input_4","shell_id":"","data":"test"}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_shell_input_4")
	testing.expect(t, res4_ok, "shell_pty_input dispatched through bridge_hub_handle_command")
	testing.expectf(t, strings.contains(res4, "failed"), "empty shell_id fails gracefully, got: %s", res4)
}

@(test)
shell_pty_resize_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Direct top-level fields with shell_id
	cmd_top := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_1","shell_id":"sh_test","rows":30,"cols":120}`
	bridge_runtime_cache_command("cmd_shell_resize_1", `{"command_id":"cmd_shell_resize_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_pty_resize(nil, cmd_top)
	cached, ok := bridge_runtime_cached_command("cmd_shell_resize_1")
	testing.expect(t, ok, "cached command found")
	testing.expectf(t, strings.contains(cached, "cached_ok"), "cached result matched, got: %s", cached)

	// 2. Nested payload fields with shell_id
	cmd_nested := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_2","payload":{"shell_id":"","rows":30,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_nested)
	res, res_ok := bridge_runtime_cached_command("cmd_shell_resize_2")
	testing.expect(t, res_ok, "command executed and cached")
	testing.expectf(t, strings.contains(res, "failed"), "empty shell_id fails gracefully, got: %s", res)

	// 3. Fallback to agent_instance_id when shell_id is omitted
	cmd_fallback := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_3","payload":{"agent_instance_id":"","rows":30,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_fallback)
	res3, res3_ok := bridge_runtime_cached_command("cmd_shell_resize_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "empty fallback agent_instance_id fails gracefully")

	// 4. Nested payload with zero dimensions
	cmd_zero := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_4","payload":{"shell_id":"sh_test","rows":0,"cols":120}}`
	bridge_hub_handle_shell_pty_resize(nil, cmd_zero)
	res4, res4_ok := bridge_runtime_cached_command("cmd_shell_resize_4")
	testing.expect(t, res4_ok, "command executed and cached")
	testing.expect(t, strings.contains(res4, "failed"), "zero rows fails gracefully")

	// 5. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_pty_resize","command_id":"cmd_shell_resize_5","shell_id":"","rows":30,"cols":120}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res5, res5_ok := bridge_runtime_cached_command("cmd_shell_resize_5")
	testing.expect(t, res5_ok, "shell_pty_resize dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res5, "failed"), "empty shell_id fails gracefully")
}

@(test)
pty_host_deliver_shell_input_and_resize_validation :: proc(t: ^testing.T) {
	testing.expect(t, !bridge_pty_host_deliver_shell_input("", "data"), "empty shell_id fails for input")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("", 24, 100), "empty shell_id fails for resize")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("sh_a", 0, 100), "zero rows fails for resize")
	testing.expect(t, !bridge_pty_host_deliver_shell_resize("sh_a", 24, 0), "zero cols fails for resize")
}

@(test)
shell_stream_attach_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Cached command returns early
	bridge_runtime_cache_command("cmd_stream_attach_1", `{"command_id":"cmd_stream_attach_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_stream_attach(nil, `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_1","session_id":"sh_test"}`)
	cached, ok := bridge_runtime_cached_command("cmd_stream_attach_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Missing session_id fails gracefully
	cmd_empty := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_2","session_id":""}`
	bridge_hub_handle_shell_stream_attach(nil, cmd_empty)
	res2, res2_ok := bridge_runtime_cached_command("cmd_stream_attach_2")
	testing.expect(t, res2_ok, "command executed and cached")
	testing.expect(t, strings.contains(res2, "failed"), "missing session_id fails gracefully")

	// 3. Nested payload with missing session_id fails gracefully
	cmd_nested_empty := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_3","payload":{"session_id":""}}`
	bridge_hub_handle_shell_stream_attach(nil, cmd_nested_empty)
	res3, res3_ok := bridge_runtime_cached_command("cmd_stream_attach_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "failed"), "nested empty session_id fails gracefully")

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_stream_attach","command_id":"cmd_stream_attach_4","session_id":""}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_stream_attach_4")
	testing.expect(t, res4_ok, "shell_stream_attach dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res4, "failed"), "empty session_id fails gracefully")
}

@(test)
shell_stream_detach_command_handles_payload_and_caching :: proc(t: ^testing.T) {
	// 1. Cached command returns early
	bridge_runtime_cache_command("cmd_stream_detach_1", `{"command_id":"cmd_stream_detach_1","status":"cached_ok"}`)
	bridge_hub_handle_shell_stream_detach(nil, `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_1","session_id":"sh_test"}`)
	cached, ok := bridge_runtime_cached_command("cmd_stream_detach_1")
	testing.expect(t, ok, "cached command found")
	testing.expect(t, strings.contains(cached, "cached_ok"), "cached result matched")

	// 2. Missing session_id fails gracefully
	cmd_empty := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_2","session_id":""}`
	bridge_hub_handle_shell_stream_detach(nil, cmd_empty)
	res2, res2_ok := bridge_runtime_cached_command("cmd_stream_detach_2")
	testing.expect(t, res2_ok, "command executed and cached")
	testing.expect(t, strings.contains(res2, "failed"), "missing session_id fails gracefully")

	// 3. Detaching non-active session succeeds cleanly (idempotent)
	cmd_nonactive := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_3","session_id":"sh_nonexistent"}`
	bridge_hub_handle_shell_stream_detach(nil, cmd_nonactive)
	res3, res3_ok := bridge_runtime_cached_command("cmd_stream_detach_3")
	testing.expect(t, res3_ok, "command executed and cached")
	testing.expect(t, strings.contains(res3, "succeeded"), "idempotent detach succeeds")

	// 4. Dispatch via bridge_hub_handle_command
	cmd_dispatch := `{"type":"shell_stream_detach","command_id":"cmd_stream_detach_4","session_id":""}`
	bridge_hub_handle_command(nil, cmd_dispatch)
	res4, res4_ok := bridge_runtime_cached_command("cmd_stream_detach_4")
	testing.expect(t, res4_ok, "shell_stream_detach dispatched through bridge_hub_handle_command")
	testing.expect(t, strings.contains(res4, "failed"), "empty session_id fails gracefully")
}

@(test)
pty_stream_worker_detach_deregisters_immediately :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	heap := runtime.heap_allocator()
	worker := new(Bridge_PTY_Stream_Worker, heap)
	worker.session_id = strings.clone("sh_detach_imm", heap)
	worker.shell_id = strings.clone("sh_detach_imm", heap)
	worker.fd = fds[0]
	worker.active = true

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = heap)
	}
	bridge_pty_stream_map.workers[strings.clone("sh_detach_imm", heap)] = worker
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	testing.expect(t, bridge_pty_stream_worker_is_active("sh_detach_imm"), "worker is initially active")

	// Detach must immediately deregister from map
	bridge_pty_stream_worker_detach("sh_detach_imm")

	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_detach_imm"), "worker is no longer active after detach")

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	_, found := bridge_pty_stream_map.workers["sh_detach_imm"]
	testing.expect(t, !found, "session key immediately purged from bridge_pty_stream_map")
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// Clean up worker memory
	delete(worker.session_id, heap)
	delete(worker.shell_id, heap)
	free(worker, heap)
}



// REQ-SHELL-5 §1: the line an agent sees when one of its BACKGROUND runs ends.
//
// The assertions worth having here are the two the requirement actually constrains:
// the SESSION ID is present (it is the handle the agent was handed when the run was
// backgrounded, and what `shell log` takes), and NO OUTPUT travels with the status.
@(test)
bridge_shell_run_notice_rendering :: proc(t: ^testing.T) {
	n := bridge_shell_run_notice("sh_123", "exited", "0")
	defer delete(n)
	testing.expect_value(t, n, "Shell run sh_123 exited (exit 0). Run './bin/ham-ctl shell log sh_123' to read its output.")

	// A kill reports as killed, and an unknown exit code is simply omitted rather than
	// fabricated as 0 — the agent must be able to tell "no code" from "exit 0".
	killed := bridge_shell_run_notice("sh_456", "killed", "")
	defer delete(killed)
	testing.expect_value(t, killed, "Shell run sh_456 killed. Run './bin/ham-ctl shell log sh_456' to read its output.")

	// Blank defaults, matching the task-nudge notice's behaviour above: render
	// something truthful rather than an empty sentence.
	blank := bridge_shell_run_notice("", "", "")
	defer delete(blank)
	testing.expect(t, strings.contains(blank, "Shell run unknown exited"), "blank session/status defaults")
}

// =============================================================================
// REQ-SHELL-40 — the BRIDGE half: no stream worker outlives the hub connection it was
// created for, and a re-attach for a live worker never creates a second one.
//
// NO PTY AND NO DAEMON (AC6). Workers are fabricated over a socketpair and registered
// directly, exactly as pty_stream_worker_detach_deregisters_immediately does — so these
// exercise the registry and teardown logic without ham-pty-host running and cannot hang
// on a dial. The reader thread is deliberately never started, so the tests free the
// worker structs themselves, which is otherwise the reader's teardown job.
// =============================================================================

// t40_fake_worker registers an active worker for `sid` over one end of a socketpair.
// Returns the worker so the caller can free it; the fds are the caller's to close.
@(private = "file")
t40_fake_worker :: proc(sid: string, fd: posix.FD) -> ^Bridge_PTY_Stream_Worker {
	heap := runtime.heap_allocator()
	worker := new(Bridge_PTY_Stream_Worker, heap)
	worker.session_id = strings.clone(sid, heap)
	worker.shell_id = strings.clone(sid, heap)
	worker.fd = fd
	worker.active = true

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = heap)
	}
	bridge_pty_stream_map.workers[strings.clone(sid, heap)] = worker
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	return worker
}

@(test)
t40_stop_all_for_reconnect_detaches_every_worker :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	// THE 128B LEAK THIS TEST USED TO REPORT IS GONE, AND SO IS THE REASONING THAT EXCUSED IT.
	// The previous version of this test appended to bridge_pty_stream_outgoing directly and then
	// explained at length why the 128B backing array could not safely be freed. That explanation
	// was wrong in its premise: the backing was not heap memory being politely left alone, it was
	// bound to whichever TEST ALLOCATOR appended first, and it outlived that allocator. The
	// tracker reported it as a leak here because it genuinely belonged to this test. Freeing it
	// was never the fix; not letting a test allocator own it was.
	// _bridge_pty_stream_outgoing_bind_heap now pins it to the heap, so the tracker sees nothing
	// and the dangling-backing use-after-free that segfaulted this test cannot recur.

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds_a: [2]posix.FD
	fds_b: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds_a) != .OK {
		testing.expect(t, false, "socketpair a failed")
		return
	}
	defer posix.close(fds_a[0]); defer posix.close(fds_a[1])
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds_b) != .OK {
		testing.expect(t, false, "socketpair b failed")
		return
	}
	defer posix.close(fds_b[0]); defer posix.close(fds_b[1])

	// TWO workers, because the defect is that the hub re-attaches PER SESSION while the
	// teardown is per CONNECTION: one connection drop must take every session's worker
	// with it, not just the first one found.
	w_a := t40_fake_worker("sh_recon_a", fds_a[0])
	w_b := t40_fake_worker("sh_recon_b", fds_b[0])
	heap := runtime.heap_allocator()
	defer {
		delete(w_a.session_id, heap); delete(w_a.shell_id, heap); free(w_a, heap)
		delete(w_b.session_id, heap); delete(w_b.shell_id, heap); free(w_b, heap)
	}

	// A frame queued by a worker that is about to be torn down. After the teardown it can
	// never be delivered to anyone — the deliberate, logged drop.
	// Queued through the PRODUCTION emit path rather than a raw append. A raw append here was
	// what bound the queue's backing to this test's allocator; going through emit_frame also
	// means the frame is heap-owned exactly as it is in production, so the drop in stop_all
	// frees it with the allocator that really allocated it.
	bridge_pty_stream_emit_frame(nil, "sh_recon_a", transmute([]byte)string("A"))

	testing.expect(t, bridge_pty_stream_worker_is_active("sh_recon_a"), "worker a starts active")
	testing.expect(t, bridge_pty_stream_worker_is_active("sh_recon_b"), "worker b starts active")

	stopped := bridge_pty_stream_stop_all_for_reconnect()

	testing.expect_value(t, stopped, 2)
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_recon_a"), "worker a must not survive the connection it belonged to")
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_recon_b"), "worker b must not survive the connection it belonged to")

	// The registry must be EMPTY, not merely marked inactive. An entry left behind would
	// make the next worker_start for that session take the not-active fall-through branch
	// rather than a clean dial.
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 0)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// And the queue is drained, so the reconnect cannot paint pre-outage bytes over the
	// fresh catch-up snapshot the re-attach earns.
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	testing.expect_value(t, len(bridge_pty_stream_outgoing), 0)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
}

@(test)
t40_stop_all_for_reconnect_is_a_noop_with_no_workers :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	// The overwhelmingly common reconnect: nobody had a pane open. This must cost nothing
	// and must not log, because a line on every reconnect of every idle bridge is how a
	// useful log becomes one nobody reads.
	testing.expect_value(t, bridge_pty_stream_stop_all_for_reconnect(), 0)
	testing.expect_value(t, bridge_pty_stream_stop_all_for_reconnect(), 0)
}

@(test)
t40_reattach_of_a_live_worker_creates_no_second_worker :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	// fds[0] is handed to the worker and is closed by bridge_pty_stream_reset below; only
	// the other end is ours to close.
	defer posix.close(fds[1])

	// NOT FREED HERE, unlike the two-worker test above. This worker is still REGISTERED
	// when the test ends — that is the whole point of the assertion — so the deferred
	// bridge_pty_stream_reset owns it: reset frees session_id, shell_id, the worker and
	// its map key, and closes its fd. Freeing it here too would be a use-after-free and a
	// double free, because defers run LIFO and ours would run BEFORE reset walked the map.
	worker := t40_fake_worker("sh_dup", fds[0])

	// THE LOAD-BEARING IDEMPOTENCE GUARD FOR AC4. The hub sends an attach per reconnect
	// and cannot know whether the bridge already has a worker, so a reconnect storm — or a
	// reconnect racing a genuine 0->1 viewer attach — puts several attaches on the wire
	// for one session. This early return is what makes that cost N no-ops instead of N
	// workers and N pty-host sockets.
	//
	// THIS TEST CANNOT DIAL, AND THAT IS THE ASSERTION, not a limitation. There is no
	// ham-pty-host running here, so bridge_pty_host_ensure_daemon would fail and
	// worker_start would return FALSE if it ever reached it. Getting `true` back is
	// therefore positive proof that the early return fired ahead of the dial — a weaker
	// test that merely counted map entries would also pass if the dedup were removed and
	// the dial simply failed.
	conn: ws.Connection
	ok := bridge_pty_stream_worker_start("sh_dup", "sh_dup", &conn)
	testing.expect(t, ok, "a re-attach for a live worker must succeed without dialing the pty-host")

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 1)
	still_there, found := bridge_pty_stream_map.workers["sh_dup"]
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	testing.expect(t, found, "the original worker must still be registered")
	testing.expect(t, still_there == worker, "the registered worker must be the SAME one, not a replacement")

	// And it was rebound to the connection the re-attach arrived on, which is what makes a
	// re-attach meaningful rather than merely harmless.
	testing.expect(t, worker.conn == &conn, "the live worker must be rebound to the new connection")
}

@(test)
t40_connection_teardown_retires_workers_then_closes :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	// THIS IS THE CALL-SITE TEST, and it exists because the other bridge tests cannot be
	// it. They assert what the teardown DOES; none of them can assert that it is CALLED on
	// the way to closing a connection, so before bridge_hub_connection_teardown existed an
	// edit that dropped or reordered the call kept every test green. Routing both closes
	// through one procedure is what made that testable without a live WS: the wrapper takes
	// a Connection, so a fake one is enough.
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	// fds[0] is the worker's; worker_detach only shuts it down, and the reader thread that
	// would normally close it is never started here, so it is ours to close. fds[1] is the
	// connection's and ws.close owns it — a REAL fd rather than a zero value, because
	// ws.close on a non-secure Connection calls net.close(conn.socket) and socket 0 would
	// close this process's stdin.
	defer posix.close(fds[0])

	worker := t40_fake_worker("sh_teardown", fds[0])
	heap := runtime.heap_allocator()
	defer { delete(worker.session_id, heap); delete(worker.shell_id, heap); free(worker, heap) }

	conn := ws.Connection{connected = true, socket = net.TCP_Socket(fds[1])}
	testing.expect(t, bridge_pty_stream_worker_is_active("sh_teardown"), "worker starts active")

	bridge_hub_connection_teardown(&conn)

	// BOTH effects from ONE call is the assertion. Either one missing means a connection
	// was closed with a worker still holding a pointer to it, or a worker was retired
	// without the connection being closed.
	testing.expect(t, !bridge_pty_stream_worker_is_active("sh_teardown"), "teardown must retire the worker")
	testing.expect(t, !conn.connected, "teardown must close the connection")
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	testing.expect_value(t, len(bridge_pty_stream_map.workers), 0)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	// Idempotent, because the hello-failure path and the shared path both route through
	// this and a future edit may well call it twice.
	bridge_hub_connection_teardown(&conn)
	testing.expect(t, !conn.connected, "a second teardown is harmless")
}

@(test)
pty_stream_worker_get_active_conn_retrieves_registered_connection :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	defer posix.close(fds[0]); defer posix.close(fds[1])

	// Non-registered session returns nil, false
	c_nil, active_nil := bridge_pty_stream_worker_get_active_conn("sh_nonexistent")
	testing.expect(t, c_nil == nil && !active_nil, "nonexistent worker must return nil, false")

	// Registered worker
	worker := t40_fake_worker("sh_get_conn", fds[0])
	heap := runtime.heap_allocator()
	defer { delete(worker.session_id, heap); delete(worker.shell_id, heap); free(worker, heap) }

	var_conn: ws.Connection
	worker.conn = &var_conn

	conn_ret, active := bridge_pty_stream_worker_get_active_conn("sh_get_conn")
	testing.expect(t, active, "registered worker must be active")
	testing.expect(t, conn_ret == &var_conn, "retrieved conn must match worker.conn")

	// Detached worker returns false
	_ = bridge_pty_stream_worker_detach("sh_get_conn")
	c_after, active_after := bridge_pty_stream_worker_get_active_conn("sh_get_conn")
	testing.expect(t, !active_after, "detached worker must not be active")
	testing.expect(t, c_after == nil, "detached worker must return nil conn")
}

@(test)
pty_stream_worker_auto_reattach_flow_preserves_connection :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	defer posix.close(fds[0]); defer posix.close(fds[1])

	inst_id := "inst_stream_relaunch_test"
	worker := t40_fake_worker(inst_id, fds[0])
	heap := runtime.heap_allocator()
	defer { delete(worker.session_id, heap); delete(worker.shell_id, heap); free(worker, heap) }

	var_conn: ws.Connection
	worker.conn = &var_conn

	// Simulate bridge_runtime_launch_agent_pty_host relaunch check:
	conn, stream_was_active := bridge_pty_stream_worker_get_active_conn(inst_id)
	testing.expect(t, stream_was_active, "stream was active prior to relaunch")
	testing.expect(t, conn == &var_conn, "stream conn was captured")

	if stream_was_active {
		bridge_pty_stream_worker_detach(inst_id)
	}

	testing.expect(t, !bridge_pty_stream_worker_is_active(inst_id), "worker detached before respawn")

	// Simulate after respawn succeeds: re-register fake worker with captured conn.
	// new_fds[0] is handed to new_worker which remains registered at test end,
	// so the deferred bridge_pty_stream_reset owns closing new_fds[0] and freeing new_worker.
	new_fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &new_fds) != .OK {
		testing.expect(t, false, "new socketpair failed")
		return
	}
	defer posix.close(new_fds[1])

	new_worker := t40_fake_worker(inst_id, new_fds[0])
	new_worker.conn = conn

	conn_after, active_after := bridge_pty_stream_worker_get_active_conn(inst_id)
	testing.expect(t, active_after, "stream worker is active on newly spawned PTY")
	testing.expect(t, conn_after == &var_conn, "conn is preserved across relaunch")
}

// REQ-PTY-NET-5: a per-session incremental overflow COMPACTS the queue to its tail and
// keeps streaming; only a storm of compactions falls back to the old drop + resync.
@(test)
pane_overflow_compacts_slow_stream_to_its_tail_and_keeps_streaming :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	slow := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	healthy := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	heap := runtime.heap_allocator()
	chunk := strings.repeat("x", 32 * 1024, heap)
	defer delete(chunk, heap)
	_bridge_pty_stream_queue_output(&healthy, slice.clone(transmute([]byte)string("healthy"), heap), heap, "healthy", false, {}, 0)
	// 8 x 32 KiB fill the 256 KiB session budget; the 9th compacts; 10..12 keep flowing.
	for i in 0..<12 do _bridge_pty_stream_queue_output(&slow, slice.clone(transmute([]byte)chunk, heap), heap, "slow", false, {}, 0)
	testing.expect(t, sync.atomic_load(&slow.active), "a compacted stream stays attached")
	testing.expect(t, sync.atomic_load(&healthy.active))
	testing.expect(t, bridge_pty_stream_outgoing_bytes <= BRIDGE_PANE_QUEUE_BYTES)
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, heap); delete(frames) }
	slow_payload := strings.builder_make()
	defer strings.builder_destroy(&slow_payload)
	resyncs := 0
	for frame in frames {
		if strings.contains(frame, "pane_resync_required") { resyncs += 1; continue }
		sid, payload, _, _, ok := pty_test_decode_output(frame)
		testing.expect(t, ok)
		if sid == "slow" do strings.write_string(&slow_payload, payload)
	}
	testing.expect_value(t, resyncs, 0)
	got := strings.to_string(slow_payload)
	testing.expect(t, strings.has_prefix(got, BRIDGE_PTY_STREAM_COMPACT_MARKER), "the kept tail is led by a clear-screen+home so the viewer sees a skip, not a torn join")
	// Tail kept = 2 x 32 KiB (<= 64 KiB), then frames 9..12.
	testing.expect_value(t, len(got), len(BRIDGE_PTY_STREAM_COMPACT_MARKER) + 6 * 32 * 1024)
	testing.expect_value(t, bridge_pty_stream_outgoing_bytes, 0)
}

@(test)
pane_overflow_storm_falls_back_to_resync_for_that_stream_only :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	slow := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	healthy := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	heap := runtime.heap_allocator()
	chunk := strings.repeat("x", 32 * 1024, heap)
	defer delete(chunk, heap)
	_bridge_pty_stream_queue_output(&healthy, slice.clone(transmute([]byte)string("healthy"), heap), heap, "healthy", false, {}, 0)
	// Never drained: compaction #1 at frame 9, #2 at ~15, #3 at ~21 -> storm -> resync.
	for i in 0..<30 do _bridge_pty_stream_queue_output(&slow, slice.clone(transmute([]byte)chunk, heap), heap, "slow", false, {}, 0)
	testing.expect(t, !sync.atomic_load(&slow.active), "a storming stream is detached for a fresh screen")
	testing.expect(t, sync.atomic_load(&healthy.active), "the healthy stream is untouched")
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, heap); delete(frames) }
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		sid, payload, _, _, _ := pty_test_decode_output(frames[0])
		testing.expect_value(t, sid, "healthy")
		testing.expect_value(t, payload, "healthy")
		testing.expect(t, strings.contains(frames[1], "pane_resync_required"))
	}
	testing.expect_value(t, bridge_pty_stream_outgoing_bytes, 0)
}

@(test)
pane_overflow_snapshot_or_global_still_resyncs :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	heap := runtime.heap_allocator()
	// Snapshot overflow: 2 MiB + 1 of snapshot records is never compacted.
	snap := Bridge_PTY_Stream_Worker{active = true, fd = -1, emitting_snapshot = true}
	big := strings.repeat("s", 512 * 1024, heap)
	defer delete(big, heap)
	for i in 0..<5 do _bridge_pty_stream_queue_output(&snap, slice.clone(transmute([]byte)big, heap), heap, "snap", false, {}, 0)
	testing.expect(t, !sync.atomic_load(&snap.active), "a snapshot overflow still resyncs")
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, heap); delete(frames) }
	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 do testing.expect(t, strings.contains(frames[0], "pane_resync_required"))
}

@(test)
pane_large_encrypted_snapshot_splits_before_encryption :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	prev_key, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer { if found { _ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEYRING") } }
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_ENC_VAULT_KEY))
	worker := Bridge_PTY_Stream_Worker{active = true, emitting_snapshot = true, fd = -1}
	source := strings.repeat("λ", 256 * 1024)
	defer delete(source)
	bridge_pty_stream_emit_frame(&worker, "pane", transmute([]byte)source)
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, runtime.heap_allocator()); delete(frames) }
	result := make([dynamic]byte)
	defer delete(result)
	// 256 Ki two-byte runes = 512 KiB of plaintext, cut at the snapshot cap BEFORE
	// encryption (REQ-PTY-NET-1), so every frame decrypts on its own.
	testing.expect_value(t, len(frames), (512 * 1024 + BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES - 1) / BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES)
	for frame in frames {
		_, plain, snapshot, encrypted, ok := pty_test_decode_output(frame, TEST_ENC_VAULT_KEY)
		testing.expect(t, encrypted)
		testing.expect(t, snapshot)
		testing.expect(t, ok)
		append(&result, ..transmute([]byte)plain)
	}
	testing.expect_value(t, string(result[:]), source)
}

// ---- REQ-BR-3: the event watcher follows a replaced daemon --------------------

// The pure decision. The incident's case is the identity row: the replacement daemon
// unlinked and re-bound the socket while the old daemon — and our connection to it —
// stayed alive and kept heartbeating, so there was neither EOF nor silence.
@(test)
bridge_br3_events_redial_decision :: proc(t: ^testing.T) {
	base := Pty_Host_Events_Daemon_Mark{generation = 4, identity = {dev = 1, ino = 100, ctime_sec = 10, ctime_nsec = 5}, has_id = true}

	testing.expect(t, !bridge_pty_host_events_should_redial(base, base, 0), "same daemon, fresh traffic: stay")
	testing.expect(t, !bridge_pty_host_events_should_redial(base, base, 89 * time.Second), "under the silence limit: stay")

	started := base
	started.generation = 5
	testing.expect(t, bridge_pty_host_events_should_redial(base, started, 0), "the bridge started a daemon: re-dial")

	rebound := base
	rebound.identity.ino = 101
	testing.expect(t, bridge_pty_host_events_should_redial(base, rebound, 0), "a different socket inode: re-dial")
	reused_ino := base
	reused_ino.identity.ctime_nsec = 6
	testing.expect(t, bridge_pty_host_events_should_redial(base, reused_ino, 0), "same inode number, new socket: re-dial")

	missing := base
	missing.has_id = false
	missing.identity = {}
	testing.expect(t, !bridge_pty_host_events_should_redial(base, missing, 0), "socket momentarily absent: a dial would fail, stay")

	testing.expect(t, bridge_pty_host_events_should_redial(base, base, 90 * time.Second), "silent for three heartbeats: re-dial")
}

@(private = "file")
br3_listen :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK || posix.listen(fd, 4) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(private = "file")
br3_run_once_thread :: proc(th: ^thread.Thread) {
	path := (^string)(th.data)^
	_ = bridge_pty_host_events_run_once(path)
}

// End to end against real sockets: run_once dials daemon A; then "daemon B" unlinks
// the path and binds a new socket there while A's connection stays open and silent —
// exactly the split brain. run_once must notice and return so the worker re-dials (to
// B). Before REQ-BR-3 it re-dialled only on EOF and sat on A forever.
@(test)
bridge_br3_events_worker_redials_when_the_socket_is_rebound :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/ham-br3-%d.sock", os.get_pid())
	defer delete(path)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	_ = posix.unlink(cpath)
	defer posix.unlink(cpath)

	a := br3_listen(path)
	testing.expect(t, a >= 0, "listener A")
	if a < 0 do return
	defer posix.close(a)

	th := thread.create(br3_run_once_thread)
	th.data = &path
	thread.start(th)
	conn_a := posix.accept(a, nil, nil)
	testing.expect(t, conn_a >= 0, "run_once dialled daemon A")

	// Let it settle into its read loop on A, then replace the daemon.
	time.sleep(300 * time.Millisecond)
	testing.expect(t, !thread.is_done(th), "still attached to A before the replacement")
	_ = posix.unlink(cpath)
	b := br3_listen(path)
	testing.expect(t, b >= 0, "listener B bound on the same path")
	defer if b >= 0 do posix.close(b)

	deadline := time.tick_now()
	for !thread.is_done(th) && time.tick_since(deadline) < 5 * time.Second do time.sleep(50 * time.Millisecond)
	testing.expect(t, thread.is_done(th), "run_once returned (to re-dial) although A's connection is still open")

	// Cleanup: closing A's end unblocks a run_once that did NOT notice (the pre-fix
	// behaviour), so the thread is always joinable.
	if conn_a >= 0 do posix.close(conn_a)
	thread.join(th)
	thread.destroy(th)
}

// ---- REQ-BR-4: never two daemons ----------------------------------------------

// ensure_daemon is asked for a daemon while the one THIS bridge started is still
// alive but not answering on its socket (the wedged-listener case). It must retire that
// process before starting a replacement. A `sleep` stands in for the wedged daemon and
// a script that just sleeps for the replacement; nothing listens on the socket, so the
// replacement never becomes ready — ensure_daemon fails, which is fine: what is asserted
// is the process count.
@(test)
bridge_br4_ensure_daemon_retires_a_live_prior_daemon_first :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	saved_socket := pty_host_daemon_socket
	saved_started := pty_host_daemon_started
	saved_process := pty_host_daemon_process
	saved_has := pty_host_daemon_has_process
	defer {
		pty_host_daemon_socket = saved_socket
		pty_host_daemon_started = saved_started
		pty_host_daemon_process = saved_process
		pty_host_daemon_has_process = saved_has
	}

	sock := fmt.aprintf("/tmp/ham-br4-%d.sock", os.get_pid())
	defer delete(sock)
	pty_host_daemon_socket = sock
	pty_host_daemon_started = true

	script := fmt.aprintf("/tmp/ham-br4-fake-daemon-%d.sh", os.get_pid())
	defer delete(script)
	_ = os.write_entire_file(script, transmute([]byte)string("#!/bin/sh\nexec sleep 600\n"))
	defer os.remove(script)
	cscript := strings.clone_to_cstring(script)
	defer delete(cscript)
	_ = posix.chmod(cscript, {.IRUSR, .IWUSR, .IXUSR})
	saved_bin := os.get_env_alloc("HEIMDALL_HAM_PTY_HOST_BIN", context.allocator)
	defer delete(saved_bin)
	_ = os.set_env("HEIMDALL_HAM_PTY_HOST_BIN", script)
	defer { if saved_bin != "" do _ = os.set_env("HEIMDALL_HAM_PTY_HOST_BIN", saved_bin); else do _ = os.unset_env("HEIMDALL_HAM_PTY_HOST_BIN") }

	prior, err := os.process_start(os.Process_Desc{command = []string{"sleep", "600"}})
	testing.expect(t, err == nil, "fake prior daemon started")
	if err != nil do return
	pty_host_daemon_process = prior
	pty_host_daemon_has_process = true

	_, ok := bridge_pty_host_ensure_daemon()
	testing.expect(t, !ok, "nothing answers on the socket, so no daemon is ready")

	// kill(pid, 0) rather than process_wait: a retired daemon's handle was already
	// closed by the wait that reaped it, and waiting on it again would close that fd
	// number a second time.
	prior_gone := posix.kill(posix.pid_t(prior.pid), posix.Signal(0)) != .OK && posix.errno() == .ESRCH
	testing.expect(t, prior_gone, "the live prior daemon was retired (and reaped) before a replacement was started")
	if !prior_gone {
		_ = os.process_kill(prior)
		_, _ = os.process_wait(prior)
	}

	testing.expect(t, pty_host_daemon_has_process, "the replacement is tracked")
	if pty_host_daemon_has_process {
		testing.expect(t, pty_host_daemon_process.pid != prior.pid, "and it is a different process")
		_ = os.process_kill(pty_host_daemon_process)
		_, _ = os.process_wait(pty_host_daemon_process)
		pty_host_daemon_has_process = false
	}
}
