#+build !windows
package ws

import "core:net"
import "core:sys/posix"

// socket_send_once issues ONE OS send. retry reports a transient condition
// (EAGAIN/EINTR) the caller should wait out; n <= 0 without retry is fatal.
socket_send_once :: proc(socket: net.TCP_Socket, bytes: []byte) -> (n: int, retry: bool) {
	r := posix.send(posix.FD(socket), raw_data(bytes), uint(len(bytes)), {.NOSIGNAL})
	if r < 0 {
		err := posix.errno()
		return 0, err == .EAGAIN || err == .EINTR
	}
	return int(r), false
}
