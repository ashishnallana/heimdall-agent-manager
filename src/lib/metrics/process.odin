package metrics

import "core:os"
import "core:strconv"
import "core:strings"

// register_process_collector emits the standard Prometheus process_* metrics
// for this process. Linux reads /proc/self; other platforms emit nothing.
register_process_collector :: proc(reg: ^Registry) {
	when ODIN_OS == .Linux {
		registry_add_collector(reg, rawptr(reg), process_collect_linux)
	}
}

Process_Stats :: struct {
	ok:                 bool,
	resident_bytes:     u64,
	virtual_bytes:      u64,
	cpu_ticks:          u64, // utime + stime in USER_HZ (100/s on Linux)
	threads:            u64,
	open_fds:           u64,
	max_fds:            u64,
	start_time_seconds: u64, // unix epoch
}

// CLK_TCK is 100 on every Linux ABI Odin targets; sysconf(_SC_CLK_TCK) would
// only differ on exotic kernels and is not worth a libc call per scrape.
@(private)
LINUX_CLK_TCK :: 100

when ODIN_OS == .Linux {

@(private)
process_collect_linux :: proc(ctx: rawptr, e: ^Exposition) {
	reg := (^Registry)(ctx)
	st := read_process_stats_linux(reg)
	if !st.ok do return
	process_emit(e, st)
}

// read_process_stats_linux gathers from /proc/self/{stat,status,fd,limits} and
// /proc/stat (btime). Every allocation uses the registry allocator and is freed
// before return.
read_process_stats_linux :: proc(reg: ^Registry) -> (st: Process_Stats) {
	a := reg.allocator
	if data, err := os.read_entire_file("/proc/self/stat", a); err == nil {
		defer delete(data, a)
		if !parse_self_stat(string(data), &st) do return
	} else {
		return
	}
	// /proc/self/status: VmRSS in kB (threads also here, stat already has it).
	if data, err := os.read_entire_file("/proc/self/status", a); err == nil {
		defer delete(data, a)
		if rss, found := parse_vmrss_bytes(string(data)); found do st.resident_bytes = rss
	}
	// /proc/stat btime: boot time (epoch seconds).
	if data, err := os.read_entire_file("/proc/stat", a); err == nil {
		defer delete(data, a)
		st.start_time_seconds += parse_btime(string(data))
	}
	// /proc/self/limits: "Max open files            1024                 4096                 files"
	if data, err := os.read_entire_file("/proc/self/limits", a); err == nil {
		defer delete(data, a)
		if soft, found := parse_max_open_files(string(data)); found do st.max_fds = soft
	}
	// /proc/self/fd: one entry per open descriptor (plus the one we hold open).
	if dir, err := os.open("/proc/self/fd"); err == nil {
		defer os.close(dir)
		it := os.read_directory_iterator_create(dir)
		defer os.read_directory_iterator_destroy(&it)
		n: u64
		for _ in os.read_directory_iterator(&it) do n += 1
		if n > 0 do n -= 1 // the directory handle itself
		st.open_fds = n
	}
	st.ok = true
	return
}

} // when Linux

// process_emit writes the process_* families for one stats snapshot. Split from
// process_collect_linux so tests can check exposition without reading /proc.
@(private)
process_emit :: proc(e: ^Exposition, st: Process_Stats) {
	expo_header(e, "process_resident_memory_bytes", "Resident memory size in bytes.", .Gauge)
	expo_sample_u64(e, "process_resident_memory_bytes", nil, nil, st.resident_bytes)
	expo_header(e, "process_virtual_memory_bytes", "Virtual memory size in bytes.", .Gauge)
	expo_sample_u64(e, "process_virtual_memory_bytes", nil, nil, st.virtual_bytes)
	expo_header(e, "process_cpu_seconds_total", "Total user and system CPU time spent in seconds.", .Counter)
	// ticks are 1/100 s, so the tick count IS centiseconds: decimals=2.
	expo_sample_u64(e, "process_cpu_seconds_total", nil, nil, st.cpu_ticks, 2)
	expo_header(e, "process_open_fds", "Number of open file descriptors.", .Gauge)
	expo_sample_u64(e, "process_open_fds", nil, nil, st.open_fds)
	expo_header(e, "process_max_fds", "Maximum number of open file descriptors.", .Gauge)
	expo_sample_u64(e, "process_max_fds", nil, nil, st.max_fds)
	expo_header(e, "process_threads", "Number of OS threads in the process.", .Gauge)
	expo_sample_u64(e, "process_threads", nil, nil, st.threads)
	expo_header(e, "process_start_time_seconds", "Start time of the process since unix epoch in seconds.", .Gauge)
	expo_sample_u64(e, "process_start_time_seconds", nil, nil, st.start_time_seconds)
}

// The parsers below are pure (no I/O) so tests can feed fixture text.

// parse_self_stat fills cpu_ticks, threads, start_time_seconds (ticks since
// boot / CLK_TCK; btime is added later) and virtual_bytes from /proc/self/stat.
// /proc/self/stat: "pid (comm) state ppid ... utime(14) stime(15) ... num_threads(20) ... starttime(22) vsize(23) rss(24)"
// comm may itself contain ')' or spaces, hence the LAST ')'.
// Returns false when the line is malformed or truncated.
@(private)
parse_self_stat :: proc(text: string, st: ^Process_Stats) -> bool {
	close := strings.last_index_byte(text, ')')
	if close < 0 do return false
	rest := strings.trim_space(text[close+1:])
	// rest[0] is field 3 (state); field N is rest index N-3.
	idx := 0
	for field in strings.fields_iterator(&rest) {
		switch idx {
		case 11: st.cpu_ticks += parse_u64(field)  // utime
		case 12: st.cpu_ticks += parse_u64(field)  // stime
		case 17: st.threads = parse_u64(field)
		case 19: st.start_time_seconds = parse_u64(field) / LINUX_CLK_TCK // ticks since boot
		case 20: st.virtual_bytes = parse_u64(field)
		}
		idx += 1
	}
	return idx >= 21
}

// parse_vmrss_bytes reads "VmRSS:  <n> kB" from /proc/self/status.
// When several VmRSS lines exist the last one wins (matches the old loop).
@(private)
parse_vmrss_bytes :: proc(text: string) -> (bytes: u64, found: bool) {
	text := text
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "VmRSS:") {
			bytes = parse_u64(strings.trim_space(strings.trim_suffix(strings.trim_space(line[len("VmRSS:"):]), "kB"))) * 1024
			found = true
		}
	}
	return
}

// parse_btime returns the boot time (epoch seconds) from /proc/stat, or 0.
@(private)
parse_btime :: proc(text: string) -> u64 {
	text := text
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "btime ") {
			return parse_u64(strings.trim_space(line[len("btime "):]))
		}
	}
	return 0
}

// parse_max_open_files returns the soft limit from /proc/self/limits:
// "Max open files            1024                 4096                 files"
@(private)
parse_max_open_files :: proc(text: string) -> (soft: u64, found: bool) {
	text := text
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "Max open files") {
			rest := strings.trim_space(line[len("Max open files"):])
			for field in strings.fields_iterator(&rest) {
				return parse_u64(field), true
			}
			return 0, true
		}
	}
	return 0, false
}

@(private)
parse_u64 :: proc(s: string) -> u64 {
	v, ok := strconv.parse_u64(s)
	return v if ok else 0
}
