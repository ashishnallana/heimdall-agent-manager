package http

import "core:strings"
import "core:testing"
import "core:time"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

@(private = "file")
stats_frame :: proc(bridge_id, stats: string) -> string {
	return strings.concatenate({`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","stats":`, stats, `,"active_instance_ids":[]}`})
}

@(test)
test_heartbeat_stats_applied_and_mapped :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_stats_apply"
	frame := stats_frame(bid, `{"rss":104857600,"pty_host_rss":2048,"cpu_s":12.34,"host_mem_total":16000000000,"host_mem_avail":4000000000,"load1":0.57,"disk_free":123456789,"instances":[{"provider":"claude","rss":300,"cpu_s":1.5},{"provider":"/opt/bin/weird-agent","rss":10,"cpu_s":0.25},{"provider":"other","rss":5,"cpu_s":0.05}]}`)
	defer delete(frame)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, nil), Heartbeat_Stats_Result.Applied)
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "bridge")), i64(104857600))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "pty_host")), i64(2048))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_process_cpu, bid, "bridge")), u64(1234))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_memory, bid, "total")), i64(16000000000))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_memory, bid, "available")), i64(4000000000))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_load1, bid)), i64(57))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_disk_free, bid)), i64(123456789))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.instance_resident, bid, "claude")), i64(300))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.instance_cpu, bid, "claude")), u64(150))
	// Unknown providers collapse onto ONE "other" series (merged: 10 + 5).
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.instance_resident, bid, "other")), i64(15))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.instance_cpu, bid, "other")), u64(30))
	for s in m.instance_resident.series {
		testing.expect(t, !strings.contains(s.label_values[1], "weird"), "raw provider string never becomes a label")
	}
	// Exposition shows the scaled values.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	metrics.gather(metrics.global(), &b)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `heimdall_bridge_process_cpu_seconds_total{bridge_id="brg_stats_apply",process="bridge"} 12.34`), "cpu seconds scaled")
	testing.expect(t, strings.contains(out, `heimdall_bridge_host_load1{bridge_id="brg_stats_apply"} 0.57`), "load1 scaled")

	// A provider that vanishes is tombstoned on the next heartbeat.
	frame2 := stats_frame(bid, `{"rss":1,"pty_host_rss":1,"cpu_s":13,"instances":[{"provider":"codex","rss":7,"cpu_s":0}]}`)
	defer delete(frame2)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame2, nil), Heartbeat_Stats_Result.Applied)
	// Disconnect tombstones everything for the bridge.
	project_service.fleet_metrics_tombstone_bridge(bid)
	for fam in ([]^metrics.Family{m.bridge_process_resident, m.bridge_process_cpu, m.bridge_host_memory, m.bridge_host_load1, m.bridge_disk_free, m.instance_resident, m.instance_cpu}) {
		for s in fam.series do if s.label_values[0] == bid do testing.expectf(t, metrics.series_is_dead(s), "%s tombstoned on disconnect", fam.name)
	}
}

@(test)
test_heartbeat_stats_vanished_provider_is_tombstoned :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_stats_vanish"
	f1 := stats_frame(bid, `{"rss":1,"pty_host_rss":1,"cpu_s":1,"instances":[{"provider":"claude","rss":300,"cpu_s":1}]}`)
	defer delete(f1)
	f2 := stats_frame(bid, `{"rss":1,"pty_host_rss":1,"cpu_s":2,"instances":[{"provider":"codex","rss":7,"cpu_s":0}]}`)
	defer delete(f2)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, f1, nil), Heartbeat_Stats_Result.Applied)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, f2, nil), Heartbeat_Stats_Result.Applied)
	live_claude, live_codex := false, false
	for s in m.instance_resident.series {
		if s.label_values[0] != bid do continue
		if s.label_values[1] == "claude" do live_claude = !metrics.series_is_dead(s)
		if s.label_values[1] == "codex" do live_codex = !metrics.series_is_dead(s)
	}
	testing.expect(t, !live_claude, "claude series tombstoned once it stopped being reported")
	testing.expect(t, live_codex, "codex series live")
}

@(test)
test_heartbeat_stats_rejections :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_stats_reject"
	rejected :: proc(reason: string) -> u64 { return metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, reason)) }

	plain := `{"type":"bridge_heartbeat","active_instance_ids":[]}`
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, plain, nil), Heartbeat_Stats_Result.Absent)

	before := rejected("stats_out_of_range")
	neg := stats_frame(bid, `{"rss":-5,"cpu_s":1}`)
	defer delete(neg)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, neg, nil), Heartbeat_Stats_Result.Rejected_Out_Of_Range)
	huge := stats_frame(bid, `{"rss":99999999999999999999,"cpu_s":1}`)
	defer delete(huge)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, huge, nil), Heartbeat_Stats_Result.Rejected_Out_Of_Range)
	expo := stats_frame(bid, `{"rss":1e9,"cpu_s":1}`)
	defer delete(expo)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, expo, nil), Heartbeat_Stats_Result.Rejected_Out_Of_Range)
	nan := stats_frame(bid, `{"rss":NaN,"cpu_s":1}`)
	defer delete(nan)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, nan, nil), Heartbeat_Stats_Result.Rejected_Out_Of_Range)
	testing.expect_value(t, rejected("stats_out_of_range") - before, u64(4))
	// Nothing was applied for this bridge.
	for s in m.bridge_process_resident.series do testing.expect(t, s.label_values[0] != bid, "rejected stats set no gauge")

	// Too many instance entries.
	many := strings.builder_make()
	defer strings.builder_destroy(&many)
	strings.write_string(&many, `{"rss":1,"cpu_s":1,"instances":[`)
	for i in 0 ..< STATS_MAX_INSTANCES + 1 {
		if i > 0 do strings.write_byte(&many, ',')
		strings.write_string(&many, `{"provider":"claude","rss":1,"cpu_s":0}`)
	}
	strings.write_string(&many, `]}`)
	many_frame := stats_frame(bid, strings.to_string(many))
	defer delete(many_frame)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, many_frame, nil), Heartbeat_Stats_Result.Rejected_Out_Of_Range)

	// Oversize object.
	before_over := rejected("stats_oversize")
	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	strings.write_string(&big, `{"rss":1,"pad":"`)
	for _ in 0 ..< STATS_MAX_BYTES do strings.write_byte(&big, 'x')
	strings.write_string(&big, `"}`)
	big_frame := stats_frame(bid, strings.to_string(big))
	defer delete(big_frame)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, big_frame, nil), Heartbeat_Stats_Result.Rejected_Oversize)
	testing.expect_value(t, rejected("stats_oversize") - before_over, u64(1))

	// Malformed (unterminated) object.
	before_bad := rejected("stats_bad_json")
	bad := `{"type":"bridge_heartbeat","stats":{"rss":1,"instances":[{"provider":"claude"`
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, bad, nil), Heartbeat_Stats_Result.Rejected_Bad_Json)
	testing.expect_value(t, rejected("stats_bad_json") - before_bad, u64(1))
}

@(test)
test_heartbeat_stats_rate_cap_per_connection :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	bid := "brg_stats_rate"
	conn: project_service.Bridge_Runtime_Connection
	frame := stats_frame(bid, `{"rss":1,"cpu_s":1}`)
	defer delete(frame)
	before := metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "stats_rate_limited"))
	t0 := i64(1_000_000_000_000)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, &conn, t0), Heartbeat_Stats_Result.Applied)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, &conn, t0 + i64(time.Second)), Heartbeat_Stats_Result.Rejected_Rate_Limited)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, &conn, t0 + i64(4999 * time.Millisecond)), Heartbeat_Stats_Result.Rejected_Rate_Limited)
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, &conn, t0 + i64(5 * time.Second)), Heartbeat_Stats_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, "stats_rate_limited")) - before, u64(2))
	// A fresh connection (reconnect) starts with no slot.
	conn2: project_service.Bridge_Runtime_Connection
	testing.expect_value(t, bridge_apply_heartbeat_stats(bid, frame, &conn2, t0 + i64(5 * time.Second) + 1), Heartbeat_Stats_Result.Applied)
}

@(test)
test_heartbeat_stats_number_parsing :: proc(t: ^testing.T) {
	v, ok := stats_number(`{"a":12.345}`, "a", 2)
	testing.expect(t, ok, "ok")
	testing.expect_value(t, v, u64(1234)) // truncates, never rounds up
	v, ok = stats_number(`{"a":7}`, "a", 2)
	testing.expect_value(t, v, u64(700))
	v, ok = stats_number(`{"a": 42 ,"b":1}`, "a")
	testing.expect(t, ok && v == 42, "spaces around value")
	_, ok = stats_number(`{"b":1}`, "a")
	testing.expect(t, ok, "missing key is ok (0)")
	_, ok = stats_number(`{"a":"12"}`, "a")
	testing.expect(t, !ok, "string refused")
	_, ok = stats_number(`{"a":1.2.3}`, "a")
	testing.expect(t, !ok, "double dot refused")
	_, ok = stats_number(`{"a":9007199254740993}`, "a")
	testing.expect(t, !ok, "beyond 2^53 refused")
	testing.expect_value(t, project_service.provider_enum("codex"), "codex")
	testing.expect_value(t, project_service.provider_enum("CLAUDE"), "other")
	testing.expect_value(t, project_service.provider_enum(""), "other")
}

@(test)
test_bridge_ready_payload_carries_heartbeat_stats_flag :: proc(t: ^testing.T) {
	on := bridge_ready_payload("brg_x", 1, false, "etag")
	defer delete(on)
	off := bridge_ready_payload("brg_x", 1, false, "etag", false)
	defer delete(off)
	testing.expect(t, strings.contains(on, `"heartbeat_stats":true`), "default on")
	testing.expect(t, strings.contains(off, `"heartbeat_stats":false`), "off when telemetry disabled")
}
