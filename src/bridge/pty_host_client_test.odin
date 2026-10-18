#+build !windows
package main

import "core:sys/posix"
import "core:testing"

// BR-2 codec tests: the Odin pty-host client must be byte-for-byte compatible
// with the Rust daemon protocol (tools/pty_host/src/dproto.rs). We assert exact
// wire bytes for the encoders and full round-trips for the reply decoder, so a
// drift on either side is caught here rather than at runtime against a live host.

// pty_host_test_reframe strips the 4-byte length prefix and returns the payload
// slice, asserting the prefix matches the payload length.
pty_host_test_reframe :: proc(t: ^testing.T, framed: []byte) -> []byte {
	testing.expect(t, len(framed) >= 4, "framed msg must have a length prefix")
	length := int(framed[0]) << 24 | int(framed[1]) << 16 | int(framed[2]) << 8 | int(framed[3])
	testing.expect_value(t, length, len(framed) - 4)
	return framed[4:]
}

@(test)
pty_host_encode_list_ping_are_single_tag :: proc(t: ^testing.T) {
	lst := pty_host_encode_list()
	defer delete(lst)
	pl := pty_host_test_reframe(t, lst)
	testing.expect_value(t, len(pl), 1)
	testing.expect_value(t, pl[0], u8(PTY_HOST_T_LIST))

	png := pty_host_encode_ping()
	defer delete(png)
	pp := pty_host_test_reframe(t, png)
	testing.expect_value(t, len(pp), 1)
	testing.expect_value(t, pp[0], u8(PTY_HOST_T_PING))
}

@(test)
pty_host_encode_instance_only_shape :: proc(t: ^testing.T) {
	// Close "ab": tag(0x21) + u32 len(2) + "ab"
	msg := pty_host_encode_close("ab")
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	want := []byte{PTY_HOST_T_CLOSE, 0, 0, 0, 2, 'a', 'b'}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])

	restart := pty_host_encode_restart("ab")
	defer delete(restart)
	rpl := pty_host_test_reframe(t, restart)
	testing.expect_value(t, rpl[0], u8(PTY_HOST_T_RESTART))
}

@(test)
pty_host_encode_key_shape :: proc(t: ^testing.T) {
	// Key "a" Enter: tag(0x32) + u32 len(1) + "a" + key byte(1)
	msg := pty_host_encode_key("a", .Enter)
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	want := []byte{PTY_HOST_T_KEY, 0, 0, 0, 1, 'a', 1}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
	// Verify a couple of discriminants match proto.rs NamedKey.
	testing.expect_value(t, u8(Pty_Host_Key.Ctrl_C), 3)
	testing.expect_value(t, u8(Pty_Host_Key.Ctrl_Backslash), 11)
	testing.expect_value(t, u8(Pty_Host_Key.Delete), 16)
}

@(test)
pty_host_encode_input_shape :: proc(t: ^testing.T) {
	// Input "a" "hi": tag(0x31) + u32 len(1) + "a" + raw "hi"
	data := []byte{'h', 'i'}
	msg := pty_host_encode_input("a", data)
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	want := []byte{PTY_HOST_T_INPUT, 0, 0, 0, 1, 'a', 'h', 'i'}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
}

@(test)
pty_host_encode_resize_shape :: proc(t: ^testing.T) {
	// Resize "a" 50x200: tag(0x33) + len(1)+"a" + u16 50 + u16 200
	msg := pty_host_encode_resize("a", 50, 200)
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	want := []byte{PTY_HOST_T_RESIZE, 0, 0, 0, 1, 'a', 0, 50, 0, 200}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
}

@(test)
pty_host_encode_spawn_full_shape :: proc(t: ^testing.T) {
	req := Pty_Host_Spawn_Request{
		instance = "i",
		argv = []string{"true"},
		cwd = "/w",
		has_cwd = true,
		env = [][2]string{{"K", "V"}},
		detect = "{}",
		has_detect = true,
		display_name = "default-agent #20",
		has_display_name = true,
		has_timeout_seconds = true,
		timeout_seconds = 120,
		rows = 24,
		cols = 80,
	}
	msg := pty_host_encode_spawn(req)
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	// tag + instance("i") + argc(1) + argv0("true") + opt cwd(1,"/w")
	// + envc(1) + K + V + opt detect(1,"{}") + rows(24) + cols(80) + opt display_name(1, "default-agent #20")
	disp_name := "default-agent #20"
	want := []byte{
		PTY_HOST_T_SPAWN,
		0, 0, 0, 1, 'i',
		0, 1, // argc u16
		0, 0, 0, 4, 't', 'r', 'u', 'e',
		1, 0, 0, 0, 2, '/', 'w', // opt cwd present
		0, 1, // envc u16
		0, 0, 0, 1, 'K',
		0, 0, 0, 1, 'V',
		1, 0, 0, 0, 2, '{', '}', // opt detect present
		0, 24, // rows
		0, 80, // cols
		1, 0, 0, 0, u8(len(disp_name)),
	}
	// append disp_name bytes
	full_want := make([dynamic]byte); defer delete(full_want)
	append(&full_want, ..want)
	for i in 0..<len(disp_name) do append(&full_want, disp_name[i])
	// opt kind(0), label(0), meta(0), tee_path(0), timeout(1, u64=120)
	append(&full_want, 0, 0, 0, 0)
	append(&full_want, 1, 0, 0, 0, 0, 0, 0, 0, 120)

	testing.expect_value(t, len(pl), len(full_want))
	for i in 0..<len(full_want) do testing.expect_value(t, pl[i], full_want[i])
}

@(test)
pty_host_encode_spawn_minimal_omits_opts :: proc(t: ^testing.T) {
	req := Pty_Host_Spawn_Request{
		instance = "i",
		argv = []string{"true"},
		has_cwd = false,
		has_detect = false,
		has_display_name = false,
		rows = 24,
		cols = 80,
	}
	msg := pty_host_encode_spawn(req)
	defer delete(msg)
	pl := pty_host_test_reframe(t, msg)
	// opt cwd absent => single 0 byte; envc 0; opt detect absent => single 0 byte; rows; cols; opt display_name absent => single 0 byte
	// opt kind, label, meta, tee_path absent => each single 0 byte
	want := []byte{
		PTY_HOST_T_SPAWN,
		0, 0, 0, 1, 'i',
		0, 1,
		0, 0, 0, 4, 't', 'r', 'u', 'e',
		0, // opt cwd absent
		0, 0, // envc u16 = 0
		0, // opt detect absent
		0, 24,
		0, 80,
		0, // opt display_name absent
		0, // opt kind absent
		0, // opt label absent
		0, // opt meta absent
		0, // opt tee_path absent
		0, // opt timeout_seconds absent
	}
	testing.expect_value(t, len(pl), len(want))
	for i in 0..<len(want) do testing.expect_value(t, pl[i], want[i])
}

// ---- reply decode round-trips (encode with our put_* then decode) --------

@(test)
pty_host_decode_spawned :: proc(t: ^testing.T) {
	// Build a Spawned payload: tag + instance + i32 pid
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_SPAWNED)
	pty_host_put_str(&p, "inst_abc")
	pty_host_put_i32(&p, 4242)
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode Spawned")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Spawned)
	testing.expect_value(t, r.instance, "inst_abc")
	testing.expect_value(t, r.pid, i32(4242))
}

@(test)
pty_host_decode_restarted :: proc(t: ^testing.T) {
	// The UI restart control maps to host.restart; the daemon acks with Restarted{pid}.
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_RESTARTED)
	pty_host_put_str(&p, "inst_r")
	pty_host_put_i32(&p, 5150)
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode Restarted")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Restarted)
	testing.expect_value(t, r.instance, "inst_r")
	testing.expect_value(t, r.pid, i32(5150))
	// And the restart request encodes to tag 0x22 + instance.
	req := pty_host_encode_restart("inst_r")
	defer delete(req)
	rp := pty_host_test_reframe(t, req)
	want := []byte{PTY_HOST_T_RESTART, 0, 0, 0, 6, 'i', 'n', 's', 't', '_', 'r'}
	testing.expect_value(t, len(rp), len(want))
	for i in 0..<len(want) do testing.expect_value(t, rp[i], want[i])
}

@(test)
pty_host_decode_child_exited_and_error :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_EXITED)
	pty_host_put_str(&p, "a")
	pty_host_put_i32(&p, 137)
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode ChildExited")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Child_Exited)
	testing.expect_value(t, r.code, i32(137))

	e := make([dynamic]byte); defer delete(e)
	append(&e, PTY_HOST_T_ERROR)
	pty_host_put_str(&e, "a")
	pty_host_put_str(&e, "no such instance")
	er, eok := pty_host_decode_reply(e[:])
	defer pty_host_reply_delete(er)
	testing.expect(t, eok, "decode Error")
	testing.expect_value(t, er.kind, Pty_Host_Reply_Kind.Error)
	testing.expect_value(t, er.message, "no such instance")
}

@(test)
pty_host_decode_agent_list_mixed :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_AGENTLIST)
	pty_host_put_u16(&p, 2)
	// agent 1: alive, no exit code
	pty_host_put_str(&p, "inst_1")
	pty_host_put_str(&p, "/bin/zsh")
	pty_host_put_i32(&p, 111)
	append(&p, 1) // alive
	append(&p, 0) // has_code = 0
	pty_host_put_u16(&p, 24)
	pty_host_put_u16(&p, 80)
	pty_host_put_u64(&p, 1_700_000_000)
	pty_host_put_u64(&p, 1_700_000_050)
	pty_host_put_opt_str(&p, true, "default-agent #20")
	// agent 2: dead, exit code 0
	pty_host_put_str(&p, "inst_2")
	pty_host_put_str(&p, "claude")
	pty_host_put_i32(&p, 222)
	append(&p, 0) // dead
	append(&p, 1) // has_code = 1
	pty_host_put_i32(&p, 0)
	pty_host_put_u16(&p, 40)
	pty_host_put_u16(&p, 120)
	pty_host_put_u64(&p, 1_700_000_100)
	pty_host_put_u64(&p, 1_700_000_100)
	pty_host_put_opt_str(&p, false, "")

	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode AgentList")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Agent_List)
	testing.expect_value(t, len(r.agents), 2)
	testing.expect_value(t, r.agents[0].instance_id, "inst_1")
	testing.expect_value(t, r.agents[0].alive, true)
	testing.expect_value(t, r.agents[0].has_exit_code, false)
	testing.expect_value(t, r.agents[0].last_activity, u64(1_700_000_050))
	testing.expect_value(t, r.agents[0].display_name, "default-agent #20")
	testing.expect_value(t, r.agents[0].has_display_name, true)
	testing.expect_value(t, r.agents[1].instance_id, "inst_2")
	testing.expect_value(t, r.agents[1].alive, false)
	testing.expect_value(t, r.agents[1].has_exit_code, true)
	testing.expect_value(t, r.agents[1].exit_code, i32(0))
	testing.expect_value(t, r.agents[1].cols, u16(120))
	testing.expect_value(t, r.agents[1].has_display_name, false)
}

@(test)
pty_host_decode_screen :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_SCREEN)
	pty_host_put_str(&p, "a")
	pty_host_put_u16(&p, 3)   // rows
	pty_host_put_u16(&p, 10)  // cols
	pty_host_put_u16(&p, 1)   // cursor_row
	pty_host_put_u16(&p, 2)   // cursor_col
	pty_host_put_u16(&p, 3)   // line count
	pty_host_put_str(&p, "hello")
	pty_host_put_str(&p, "")
	pty_host_put_str(&p, "world")
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode Screen")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Screen)
	testing.expect_value(t, r.instance, "a")
	testing.expect_value(t, r.screen.rows, u16(3))
	testing.expect_value(t, r.screen.cursor_col, u16(2))
	testing.expect_value(t, len(r.screen.lines), 3)
	testing.expect_value(t, r.screen.lines[0], "hello")
	testing.expect_value(t, r.screen.lines[1], "")
	testing.expect_value(t, r.screen.lines[2], "world")
}

@(test)
pty_host_decode_output_and_pong :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_OUTPUT)
	pty_host_put_str(&p, "a")
	append(&p, 0x1b, '[', '3', '1', 'm')
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode Output")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Output)
	testing.expect_value(t, len(r.data), 5)
	testing.expect_value(t, r.data[0], u8(0x1b))

	pong := []byte{PTY_HOST_T_PONG}
	pr, pok := pty_host_decode_reply(pong)
	defer pty_host_reply_delete(pr)
	testing.expect(t, pok, "decode Pong")
	testing.expect_value(t, pr.kind, Pty_Host_Reply_Kind.Pong)
}

// ---- control/event interleaving (BR-3 live-repro regression) --------------
//
// The daemon may interleave async events (ScreenChanged/Output/...) into any
// connection, including a control-only one. pty_host_read_control_reply must skip
// those and return the first CONTROL reply. This reproduces the exact live failure
// the reviewer hit (restart against a busy agent got a ScreenChanged) over a real
// socketpair, and proves the bridge is robust to it regardless of the host fix.

@(test)
pty_host_request_skips_async_before_control_reply :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		testing.expect(t, false, "socketpair failed")
		return
	}
	writer := fds[0]
	reader := fds[1]
	defer posix.close(writer)
	defer posix.close(reader)

	// Write two ScreenChanged events (what a busy agent emits), then the real
	// Restarted control reply — the interleaving the reviewer observed live.
	pty_host_test_write_screen_changed(writer, "t1", 0x1111)
	pty_host_test_write_screen_changed(writer, "t1", 0x2222)
	frame := make([dynamic]byte); defer delete(frame)
	append(&frame, PTY_HOST_T_RESTARTED)
	pty_host_put_str(&frame, "t1")
	pty_host_put_i32(&frame, 4242)
	framed := pty_host_frame(frame[:]); defer delete(framed)
	_ = pty_host_send_all(writer, framed)

	reply, ok := pty_host_read_control_reply(reader)
	defer pty_host_reply_delete(reply)
	testing.expect(t, ok, "control reply read past async events")
	testing.expect_value(t, reply.kind, Pty_Host_Reply_Kind.Restarted)
	testing.expect_value(t, reply.instance, "t1")
	testing.expect_value(t, reply.pid, i32(4242))
}

@(test)
pty_host_reply_is_async_classification :: proc(t: ^testing.T) {
	// Async events skipped by a control read.
	testing.expect(t, pty_host_reply_is_async(.Output), "Output async")
	testing.expect(t, pty_host_reply_is_async(.Child_Exited), "ChildExited async")
	testing.expect(t, pty_host_reply_is_async(.Screen_Changed), "ScreenChanged async")
	testing.expect(t, pty_host_reply_is_async(.Startup_Ready), "StartupReady async")
	testing.expect(t, pty_host_reply_is_async(.Startup_Blocked), "StartupBlocked async")
	// Control replies are NOT async.
	testing.expect(t, !pty_host_reply_is_async(.Spawned), "Spawned control")
	testing.expect(t, !pty_host_reply_is_async(.Closed), "Closed control")
	testing.expect(t, !pty_host_reply_is_async(.Restarted), "Restarted control")
	testing.expect(t, !pty_host_reply_is_async(.Agent_List), "AgentList control")
	testing.expect(t, !pty_host_reply_is_async(.Screen), "Screen control (capture reply)")
	testing.expect(t, !pty_host_reply_is_async(.Pong), "Pong control")
	testing.expect(t, !pty_host_reply_is_async(.Error), "Error control")
}

// pty_host_test_write_screen_changed frames+writes a ScreenChanged event to fd.
pty_host_test_write_screen_changed :: proc(fd: posix.FD, instance: string, hash: u64) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_SCREEN_CHANGED)
	pty_host_put_str(&p, instance)
	pty_host_put_u64(&p, hash)
	framed := pty_host_frame(p[:]); defer delete(framed)
	_ = pty_host_send_all(fd, framed)
}

@(test)
pty_host_decode_rejects_empty_and_unknown :: proc(t: ^testing.T) {
	_, ok := pty_host_decode_reply([]byte{})
	testing.expect(t, !ok, "empty payload rejected")
	_, ok2 := pty_host_decode_reply([]byte{0xFF})
	testing.expect(t, !ok2, "unknown tag rejected")
}

// ---- HOST-2 event decode (tags 0xA9/0xAA/0xAB, matching dproto.rs) --------

@(test)
pty_host_decode_startup_ready :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_STARTUP_READY)
	pty_host_put_str(&p, "inst_x")
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode StartupReady")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Startup_Ready)
	testing.expect_value(t, r.instance, "inst_x")
}

@(test)
pty_host_decode_startup_blocked :: proc(t: ^testing.T) {
	// instance + reason_code + safe_diagnostic
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_STARTUP_BLOCKED)
	pty_host_put_str(&p, "inst_x")
	pty_host_put_str(&p, "blocked_0trust")
	pty_host_put_str(&p, "folder trust prompt not auto-dismissable")
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode StartupBlocked")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Startup_Blocked)
	testing.expect_value(t, r.instance, "inst_x")
	testing.expect_value(t, r.reason_code, "blocked_0trust")
	testing.expect_value(t, r.message, "folder trust prompt not auto-dismissable")
}

@(test)
pty_host_decode_screen_changed :: proc(t: ^testing.T) {
	// instance + u64 hash
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_SCREEN_CHANGED)
	pty_host_put_str(&p, "inst_x")
	pty_host_put_u64(&p, 0xDEADBEEFCAFE1234)
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode ScreenChanged")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Screen_Changed)
	testing.expect_value(t, r.instance, "inst_x")
	testing.expect_value(t, r.hash, u64(0xDEADBEEFCAFE1234))
}

// REQ-STREAM-EVENT-2: PTY stream lifecycle event decoding (tags 0xAE/0xAF)

@(test)
pty_host_decode_stream_ready :: proc(t: ^testing.T) {
	p := make([dynamic]byte); defer delete(p)
	append(&p, PTY_HOST_T_STREAM_READY)
	pty_host_put_str(&p, "inst_ready")
	r, ok := pty_host_decode_reply(p[:])
	defer pty_host_reply_delete(r)
	testing.expect(t, ok, "decode StreamReady")
	testing.expect_value(t, r.kind, Pty_Host_Reply_Kind.Stream_Ready)
	testing.expect_value(t, r.instance, "inst_ready")
}

@(test)
pty_host_decode_stream_closed :: proc(t: ^testing.T) {
	// With exit code
	p1 := make([dynamic]byte); defer delete(p1)
	append(&p1, PTY_HOST_T_STREAM_CLOSED)
	pty_host_put_str(&p1, "inst_closed_code")
	append(&p1, 1) // has_code = 1
	pty_host_put_i32(&p1, 0)
	r1, ok1 := pty_host_decode_reply(p1[:])
	defer pty_host_reply_delete(r1)
	testing.expect(t, ok1, "decode StreamClosed with code")
	testing.expect_value(t, r1.kind, Pty_Host_Reply_Kind.Stream_Closed)
	testing.expect_value(t, r1.instance, "inst_closed_code")
	testing.expect_value(t, r1.has_code, true)
	testing.expect_value(t, r1.code, i32(0))

	// Without exit code
	p2 := make([dynamic]byte); defer delete(p2)
	append(&p2, PTY_HOST_T_STREAM_CLOSED)
	pty_host_put_str(&p2, "inst_closed_nocode")
	append(&p2, 0) // has_code = 0
	r2, ok2 := pty_host_decode_reply(p2[:])
	defer pty_host_reply_delete(r2)
	testing.expect(t, ok2, "decode StreamClosed without code")
	testing.expect_value(t, r2.kind, Pty_Host_Reply_Kind.Stream_Closed)
	testing.expect_value(t, r2.instance, "inst_closed_nocode")
	testing.expect_value(t, r2.has_code, false)
}
