package ws

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
tls_pipe_write_obeys_total_deadline :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	data := make([]byte, 1024 * 1024)
	defer delete(data)
	before := send_timeouts()
	started := time.tick_now()
	ok := send_all_file(w, data)
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
	payload := "payload"
	testing.expect(t, send_all_file(w, transmute([]byte)payload))
	data: [7]byte
	n, read_err := os.read(r, data[:])
	testing.expect(t, read_err == nil)
	testing.expect_value(t, n, 7)
	testing.expect_value(t, string(data[:]), "payload")
}

@(test)
chunk_reassembly_reserves_a_total_byte_budget :: proc(t: ^testing.T) {
	states := make([dynamic]Chunk_Reassembly)
	defer chunk_reassemblies_free(&states)
	first := chunk_json("a", 0, 2, 8, "YWJjZA==")
	defer delete(first)
	second := chunk_json("b", 0, 2, 8, "YWJjZA==")
	defer delete(second)
	_, _, ok := reassemble_chunk(&states, first, max_buffered_bytes = 12)
	testing.expect(t, ok)
	_, _, overflow_ok := reassemble_chunk(&states, second, max_buffered_bytes = 12)
	testing.expect(t, !overflow_ok)
	testing.expect_value(t, len(states), 1)
	testing.expect_value(t, states[0].received_bytes, 4)
}

// The TLS WebSocket handshake budget matches the HTTP client's 20 s rather
// than the old hard-coded 5 s, and HAM_WS_HANDSHAKE_TIMEOUT_MS overrides it.
@(test)
handshake_deadline_default_and_override :: proc(t: ^testing.T) {
	testing.expect_value(t, handshake_deadline_from(""), 20 * time.Second)
	testing.expect_value(t, handshake_deadline_from("1500"), 1500 * time.Millisecond)
	testing.expect_value(t, handshake_deadline_from("0"), 20 * time.Second)
	testing.expect_value(t, handshake_deadline_from("-5"), 20 * time.Second)
	testing.expect_value(t, handshake_deadline_from("soon"), 20 * time.Second)
}

// A timeout, a relay closing early and a non-101 status are reported
// distinctly so the bridge log says which one happened.
@(test)
handshake_failure_reasons_are_specific :: proc(t: ^testing.T) {
	r := handshake_failure_reason("", true, 20 * time.Second, "hub.example", 443)
	testing.expect(t, strings.contains(r, "timed out") && strings.contains(r, "hub.example:443") && strings.contains(r, "HAM_WS_HANDSHAKE_TIMEOUT_MS"), r)
	r = handshake_failure_reason("", false, 20 * time.Second, "hub.example", 443)
	testing.expect(t, strings.contains(r, "closed before any handshake response"), r)
	r = handshake_failure_reason("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n", false, 20 * time.Second, "hub.example", 443)
	testing.expect(t, strings.contains(r, "rejected by hub.example:443: HTTP/1.1 302 Found") && !strings.contains(r, "Location"), r)
	set_last_connect_error(r)
	testing.expect(t, strings.contains(last_connect_error(), "302 Found"), "last_connect_error round-trips")
}
