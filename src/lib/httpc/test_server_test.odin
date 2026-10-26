package httpc

// A scripted loopback HTTP/1.1 server for the httpc tests. Each accepted
// connection takes the next Test_Step: the server reads one whole request
// (headers + Content-Length body), records it, then replays the step's reply
// chunks (with optional pauses) and closes or holds the connection.

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Test_Step :: struct {
	chunks:      []string,      // written in order
	pause:       time.Duration, // between chunks
	hold:        time.Duration, // keep the connection open this long after replying
	no_read:     bool,          // reply without reading the request first
	close_early: bool,          // read the request, then close without replying
}

Test_Server :: struct {
	listener: net.TCP_Socket,
	port:     int,
	steps:    []Test_Step,
	mu:       sync.Mutex,
	requests: [dynamic]string, // raw requests (runtime heap)
	accepted: int,
	worker:   ^thread.Thread,
}

test_server_start :: proc(steps: []Test_Step) -> ^Test_Server {
	s := new(Test_Server, runtime.heap_allocator())
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		free(s, runtime.heap_allocator())
		return nil
	}
	bound, _ := net.bound_endpoint(listener)
	s.listener = listener
	s.port = bound.port
	s.steps = steps
	s.requests = make([dynamic]string, runtime.heap_allocator())
	s.worker = thread.create_and_start_with_data(s, test_server_run)
	return s
}

test_server_url :: proc(s: ^Test_Server, suffix := "") -> Url {
	u, _ := parse_url(fmt.tprintf("http://127.0.0.1:%d%s", s.port, suffix))
	return u
}

// test_server_stop joins the worker (all steps must have been consumed, or the
// listener is closed to unblock accept) and frees everything.
test_server_stop :: proc(s: ^Test_Server) {
	if s == nil do return
	// Wake a worker still parked in accept for an unused step.
	if sync.atomic_load(&s.accepted) < len(s.steps) {
		if sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = s.port}); err == nil {
			net.close(sock)
		}
	}
	thread.join(s.worker)
	thread.destroy(s.worker)
	net.close(s.listener)
	for r in s.requests do delete(r, runtime.heap_allocator())
	delete(s.requests)
	free(s, runtime.heap_allocator())
}

test_server_request :: proc(s: ^Test_Server, i: int) -> string {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if i >= len(s.requests) do return ""
	return s.requests[i]
}

test_server_run :: proc(data: rawptr) {
	s := (^Test_Server)(data)
	for step in s.steps {
		client, _, err := net.accept_tcp(s.listener)
		sync.atomic_add(&s.accepted, 1)
		if err != nil do return
		_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
		if !step.no_read {
			raw := test_read_request(client)
			sync.mutex_lock(&s.mu)
			append(&s.requests, raw)
			sync.mutex_unlock(&s.mu)
		}
		if !step.close_early {
			for chunk, i in step.chunks {
				if i > 0 && step.pause > 0 do time.sleep(step.pause)
				if _, serr := net.send_tcp(client, transmute([]byte)chunk); serr != nil do break
			}
			if step.hold > 0 do time.sleep(step.hold)
		}
		net.close(client)
	}
}

test_read_request :: proc(client: net.TCP_Socket) -> string {
	data := make([dynamic]byte, 0, 1024)
	defer delete(data)
	buf: [4096]byte
	for {
		raw := string(data[:])
		if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 {
			want := 0
			lines := raw[:idx]
			for line in strings.split_lines_iterator(&lines) {
				if colon := strings.index_byte(line, ':'); colon > 0 && strings.equal_fold(line[:colon], "content-length") {
					want, _ = strconv.parse_int(strings.trim_space(line[colon + 1:]))
				}
			}
			if len(raw) - (idx + 4) >= want do break
		}
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n == 0 do break
		append(&data, ..buf[:n])
	}
	return strings.clone(string(data[:]), runtime.heap_allocator())
}

// test_request_header finds a header in a raw recorded request ("" if absent).
test_request_header :: proc(raw, name: string) -> (string, bool) {
	idx := strings.index(raw, "\r\n\r\n")
	head := raw if idx < 0 else raw[:idx]
	first := true
	for line in strings.split_lines_iterator(&head) {
		if first {
			first = false
			continue
		}
		if colon := strings.index_byte(line, ':'); colon > 0 && strings.equal_fold(line[:colon], name) {
			return strings.trim_space(line[colon + 1:]), true
		}
	}
	return "", false
}

test_request_line :: proc(raw: string) -> string {
	if idx := strings.index(raw, "\r\n"); idx >= 0 do return raw[:idx]
	return raw
}

test_request_body :: proc(raw: string) -> string {
	if idx := strings.index(raw, "\r\n\r\n"); idx >= 0 do return raw[idx + 4:]
	return ""
}

test_reply :: proc(status: int, reason: string, headers: string, body: string) -> string {
	return fmt.tprintf("HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n%s", status, reason, len(body), headers, body)
}
