package main

import "core:strings"
import "core:sys/posix"
import "core:testing"

// Heartbeat stats (plan 4.3, bridge side).

@(test)
test_heartbeat_stats_parse_cputime :: proc(t: ^testing.T) {
	v, ok := heartbeat_stats_parse_cputime("00:05")
	testing.expect(t, ok && v == 5, "mm:ss")
	v, ok = heartbeat_stats_parse_cputime("01:02:03")
	testing.expect(t, ok && v == 3723, "hh:mm:ss")
	v, ok = heartbeat_stats_parse_cputime("2-01:00:00")
	testing.expect(t, ok && v == 2 * 86400 + 3600, "dd-hh:mm:ss")
	v, ok = heartbeat_stats_parse_cputime("0:01.25")
	testing.expect(t, ok && v > 1.24 && v < 1.26, "macOS fractional seconds")
	_, ok = heartbeat_stats_parse_cputime("garbage")
	testing.expect(t, !ok, "garbage refused")
	_, ok = heartbeat_stats_parse_cputime("5")
	testing.expect(t, !ok, "a bare number is not a cputime")
}

@(test)
test_heartbeat_stats_parse_ps_line :: proc(t: ^testing.T) {
	p, ok := heartbeat_stats_parse_ps_line("  1234  1000 51200 00:01:30 /nix/store/abc/bin/claude --dangerously-skip-permissions")
	testing.expect(t, ok, "parsed")
	testing.expect_value(t, p.pid, i32(1234))
	testing.expect_value(t, p.ppid, i32(1000))
	testing.expect_value(t, p.rss_bytes, i64(51200 * 1024))
	testing.expect_value(t, p.cpu_seconds, f64(90))
	testing.expect_value(t, p.args, "/nix/store/abc/bin/claude --dangerously-skip-permissions")
	_, ok = heartbeat_stats_parse_ps_line("not a ps line")
	testing.expect(t, !ok, "junk refused")
	_, ok = heartbeat_stats_parse_ps_line("")
	testing.expect(t, !ok, "empty refused")
}

@(test)
test_heartbeat_stats_sum_tree_and_provider :: proc(t: ^testing.T) {
	procs := []Stats_Proc{
		{pid = 10, ppid = 1, rss_bytes = 100, cpu_seconds = 1},
		{pid = 11, ppid = 10, rss_bytes = 20, cpu_seconds = 0.5},
		{pid = 12, ppid = 11, rss_bytes = 3, cpu_seconds = 0.25},
		{pid = 99, ppid = 1, rss_bytes = 1000, cpu_seconds = 9}, // unrelated
	}
	rss, cpu := heartbeat_stats_sum_tree(procs, 10)
	testing.expect_value(t, rss, i64(123))
	testing.expect_value(t, cpu, f64(1.75))
	testing.expect_value(t, heartbeat_stats_provider_from_program("/nix/store/x/bin/claude"), "claude")
	testing.expect_value(t, heartbeat_stats_provider_from_program("codex --full-auto"), "codex")
	testing.expect_value(t, heartbeat_stats_provider_from_program("/usr/local/bin/some-shell"), "other")
	testing.expect_value(t, heartbeat_stats_provider_from_program(""), "other")
}

@(test)
test_heartbeat_stats_format_shape :: proc(t: ^testing.T) {
	st := Heartbeat_Stats{ok = true, rss = 1024, pty_host_rss = 512, cpu_seconds = 12.345, host_mem_total = 16, host_mem_avail = 4, has_host_mem = true, load1 = 0.5, has_load1 = true, disk_free = 99, has_disk_free = true}
	st.instances = make([dynamic]Stats_Instance)
	defer delete(st.instances)
	append(&st.instances, Stats_Instance{provider = "claude", rss_bytes = 300, cpu_seconds = 1.5})
	out := heartbeat_stats_format(st)
	defer delete(out)
	testing.expect_value(t, out, `{"rss":1024,"pty_host_rss":512,"cpu_s":12.35,"host_mem_total":16,"host_mem_avail":4,"load1":0.50,"disk_free":99,"instances":[{"provider":"claude","rss":300,"cpu_s":1.50}]}`)
	// Optional host fields are omitted when unknown (macOS path).
	st2 := Heartbeat_Stats{ok = true, rss = 1, cpu_seconds = 0}
	out2 := heartbeat_stats_format(st2)
	defer delete(out2)
	testing.expect_value(t, out2, `{"rss":1,"pty_host_rss":0,"cpu_s":0.00,"instances":[]}`)
}

// Live collection on this host: the bridge's own row must be found and the
// cpu value must agree with /proc/self/stat (Linux) within ps's 1 s rounding.
@(test)
test_heartbeat_stats_collect_live :: proc(t: ^testing.T) {
	st := heartbeat_stats_collect(context.temp_allocator)
	if !st.ok {
		testing.expect(t, true, "ps unavailable on this host; skipping")
		return
	}
	testing.expect(t, st.rss > 1024 * 1024, "own rss > 1 MiB")
	testing.expect(t, st.has_disk_free && st.disk_free > 0, "disk_free from statvfs")
	when ODIN_OS == .Linux {
		testing.expect(t, st.has_host_mem && st.host_mem_total >= st.host_mem_avail && st.host_mem_total > 0, "meminfo")
		testing.expect(t, st.has_load1, "loadavg")
		proc_cpu, proc_ok := heartbeat_stats_cpu_seconds_linux(i32(posix.getpid()), context.temp_allocator)
		testing.expect(t, proc_ok, "/proc/self/stat readable")
		diff := proc_cpu - st.cpu_seconds
		if diff < 0 do diff = -diff
		testing.expectf(t, diff <= 1.5, "ps cputime (%v) agrees with /proc (%v)", st.cpu_seconds, proc_cpu)
	}
	json := heartbeat_stats_format(st, context.temp_allocator)
	testing.expect(t, strings.has_prefix(json, `{"rss":`) && strings.has_suffix(json, "]}"), "well-formed object")
}

@(test)
test_heartbeat_stats_toggle_omits_object :: proc(t: ^testing.T) {
	defer bridge_heartbeat_stats_set_enabled(true)
	bridge_heartbeat_stats_set_enabled(false)
	testing.expect_value(t, bridge_heartbeat_stats_json(), "")
	hb := bridge_hub_heartbeat_json()
	defer delete(hb)
	testing.expect(t, !strings.contains(hb, `"stats":`), "heartbeat has no stats when disabled")
	bridge_heartbeat_stats_set_enabled(true)
	hb2 := bridge_hub_heartbeat_json()
	defer delete(hb2)
	// Either the stats object is present or ps was unavailable; both keep the frame valid.
	testing.expect(t, strings.has_prefix(hb2, `{"type":"bridge_heartbeat"`), "heartbeat frame intact")
}
