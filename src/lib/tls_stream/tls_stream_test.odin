package tls_stream

// Ported from src/lib/http_client: the Unix relay argv the WebSocket transport
// spawns. socat is the default and openssl the s_client fallback, so a package
// that ships only one of them breaks wss:// for one of the two settings. The
// tests use the pure relay_command_for_backend rather than HAM_TLS_BACKEND,
// because the test runner is concurrent and env is process-global.

import "core:strings"
import "core:testing"

@(test)
tls_backend_defaults_to_socat :: proc(t: ^testing.T) {
	// Unset/empty, the explicit default, odd casing+spacing, and an unknown value
	// must ALL select socat — only the exact "s_client" may divert.
	backends := [?]string{"", "socat", " SOCAT ", "openssl", "unknown"}
	for backend in backends {
		cmd := relay_command_for_backend(backend, "hub.brolabs.ai", 443, "")
		defer delete(cmd)
		testing.expect_value(t, len(cmd), 3)
		testing.expect_value(t, cmd[0], "socat")
		testing.expect_value(t, cmd[1], "STDIO")
		testing.expect_value(t, cmd[2], "OPENSSL-CONNECT:hub.brolabs.ai:443,snihost=hub.brolabs.ai,verify=1,commonname=hub.brolabs.ai")
	}
}

@(test)
tls_backend_s_client_uses_openssl :: proc(t: ^testing.T) {
	backends := [?]string{"s_client", " S_Client "}
	for backend in backends {
		cmd := relay_command_for_backend(backend, "hub.brolabs.ai", 443, "/etc/ssl/ca.pem")
		defer delete(cmd)
		testing.expect_value(t, cmd[0], "openssl")
		testing.expect_value(t, cmd[1], "s_client")
		joined := strings.join(cmd, " ")
		defer delete(joined)
		testing.expect(t, strings.contains(joined, "-verify_return_error"), joined)
		testing.expect(t, strings.contains(joined, "-CAfile /etc/ssl/ca.pem"), joined)
		testing.expect(t, strings.has_suffix(joined, "-connect hub.brolabs.ai:443"), joined)
	}
}
