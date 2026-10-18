package os_random

import "core:os"
import win "core:sys/windows"

// fill uses the system-preferred RNG (BCryptGenRandom), the Windows counterpart
// of /dev/urandom. A non-default source is read as a file, so a test that points
// it at an unreadable path still exercises the fail-closed branch.
fill :: proc(dst: []byte, source := DEFAULT_SOURCE) -> bool {
	if len(dst) == 0 do return true
	if source != DEFAULT_SOURCE {
		data, err := os.read_entire_file(source, context.temp_allocator)
		if err != nil || len(data) < len(dst) do return false
		copy(dst, data)
		return true
	}
	for off := 0; off < len(dst); {
		n := min(len(dst) - off, int(max(u32)))
		if win.BCryptGenRandom(nil, raw_data(dst[off:]), u32(n), win.BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0 do return false
		off += n
	}
	return true
}
