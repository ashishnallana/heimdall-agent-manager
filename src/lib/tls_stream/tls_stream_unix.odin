#+build !windows
package tls_stream

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

// Stream on Unix: the relay subprocess owns the TCP socket and the TLS session;
// plaintext flows over its stdin/stdout pipes.
Stream :: struct {
	process:  os.Process,
	stdin_w:  ^os.File,
	stdout_r: ^os.File,
}

// dial starts the relay. The timeout is not used here: the relay connects in the
// background and the caller's read deadline bounds the whole exchange.
dial :: proc(host: string, port: u16, timeout: time.Duration = 0) -> (Stream, bool) {
	stdin_r, stdin_w, stdin_err := os.pipe()
	if stdin_err != nil { set_last_dial_error("pipe creation failed"); return {}, false }
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil {
		_ = os.close(stdin_r)
		_ = os.close(stdin_w)
		set_last_dial_error("pipe creation failed")
		return {}, false
	}
	cmd := relay_command(host, port)
	defer delete(cmd)
	process, start_err := os.process_start(os.Process_Desc{command = cmd, stdin = stdin_r, stdout = stdout_w})
	_ = os.close(stdin_r)
	_ = os.close(stdout_w)
	if start_err != nil {
		set_last_dial_error(fmt.tprintf("could not start the TLS relay %s: %v", cmd[0], start_err))
		_ = os.close(stdin_w)
		_ = os.close(stdout_r)
		return {}, false
	}
	return Stream{process = process, stdin_w = stdin_w, stdout_r = stdout_r}, true
}

has_data :: proc(s: ^Stream) -> (ready: bool, ok: bool) {
	if s.stdout_r == nil do return false, false
	ready_, err := os.pipe_has_data(s.stdout_r)
	if err != nil do return false, false
	return ready_, true
}

// read returns (0, true) at end of stream; os.read reports EOF as the .EOF error and
// may carry data with it, which is delivered first.
read :: proc(s: ^Stream, out: []byte) -> (n: int, ok: bool) {
	if s.stdout_r == nil do return 0, false
	got, err := os.read(s.stdout_r, out)
	if err == .EOF do return max(got, 0), true
	if err != nil do return 0, false
	return max(got, 0), true
}

// write_all with timeout 0 is a plain blocking write. With a timeout the pipe is
// switched to non-blocking so a stalled relay obeys the same deadline as TCP; a
// partial frame is then fatal to the stream.
write_all :: proc(s: ^Stream, bytes: []byte, timeout: time.Duration = 0) -> Write_Result {
	if s.stdin_w == nil do return .Failed
	if timeout <= 0 {
		_, err := os.write(s.stdin_w, bytes)
		return .Ok if err == nil else .Failed
	}
	fd := posix.FD(os.fd(s.stdin_w))
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 || posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) < 0 do return .Failed
	sent := 0
	started := time.tick_now()
	for sent < len(bytes) {
		if time.tick_since(started) >= timeout do return .Timed_Out
		n := posix.write(fd, raw_data(bytes[sent:]), uint(int(len(bytes))-sent))
		if n < 0 {
			err := posix.errno()
			if err == .EAGAIN || err == .EINTR { time.sleep(time.Millisecond); continue }
			return .Failed
		}
		if n == 0 do return .Failed
		sent += int(n)
	}
	return .Ok
}

// close_write closes the relay's stdin (part of close).
@(private)
close_write :: proc(s: ^Stream) {
	if s.stdin_w != nil {
		_ = os.close(s.stdin_w)
		s.stdin_w = nil
	}
}

// abort kills the relay so a reader parked on stdout_r wakes with EOF; the reader
// still owns close().
abort :: proc(s: ^Stream) {
	_ = os.process_kill(s.process)
}

close :: proc(s: ^Stream) {
	close_write(s)
	if s.stdout_r != nil {
		_ = os.close(s.stdout_r)
		s.stdout_r = nil
	}
	_ = os.process_terminate(s.process)
	_, _ = os.process_wait(s.process, 250 * time.Millisecond)
}
