package http_client
import "core:testing"
import "core:net"
import "core:fmt"
import "core:thread"
import "core:time"
import "core:os"
import "core:log"

Deadline_Trickle :: struct { listener: net.TCP_Socket, closed: bool }
deadline_trickle_thread :: proc(data: rawptr) {
    f := (^Deadline_Trickle)(data)
    client, _, err := net.accept_tcp(f.listener)
    if err != nil do return
    defer net.close(client)
    buf: [4096]byte
    _ = net.set_option(client, .Receive_Timeout, time.Second)
    _, _ = net.recv_tcp(client, buf[:])
    header := "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
    _, _ = net.send_tcp(client, transmute([]byte)header)
    for _ in 0..<12 {
        time.sleep(20*time.Millisecond)
        if _, err := net.send_tcp(client, []byte{'x'}); err != nil do break
    }
    f.closed = true
}
@(test)
deadline_bounds_slow_trickle_across_all_reads :: proc(t: ^testing.T) {
    listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, err == nil) do return
    defer net.close(listener)
    bound, _ := net.bound_endpoint(listener)
    f := Deadline_Trickle{listener = listener}
    worker := thread.create_and_start_with_data(&f, deadline_trickle_thread)
    defer { thread.join(worker); thread.destroy(worker) }
    started := time.tick_now()
    resp, ok := request_with_headers_deadline("GET", fmt.tprintf("http://127.0.0.1:%d", bound.port), "/", "", nil, 80)
    defer delete(resp.body)
    elapsed := time.tick_since(started)
    testing.expect(t, !ok)
    testing.expect(t, resp.may_have_sent, "a lost/truncated response fences unsafe POST replay")
    testing.expect(t, elapsed >= 50*time.Millisecond && elapsed < 300*time.Millisecond)
}
@(test)
deadline_positive_complete_response_and_zero_budget :: proc(t: ^testing.T) {
    response := http_test_response(200, "OK", "", "complete")
    mock, port, worker := http_test_start_mock(t, []string{response})
    if worker == nil do return
    defer http_test_mock_join(mock, worker)
    resp, ok := request_with_headers_deadline("GET", fmt.tprintf("http://127.0.0.1:%d", port), "/", "", nil, 1000)
    defer delete(resp.body)
    testing.expect(t, ok && resp.status == 200 && resp.body == "complete")
    _, granted := request_with_headers_deadline("GET", "http://localhost", "/", "", nil, 0)
    testing.expect(t, !granted)
}

// ---- Response framing (bridge credential refresh incident, 2026-10-25) ----
//
// A hub reply of 256+ bytes is gzipped by the origin-side nginx
// (recommendedGzipSettings: gzip_min_length 256) and re-framed as chunked by
// Cloudflare for a client that sent no Accept-Encoding. The deadline reader only
// recognised Content-Length, and over TLS a peer close arrives as POLLHUP on the
// relay pipe, which it treated as an error. So a complete 200 refresh reply was
// reported as a failed request (Bridge_Timeout) after the hub had rotated the
// token.

@(test)
deadline_framing_detects_chunked_and_any_header_case :: proc(t: ^testing.T) {
    chunked := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    testing.expect(t, response_complete(chunked), "a terminated chunked body is complete")
    testing.expect(t, !response_complete(chunked[:len(chunked) - 2]), "the final empty line is required")
    testing.expect(t, !response_complete("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"), "a partial chunk is not complete")
    testing.expect(t, response_complete("HTTP/1.1 200 OK\r\ntransfer-encoding: CHUNKED\r\n\r\n0\r\nx-trailer: 1\r\n\r\n"), "trailers end at the empty line")
    testing.expect(t, response_complete("HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 2\r\n\r\nok"), "Content-Length matches in any case")
    testing.expect(t, !response_complete("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nok"), "close-delimited bodies need the close")
    testing.expect(t, response_complete_at_eof("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nok"), "the close delimits an unframed body")
    testing.expect(t, !response_complete_at_eof("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nok"), "a short Content-Length body stays truncated")
    testing.expect(t, !response_complete_at_eof("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"), "an unterminated chunk stream stays truncated")
    _, sixteen := parse_hex_size("1000000000000000")
    testing.expect(t, !sixteen, "a chunk size over 15 hex digits is refused, never wrapped")
    huge, fifteen := parse_hex_size("fffffffffffffff")
    testing.expect(t, fifteen && huge > 0)
    testing.expect(t, !response_complete("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\nx\r\n0\r\n\r\n"), "an overflowing size is not a complete response")
    resp, ok := deadline_finish_eof(transmute([]byte)chunked, true)
    defer delete(resp.body)
    testing.expect(t, ok && resp.status == 200 && resp.body == "hello")
}

Deadline_Chunked_Keepalive :: struct { listener: net.TCP_Socket }
deadline_chunked_keepalive_thread :: proc(data: rawptr) {
    f := (^Deadline_Chunked_Keepalive)(data)
    client, _, err := net.accept_tcp(f.listener)
    if err != nil do return
    defer net.close(client)
    buf: [4096]byte
    _ = net.set_option(client, .Receive_Timeout, time.Second)
    _, _ = net.recv_tcp(client, buf[:])
    // No Connection: close and no close until well after the client's budget: the
    // reader must stop at the terminating chunk, not wait for EOF.
    resp := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    _, _ = net.send_tcp(client, transmute([]byte)resp)
    time.sleep(1500 * time.Millisecond)
}

@(test)
deadline_chunked_reply_completes_without_waiting_for_close :: proc(t: ^testing.T) {
    listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, err == nil) do return
    defer net.close(listener)
    bound, _ := net.bound_endpoint(listener)
    f := Deadline_Chunked_Keepalive{listener = listener}
    worker := thread.create_and_start_with_data(&f, deadline_chunked_keepalive_thread)
    defer { thread.join(worker); thread.destroy(worker) }
    resp, ok := request_with_headers_deadline("POST", fmt.tprintf("http://127.0.0.1:%d", bound.port), "/", "{}", nil, 1000)
    defer delete(resp.body)
    testing.expect(t, ok && resp.status == 200 && resp.body == "hello", fmt.tprintf("ok=%v status=%d body=%q", ok, resp.status, resp.body))
}

// The TLS path, end to end through the real socat relay: a chunked 200 followed by
// the server closing. This is the exact shape that stranded the bridge. Skipped
// when openssl/socat are not on PATH (they are inside `nix develop`).
@(test)
deadline_tls_chunked_reply_then_close_is_a_success :: proc(t: ^testing.T) {
    if !deadline_test_tool_present("openssl") || !deadline_test_tool_present("socat") {
        log.warn("skipping: openssl and socat are required")
        return
    }
    home := os.get_env("HOME", context.temp_allocator)
    dir := fmt.tprintf("%s/.cache/heimdall-tests/tls-chunked-%d", home, time.to_unix_nanoseconds(time.now()))
    _ = os.make_directory_all(dir)
    defer _ = os.remove_all(dir)
    cert := fmt.tprintf("%s/cert.pem", dir)
    key := fmt.tprintf("%s/key.pem", dir)
    gen, _, _, gen_err := os.process_exec(os.Process_Desc{command = []string{
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
    }}, context.temp_allocator)
    if !testing.expect(t, gen_err == nil && gen.exited && gen.success, "test certificate generated") do return
    probe, perr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, perr == nil) do return
    bound, _ := net.bound_endpoint(probe)
    net.close(probe)
    reply_path := fmt.tprintf("%s/reply.http", dir)
    reply_bytes := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\n{\"a\":1}\r\n0\r\n\r\n"
    if !testing.expect(t, os.write_entire_file(reply_path, transmute([]byte)reply_bytes) == nil) do return
    server, serr := os.process_start(os.Process_Desc{command = []string{
        "socat", fmt.tprintf("OPENSSL-LISTEN:%d,bind=127.0.0.1,reuseaddr,fork,cert=%s,key=%s,verify=0", bound.port, cert, key),
        fmt.tprintf("EXEC:cat %s", reply_path),
    }})
    if !testing.expect(t, serr == nil, "socat TLS server starts") do return
    defer { _ = os.process_kill(server); _, _ = os.process_wait(server) }
    // Wait for the listener rather than racing it.
    for _ in 0..<100 {
        sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
        if derr == nil { net.close(sock); break }
        time.sleep(20 * time.Millisecond)
    }
    // No other test in this package dials TLS, so the process-global CA override
    // cannot leak into a concurrent test's transport.
    os.set_env("HAM_TLS_CA_FILE", cert)
    defer os.unset_env("HAM_TLS_CA_FILE")
    resp, ok := request_with_headers_deadline("POST", fmt.tprintf("https://localhost:%d", bound.port), "/api/v1/device/bridge-refresh", "{}", nil, 5000)
    defer delete(resp.body)
    testing.expect(t, ok && resp.status == 200 && resp.body == `{"a":1}`, fmt.tprintf("ok=%v status=%d body=%q", ok, resp.status, resp.body))
}

deadline_test_tool_present :: proc(name: string) -> bool {
    state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", fmt.tprintf("command -v %s >/dev/null", name)}}, context.temp_allocator)
    return err == nil && state.exited && state.success
}
