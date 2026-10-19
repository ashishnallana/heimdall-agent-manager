package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// An in-process stand-in for the local Bridge JSONL endpoint (tcp:127.0.0.1:N).
// It serves one prebuilt response line per accepted connection and records the
// request lines into fixed buffers, so the server thread never allocates. Tests
// use it to pin which agent.* method and params a ham-ctl verb actually sends.

FAKE_BRIDGE_MAX :: 8
FAKE_BRIDGE_LINE :: 32 * 1024

Fake_Bridge :: struct {
	listener:  net.TCP_Socket,
	responses: []string,
	served:    int,
	req_buf:   [FAKE_BRIDGE_MAX][FAKE_BRIDGE_LINE]byte,
	req_len:   [FAKE_BRIDGE_MAX]int,
	handle:    ^thread.Thread,
	endpoint:  string,
}

fake_bridge_thread :: proc(data: rawptr) {
	fb := cast(^Fake_Bridge)data
	for fb.served < len(fb.responses) && fb.served < FAKE_BRIDGE_MAX {
		client, _, aerr := net.accept_tcp(fb.listener)
		if aerr != nil do return
		_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
		buf := fb.req_buf[fb.served][:]
		total := 0
		for total < len(buf) {
			n, rerr := net.recv_tcp(client, buf[total:])
			if rerr != nil || n <= 0 do break
			total += n
			if strings.index_byte(string(buf[:total]), '\n') >= 0 do break
		}
		fb.req_len[fb.served] = total
		_, _ = net.send_tcp(client, transmute([]byte)fb.responses[fb.served])
		fb.served += 1
		net.close(client)
	}
}

// fake_bridge_start serves `responses` (each must end in "\n") in order.
fake_bridge_start :: proc(t: ^testing.T, responses: []string) -> ^Fake_Bridge {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, err == nil, "fake bridge binds") do return nil
	bound, berr := net.bound_endpoint(listener)
	if !testing.expect(t, berr == nil, "fake bridge bound endpoint") {
		net.close(listener)
		return nil
	}
	fb := new(Fake_Bridge)
	fb.listener = listener
	fb.responses = responses
	fb.endpoint = fmt.aprintf("tcp:127.0.0.1:%d", bound.port)
	fb.handle = thread.create_and_start_with_data(fb, fake_bridge_thread)
	return fb
}

fake_bridge_request :: proc(fb: ^Fake_Bridge, i: int) -> string {
	return string(fb.req_buf[i][:fb.req_len[i]])
}

// fake_bridge_stop joins the server; every expected request must have arrived.
fake_bridge_stop :: proc(fb: ^Fake_Bridge) {
	if fb == nil do return
	if fb.served < len(fb.responses) {
		// Unblock accept by connecting once so the thread can exit.
		for fb.served < len(fb.responses) {
			addr := net.IP4_Loopback
			parts := strings.split(fb.endpoint, ":", context.temp_allocator)
			port, _ := strconv_parse_int_agent(parts[2])
			s, derr := net.dial_tcp(addr, port)
			if derr != nil do break
			_, _ = net.send_tcp(s, transmute([]byte)string("\n"))
			buf: [256]byte
			_, _ = net.recv_tcp(s, buf[:])
			net.close(s)
		}
	}
	thread.join(fb.handle)
	thread.destroy(fb.handle)
	net.close(fb.listener)
	delete(fb.endpoint)
	free(fb)
}
