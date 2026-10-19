#+build windows
package main

import "core:strings"
import win "core:sys/windows"

// bridge_instance_lock takes an exclusive, non-blocking lock on `path` for the life
// of the process: a second bridge instance using the same config or the same (hub,
// bridge id) scope refuses to start instead of sharing its state. The handle is
// intentionally never closed (Windows releases the lock when the process exits).
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
	return true
}
