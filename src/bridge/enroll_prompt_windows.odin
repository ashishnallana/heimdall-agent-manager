#+build windows
package main

// bridge_stdin_wait_readable: console input has no portable poll here; the prompt
// reads directly (it is only reached on an interactive console).
bridge_stdin_wait_readable :: proc(timeout_ms: int) -> bool {
	return true
}
