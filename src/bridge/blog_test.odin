package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

@(private = "file")
max_size_entry :: proc(i: int) -> Blog_Entry {
	// The widest shape an entry can take: longest code, 4 fields including the
	// longest key/symbol names and the most negative i64, max count, big seq/ts.
	e := Blog_Entry{
		seq   = max(u64) - u64(i),
		ts_ms = max(i64),
		level = .Error,
		code  = .telemetry_collector_failed,
		count = contracts.BRIDGE_LOG_MAX_COUNT,
	}
	e.fields[0] = blog_sym(.command_kind, .agent_pty_input)
	e.fields[1] = blog_int(.duration_ms, min(i64))
	e.fields[2] = blog_sym(.stage, .android_keystore)
	e.fields[3] = blog_int(.hub_status, min(i64) + i64(i))
	e.n_fields = 4
	return e
}

@(test)
test_blog_frame_shape_and_size_cap :: proc(t: ^testing.T) {
	r: Blog_Ring
	for i in 0 ..< 25 do blog_enqueue(&r, max_size_entry(i))
	testing.expect_value(t, blog_pending_count(&r), 25)
	batch, dropped := blog_take_batch(&r)
	defer delete(batch)
	testing.expect_value(t, len(batch), contracts.BRIDGE_LOG_MAX_ENTRIES)
	testing.expect_value(t, dropped, u32(0))
	testing.expect_value(t, blog_pending_count(&r), 15)

	frame := blog_frame_json(batch, 65535)
	defer delete(frame)
	testing.expect(t, len(frame) <= contracts.BRIDGE_LOG_MAX_FRAME_BYTES, fmt.tprintf("frame of 10 max-size entries must be <= %d bytes, got %d", contracts.BRIDGE_LOG_MAX_FRAME_BYTES, len(frame)))
	testing.expect(t, len(frame) < contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES, "frame must never reach the chunk threshold")
	testing.expect(t, strings.has_prefix(frame, `{"type":"bridge_log","seq_from":1,"seq_to":10,"dropped":65535,"entries":[`), frame)

	val, err := json.parse_string(frame, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == nil, "frame must be valid JSON")
	obj := val.(json.Object)
	entries := obj["entries"].(json.Array)
	testing.expect_value(t, len(entries), 10)
	first := entries[0].(json.Object)
	testing.expect_value(t, first["level"].(json.String), "error")
	testing.expect_value(t, first["code"].(json.String), "telemetry_collector_failed")
	testing.expect_value(t, first["count"].(json.Float), 1000)
	fields := first["fields"].(json.Object)
	testing.expect_value(t, fields["command_kind"].(json.String), "agent_pty_input")
	testing.expect_value(t, fields["stage"].(json.String), "android_keystore")
	_, dur_is_number := fields["duration_ms"].(json.Float)
	testing.expect(t, dur_is_number, "int fields are JSON numbers")
	testing.expect_value(t, len(fields), 4)
}

@(test)
test_blog_dedup_merges_identical_and_clamps_count :: proc(t: ^testing.T) {
	r: Blog_Ring
	for _ in 0 ..< 1500 {
		e := Blog_Entry{ts_ms = 1, level = .Warn, code = .hub_ws_closed, count = 1}
		e.fields[0] = blog_sym(.reason, .eof)
		e.n_fields = 1
		blog_enqueue(&r, e)
	}
	// A different field value is a different shape.
	other := Blog_Entry{ts_ms = 1, level = .Warn, code = .hub_ws_closed, count = 1}
	other.fields[0] = blog_sym(.reason, .timeout)
	other.n_fields = 1
	blog_enqueue(&r, other)
	// Same code, different level: distinct too.
	lvl := Blog_Entry{ts_ms = 1, level = .Error, code = .hub_ws_closed, count = 1}
	lvl.fields[0] = blog_sym(.reason, .eof)
	lvl.n_fields = 1
	blog_enqueue(&r, lvl)

	testing.expect_value(t, blog_pending_count(&r), 3)
	batch, _ := blog_take_batch(&r)
	defer delete(batch)
	testing.expect_value(t, batch[0].count, u32(contracts.BRIDGE_LOG_MAX_COUNT))
	testing.expect_value(t, batch[0].seq, u64(1))
	testing.expect_value(t, batch[1].seq, u64(2))
	testing.expect_value(t, batch[2].seq, u64(3))
	frame := blog_frame_json(batch, 0)
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"count":1000`), frame)
}

@(test)
test_blog_overflow_drops_oldest_and_counts :: proc(t: ^testing.T) {
	r: Blog_Ring
	for i in 0 ..< BLOG_RING_SLOTS + 44 {
		e := Blog_Entry{ts_ms = 1, level = .Error, code = .agent_exited_early, count = 1}
		e.fields[0] = blog_int(.exit_code, i64(i))
		e.n_fields = 1
		blog_enqueue(&r, e)
	}
	testing.expect_value(t, blog_pending_count(&r), BLOG_RING_SLOTS)
	batch, dropped := blog_take_batch(&r)
	defer delete(batch)
	testing.expect_value(t, dropped, u32(44))
	testing.expect_value(t, batch[0].seq, u64(45))
	testing.expect_value(t, batch[0].fields[0].int_value, i64(44))
	// Dropped is reported once, then reset.
	batch2, dropped2 := blog_take_batch(&r)
	defer delete(batch2)
	testing.expect_value(t, dropped2, u32(0))
	testing.expect_value(t, batch2[0].seq, u64(55))

	// Clamp: the counter never exceeds the wire bound.
	r2: Blog_Ring
	for i in 0 ..< BLOG_RING_SLOTS + 70000 {
		e := Blog_Entry{ts_ms = 1, level = .Warn, code = .internal, count = 1}
		e.fields[0] = blog_int(.attempt, i64(i))
		e.n_fields = 1
		blog_enqueue(&r2, e)
	}
	b3, d := blog_take_batch(&r2)
	delete(b3)
	testing.expect_value(t, d, u32(contracts.BRIDGE_LOG_MAX_DROPPED))
}

@(test)
test_blog_flush_cadence_10s_or_error_debounced :: proc(t: ^testing.T) {
	r: Blog_Ring
	base := i64(1_000_000_000_000)
	testing.expect(t, !blog_flush_due(&r, base), "empty ring never flushes")

	// Never flushed before + non-empty -> due immediately (reconnect backlog).
	blog_enqueue(&r, Blog_Entry{level = .Warn, code = .hub_ws_closed, count = 1})
	testing.expect(t, blog_flush_due(&r, base), "first flush is immediate")
	blog_mark_flushed(&r, base)

	// A warn alone waits for the 10 s cadence.
	blog_enqueue(&r, Blog_Entry{level = .Warn, code = .hub_ws_closed, count = 1})
	testing.expect(t, !blog_flush_due(&r, base + i64(5 * time.Second)), "warn: not due at 5 s")
	testing.expect(t, blog_flush_due(&r, base + i64(BLOG_FLUSH_INTERVAL)), "warn: due at 10 s")

	// An error flushes after the 1 s debounce.
	blog_enqueue(&r, Blog_Entry{level = .Error, code = .provider_missing, count = 1})
	testing.expect(t, !blog_flush_due(&r, base + i64(500 * time.Millisecond)), "error: debounced under 1 s")
	testing.expect(t, blog_flush_due(&r, base + i64(BLOG_ERROR_DEBOUNCE)), "error: due at 1 s")

	// Draining everything clears the error flag.
	b, _ := blog_take_batch(&r)
	delete(b)
	blog_mark_flushed(&r, base + i64(2 * time.Second))
	blog_enqueue(&r, Blog_Entry{level = .Warn, code = .hub_ws_closed, count = 1})
	testing.expect(t, !blog_flush_due(&r, base + i64(4 * time.Second)), "error flag does not leak into the next window")
}

@(test)
test_blog_restore_batch_keeps_order_and_dropped :: proc(t: ^testing.T) {
	r: Blog_Ring
	for i in 0 ..< 12 {
		e := Blog_Entry{level = .Warn, code = .hub_connect_failed, count = 1}
		e.fields[0] = blog_int(.attempt, i64(i))
		e.n_fields = 1
		blog_enqueue(&r, e)
	}
	batch, dropped := blog_take_batch(&r)
	testing.expect_value(t, len(batch), 10)
	blog_restore_batch(&r, batch, dropped + 3)
	delete(batch)
	testing.expect_value(t, blog_pending_count(&r), 12)
	again, dropped2 := blog_take_batch(&r)
	defer delete(again)
	testing.expect_value(t, dropped2, u32(3))
	for e, i in again do testing.expect_value(t, e.seq, u64(i + 1))
}

@(test)
test_blog_codes_keys_syms_round_trip :: proc(t: ^testing.T) {
	for code in Blog_Code {
		name := contracts.bridge_log_code_name(code)
		testing.expect(t, name != "", "every code has a wire name")
		back, ok := contracts.bridge_log_code_from_name(name)
		testing.expect(t, ok && back == code, name)
		for c in name do testing.expect(t, (c >= 'a' && c <= 'z') || c == '_', "code names are snake_case")
		e := Blog_Entry{seq = 1, level = .Error, code = code, count = 1}
		frame := blog_frame_json({e}, 0)
		defer delete(frame)
		testing.expect(t, strings.contains(frame, fmt.tprintf(`"code":"%s"`, name)), frame)
	}
	for key in Blog_Key {
		name := contracts.bridge_log_key_name(key)
		back, ok := contracts.bridge_log_key_from_name(name)
		testing.expect(t, ok && back == key, name)
	}
	for sym in Blog_Sym {
		name := contracts.bridge_log_sym_name(sym)
		back, ok := contracts.bridge_log_sym_from_name(name)
		testing.expect(t, ok && back == sym, name)
	}
	_, unknown_ok := contracts.bridge_log_code_from_name("made_up")
	testing.expect(t, !unknown_ok, "unknown code name is not accepted")
	testing.expect_value(t, contracts.bridge_log_provider_sym("claude"), Blog_Sym.claude)
	testing.expect_value(t, contracts.bridge_log_provider_sym("/usr/bin/evil"), Blog_Sym.other)

	// Rendering: every field prints as key=value, ints as decimals.
	e := Blog_Entry{level = .Warn, code = .agent_exited_early, count = 1}
	e.fields[0] = blog_sym(.provider, .codex)
	e.fields[1] = blog_int(.exit_code, -1)
	e.n_fields = 2
	line := blog_render_line(e)
	defer delete(line)
	testing.expect_value(t, line, "ham-bridge WARN agent_exited_early provider=codex exit_code=-1")
}

@(test)
test_blog_connect_failure_classification :: proc(t: ^testing.T) {
	code, stage, why := blog_connect_failure("could not start the TLS relay socat: not found")
	testing.expect(t, code == .tls_backend_missing && stage == .tls && why == .missing_binary, "missing relay binary")
	code, stage, why = blog_connect_failure("handshake timed out after 10s with no response from h:443 (...)")
	testing.expect(t, code == .hub_connect_failed && stage == .tcp && why == .timeout, "timeout")
	code, stage, _ = blog_connect_failure("TLS relay closed before any handshake response from h:443 (TLS verification or connection failure)")
	testing.expect(t, code == .hub_connect_failed && stage == .tls, "tls")
	code, stage, _ = blog_connect_failure("handshake rejected by h:443: HTTP/1.1 401 Unauthorized")
	testing.expect(t, code == .hub_connect_failed && stage == .ws_upgrade, "upgrade")
	testing.expect_value(t, blog_http_status_from_reason("handshake rejected by h:443: HTTP/1.1 401 Unauthorized"), i64(401))
	testing.expect_value(t, blog_http_status_from_reason("handshake rejected by h:443: garbage"), i64(0))
	testing.expect_value(t, blog_hub_error_reason("hub rejected bridge session after hello: bridge revoked"), Blog_Sym.revoked)
	testing.expect_value(t, blog_hub_error_reason("something else"), Blog_Sym.unknown)
	testing.expect_value(t, blog_bootstrap_stage("blob_fetch"), Blog_Sym.blob)
	testing.expect_value(t, blog_bootstrap_stage("nope"), Blog_Sym.other)
	testing.expect(t, blog_startup_reason_is_login("login_required"), "login reason")
	testing.expect(t, !blog_startup_reason_is_login("permission_prompt"), "non-login reason")
}

@(private = "file")
blog_fake_ws :: proc() -> (conn: ws.Connection, read_fd: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK do return {}, -1, false
	return ws.Connection{connected = true, socket = net.TCP_Socket(fds[1])}, fds[0], true
}

// Drain: gated by the telemetry switch (buffering continues while off), sends
// exactly one frame per call on the live connection, and nothing is lost on a
// dead socket (the batch goes back to the ring for the next ready connection).
@(test)
test_blog_drain_respects_opt_out_and_sends_frame :: proc(t: ^testing.T) {
	prev_enabled := bridge_heartbeat_stats_enabled()
	defer bridge_heartbeat_stats_set_enabled(prev_enabled)
	blog_reset(&blog_ring)
	defer blog_reset(&blog_ring)

	conn, read_fd, ok := blog_fake_ws()
	testing.expect(t, ok, "socketpair")
	if !ok do return

	now := time.tick_now()._nsec
	bridge_heartbeat_stats_set_enabled(false)
	blog_emit(.Error, .provider_missing, {blog_sym(.provider, .gemini)}, now_ms = 1700000000000)
	testing.expect(t, !bridge_log_drain_outgoing_at(&conn, now), "opt-out: nothing is shipped")
	testing.expect(t, blog_pending_count(&blog_ring) >= 1, "opt-out: the ring still buffers")
	testing.expect(t, conn.connected, "opt-out: connection untouched")

	bridge_heartbeat_stats_set_enabled(true)
	testing.expect(t, bridge_log_drain_outgoing_at(&conn, now), "enabled: one frame goes out")
	buf: [8192]byte
	n := posix.read(read_fd, &buf[0], len(buf))
	testing.expect(t, n > 0, "frame bytes on the wire")
	wire := string(buf[:max(n, 0)])
	testing.expect(t, strings.contains(wire, `"type":"bridge_log"`), wire)
	testing.expect(t, strings.contains(wire, `"code":"provider_missing"`), wire)
	testing.expect(t, strings.contains(wire, `"fields":{"provider":"gemini"}`), wire)
	testing.expect(t, strings.contains(wire, `"ts_ms":1700000000000`), wire)
	testing.expect(t, !blog_flush_due(&blog_ring, now), "nothing left / cadence resets after a send")

	posix.close(read_fd)
	posix.close(posix.FD(conn.socket))

	// Dead socket (peer already closed): the batch is restored and the
	// connection is marked dead so the loop exits and reconnects.
	blog_emit(.Error, .pty_host_unreachable, {blog_sym(.stage, .ready)}, now_ms = 1700000000001)
	dead_fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &dead_fds) != .OK do return
	posix.close(dead_fds[0])
	dead := ws.Connection{connected = true, socket = net.TCP_Socket(dead_fds[1])}
	before := blog_pending_count(&blog_ring)
	testing.expect(t, !bridge_log_drain_outgoing_at(&dead, now + i64(BLOG_FLUSH_INTERVAL)), "send on a dead socket fails")
	testing.expect(t, !dead.connected, "dead socket marks the connection closed")
	testing.expect_value(t, blog_pending_count(&blog_ring), before)
	posix.close(dead_fds[1])
}

// set_telemetry carries two switches: `enabled` (Telegraf) and
// `heartbeat_stats` (stats + bridge_log shipping). "inherit" at PATCH time is
// enabled=false,heartbeat_stats=true and must leave shipping ON; "disabled" is
// false/false; "enabled" is true/true. An old hub sends only `enabled`, which
// then drives both (legacy).
@(test)
test_blog_set_telemetry_two_flags_govern_shipping :: proc(t: ^testing.T) {
	prev := bridge_heartbeat_stats_enabled()
	defer bridge_heartbeat_stats_set_enabled(prev)

	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"","enabled":false,"heartbeat_stats":true}`)
	testing.expect(t, bridge_heartbeat_stats_enabled(), "inherit: stats/log shipping stay ON while Telegraf is off")
	testing.expect(t, !bridge_telemetry_status(), "inherit: Telegraf off")

	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"","enabled":false,"heartbeat_stats":false}`)
	testing.expect(t, !bridge_heartbeat_stats_enabled(), "disabled: shipping OFF")

	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"","enabled":true,"heartbeat_stats":true}`)
	testing.expect(t, bridge_heartbeat_stats_enabled(), "enabled: shipping ON")
	_ = bridge_telemetry_stop()

	// Legacy single-flag hub.
	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"","enabled":false}`)
	testing.expect(t, !bridge_heartbeat_stats_enabled(), "legacy enabled=false turns shipping off")
	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"","enabled":true}`)
	testing.expect(t, bridge_heartbeat_stats_enabled(), "legacy enabled=true turns shipping on")
	_ = bridge_telemetry_stop()
}
