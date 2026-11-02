package main

import "core:strings"
import win "core:sys/windows"

// GetFullPathName only cleans spelling. Follow the actual file handle so an
// ancestor junction cannot turn a sandboxed history/project path into an escape.
session_project_windows_realpath :: proc(path: string) -> (string, bool) {
	native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	if !strings.has_prefix(native, `\\?\`) {
		native = strings.concatenate({`\\?\UNC\`, native[2:]}, context.temp_allocator) if strings.has_prefix(native, `\\`) else strings.concatenate({`\\?\`, native}, context.temp_allocator)
	}
	wide := win.utf8_to_wstring(native, context.temp_allocator)
	handle := win.CreateFileW(wide, win.FILE_READ_ATTRIBUTES, win.FILE_SHARE_READ|win.FILE_SHARE_WRITE|win.FILE_SHARE_DELETE, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if handle == win.INVALID_HANDLE_VALUE do return "", false
	defer win.CloseHandle(handle)
	needed := win.GetFinalPathNameByHandleW(handle, nil, 0, 0)
	if needed == 0 do return "", false
	buffer := make([]u16, int(needed), context.temp_allocator)
	written := win.GetFinalPathNameByHandleW(handle, cstring16(raw_data(buffer)), needed, 0)
	if written == 0 || written >= needed do return "", false
	resolved := win.utf16_to_utf8(buffer[:written], context.temp_allocator) or_else ""
	if resolved == "" do return "", false
	if strings.has_prefix(resolved, `\\?\UNC\`) {
		resolved = strings.concatenate({`\\`, resolved[len(`\\?\UNC\`):]}, context.temp_allocator)
	} else if strings.has_prefix(resolved, `\\?\`) {
		resolved = resolved[len(`\\?\`):]
	}
	return resolved, true
}
