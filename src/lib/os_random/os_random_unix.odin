#+build !windows
package os_random

import "core:os"

// fill reads exactly len(dst) bytes from source. A short read is a failure, not
// a partial success.
fill :: proc(dst: []byte, source := DEFAULT_SOURCE) -> bool {
	if len(dst) == 0 do return true
	f, err := os.open(source)
	if err != nil do return false
	defer os.close(f)
	got := 0
	for got < len(dst) {
		n, read_err := os.read(f, dst[got:])
		if read_err != nil || n <= 0 do return false
		got += n
	}
	return true
}
