#+build windows
package main

import "base:runtime"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

@(private = "file")
g_instance_lock_mu: sync.Mutex
@(private = "file")
g_instance_locks: map[string]win.HANDLE

// bridge_instance_lock takes an exclusive, non-blocking lock on `path` for the life
// of the process (or until bridge_instance_unlock): a second bridge instance using
// the same config or the same (hub, bridge id) scope refuses to start instead of
// sharing its state. Windows releases the lock when the process exits.
bridge_instance_lock :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	h := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator),
		win.GENERIC_READ | win.GENERIC_WRITE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		nil, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil,
	)
	if h == win.INVALID_HANDLE_VALUE do return false
	overlapped: win.OVERLAPPED
	if !win.LockFileEx(h, win.LOCKFILE_EXCLUSIVE_LOCK | win.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped) {
		win.CloseHandle(h)
		return false
	}
	sync.mutex_lock(&g_instance_lock_mu)
	defer sync.mutex_unlock(&g_instance_lock_mu)
	// Process-lifetime state: never on the caller's allocator (a test runner frees
	// each test's allocator, leaving the map pointing at freed memory).
	context.allocator = runtime.heap_allocator()
	g_instance_locks[strings.clone(path)] = h
	return true
}

// bridge_instance_unlock releases a lock this process took (no-op otherwise).
bridge_instance_unlock :: proc(path: string) {
	sync.mutex_lock(&g_instance_lock_mu)
	defer sync.mutex_unlock(&g_instance_lock_mu)
	context.allocator = runtime.heap_allocator()
	if path not_in g_instance_locks do return
	key, h := delete_key(&g_instance_locks, path)
	win.CloseHandle(h)
	delete(key)
}

// bridge_os_real_path resolves an EXISTING file or directory to its final path
// (GetFinalPathNameByHandleW: symlinks, junctions, 8.3 names and "..", resolved),
// lowercased because Windows paths are case-insensitive. Temp-allocated.
bridge_os_real_path :: proc(path: string) -> (string, bool) {
	h := win.CreateFileW(
		win.utf8_to_wstring(path, context.temp_allocator), 0,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil,
	)
	if h == win.INVALID_HANDLE_VALUE do return "", false
	defer win.CloseHandle(h)
	buf: [1024]u16
	n := win.GetFinalPathNameByHandleW(h, cstring16(raw_data(buf[:])), u32(len(buf)), 0)
	if n == 0 || int(n) >= len(buf) do return "", false
	s, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil do return "", false
	s = strings.trim_prefix(s, `\\?\`)
	s, _ = strings.replace_all(s, `\`, "/", context.temp_allocator)
	return strings.to_lower(s, context.temp_allocator), true
}
