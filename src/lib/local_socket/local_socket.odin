// Package local_socket is the AF_UNIX stream socket used for same-machine IPC:
// ham-ctl -> bridge (the `unix:` agent endpoint) and bridge <-> ham-pty-host.
//
// The same path-based sockets exist on every supported OS: POSIX everywhere, and
// natively in Winsock since Windows 10 1803, so a stock Windows install needs
// nothing extra and both sides keep one wire format. Per-OS files hold only the
// syscalls; the API is identical:
//
//   dial(path)                 -> (Socket, ok)
//   listen(path, backlog)      -> (Socket, ok)   replaces a stale file; owner-only
//   accept(listener)           -> (Socket, ok)
//   pair()                     -> (a, b, ok)     a connected pair (tests, in-process)
//   send(s, bytes)             -> bytes sent, or -1 on error (one OS call)
//   recv(s, buf)               -> bytes read, 0 at end of stream, -1 on error
//   recv_ex(s, buf)            -> (n, Error)     tells a timeout from a close
//   poll_readable(s, ms)       -> (ready, ok)    ok=false only on a real error
//   set_recv_timeout(s, d)
//   shutdown(s, how)           wake a blocked reader without freeing the handle
//   peer_pid(s)                -> (pid, ok)      the connected peer process
//   close(s)
//   valid(s), max_path_len()
//
// The stream calls take any connected stream socket, so the bridge also uses them
// on accepted TCP sockets (cast the handle to Socket).
package local_socket

Error :: enum {
	None,
	Would_Block, // no data before the receive timeout; the socket is still usable
	Interrupted, // a signal interrupted the call; retry
	Failed,
}

Shutdown_How :: enum {
	Read,
	Write,
	Both,
}

// path_fits reports whether path can be bound or dialed as-is.
path_fits :: proc(path: string) -> bool {
	return len(path) > 0 && len(path) <= max_path_len()
}

valid :: proc(s: Socket) -> bool {
	return s != INVALID_SOCKET
}
