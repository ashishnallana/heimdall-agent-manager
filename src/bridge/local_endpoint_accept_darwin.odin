#+build darwin
package main

import "core:sys/posix"

// macOS has no seccomp allowlist concern; the libc accept is the right call.
bridge_accept_unix :: proc(listener: posix.FD) -> posix.FD {
	return posix.accept(listener, nil, nil)
}
