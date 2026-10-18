// Package local_socket is the AF_UNIX stream socket used for same-machine IPC:
// ham-ctl -> bridge (the `unix:` agent endpoint) and bridge <-> ham-pty-host.
//
// The same path-based sockets exist on every supported OS: POSIX everywhere, and
// natively in Winsock since Windows 10 1803, so a stock Windows install needs
// nothing extra and both sides keep one wire format. Per-OS files hold only the
// syscalls; the API is identical:
//
//   dial(path)          -> (Socket, ok)
//   send(s, bytes)      -> bytes sent, or -1 on error (one OS call)
//   recv(s, buf)        -> bytes read, 0 at end of stream, -1 on error
//   close(s)
//   max_path_len()      -> longest path that fits sockaddr_un (excluding the NUL)
package local_socket

// path_fits reports whether path can be bound or dialed as-is.
path_fits :: proc(path: string) -> bool {
	return len(path) > 0 && len(path) <= max_path_len()
}
