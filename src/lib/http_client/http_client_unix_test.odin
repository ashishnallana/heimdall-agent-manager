#+build !windows
package http_client

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The Unix TLS transport is the socat / openssl relay subprocess; this pins its
// half-close behavior. Windows uses in-process SChannel and has no relay.

// A fake `socat` on PATH that behaves like the real relay's half-close grace:
// after reading the request headers it waits ~100 ms, and if its stdin has been
// closed by then it exits WITHOUT answering (what real socat does once its
// default grace expires). A client that keeps stdin open until the response is
// complete gets HTTP 200.
FAKE_SOCAT_SCRIPT :: `#!/bin/bash
while IFS= read -r line; do [[ "$line" == "" || "$line" == $'\r' ]] && break; done
sleep 0.1
if read -t 0.05 -r _; then :; else rc=$?; [ "$rc" -gt 128 ] || exit 0; fi
printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'
`

@(test)
tls_request_survives_a_slow_first_byte :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/ham-fake-socat-%d", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	testing.expect_value(t, os.make_directory(dir), nil)
	defer os.remove_all(dir)
	script := strings.concatenate({dir, "/socat"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(script, transmute([]byte)string(FAKE_SOCAT_SCRIPT)), nil)
	testing.expect_value(t, os.chmod(script, {.Read_User, .Write_User, .Execute_User}), nil)
	old_path := os.get_env("PATH", context.temp_allocator)
	defer os.set_env("PATH", old_path)
	testing.expect_value(t, os.set_env("PATH", strings.concatenate({dir, ":", old_path}, context.temp_allocator)), nil)
	testing.expect_value(t, os.set_env("HAM_TLS_BACKEND", "socat"), nil)
	defer os.unset_env("HAM_TLS_BACKEND")

	resp, ok := request_with_headers_timeout("GET", "https://hub.invalid:443", "/api/v1/health", "", nil, 5000)
	testing.expect(t, ok, "a response must arrive even when the first byte is delayed")
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.body, "ok")
}
