#+build !windows
package sqlite

import "core:sys/posix"

// sqlite_file_size stats a path with a stack cstring and no allocation (this
// runs on the metrics thread, which never resets a temp arena).
sqlite_file_size :: proc(path: string) -> (i64, bool) {
	cbuf: [4096 + 1]u8
	if len(path) >= len(cbuf) do return 0, false
	copy(cbuf[:], path)
	cbuf[len(path)] = 0
	st: posix.stat_t
	if posix.stat(cstring(raw_data(cbuf[:])), &st) != .OK do return 0, false
	return i64(st.st_size), true
}
