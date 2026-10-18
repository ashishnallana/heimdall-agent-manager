package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// Heartbeat resource stats (hub telemetry plan 4.3). Piggybacked on the existing
// 45 s bridge_heartbeat as a `stats` object; the hub turns it into per-bridge
// gauges. Nothing here opens a listener and nothing runs on its own cadence:
// one `ps -A` fork per heartbeat (the same shape Telegraf's procstat does),
// plus /proc reads on Linux.
//
// Shape (all numbers are integers except cpu_s/load1; any field may be absent):
//   {"rss":N,"pty_host_rss":N,"cpu_s":F,"host_mem_total":N,"host_mem_avail":N,
//    "load1":F,"disk_free":N,"instances":[{"provider":"claude","rss":N,"cpu_s":F}]}
//
// Governed by the hub's telemetry_enabled switch: bridge_ready carries
// heartbeat_stats:false for a bridge whose owner opted out, and set_telemetry
// toggles it at runtime. Default is ON so old hubs (no field) still get stats.

@(private = "file")
heartbeat_stats_enabled: bool = true

bridge_heartbeat_stats_set_enabled :: proc(enabled: bool) {
	sync.atomic_store(&heartbeat_stats_enabled, enabled)
}

bridge_heartbeat_stats_enabled :: proc() -> bool {
	return sync.atomic_load(&heartbeat_stats_enabled)
}

// One row of `ps -A -o pid=,ppid=,rss=,cputime=,args=`.
Stats_Proc :: struct {
	pid:         i32,
	ppid:        i32,
	rss_bytes:   i64,
	cpu_seconds: f64,
	args:        string, // borrowed from the ps output buffer
}

Stats_Instance :: struct {
	provider:    string,
	rss_bytes:   i64,
	cpu_seconds: f64,
}

Heartbeat_Stats :: struct {
	ok:             bool,
	rss:            i64,
	pty_host_rss:   i64,
	cpu_seconds:    f64,
	host_mem_total: i64,
	host_mem_avail: i64,
	has_host_mem:   bool,
	load1:          f64,
	has_load1:      bool,
	disk_free:      i64,
	has_disk_free:  bool,
	instances:      [dynamic]Stats_Instance,
}

// bridge_heartbeat_stats_json returns the `stats` object, or "" when disabled or
// when nothing could be collected. The caller owns the string.
bridge_heartbeat_stats_json :: proc(allocator := context.allocator) -> string {
	if !bridge_heartbeat_stats_enabled() do return ""
	st := heartbeat_stats_collect(context.temp_allocator)
	if !st.ok do return ""
	return heartbeat_stats_format(st, allocator)
}

heartbeat_stats_format :: proc(st: Heartbeat_Stats, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"rss":`)
	strings.write_i64(&b, st.rss)
	strings.write_string(&b, `,"pty_host_rss":`)
	strings.write_i64(&b, st.pty_host_rss)
	strings.write_string(&b, `,"cpu_s":`)
	heartbeat_stats_write_f64(&b, st.cpu_seconds)
	if st.has_host_mem {
		strings.write_string(&b, `,"host_mem_total":`)
		strings.write_i64(&b, st.host_mem_total)
		strings.write_string(&b, `,"host_mem_avail":`)
		strings.write_i64(&b, st.host_mem_avail)
	}
	if st.has_load1 {
		strings.write_string(&b, `,"load1":`)
		heartbeat_stats_write_f64(&b, st.load1)
	}
	if st.has_disk_free {
		strings.write_string(&b, `,"disk_free":`)
		strings.write_i64(&b, st.disk_free)
	}
	strings.write_string(&b, `,"instances":[`)
	for inst, i in st.instances {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"provider":"`)
		bridge_runtime_write_json_string(&b, inst.provider)
		strings.write_string(&b, `","rss":`)
		strings.write_i64(&b, inst.rss_bytes)
		strings.write_string(&b, `,"cpu_s":`)
		heartbeat_stats_write_f64(&b, inst.cpu_seconds)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// Fixed two-decimal formatting; avoids locale/exponent surprises on the wire.
@(private = "file")
heartbeat_stats_write_f64 :: proc(b: ^strings.Builder, v: f64) {
	x := v
	if x < 0 do x = 0
	whole := i64(x)
	frac := i64((x - f64(whole)) * 100 + 0.5)
	if frac >= 100 { whole += 1; frac -= 100 }
	strings.write_i64(b, whole)
	strings.write_byte(b, '.')
	if frac < 10 do strings.write_byte(b, '0')
	strings.write_i64(b, frac)
}

// heartbeat_stats_collect gathers everything. All allocations go to `allocator`
// (the caller passes a temp arena).
heartbeat_stats_collect :: proc(allocator := context.allocator) -> (st: Heartbeat_Stats) {
	ps_out, ps_ok := heartbeat_stats_run_ps(allocator)
	if !ps_ok do return
	procs := heartbeat_stats_parse_ps(ps_out, allocator)
	self_pid := i32(os.get_pid())
	for p in procs {
		if p.pid == self_pid {
			st.rss = p.rss_bytes
			st.cpu_seconds = p.cpu_seconds
		}
		if strings.contains(p.args, "ham-pty-host") do st.pty_host_rss += p.rss_bytes
	}
	st.instances = make([dynamic]Stats_Instance, allocator)
	// Instance trees: root pid + program from the pty host, descendants from ps.
	if socket, sock_ok := bridge_pty_host_ensure_daemon(); sock_ok {
		if reply, ok := bridge_pty_host_list(socket); ok {
			defer pty_host_reply_delete(reply)
			for a in reply.agents {
				if !a.alive || a.pid <= 0 do continue
				rss, cpu := heartbeat_stats_sum_tree(procs[:], a.pid, allocator)
				provider := heartbeat_stats_provider_from_program(a.program)
				merged := false
				for &inst in st.instances {
					if inst.provider == provider { inst.rss_bytes += rss; inst.cpu_seconds += cpu; merged = true; break }
				}
				if !merged do append(&st.instances, Stats_Instance{provider = strings.clone(provider, allocator), rss_bytes = rss, cpu_seconds = cpu})
			}
		}
	}
	heartbeat_stats_collect_host(&st, allocator)
	st.ok = true
	return
}

// heartbeat_stats_provider_from_program reduces a program path to its lowercase
// basename ("/nix/store/.../bin/claude" -> "claude"). The hub maps it onto its
// provider enum; anything unknown becomes "other" there, never a new series.
heartbeat_stats_provider_from_program :: proc(program: string) -> string {
	p := program
	if i := strings.last_index_byte(p, '/'); i >= 0 do p = p[i+1:]
	if j := strings.index_byte(p, ' '); j >= 0 do p = p[:j]
	switch strings.to_lower(p, context.temp_allocator) {
	case "claude", "claude-code":               return "claude"
	case "codex":                               return "codex"
	case "copilot", "github-copilot", "gh":     return "copilot"
	case "antigravity", "agy":                  return "antigravity"
	case "gemini":                              return "gemini"
	case "":                                    return "other"
	}
	return "other"
}

// heartbeat_stats_sum_tree sums rss and cpu over `root` and its descendants.
heartbeat_stats_sum_tree :: proc(procs: []Stats_Proc, root: i32, allocator := context.allocator) -> (rss: i64, cpu: f64) {
	queue := make([dynamic]i32, allocator)
	append(&queue, root)
	seen := make(map[i32]bool, allocator)
	for len(queue) > 0 {
		pid := pop(&queue)
		if pid in seen do continue
		seen[pid] = true
		for p in procs {
			if p.pid == pid { rss += p.rss_bytes; cpu += p.cpu_seconds }
			if p.ppid == pid && !(p.pid in seen) do append(&queue, p.pid)
		}
	}
	return
}

@(private = "file")
heartbeat_stats_run_ps :: proc(allocator := context.allocator) -> (output: string, ok: bool) {
	cmd := [?]string{"ps", "-A", "-o", "pid=,ppid=,rss=,cputime=,args="}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = cmd[:], env = []string{"LC_ALL=C"}}, allocator)
	if len(stderr) > 0 do delete(stderr, allocator)
	if err != nil || !state.success {
		if len(stdout) > 0 do delete(stdout, allocator)
		return "", false
	}
	return string(stdout), true
}

// heartbeat_stats_parse_ps parses `pid ppid rss cputime args` rows. rss is in
// KiB on both Linux and macOS ps; cputime is [[dd-]hh:]mm:ss.
heartbeat_stats_parse_ps :: proc(output: string, allocator := context.allocator) -> [dynamic]Stats_Proc {
	out := make([dynamic]Stats_Proc, allocator)
	text := output
	for line in strings.split_lines_iterator(&text) {
		if p, ok := heartbeat_stats_parse_ps_line(line); ok do append(&out, p)
	}
	return out
}

heartbeat_stats_parse_ps_line :: proc(line: string) -> (p: Stats_Proc, ok: bool) {
	rest := strings.trim_space(line)
	fields: [4]string
	for i in 0 ..< 4 {
		rest = strings.trim_left_space(rest)
		end := strings.index_any(rest, " \t")
		if end < 0 do return {}, false
		fields[i] = rest[:end]
		rest = rest[end:]
	}
	pid, pid_ok := strconv.parse_int(fields[0])
	ppid, ppid_ok := strconv.parse_int(fields[1])
	rss, rss_ok := strconv.parse_int(fields[2])
	cpu, cpu_ok := heartbeat_stats_parse_cputime(fields[3])
	if !pid_ok || !ppid_ok || !rss_ok || !cpu_ok do return {}, false
	p.pid = i32(pid)
	p.ppid = i32(ppid)
	p.rss_bytes = i64(rss) * 1024
	p.cpu_seconds = cpu
	p.args = strings.trim_space(rest)
	return p, true
}

// heartbeat_stats_parse_cputime accepts "mm:ss", "hh:mm:ss", "dd-hh:mm:ss"
// (and fractional seconds on macOS, e.g. "0:01.23").
heartbeat_stats_parse_cputime :: proc(s: string) -> (seconds: f64, ok: bool) {
	rest := s
	days := 0
	if dash := strings.index_byte(rest, '-'); dash >= 0 {
		d, d_ok := strconv.parse_int(rest[:dash])
		if !d_ok do return 0, false
		days = int(d)
		rest = rest[dash+1:]
	}
	parts := [3]f64{}
	n := 0
	for n < 3 {
		colon := strings.index_byte(rest, ':')
		field := rest if colon < 0 else rest[:colon]
		v, v_ok := strconv.parse_f64(field)
		if !v_ok do return 0, false
		parts[n] = v
		n += 1
		if colon < 0 do break
		rest = rest[colon+1:]
	}
	if n < 2 do return 0, false
	switch n {
	case 2: seconds = parts[0] * 60 + parts[1]
	case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
	}
	seconds += f64(days) * 86400
	return seconds, true
}

// Host-level numbers. Linux reads /proc; every platform gets disk_free from
// statvfs on the scratch root (where sessions and caches live).
@(private = "file")
heartbeat_stats_collect_host :: proc(st: ^Heartbeat_Stats, allocator := context.allocator) {
	when ODIN_OS == .Linux {
		if data, err := os.read_entire_file("/proc/meminfo", allocator); err == nil {
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				if strings.has_prefix(line, "MemTotal:") {
					st.host_mem_total = heartbeat_stats_parse_kb(line[len("MemTotal:"):])
				} else if strings.has_prefix(line, "MemAvailable:") {
					st.host_mem_avail = heartbeat_stats_parse_kb(line[len("MemAvailable:"):])
					st.has_host_mem = true
				}
			}
		}
		if data, err := os.read_entire_file("/proc/loadavg", allocator); err == nil {
			text := string(data)
			for field in strings.fields_iterator(&text) {
				if v, ok := strconv.parse_f64(field); ok { st.load1 = v; st.has_load1 = true }
				break
			}
		}
	}
	root := bridge_scratch_root(allocator)
	if free, ok := bridge_os_disk_free(root); ok {
		st.disk_free = free
		st.has_disk_free = true
	}
}

@(private = "file")
heartbeat_stats_parse_kb :: proc(s: string) -> i64 {
	v, ok := strconv.parse_i64(strings.trim_space(strings.trim_suffix(strings.trim_space(s), "kB")))
	return v * 1024 if ok else 0
}

// heartbeat_stats_cpu_seconds_linux reads utime+stime for a pid from
// /proc/<pid>/stat (used by the unit test to cross-check the ps parser).
heartbeat_stats_cpu_seconds_linux :: proc(pid: i32, allocator := context.allocator) -> (f64, bool) {
	when ODIN_OS == .Linux {
		buf: [64]byte
		path := strings.concatenate({"/proc/", strconv.write_int(buf[:], i64(pid), 10), "/stat"}, allocator)
		data, err := os.read_entire_file(path, allocator)
		if err != nil do return 0, false
		text := string(data)
		close := strings.last_index_byte(text, ')')
		if close < 0 do return 0, false
		rest := text[close+1:]
		idx := 0
		ticks: f64
		for field in strings.fields_iterator(&rest) {
			if idx == 11 || idx == 12 {
				if v, ok := strconv.parse_f64(field); ok do ticks += v
			}
			idx += 1
		}
		return ticks / 100, idx > 12
	} else {
		return 0, false
	}
}

_ :: time
