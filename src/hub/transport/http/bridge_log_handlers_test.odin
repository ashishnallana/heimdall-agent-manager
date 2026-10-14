package http

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

@(private = "file")
NOW_MS :: i64(1_700_000_000_000)

@(private = "file")
log_frame :: proc(entries: string, dropped := 0) -> string {
	return fmt.aprintf(`{{"type":"bridge_log","seq_from":1,"seq_to":1,"dropped":%d,"entries":[%s]}`, dropped, entries)
}

@(private = "file")
entry :: proc(level, code, fields: string, count := 1, ts: i64 = NOW_MS - 1000) -> string {
	return fmt.tprintf(`{{"seq":1,"ts_ms":%d,"level":"%s","code":"%s","fields":%s,"count":%d}`, ts, level, code, fields, count)
}

@(private = "file")
fresh_connection :: proc() -> project_service.Bridge_Runtime_Connection {
	return project_service.Bridge_Runtime_Connection{telemetry_enabled = true}
}

@(test)
test_bridge_log_frame_caps_and_shape :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_log_caps"

	// Oversize frame refused whole.
	big := strings.repeat(" ", contracts.BRIDGE_LOG_MAX_FRAME_BYTES + 1)
	defer delete(big)
	st := bridge_apply_log_frame(nil, bid, big, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Rejected_Oversize)
	testing.expect(t, metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_oversize")) >= 1, "oversize counted")

	// Missing / unbalanced entries.
	st = bridge_apply_log_frame(nil, bid, `{"type":"bridge_log"}`, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Rejected_Bad_Json)
	st = bridge_apply_log_frame(nil, bid, `{"type":"bridge_log","entries":[{"level":"warn"`, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Rejected_Bad_Json)

	// 11 entries: refused whole, nothing counted.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 11 {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, entry("error", "internal", `{"stage":"spawn"}`))
	}
	f11 := log_frame(strings.to_string(b))
	defer delete(f11)
	// Tests in this package run in parallel against one global registry, so
	// assert deltas on series only this test touches.
	before_errors := metrics.counter_value(metrics.with(m.bridge_errors, "tls_backend_missing", "warn"))
	before_dropped := metrics.counter_value(m.bridge_log_dropped)
	before_too_many := metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_too_many"))
	st = bridge_apply_log_frame(nil, bid, f11, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Rejected_Too_Many)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_errors, "tls_backend_missing", "warn")), before_errors)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_too_many")) - before_too_many, u64(1))

	// Exactly 10 is fine; dropped hint is clamped and counted.
	strings.builder_reset(&b)
	for i in 0 ..< 10 {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, entry("warn", "tls_backend_missing", `{"reason":"missing_binary"}`))
	}
	f10 := log_frame(strings.to_string(b), 99_999)
	defer delete(f10)
	st = bridge_apply_log_frame(nil, bid, f10, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Applied)
	testing.expect_value(t, st.accepted, 10)
	testing.expect_value(t, st.dropped_hint, contracts.BRIDGE_LOG_MAX_DROPPED)
	testing.expect_value(t, metrics.counter_value(m.bridge_log_dropped) - before_dropped, u64(contracts.BRIDGE_LOG_MAX_DROPPED))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_errors, "tls_backend_missing", "warn")) - before_errors, u64(10))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_errors_by_bridge, bid)), u64(10))
}

@(test)
test_bridge_log_entry_validation_enum_map_and_clamps :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_log_validate"

	// Unknown code -> "other" (never a new label), count clamped, ts clamped
	// both ways, unknown symbol -> "other", int field kept.
	e, ok := bridge_log_validate_entry(bid, entry("error", "brand_new_code", `{"stage":"from_the_future","exit_code":-7}`, 5000, NOW_MS + i64(time.Hour / time.Millisecond)), NOW_MS)
	testing.expect(t, ok, "valid shape")
	defer domain.bridge_log_event_destroy(&e)
	testing.expect_value(t, e.code, "other")
	testing.expect_value(t, e.level, "error")
	testing.expect_value(t, e.count, contracts.BRIDGE_LOG_MAX_COUNT)
	testing.expect_value(t, e.ts_ms, NOW_MS + i64(BRIDGE_LOG_TS_FUTURE / time.Millisecond))
	testing.expect_value(t, e.received_at, NOW_MS)
	testing.expect_value(t, e.fields_json, `{"stage":"other","exit_code":-7}`)
	testing.expect_value(t, e.bridge_id, bid)

	old, ok_old := bridge_log_validate_entry(bid, entry("warn", "provider_missing", `{"provider":"gemini"}`, 0, 12345), NOW_MS)
	testing.expect(t, ok_old, "old ts accepted")
	defer domain.bridge_log_event_destroy(&old)
	testing.expect_value(t, old.ts_ms, NOW_MS - i64(BRIDGE_LOG_TS_PAST / time.Millisecond))
	testing.expect_value(t, old.count, 1)
	testing.expect_value(t, old.code, "provider_missing")

	// Missing fields object -> "{}".
	nf, ok_nf := bridge_log_validate_entry(bid, `{"seq":1,"ts_ms":1,"level":"warn","code":"internal","count":1}`, NOW_MS)
	testing.expect(t, ok_nf, "no fields ok")
	defer domain.bridge_log_event_destroy(&nf)
	testing.expect_value(t, nf.fields_json, "{}")

	// Bad fields: unknown key, wrong types, too many keys, duplicate key, bad level.
	bad := [?]string{
		entry("error", "internal", `{"path":"/home/jane"}`),
		entry("error", "internal", `{"exit_code":"1"}`),
		entry("error", "internal", `{"stage":17}`),
		entry("error", "internal", `{"stage":"tls","reason":"eof","provider":"claude","exit_code":1,"port":80}`),
		entry("error", "internal", `{"stage":"tls","stage":"tcp"}`),
		entry("error", "internal", `{"exit_code":1.5}`),
		entry("error", "internal", `{"exit_code":true}`),
		entry("error", "internal", `{"stage":"tls"`),
		entry("info", "internal", `{}`),
		entry("", "internal", `{}`),
	}
	for raw, i in bad {
		_, bad_ok := bridge_log_validate_entry(bid, raw, NOW_MS)
		testing.expectf(t, !bad_ok, "bad entry %d must be rejected: %s", i, raw)
	}
	// Through the frame path they count as log_bad_field and nothing else.
	frame := log_frame(strings.join({entry("error", "internal", `{"path":"/home/jane"}`), entry("error", "internal", `{"stage":"tls"}`)}, ",", context.temp_allocator))
	defer delete(frame)
	before := metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_bad_field"))
	st := bridge_apply_log_frame(nil, bid, frame, nil, NOW_MS)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Applied)
	testing.expect_value(t, st.bad_field, 1)
	testing.expect_value(t, st.accepted, 1)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_bad_field")) - before, u64(1))
	// Fields never become labels: only {code, level} on bridge_errors.
	for s in m.bridge_errors.series do testing.expect(t, !strings.contains(s.label_values[0], "jane") && !strings.contains(s.label_values[1], "jane"), "no field value leaks into a label")
}

@(test)
test_bridge_log_opt_out_and_token_bucket :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_log_bucket"
	conn := fresh_connection()
	one := log_frame(entry("error", "pty_host_unreachable", `{"stage":"ready"}`))
	defer delete(one)

	// Opt-out: dropped silently, no counters.
	conn.telemetry_enabled = false
	st := bridge_apply_log_frame(nil, bid, one, &conn, NOW_MS, 1_000)
	testing.expect_value(t, st.result, Bridge_Log_Frame_Result.Dropped_Opted_Out)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_errors_by_bridge, bid)), u64(0))
	conn.telemetry_enabled = true

	// Burst: 300 entries pass, the 301st..310th are dropped; one rejection
	// counter tick per rate-limited frame.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 10 {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, entry("warn", "lsp_crashed", `{"reason":"timeout"}`))
	}
	ten := log_frame(strings.to_string(b))
	defer delete(ten)
	before_limited := metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_rate_limited"))
	tick := i64(1_000_000)
	accepted := 0
	limited := 0
	for _ in 0 ..< 31 {
		st = bridge_apply_log_frame(nil, bid, ten, &conn, NOW_MS, tick)
		accepted += st.accepted
		limited += st.rate_limited
	}
	testing.expect_value(t, accepted, BRIDGE_LOG_BUCKET_BURST)
	testing.expect_value(t, limited, 10)
	testing.expect_value(t, conn.log_tokens, 0)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_frames_rejected, "log_rate_limited")) - before_limited, u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_errors_by_bridge, bid)), u64(BRIDGE_LOG_BUCKET_BURST))

	// Still empty 400 ms later (refill is 1 token per 500 ms).
	st = bridge_apply_log_frame(nil, bid, one, &conn, NOW_MS, tick + i64(400 * time.Millisecond))
	testing.expect_value(t, st.rate_limited, 1)
	// 10 s later: 20 tokens -> a 10-entry frame passes twice, then dry again.
	tick += i64(BRIDGE_LOG_BUCKET_PERIOD)
	st = bridge_apply_log_frame(nil, bid, ten, &conn, NOW_MS, tick)
	testing.expect_value(t, st.accepted, 10)
	st = bridge_apply_log_frame(nil, bid, ten, &conn, NOW_MS, tick)
	testing.expect_value(t, st.accepted, 10)
	st = bridge_apply_log_frame(nil, bid, one, &conn, NOW_MS, tick)
	testing.expect_value(t, st.rate_limited, 1)
	// Never above the burst.
	tick += i64(100 * BRIDGE_LOG_BUCKET_PERIOD)
	bridge_log_bucket_refill(&conn, tick)
	testing.expect_value(t, conn.log_tokens, BRIDGE_LOG_BUCKET_BURST)

	// A replaced connection gets a fresh struct = a full bucket.
	conn2 := fresh_connection()
	st = bridge_apply_log_frame(nil, bid, ten, &conn2, NOW_MS, tick)
	testing.expect_value(t, st.accepted, 10)
	testing.expect_value(t, conn2.log_tokens, BRIDGE_LOG_BUCKET_BURST - 10)
}

@(test)
test_bridge_log_set_telemetry_payload_two_flags :: proc(t: ^testing.T) {
	inherit := bridge_set_telemetry_payload("c1", false, true)
	defer delete(inherit)
	testing.expect(t, strings.contains(inherit, `"enabled":false`) && strings.contains(inherit, `"heartbeat_stats":true`), inherit)
	disabled := bridge_set_telemetry_payload("c1", false, false)
	defer delete(disabled)
	testing.expect(t, strings.contains(disabled, `"enabled":false`) && strings.contains(disabled, `"heartbeat_stats":false`), disabled)
	enabled := bridge_set_telemetry_payload("c1", true)
	defer delete(enabled)
	testing.expect(t, strings.contains(enabled, `"enabled":true`) && strings.contains(enabled, `"heartbeat_stats":true`), enabled)
}

@(test)
test_bridge_log_render_covers_every_code :: proc(t: ^testing.T) {
	generic := bridge_log_render_title("definitely_unknown")
	for code in contracts.Bridge_Log_Code {
		name := contracts.bridge_log_code_name(code)
		title := bridge_log_render_title(name)
		testing.expectf(t, title != "" && title != generic && title != "Bridge event", "code %s has its own rendering", name)
	}
	msg := bridge_log_render_message("agent_exited_early", `{"provider":"codex","exit_code":1,"duration_ms":2500}`)
	defer delete(msg)
	testing.expect_value(t, msg, "Agent exited right after launch (provider: codex, exit code 1, after 2 s)")
	msg2 := bridge_log_render_message("hub_connect_failed", `{"stage":"ws_upgrade","hub_status":401}`)
	defer delete(msg2)
	testing.expect_value(t, msg2, "Could not connect to the hub (stage: ws_upgrade, HTTP 401)")
	msg3 := bridge_log_render_message("other", "{}")
	defer delete(msg3)
	testing.expect_value(t, msg3, generic)
	msg4 := bridge_log_render_message("hub_ws_closed", `{"reason":"replaced","duration_ms":250}`)
	defer delete(msg4)
	testing.expect_value(t, msg4, "Connection to the hub closed; reconnecting (reason: replaced, after 250 ms)")

	// The owner API row carries the rendered message and the raw fields.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_bridge_log_event_json(&b, domain.Bridge_Log_Event{id = 7, bridge_id = "brg", ts_ms = 1, received_at = 2, level = "warn", code = "provider_missing", fields_json = `{"provider":"claude"}`, count = 3})
	testing.expect_value(t, strings.to_string(b), `{"id":7,"ts_ms":1,"received_at":2,"level":"warn","code":"provider_missing","fields":{"provider":"claude"},"count":3,"message":"Provider CLI is not installed or has no runnable command (provider: claude)"}`)
}
