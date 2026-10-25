package http_client

import "core:net"
import "core:time"
import tls "../tls_stream"

// This API grants one cumulative monotonic budget to DNS, connect, TLS, writes
// and every read. There is no detached I/O thread and the caller owns teardown.
request_with_headers_deadline :: proc(method, base_url, request_path, body: string, headers: []Header, timeout_ms: int) -> (Response, bool) {
    may_have_sent := false
    if timeout_ms <= 0 do return Response{may_have_sent=may_have_sent}, false
    started := time.tick_now()
    remaining := proc(started: time.Tick, ms: int) -> time.Duration {
        return max(0, time.Duration(ms)*time.Millisecond - time.tick_since(started))
    }
    host, port, secure, valid := parse_base_url(base_url)
    if !valid do return Response{may_have_sent=may_have_sent}, false
    path := request_target(base_url, request_path)
    req := build_http_request(method, host, port, path, body, headers)
    defer delete(req)
    data := make([dynamic]byte, 0, 8192)
    defer delete(data)
    buf: [8192]byte
    if secure {
        // The Windows SChannel backend currently has an unbounded system DNS
        // entrypoint. Fail closed instead of pretending to enforce this API.
        when ODIN_OS == .Windows { return Response{may_have_sent=may_have_sent}, false }
        else {
            stream, ok := tls.dial(host, port, remaining(started, timeout_ms))
            if !ok do return Response{may_have_sent=may_have_sent}, false
            defer { tls.abort(&stream); tls.close(&stream) }
            left := remaining(started, timeout_ms)
            if left <= 0 do return Response{may_have_sent=may_have_sent}, false
            // write_all cannot report its partial byte count; a failure here
            // must conservatively be treated as an uncertain request.
            may_have_sent = true
            if tls.write_all(&stream, transmute([]byte)req, left) != .Ok do return Response{may_have_sent=may_have_sent}, false
            for remaining(started, timeout_ms) > 0 {
                ready, available := tls.has_data(&stream)
                // The relay closing its stdout (POLLHUP with nothing left to read)
                // is how a TLS peer's close arrives here. It ends a close-delimited
                // or already-whole response; os.pipe_has_data reports it as an
                // error, which used to turn a complete chunked 200 into a failure.
                if !available do return deadline_finish_eof(data[:], may_have_sent)
                if ready {
                    n, read_ok := tls.read(&stream, buf[:])
                    if !read_ok do return Response{may_have_sent=may_have_sent}, false
                    if n == 0 do return deadline_finish_eof(data[:], may_have_sent)
                    append(&data, ..buf[:n])
                    if response_complete(string(data[:])) do return deadline_parse_response(data[:], may_have_sent)
                } else {
                    // Do not reap here: teardown must kill before reaping, so a
                    // later abort cannot signal a recycled process id.
                    time.sleep(min(time.Millisecond, remaining(started, timeout_ms)))
                }
            }
            return Response{may_have_sent=may_have_sent}, false
        }
    }
    when ODIN_OS == .Windows {
        if _, literal := resolve_host_without_dns(host_trim_brackets(host), int(port)); !literal do return Response{may_have_sent=may_have_sent}, false
    }
    left_ms := int(remaining(started, timeout_ms)/time.Millisecond)
    if left_ms <= 0 do return Response{may_have_sent=may_have_sent}, false
    endpoint, found := resolve_host_with_timeout(host, int(port), left_ms)
    if !found do return Response{may_have_sent=may_have_sent}, false
    sock_any, create_err := net.create_socket(net.family_from_endpoint(endpoint), .TCP)
    if create_err != nil do return Response{may_have_sent=may_have_sent}, false
    socket := sock_any.(net.TCP_Socket)
    defer net.close(socket)
    if net.set_blocking(socket, false) != nil do return Response{may_have_sent=may_have_sent}, false
    left_ms = int(remaining(started, timeout_ms)/time.Millisecond)
    if left_ms <= 0 || !connect_with_timeout(socket, endpoint, left_ms) do return Response{may_have_sent=may_have_sent}, false
    sent := 0
    for sent < len(req) && remaining(started, timeout_ms) > 0 {
        n, err := net.send_tcp(socket, transmute([]byte)req[sent:])
        if n > 0 do may_have_sent = true
        if err != nil && err != .Would_Block && err != .Timeout do return Response{may_have_sent=may_have_sent}, false
        if n > 0 do sent += n
        if n <= 0 do time.sleep(min(time.Millisecond, remaining(started, timeout_ms)))
    }
    if sent != len(req) do return Response{may_have_sent=may_have_sent}, false
    for remaining(started, timeout_ms) > 0 {
        n, err := net.recv_tcp(socket, buf[:])
        if err != nil {
            if err != .Would_Block && err != .Timeout do return Response{may_have_sent=may_have_sent}, false
            time.sleep(min(time.Millisecond, remaining(started, timeout_ms)))
            continue
        }
        if n == 0 do return deadline_finish_eof(data[:], may_have_sent)
        append(&data, ..buf[:n])
        if response_complete(string(data[:])) do return deadline_parse_response(data[:], may_have_sent)
    }
    return Response{may_have_sent=may_have_sent}, false
}

deadline_supported :: proc(base_url: string) -> bool {
    host, port, secure, valid := parse_base_url(base_url)
    if !valid do return false
    when ODIN_OS == .Windows {
        if secure do return false
        _, literal := resolve_host_without_dns(host_trim_brackets(host), int(port))
        return literal
    } else { return true }
}

// deadline_finish_eof parses what a closed peer sent, but only if it is a whole
// response: a truncated Content-Length or chunk stream is still a failure.
deadline_finish_eof :: proc(data: []byte, may_have_sent: bool) -> (Response, bool) {
    if !response_complete_at_eof(string(data)) do return Response{may_have_sent=may_have_sent}, false
    return deadline_parse_response(data, may_have_sent)
}

deadline_parse_response :: proc(data: []byte, may_have_sent: bool) -> (Response, bool) {
    resp, ok := parse_response_bytes(data)
    resp.may_have_sent = may_have_sent
    return resp, ok
}
