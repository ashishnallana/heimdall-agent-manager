package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// core:thread allocates the Thread record with the CREATING context's allocator
// and the new thread's entry writes into it. Hub request threads, the bridge WS
// reader (per frame) and the reaper (per pass) run on arenas that are destroyed
// when the request/frame/pass ends — a thread spawned there writes into unmapped
// memory and the hub dies with SIGSEGV in __unix_thread_entry_proc (v0.4.21 prod
// crash loop, bridge_proxy_relay). So every spawn in the hub must either install
// the heap allocator first or be marked as a startup spawn.
@(private = "file")
SPAWN_CALLS :: []string{"thread.create(", "thread.create_and_start", "thread.run_with", "thread.run("}

@(private = "file")
SPAWN_LOOKBACK :: 30

@(test)
test_every_thread_spawn_uses_the_heap_allocator :: proc(t: ^testing.T) {
	hub_root := filepath.dir(strings.trim_right(#directory, "/"))
	offenders: [dynamic]string
	defer delete(offenders)
	scan_spawn_sites(hub_root, &offenders)
	testing.expectf(t, len(offenders) > 0 || scanned_any(hub_root), "scanned nothing under %s", hub_root)
	for o in offenders {
		testing.expectf(t, false, "%s spawns a thread without `context.allocator = runtime.heap_allocator()` (or `= heap`) in the same proc just before it. The Thread record would live in the caller's arena and be freed under the running thread. Install the heap allocator before the spawn, or mark a process-startup spawn with `// thread-spawn: startup`.", o)
	}
}

@(private = "file")
scan_spawn_sites :: proc(dir: string, offenders: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if e.type == .Directory {
			scan_spawn_sites(e.fullpath, offenders)
			continue
		}
		if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") do continue
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil do continue
		lines := strings.split_lines(string(data), context.temp_allocator)
		for line, i in lines {
			code := strings.trim_space(line)
			if strings.has_prefix(code, "//") do continue
			is_spawn := false
			for call in SPAWN_CALLS do if strings.contains(code, call) do is_spawn = true
			if !is_spawn || spawn_is_guarded(lines, i) do continue
			append(offenders, fmt.tprintf("%s:%d", e.fullpath, i + 1))
		}
	}
}

// spawn_is_guarded looks back through the enclosing proc (stopping at its
// header) for a heap-allocator install or a startup marker.
@(private = "file")
spawn_is_guarded :: proc(lines: []string, spawn: int) -> bool {
	for i := spawn - 1; i >= 0 && i >= spawn - SPAWN_LOOKBACK; i -= 1 {
		l := lines[i]
		if strings.contains(l, "// thread-spawn: startup") do return true
		if strings.contains(l, "context.allocator = runtime.heap_allocator()") || strings.contains(l, "context.allocator = heap") do return true
		if strings.contains(l, ":: proc") do return false
	}
	return false
}

@(private = "file")
scanned_any :: proc(hub_root: string) -> bool {
	_, err := os.stat(strings.concatenate({hub_root, "/transport/http/server.odin"}, context.temp_allocator), context.temp_allocator)
	return err == nil
}
