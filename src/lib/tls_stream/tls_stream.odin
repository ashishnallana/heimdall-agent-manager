// Package tls_stream is the TLS client transport behind src/lib/ws (wss://).
// Outbound HTTP(S) no longer uses it: that is src/lib/httpc (libcurl). Callers
// see a single Stream API; the backend is per-OS:
//
//   - Unix (tls_stream_unix.odin): a TLS relay SUBPROCESS -- socat by default,
//     `openssl s_client` when HAM_TLS_BACKEND=s_client -- spoken to over pipes.
//     This is the historical transport, moved here unchanged.
//   - Windows (tls_stream_windows.odin): SChannel in-process over a TCP socket, so
//     a stock Windows install needs no socat/openssl binary.
//
// Stream API (all backends):
//   dial(host, port, timeout)          -> Stream, ok      (last_dial_error() on failure)
//   has_data(&s)    -> (ready, ok)      non-blocking: true when read() will not block
//   read(&s, buf)   -> (n, ok)          n == 0 with ok == true is end of stream
//   write_all(&s, bytes, timeout)       timeout 0 blocks; else partial writes are fatal
//   abort(&s)                           wake a blocked reader from another thread
//   close(&s)                           release everything; reader-owned (see AGENTS.md)
package tls_stream

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

Write_Result :: enum {
	Ok,
	Timed_Out,
	Failed,
}

// last_dial_error is the reason the most recent dial failed, for the caller's log
// line ("could not start the TLS relay", "TLS handshake failed: ...").
_last_dial_error: string
_last_dial_error_mu: sync.Mutex

set_last_dial_error :: proc(reason: string) {
	sync.mutex_lock(&_last_dial_error_mu)
	defer sync.mutex_unlock(&_last_dial_error_mu)
	if len(_last_dial_error) > 0 do delete(_last_dial_error)
	_last_dial_error = strings.clone(reason)
}

last_dial_error :: proc(allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&_last_dial_error_mu)
	defer sync.mutex_unlock(&_last_dial_error_mu)
	return strings.clone(_last_dial_error, allocator)
}

host_trim_brackets :: proc(host: string) -> string {
	if len(host) >= 2 && host[0] == '[' && host[len(host)-1] == ']' {
		return host[1:len(host)-1]
	}
	return host
}

// ca_file is the extra trust anchor from HAM_TLS_CA_FILE ("" = system store).
ca_file :: proc() -> string {
	return strings.trim_space(os.get_env("HAM_TLS_CA_FILE", context.temp_allocator))
}

// relay_command builds the argv of the Unix TLS relay subprocess. The transport is
// selected by the HAM_TLS_BACKEND env toggle:
//   - "s_client"      -> legacy `openssl s_client` (fallback; 16 KB teardown).
//   - anything else   -> `socat OPENSSL-CONNECT` (DEFAULT; full-duplex, no teardown).
// SHARED CONTRACT: the bridge's bridge_tls_backend_is_socat
// (src/bridge/fs_management.odin) applies the same rule -- keep them in sync.
// Either helper must be on PATH for any wss:// connection on Unix (the bridge's
// hub WebSocket) -- see the ham-bridge runtimeInputs in flake.nix. The Windows
// backend ignores HAM_TLS_BACKEND. HTTPS (src/lib/httpc) does not use it.
relay_command :: proc(host: string, port: u16) -> []string {
	return relay_command_for_backend(os.get_env("HAM_TLS_BACKEND", context.temp_allocator), host, port, ca_file())
}

// relay_command_for_backend is the pure core of relay_command with the backend
// toggle and CA path passed in explicitly. Splitting it out lets unit tests pin a
// specific backend deterministically WITHOUT mutating the global HAM_TLS_BACKEND env
// (the Odin test runner executes tests concurrently, so env mutation would race
// other tests' transport selection). `backend` is normalized here (trimmed +
// lowercased) rather than by the caller, so the raw env value and a test-supplied
// value cannot diverge; only the exact value "s_client" selects the legacy path.
relay_command_for_backend :: proc(backend: string, host: string, port: u16, ca_file: string) -> []string {
	clean_host := host_trim_brackets(host)
	if strings.to_lower(strings.trim_space(backend), context.temp_allocator) == "s_client" {
		return openssl_s_client_command(clean_host, port, ca_file)
	}
	return socat_openssl_command(clean_host, port, ca_file)
}

// openssl_s_client_command is the legacy fallback transport (HAM_TLS_BACKEND=s_client).
openssl_s_client_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	cmd := make([dynamic]string)
	append(&cmd, "openssl")
	append(&cmd, "s_client")
	append(&cmd, "-quiet")
	append(&cmd, "-verify_return_error")
	append(&cmd, "-servername")
	append(&cmd, clean_host)
	append(&cmd, "-verify_hostname")
	append(&cmd, clean_host)
	if ca_file != "" {
		append(&cmd, "-CAfile")
		append(&cmd, ca_file)
	}
	append(&cmd, "-connect")
	append(&cmd, fmt.tprintf("%s:%d", clean_host, port))
	return cmd[:]
}

// socat_openssl_command is the default transport. It relays STDIO <-> an OpenSSL
// TLS connection. TLS verification is EQUIVALENT to the s_client path and MUST NOT
// be weakened:
//   - verify=1        : require + verify the peer certificate chain (fail closed).
//   - commonname=<h>  : check the cert's CN/SAN against the intended host -- this is
//                       the hostname verification (mirrors s_client -verify_hostname).
//   - snihost=<h>     : send SNI so the server presents the right cert (mirrors
//                       s_client -servername).
//   - cafile=<ca>     : trust anchor when HAM_TLS_CA_FILE is set; when unset, socat
//                       uses OpenSSL's default CA store, exactly like s_client with
//                       no -CAfile. NEVER emit verify=0.
// The option string is temp-allocated: the argv is consumed immediately by
// os.process_start in the same frame, and on the default allocator this builder
// leaked on every https call -- a per-request leak in a long-running hub.
socat_openssl_command :: proc(clean_host: string, port: u16, ca_file: string) -> []string {
	opts := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&opts, "OPENSSL-CONNECT:%s:%d", clean_host, port)
	fmt.sbprintf(&opts, ",snihost=%s", clean_host)
	strings.write_string(&opts, ",verify=1")
	fmt.sbprintf(&opts, ",commonname=%s", clean_host)
	if ca_file != "" {
		fmt.sbprintf(&opts, ",cafile=%s", ca_file)
	}
	cmd := make([dynamic]string)
	append(&cmd, "socat")
	append(&cmd, "STDIO")
	append(&cmd, strings.to_string(opts))
	return cmd[:]
}
