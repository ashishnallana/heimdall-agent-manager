#+build !windows
package main

import "core:sys/posix"

// bridge_stdin_wait_readable waits up to timeout_ms for an answer on stdin, so a
// terminal nobody answers (a test runner or a managed shell on a pty) gives up
// instead of blocking the enrollment forever.
bridge_stdin_wait_readable :: proc(timeout_ms: int) -> bool {
	pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
	return posix.poll(&pfd, 1, i32(timeout_ms)) > 0
}
