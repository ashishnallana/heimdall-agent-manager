package ws

import "core:strings"
import "core:testing"
import "core:time"

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
