package sqlite

import win "core:sys/windows"

// sqlite_file_size reads a file's size with a stack path buffer and no allocation
// (this runs on the metrics thread, which never resets a temp arena).
sqlite_file_size :: proc(path: string) -> (i64, bool) {
	wbuf: [4096 + 1]u16
	if len(path) >= len(wbuf) do return 0, false
	wpath := win.utf8_to_wstring_buf(wbuf[:], path)
	if wpath == nil do return 0, false
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(wpath, win.GetFileExInfoStandard, &data) do return 0, false
	return i64(u64(data.nFileSizeHigh) << 32 | u64(data.nFileSizeLow)), true
}
