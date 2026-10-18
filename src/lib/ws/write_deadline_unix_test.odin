#+build !windows
package ws

import "core:os"
import "core:testing"
import "core:time"
import tls "../tls_stream"

// The Unix TLS transport is a relay subprocess behind a pipe; these drive its
// writer directly through a bare pipe.

@(test)
tls_pipe_write_obeys_total_deadline :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	stream := tls.Stream{stdin_w = w}
	data := make([]byte, 1024 * 1024)
	defer delete(data)
	before := send_timeouts()
	started := time.tick_now()
	ok := send_all_tls(&stream, data)
	elapsed := time.tick_since(started)
	testing.expect(t, !ok, "a full undrained pipe must fail")
	testing.expect(t, elapsed >= WRITE_DEADLINE && elapsed < WRITE_DEADLINE + time.Second)
	testing.expect(t, send_timeouts() > before, "TLS timeout must be observable")
}

@(test)
tls_pipe_small_write_is_exact :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	stream := tls.Stream{stdin_w = w}
	payload := "payload"
	testing.expect(t, send_all_tls(&stream, transmute([]byte)payload))
	data: [7]byte
	n, read_err := os.read(r, data[:])
	testing.expect(t, read_err == nil)
	testing.expect_value(t, n, 7)
	testing.expect_value(t, string(data[:]), "payload")
}
